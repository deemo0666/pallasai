import SwiftUI

/// Under a `mac_task` row: where the task is (connecting, waiting for 允许, sending files, running),
/// the computer agent's steps as they happen, its latest words and the newest screenshot it took.
struct MacTaskLiveView: View {
    let task: String
    let stepID: String
    let sessionID: String?
    let running: Bool
    @ObservedObject private var tasks = MacTask.shared
    @State private var enlarged = false

    var body: some View {
        if let live = tasks.live(for: task, stepID: stepID, sessionID: sessionID) {
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
                .accessibilityElement(children: .combine).accessibilityIdentifier("macTaskStage")

                let shown = running ? Array(live.steps.suffix(4)) : live.steps
                ForEach(shown, id: \.id) { step in row(step) }

                if running, !live.note.isEmpty {
                    Text(verbatim: live.note.replacingOccurrences(of: "\n", with: " "))
                        .font(StreamRow.detail).foregroundStyle(ChatColors.secondary).lineLimit(2)
                }
                if let shot = live.screenshot {
                    Button { enlarged = true } label: {
                        Image(platformImage: shot).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 200, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    .accessibilityLabel("电脑屏幕截图").accessibilityIdentifier("macTaskScreenshot")
                    #if os(macOS)
                    .sheet(isPresented: $enlarged) {
                        NavigationStack {
                            ScreenshotViewer(image: shot)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("关闭") { enlarged = false }.keyboardShortcut(.cancelAction)
                                    }
                                }
                        }.desktopSheet(width: 600, height: 400)
                    }
                    #else
                    .fullScreenCover(isPresented: $enlarged) { ScreenshotViewer(image: shot) }
                    #endif
                }
            }
            .padding(.leading, StreamRow.indent).padding(.bottom, 6)
            .animation(Motion.std(Motion.standard), value: live.steps.count)
        }
    }

    private func stage(_ live: MacTask.Live) -> String {
        let host = live.host
        switch live.stage {
        case .connecting: return String(localized: "正在连接「\(host)」")
        case .asking: return String(localized: "等你允许在「\(host)」上执行")
        case .uploading(let count): return String(localized: "正在把 \(count) 个文件传到「\(host)」")
        case .working:
            return live.steps.isEmpty ? String(localized: "「\(host)」已开始执行") : String(localized: "「\(host)」正在执行 · 第 \(live.steps.count) 步")
        case .fetching(let count): return String(localized: "正在从「\(host)」取回 \(count) 个文件")
        case .finished: return String(localized: "「\(host)」上执行了 \(live.steps.count) 步")
        }
    }

    private func row(_ step: ChatStep) -> some View {
        let summary = step.summary(in: "")
        return HStack(spacing: StreamRow.gap) {
            ToolGlyph(name: step.name).scaleEffect(0.85)
            HStack(spacing: 0) {
                Text(step.verb).font(StreamRow.detail).foregroundStyle(ChatColors.secondary).lineLimit(1).layoutPriority(1)
                if !summary.isEmpty {
                    StreamDot()
                    Text(verbatim: summary).font(StreamRow.detail).foregroundStyle(ChatColors.tertiary).lineLimit(1).truncationMode(.tail)
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
}

/// The screenshot full screen; tap to close.
private struct ScreenshotViewer: View {
    let image: PlatformImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(platformImage: image).resizable().scaledToFit()
        }
        .onTapGesture { dismiss() }
        .accessibilityAddTraits(.isButton).accessibilityLabel("关闭")
    }
}
