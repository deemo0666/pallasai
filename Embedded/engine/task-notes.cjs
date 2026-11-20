// Each 自动化任务's own notes on how to run it ("打开快递 App 看，不是查邮件"), kept apart from the
// person's memory (memory.cjs), which is about the person and not about one task.
//
// The model writes them with the task_notes tool when the person corrects how a task was done. The
// next run gets them in its [SCHEDULE REMINDER] message: the scheduler's runtime builds that text and
// hands it to its own `send`, which is wrapped here (from the plugin side, the way schedule-hold.cjs
// wraps `deliverDue`), so the notes reach the run whether it goes to the same conversation or a new one.
//
// Stored in DSH_HOME/ios-task-notes.json as {"schedule-…": ["note", …]}; the task's page in the app
// (AutomationViews.swift, TaskNotes) reads, edits and clears the same file. Read afresh on every use,
// so an edit in the app reaches the next run. Notes of tasks that no longer exist are dropped.
const fs = require('node:fs');
const path = require('node:path');
const P = require('./prompts/task-notes.cjs');

const LIMIT = { notes: 8, length: 300 };
const wrapped = Symbol('dsh.ios.taskNotes');
const ID = /schedule_id(?:_json)?"?:\s*"(schedule-[0-9a-fA-F-]{8,})"/g;

function length(text) { let count = 0; for (const _ of text) count++; return count; }

/** The ids a scheduler run message is for; none for any other text (change notices included). */
function runIDs(text) {
  if (typeof text !== 'string' || !text.startsWith('[SCHEDULE REMINDER')) return [];
  return [...new Set([...text.matchAll(ID)].map(match => match[1]))];
}

/**
 * @param options {file: () => string, refusal?: (text) => string|undefined}
 *   `refusal` says why a note must not be stored (memory.cjs's check for secrets and injected instructions).
 */
exports.create = function (options) {
  let runtime;
  const lastRun = new Map();      // session → ids of the task run seen last in it

  function load() {
    try {
      const value = JSON.parse(fs.readFileSync(options.file(), 'utf8'));
      if (value && typeof value === 'object' && !Array.isArray(value)) return value;
    } catch {}
    return {};
  }
  function save(all) {
    const file = options.file();
    for (const id of Object.keys(all)) if (!Array.isArray(all[id]) || !all[id].length) delete all[id];
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file + '.tmp', JSON.stringify(all), { mode: 0o600 });
    fs.renameSync(file + '.tmp', file);
  }
  function list(id) {
    return notesFor(load(), id);
  }
  function notesFor(all, id) {
    const notes = all[id];
    return Array.isArray(notes) ? notes.filter(note => typeof note === 'string' && note.trim()) : [];
  }
  /** Every task the scheduler has, or undefined before its runtime is known. */
  function tasks() {
    try { const all = runtime?.tasks?.(); return Array.isArray(all) ? all : undefined; } catch { return undefined; }
  }
  /** Drops the notes of tasks that are gone; only with a non-empty task list, never on a guess. */
  function prune(live) {
    if (!live?.length) return;
    const ids = new Set(live);
    const all = load();
    const gone = Object.keys(all).filter(id => !ids.has(id));
    if (!gone.length) return;
    for (const id of gone) delete all[id];
    try { save(all); } catch {}
  }

  /** The run message with the notes of its tasks below it; unchanged when they have none. */
  function frame(text) {
    const ids = runIDs(text);
    if (!ids.length) return text;
    const all = load();
    const notes = {};
    for (const id of ids) {
      const kept = notesFor(all, id);
      if (kept.length) notes[id] = kept;
    }
    if (!Object.keys(notes).length) return text;
    return `${text}\n\n[TASK NOTES]\nHow to run these tasks, kept from the person's corrections of earlier runs. Follow them.\ntask_notes_json: ${JSON.stringify(notes)}`;
  }

  function wrap(target) {
    runtime = target;
    if (!target || target[wrapped] || typeof target.send !== 'function') return;
    const send = target.send;
    target[wrapped] = true;
    target.send = function (agent, text, held) {
      try {
        prune(tasks()?.map(task => task?.record?.id).filter(Boolean));
        text = frame(text);
      } catch {}
      return send.call(this, agent, text, held);
    };
  }

  function title(id) {
    return tasks()?.find(task => task?.record?.id === id)?.record?.title || '';
  }
  function header(id, notes) {
    const name = title(id);
    return `Notes of task ${JSON.stringify(id)}${name ? ` (${JSON.stringify(name)})` : ''} [${notes.length}/${LIMIT.notes}]:\n`
      + (notes.length ? notes.map((note, i) => `${i + 1}. ${note}`).join('\n') : '(none)');
  }
  /** The task a call is about: the one named, or the one whose run is in this conversation. */
  function target(args, sessionID) {
    const named = typeof args?.schedule_id === 'string' ? args.schedule_id.trim() : '';
    if (named) {
      const live = tasks();
      if (live?.length && !live.some(task => task?.record?.id === named)) throw new Error(`no scheduled task has schedule_id ${JSON.stringify(named)}`);
      return named;
    }
    const ids = lastRun.get(sessionID) ?? [];
    if (ids.length === 1) return ids[0];
    if (ids.length > 1) throw new Error(`this conversation ran several tasks (${ids.join(', ')}); pass schedule_id`);
    throw new Error('no task run in this conversation is known; pass schedule_id, from the [SCHEDULE REMINDER] message or the schedule tools');
  }
  function locate(notes, needle) {
    const hits = notes.map((note, i) => note.includes(needle) ? i : -1).filter(i => i >= 0);
    if (!hits.length) throw new Error(`no note contains ${JSON.stringify(needle)}`);
    if (hits.length > 1) throw new Error(`${JSON.stringify(needle)} is in ${hits.length} notes; quote a longer piece found in only one`);
    return hits[0];
  }

  /** One tool call; returns the text the model reads, throws for a refused call. */
  function apply(args, sessionID) {
    const action = args?.action;
    if (!['add', 'patch', 'remove', 'list'].includes(action)) throw new Error('action must be add, patch, remove or list');
    const id = target(args, sessionID);
    const all = load();
    const notes = notesFor(all, id);
    if (action === 'list') return header(id, notes);
    const content = typeof args.content === 'string' ? args.content.trim().replace(/\s*\n\s*/g, ' ') : '';
    const needle = typeof args.old_text === 'string' ? args.old_text.trim() : '';
    if (action !== 'remove') {
      if (!content) throw new Error('content is required');
      if (length(content) > LIMIT.length) throw new Error(`a note is at most ${LIMIT.length} characters; this one is ${length(content)}. Shorten it. Nothing was written.`);
      const why = options.refusal?.(content);
      if (why) throw new Error(`refused: content ${why}`);
    }
    let next;
    if (action === 'add') {
      if (notes.includes(content)) return `Already noted; nothing written.\n${header(id, notes)}`;
      if (notes.length >= LIMIT.notes) throw new Error(`this task already has ${LIMIT.notes} notes. Patch one to cover this too, or remove one that no longer holds, then retry. Nothing was written.`);
      next = [...notes, content];
    } else {
      if (!needle) throw new Error('old_text is required: a short piece of the note to change');
      const index = locate(notes, needle);
      if (action === 'remove') next = notes.toSpliced(index, 1);
      else {
        if (notes.some((note, i) => i !== index && note === content)) throw new Error('another note already says exactly this; remove this one instead');
        next = notes.toSpliced(index, 1, content);
      }
    }
    all[id] = next;
    save(all);
    const verb = { add: 'Noted', patch: 'Updated', remove: 'Removed' }[action];
    return `${verb}. The task's next run reads these notes.\n${header(id, next)}`;
  }

  /** The runtime may be set later; retain accessors installed by schedule-hold.cjs. */
  function attach(service) {
    if (!service) return;
    const prior = Object.getOwnPropertyDescriptor(service, 'runtime');
    let current = service.runtime;
    Object.defineProperty(service, 'runtime', {
      configurable: true, enumerable: true,
      get: () => prior?.get ? prior.get.call(service) : current,
      set: value => { if (prior?.set) prior.set.call(service, value); else current = value; wrap(value); },
    });
    wrap(service.runtime);
  }

  function observedIDs(event) {
    if (event?.type !== 'user/message' || event.data?.source?.kind !== 'schedule') return [];
    return runIDs((event.data.content ?? []).map(block => block.text ?? '').join('\n'));
  }

  function observe(sessionID, event) {
    const ids = observedIDs(event);
    if (ids.length) lastRun.set(sessionID, ids);
  }

  function register(ctx, defineTool) {
    ctx.inject?.(['schedule'], inner => attach(inner.schedule));
    ctx.on?.('session/event', (session, event) => observe(session.id, event));
    ctx.systemPrompt.section({
      name: 'pallas:task_notes',
      order: ctx.systemPrompt.getSectionOrder('TOOL_READ'),
      text: ({scope}) => ctx.tools.get('task_notes', scope) ? P.system : '',
      interpolate: false,
    });
    ctx.tools.register(defineTool({
      name: 'task_notes',
      description: P.description,
      parameters: {
        action: { type: 'string', required: true, enum: ['add', 'patch', 'remove', 'list'], description: P.params.action },
        schedule_id: { type: 'string', description: P.params.schedule_id },
        content: { type: 'string', description: P.params.content },
        old_text: { type: 'string', description: P.params.old_text },
      },
      output: { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] },
      async execute(args, exec) {
        const session = exec?.agent?.session;
        if (session && !args?.schedule_id && !lastRun.has(session.id)) {
          const reminder = session.snapshotEvents?.().findLast(event => observedIDs(event).length);
          if (reminder) observe(session.id, reminder);
        }
        return apply(args, session?.id);
      },
    }));
  }

  return { list, frame, apply, prune, attach, observe, register };
};

exports.LIMIT = LIMIT;
exports.runIDs = runIDs;

exports.forHome = function forHome(home = process.env.DSH_HOME) {
  return exports.create({
    file: () => path.join(home, 'ios-task-notes.json'),
    refusal: text => require('./memory.cjs').refusal(text),
  });
};

exports.install = function install(home) {
  const notes = exports.forHome(home);
  const hook = Symbol.for('dsh.ios.memoryTool');
  const previous = globalThis[hook];
  globalThis[hook] = (ctx, defineTool) => {
    previous?.(ctx, defineTool);
    notes.register(ctx, defineTool);
  };
  return notes;
};
