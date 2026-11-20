import SwiftUI
import UIKit

/// Keep one UITextView (including its selection and IME marked range) as the draft changes.
struct ChatDraftEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var composing: Bool
    @Environment(\.isEnabled) private var enabled
    let identifier: String
    /// Changes with the conversation's state (生成中 · 可直接插话, 正在同步对话 …).
    var placeholder = String(localized: "给 Pallas 发消息…")
    /// Lets the `/` and `@` palette edit the text at the caret.
    var handle: DraftEditorHandle? = nil
    /// The text and caret (UTF-16) after each edit or caret move, delivered after the current update.
    var onCaret: ((String, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let editor = UITextView()
        editor.backgroundColor = .clear
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.textContainer.lineFragmentPadding = 0
        editor.textContainerInset = UIEdgeInsets(top: 9, left: 8, bottom: 9, right: 8)
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editor.accessibilityIdentifier = identifier
        editor.accessibilityLabel = placeholder
        editor.delegate = context.coordinator
        let placeholder = context.coordinator.placeholder
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = editor.accessibilityLabel
        placeholder.font = editor.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.textAlignment = .natural
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.isAccessibilityElement = false
        editor.addSubview(placeholder)
        handle?.view = editor
        handle?.changed = { [weak coordinator = context.coordinator] view in coordinator?.textViewDidChange(view) }
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: editor.frameLayoutGuide.leadingAnchor, constant: 8),
            placeholder.centerYAnchor.constraint(equalTo: editor.frameLayoutGuide.centerYAnchor),
            placeholder.trailingAnchor.constraint(equalTo: editor.frameLayoutGuide.trailingAnchor, constant: -8)
        ])
        return editor
    }

    func updateUIView(_ editor: UITextView, context: Context) {
        editor.isEditable = enabled
        let coordinator = context.coordinator
        coordinator.parent = self
        // Ordinary draft updates must never toggle the keyboard. A real focus change waits until
        // this update is over: becoming or resigning first responder inside it makes UIKit ask
        // SwiftUI's focus bridge about the very graph being updated — an AttributeGraph cycle that
        // hung the app until the watchdog killed it (sending a message folds the keyboard this way).
        if composing != coordinator.editing { coordinator.syncFocus(editor) }
        // The keyboard can own provisional text before reporting a marked range or
        // calling didChange. An unrelated render must not write the old draft back.
        if text != coordinator.lastDraft, editor.markedTextRange == nil {
            coordinator.lastDraft = text
            if editor.text != text { editor.text = text }
        }
        if coordinator.placeholder.text != placeholder { coordinator.placeholder.text = placeholder; editor.accessibilityLabel = placeholder }
        coordinator.placeholder.isHidden = composing || coordinator.editing || !editor.text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let font = uiView.font else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(40, min(height, ceil(font.lineHeight * 5) + 18)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatDraftEditor
        var lastDraft = ""
        var editing = false
        let placeholder = UILabel()
        private var focusQueued = false
        init(_ parent: ChatDraftEditor) { self.parent = parent }

        /// Moves the keyboard to match `composing` on the next turn of the run loop, once.
        /// If the editor cannot take focus, `composing` goes back to false instead of retrying.
        func syncFocus(_ editor: UITextView) {
            guard !focusQueued else { return }
            focusQueued = true
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self else { return }
                self.focusQueued = false
                guard let editor, editor.window != nil else { return }
                if self.parent.composing {
                    if !editor.isFirstResponder, !editor.becomeFirstResponder() { self.parent.composing = false }
                } else if editor.isFirstResponder {
                    editor.resignFirstResponder()
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            editing = true
            placeholder.isHidden = true
            parent.composing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            editing = false
            placeholder.isHidden = !textView.text.isEmpty
            parent.composing = false
        }

        func textViewDidChange(_ textView: UITextView) {
            placeholder.isHidden = editing || !textView.text.isEmpty
            lastDraft = textView.text
            if parent.text != lastDraft { parent.text = lastDraft }
            textView.invalidateIntrinsicContentSize()
            reportCaret(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) { reportCaret(textView) }

        /// Never while the keyboard is composing (pinyin): the marked letters are not the query yet.
        /// Always after this run-loop turn: a caret moved by an update must not publish inside it.
        private func reportCaret(_ textView: UITextView) {
            guard let report = parent.onCaret, textView.markedTextRange == nil else { return }
            let text = textView.text ?? "", caret = textView.selectedRange.length == 0 ? textView.selectedRange.location : -1
            DispatchQueue.main.async { report(text, caret) }
        }
    }
}
