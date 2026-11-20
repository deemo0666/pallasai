import SwiftUI

/// Under a `claude_desktop` row: where the message is (connecting, waiting for 允许, sending, being
/// worked on), the Claude session's tool calls as they happen, its latest words, and a question it
/// put to the person on the computer.
struct ClaudeDesktopLiveView: View {
    let message: String
    let stepID: String
    let sessionID: String?
    let running: Bool
    @ObservedObject private var desktop = ClaudeDesktop.shared

    var body: some View {
        if let live = desktop.live(for: message, stepID: stepID, sessionID: sessionID) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(stage(live)).lineLimit(1)
                    Spacer(minLength: 8)
                    if running && live.stage != .finished {
                        TimelineView(.periodic(from: live.started, by: 1)) { context in
                            Text(ChatFormat.span(context.date.timeIntervalSince(live.started))).monospacedDigit()
                        }
                    }
                }
                .font(StreamRow.detail).foregroundStyle(ChatColors.tertiary)
                .accessibilityElement(children: .combine).accessibilityIdentifier("claudeDesktopStage")

                let shown = running ? Array(live.steps.suffix(4)) : live.steps
                ForEach(shown) { step in row(step) }

                if let question = live.question, !question.isEmpty {
                    Text(verbatim: question).font(StreamRow.detail).foregroundStyle(ChatColors.secondary).lineLimit(4)
                } else if running, !live.note.isEmpty {
                    Text(verbatim: live.note.replacingOccurrences(of: "\n", with: " "))
                        .font(StreamRow.detail).foregroundStyle(ChatColors.secondary).lineLimit(2)
                }
            }
            .padding(.leading, StreamRow.indent).padding(.bottom, 6)
            .animation(Motion.std(Motion.standard), value: live.steps.count)
        }
    }

    private func stage(_ live: ClaudeDesktop.Live) -> String {
        let title = live.title.isEmpty ? live.host : live.title
        switch live.stage {
        case .connecting: return String(localized: "正在连接「\(live.host)」")
        case .asking: return String(localized: "等你确认发给 Mac 上的 Claude")
        case .sending: return String(localized: "正在发给 Claude「\(title)」")
        case .working:
            return live.steps.isEmpty ? String(localized: "Claude「\(title)」已开始处理") : String(localized: "Claude「\(title)」正在处理 · 第 \(live.steps.count) 步")
        case .finished: return String(localized: "Claude「\(title)」处理了 \(live.steps.count) 步")
        }
    }

    private func row(_ step: ClaudeDesktop.Step) -> some View {
        HStack(spacing: StreamRow.gap) {
            Image(systemName: Self.symbol(step.name)).font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatColors.tertiary).frame(width: 18)
            HStack(spacing: 0) {
                Text(verbatim: step.name).font(StreamRow.detail).foregroundStyle(ChatColors.secondary).lineLimit(1).layoutPriority(1)
                if !step.summary.isEmpty {
                    StreamDot()
                    Text(verbatim: step.summary).font(StreamRow.detail).foregroundStyle(ChatColors.tertiary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            switch step.state {
            case "running": QuietArc(size: 12).foregroundStyle(ChatColors.tertiary).frame(width: 14, height: 14)
            case "ok": EmptyView()
            default: Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.red)
            }
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
    }

    /// Claude Code's tool names, drawn like the app's own tools.
    private static func symbol(_ name: String) -> String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "AskUserQuestion": "questionmark.bubble"
        default: "wrench.and.screwdriver"
        }
    }
}
