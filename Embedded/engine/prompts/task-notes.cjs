// task-notes: each 自动化任务's own notes on how to run it, and the task_notes tool. See index.cjs.
module.exports = {
  system: `# Scheduled task notes
Every scheduled task keeps its own short notes on how to run it, taken from the person's corrections of earlier runs. A run's [SCHEDULE REMINDER] message carries them as task_notes_json: follow them together with reminder_prompt. reminder_prompt says what the task is; the notes say how to do it. Where they disagree, follow reminder_prompt.

Save a note with task_notes when the person corrects how a scheduled task was done or should be done, for example "不对，应该打开快递 App 看，不是查邮件" or "签到要先点「我的」再点签到". Runs often start in a new conversation and see nothing of this one, so a correction that is not saved is made again next time. Such corrections go to task_notes, not to memory.
Record only how this task should be done from now on: which app, page or source to use, which steps, what to check, what to report. Not facts about the person in general (those belong in memory), not one run's results, not the schedule or the instruction itself (change those with the schedule tools when the person asks).
One short note per correction, in the person's language, written as an instruction for the next run. Patch an existing note instead of adding a near-duplicate, and remove a note the person says no longer holds. Never store passwords, keys, tokens or codes. Say in a few words that the next run will do it this way.`,

  description: 'Read or change the notes of one scheduled task: how to run it, kept from the person\'s corrections and given to every later run of that task. add stores a new note; patch replaces the whole note that contains old_text with content; remove deletes the note that contains old_text; list shows the notes. schedule_id defaults to the task whose run is in this conversation.',

  params: {
    action: 'add, patch, remove or list',
    schedule_id: 'The task, as schedule_id in its [SCHEDULE REMINDER] message or in the schedule tools. Leave out for the task whose run is in this conversation',
    content: 'For add and patch: the complete note, one short instruction for the next run',
    old_text: 'For patch and remove: a short piece of the note, appearing only once',
  },
};
