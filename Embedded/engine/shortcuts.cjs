// The run_shortcut tool. The native app runs the named shortcut and replies over the engine pipe.
const { randomUUID } = require('node:crypto');
const P = require('./prompts/shortcuts.cjs');
const { approvalPolicy } = require('./mac-host.cjs');

// The engine build calls a fixed set of registration hooks (Embedded/patches); this tool rides on
// the lan_services one, so install() must run after lan.cjs's.
const HOOK = Symbol.for('dsh.ios.lanTool');
// A shortcut may ask the person questions or wait on another app; past this the app answers anyway.
const LIMIT_MS = 11 * 60 * 1000;

exports.bridge = function bridge(send, { desktop = false } = {}) {
  const pending = new Map();
  const limit = LIMIT_MS + (desktop ? 2 * 60 * 1000 : 0); // The Mac can also wait for native approval.
  function register(ctx, defineTool) {
    ctx.systemPrompt.section({
      name: 'tool:run_shortcut',
      order: ctx.systemPrompt.getSectionOrder('TOOL_READ'),
      text: ({scope}) => ctx.tools.get('run_shortcut', scope) ? (desktop ? P.desktop : P.system) : '',
    });
    ctx.tools.register(defineTool({
      name: 'run_shortcut',
      description: desktop ? P.desktopDescription : P.description,
      parameters: {
        name: { type: 'string', required: true, description: P.params.name },
        input: { type: 'string', description: P.params.input },
      },
      output: { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] },
      async execute(args, exec) {
        const id = randomUUID();
        exec.signal?.throwIfAborted();
        const name = String(args?.name ?? '').trim();
        const input = typeof args?.input === 'string' && args.input !== '' ? args.input : undefined;
        if (desktop && (Buffer.byteLength(name) > 4096 || Buffer.byteLength(input ?? '') > 256 * 1024)) {
          return JSON.stringify({ tool: 'run_shortcut', ok: false, timestamp: new Date().toISOString(),
            error: { code: 'invalid_args', message: 'The shortcut name or input is too long.' } });
        }
        return new Promise((resolve, reject) => {
          const abort = () => cancel('shortcut_request_cancelled');
          const timer = setTimeout(() => cancel('internal_error: the app did not answer in time'), limit);
          function cancel(code) {
            try { send({ shortcutCancel: id }); } catch {}
            finish(new Error(code));
          }
          function finish(error, value) {
            clearTimeout(timer);
            exec.signal?.removeEventListener('abort', abort);
            pending.delete(id);
            if (error) reject(error); else resolve(value);
          }
          pending.set(id, finish);
          exec.signal?.addEventListener('abort', abort, {once: true});
          try {
            send({ shortcutRequest: id, args: input === undefined ? { name } : { name, input },
              ...(desktop ? { approval: approvalPolicy(exec.agent?.session) } : {}) });
          } catch (error) { finish(error); }
        });
      }
    }));
  }
  function receive(reply) {
    if (typeof reply?.shortcutReply !== 'string') return;
    pending.get(reply.shortcutReply)?.(reply.error ? new Error(reply.error) : null, String(reply.value ?? ''));
  }
  return { register, receive };
};

exports.install = function install(send) {
  const { register, receive } = exports.bridge(send);
  const previous = globalThis[HOOK];
  globalThis[HOOK] = (ctx, defineTool) => {
    previous?.(ctx, defineTool);
    register(ctx, defineTool);
  };
  return line => { if (line.startsWith('{')) receive(JSON.parse(line)); };
};
