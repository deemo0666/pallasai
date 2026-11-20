// claude_sessions and claude_desktop: the Claude desktop app on the person's computer. The native
// host owns the SSH connection to the paired computer, the question to the person and the stream
// of what the session does; only the request and the final JSON cross these pipes.
const { randomUUID } = require('node:crypto');
const P = require('./prompts/claude-desktop.cjs');

const HOOK = Symbol.for('dsh.ios.macTool');

exports.bridge = function bridge(send, { desktop = false, localAvailable = () => false } = {}) {
  const pending = new Map();
  let hasHost = false;
  let localEnabled = false;
  const canUseLocal = () => desktop && localEnabled && localAvailable();
  const available = () => hasHost || canUseLocal();
  // The Claude session each conversation last used, so a follow-up goes to the same one.
  const bound = new Map();
  function register(ctx, defineTool) {
    ctx.systemPrompt.section({
      name: 'tool:claude_desktop',
      order: ctx.systemPrompt.getSectionOrder('TOOL_READ'),
      text: ({scope, session}) => {
        // Without a computer, mac_task's section already points the person to pairing one.
        if (!available() || !ctx.tools.get('claude_desktop', scope)) return '';
        const last = session?.id ? bound.get(session.id) : undefined;
        return (desktop ? P.desktop : P.system) + (last ? '\n' + P.bound(last.title, last.id, last.computer) : '');
      },
    });

    function ask(request, exec, limit) {
      const id = randomUUID();
      exec.signal?.throwIfAborted();
      return new Promise((resolve, reject) => {
        const abort = () => cancel('claude_desktop_cancelled');
        const timer = setTimeout(() => cancel('claude_desktop_timeout'), limit);
        function cancel(code) {
          try { send({ claudeCancel: id }); } catch {}
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
          const session = exec.agent?.session;
          send({ claudeRequest: id, ...request, ...(desktop ? { localAvailable: canUseLocal() } : {}),
            ...(session ? { originSessionId: session.id, callId: exec.callId } : {}) });
        } catch (error) { finish(error); }
      });
    }

    const text = { type: 'string' };
    const output = { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] };

    ctx.tools.register(defineTool({
      name: 'claude_sessions',
      description: P.sessions.description,
      parameters: { host: { ...text, description: desktop ? P.desktopHost : P.sessions.params.host } },
      output,
      execute: (args, exec) => ask({ kind: 'catalog', ...(args.host ? { host: String(args.host) } : {}) }, exec, 120000),
    }), {when: available});

    const params = {};
    for (const key of ['message', 'action', 'session_id', 'project', 'project_name', 'title', 'confidence', 'reason', 'host']) {
      params[key] = { ...(key === 'confidence' ? { type: 'number' } : text), description: P.send.params[key] };
    }
    params.message.required = true;
    params.action.required = true;
    params.action.enum = ['continue', 'new_session', 'new_project'];
    if (desktop) params.host.description = P.desktopHost;

    ctx.tools.register(defineTool({
      name: 'claude_desktop',
      description: P.send.description,
      parameters: params,
      output,
      async execute(args, exec) {
        const sessionId = exec.agent?.session?.id;
        const action = String(args.action ?? '');
        let target = typeof args.session_id === 'string' ? args.session_id.trim() : '';
        let host = typeof args.host === 'string' ? args.host.trim() : '';
        // A follow-up with no target named goes to the session this conversation last used.
        const last = sessionId && bound.get(sessionId);
        if (action === 'continue' && last && (!host || host === last.host || host === last.computer)) {
          if (!target) target = last.id;
          if (target === last.id && !host) host = last.host;
        }
        const confidence = Number.isFinite(Number(args.confidence)) ? Math.max(0, Math.min(1, Number(args.confidence))) : 0.5;
        const value = await ask({
          kind: 'send',
          message: String(args.message ?? ''),
          action,
          ...(target ? { sessionId: target } : {}),
          ...(args.project ? { cwd: String(args.project) } : {}),
          ...(args.project_name ? { projectName: String(args.project_name) } : {}),
          ...(args.title ? { title: String(args.title) } : {}),
          ...(args.reason ? { reason: String(args.reason).slice(0, 200) } : {}),
          ...(host ? { host } : {}),
          confidence,
        }, exec, 40 * 60000);
        try {
          const result = JSON.parse(value);
          const session = result?.session;
          if (sessionId && session?.id) bound.set(sessionId, {
            id: session.id, title: session.title || session.id, host: result.host, computer: result.computer,
          });
        } catch {}
        return value;
      },
    }), {when: available});
  }

  function receive(reply) {
    if (!reply || typeof reply !== 'object') return;
    if (typeof reply.claudeHosts === 'number') hasHost = reply.claudeHosts > 0;
    else if (!desktop && typeof reply.macHosts === 'number') hasHost = reply.macHosts > 0;
    if (typeof reply.localClaudeEnabled === 'boolean') localEnabled = reply.localClaudeEnabled;
    pending.get(reply.claudeReply)?.(reply.error ? new Error(reply.error) : null, reply.value);
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
