// mac_task: one task handed to DSH on the person's computer. See prompts/index.cjs.
const { label } = require('../ui-names.cjs');

module.exports = {
  system: 'This conversation runs on the iPhone. For anything that must happen on the user\'s computer ("on my Mac", files in its Downloads, ffmpeg or other desktop software), call mac_task; bash here only sees the iPhone. Images the user attached here and files in this workspace do not exist on the computer: pass them with images / files, and never ask the computer to look for them in its Photos, Downloads or elsewhere. Files the computer delivers come back under workspacePath: call present on them when the user asked to get a file back.',

  desktop: 'This conversation runs on this Mac. Use mac_task when the user asks to hand work to a different saved computer. Work on this Mac stays in this conversation. Supply the saved computer\'s name if the user specified one. Send relevant attachments with images or files and call present on returned workspacePath values when the user asked to get a file back.',

  // Shown instead of system while no computer is saved, so a request for the computer gets a pointer rather than a guess.
  get noHost() { return 'This conversation runs on the iPhone, and the user has not connected a computer yet. If they ask for anything that must happen on their computer ("on my Mac", files on it, desktop software), do not try it with bash or other tools here (they only see the iPhone): tell them in one or two sentences to connect their computer on the app\'s ' + label('remoteHost') + ' page first, then ask again.'; },

  description(desktop) {
    const computer = desktop ? 'a different saved computer' : 'the user\'s computer';
    const workspace = desktop ? 'this session\'s workspace' : 'this iPhone\'s workspace';
    return 'Run one task on ' + computer + ' through the DSH agent there, over a computer connection the user saved on the app\'s ' + label('remoteHost') + ' page. The person is asked to allow it first unless this conversation has full access or they turned on automatic approval; the same rule covers each approval the computer agent needs. Write task as a complete, self-contained instruction: the agent on the computer sees nothing of this conversation. To give the computer the images the user attached here, set images ("latest": those in the user\'s most recent message with images; "all": every image in this conversation; otherwise "none"). To give it files from this workspace, list their paths in files. Sent files arrive as attachments of the task, with their paths on the computer, so the task can refer to them as "the attached images/files". Ask it to present any file that should come back; presented files are copied into ' + workspace + '. Returns JSON: host, reply (the agent\'s final answer), sent (names of files sent), files [{macPath, workspacePath}], and ended when the turn did not finish normally. Can take minutes.';
  },

  params: {
    task: 'The full instruction for the agent on the computer',
    host: 'Name of the saved computer; only needed when several are saved',
    images: 'Images the user attached in this conversation to send along; none unless the task needs them',
    files: 'Workspace paths of files to send to the computer',
  },
};
