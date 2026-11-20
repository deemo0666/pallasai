const { dirname, isAbsolute, resolve } = require('node:path');
// DSH session headers keep their original cwd. Only map a prior app container's
// workspace (or the prototype's Linux mount) at filesystem boundaries.
const oldRoot = /^(?:\/root\/workspace|(?:\/private)?\/var\/mobile\/Containers\/Data\/Application\/[0-9a-f-]{36}\/Documents\/workspace)(?=\/|$)/i;
exports.install = function install(root) {
  const map = (path, to) => typeof path === 'string' ? path.replace(oldRoot, () => to) : path;
  // The app container also holds native attachments and installed skills;
  // bundled skills live alongside the embedded engine in the app bundle.
  const container = dirname(dirname(root));
  const bundle = dirname(__dirname);
  const canonical = path => path.replace(/^\/private(?=\/var\/)/, '');
  const isWithin = (path, base) => path === base || path.startsWith(base + '/');
  // Folders the person authorized in Files (iCloud Drive included). The app holds their security
  // scope while it runs, so this process reads them directly; writes follow the sandbox mode.
  let folders = [];
  // The app's own state: engine home (settings, credentials, sessions) and preferences.
  const own = resolve(container, 'Library');
  globalThis[Symbol.for('dsh.local.workspace')] = {
    setFolders(list) {
      folders = (Array.isArray(list) ? list : []).filter(path => typeof path === 'string' && isAbsolute(path)).map(canonical);
    },
    folders: () => folders.slice(),
    /** Full access may write anywhere the app can, except the app's own settings and credentials. */
    guardWrite(path) {
      if (typeof path !== 'string') return;
      if (isWithin(canonical(resolve(map(path, root))), canonical(own))) {
        const error = new Error(`cannot write "${path}": Pallas Agent's own settings and data are protected in every mode`);
        error.code = 'FS_SANDBOX_DENIED';
        throw error;
      }
    },
    guestReadPath(path, cwd) {
      const absolute = resolve(map(cwd ?? root, '/root/workspace'), map(path, '/root/workspace'));
      if (isWithin(absolute, '/root/workspace') ||
          [container, bundle, ...folders].some(base => isWithin(canonical(absolute), canonical(base)))) return;
      // Keep symlink/../ traversal in the guest provider.
      return isAbsolute(path) ? path : map(cwd ?? root, '/root/workspace') + '/' + path;
    },
    physical: path => map(path, root),
    stable: path => map(path, '/root/workspace'),
  };
};
