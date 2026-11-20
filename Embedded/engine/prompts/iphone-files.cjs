// iphone_files: folders the person authorized in the Files app. See prompts/index.cjs.
const { label } = require('../ui-names.cjs');

module.exports = {
  get desktop() {
    return 'For folders the user authorized on this Mac, call authorized_files with action folders first. The path returned for each folder works with read, read_image, glob and grep. Append a relative path inside that folder to reach a file. Use list to browse a large directory before searching. To modify the original with write or edit, the call needs full file access (danger-full-access). Use authorized_files open to copy a file into the local workspace for shell commands or changes to a copy. If the folder is not granted, direct the user to ＋ → ' + label('authorizedFolders') + '.';
  },
  get desktopDescription() {
    return 'List folders authorized on this Mac and their paths for file tools. Use list to browse by folder ID, or open to copy a file into the local workspace.';
  },
  /** [open]: [{name, path}] of the folders the app holds open right now. */
  system: open => (open.length
          ? 'Folders the user authorized from the iPhone Files app (iCloud Drive included) are open at these paths: '
            + open.map(f => JSON.stringify(f.name) + ' at ' + JSON.stringify(f.path)).join('; ')
            + '. Use read, glob, grep and read_image on them directly by absolute path. Such a folder can be huge (iCloud Drive holds the user\'s whole cloud storage): look at its top level with iphone_files list, then glob or grep a specific subfolder rather than the folder root; searches of very large trees stop early with partial results. write and edit there work only under danger-full-access (full access); in other modes, open a copy into the workspace with iphone_files and work on that. Bash runs in a Linux machine that sees only the workspace: for a command on such a file, open it into the workspace first. '
          : '')
          + 'For files in the iPhone Files app, including recordings outside workspace, call iphone_files with action folders first, even if an earlier turn lacked access. Use list to find the file and open to obtain its workspacePath. If no suitable folder is granted, direct the user to ＋ → ' + label('authorizedFolders') + '.',

  // A getter, so the label is read after start.cjs has set the names.
  get description() { return 'Find files and recordings on this iPhone in folders the user authorized in Files. Start with folders, then list subdirectories. Use open to materialize one file in the shared workspace for read or bash. If no folders are authorized, ask the user to choose ＋ → ' + label('authorizedFolders') + '.'; },

  params: {
    action: 'folders, list, or open',
    folder: 'Folder id returned by folders',
    path: 'Path relative to that folder; empty for its root',
    offset: 'For listing: nextOffset from previous page',
  },
};
