// Runs on the embedded Node thread. The first pipe belongs to the native host and carries the
// launch result, then the new URL whenever the listener moves; the second carries the host's
// commands. The engine's login URL never enters a log.
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { trackLoopbackListeners } = require('./listener.cjs');
const [home, workspace, descriptor, commandDescriptor, phoneControl, uiNames, appFront] = process.argv.slice(2);
// The engine is some 7000 files that the interpreter (--jitless) compiles again at every start: keep
// their bytecode in Caches. A new app build lives at a new path, so each build keeps its own folder
// and the folders of earlier builds go.
function compileCache() {
  try {
    const root = path.join(require('node:os').homedir(), 'Library/Caches/dsh-compile-cache');
    const build = require('node:crypto').createHash('sha256').update(__dirname).digest('hex').slice(0, 16);
    fs.mkdirSync(root, { recursive: true, mode: 0o700 });
    for (const name of fs.readdirSync(root)) if (name !== build) fs.rmSync(path.join(root, name), { recursive: true, force: true });
    require('node:module').enableCompileCache(path.join(root, build));
  } catch {}
}
compileCache();
require('./ui-names.cjs').set(uiNames);
const fd = Number(descriptor);
const listeners = trackLoopbackListeners();
/** The authenticated URL the host connects to; its port follows the listener. */
let login;
let reported = false;
function send(message) {
  try { fs.writeSync(fd, JSON.stringify(message) + '\n'); } catch {}
}
function report(result) {
  if (reported) return;
  reported = true;
  send(result);
}
// 「relisten」: iOS took the listener while the app was suspended.
async function relisten() {
  if (!login) return send({ relisten: 'not_ready' });
  const url = new URL(login);
  try {
    url.port = String(await listeners.relisten(Number(url.port)));
    login = url.href;
    mark('relisten');
    send({ url: login });
  } catch (error) {
    send({ relisten: 'failed', code: /^[A-Z_]{2,40}$/.test(error.code) ? error.code : 'error' });
  }
}
// Memory needs no pipe to work; dreaming listens on it when there is one.
const memoryReply = require('./memory.cjs').install(send, home);
// After memory.cjs: the task_notes tool registers through the memory hook.
require('./task-notes.cjs').install(home);
if (commandDescriptor !== undefined) {
  let calculatorReply = () => {};
  const folderReply = require('./iphone-folders.cjs').install(send);
  const macReply = require('./mac-host.cjs').install(send);
  // After mac-host.cjs: claude_desktop registers through the mac_task hook.
  const claudeReply = require('./claude-desktop.cjs').install(send);
  const appleReply = require('./apple-model.cjs').install(send);
  const lanReply = require('./lan.cjs').install(send);
  let siBootTunnelReply = () => {};
  // After lan.cjs: run_shortcut registers through the lan_services hook.
  const shortcutReply = require('./shortcuts.cjs').install(send);
  // After lan.cjs: its tools register through the lan_services hook.
  const appleDataReply = require('./apple-data.cjs').install(send);
  let phoneCallReply = () => {}, deviceReply = () => {};
  // After lan.cjs: its prompt registers through the lan_services hook.
  const fullAutoReply = require('./full-auto.cjs').install(phoneControl);
  const commands = new net.Socket({ fd: Number(commandDescriptor), readable: true, writable: false });
  commands.setEncoding('utf8');
  commands.unref();
  let pending = '';
  commands.on('data', chunk => {
    pending += chunk;
    for (let end = pending.indexOf('\n'); end >= 0; end = pending.indexOf('\n')) {
      const line = pending.slice(0, end);
      pending = pending.slice(end + 1);
      if (line === 'relisten') relisten();
      else if (line === 'claude-oauth-fixture' && fs.existsSync(path.join(__dirname, 'claude-oauth-device.cjs'))) {
        require('./claude-oauth-device.cjs').port(home).then(
          port => send({ claudeOAuthFixture: String(port) }), () => send({ claudeOAuthFixture: 'failed' }));
      }
      else { folderReply(line); macReply(line); claudeReply(line); appleReply(line); lanReply(line); siBootTunnelReply(line); shortcutReply(line); appleDataReply(line); phoneCallReply(line); deviceReply(line); fullAutoReply(line); calculatorReply(line); memoryReply(line); }
    }
  });
  commands.on('error', () => {});
}
// Opt-in real-device timings. Record fixed stage names only.
const timingFile = process.env.DSH_IOS_BENCH === '1'
  ? path.join(require('node:os').homedir(), 'Library/Caches/dsh-engine-times') : undefined;
function mark(stage) {
  if (timingFile) fs.appendFileSync(timingFile, Date.now() + ' ' + stage + '\n', { mode: 0o600 });
}
if (timingFile) {
  mark('node');
  require('node:diagnostics_channel').subscribe('undici:request:create', ({ request }) => {
    if (request.origin === 'https://api.openai.com' && request.path === '/v1/responses') mark('model-request');
  });
}
// Profiles written before history search keep everything they say and get its rows appended once.
function addSessionSearch(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (text.includes('ios-tool-session-query')) return;
  const rows = fs.readFileSync(path.join(__dirname, 'account-default.yml'), 'utf8');
  const start = rows.indexOf('# History search');
  if (start < 0) return;
  fs.writeFileSync(file + '.tmp', text.replace(/\s*$/, '\n') + rows.slice(start), { mode: 0o600 });
  fs.renameSync(file + '.tmp', file);
}
// Profiles written before the phone orientation keep everything they say and get the row once.
function disableWebSurface(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (text.includes('id: harness-dev-context')) return;
  const row = '- id: harness-dev-context\n  disabled: true\n';
  fs.writeFileSync(file + '.tmp', text.replace(/\s*$/, '\n') + row, { mode: 0o600 });
  fs.renameSync(file + '.tmp', file);
}
// Without the Linux machine (a build that ships no guest shell) bash has nowhere to run: its tool
// and executor rows are disabled, so the model is never offered it.
function disableShellWithoutLinux(file) {
  if (process.env.DSH_IOS_SHELL_MODULE) return;
  let text = fs.readFileSync(file, 'utf8');
  for (const id of ['tool-bash', 'bash-sandbox']) {
    if (new RegExp('^- id: ' + id + '\\n', 'm').test(text)) continue;
    text = text.replace(/\s*$/, '\n') + '- id: ' + id + '\n  disabled: true\n';
  }
  fs.writeFileSync(file + '.tmp', text, { mode: 0o600 });
  fs.renameSync(file + '.tmp', file);
}
// Profiles written before the vendor uploads were switched off get the session-log row disabled once
// (older ones only had `enabled: false`, which the settings page could turn back on).
function disableVendorLogs(file) {
  const text = fs.readFileSync(file, 'utf8');
  const disabled = '- id: session-log-deepseek\n  disabled: true\n';
  const row = /^- id: session-log-deepseek\n(?:[ \t]+.*\n)*/m.exec(text);
  if (row && row[0] === disabled) return;
  const next = row ? text.replace(row[0], disabled) : text.replace(/\s*$/, '\n') + disabled;
  fs.writeFileSync(file + '.tmp', next, { mode: 0o600 });
  fs.renameSync(file + '.tmp', file);
}
// Profiles written before search followed the model: an existing web row (the search switch writes
// one) gets its search provider replaced, otherwise the row is added once.
function followModelSearch(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (text.includes('searchProvider: pallas-web-search')) return;
  const row = /^- id: web\n(?:[ \t]+.*\n)*/m.exec(text);
  let next;
  // The search switch also moves fetching to the DeepSeek Fetch API; fetching goes direct again.
  if (row && /searchProvider:/.test(row[0])) next = text.replace(row[0], row[0].replace(/searchProvider:.*$/m, 'searchProvider: pallas-web-search').replace(/fetchProvider:.*$/m, 'fetchProvider: http'));
  else if (row) next = text.replace(row[0], row[0] + (/\n  config:\n/.test(row[0]) ? '    searchProvider: pallas-web-search\n' : '  config:\n    searchProvider: pallas-web-search\n'));
  else next = text.replace(/\s*$/, '\n') + '- id: web\n  config:\n    searchProvider: pallas-web-search\n    fetchProvider: http\n';
  fs.writeFileSync(file + '.tmp', next, { mode: 0o600 });
  fs.renameSync(file + '.tmp', file);
}
// Profiles written before the assistant persona keep everything they say and get the row once. The
// text itself stays in prompts/persona.cjs and travels in the environment, so it follows the app.
function addPersona(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (text.includes('id: system-prompt')) return;
  const row = '- id: system-prompt\n  config:\n    includeHarnessIdentity: false\n    personaPrefix: !!js "process.env.DSH_IOS_PERSONA"\n';
  fs.writeFileSync(file + '.tmp', text.replace(/\s*$/, '\n') + row, { mode: 0o600 });
  fs.renameSync(file + '.tmp', file);
}
async function start() {
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  fs.mkdirSync(workspace, { recursive: true, mode: 0o700 });
  process.env.DSH_HOME = home;
  process.env.NARB_DISABLE_NATIVE_CACHE = '1';
  // The stock base layer uploads a conversation's log to the engine vendor's collector once the
  // person sends /feedback. Nothing of the person's leaves for anyone but the model they chose:
  // any non-empty value makes the launcher patch that row disabled.
  process.env.DSH_TELEMETRY_DISABLED = '1';
  process.chdir(fs.realpathSync(workspace));
  require('./workspace.cjs').install(process.cwd());
  process.env.DSH_IOS_PERSONA = require('./prompts/persona.cjs').system;
  const root = path.dirname(__dirname);
  // The app bundle is read-only: boot remembers what it learns about the files in it (patches/zz-startup.diff).
  const real = fs.realpathSync(root);
  process.env.DSH_IOS_IMMUTABLE_ROOT = [...new Set([real, real.replace(/^\/private\//, '/'), root])].join(':');
  process.env.DSH_IOS_BOOT_FACTS = path.join(require('node:os').homedir(), 'Library/Caches/dsh-boot-facts.json');
  // Only this engine writes the session root, always zstd: no need to read every session at start to prove it.
  process.env.DSH_IOS_SINGLE_ENCODING = '1';
  process.env.DSH_IOS_SESSION_HEADERS = path.join(require('node:os').homedir(), 'Library/Caches/dsh-session-headers.json');
  process.env.DSH_SYSTEM_FRAMEWORK = path.join(root, 'Frameworks/DshSystem.framework/DshSystem');
  // Skills that ship with the app (skills/<name>/SKILL.md): listed with the person's own, never removable.
  process.env.DSH_BUNDLED_SKILL_DIR = path.join(__dirname, 'skills');
  for (const stream of [process.stdout, process.stderr]) {
    let pending = '';
    stream.write = (chunk, encoding, callback) => {
      pending = (pending + String(chunk)).slice(-16384);
      const lines = pending.split('\n');
      pending = lines.pop();
      for (const line of lines) {
        const match = /dsh web:\s+(http:\/\/127\.0\.0\.1:\d+\/\?token=[^\s]+)/.exec(line);
        if (match && !login) { login = match[1]; mark('engine-ready'); report({ url: login }); }
      }
      const done = typeof encoding === 'function' ? encoding : callback;
      if (typeof done === 'function') queueMicrotask(done);
      return true;
    };
  }
  // The CLI can call process.exit on an invalid profile. Keep UIKit alive.
  process.exit = code => { throw new Error('engine_exit_' + code); };
  const entry = path.join(__dirname, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
  const profile = path.join(home, 'profiles', 'web');
  const localPlugins = require('./local-plugins.cjs');
  localPlugins.prepare(profile);
  globalThis[Symbol.for('dsh.ios.localPlugins')] = localPlugins;
  if (!fs.existsSync(path.join(profile, 'cordis.yml'))) fs.writeFileSync(path.join(profile, 'cordis.yml'), '[]');
  const defaults = path.join(profile, 'cordis.patch.yml');
  const prior = fs.existsSync(defaults) ? fs.readFileSync(defaults, 'utf8').replace(/^\s*#.*$/gm, '').trim() : '';
  if (!prior || prior === '[]') fs.copyFileSync(path.join(__dirname, 'account-default.yml'), defaults);
  else { addSessionSearch(defaults); disableWebSurface(defaults); addPersona(defaults); disableVendorLogs(defaults); followModelSearch(defaults); }
  disableShellWithoutLinux(defaults);
  process.argv = [process.execPath, entry, '--profile', 'web', '--host', '127.0.0.1', '--port', '0', '--no-open'];
  mark('cli-import');
  const { runCli } = await import(pathToFileURL(entry));
  mark('cli-loaded');
  await runCli();
}
start().catch(error => {
  const code = /^[A-Z_]{2,40}$/.test(error.code) ? error.code : 'engine_start_failed';
  mark(code);
  report({ error: code });
});
