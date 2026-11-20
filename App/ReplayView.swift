import SwiftUI

struct ReplayView: View {
    let document: ReplayDocument
    var continueChat: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @AppStorage("accentPalette") private var palette = AccentPalette.graphite
    @AppStorage("accentHue") private var hue = 0.58
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @State private var elapsed = 0.0
    @State private var playing = true
    @State private var speed = 1
    @State private var activePicture: ReplayPictureID?
    @State private var tasksOpen = false
    private let timing: ReplayTiming
    private let starts: [Double]
    private let end: Double
    private let status: [(tasks: Int?, goal: Int?)]

    @ViewBuilder private func picture(_ item: ReplayPictureID) -> some View {
        if let bytes = document.images[item.id] {
            AttachmentPreview(title: String(localized: "回放图片"), dimensions: "", thumbnail: nil) { bytes }
        }
    }

    init(document: ReplayDocument, continueChat: ((String) -> Void)? = nil) {
        self.document = document
        self.continueChat = continueChat
        let timing = ReplayTiming(events: document.events)
        self.timing = timing
        starts = timing.rows.map(\.start)
        end = max(0.001, timing.duration)
        var tasks: Int?, goal: Int?
        status = document.events.indices.map { index in
            let event = document.events[index]
            if event.kind == "turn" { tasks = nil }
            if event.kind == "todos" { tasks = event.tasks.isEmpty ? nil : index }
            if event.kind == "goal" { goal = event.text.isEmpty ? nil : index }
            return (tasks, goal)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<visibleCount, id: \.self) { index in
                            let event = document.events[index]
                            VStack(alignment: .leading, spacing: 6) {
                                let finish = timing.turnForRow[index].flatMap { timing.turnEnds[$0] }
                                row(event, span: timing.rows[index], turnComplete: finish.map { elapsed >= $0 } ?? false)
                                if let turn = timing.footerAfter[index], let end = timing.turnEnds[turn], full || elapsed >= end,
                                   let summary = document.events[turn].turnSummary {
                                    Text(summary).font(.caption).foregroundStyle(ChatColors.muted)
                                }
                            }.id(event.id)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }.onChange(of: visibleCount) { _, count in
                    if playing, !full, count > 0 { reader.scrollTo(document.events[count - 1].id, anchor: .bottom) }
                }
            }
            dock
        }.background(ChatColors.canvas.ignoresSafeArea()).foregroundStyle(ChatColors.ink)
        #if os(macOS)
        .sheet(item: $activePicture) { picture($0) }
        #else
        .fullScreenCover(item: $activePicture) { picture($0) }
        #endif
        .task(id: playing && !full && scene == .active && activePicture == nil) {
            guard playing, !full, scene == .active, activePicture == nil else { return }
            let clock = ContinuousClock()
            var previous = clock.now
            while !Task.isCancelled && elapsed < end {
                do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
                let now = clock.now
                let delta = previous.duration(to: now).components
                elapsed = min(end, elapsed + (Double(delta.seconds) + Double(delta.attoseconds) / 1e18) * Double(speed))
                previous = now
            }
            if !Task.isCancelled { playing = false }
        }
        .tint(palette.color(hue: hue))
    }

    /// Everything shows: the end of the replay (「全文」 or played through).
    private var full: Bool { elapsed >= end }

    /// Back, the title capsule with 「10 月 24 日 · 12 分钟 · 第 2–3 轮」, 「全文」; under them the transport.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ChatIcon(label: String(localized: "返回"), symbol: "chevron.left") { dismiss() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: document.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption2.monospacedDigit()).foregroundStyle(ChatColors.muted).lineLimit(1)
                    }
                }.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).chatCapsule()
                    .accessibilityElement(children: .combine).accessibilityIdentifier("replayTitle")
                ChatIcon(label: String(localized: "全文"), symbol: "doc.plaintext") { elapsed = end; playing = false }
                    .disabled(full && !playing).opacity(full && !playing ? 0.45 : 1)
            }
            transport
        }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    /// The goal and todo bars, then 「接着聊」.
    @ViewBuilder private var dock: some View {
        let current: (tasks: Int?, goal: Int?) = visibleCount > 0 ? status[visibleCount - 1] : (nil, nil)
        if current.goal != nil || current.tasks != nil || continueChat != nil {
            VStack(spacing: 8) {
                if let goal = current.goal {
                    let event = document.events[goal]
                    Label(event.text, systemImage: event.phase == "complete" ? "checkmark.circle" : event.phase == "paused" ? "pause.circle" : "scope")
                        .lineLimit(2).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10).chatCapsule()
                        .accessibilityLabel(String(localized: "目标，") + event.text)
                }
                if let tasks = current.tasks {
                    let items = document.events[tasks].tasks
                    DisclosureGroup("待办 · \(items.filter { $0.status == "completed" }.count)/\(items.count)", isExpanded: $tasksOpen) {
                        ViewThatFits(in: .vertical) {
                            taskList(items)
                            ScrollView { taskList(items) }
                        }.frame(maxHeight: 170)
                    }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(ChatColors.line, lineWidth: 0.6))
                }
                if let continueChat {
                    Button { continueChat(document.markdown) } label: {
                        Text("接着聊").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 34)
                    }.prominentButton().buttonBorderShape(.capsule).controlSize(.large)
                }
            }.padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
        }
    }

    /// 「10 月 24 日 · 12 分钟」, and the rounds of a part.
    private var subtitle: String {
        var parts: [String] = []
        if let start = document.start {
            let day = Calendar.current.dateComponents([.month, .day], from: start)
            parts.append(String(localized: "\(day.month ?? 1)月\(day.day ?? 1)日"))
        }
        if document.timed, document.span >= 1000 { parts.append(Self.span(Double(document.span) / 1000)) }
        if let range = document.range {
            parts.append(range.from == range.to ? String(localized: "第 \(range.from) 轮") : String(localized: "第 \(range.from)–\(range.to) 轮"))
        }
        return parts.joined(separator: " · ")
    }

    /// 「12 秒」「12 分钟」「1 小时 5 分钟」.
    static func span(_ seconds: Double) -> String {
        if seconds < 60 { return String(localized: "\(max(1, Int(seconds))) 秒") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "\(minutes) 分钟") }
        let rest = minutes % 60
        return rest == 0 ? String(localized: "\(minutes / 60) 小时") : String(localized: "\(minutes / 60) 小时 \(rest) 分")
    }

    private func taskList(_ items: [(text: String, status: String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                Label(items[i].text, systemImage: items[i].status == "completed" ? "checkmark.circle.fill" : items[i].status == "in_progress" ? "circle.dotted" : "circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button {
                if elapsed >= end { elapsed = 0; playing = true } else { playing.toggle() }
            } label: {
                Image(systemName: elapsed >= end ? "arrow.counterclockwise" : playing ? "pause.fill" : "play.fill").frame(width: 32, height: 36)
            }.accessibilityLabel(elapsed >= end ? "重新播放" : playing ? "暂停" : "播放")
            Slider(value: $elapsed, in: 0...end, onEditingChanged: { moving in if moving { playing = false } })
                .accessibilityLabel("回放进度")
            Text(Self.time(elapsed) + " / " + Self.time(end)).accessibilityIdentifier("replayClock").font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted)
            Button("\(speed)×") { speed = speed == 4 ? 1 : speed * 2 }.font(.subheadline.bold().monospacedDigit()).frame(minWidth: 35, minHeight: 36)
                .accessibilityHint("倍速 \(speed)×")
        }.buttonStyle(.plain).padding(.horizontal, 9).frame(minHeight: 44).chatCapsule()
    }

    private static func time(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder private func row(_ event: ReplayEvent, span: ReplayTiming.Span, turnComplete: Bool) -> some View {
        switch event.kind {
        case "turn", "todos", "goal":
            EmptyView()
        case "user":
            pictures(event).frame(maxWidth: .infinity, alignment: .trailing)
            if !event.text.isEmpty {
                ChatQuestion(text: event.text, font: typeSize.font).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !event.detail.isEmpty { Label(event.detail, systemImage: "paperclip").font(.caption).frame(maxWidth: .infinity, alignment: .trailing) }
        case "reply":
            if !event.detail.isEmpty {
                let live = !full && elapsed < span.answer
                let fraction = min(1, max(0, (elapsed - span.start) / max(0.001, span.answer - span.start)))
                let thinking = live ? String(event.detail.prefix(Int(Double(event.detail.count) * fraction))) + "▍" : event.detail
                ChatStepsView(thinking: thinking, steps: [], live: live).id(turnComplete)
            }
            if !event.text.isEmpty, full || elapsed >= span.answer {
                ChatAnswer(text: revealed(event, span: span), font: typeSize.font).textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                    })
            }
            pictures(event)
        case "tool":
            if let tool = event.tool {
                let running = !full && elapsed < span.end
                ToolDetails(step: presented(tool, running: running), live: running, title: event.text).id(turnComplete).chatCard()
                if !running { pictures(event) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label(event.label, systemImage: event.kind == "command" ? "terminal" : "info.circle").font(.caption).foregroundStyle(ChatColors.muted)
                Text(verbatim: event.text).font(typeSize.font)
                if !event.detail.isEmpty { DisclosureGroup("详情") { Text(verbatim: event.detail).textSelection(.enabled) } }
            }.chatCard()
        }
    }

    private func presented(_ tool: ChatStep, running: Bool) -> ChatStep {
        guard running else { return tool }
        var copy = tool; copy.state = "running"; copy.result = ""
        return copy
    }

    @ViewBuilder private func pictures(_ event: ReplayEvent) -> some View {
        ForEach(Array(event.imageIDs.enumerated()), id: \.offset) { _, id in
            if let bytes = document.images[id] {
                ReplayThumbnail(id: id, bytes: bytes) { activePicture = ReplayPictureID(id: id) }
            } else {
                Label("图片不可用", systemImage: "photo").font(.caption).foregroundStyle(ChatColors.muted)
            }
        }
    }

    private func revealed(_ event: ReplayEvent, span: ReplayTiming.Span) -> String {
        guard !full, elapsed < span.end else { return event.text }
        let progress = min(1, max(0, (elapsed - span.answer) / max(0.001, span.end - span.answer)))
        return String(event.text.prefix(Int(Double(event.text.count) * progress))) + "▍"
    }

    private var visibleCount: Int {
        if full { return starts.count }
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= elapsed { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

private struct ReplayPictureID: Identifiable, Equatable { let id: String }

private struct ReplayThumbnail: View {
    let id: String
    let bytes: Data
    let open: () -> Void
    @State private var thumbnail: PlatformImage?
    var body: some View {
        Button(action: open) {
            if let thumbnail {
                Image(platformImage: thumbnail).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else { Image(systemName: "photo") }
        }.buttonStyle(.plain).accessibilityLabel("回放图片")
            .task(id: id) { thumbnail = await HostImage.thumbnail(bytes, maxPixels: 800) }
    }
}
