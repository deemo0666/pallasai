// 自动化任务 that may need the screen wait while Pallas Agent is not in front.
//
// The scheduler delivers whatever is due the moment the engine runs, and iOS runs the app in the
// background now and then (memory tidying, a background refresh, the seconds after it leaves the
// screen). A task that needs the screen then fails at once ("请先回到 Pallas Agent 再开始任务") and its
// turn is used up, where the same task run with the app in front gets done.
//
// Whether a task needs the screen is decided by the model while it runs, so it is learned from the
// runs: a task that touched the phone in one of its last runs (up to three) waits; any other task,
// one that has not run yet included, runs in the background and waits only at its first phone step
// (`beforePhone`). A task known to use the screen is held before its run starts rather than inside
// it, because a run waiting in the background keeps its turn open and is lost if iOS ends the app.
// With phone control off no task can touch the phone and nothing waits.
//
// A held task stays due: `deliverDue` answers "these remain due", which the scheduler already
// understands as "skip them until the next drive request", and coming back in front requests one.
//
// A wrong guess costs time, not the run: a task let through that then reaches for the phone waits
// inside that step (`beforePhone`) until the app is in front, and goes on from there.
const fs = require('node:fs');
const wrapped = Symbol('dsh.ios.scheduleHold');
const kept = 3, most = 500;

/**
 * @param initial {phoneOn: boolean, front: boolean, file: () => string|undefined, waiting?: (run) => void}
 *   `file` is where the runs are remembered (also read by the app, DueTasks.swift);
 *   `waiting` is told when a run stops to wait for the app.
 */
exports.create = function (initial) {
  const state = { phoneOn: !!initial.phoneOn, front: !!initial.front };
  let runtime, history;
  const turnOf = new Map(), runs = new Map(), waiters = new Set();

  function load() {
    if (history) return history;
    history = {};
    try { history = JSON.parse(fs.readFileSync(initial.file(), 'utf8')) || {}; } catch {}
    return history;
  }
  function remember(ids, usedScreen) {
    const all = load();
    for (const id of ids) {
      const past = Array.isArray(all[id]) ? all[id] : [];
      delete all[id];                       // newest last, so the oldest tasks go first when full
      all[id] = [...past, usedScreen].slice(-kept);
    }
    for (const id of Object.keys(all).slice(0, Math.max(0, Object.keys(all).length - most))) delete all[id];
    try {
      const file = initial.file();
      fs.writeFileSync(file + '.tmp', JSON.stringify(all), { mode: 0o600 });
      fs.renameSync(file + '.tmp', file);
    } catch {}
  }
  /** Its completed runs so far never touched the phone. */
  function screenFree(id) {
    const past = load()[id];
    return Array.isArray(past) && past.length > 0 && past.every(used => used === false);
  }
  /** One of its last runs touched the phone. */
  function usedScreen(id) {
    const past = load()[id];
    return Array.isArray(past) && past.includes(true);
  }
  const away = () => state.phoneOn && !state.front;
  const held = id => away() && usedScreen(id);

  function wrap(target) {
    runtime = target;
    if (!target || target[wrapped] || typeof target.deliverDue !== 'function') return;
    const deliver = target.deliverDue;
    target[wrapped] = true;
    target.deliverDue = async function (group, batch) {
      const waiting = group.filter(task => held(task.record.id)).map(task => task.record.id);
      if (!waiting.length) return deliver.call(this, group, batch);
      const going = group.filter(task => !waiting.includes(task.record.id));
      return going.length ? [...waiting, ...await deliver.call(this, going, batch)] : waiting;
    };
  }

  return {
    held, screenFree, usedScreen,
    /**
     * The `schedule` service; its runtime may be set later, at the end of its own start. Keeps any
     * accessor already on it (task-notes.cjs wraps the same runtime).
     */
    attach(service) {
      const prior = Object.getOwnPropertyDescriptor(service, 'runtime');
      let current = service.runtime;
      Object.defineProperty(service, 'runtime', {
        configurable: true, enumerable: true,
        get: () => prior?.get ? prior.get.call(service) : current,
        set: value => { if (prior?.set) prior.set.call(service, value); else current = value; wrap(value); },
      });
      wrap(service.runtime);
    },
    /** A change of either fact; leaving the hold runs what became due meanwhile. */
    set(change) {
      const before = away();
      Object.assign(state, change);
      if (state.front || !state.phoneOn) { for (const go of [...waiters]) go(); }
      if (before && !away()) runtime?.requestDrive?.();
    },
    /** Every session event: which turns are task runs, and how they end. */
    observe(sessionID, event) {
      const data = event?.data ?? {};
      if (event.type === 'turn/start') turnOf.set(sessionID, data.turn);
      else if (event.type === 'user/message' && data.source?.kind === 'schedule') {
        const text = (data.content ?? []).map(block => block.text ?? '').join('\n');
        const ids = [...text.matchAll(/schedule_id(?:_json)?"?:\s*"(schedule-[0-9a-fA-F-]{8,})"/g)].map(match => match[1]);
        if (ids.length) runs.set(sessionID, { turn: turnOf.get(sessionID), ids: [...new Set(ids)], session: sessionID, usedScreen: false });
      } else if (event.type === 'turn/end') {
        const run = runs.get(sessionID);
        if (!run || (run.turn !== undefined && run.turn !== data.turn)) return;
        runs.delete(sessionID);
        // A run that failed or was stopped says nothing about what the task needs.
        // One that touched the phone was noted when it did.
        if (data.reason?.kind === 'completed' && !run.usedScreen) remember(run.ids, false);
      }
    },
    /**
     * Before a step that drives the phone. In a task's run with the app off screen and no app
     * opened by this turn yet, waits for Pallas Agent to be in front (the person opening it).
     * @param opened whether this turn already has an app open, which is why the app is off screen
     */
    async beforePhone(sessionID, turn, opened, signal) {
      const run = runs.get(sessionID);
      if (!run || (run.turn !== undefined && run.turn !== turn)) return;
      if (!run.usedScreen) { run.usedScreen = true; remember(run.ids, true); }
      if (state.front || opened) return;
      initial.waiting?.(run);
      await new Promise((resolve, reject) => {
        const done = () => { waiters.delete(done); signal?.removeEventListener('abort', stop); resolve(); };
        const stop = () => { waiters.delete(done); reject(signal.reason ?? new Error('calculator_stopped')); };
        waiters.add(done);
        signal?.addEventListener('abort', stop, { once: true });
      });
    },
  };
};
