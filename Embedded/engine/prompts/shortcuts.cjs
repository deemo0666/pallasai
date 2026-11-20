// run_shortcut: the person's own shortcuts in the Shortcuts app. See prompts/index.cjs.
module.exports = {
  system: `# The person's shortcuts
run_shortcut runs a shortcut the person made in the Shortcuts app, by its exact name, and returns what the shortcut outputs. Apps that offer Shortcuts actions do their work this way without opening their screens, so when the task is something an app does through a shortcut the person has, run that shortcut instead of operating the phone screen with iphone_screen. Use phone control only when no shortcut fits.
You cannot list the person's shortcuts: use only names the person gave you or that MEMORY records. When the person tells you about one of their shortcuts ("I have a shortcut called Log Expense that …"), save its exact name and what it does to MEMORY with the memory tool (this is an exception to only saving on request); fix the entry if a run reports the shortcut was not found. If no recorded shortcut fits, you may suggest the person make one with the app's action in the Shortcuts app and tell you its name.
Running a shortcut switches to the Shortcuts app and comes back to Pallas Agent when it finishes. A shortcut can send messages, spend money or change data like any app; ask first the same way you would before doing that yourself.`,

  description: 'Run one of the person\'s shortcuts from the Shortcuts app by its exact name, optionally passing text as its input, and wait until it finishes. Returns JSON {ok, data:{name, output}} where output is the text the shortcut ended with (empty when it outputs nothing), or {ok:false, error:{code, message}} with code invalid_args, not_available (Shortcuts app missing or Pallas Agent not on screen), shortcut_failed (includes not found; message is the Shortcuts app\'s), cancelled (the person stopped it), no_callback (the person came back before it finished; outcome unknown) or timeout.',

  desktop: `# The person's shortcuts
run_shortcut runs an existing shortcut from this Mac's Shortcuts app by its exact name. Use a suitable shortcut the person named instead of operating the window. You cannot list the person's shortcuts: use only names they gave you or that MEMORY records. When they tell you about one of their shortcuts, save its exact name and purpose to MEMORY. Fix the entry if a run reports that the shortcut was not found.
A shortcut can open an app, request input or have side effects. Ask first about sending, spending or changing data as you would for those actions directly. If permission is denied, do not repeat the action another way. Stopping a run cannot undo actions it already took.`,

  desktopDescription: 'Run an existing shortcut on this Mac by its exact name, optionally passing text as Shortcut Input. Returns JSON {ok, data:{name, output}} or {ok:false, error:{code, message}}. An empty output means the shortcut returned no text. A shortcut can ask the person for input. The run can be denied, cancelled, time out or fail, including when no shortcut has that name.',

  params: {
    name: 'The shortcut\'s exact name, as the person gave it or as MEMORY records it',
    input: 'Text handed to the shortcut as its input (Shortcut Input); omit when it takes none',
  },
};
