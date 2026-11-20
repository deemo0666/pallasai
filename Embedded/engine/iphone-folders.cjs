// The native host resolves the user's bookmarks. Only tool arguments and results cross the pipe.
const { randomUUID } = require('node:crypto');
const P = require('./prompts/iphone-files.cjs');

exports.bridge = function bridge(send, { desktop = false, folderPath } = {}) {
  const pending = new Map();
  const name = desktop ? 'authorized_files' : 'iphone_files';
  const actions = ['folders', 'list', 'open'];
  // [{name, path}] of the folders the app holds open, from its `folders` line.
  let open = [];
  async function request(args, signal) {
    const id = randomUUID();
    signal?.throwIfAborted();
    return new Promise((resolve, reject) => {
      const abort = () => cancel('folder_request_cancelled');
      const timer = setTimeout(() => cancel('folder_request_timeout'), 120000);
      function cancel(code) {
        if (desktop) { try { send({ folderCancel: id }); } catch {} }
        finish(new Error(code));
      }
      function finish(error, value) {
        if (!pending.delete(id)) return;
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        if (error) reject(error); else resolve(value);
      }
      pending.set(id, finish);
      signal?.addEventListener('abort', abort, { once: true });
      try { send({ folderRequest: id, args }); }
      catch (error) { finish(error); }
    });
  }

  function register(ctx, defineTool) {
    ctx.systemPrompt.section({
      name: 'tool:' + name,
      order: ctx.systemPrompt.getSectionOrder('TOOL_READ'),
      text: ({scope}) => ctx.tools.get(name, scope) ? (desktop ? P.desktop : P.system(open)) : '',
    });
    ctx.tools.register(defineTool({
      name,
      description: desktop ? P.desktopDescription : P.description,
      parameters: {
        action: { type: 'string', required: true, enum: actions, description: P.params.action },
        folder: { type: 'string', description: P.params.folder },
        path: { type: 'string', description: P.params.path },
        offset: { type: 'integer', description: P.params.offset },
      },
      output: { schema: { type: 'string' }, render: (_args, value) => [{type: 'text', text: value}] },
      async execute(args, exec) {
        if (!actions.includes(args?.action)) throw new Error('folder_invalid_action');
        const value = await request(args, exec.signal);
        if (!folderPath || args.action !== 'folders') return value;
        return JSON.stringify(JSON.parse(value).map(folder => ({ ...folder, path: folderPath(folder.id) })));
      }
    }));
  }
  function receive(reply) {
    if (!reply || typeof reply !== 'object') return;
    if (!desktop && Array.isArray(reply.folders)) {
      open = reply.folders.filter(f => f && typeof f.path === 'string' && typeof f.name === 'string');
      globalThis[Symbol.for('dsh.local.workspace')]?.setFolders(open.map(f => f.path));
      return;
    }
    pending.get(reply.folderReply)?.(reply.error ? new Error(reply.error) : null, reply.value);
  }
  return { register, receive, request };
};

exports.install = function install(send) {
  const folders = exports.bridge(send);
  globalThis[Symbol.for('dsh.ios.folderTool')] = folders.register;
  return line => {
    if (line.startsWith('{')) folders.receive(JSON.parse(line));
  };
};
