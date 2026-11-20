// Dreaming: a pass that reads the conversations since the last pass and the two memory files, and
// has the default chat model write both files again — duplicates merged, the newer of two
// contradicting entries kept, past plans moved to the past or dropped, lasting facts that were
// never written down added.
//
// Safety: the answer goes to temporary files first and replaces the real ones only after the
// limits and the refusal checks pass; a failed pass changes nothing. Before every replacement the
// current files are kept in memories/backup, which 「恢复上一版」 puts back. memories/state.json
// remembers how far the passes have read.
//
// The native host asks for a pass over the command pipe: {"memoryDream": "<id>", "mode": "auto"}
// when the app comes to the front (switch on, a day since the last pass), "now" for 立即整理,
// "restore" for 恢复上一版. The engine answers {"memoryDreamReply": "<id>", "status": …}.
const fs = require('node:fs');
const path = require('node:path');
const memory = require('./memory.cjs');
const P = require('./prompts/dream.cjs');

/** Bytes of conversation one pass reads; what does not fit waits for the next pass. */
const BUDGET = 48 * 1024;
/** Room for both files (about 3,600 characters, up to one token each) and a little reasoning. */
const OUTPUT_TOKENS = 6000;
/** Characters kept from one message. */
const MESSAGE_CAP = 1600;

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function clip(text, cap = MESSAGE_CAP) {
  const chars = Array.from(text.trim());
  return chars.length > cap ? chars.slice(0, cap).join('') + '…' : chars.join('');
}

function textOf(content) {
  return (Array.isArray(content) ? content : []).filter(part => part?.type === 'text').map(part => part.text).join('').trim();
}

/** The person's messages and the assistant's last reply of each turn, after [after] (ms). */
function excerpt(events, after = 0) {
  const lines = [];
  const finals = new Map();
  for (const event of events) {
    if (event.time !== undefined && event.time <= after) continue;
    const data = event.data ?? {};
    if (event.type === 'user/message' && ['user', 'user-rpc'].includes(data.source?.kind)) {
      const text = textOf(data.content);
      if (text) lines.push({ seq: event.seq, text: `User: ${clip(text)}` });
    } else if (event.type === 'assistant/message') {
      const text = textOf(data.message?.content);
      if (text) finals.set(data.turn ?? event.seq, { seq: event.seq, text: `Assistant: ${clip(text)}` });
    }
  }
  return [...lines, ...finals.values()].sort((a, b) => a.seq - b.seq).map(line => line.text);
}

function day(ms) {
  return memory.today(new Date(ms));
}

const SYSTEM = P.system(memory.TARGETS);

class Dreamer {
  constructor(store, home, { now = () => Date.now() } = {}) {
    this.store = store;
    this.home = home;
    this.now = now;
    this.stateFile = path.join(store.dir, 'state.json');
    this.backupDir = path.join(store.dir, 'backup');
    this.running = undefined;
  }

  state() {
    return readJSON(this.stateFile, undefined);
  }

  saveState(state) {
    memory.writeAtomic(this.stateFile, JSON.stringify(state));
  }

  /** The first time memory runs, passes start from now: older conversations are not reviewed. */
  ensureState() {
    if (this.state()) return;
    try { this.saveState({ since: this.now(), seen: {} }); } catch {}
  }

  /** Session logs written to since the last pass, oldest first. */
  changedSessions(state) {
    const root = path.join(this.home, 'sessions');
    const since = state.since ?? 0;
    const found = [];
    let places = [];
    try { places = fs.readdirSync(root); } catch { return found; }
    for (const place of places) {
      let ids = [];
      try { ids = fs.readdirSync(path.join(root, place)); } catch { continue; }
      for (const id of ids) {
        if (!id.startsWith('session-')) continue;
        let mtime = 0;
        try {
          for (const name of fs.readdirSync(path.join(root, place, id))) {
            if (name.startsWith('session.')) mtime = Math.max(mtime, fs.statSync(path.join(root, place, id, name)).mtimeMs);
          }
        } catch { continue; }
        const after = Math.max(since, state.seen?.[id] ?? 0);
        if (mtime > after) found.push({ id, mtime, after });
      }
    }
    return found.sort((a, b) => a.mtime - b.mtime);
  }

  /** Conversation text for one pass, within the budget, and the state to save if the pass succeeds. */
  async gather(sessionQuery, state) {
    const parts = [];
    const seen = { ...(state.seen ?? {}) };
    let used = 0;
    let through = state.through ?? state.since ?? 0;
    let left = 0;
    const changed = this.changedSessions(state);
    for (const [index, candidate] of changed.entries()) {
      let read;
      try { read = await sessionQuery.readSession(candidate.id); } catch { continue; }
      if (read.session?.parentSession) { seen[candidate.id] = candidate.mtime; continue; }
      const lastTime = read.events.at(-1)?.time ?? candidate.mtime;
      const lines = excerpt(read.events, candidate.after);
      if (lines.length === 0) { seen[candidate.id] = Math.max(candidate.mtime, lastTime); continue; }
      let text = `## Conversation of ${day(lastTime)}\n${lines.join('\n')}`;
      const bytes = Buffer.byteLength(text);
      if (used + bytes > BUDGET) {
        if (parts.length > 0) { left = changed.length - index; break; }
        text = Buffer.from(text).subarray(0, BUDGET).toString('utf8').replace(/�$/, '') + '\n…';
      }
      parts.push(text);
      used += Buffer.byteLength(text);
      seen[candidate.id] = Math.max(candidate.mtime, lastTime);
      through = Math.max(through, lastTime);
    }
    return { transcript: parts.join('\n\n'), conversations: parts.length, left, next: { ...state, seen, through } };
  }

  /** The two files from the model's answer, or a reason they cannot be used. */
  parseAnswer(answer) {
    const pick = tag => {
      const match = new RegExp(`<${tag}>\\n?([\\s\\S]*?)</${tag}>`, 'i').exec(answer);
      return match ? match[1] : undefined;
    };
    const files = { user: pick('user'), memory: pick('memory') };
    if (files.user === undefined || files.memory === undefined) return { error: 'answer_format' };
    for (const target of ['user', 'memory']) {
      const why = memory.refusalOfFile(files[target], target);
      if (why) return { error: 'refused', detail: why };
      files[target] = memory.serialize(memory.parse(files[target]));
    }
    return { files };
  }

  /** Writes both files: temporary copies, then the backup, then the replacement. */
  replace(files) {
    const temps = {};
    for (const target of ['user', 'memory']) {
      const temp = this.store.file(target) + '.dream';
      memory.writeAtomic(temp, files[target]);
      // Read back what landed on disk and check it again before anything is replaced.
      const why = memory.refusalOfFile(fs.readFileSync(temp, 'utf8'), target);
      if (why) { for (const t of Object.values(temps)) fs.rmSync(t, { force: true }); fs.rmSync(temp, { force: true }); throw new Error(why); }
      temps[target] = temp;
    }
    fs.mkdirSync(this.backupDir, { recursive: true, mode: 0o700 });
    for (const target of ['user', 'memory']) {
      const current = this.store.file(target);
      memory.writeAtomic(path.join(this.backupDir, memory.TARGETS[target].file), fs.existsSync(current) ? fs.readFileSync(current, 'utf8') : '');
    }
    for (const target of ['user', 'memory']) fs.renameSync(temps[target], this.store.file(target));
  }

  /** Puts back the files as they were before the last pass. */
  restore() {
    const files = {};
    for (const target of ['user', 'memory']) {
      const backup = path.join(this.backupDir, memory.TARGETS[target].file);
      if (!fs.existsSync(backup)) return { status: 'skipped', reason: 'no_backup' };
      files[target] = fs.readFileSync(backup, 'utf8');
    }
    for (const target of ['user', 'memory']) memory.writeAtomic(this.store.file(target), files[target]);
    for (const target of ['user', 'memory']) fs.rmSync(path.join(this.backupDir, memory.TARGETS[target].file), { force: true });
    const state = this.state() ?? {};
    this.saveState({ ...state, restoredAt: this.now() });
    return { status: 'restored' };
  }

  /**
   * One pass. [services]: { sessionQuery, agents, complete(system, input, signal) → text }.
   * mode "auto" needs new conversations and nobody else working; "now" runs on what there is.
   */
  async run(mode, services, signal) {
    if (this.running) return { status: 'skipped', reason: 'already_running' };
    this.running = this.pass(mode, services, signal).finally(() => { this.running = undefined; });
    return this.running;
  }

  async pass(mode, { sessionQuery, agents, complete }, signal) {
    const started = this.now();
    if (!this.store.settings().enabled) return { status: 'skipped', reason: 'memory_off' };
    if (mode === 'auto' && !this.store.settings().autoDream) return { status: 'skipped', reason: 'auto_off' };
    if (agents?.list().some(agent => agent.status === 'running')) return { status: 'skipped', reason: 'busy' };
    if (!sessionQuery || !complete) return { status: 'failed', reason: 'engine_not_ready' };
    this.ensureState();
    const state = this.state() ?? { since: this.now(), seen: {} };
    const gathered = await this.gather(sessionQuery, state);
    if (signal?.aborted) return this.failed(state, 'aborted');
    if (mode === 'auto' && gathered.conversations === 0) {
      this.saveState({ ...gathered.next, lastCheckAt: this.now() });
      return { status: 'skipped', reason: 'no_new_conversations' };
    }
    const today = memory.today(new Date(this.now()));
    const current = target => this.store.entries(target).join(memory.SEPARATOR);
    const before = { user: current('user'), memory: current('memory') };
    const input = P.input({ today, ...before, transcript: gathered.transcript });
    let answer;
    try {
      answer = await complete(SYSTEM, input, signal);
    } catch (error) {
      return this.failed(state, 'model_failed', String(error?.code ?? error?.message ?? error).slice(0, 120));
    }
    if (signal?.aborted) return this.failed(state, 'aborted');
    const settings = this.store.settings();
    if (!settings.enabled) return { status: 'skipped', reason: 'memory_off' };
    if (mode === 'auto' && !settings.autoDream) return { status: 'skipped', reason: 'auto_off' };
    if (Object.entries(before).some(([target, text]) => current(target) !== text)) {
      return this.failed(state, 'memory_changed');
    }
    const parsed = this.parseAnswer(String(answer ?? ''));
    if (parsed.error) return this.failed(state, parsed.error, parsed.detail);
    try {
      this.replace(parsed.files);
    } catch (error) {
      return this.failed(state, 'write_failed', String(error?.message ?? error).slice(0, 120));
    }
    this.saveState({ ...gathered.next, lastRunAt: this.now(), lastResult: 'done', lastError: undefined, lastDurationMs: this.now() - started });
    return { status: 'done', conversations: gathered.conversations, left: gathered.left };
  }

  failed(state, reason, detail) {
    try { this.saveState({ ...state, lastFailedAt: this.now(), lastResult: 'failed', lastError: reason }); } catch {}
    return { status: 'failed', reason, ...(detail ? { detail } : {}) };
  }
}

/** A model call on the default chat model, as the title plugin makes its own. */
function completer(ctx, { maxTokens = OUTPUT_TOKENS, purpose = 'memory-dream' } = {}) {
  return async (system, input, signal) => {
    const llm = ctx.get('llm');
    const selection = ctx.get('agentDefaultModel')?.currentSelection();
    if (!llm || !selection?.provider || !selection?.model) throw Object.assign(new Error('no default model'), { code: 'no_model' });
    const { BlockAssembler, createUserMessage } = await import('@deepseek-ai/dsh-llm');
    // Both files together are at most about 3,600 characters; the least reasoning the route offers
    // is enough to sort them, as the title plugin does for its own call.
    const call = await llm.prepareCall({ provider: selection.provider, model: selection.model, maxTokens }, signal,
      (controls, model) => {
        const effort = model.reasoning?.efforts[0]?.id;
        return effort === undefined ? controls : { ...controls, reasoningEffort: effort };
      });
    const assembler = new BlockAssembler();
    const messages = [createUserMessage({ content: [{ type: 'text', text: input }], source: { kind: `dsh-local-${purpose}` } })];
    for await (const chunk of call.stream({ ...call.config, messages, system, purpose, signal })) assembler.push(chunk);
    const finish = assembler.finish;
    if (finish?.kind === 'error' || finish?.kind === 'aborted') throw Object.assign(new Error(finish.failure?.message ?? finish.kind), { code: finish.failure?.code ?? finish.kind });
    return assembler.blocks().filter(block => block.type === 'text').map(block => block.text).join('');
  };
}

exports.install = function install(send, store, home) {
  const dreamer = new Dreamer(store, home);
  dreamer.ensureState();
  let ctx;
  const running = new Set();
  const attach = value => { ctx = value; };
  const abort = () => { for (const controller of running) controller.abort(); };
  const receive = order => {
    // The new conversation's examples, when the device has no on-device model: one short call on
    // the default chat model. The host checks what comes back; an empty value keeps its own.
    if (typeof order?.starterIdeas === 'string') {
      const id = order.starterIdeas;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 30000);
      Promise.resolve()
        .then(() => {
          if (!ctx) throw new Error('engine not ready');
          return completer(ctx, { maxTokens: 800, purpose: 'starter-ideas' })(String(order.system ?? ''), String(order.input ?? ''), controller.signal);
        })
        .then(value => value, () => '')
        .then(value => { clearTimeout(timer); send({ starterIdeasReply: id, value: String(value ?? '') }); });
      return;
    }
    if (typeof order?.memoryDream !== 'string') return;
    const id = order.memoryDream;
    const answer = result => send({ memoryDreamReply: id, ...Object.fromEntries(Object.entries(result).map(([k, v]) => [k, String(v)])) });
    if (order.mode === 'abort') {
      abort();
      answer({ status: 'aborted' });
      return;
    }
    if (order.mode === 'restore') {
      if (dreamer.running) { answer({ status: 'skipped', reason: 'already_running' }); return; }
      try { answer(dreamer.restore()); } catch (error) { answer({ status: 'failed', reason: 'restore_failed' }); }
      return;
    }
    const controller = new AbortController();
    running.add(controller);
    const timer = setTimeout(() => controller.abort(), 180000);
    dreamer.run(order.mode === 'now' ? 'now' : 'auto', {
      sessionQuery: ctx?.get('sessionQuery'),
      agents: ctx?.get('agents'),
      complete: ctx ? completer(ctx) : undefined,
    }, controller.signal)
      .catch(error => ({ status: 'failed', reason: 'error', detail: String(error?.message ?? error).slice(0, 120) }))
      .then(result => { clearTimeout(timer); running.delete(controller); answer(result); });
  };
  const reply = line => {
    if (!line.startsWith('{')) return;
    let order;
    try { order = JSON.parse(line); } catch { return; }
    receive(order);
  };
  return { attach, reply, receive, abort, dreamer };
};

Object.assign(exports, { Dreamer, excerpt, SYSTEM, BUDGET });
