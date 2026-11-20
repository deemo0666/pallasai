// Every prompt this app adds to the on-phone DSH engine lives in this folder, one file per tool or
// feature, so it can be read and changed in one place:
//
//   iphone-files.cjs       iphone_files: authorized Files folders
//   mac-task.cjs           mac_task: a task run on the person's computer
//   claude-desktop.cjs     claude_sessions, claude_desktop: sessions in the Claude desktop app on the person's computer
//   lan.cjs                lan_services: Bonjour services on the local network
//   shortcuts.cjs          run_shortcut: the person's shortcuts in the Shortcuts app
//   apple-data.cjs         apple_calendar, apple_contacts, compose_message: calendar, reminders, contacts, texts and email
//   memory.cjs             persistent memory rules and the memory tool
//   task-notes.cjs         task_notes: each scheduled task's own notes on how to run it
//   dream.cjs              the background memory review (dreaming)
//   persona.cjs            who the model is: the owner's assistant, not a coding agent (replaces the stock
//                          web profile's personaPrefix; see the system-prompt row in account-default.yml)
//   surface.cjs            where the person talks to you (Pallas Agent on this iPhone)
//
// Not here: the DSH engine's own prompts (its @deepseek-ai packages) and Embedded/patches, which
// change upstream code. Page names the prompts send the person to come from the app in the
// interface language (../ui-names.cjs); never write an interface label into a prompt.
module.exports = {
  iphoneFiles: require('./iphone-files.cjs'),
  macTask: require('./mac-task.cjs'),
  claudeDesktop: require('./claude-desktop.cjs'),
  lan: require('./lan.cjs'),
  shortcuts: require('./shortcuts.cjs'),
  appleData: require('./apple-data.cjs'),
  memory: require('./memory.cjs'),
  taskNotes: require('./task-notes.cjs'),
  dream: require('./dream.cjs'),
  persona: require('./persona.cjs'),
  surface: require('./surface.cjs'),
};
