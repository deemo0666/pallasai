// Hands one task to DSH on a computer the user saved in Remote Hosts. The native host owns the SSH
// connection, the question to the person and the remote conversation; only the task, the files to
// send, the reply and workspace paths of fetched files cross these pipes.
const { randomUUID } = require('node:crypto');
const P = require('./prompts/mac-task.cjs');

// Images the person attached to this conversation, one list per message, oldest first.
function attachedImages(session) {
  const messages = [];
  for (const event of session?.snapshotEvents?.() ?? []) {
    if (event?.type !== 'agent/inbox/spliced') continue;
    for (const message of event.data?.inserted ?? []) {
      const images = (message?.content ?? []).filter(block => block?.type === 'image' && block.attachment?.attachmentId).map(block => block.attachment);
      if (images.length) messages.push(images);
    }
  }
  return messages;
}

// The conversation's approval policy: "never" under full access, "ask" otherwise.
function approvalPolicy(session) {
  // 全自动 runs device and computer tasks without asking, as full access does.
  if (require('./full-auto.cjs').isOn(session?.id)) return 'never';
  let policy = 'ask';
  for (const event of session?.snapshotEvents?.() ?? []) {
    if (event?.type === 'approval/policy' && typeof event.data?.policy === 'string') policy = event.data.policy;
  }
  return policy;
}

exports.approvalPolicy = approvalPolicy;

exports.bridge = function bridge(send, { desktop = false } = {}) {
  const pending = new Map();
  // Whether the person saved a confirmed computer; until the app says so, the tool is not offered.
  let hasHost = false;
  // Sessions with an open turn, so the app keeps running in the background until they end.
  const open = new Set();
  let reported = 0;
  const report = () => { if (open.size !== reported) { reported = open.size; send({ turnsActive: reported }); } };
  function register(ctx, defineTool) {
    if (!desktop) {
      ctx.on('session/event', (session, event) => {
        if (event?.type === 'turn/start') open.add(session.id);
        else if (event?.type === 'turn/end') open.delete(session.id);
        else return;
        report();
      });
      ctx.on('agent/disposed', ({agent}) => { if (open.delete(agent?.session?.id)) report(); });
    }
    ctx.systemPrompt.section({
      name: 'tool:mac_task',
      order: ctx.systemPrompt.getSectionOrder('TOOL_READ'),
      text: ({scope}) => !hasHost ? (desktop ? '' : P.noHost) :
        ctx.tools.get('mac_task', scope) ? (desktop ? P.desktop : P.system) : '',
    });
    ctx.tools.register(defineTool({
      name: 'mac_task',
      description: P.description(desktop),
      parameters: {
        task: { type: 'string', required: true, description: P.params.task },
        host: { type: 'string', description: P.params.host },
        images: { type: 'string', enum: ['none', 'latest', 'all'], description: P.params.images },
        files: { type: 'array', items: { type: 'string' }, description: P.params.files },
      },
      output: { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] },
      async execute(args, exec) {
        if (!hasHost) throw new Error('mac_no_host');
        const id = randomUUID();
        exec.signal?.throwIfAborted();
        // Only the engine can supply a session's directory. The model supplies file paths within it.
        const session = exec.agent?.session;
        const workspace = desktop ? (session?.header?.cwd ?? ctx.workingDirectory.defaultDirectory) : undefined;
        const outgoing = [];
        if (args.images === 'latest' || args.images === 'all') {
          const attachments = ctx.get('attachments');
          const messages = attachedImages(exec.agent?.session);
          const chosen = args.images === 'all' ? messages.flat() : (messages.at(-1) ?? []);
          for (const image of chosen) {
            const path = attachments?.imageHostPath?.(image);
            if (!path) throw new Error('mac_task_image_unavailable');
            outgoing.push({ path, name: image.name || `${String(image.attachmentId).slice(7, 19)}.${String(image.mediaType).split('/')[1] || 'jpg'}` });
          }
        }
        for (const path of Array.isArray(args.files) ? args.files : []) {
          if (typeof path === 'string' && path.trim()) outgoing.push({ workspacePath: path.trim() });
        }
        if (outgoing.length > 12) throw new Error('mac_task_too_many_files: send at most 12 files at once');
        return new Promise((resolve, reject) => {
          const abort = () => cancel('mac_task_cancelled');
          const timer = setTimeout(() => cancel('mac_task_timeout'), 30 * 60000);
          function cancel(code) {
            try { send({ macCancel: id }); } catch {}
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
            send({ macRequest: id, task: String(args.task ?? ''), approval: approvalPolicy(session),
              ...(session ? { sessionId: session.id, callId: exec.callId } : {}),
              ...(workspace ? { workspace } : {}),
              ...(typeof args.host === 'string' && args.host ? { host: args.host } : {}),
              ...(outgoing.length ? { files: outgoing } : {}) });
          } catch (error) { finish(error); }
        });
      }
    }), {when: () => hasHost});
  }
  function receive(reply) {
    if (!reply || typeof reply !== 'object') return;
    if (typeof reply.macHosts === 'number') hasHost = reply.macHosts > 0;
    pending.get(reply.macReply)?.(reply.error ? new Error(reply.error) : null, reply.value);
  }
  return { register, receive };
};

exports.install = function install(send) {
  const { register, receive } = exports.bridge(send);
  globalThis[Symbol.for('dsh.ios.macTool')] = register;
  return line => { if (line.startsWith('{')) receive(JSON.parse(line)); };
};
