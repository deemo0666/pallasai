// Persistent memory for the embedded engine: two small files under DSH_HOME/memories that the model
// writes with the `memory` tool and that every new conversation reads once, at its start.
//   USER.md    what the model knows about the person      (1,375 characters at most)
//   MEMORY.md  notes the model keeps for itself            (2,200 characters at most)
// Entries are separated by a line holding only 「§」 and start with the day they were written:
// 「[2026-11-12] 回复尽量简短」. Characters are counted as Unicode code points, the same on the
// Swift side (unicodeScalars). The memory page in the app reads and writes the same files.
//
// A conversation sees the files as they were when it began: writes made during it land on disk
// and reach the prompt of the next conversation, so the prompt (and its cache) does not change
// under a running conversation. The snapshot of each conversation is kept in snapshots.json so a
// conversation picked up again after the app was closed still sees the same text.
const fs = require('node:fs');
const path = require('node:path');
const P = require('./prompts/memory.cjs');

const SEPARATOR = '\n§\n';
const TARGETS = {
  user: { file: 'USER.md', limit: 1375, title: 'USER PROFILE' },
  memory: { file: 'MEMORY.md', limit: 2200, title: 'MEMORY' },
};
const SNAPSHOT_KEEP = 64;

/** Code points, as the limits count them. */
function length(text) {
  let count = 0;
  for (const _ of text) count++;
  return count;
}

function today(now = new Date()) {
  const pad = n => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/** Entries of one file's text, each as written (date prefix included). */
function parse(text) {
  return String(text ?? '').replace(/\r\n/g, '\n').split(/\n[ \t]*§[ \t]*\n/)
    .map(entry => entry.trim()).filter(entry => entry.length > 0 && entry !== '§');
}

function serialize(entries) {
  return entries.length ? entries.join(SEPARATOR) + '\n' : '';
}

/** The text an entry holds, without its date. */
function body(entry) {
  return entry.replace(/^\[\d{4}-\d{2}-\d{2}\]\s*/, '');
}

/** What the limit counts: the entries and the separators between them, not the final newline. */
function used(entries) {
  return length(entries.join(SEPARATOR));
}

// Characters that do not show on screen and can hide text from the person reading the memory page.
const INVISIBLE = /[­᠎​-‏‪-‮⁠-⁤⁦-⁯﻿￹-￻]|[\u{E0000}-\u{E007F}]/u;
const INJECTION = [
  /\b(ignore|disregard|forget|override)\b[^\n]{0,40}\b(previous|prior|above|earlier|all|any|system)\b[^\n]{0,20}\b(instructions?|prompts?|rules?|messages?)\b/i,
  /\b(you are now|from now on you are|act as (the )?system|new system prompt|system prompt override)\b/i,
  /<\/?\s*(system|assistant|developer|tool_call|im_start|im_end)\b[^>]*>/i,
  /^\s*(system|assistant|developer)\s*[:：]/im,
  /(忽略|无视|忘掉|忘记|覆盖)[^\n]{0,12}(之前|以上|前面|先前|所有|全部|系统)[^\n]{0,8}(的)?(指令|指示|提示词?|规则|设定)/,
  /(新的?|更新的?)系统(提示词?|指令)|你现在是一个?(没有|不受)/,
];
const SECRET = [
  /\bsk-(ant-|proj-)?[A-Za-z0-9_-]{16,}/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /\bgh[pousr]_[A-Za-z0-9]{20,}/,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/,
  /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
  /\bAIza[0-9A-Za-z_-]{30,}/,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\./,
  /\b(api[ _-]?key|secret|token|password|passwd|bearer)\b\s*[:=：]?\s*['"]?[A-Za-z0-9+/_.=-]{8,}/i,
  /(密码|口令|密钥|验证码|私钥)\s*(是|为)?\s*[:=：]?\s*[A-Za-z0-9+/_.=!@#$%^&*-]{4,}/,
  /(?<![A-Za-z0-9+_-])(?=[A-Za-z0-9+_-]*\d)(?=[A-Za-z0-9+_-]*[A-Za-z])[A-Za-z0-9+_-]{40,}/,
];

/** Why [text] must not be stored, or undefined when it may. */
function refusal(text) {
  if (INVISIBLE.test(text)) return 'contains invisible Unicode characters';
  if (text.includes('§')) return 'contains the entry separator §';
  if (INJECTION.some(pattern => pattern.test(text))) return 'looks like an instruction aimed at the assistant (prompt injection)';
  if (SECRET.some(pattern => pattern.test(text))) return 'looks like a password, key or token; never store secrets';
  return undefined;
}

/** The whole text of a file the app or the dreaming pass wants to write: every entry must pass. */
function refusalOfFile(text, target) {
  const spec = TARGETS[target];
  const entries = parse(text);
  for (const entry of entries) {
    const why = refusal(body(entry));
    if (why) return `${spec.title} entry ${why}`;
  }
  const count = used(entries);
  if (count > spec.limit) return `${spec.title} is ${count}/${spec.limit} chars`;
  return undefined;
}

function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = `${file}.${process.pid}.${Date.now()}.tmp`;
  const fd = fs.openSync(temp, 'w', 0o600);
  try {
    fs.writeSync(fd, text);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temp, file);
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch { return ''; }
}

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function grouped(n) {
  return n.toLocaleString('en-US');
}

/** The memory files of one engine home. */
class MemoryStore {
  constructor(home, { now = () => new Date() } = {}) {
    this.dir = path.join(home, 'memories');
    this.now = now;
  }

  file(target) { return path.join(this.dir, TARGETS[target].file); }

  entries(target) { return parse(readText(this.file(target))); }

  settings() {
    const value = readJSON(path.join(this.dir, 'settings.json'), {});
    return { enabled: value.enabled !== false, autoDream: value.autoDream !== false };
  }

  write(target, entries) { writeAtomic(this.file(target), serialize(entries)); }

  header(target, entries) {
    const spec = TARGETS[target];
    const count = used(entries);
    return `${spec.title} [${Math.round(count / spec.limit * 100)}% — ${grouped(count)}/${grouped(spec.limit)} chars]`;
  }

  /** Runs one tool call; returns the text the model reads, throws for a refused call. */
  apply(args) {
    const target = args?.target;
    const spec = TARGETS[target];
    if (!spec) throw new Error('target must be "user" or "memory"');
    const action = args.action;
    const entries = this.entries(target);
    const content = typeof args.content === 'string' ? args.content.trim() : '';
    const needle = typeof args.old_text === 'string' ? args.old_text.trim() : '';
    if (action === 'add' || action === 'patch') {
      if (!content) throw new Error('content is required');
      const why = refusal(content);
      if (why) throw new Error(`refused: content ${why}`);
    }
    let next;
    if (action === 'add') {
      if (entries.some(entry => body(entry) === content)) return `Already in ${spec.title}; nothing written.\n${this.header(target, entries)}`;
      next = [...entries, `[${today(this.now())}] ${content}`];
    } else if (action === 'patch' || action === 'remove') {
      if (!needle) throw new Error('old_text is required: a short unique piece of the entry to change');
      const index = this.locate(entries, needle);
      if (action === 'remove') next = entries.toSpliced(index, 1);
      else {
        if (entries.some((entry, i) => i !== index && body(entry) === content)) throw new Error('another entry already says exactly this; remove this one instead');
        next = entries.toSpliced(index, 1, `[${today(this.now())}] ${content}`);
      }
    } else {
      throw new Error('action must be add, patch or remove');
    }
    const count = used(next);
    if (count > spec.limit) {
      throw new Error(`${spec.title} would be ${grouped(count)}/${grouped(spec.limit)} chars. Free at least ${grouped(count - spec.limit)} chars first: remove outdated entries or patch long ones shorter, then retry. Nothing was written.`);
    }
    this.write(target, next);
    const verb = { add: 'Added to', patch: 'Updated in', remove: 'Removed from' }[action];
    return `${verb} ${spec.title}. Takes effect from the next conversation.\n${this.header(target, next)}`;
  }

  /** The one entry [needle] picks out; throws when none or several do. */
  locate(entries, needle) {
    let index = -1;
    let hits = 0;
    entries.forEach((entry, i) => {
      for (let at = entry.indexOf(needle); at >= 0; at = entry.indexOf(needle, at + 1)) {
        hits++;
        index = i;
      }
    });
    if (hits === 0) throw new Error(`no entry contains "${needle}"`);
    if (hits > 1) throw new Error(`"${needle}" matches ${hits} places; quote a longer piece that appears only once`);
    return index;
  }

  /** The two files as the prompt shows them. */
  render() {
    return ['user', 'memory'].map(target => {
      const entries = this.entries(target);
      return `${this.header(target, entries)}\n${entries.length ? entries.join(SEPARATOR) : '(empty)'}`;
    }).join('\n\n');
  }

  /** The text a conversation sees: taken on its first step, the same on every later one. */
  snapshot(id) {
    const file = path.join(this.dir, 'snapshots.json');
    if (!this.cache) this.cache = readJSON(file, {});
    const kept = this.cache[id];
    if (typeof kept?.text === 'string') return kept.text;
    const text = this.render();
    if (id === undefined) return text;
    this.cache[id] = { at: Date.now(), text };
    const ids = Object.keys(this.cache).sort((a, b) => (this.cache[b].at ?? 0) - (this.cache[a].at ?? 0));
    for (const old of ids.slice(SNAPSHOT_KEEP)) delete this.cache[old];
    try { writeAtomic(file, JSON.stringify(this.cache)); } catch {}
    return text;
  }
}

const RULES = P.rules;

const SEARCH_RULE = P.searchRule;

/** The section the model reads; empty when memory is switched off. */
function promptSection(store, id, search = false) {
  if (!store.settings().enabled) return '';
  return `${RULES}${search ? `\n\n${SEARCH_RULE}` : ''}\n\n${store.snapshot(id)}`;
}

// The history index is built on its first search, from every conversation on the phone (about
// 2.4 s for 570 of them on an iPhone). Build it in the background as soon as the engine is up and
// has been quiet for a few seconds, so the model's first session_search only reads what changed.
// Wait for the first turn to end: a build that overlaps a turn sees that conversation's log change
// between its two listings and starts over (about 160 s instead of 80 s on a fresh install).
let warmed = false;
function warmSearch(ctx) {
  if (warmed) return;
  warmed = true;
  let tries = 0;
  let quiet = 0;
  let turned = false;
  const attempt = () => {
    const query = ctx.get?.('sessionQuery');
    const busy = ctx.get?.('agents')?.list?.().some(agent => agent.status === 'running');
    if (busy) turned = true;
    quiet = busy ? 0 : quiet + 1;
    // Without a turn seen, wait a full minute of quiet so a turn that is just starting goes first.
    if ((!query || quiet < (turned ? 5 : 60)) && ++tries < 900) return setTimeout(attempt, 1000).unref?.();
    if (!query) return;
    query.searchSessions?.({ query: 'dsh', sessionFilters: [], eventFilters: [] })?.catch?.(() => {});
  };
  setTimeout(attempt, 1000).unref?.();
}

exports.create = function create(send, home = process.env.DSH_HOME, { phone = false } = {}) {
  const store = new MemoryStore(home);
  const dreaming = require('./dream.cjs').install(send, store, home);
  function register(ctx, defineTool) {
    dreaming.attach(ctx);
    warmSearch(ctx);
    if (phone) {
      require('./web-search.cjs').attach(ctx);
      ctx.systemPrompt.section({
        name: 'ios:surface',
        order: ctx.systemPrompt.getSectionOrder('FILE_REFERENCE') + 40,
        text: () => require('./prompts/surface.cjs').system,
        interpolate: false,
      });
    }
    ctx.systemPrompt.section({
      name: phone ? 'ios:memory' : 'pallas:memory',
      order: ctx.systemPrompt.getSectionOrder('FILE_REFERENCE') + 50,
      text: ({scope}) => promptSection(store, scope?.id, ctx.tools.get('session_search', scope) !== undefined),
      interpolate: false,
    });
    ctx.tools.register(defineTool({
      name: 'memory',
      description: P.description,
      parameters: {
        action: { type: 'string', required: true, enum: ['add', 'patch', 'remove'], description: P.params.action },
        target: { type: 'string', required: true, enum: ['user', 'memory'], description: P.params.target },
        content: { type: 'string', description: P.params.content },
        old_text: { type: 'string', description: P.params.old_text },
      },
      output: { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] },
      async execute(args) {
        return store.apply(args);
      },
    }), { when: () => store.settings().enabled });
  }
  return { store, register, dreaming };
};

exports.install = function install(send, home) {
  const { store, register, dreaming } = exports.create(send, home, { phone: true });
  exports.store = store;
  exports.dreaming = dreaming;
  globalThis[Symbol.for('dsh.ios.memoryTool')] = register;
  return dreaming.reply;
};

Object.assign(exports, { MemoryStore, TARGETS, parse, serialize, body, used, length, refusal, refusalOfFile, writeAtomic, promptSection, today, SEPARATOR });
