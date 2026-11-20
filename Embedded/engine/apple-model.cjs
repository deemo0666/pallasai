// The native host can name a conversation with the on-device Apple model. An empty response
// leaves title generation to the configured chat model. The iOS host also uses the same pipe
// for one-line notification summaries and records summaries and phone-step checks in the log.
const { randomUUID } = require('node:crypto');

const RECORD = 'plugin:pallas/apple-model';

exports.bridge = function bridge(send, { cancellable = false } = {}) {
  const pending = new Map();
  /** Set once the host says this device has no model, so later requests skip the round trip. */
  let absent = false;
  /** Resolves to the value and the seconds the host reports, or undefined. */
  function ask(task, system, input, signal, limit = 15000) {
    if (absent || signal?.aborted) return Promise.resolve(undefined);
    const id = randomUUID();
    return new Promise(resolve => {
      const timer = setTimeout(abort, limit);
      function abort() {
        finish(undefined);
        if (cancellable) {
          try { send({ appleModelCancel: id }); } catch {}
        }
      }
      function finish(value) {
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        pending.delete(id);
        resolve(value);
      }
      pending.set(id, finish);
      signal?.addEventListener('abort', abort, {once: true});
      try {
        send({ appleModelRequest: id, ...(task ? { task } : {}), system: String(system), input: String(input) });
      } catch {
        finish(undefined);
      }
    });
  }
  // The title provider patch is shared with the iOS runtime.
  globalThis[Symbol.for('dsh.ios.appleModel')] = (system, input, signal) =>
    ask(undefined, system, input, signal).then(answer => answer?.value);

  function receive(reply) {
    if (typeof reply?.appleModelReply !== 'string') return;
    const finish = pending.get(reply.appleModelReply);
    if (!finish) return;
    if (reply.absent === 'true') absent = true;
    const value = typeof reply.value === 'string' && reply.value.trim() ? reply.value : undefined;
    const seconds = Number(reply.seconds);
    finish(value === undefined ? undefined : { value, seconds: Number.isFinite(seconds) ? seconds : undefined });
  }

  function close() {
    absent = true;
    for (const finish of pending.values()) finish(undefined);
  }

  return { ask, receive, close };
};

exports.install = function install(send) {
  const { ask, receive } = exports.bridge(send);

  let sessionLib;
  /** Appends one record to a session's log; a log that cannot take it now goes without. */
  function record(session, data) {
    if (!session) return;
    sessionLib ??= import('@deepseek-ai/dsh-session');
    sessionLib.then(lib => {
      try { lib.appendPluginRecord(session, RECORD, { provider: 'apple', model: 'on-device', ...data }); } catch {}
    }, () => {});
  }
  // The host's notes on phone steps arrive with its replies to the phone tools.
  globalThis[Symbol.for('dsh.ios.appleModelRecord')] = (session, json) => {
    let rows;
    try { rows = JSON.parse(json); } catch { return; }
    if (Array.isArray(rows)) for (const row of rows) if (row && typeof row === 'object') record(session, row);
  };

  // A finished turn's reply, in one line, for the notification that says it is done.
  const replies = new Map();
  let attached = false;
  globalThis[Symbol.for('dsh.ios.appleModelContext')] = ctx => {
    if (attached) return;
    attached = true;
    ctx.on('session/event', (session, event) => {
      // Subagents' turns end inside the person's turn; only the conversation itself is summed up.
      if (session?.header?.parentSession !== undefined) return;
      if (event.type === 'assistant/message') {
        const text = (event.data?.message?.content ?? []).filter(block => block?.type === 'text').map(block => block.text).join('\n').trim();
        if (text) replies.set(session.id, { turn: event.data.turn, text });
      } else if (event.type === 'turn/end') {
        const reply = replies.get(session.id);
        replies.delete(session.id);
        if (event.data?.reason?.kind !== 'completed' || !reply || reply.turn !== event.data.turn) return;
        ask('summary', '', reply.text, undefined, 10000).then(answer => {
          if (!answer?.value) return;
          send({ appleModelSummary: session.id, value: answer.value });
          record(session, { task: 'summary', turn: event.data.turn, seconds: answer.seconds, characters: [...answer.value].length });
        });
      }
    });
  };

  return line => { if (line.startsWith('{')) receive(JSON.parse(line)); };
};
