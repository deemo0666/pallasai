import { homedir } from 'node:os';
import { join, relative } from 'node:path';

const native = { exports: {} };
process.dlopen(native, process.env.DSH_SYSTEM_FRAMEWORK);

function storeName(path) {
  // DSH_HOME is the native host's absolute path. Its container UUID can
  // change across an update and Darwin may prepend /private to it.
  const canonical = value => value.replace(/^\/private\//, '/');
  if (canonical(path) === canonical(join(process.env.DSH_HOME, '.credentials.yaml'))) return 'default';
  return relative(canonical(homedir()), canonical(path));
}
export async function readFile(path) {
  const name = storeName(path);
  const text = native.exports.credentialDocument(name);
  if (text === undefined) throw Object.assign(Error('credential store is empty'), { code: 'ENOENT' });
  return text;
}

export async function writeFileAtomic(path, text) {
  native.exports.credentialDocument(storeName(path), text);
}
