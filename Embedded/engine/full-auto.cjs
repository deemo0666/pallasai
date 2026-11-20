// 全自动: the conversations the person switched to full auto in the app (App/FullAuto.swift).
// The app sends {"fullAuto": [session ids]} whenever the list changes, and {"accounts": [{id, label,
// username}]} for the sign-ins saved in Pallas Agent (never their passwords: the app types those).
//
// A full-auto conversation:
//   - gets the prompt in prompts/full-auto.cjs (no questions, sign-ins and codes handled on the phone);
//   - has the approval policy "never" (mac-host.cjs approvalPolicy), so device and computer tasks run;
//   - sends `auto` with phone, call and Apple data requests, so the app asks nothing for them.
const P = require('./prompts/full-auto.cjs');

const HOOK = Symbol.for('dsh.ios.lanTool');
const ID = /^[A-Za-z0-9._:-]{1,128}$/;
let sessions = new Set();
let accounts = [];

function isOn(sessionID) { return typeof sessionID === 'string' && sessions.has(sessionID); }
function account(id) { return accounts.find(a => a.id === id); }

/** Applies one line from the app; true when it was for this module. */
function receive(reply) {
  if (Array.isArray(reply?.fullAuto)) {
    sessions = new Set(reply.fullAuto.filter(id => typeof id === 'string' && ID.test(id)));
    return true;
  }
  if (Array.isArray(reply?.accounts)) {
    const text = (value, limit) => (typeof value === 'string' ? value.replace(/[\r\n;]+/g, ' ').trim().slice(0, limit) : '');
    accounts = reply.accounts
      .filter(a => typeof a?.id === 'string' && ID.test(a.id))
      .map(a => ({ id: a.id, label: text(a.label, 60) || a.id, username: text(a.username, 120) }))
      .slice(0, 100);
    return true;
  }
  return false;
}

function register(ctx, phoneOn = () => false) {
  ctx.systemPrompt.context({
    name: 'full-auto', order: 230, required: true, interpolate: false,
    text: ({ agent }) => isOn(agent?.session?.id) ? P.system(accounts, phoneOn()) : '',
  });
}

exports.isOn = isOn;
exports.account = account;
exports.receive = receive;
exports.register = register;
exports.reset = () => { sessions = new Set(); accounts = []; };
/** `phoneControl`: the app's phone control state at start ('on', 'off', 'unlinked'); later lines update it. */
exports.install = function install(phoneControl) {
  let phoneOn = phoneControl === 'on';
  const previous = globalThis[HOOK];
  globalThis[HOOK] = (ctx, defineTool) => {
    previous?.(ctx, defineTool);
    register(ctx, () => phoneOn);
  };
  return line => {
    if (!line.startsWith('{')) return;
    let reply;
    try { reply = JSON.parse(line); } catch { return; }
    if (typeof reply?.phoneControl === 'string') phoneOn = reply.phoneControl === 'on';
    receive(reply);
  };
};
