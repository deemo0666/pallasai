const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { randomUUID } = require('node:crypto');

const packageName = /^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/;
function writeJSON(target, value) {
  const temp = target + '.' + randomUUID();
  try {
    fs.writeFileSync(temp, JSON.stringify(value, null, 2) + '\n', {mode: 0o600});
    fs.renameSync(temp, target);
  } finally { fs.rmSync(temp, {force: true}); }
}

// A process can end between a directory rename and the atomic manifest write.
// Recover only the package named in our journal, using the committed manifest.
function recover(profile) {
  const journal = path.join(profile, '.ios-plugin-operation.json');
  if (!fs.existsSync(journal)) return;
  const {name, operation, temp} = JSON.parse(fs.readFileSync(journal));
  if (!packageName.test(name) || !/^\.import-[A-Za-z0-9]+$/.test(temp) ||
      !['add', 'remove'].includes(operation)) throw new Error('本机插件事务记录无效。');
  const dest = path.join(profile, 'node_modules', name);
  const staged = path.join(path.dirname(dest), temp);
  const manifest = JSON.parse(fs.readFileSync(path.join(profile, 'package.json')));
  const retained = manifest.dependencies?.[name] === 'file:node_modules/' + name;
  if (operation === 'add' && !retained) fs.rmSync(dest, {recursive: true, force: true});
  if (operation === 'remove' && retained && fs.existsSync(staged)) fs.renameSync(staged, dest);
  fs.rmSync(staged, {recursive: true, force: true});
  fs.unlinkSync(journal);
}

function prepare(profile) {
  fs.mkdirSync(profile, {recursive: true});
  const modules = path.join(profile, 'node_modules');
  // Older builds projected the signed app's entire module tree here.
  if (fs.lstatSync(modules, {throwIfNoEntry: false})?.isSymbolicLink()) fs.unlinkSync(modules);
  fs.mkdirSync(modules, {recursive: true});
  if (!fs.existsSync(path.join(profile, 'package.json'))) {
    writeJSON(path.join(profile, 'package.json'), {name: 'dsh-profile-web', private: true, dependencies: {},
      dsh: {profile: {bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']}}});
  }
  recover(profile);
}

// Called under the DSH plugin manager's profile lock. The caller validates
// compatibility, patch syntax and platform, then applies the normal lifecycle.
function add(profile, source) {
  const inbox = fs.realpathSync(path.join(os.tmpdir(), 'DSHPluginImport'));
  const folder = fs.realpathSync(source);
  if (path.dirname(folder) !== inbox || !/^[0-9a-f-]{36}$/i.test(path.basename(folder))) {
    throw new Error('请通过「导入桌面插件目录」选择已构建的插件。');
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(profile, 'package.json')));
  const pkgFile = path.join(folder, 'package.json');
  if (!fs.lstatSync(pkgFile).isFile()) throw new Error('插件缺少 package.json。');
  const pkg = JSON.parse(fs.readFileSync(pkgFile));
  const name = pkg.name;
  if (typeof name !== 'string' || !packageName.test(name) || name.length > 214 ||
      name === 'node_modules' || !pkg.dsh?.bundle?.patch) throw new Error('请选择带插件声明的插件包。');
  const modules = path.join(profile, 'node_modules');
  const dest = path.join(modules, name);
  if (Object.hasOwn(manifest.dependencies ?? {}, name) || fs.existsSync(path.join(__dirname, 'node_modules', name))) {
    throw new Error('此名称已有安装；请先检查已安装的插件。');
  }
  const parent = path.dirname(dest);
  fs.mkdirSync(parent, {recursive: true});
  if (fs.realpathSync(parent) !== path.resolve(fs.realpathSync(modules), path.dirname(name))) {
    throw new Error('插件目录无效。');
  }
  const patches = Array.isArray(pkg.dsh.bundle.patch) ? pkg.dsh.bundle.patch : [pkg.dsh.bundle.patch];
  if (!patches.length || !patches.every(p => typeof p === 'string' &&
      fs.realpathSync(path.resolve(folder, p)).startsWith(folder + path.sep) &&
      fs.statSync(path.resolve(folder, p)).isFile())) throw new Error('插件 patch 路径无效。');
  const stage = fs.mkdtempSync(path.join(parent, '.import-'));
  try {
    fs.cpSync(folder, stage, {recursive: true, filter(file) {
      if (path.basename(file) === '.git') return false;
      const stat = fs.lstatSync(file);
      if (stat.isDirectory()) return true;
      if (!stat.isFile() || /\.(node|dylib|dll|so)(\.|$)/i.test(file)) {
        throw new Error('插件包含符号链接、特殊文件或桌面原生库；请导入已构建的纯 JavaScript 包。');
      }
      return true;
    }});
    if (fs.lstatSync(dest, {throwIfNoEntry: false})) throw new Error('插件目录已存在。');
    const journal = path.join(profile, '.ios-plugin-operation.json');
    writeJSON(journal, {name, operation: 'add', temp: path.basename(stage)});
    try {
      fs.renameSync(stage, dest);
      manifest.dependencies ??= {};
      manifest.dependencies[name] = 'file:node_modules/' + name;
      writeJSON(path.join(profile, 'package.json'), manifest);
    } finally { recover(profile); }
    return () => fs.rmSync(dest, {recursive: true, force: true});
  } finally { fs.rmSync(stage, {recursive: true, force: true}); }
}

function remove(profile, name) {
  const manifest = JSON.parse(fs.readFileSync(path.join(profile, 'package.json')));
  if (!packageName.test(name) || manifest.dependencies?.[name] !== 'file:node_modules/' + name) {
    throw new Error('此插件不属于本机目录导入。');
  }
  const dest = path.join(profile, 'node_modules', name);
  const temp = '.import-' + randomUUID().replaceAll('-', '');
  const old = path.join(path.dirname(dest), temp);
  writeJSON(path.join(profile, '.ios-plugin-operation.json'), {name, operation: 'remove', temp});
  try {
    fs.renameSync(dest, old);
    delete manifest.dependencies[name];
    writeJSON(path.join(profile, 'package.json'), manifest);
  } finally { recover(profile); }
}

module.exports = {prepare, add, remove};
