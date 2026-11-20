// The native app handles EventKit, Contacts and message drafts and replies over the engine pipe.
const { randomUUID } = require('node:crypto');
const P = require('./prompts/apple-data.cjs');
const { approvalPolicy } = require('./mac-host.cjs');

// The engine build calls a fixed set of registration hooks (Embedded/patches); these tools ride on
// the lan_services one, so install() must run after lan.cjs's.
const HOOK = Symbol.for('dsh.ios.lanTool');

// Models fill unused fields with blanks ("", 0, false, []); the app reads an absent field as "not given".
function clean(args) {
  const out = {};
  for (const [key, value] of Object.entries(args ?? {})) {
    if (value === '' || value === 0 || value === false || value === null || value === undefined) continue;
    if (Array.isArray(value) && !value.length) continue;
    out[key] = value;
  }
  return out;
}

const text = { type: 'string' };
const TOOLS = [
  {
    name: 'apple_calendar', prompt: P.calendar,
    parameters: {
      action: { ...text, required: true, enum: ['add_event', 'find_events', 'add_reminder', 'list_reminders', 'complete_reminder'] },
      title: text, start: text, end: text, all_day: { type: 'boolean' }, location: text, notes: text,
      alarm_minutes: { type: 'integer' }, from: text, to: text, query: text, due: text,
      // No enum: models fill every field, and an enum makes them pick a priority nobody asked for.
      priority: text, list: text, include_completed: { type: 'boolean' }, id: text,
    },
  },
  {
    name: 'apple_contacts', prompt: P.contacts,
    parameters: { action: { ...text, required: true, enum: ['find'] }, query: { ...text, required: true }, limit: { type: 'integer' } },
  },
  {
    name: 'compose_message', prompt: P.compose,
    parameters: {
      kind: { ...text, required: true, enum: ['sms', 'email'] },
      to: { type: 'array', items: text, required: true }, cc: { type: 'array', items: text }, subject: text, body: text,
    },
  },
  {
    // Signed-in Gmail / Outlook (设置 › 连接器); the phone app makes the calls. Not on the Mac.
    name: 'email', prompt: P.email, phoneOnly: true,
    parameters: {
      action: { ...text, required: true, enum: ['accounts', 'search', 'read', 'send'] },
      account: text, query: text, limit: { type: 'integer' }, id: text,
      to: { type: 'array', items: text }, cc: { type: 'array', items: text }, subject: text, body: text, reply_to: text,
    },
  },
];

exports.bridge = function bridge(send, { desktop = false } = {}) {
  const pending = new Map();
  function register(ctx, defineTool) {
    ctx.systemPrompt.section({
      name: 'tool:apple_data',
      order: ctx.systemPrompt.getSectionOrder('TOOL_READ'),
      text: ({scope}) => TOOLS.some(tool => ctx.tools.get(tool.name, scope)) ? (desktop ? P.desktop : P.system) : '',
    });
    for (const tool of TOOLS) {
      if (desktop && tool.phoneOnly) continue;
      const parameters = {};
      for (const [key, schema] of Object.entries(tool.parameters)) parameters[key] = { ...schema, description: tool.prompt.params[key] };
      ctx.tools.register(defineTool({
        name: tool.name,
        description: desktop ? tool.prompt.desktopDescription : tool.prompt.description,
        parameters,
        output: { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] },
        async execute(args, exec) {
          const id = randomUUID();
          exec.signal?.throwIfAborted();
          return new Promise((resolve, reject) => {
            const abort = () => cancel('apple_data_cancelled');
            // Above the two minutes a question to the person waits; a message form stays open longer.
            const limit = tool.name === 'compose_message' ? 15 * 60000 : tool.name === 'email' ? 240000 : 180000;
            const timer = setTimeout(() => cancel(`internal_error: the app did not answer within ${limit / 1000} seconds`), limit);
            function cancel(code) {
              try { send({ appleDataCancel: id }); } catch {}
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
              send({ appleDataRequest: id, tool: tool.name, args: clean(args),
                ...(desktop ? { approval: approvalPolicy(exec.agent?.session) } : {}),
                ...(require('./full-auto.cjs').isOn(exec.agent?.session?.id) ? { auto: true } : {}) });
            } catch (error) { finish(error); }
          });
        },
      }));
    }
  }
  function receive(reply) {
    if (typeof reply?.appleDataReply !== 'string') return;
    pending.get(reply.appleDataReply)?.(reply.error ? new Error(reply.error) : null, String(reply.value ?? ''));
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
