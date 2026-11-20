// Names of the app's pages as the person sees them, in the interface language, so prompts that
// send the person somewhere use the exact label on screen. The app passes them as JSON in its
// launch arguments (a language change takes a relaunch anyway); English is the fallback.
const names = {
  remoteHost: 'My Devices',
  authorizedFolders: 'Authorized Folders',
  pluginMarket: 'All Features → Plugins → Plugin Market',
  importPlugin: 'All Features → Plugins → Installed → Import Offline Plugin Package',
  phoneControl: 'Settings → Phone Control',
};

exports.set = function set(json) {
  try {
    const given = JSON.parse(json || '{}');
    for (const key of Object.keys(names)) {
      if (typeof given[key] === 'string' && given[key].trim()) names[key] = given[key].trim();
    }
  } catch {}
};

/** The on-screen label for `key`, quoted for a prompt. */
exports.label = key => '"' + names[key] + '"';
