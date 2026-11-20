import SwiftUI

/// What pages pushed by the shell can ask of it without knowing how it is built: go back to the
/// chat (a prompt or a report was put in the draft), or switch to 本机引擎.
struct ShellActions {
    /// Pops every pushed page; the chat is in front again.
    var returnToChat: () -> Void = {}
    /// Connects to 本机引擎. `resume` reconnects the conversation last open on it and keeps the
    /// pushed pages; otherwise a new conversation opens and the chat comes to the front.
    /// Returns the error shown to the user, nil when it worked. Nil itself: no shell to ask.
    var useEngine: ((_ resume: Bool) async -> String?)? = nil
}

private struct ShellActionsKey: EnvironmentKey {
    static let defaultValue = ShellActions()
}

extension EnvironmentValues {
    var shellActions: ShellActions {
        get { self[ShellActionsKey.self] }
        set { self[ShellActionsKey.self] = newValue }
    }
}

extension Conversation {
    /// Puts `text` in the draft of a new conversation on the host in use, without sending it.
    /// With no host to open one on, the text waits in the current draft. Returns at once:
    /// `openSession` only returns when that conversation's connection ends.
    func startDraft(_ text: String) {
        if connection != nil {
            Task { await openSession(nil, initialDraft: text) }
        } else {
            draft = text
        }
    }
}
