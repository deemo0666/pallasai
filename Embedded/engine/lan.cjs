// The lan_services tool. The app does the Bonjour work with Network.framework (App/LanServices.swift)
// and answers with the JSON the model reads; only the tool arguments and that answer cross the pipes.
const { randomUUID } = require('node:crypto');
const P = require('./prompts/lan.cjs');
const { approvalPolicy } = require('./mac-host.cjs');

exports.bridge = function bridge(send, { desktop = false } = {}) {
  const pending = new Map();
  function register(ctx, defineTool) {
    ctx.systemPrompt.section({
      name: 'tool:lan_services',
      order: ctx.systemPrompt.getSectionOrder('TOOL_READ'),
      text: ({scope}) => ctx.tools.get('lan_services', scope) ? (desktop ? P.desktop : P.system) : '',
    });
    ctx.tools.register(defineTool({
      name: 'lan_services',
      description: desktop ? P.desktopDescription : P.description,
      parameters: {
        action: { type: 'string', required: true, enum: ['types', 'browse', 'resolve', 'connect', 'advertise', 'list', 'stop'], description: P.params.action },
        type: { type: 'string', description: P.params.type },
        name: { type: 'string', description: P.params.name },
        domain: { type: 'string', description: P.params.domain },
        host: { type: 'string', description: P.params.host },
        port: { type: 'integer', description: desktop ? P.desktopPort : P.params.port },
        txt: { type: 'array', items: { type: 'string' }, description: P.params.txt },
        timeout: { type: 'number', description: P.params.timeout },
        p2p_only: { type: 'boolean', description: P.params.p2p_only },
        category: { type: 'string', description: P.params.category },
        id: { type: 'string', description: P.params.id },
        all: { type: 'boolean', description: P.params.all },
      },
      output: { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] },
      async execute(args, exec) {
        const id = randomUUID();
        exec.signal?.throwIfAborted();
        // Models fill unused fields with blanks ("", 0, false, []); the app reads an absent field as
        // "not given". No field means anything with 0 or false: ports and timeouts start at 1, flags default off.
        const clean = {};
        for (const [key, value] of Object.entries(args ?? {})) {
          if (value === '' || value === 0 || value === false || value === null || value === undefined) continue;
          if (Array.isArray(value) && !value.length) continue;
          clean[key] = value;
        }
        return new Promise((resolve, reject) => {
          const publishing = desktop && clean.action === 'advertise';
          const abort = () => cancel('lan_request_cancelled');
          // Above the longest browse (60 s) plus a connection.
          // Desktop publishing can also ask the person to approve it.
          const limit = publishing ? 150000 : 75000;
          const timer = setTimeout(() => cancel(`internal_error: the app did not answer within ${limit / 1000} seconds`), limit);
          function cancel(reason) {
            if (desktop) {
              try { send({ lanCancel: id }); } catch {}
            }
            finish(new Error(reason));
          }
          function finish(error, value) {
            if (!pending.delete(id)) return;
            clearTimeout(timer);
            exec.signal?.removeEventListener('abort', abort);
            if (error) reject(error); else resolve(value);
          }
          pending.set(id, finish);
          exec.signal?.addEventListener('abort', abort, {once: true});
          try {
            send({ lanRequest: id, args: clean, ...(publishing ? { approval: approvalPolicy(exec.agent?.session) } : {}) });
          } catch (error) { finish(error); }
        });
      }
    }));
  }
  function receive(reply) {
    if (typeof reply?.lanReply !== 'string') return;
    pending.get(reply.lanReply)?.(reply.error ? new Error(reply.error) : null, String(reply.value ?? ''));
  }
  function close() {
    for (const finish of pending.values()) finish(new Error('Pallas connection closed.'));
  }
  return { register, receive, close };
};

exports.install = function install(send) {
  const { register, receive } = exports.bridge(send);
  globalThis[Symbol.for('dsh.ios.lanTool')] = register;
  return line => {
    if (line.startsWith('{')) receive(JSON.parse(line));
  };
};
