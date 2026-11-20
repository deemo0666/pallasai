import SwiftUI

private struct FirstMessageFrame: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

private struct HistoryEnd: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// One row of the host message stream.
private indirect enum StreamItem: Identifiable {
    case user(Message)
    /// A reply; [thinking] / [text] say which half is shown (a folded turn keeps the thinking in its process).
    case assistant(Message, thinking: Bool, text: Bool, actions: Bool, footnote: TurnTrace?)
    case tool(ToolEntry)
    case group([ToolEntry], live: Bool)
    case notice(Message)
    case process(TurnTrace, [StreamItem], label: String, cut: Int?)
    case footnote(TurnTrace)
    case changes([TurnFileChange], anchor: String)
    case files([HostDeliverable], turn: Int)
    case interaction(Object)

    var id: String {
        switch self {
        case .user(let m): "u" + m.id.uuidString
        case .assistant(let m, let thinking, let text, _, _): "a" + m.id.uuidString + (thinking && !text ? "#r" : "")
        case .tool(let entry): "t" + entry.id.uuidString
        case .group(let entries, _): "g" + (entries.first?.id.uuidString ?? "")
        case .notice(let m): "n" + m.id.uuidString
        case .process(let trace, _, _, let cut): "p\(trace.startSeq)" + (cut.map { "@\($0)" } ?? "")
        case .footnote(let trace): "f\(trace.startSeq)"
        case .changes(_, let anchor): "c" + anchor
        case .files(_, let turn): "d\(turn)"
        case .interaction(let event): "i" + (event["eventId"] as? String ?? "")
        }
    }

    var isUser: Bool { if case .user = self { return true }; return false }

    /// Quiet process rows sit flush against each other.
    var isProcess: Bool {
        switch self {
        case .tool, .group: return true
        case .assistant(let m, let thinking, let text, _, _):
            return thinking && (!text || m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .notice(let m): return m.notice?.kind != "error" && m.notice?.kind != "late"
        default: return false
        }
    }

    var isCard: Bool {
        switch self { case .changes, .files, .interaction: true; default: false }
    }

    /// 换轮 24、同一轮 8、相邻过程行 0、卡片 12、脚注 4.
    func gap(after previous: StreamItem?) -> CGFloat {
        guard let previous else { return 0 }
        if isUser { return previous.isUser ? 8 : 24 }
        if isProcess && previous.isProcess { return 0 }
        if isCard { return 12 }
        if case .footnote = self { return 4 }
        return 8
    }
}

/// One file changed in a turn: every successful edit of it, merged.
struct TurnFileChange: Identifiable {
    let path: String
    var created: Bool
    var added = 0
    var removed = 0
    var edits = 0
    var changes: [ToolFileChange] = []
    /// Written whole by an Office tool: no lines to count or compare.
    var whole = false
    var id: String { path }

    static func collect(_ entries: [ToolEntry]) -> [TurnFileChange] {
        var order: [String] = [], files: [String: TurnFileChange] = [:]
        for entry in entries where entry.status == .succeeded && entry.step.kind == .edit {
            var touched = Set<String>()
            for change in entry.step.fileChanges {
                let key = change.path
                if files[key] == nil {
                    order.append(key)
                    files[key] = TurnFileChange(path: key, created: change.before == nil && (entry.step.name == "write" || entry.step.arg("command") == "create"))
                }
                let stats = change.stats
                files[key]?.changes.append(change)
                files[key]?.added += stats.added
                files[key]?.removed += stats.removed
                if touched.insert(key).inserted { files[key]?.edits += 1 }
            }
        }
        // Office documents are written whole by their own tools, with no text diff: listed as new or changed, no line counts.
        for entry in entries where entry.status == .succeeded {
            guard let kind = officeTools[entry.step.name], let path = entry.step.arg("path"), !path.isEmpty else { continue }
            if files[path] == nil {
                order.append(path)
                files[path] = TurnFileChange(path: path, created: kind == .created && entry.step.args?["overwrite"] as? Bool != true, whole: true)
            }
            files[path]?.edits += 1
        }
        return order.compactMap { files[$0] }
    }

    private enum OfficeWrite { case created, updated }
    private static let officeTools: [String: OfficeWrite] = [
        "word_create": .created, "excel_create": .created, "ppt_create": .created,
        "word_update": .updated, "excel_update": .updated, "ppt_update": .updated,
    ]

    func shownPath(_ workspace: String) -> String { ChatStep.displayPath(path, workspace: workspace) }
    func fileName(_ workspace: String) -> String { (shownPath(workspace) as NSString).lastPathComponent }
    func directory(_ workspace: String) -> String {
        let shown = shownPath(workspace)
        guard let slash = shown.lastIndex(of: "/"), slash > shown.startIndex else { return "" }
        return String(shown[..<slash])
    }

    /// Unified diff for 复制补丁 (unknown line numbers start at 1).
    func patch(_ workspace: String) -> String {
        let shown = shownPath(workspace)
        if whole { return "Binary files " + (created ? "/dev/null" : "a/" + shown) + " and b/" + shown + " differ\n" }
        var out = [created ? "--- /dev/null" : "--- a/" + shown, "+++ b/" + shown]
        for change in changes {
            let lines = change.displayLines
            let old = lines.filter { $0.prefix != "+" }.count, new = lines.filter { $0.prefix != "−" }.count
            out.append("@@ -\(old == 0 ? 0 : 1),\(old) +\(new == 0 ? 0 : 1),\(new) @@")
            out += lines.map { ($0.prefix == "−" ? "-" : $0.prefix) + $0.text }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

private struct SheetTarget: Identifiable { let id: Int }

/// Where a failed turn's button leads: the DeepSeek account (top up, sign in) or the saved API keys.
#if os(iOS)
private enum NoticeDestination: String, Identifiable {
    case account, apiKeys
    var id: String { rawValue }
}
#endif

struct HostMessageHistory: View {
    @ObservedObject var chat: Conversation
    let font: Font
    let share: (UUID) -> Void
    @AppStorage("collapseChatSteps") private var foldTurns = true
    @State private var firstFrame = CGRect.null
    @State private var anchor: (id: String, point: UnitPoint)?
    @State private var following = true
    @State private var nearEnd = true
    @State private var unseen = false
    @State private var topVisible = false
    @State private var trajectory: SheetTarget?
    #if os(iOS)
    @State private var destination: NoticeDestination?
    #endif
    /// 哪些行是打开后才来的：只有它们播进场动画。
    @State private var ledger = EntranceLedger()
    @State private var probe = ScrollProbe()
    @Environment(\.scenePhase) private var scenePhase
    /// 逐字显现推进时跟随到底部用。
    @State private var proxy: ScrollViewProxy?

    private func action(_ kind: Conversation.BranchAction, _ row: Message) -> (() -> Void)? {
        guard chat.canBranch(kind, at: row) else { return nil }
        return { Task { await chat.branch(kind, at: row) } }
    }

    // MARK: Rows

    /// Rows from events: turns, tool groups, folded processes, footnotes, change cards, cards.
    private func derive() -> [StreamItem] {
        let traces = chat.traces
        let messages = chat.messages
        let running = chat.phase == .replying
        let approvals = chat.interactions.filter { $0["event"] as? String == "approval/request" }
        var byCall: [String: Object] = [:]
        for item in approvals { if let call = (item["request"] as? Object)?["callId"] as? String { byCall[call] = item } }
        let deliverables = Dictionary(grouping: chat.deliverables, by: \.turn)
        var attached = Set<String>(), shownFiles = Set<Int>()

        var rows: [StreamItem] = []
        var tools: [ToolEntry] = []
        var pieceStart: Int?
        var pieceEnd = 0
        var lastText: Int?
        var turn: TurnTrace?
        var turnNumber: Int?
        var turnTools: [ToolEntry] = []
        var cursor = 0

        func turnAt(_ seq: Int) -> TurnTrace? {
            guard !traces.isEmpty else { return nil }
            while cursor + 1 < traces.count && traces[cursor + 1].startSeq <= seq { cursor += 1 }
            while cursor > 0 && traces[cursor].startSeq > seq { cursor -= 1 }
            let trace = traces[cursor]
            return trace.contains(seq) ? trace : nil
        }

        func flushTools(live: Bool = false) {
            guard !tools.isEmpty else { return }
            if pieceStart == nil { pieceStart = rows.count }
            if tools.count >= 3 { rows.append(.group(tools, live: live)) } else { rows += tools.map { .tool($0) } }
            tools = []
            pieceEnd = rows.count
        }

        func fold(_ trace: TurnTrace, reply: Int?, cut: Int?) -> Int? {
            guard let start = pieceStart else { return reply }
            func text(_ m: Message) -> Bool { !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let hasFinal = rows[start..<pieceEnd].contains { row in
                if case .assistant(let m, _, _, _, _) = row { return m.finalAnswer && text(m) }
                return false
            }
            var answer = hasFinal ? nil : reply
            if let a = answer, a + 1 < pieceEnd {
                for i in (a + 1)..<pieceEnd {
                    switch rows[i] { case .tool, .group, .assistant: answer = nil; default: break }
                    if answer == nil { break }
                }
            }
            let end = answer ?? pieceEnd
            var process: [StreamItem] = [], kept: [StreamItem] = []
            var keptAnswer: Int?
            var toolCalls = 0, replies = 0
            var worked: [ToolEntry] = []
            for i in start..<end {
                switch rows[i] {
                case .tool(let entry): toolCalls += 1; worked.append(entry); process.append(rows[i])
                case .group(let entries, _): toolCalls += entries.count; worked += entries; process.append(rows[i])
                case .assistant(let m, _, _, _, _) where m.finalAnswer && text(m):
                    if !m.thinking.isEmpty { process.append(.assistant(m, thinking: true, text: false, actions: false, footnote: nil)) }
                    keptAnswer = kept.count
                    kept.append(.assistant(m, thinking: false, text: true, actions: false, footnote: nil))
                case .assistant(let m, _, _, _, _):
                    if text(m) { replies += 1 }
                    process.append(rows[i])
                case .notice: process.append(rows[i])
                default: kept.append(rows[i])
                }
            }
            var answerRow: StreamItem? = answer.map { rows[$0] }
            if case .assistant(let m, _, _, _, _)? = answerRow, !m.thinking.isEmpty {
                process.append(.assistant(m, thinking: true, text: false, actions: false, footnote: nil))
                answerRow = .assistant(m, thinking: false, text: true, actions: false, footnote: nil)
            }
            if toolCalls == 0 && replies == 0 && process.count <= 1 { return reply }
            let thoughts = process.filter { if case .assistant(let m, true, _, _, _) = $0 { return !m.thinking.isEmpty }; return false }.count
            // What was done, not how many calls it took: 「已完成 · 操作手机 6 步 · 改了 2 个文件」.
            var parts = [String(localized: "已完成")]
            if toolCalls > 0 {
                let done = ToolSummary.parts(worked)
                parts += done.isEmpty ? [String(localized: "做了 \(toolCalls) 步操作")] : Array(done.prefix(3))
            } else if replies > 0 { parts.append(String(localized: "说明了 \(replies) 次")) }
            else if thoughts > 0 { parts.append(String(localized: "思考了 \(thoughts) 次")) }
            var replacement: [StreamItem] = [.process(trace, process, label: parts.joined(separator: " · "), cut: cut)] + kept
            if let answerRow { replacement.append(answerRow) }
            let removed = (answer.map { $0 + 1 } ?? end) - start
            rows.replaceSubrange(start..<(start + removed), with: replacement)
            pieceEnd += replacement.count - removed
            if answerRow != nil { return start + replacement.count - 1 }
            return keptAnswer.map { start + 1 + $0 }
        }

        func close(cut: Int? = nil) {
            flushTools()
            let last = cut == nil
            let done = turn.flatMap { !$0.running && $0.endSeq != nil ? $0 : nil }
            var index = lastText
            if foldTurns, let done, pieceStart != nil, done.completed { index = fold(done, reply: index, cut: cut) }
            let footnote = last ? done : nil
            if let index, case .assistant(let m, let thinking, let text, _, _) = rows[index] {
                rows[index] = .assistant(m, thinking: thinking, text: text, actions: true, footnote: footnote)
            } else if let footnote, !rows.isEmpty {
                rows.insert(.footnote(footnote), at: pieceEnd); pieceEnd += 1
            }
            lastText = nil
            pieceStart = nil
            guard last else { return }
            let files = TurnFileChange.collect(turnTools)
            if !files.isEmpty {
                let anchor = turnTools.first { $0.step.kind == .edit }?.step.id ?? "\(pieceEnd)"
                rows.insert(.changes(files, anchor: anchor), at: pieceEnd); pieceEnd += 1
            }
            if let number = turn?.turn ?? turnNumber, !shownFiles.contains(number), let cards = deliverables[number], !cards.isEmpty {
                shownFiles.insert(number)
                rows.insert(.files(cards, turn: number), at: pieceEnd); pieceEnd += 1
            }
            turnTools = []
            turnNumber = nil
            pieceEnd = rows.count
        }

        for (i, m) in messages.enumerated() {
            if let seq = m.sequence {
                let owner = turnAt(seq)
                if owner?.startSeq != turn?.startSeq {
                    close()
                    turn = owner
                }
            }
            if let number = m.turn { turnNumber = number }
            if let step = m.tool {
                var approval: Object?
                if let pending = byCall[Conversation.callID(of: step)] {
                    approval = pending
                    if let id = pending["eventId"] as? String { attached.insert(id) }
                }
                let entry = ToolEntry(id: m.id, step: step, status: chat.toolStatus(step, turn: m.turn), approval: approval)
                tools.append(entry)
                turnTools.append(entry)
            } else if m.outgoing {
                if let current = turn, m.sequence != nil || current.running {
                    close(cut: m.sequence ?? Int.max)
                } else {
                    close()
                    if m.sequence == nil { turn = nil }
                }
                rows.append(.user(m))
                pieceEnd = rows.count
            } else if let notice = m.notice {
                flushTools()
                // Stands where the person's message would: before the turn, outside what folds.
                if notice.kind == "late" { rows.append(.notice(m)); pieceEnd = rows.count; continue }
                if notice.kind == "aborted", i > 0, messages[i - 1].interrupted { continue }
                if pieceStart == nil { pieceStart = rows.count }
                rows.append(.notice(m))
                pieceEnd = rows.count
            } else {
                flushTools()
                if pieceStart == nil { pieceStart = rows.count }
                rows.append(.assistant(m, thinking: true, text: true, actions: false, footnote: nil))
                if !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = rows.count - 1 }
                pieceEnd = rows.count
            }
        }
        if running { flushTools(live: true) } else { close() }
        for item in approvals where !attached.contains(item["eventId"] as? String ?? "") { rows.append(.interaction(item)) }
        for item in chat.interactions where item["event"] as? String == "user-questions/request" { rows.append(.interaction(item)) }
        return rows
    }

    // MARK: Body

    private struct Placed: Identifiable {
        let item: StreamItem
        let gap: CGFloat
        let first: Bool
        let index: Int
        var id: String { item.id }
    }

    private static func positioned(_ rows: [StreamItem]) -> [Placed] {
        rows.indices.map { Placed(item: rows[$0], gap: rows[$0].gap(after: $0 > 0 ? rows[$0 - 1] : nil), first: $0 == 0, index: $0) }
    }

    /// 回复还没来第一个字：最后一行是刚发出的提问。
    private func waiting(_ rows: [StreamItem]) -> Bool {
        guard chat.phase == .replying, !chat.preparingPhoneCommand, case .user? = rows.last else { return false }
        return true
    }

    /// To the end of the list, unless it all fits on screen: scrolling short content to the bottom pulls it
    /// past the top bar and it springs back, so every streamed word made a new conversation shake.
    private func toLatest(_ reader: ScrollViewProxy) {
        guard !probe.fits else { return }
        reader.scrollTo("latest", anchor: .bottom)
    }

    private func follow(animated: Bool) {
        guard following, let proxy, !probe.fits else { return }
        if animated && !Motion.reduced {
            withAnimation(Motion.std(Motion.standard)) { proxy.scrollTo("latest", anchor: .bottom) }
        } else {
            proxy.scrollTo("latest", anchor: .bottom)
        }
    }

    var body: some View {
        let rows = derive()
        let pending = Set(rows.compactMap { row -> String? in
            if case .user(let m) = row, m.sequence == nil { return row.id }
            return nil
        })
        // A reload (reconnect, back from the background) rebuilds every row with new ids: count it as a fresh open.
        let reloaded = ledger.prime(rows.map(\.id), pending: pending,
                                    session: chat.connection.map { $0.sessionID + "#" + $0.sessionGeneration.uuidString })
        let _ = reloaded ? UITrace.note("history baseline rows=\(rows.count) messages=\(chat.messages.count) session=\(Log.session(chat.connection?.sessionID)) generation=\(chat.connection?.sessionGeneration.uuidString.prefix(8) ?? "-")") : ()
        let waitingForReply = waiting(rows)
        GeometryReader { viewport in
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if chat.hasOlder || chat.loadingOlder {
                            Group {
                                if chat.loadingOlder { ProgressView().controlSize(.small) } else { Color.clear }
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .onAppear { topVisible = true; autoLoad(rows, viewport: viewport.size) }
                            .onDisappear { topVisible = false }
                            .accessibilityLabel(chat.loadingOlder ? "正在加载更早消息" : "")
                        }
                        ForEach(Self.positioned(rows)) { placed in
                            rowView(placed.item)
                                .modifier(StreamEntrance(play: ledger.play(placed.id, index: placed.index, count: rows.count),
                                                         rise: placed.item.isUser))
                                .padding(.top, placed.gap)
                                .background {
                                    if placed.first {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: FirstMessageFrame.self, value: geometry.frame(in: .named("hostHistory")))
                                        }
                                    }
                                }
                                .id(placed.id)
                        }
                        if waitingForReply {
                            TypingDots().padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.asymmetric(insertion: .opacity.animation(Motion.std(Motion.quick)),
                                                        removal: .opacity.animation(.linear(duration: 0.09))))
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .animation(.linear(duration: 0.09), value: waitingForReply)
                    .padding()
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: HistoryEnd.self, value: geometry.frame(in: .named("hostHistory")).maxY)
                        }
                    }
                }
                .coordinateSpace(name: "hostHistory")
                .accessibilityIdentifier("hostHistory")
                .modifier(StartAtEnd())
                .onAppear {
                    proxy = reader
                    // A lazy list settles its row heights after the first scroll: follow once more.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if following { toLatest(reader) }
                    }
                }
                .modifier(HistoryTracking(following: $following, nearEnd: $nearEnd, height: viewport.size.height) { anchor = nil })
                .modifier(ScrollProbing(probe: probe))
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // Once layout has settled after coming back: what the list holds and where it is scrolled.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        UITrace.note("history on return rows=\(derive().count) messages=\(chat.messages.count) chat=\(chat.phase) following=\(following) nearEnd=\(nearEnd) \(probe.summary) viewport \(Int(viewport.size.height))")
                    }
                }
                .onPreferenceChange(FirstMessageFrame.self) { firstFrame = $0 }
                .onChange(of: rows.first?.id) { _, _ in
                    if let anchor {
                        reader.scrollTo(anchor.id, anchor: anchor.point)
                        self.anchor = nil
                    } else if following { toLatest(reader) }
                }
                .onChange(of: chat.messages.last?.id, initial: true) { old, id in
                    // A new row glides into view; the first layout just lands at the end.
                    if following && id != nil {
                        if old == nil { toLatest(reader) } else { follow(animated: true) }
                    } else if id != nil { unseen = true }
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    if following { toLatest(reader) } else { unseen = true }
                }
                .onChange(of: chat.phase) { _, _ in
                    if following { toLatest(reader) }
                }
                .onChange(of: chat.interactions.count) { _, _ in
                    if following { toLatest(reader) }
                }
                // Rotation and the keyboard resize the list; the latest reply must not end up behind the composer.
                .onChange(of: viewport.size) { _, _ in
                    guard following || nearEnd else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        toLatest(reader)
                    }
                }
                .onChange(of: following) { _, value in
                    if value { unseen = false } else { autoLoad(rows, viewport: viewport.size) }
                }
                .onChange(of: chat.loadingOlder) { _, loading in
                    if !loading { autoLoad(rows, viewport: viewport.size) }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Pops in from 0.6× on a spring, leaves in 160ms.
                    ZStack {
                        if !following && !nearEnd {
                            JumpToBottom(waiting: chat.interactions.count, unseen: unseen) {
                                following = true
                                unseen = false
                                withAnimation(Motion.std(Motion.emphasized)) { reader.scrollTo("latest", anchor: .bottom) }
                            }.padding(12)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                                    removal: .scale(scale: 0.8).combined(with: .opacity).animation(Motion.enter(Motion.quick))))
                        }
                    }.animation(Motion.popSpring, value: !following && !nearEnd)
                }
                .overlay(alignment: .bottom) {
                    if let toast = chat.forkToast {
                        ForkToast(text: toast, parent: chat.forkParent, chat: chat).padding(.bottom, 12).padding(.horizontal, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: chat.forkToast)
                .sheet(item: $trajectory) { target in
                    TrajectorySheet(chat: chat, startSeq: target.id)
                        .presentationDetents([.medium, .large])
                        .desktopSheet(width: 540, height: 460)
                }
                #if os(iOS)
                .sheet(item: $destination) { target in
                    NavigationStack {
                        Group {
                            switch target {
                            case .account: DeepSeekAccountPage()
                            case .apiKeys: ThirdPartyListPage()
                            }
                        }
                        .inlineNavigationTitle()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { destination = nil } } }
                    }
                }
                #endif
            }
        }
    }

    /// Older messages load when the top comes into view (after the person scrolled, or when everything fits).
    private func autoLoad(_ rows: [StreamItem], viewport: CGSize) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard topVisible, !following || nearEnd, chat.hasOlder, !chat.loadingOlder else { return }
            if let first = rows.first, !firstFrame.isNull {
                let span = viewport.height - firstFrame.height
                let y = abs(span) > 1 ? firstFrame.minY / span : 0
                anchor = (first.id, UnitPoint(x: 0.5, y: y))
            }
            let first = chat.messages.first?.id
            await chat.loadOlder()
            if first == chat.messages.first?.id { anchor = nil }
        }
    }

    // MARK: Row views

    private func rowView(_ row: StreamItem) -> AnyView {
        switch row {
        case .user(let m): return AnyView(userRow(m))
        case .assistant(let m, let thinking, let text, let actions, let footnote):
            return AnyView(assistantRow(m, thinking: thinking, text: text, actions: actions, footnote: footnote))
        case .tool(let entry):
            return AnyView(ToolRowView(step: entry.step, status: entry.status, workspace: chat.workspace, host: chat.connection, chat: chat, approval: entry.approval))
        case .group(let entries, let live):
            return AnyView(ToolGroupView(entries: entries, live: live, workspace: chat.workspace, host: chat.connection, chat: chat))
        case .notice(let m):
            return AnyView(NoticeRowView(notice: m.notice ?? TurnNotice(kind: "error"), action: noticeAction(m)))
        case .process(_, let items, let label, _):
            return AnyView(TurnProcessView(label: label) {
                ForEach(items.indices, id: \.self) { i in
                    rowView(items[i]).padding(.top, items[i].gap(after: i > 0 ? items[i - 1] : nil))
                }
            })
        case .footnote(let trace):
            return AnyView(HStack { Spacer(); TurnFootnote(trace: trace) { trajectory = SheetTarget(id: trace.startSeq) } })
        case .changes(let files, _):
            return AnyView(ChangeCardView(files: files, workspace: chat.workspace))
        case .files(let files, _):
            if let host = chat.connection { return AnyView(HostTurnFiles(host: host, files: files)) }
            return AnyView(EmptyView())
        case .interaction(let event):
            return AnyView(HostInteractionView(event: event, chat: chat).id(event["eventId"] as? String))
        }
    }

    @ViewBuilder private func userRow(_ m: Message) -> some View {
        let pending = m.sequence == nil && !chat.botSession
        VStack(alignment: .trailing, spacing: 6) {
            if let host = chat.connection, !m.images.isEmpty {
                if m.images.count > 1 {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(DraftImageStack.side), spacing: 6), count: min(3, m.images.count)), alignment: .trailing, spacing: 6) {
                        HostImageGallery(host: host, images: m.images, square: DraftImageStack.side)
                    }.fixedSize()
                } else { HostImageGallery(host: host, images: m.images) }
            } else if !m.drafts.isEmpty {
                DraftImageStack(images: m.drafts.filter(\.isImage))
            }
            ForEach(m.files.indices, id: \.self) { FileAttachmentCard(name: m.files[$0]) }
            if !m.bubbleText.isEmpty {
                MessageBubble(text: m.bubbleText, outgoing: true, font: font,
                              share: { share(m.id) }, quote: { chat.draft = MessageBubble.quoting(m.bubbleText, in: chat.draft) },
                              edit: action(.edit, m))
            }
            if m.failed {
                HStack(spacing: 4) {
                    Label("未送达 · 已保留", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(ChatColors.muted)
                    Button("编辑后重发") { chat.editFailed(m.id) }.font(.caption.weight(.semibold))
                }.padding(.trailing, 8)
            } else if pending {
                Label(m.steering ? "插话中" : "发送中", systemImage: "clock").font(.caption).foregroundStyle(ChatColors.muted)
                    .padding(.trailing, 8)
                    .transition(.reveal(Motion.standard))
            }
        }
        .opacity(pending && !m.failed ? 0.72 : 1)
        .animation(Motion.std(Motion.quick), value: pending)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private func assistantRow(_ m: Message, thinking: Bool, text: Bool, actions: Bool, footnote: TurnTrace?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if thinking && !m.thinking.isEmpty {
                ThinkingRow(text: m.thinking, active: m.sequence == nil && chat.phase == .replying && m.text.isEmpty)
            }
            if text {
                if let host = chat.connection, !m.images.isEmpty {
                    HostImageGallery(host: host, images: m.images).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !m.text.isEmpty {
                    MessageBubble(text: m.text, outgoing: false, font: font,
                                  share: { share(m.id) }, quote: { chat.draft = MessageBubble.quoting(m.text, in: chat.draft) },
                                  fork: action(.fork, m), retry: action(.retry, m),
                                  showActions: actions,
                                  footnote: footnote.map { trace in AnyView(TurnFootnote(trace: trace) { trajectory = SheetTarget(id: trace.startSeq) }) },
                                  interrupted: m.interrupted, busy: chat.forking,
                                  live: m.sequence == nil && chat.phase == .replying,
                                  onReveal: { follow(animated: false) })
                }
            }
        }
    }

    /// The next step on the last notice of a finished turn: 「压缩对话」「去充值」「去登录」「去设置」, else 「重试」 or 「继续」.
    private func noticeAction(_ notice: Message) -> (label: String, run: () -> Void)? {
        guard chat.phase == .ready, !chat.forking, let kind = notice.notice?.kind else { return nil }
        let code = notice.notice?.code ?? ""
        let messages = chat.messages
        guard let at = messages.lastIndex(where: { $0.id == notice.id }),
              messages[(at + 1)...].allSatisfy({ $0.notice?.kind == "retry" }) else { return nil }
        // The account and the saved keys are this iPhone's; a computer keeps its own.
        if kind == "error" {
            switch code {
            case "CONTEXT_WINDOW_EXCEEDED":
                return (String(localized: "压缩对话"), { compact() })
            #if os(iOS)
            case "QUOTA", "ACCOUNT_QUOTA":
                guard let host = chat.connection, EmbeddedEngine.shared.owns(host), DeepSeekAccount.shared.signedIn else { return nil }
                return (String(localized: "去充值"), { destination = .account })
            case "AUTH", "INVALID_CREDENTIAL", "MISSING_CREDENTIAL":
                guard let host = chat.connection, EmbeddedEngine.shared.owns(host) else { return nil }
                let ownKey = notice.notice?.message?.hasPrefix("llm-pi-ai") == true
                    || (!DeepSeekAccount.shared.signedIn && !ThirdPartyProviders.load().isEmpty)
                if ownKey { return (String(localized: "去设置"), { destination = .apiKeys }) }
                return (DeepSeekAccount.shared.signedIn ? String(localized: "去设置") : String(localized: "去登录"), { destination = .account })
            #endif
            default: break
            }
        }
        let repeatable: Bool
        switch kind {
        case "error":
            repeatable = !["AUTH", "INVALID_CREDENTIAL", "QUOTA", "CLIENT_UPGRADE_REQUIRED", "MODEL_UNSUPPORTED", "UNSUPPORTED_REASONING_EFFORT", "MISSING_CREDENTIAL"].contains(code)
                && !code.hasPrefix("ACCOUNT_")
        case "interrupted", "max-tokens": repeatable = true
        default: repeatable = false
        }
        guard repeatable, !messages.contains(where: { $0.outgoing && $0.sequence == nil }) else { return nil }
        var prompt: Message?
        var worked = false
        var i = at - 1
        while i >= 0 && prompt == nil {
            let item = messages[i]
            if let other = item.notice, other.kind != "retry" { break }
            if item.outgoing { prompt = item } else if item.tool != nil || !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { worked = true }
            i -= 1
        }
        guard let prompt else { return nil }
        if kind == "error", !worked, !prompt.hasAttachment, let text = prompt.prompt, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (String(localized: "重试"), { Task { await chat.send(text) } })
        }
        return (String(localized: "继续"), { Task { await chat.send(String(localized: "继续")) } })
    }

    /// 「压缩对话」: the engine's own compaction, so the person never types a command.
    private func compact() {
        guard let host = chat.connection, !host.sessionID.isEmpty else { return }
        Task {
            do {
                let reply = try await host.rpc("commands/execute", args: ["agentId": host.sessionID, "line": "/compact",
                                                                          "submittedAttachments": [] as [Any]])
                let result = reply["result"] as? Object
                if result?["kind"] as? String == "success" {
                    chat.notice = String(localized: "对话已压缩，可以接着聊。")
                } else {
                    chat.notice = String(localized: "没能压缩对话。可以新开一个对话接着聊。")
                }
            } catch { chat.notice = String(localized: "没能压缩对话。可以新开一个对话接着聊。") }
        }
    }
}

// MARK: - Stream pieces

/// 「回到底部」: a round button with a dot when something new arrived; 「N 项待确认」 while approvals wait.
private struct JumpToBottom: View {
    let waiting: Int
    let unseen: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if waiting > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").foregroundStyle(Color.orange)
                    Text("\(waiting) 项待确认").font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(ChatColors.ink)
                    Image(systemName: "arrow.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(ChatColors.muted)
                }.padding(.horizontal, 16).frame(height: 44).chatCapsule()
            } else {
                Image(systemName: "arrow.down").font(.system(size: 18, weight: .semibold)).foregroundStyle(ChatColors.ink)
                    .frame(width: 44, height: 44).chatCapsule()
                    .overlay(alignment: .topTrailing) {
                        ZStack {
                            if unseen {
                                Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(ChatColors.chip, lineWidth: 1.5)).offset(x: -2, y: 2)
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            }
                        }.animation(Motion.popSpring, value: unseen)
                    }
            }
        }.buttonStyle(.pressable)
            .animation(Motion.std(Motion.quick), value: waiting > 0)
            .accessibilityLabel(waiting > 0 ? "\(waiting) 项待确认，回到底部" : "回到底部")
            .accessibilityIdentifier("回到底部")
    }
}

/// 「已在新对话中继续」 with 返回原对话, after a fork.
private struct ForkToast: View {
    let text: String
    let parent: String?
    @ObservedObject var chat: Conversation
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.subheadline).foregroundStyle(ChatColors.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let parent {
                Button("返回原对话") {
                    chat.dismissForkToast()
                    Task { await chat.openSession(parent) }
                }.font(.subheadline.weight(.semibold))
            }
        }
        .padding(.leading, 16).padding(.trailing, 12).frame(minHeight: 44)
        .chatCapsule()
        .task(id: text) {
            try? await Task.sleep(for: .seconds(5))
            if chat.forkToast == text { chat.dismissForkToast() }
        }
    }
}

/// 「已停止」「余额不足」「对话太长」「出错了，没有完成」… with the next step as a button (重试 / 继续 / 压缩对话 / 去充值 / 去设置).
/// The error code and the service's own wording only show when the row is tapped open.
private struct NoticeRowView: View {
    let notice: TurnNotice
    let action: (label: String, run: () -> Void)?
    @State private var expanded = false

    private static func failureText(_ code: String?) -> String {
        switch code {
        case "AUTH", "INVALID_CREDENTIAL": return String(localized: "API Key 无效或已过期")
        case "QUOTA": return String(localized: "余额不足，充值后再试")
        case "ACCOUNT_QUOTA": return String(localized: "账号额度已用完，充值后再试")
        case "RATE_LIMIT": return String(localized: "请求太频繁，稍后再试")
        case "CONTEXT_WINDOW_EXCEEDED": return String(localized: "对话太长，压缩后再试")
        case "SERVER": return String(localized: "模型服务暂时不可用，稍后再试")
        case "TIMEOUT": return String(localized: "模型太久没有回应，稍后再试")
        case "TRANSPORT": return String(localized: "没能连上模型服务，检查网络后再试")
        case "EMPTY_RESPONSE": return String(localized: "模型没有返回内容")
        case "CLIENT_UPGRADE_REQUIRED": return String(localized: "这个模型需要更新后才能用")
        case "MODEL_UNSUPPORTED": return String(localized: "当前模型不可用，换一个模型再试")
        case "UNSUPPORTED_REASONING_EFFORT": return String(localized: "当前模型不支持这个思考深度，调低一档或换个模型")
        // 手机操控 stopped the turn itself: say why.
        case "PHONE_REPEATED_INVALID_OPEN": return String(localized: "两次都没认出要打开哪个 App，已停止操作手机。说出 App 的名字再试")
        case "PHONE_INVALID_ARGUMENT_STREAM": return String(localized: "这一步手机操作没有生成好，没有执行。再试一次")
        case let value? where value.range(of: #"^HTTP_5\d\d$"#, options: .regularExpression) != nil: return String(localized: "模型服务暂时不可用，稍后再试")
        default: return String(localized: "出错了，没有完成")
        }
    }

    private var content: (icon: String, text: String) {
        switch notice.kind {
        case "error":
            if notice.code == "MISSING_CREDENTIAL" {
                return ("key", notice.message?.hasPrefix("llm-pi-ai") == true ? String(localized: "这个模型服务还没有填 API Key") : String(localized: "还没有登录 DeepSeek 账号"))
            }
            return ("exclamationmark.triangle", Self.failureText(notice.code))
        case "aborted": return ("stop.circle", String(localized: "已停止"))
        case "max-tokens": return ("text.badge.xmark", String(localized: "一次写不完，已停在这里"))
        case "blocked": return ("hand.raised", String(localized: "被安全规则或插件拦下，没有继续。换个说法再试"))
        case "interrupted": return ("arrow.triangle.2.circlepath", String(localized: "中途重启过，这一轮没有做完"))
        case "late": return ("clock.badge.exclamationmark", notice.message ?? "")
        case "retry":
            if let retry = notice.retry {
                return ("arrow.clockwise", notice.maxRetries.map { String(localized: "请求失败，正在重试（\(retry)/\($0)）") } ?? String(localized: "请求失败，正在重试（第 \(retry) 次）"))
            }
            return ("arrow.clockwise", String(localized: "请求失败，正在重试"))
        default: return ("info.circle", notice.message ?? "")
        }
    }

    var body: some View {
        let error = notice.kind == "error"
        let details = error ? [notice.code, notice.message].compactMap { $0 }.joined(separator: "\n") : ""
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: StreamRow.gap) {
                Image(systemName: content.icon).font(.system(size: error ? 12 : 15, weight: error ? .semibold : .regular))
                    .foregroundStyle(error ? Color.red : ChatColors.muted)
                    .frame(width: error ? 22 : 24, height: error ? 22 : 24)
                    .background(error ? Color.red.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(width: StreamRow.lead, height: StreamRow.lead)
                Text(content.text).font(.footnote).foregroundStyle(error ? Color.red : ChatColors.muted)
                    .padding(.top, 3).frame(maxWidth: .infinity, alignment: .leading)
                if let action {
                    Button(action.label, action: action.run).font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4).frame(minHeight: StreamRow.minHeight)
            .contentShape(Rectangle())
            .onTapGesture { if !details.isEmpty { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } }
            if expanded && !details.isEmpty {
                Text(verbatim: details).font(.footnote).foregroundStyle(ChatColors.muted).textSelection(.enabled)
                    .padding(.leading, StreamRow.indent).padding(.bottom, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The quiet per-turn footnote 「47 秒 ›」 (and the spend when a price is known) that opens 本轮过程; steps and usage are in there.
private struct TurnFootnote: View {
    let trace: TurnTrace
    let open: () -> Void
    @AppStorage(ModelPricing.storageKey) private var prices = Data()
    var body: some View {
        let time = trace.duration.map(ChatFormat.span) ?? String(localized: "进行中")
        // Only at a price the person entered; the host reports no spend.
        let cost = trace.cost(ModelPricing.decode(prices)).map { ModelPricing.label($0.amount, currency: $0.currency) }
        let full = [time, cost].compactMap { $0 }.joined(separator: " · ")
        Button(action: open) {
            HStack(spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    Text(full)
                    Text(time)
                }.lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .font(.caption).monospacedDigit().foregroundStyle(ChatColors.muted)
            .padding(.leading, 8).frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(String(localized: "本轮 ") + full + String(localized: "，查看本轮过程"))
    }
}

// MARK: - Change card and diff page

/// 「改了 N 个文件」, up to three file rows, 「看看改了什么 / 还有 N 个文件 ›」. Line counts and the line-by-line view are on the page behind it.
private struct ChangeCardView: View {
    let files: [TurnFileChange]
    let workspace: String
    @State private var open: SheetTarget?

    var body: some View {
        let shown = Array(files.prefix(3))
        let hidden = files.count - shown.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "pencil").font(.system(size: 14, weight: .semibold)).foregroundStyle(ChatColors.muted)
                Text("改了 \(files.count) 个文件").font(.subheadline.weight(.semibold)).foregroundStyle(ChatColors.ink)
                Spacer(minLength: 8)
            }.padding(.horizontal, 14).frame(minHeight: 44)
            ForEach(shown.indices, id: \.self) { index in
                let file = shown[index]
                Button { open = SheetTarget(id: index) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: file.created ? "doc.badge.plus" : "doc.text").font(.system(size: 16))
                            .foregroundStyle(file.created ? Color.green : ChatColors.muted).frame(width: 22)
                        (Text(verbatim: file.fileName(workspace)).foregroundStyle(ChatColors.ink)
                         + Text(file.created ? "  新建" : "").font(.caption).foregroundStyle(Color.green))
                            .font(.subheadline).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                    }.padding(.horizontal, 14).frame(minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .contextMenu { Button { PlatformPasteboard.copy(file.path) } label: { Label("复制文件位置", systemImage: "link") } }
                    .accessibilityLabel(file.created ? "\(file.fileName(workspace))，新建" : file.fileName(workspace))
            }
            Divider().overlay(ChatColors.line)
            Button { open = SheetTarget(id: 0) } label: {
                HStack(spacing: 6) {
                    Text("看看改了什么").font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
                    Spacer(minLength: 8)
                    if hidden > 0 { Text("还有 \(hidden) 个文件").font(.footnote).foregroundStyle(ChatColors.muted) }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(ChatColors.muted)
                }.padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(hidden > 0 ? "看看改了什么，还有 \(hidden) 个文件" : "看看改了什么")
        }
        .background(ChatColors.chip.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.55))
        .sheet(item: $open) { target in
            ChangeDiffPage(files: files, workspace: workspace, index: target.id)
        }
    }
}

/// 「本轮改动」: file chips, swipe between files, wrap toggle, 复制改动内容.
private struct ChangeDiffPage: View {
    let files: [TurnFileChange]
    let workspace: String
    @State var index: Int
    @State private var wrap = ChangeDiffPage.wrapPreference
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss
    @MainActor private static var wrapPreference = true

    var body: some View {
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        NavigationStack {
            VStack(spacing: 0) {
                if files.count > 1 {
                    ScrollViewReader { chips in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(files.indices, id: \.self) { i in
                                    Button { withAnimation { index = i } } label: {
                                        HStack(spacing: 6) {
                                            Text(verbatim: files[i].fileName(workspace)).lineLimit(1)
                                            if !files[i].whole { DiffCountsText(added: files[i].added, removed: files[i].removed) }
                                        }
                                        .font(.footnote).padding(.horizontal, 12).frame(height: 32)
                                        .background(i == index ? Color.accentColor.opacity(0.14) : ChatColors.chip, in: Capsule())
                                        .overlay(Capsule().strokeBorder(i == index ? Color.accentColor.opacity(0.5) : ChatColors.line, lineWidth: 0.6))
                                        .foregroundStyle(ChatColors.ink)
                                    }.buttonStyle(.plain).id(i)
                                }
                            }.padding(.horizontal, 16).padding(.vertical, 8)
                        }.onChange(of: index) { _, value in withAnimation { chips.scrollTo(value, anchor: .center) } }
                    }
                }
                #if os(macOS)
                if files.indices.contains(index) {
                    FileDiffPane(file: files[index], workspace: workspace, wrap: wrap) { copied in show(copied) }
                        .id(index)
                }
                #else
                TabView(selection: $index) {
                    ForEach(files.indices, id: \.self) { i in
                        FileDiffPane(file: files[i], workspace: workspace, wrap: wrap) { copied in show(copied) }.tag(i)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
                #endif
            }
            .background(ChatColors.canvas.ignoresSafeArea())
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .screenLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("返回")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("本轮改动").font(.headline)
                        HStack(spacing: 6) {
                            Text("\(files.count) 个文件").font(.caption).foregroundStyle(ChatColors.muted)
                            if files.contains(where: { !$0.whole }) { DiffCountsText(added: added, removed: removed) }
                        }
                    }
                }
                ToolbarItemGroup(placement: .screenTrailing) {
                    Button { wrap.toggle(); Self.wrapPreference = wrap } label: {
                        Image(systemName: "text.word.spacing").foregroundStyle(wrap ? Color.accentColor : ChatColors.muted)
                    }.accessibilityLabel(wrap ? "不换行" : "自动换行")
                    Button {
                        PlatformPasteboard.copy(files[min(index, files.count - 1)].patch(workspace))
                        show(String(localized: "已复制改动内容"))
                    } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制改动内容")
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.subheadline).padding(.horizontal, 16).frame(height: 40).chatCapsule().padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }.desktopSheet(width: 620, height: 460)
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toast == text { withAnimation { toast = nil } }
        }
    }
}

private struct FileDiffPane: View {
    let file: TurnFileChange
    let workspace: String
    let wrap: Bool
    let notify: (String) -> Void

    private var facts: [String] {
        var facts: [String] = []
        if file.created { facts.append(String(localized: "新建文件")) } else if file.edits > 1 { facts.append(String(localized: "修改 \(file.edits) 次")) }
        return facts
    }

    var body: some View {
        let directory = file.directory(workspace)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: file.fileName(workspace)).font(.headline)
                        if !directory.isEmpty {
                            Text(verbatim: directory).font(.system(size: 12, design: .monospaced)).foregroundStyle(ChatColors.muted)
                        }
                        HStack(spacing: 8) {
                            if !file.whole { DiffCountsText(added: file.added, removed: file.removed) }
                            ForEach(facts, id: \.self) { Text($0).font(.caption).foregroundStyle(ChatColors.muted) }
                        }.padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                    Button {
                        PlatformPasteboard.copy(file.path)
                        notify(String(localized: "已复制文件位置"))
                    } label: { Label("复制文件位置", systemImage: "link").font(.footnote) }
                }
                if file.whole {
                    Text("整份文档重新写过，没有逐行对比").font(.subheadline).foregroundStyle(ChatColors.muted)
                } else if file.changes.allSatisfy({ $0.after.isEmpty && ($0.before ?? "").isEmpty }) {
                    Text("空文件，没有可显示的改动").font(.subheadline).foregroundStyle(ChatColors.muted)
                } else {
                    Group {
                        if wrap {
                            diff
                        } else {
                            ScrollView(.horizontal) { diff }
                        }
                    }
                    .background(ChatColors.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }.padding(16)
        }
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(file.changes.indices, id: \.self) { i in
                if file.changes.count > 1 {
                    Text("第 \(i + 1) 次修改（共 \(file.changes.count) 次）").font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ChatColors.muted).padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        .background(ChatColors.muted.opacity(0.08))
                }
                DiffLinesView(changes: [file.changes[i]], wrap: wrap).padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Turn trajectory

@MainActor private extension TraceSpan {
    /// The tool call this span describes, from the stream when loaded.
    func toolStep(in chat: Conversation) -> ChatStep {
        if let callID, let real = chat.messages.last(where: { $0.tool.map(Conversation.callID) == callID })?.tool { return real }
        return ChatStep(id: "0/\(step)/" + (callID ?? "span\(seq)"), name: toolName ?? "", arguments: arguments ?? "", result: "",
                        state: open ? "running" : failed ? "error" : "ok")
    }

    func label(in chat: Conversation) -> (title: String, detail: String, code: Bool) {
        switch kind {
        case .model:
            let title = open ? String(localized: "思考") : toolCalls == 0 && hasText ? (interrupted ? String(localized: "回复（已中断）") : String(localized: "回复")) : String(localized: "思考")
            return (title, !open && toolCalls > 0 ? String(localized: "接着做 \(toolCalls) 步操作") : "", false)
        case .approval:
            let call = toolStep(in: chat)
            return (open ? String(localized: "等你确认") : String(localized: "等待确认"), (call.verb + " " + call.summary(in: chat.workspace)).trimmingCharacters(in: .whitespaces), false)
        case .question:
            return (open ? String(localized: "等你回答") : String(localized: "等待回答"), toolStep(in: chat).summary(in: chat.workspace), false)
        case .tool:
            let call = toolStep(in: chat)
            return (call.verb, call.summary(in: chat.workspace), call.summaryIsCode)
        }
    }
}

private struct SpanGlyph: View {
    let span: TraceSpan
    var body: some View {
        switch span.kind {
        case .model:
            Image(systemName: span.toolCalls == 0 && span.hasText && !span.open ? "text.bubble" : "atom")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(StreamRow.brand)
                .frame(width: 22, height: 22).background(StreamRow.brand.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .approval, .question:
            Image(systemName: span.kind == .approval ? "checkmark.shield" : "questionmark.bubble")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.orange)
                .frame(width: 22, height: 22).background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .tool: ToolGlyph(name: span.toolName ?? "")
        }
    }
}

/// 「本轮过程」: every span of the turn on a real-time axis, then the turn's token use.
private struct TrajectorySheet: View {
    @ObservedObject var chat: Conversation
    let startSeq: Int
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ModelPricing.storageKey) private var prices = Data()

    var body: some View {
        NavigationStack {
            Group {
                if let trace = chat.traces.first(where: { $0.startSeq == startSeq }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        content(trace, now: trace.running ? context.date : (trace.end ?? context.date))
                    }
                } else {
                    Text("本轮记录尚未加载").foregroundStyle(ChatColors.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(ChatColors.canvas.ignoresSafeArea())
            .toolbar { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭") }
        }
    }

    private func content(_ trace: TurnTrace, now: Date) -> some View {
        let total = max(0.001, (trace.end ?? now).timeIntervalSince(trace.start))
        let note: (String, Color)?
        if trace.running { note = (String(localized: "进行中"), Color.accentColor) } else {
            switch trace.reason {
            case "aborted": note = (String(localized: "已停止"), ChatColors.muted)
            case "error": note = (String(localized: "出错了，没有完成"), Color.red)
            case "max-tokens": note = (String(localized: "一次写不完，已停在这里"), Color.orange)
            case "interrupted": note = (String(localized: "中途重启过，这一轮没有做完"), Color.orange)
            case "blocked": note = (String(localized: "被安全规则或插件拦下"), Color.orange)
            default: note = nil
            }
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    (Text("本轮过程  ") + Text(ChatFormat.span(total)).foregroundStyle(ChatColors.muted).fontWeight(.regular))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    if let note { Text(note.0).font(.footnote).foregroundStyle(note.1) }
                    let stepCount: String? = trace.steps > 0 ? String(localized: "\(trace.steps) 步") : nil
                    let wait: String? = trace.ttft.map { String(localized: "开始回复前等了 ") + ChatFormat.span($0) }
                    let spend: String? = trace.cost(ModelPricing.decode(prices)).map { String(localized: "花费 ") + ModelPricing.label($0.amount, currency: $0.currency) }
                    let facts = [stepCount, wait, spend].compactMap { $0 }
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · ")).font(.footnote).monospacedDigit().foregroundStyle(ChatColors.muted)
                            .accessibilityIdentifier("trajectoryFacts")
                    }
                }
                composition(trace)
                let rows = Self.rows(trace)
                if rows.isEmpty {
                    Text("本轮没有可计时的步骤").font(.subheadline).foregroundStyle(ChatColors.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { i in
                            if i > 0 { Divider().overlay(ChatColors.line).padding(.leading, 44) }
                            if rows[i].count == 1 {
                                spanTile(rows[i][0], trace: trace, total: total, now: now)
                            } else {
                                SpanGroupTile(spans: rows[i], chat: chat) { span in spanTile(span, trace: trace, total: total, now: now, inset: 20) }
                            }
                        }
                    }
                    .background(ChatColors.chip.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                usageFooter(trace)
            }.padding(16)
        }
    }

    /// The models this turn asked (and the conversation's current one), for 「单价」.
    static func models(_ trace: TurnTrace, chat: Conversation) -> [(key: String, name: String)] {
        var seen: [(key: String, name: String)] = []
        let pairs = trace.spans.filter { $0.kind == .model }.compactMap { span in span.provider.flatMap { p in span.model.map { (p, $0) } } }
            + (chat.modelProvider.isEmpty || chat.modelName.isEmpty ? [] : [(chat.modelProvider, chat.modelName)])
        for (provider, model) in pairs {
            let key = ModelPricing.key(provider: provider, model: model)
            if !seen.contains(where: { $0.key == key }) { seen.append((key, (chat.modelNames[key] ?? model) + " · " + provider)) }
        }
        return seen
    }

    /// Same step, three or more consecutive finished tool calls fold into one row.
    static func rows(_ trace: TurnTrace) -> [[TraceSpan]] {
        var rows: [[TraceSpan]] = [], run: [TraceSpan] = []
        func flush() { if run.count >= 3 { rows.append(run) } else { rows += run.map { [$0] } }; run = [] }
        for span in trace.spans {
            let groupable = span.kind == .tool && !span.open
            if groupable && (run.isEmpty || run[0].step == span.step) { run.append(span); continue }
            flush()
            if groupable { run.append(span) } else { rows.append([span]) }
        }
        flush()
        return rows
    }

    private func composition(_ trace: TurnTrace) -> some View {
        let parts: [(String, TimeInterval, Color)] = [(String(localized: "模型思考"), trace.modelTime, .accentColor), (String(localized: "执行操作"), trace.toolTime, ToolTone.terminal.color), (String(localized: "等你"), trace.waitTime, .orange)]
        let sum = max(0.001, parts.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts.indices.filter { parts[$0].1 > 0 }, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(parts[i].2).frame(width: max(3, geometry.size.width * parts[i].1 / sum))
                    }
                }
            }.frame(height: 8)
            HStack(spacing: 14) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        Circle().fill(parts[i].2).frame(width: 7, height: 7)
                        Text(parts[i].0).foregroundStyle(ChatColors.muted)
                        Text(ChatFormat.span(parts[i].1)).foregroundStyle(ChatColors.ink)
                    }
                }
            }.font(.caption).monospacedDigit()
        }
    }

    private func spanTile(_ span: TraceSpan, trace: TurnTrace, total: TimeInterval, now: Date, inset: CGFloat = 12) -> some View {
        let label = span.label(in: chat)
        let end = span.end ?? now
        let duration = end.timeIntervalSince(span.start)
        let failed = span.failed || (span.cutShort && span.kind == .tool)
        let color: Color = switch span.kind {
        case .model: .accentColor
        case .approval, .question: .orange
        case .tool: ChatStep.tone(for: span.toolName ?? "").color
        }
        return NavigationLink {
            StepDetailView(chat: chat, startSeq: trace.startSeq, spanID: span.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                SpanGlyph(span: span).frame(width: StreamRow.lead, height: StreamRow.lead)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(label.title).font(.subheadline).foregroundStyle(span.waiting ? Color.orange : ChatColors.ink)
                        if !label.detail.isEmpty {
                            Text(verbatim: "· " + label.detail)
                                .font(label.code ? .system(size: 12, design: .monospaced) : .caption)
                                .foregroundStyle(failed ? Color.red : ChatColors.muted).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(ChatFormat.span(duration))
                            .font(.caption).monospacedDigit().foregroundStyle(ChatColors.muted)
                    }
                    GeometryReader { geometry in
                        let x = geometry.size.width * max(0, span.start.timeIntervalSince(trace.start)) / total
                        let width = max(3, geometry.size.width * duration / total)
                        ZStack(alignment: .leading) {
                            Capsule().fill(ChatColors.muted.opacity(0.1))
                            Capsule().fill(color.opacity(span.open ? 0.5 : 0.85)).frame(width: min(width, geometry.size.width - x)).offset(x: min(x, geometry.size.width - 3))
                        }
                    }.frame(height: 4)
                }
            }
            .padding(.horizontal, inset).padding(.vertical, 12)
            .background(span.waiting ? Color.orange.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(String(localized: "\(label.title) \(label.detail)，") + String(localized: "用时 \(ChatFormat.span(duration))"))
    }

    private func usageFooter(_ trace: TurnTrace) -> some View {
        let usage = trace.usage
        let items: [(String, String)] = [
            (String(localized: "输入"), usage.isEmpty ? "—" : ChatFormat.tokens(usage.input)),
            (String(localized: "重复内容"), usage.cacheHitRate.map(ChatFormat.percent) ?? "—"),
            (String(localized: "输出"), usage.isEmpty ? "—" : ChatFormat.tokens(usage.output)),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("用量").font(.subheadline.weight(.semibold)).foregroundStyle(ChatColors.ink)
            HStack {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(items[i].1).font(.title3.weight(.semibold)).monospacedDigit()
                        Text(items[i].0).font(.caption).foregroundStyle(ChatColors.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if usage.reasoning > 0 {
                Text(String(localized: "输出里思考占 ") + ChatFormat.tokens(usage.reasoning))
                    .font(.caption).foregroundStyle(ChatColors.muted)
            }
            Divider().overlay(ChatColors.line)
            NavigationLink {
                ModelPricingPage(models: Self.models(trace, chat: chat))
            } label: {
                HStack {
                    Text("花费").foregroundStyle(ChatColors.ink)
                    Spacer()
                    Text(trace.cost(ModelPricing.decode(prices)).map { ModelPricing.label($0.amount, currency: $0.currency) } ?? String(localized: "填单价后显示"))
                        .foregroundStyle(ChatColors.muted).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted)
                }.font(.subheadline).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("turnCost")
        }.padding(14).background(ChatColors.chip.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension Array where Element == String {
    func appending(_ value: String) -> [String] { self + [value] }
}

private struct SpanGroupTile<Tile: View>: View {
    let spans: [TraceSpan]
    @ObservedObject var chat: Conversation
    @ViewBuilder let tile: (TraceSpan) -> Tile
    @State private var expanded = false

    var body: some View {
        let entries = spans.map { span in
            ToolEntry(id: UUID(), step: span.toolStep(in: chat), status: span.failed ? .failed : .succeeded)
        }
        let duration = (spans.compactMap(\.end).max() ?? spans[0].start).timeIntervalSince(spans[0].start)
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    ToolGlyph(name: ToolSummary.leadingTool(entries))
                    Text(ToolSummary.label(entries).label).font(.subheadline).foregroundStyle(ChatColors.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(ChatFormat.span(duration)).font(.caption).monospacedDigit().foregroundStyle(ChatColors.muted)
                    StreamChevron(open: expanded)
                }.padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded { ForEach(spans) { tile($0) } }
        }
    }
}

/// 「步骤详情」: one model request or tool call of a turn.
private struct StepDetailView: View {
    @ObservedObject var chat: Conversation
    let startSeq: Int
    let spanID: String

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let trace = chat.traces.first { $0.startSeq == startSeq }
        let span = trace?.spans.first { $0.id == spanID }
        Group {
            if let trace, let span {
                if span.kind == .model { model(span, trace: trace) } else { tool(span, trace: trace) }
            } else {
                Text("这一步不在已加载的记录里").foregroundStyle(ChatColors.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("步骤详情").inlineNavigationTitle()
    }

    private func fact(_ title: String, _ value: String, mono: Bool = false, tint: Color = ChatColors.ink) -> some View {
        LabeledContent(title) {
            Text(verbatim: value).font(mono ? .system(.subheadline, design: .monospaced) : .subheadline).foregroundStyle(tint)
                .monospacedDigit().textSelection(.enabled)
        }
    }

    private func tool(_ span: TraceSpan, trace: TurnTrace) -> some View {
        let step = span.toolStep(in: chat)
        let message = chat.messages.last { $0.tool.map(Conversation.callID) == span.callID }
        let status = message?.tool.map { chat.toolStatus($0, turn: message?.turn) } ?? (span.open ? .running : span.failed ? .failed : .succeeded)
        let state: (String, Color) = switch status {
        case .succeeded: (String(localized: "成功"), .green)
        case .failed: (String(localized: "失败"), .red)
        case .denied: (String(localized: "已拒绝"), .orange)
        case .cancelled: (String(localized: "已取消"), ChatColors.muted)
        case .awaitingApproval: (String(localized: "等你确认"), .orange)
        case .running: (String(localized: "进行中"), .accentColor)
        }
        let wait = trace.spans.first { $0.kind == .approval && $0.callID == span.callID && $0.callID != nil }
        let summary = step.summary(in: chat.workspace)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(span.kind == .question ? String(localized: "提问") : step.verb).font(.title3.weight(.semibold))
                    if !summary.isEmpty {
                        Text(verbatim: summary).font(step.summaryIsCode ? .system(size: 13, design: .monospaced) : .subheadline)
                            .foregroundStyle(ChatColors.muted).lineLimit(3)
                    }
                }.listRowBackground(Color.clear)
            }
            Section {
                fact(String(localized: "工具"), step.readableName, mono: true)
                fact(String(localized: "状态"), state.0, tint: state.1)
                fact(String(localized: "发出"), Self.clock.string(from: span.start))
                if let wait {
                    let outcome = wait.outcome.map { $0 == "allowed-once" ? String(localized: " · 允许了") : $0 == "rejected" ? String(localized: " · 已拒绝") : String(localized: " · 已答复") } ?? ""
                    fact(wait.open ? String(localized: "等你确认") : String(localized: "等待确认"), ChatFormat.span(wait.duration ?? Date().timeIntervalSince(wait.start)) + outcome, tint: .orange)
                }
                fact(span.kind == .question ? String(localized: "等你回答") : String(localized: "执行"), span.duration.map(ChatFormat.span) ?? String(localized: "进行中"))
                fact(String(localized: "所在"), String(localized: "第 \(trace.turn) 轮 · 第 \(span.step) 步"))
            }.listRowBackground(ChatColors.chip)
            Section {
                ToolDetailWell(step: step, status: status, workspace: chat.workspace, host: chat.connection)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        }
    }

    private func model(_ span: TraceSpan, trace: TurnTrace) -> some View {
        let reply = chat.messages.first { $0.sequence == span.seq && span.seq >= 0 && $0.tool == nil }
        let label = span.label(in: chat)
        let calls = trace.spans.filter { $0.step == span.step && $0.kind != .model && $0.kind != .approval }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label.title).font(.title3.weight(.semibold))
                    Text(span.open ? String(localized: "模型正在处理") : label.detail.isEmpty ? String(localized: "模型处理了一次") : String(localized: "模型处理了一次 · ") + label.detail)
                        .font(.subheadline).foregroundStyle(ChatColors.muted)
                }.listRowBackground(Color.clear)
            }
            Section("计时") {
                fact(String(localized: "开始"), Self.clock.string(from: span.start))
                fact(String(localized: "用时"), span.duration.map(ChatFormat.span) ?? String(localized: "进行中"))
                if let model = span.model { fact(String(localized: "模型"), model, mono: true) }
                fact(String(localized: "所在"), String(localized: "第 \(trace.turn) 轮 · 第 \(span.step) 步"))
            }.listRowBackground(ChatColors.chip)
            if let usage = span.usage {
                Section("用量") {
                    fact(String(localized: "输入"), ChatFormat.tokens(usage.input))
                    fact(String(localized: "  重复内容"), ChatFormat.tokens(usage.cacheRead))
                    fact(String(localized: "  新内容"), ChatFormat.tokens(usage.uncached))
                    if usage.cacheWrite > 0 { fact(String(localized: "  存下备用"), ChatFormat.tokens(usage.cacheWrite)) }
                    fact(String(localized: "输出"), ChatFormat.tokens(usage.output))
                    if usage.reasoning > 0 {
                        fact(String(localized: "  思考"), ChatFormat.tokens(usage.reasoning))
                        fact(String(localized: "  回答"), ChatFormat.tokens(max(0, usage.output - usage.reasoning)))
                    }
                }.listRowBackground(ChatColors.chip)
            }
            if let thinking = reply?.thinking.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
                Section("思考过程") {
                    ChatAnswer(text: thinking, font: .subheadline).foregroundStyle(ChatColors.muted).textSelection(.enabled)
                }.listRowBackground(ChatColors.chip)
            }
            if let text = reply?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Section(span.toolCalls > 0 ? "说明" : "回复") {
                    ChatAnswer(text: text, font: .subheadline).textSelection(.enabled)
                }.listRowBackground(ChatColors.chip)
            }
            if !calls.isEmpty {
                Section("这一步做的操作") {
                    ForEach(calls) { call in
                        let step = call.toolStep(in: chat)
                        NavigationLink {
                            StepDetailView(chat: chat, startSeq: startSeq, spanID: call.id)
                        } label: {
                            HStack(spacing: 8) {
                                SpanGlyph(span: call)
                                Text(step.verb).font(.subheadline)
                                Text(verbatim: step.summary(in: chat.workspace)).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(call.duration.map(ChatFormat.span) ?? String(localized: "进行中")).font(.caption).monospacedDigit().foregroundStyle(ChatColors.muted)
                            }
                        }
                    }
                }.listRowBackground(ChatColors.chip)
            }
        }
    }
}

/// Feeds the list's scroll geometry into a `ScrollProbe` for the UI trace.
private struct ScrollProbing: ViewModifier {
    let probe: ScrollProbe

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollGeometryChange(for: [Int].self) { geometry in
                [Int(geometry.contentSize.height), Int(geometry.contentOffset.y), Int(geometry.visibleRect.height),
                 Int(geometry.contentInsets.top + geometry.contentInsets.bottom)]
            } action: { _, value in
                probe.content = CGFloat(value[0]); probe.top = CGFloat(value[1]); probe.visible = CGFloat(value[2]); probe.insets = CGFloat(value[3])
            }
        } else {
            content
        }
    }
}

private struct HistoryTracking: ViewModifier {
    @Binding var following: Bool
    @Binding var nearEnd: Bool
    let height: CGFloat
    let started: () -> Void
    @State private var scrolling = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 30
            } action: { _, close in
                nearEnd = close
                if scrolling { following = close }
            }
            .onScrollPhaseChange { _, phase, context in
                if !scrolling && (phase == .interacting || phase == .decelerating) {
                    started()
                    scrolling = true
                    following = false
                } else if phase == .idle && scrolling {
                    let close = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 30
                    nearEnd = close; following = close; scrolling = false
                }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                started()
                if value.translation.height > 0 || !nearEnd { following = false }
            }.onEnded { value in
                if value.translation.height > 5 { following = false }
                else if nearEnd { following = true }
            })
            .onPreferenceChange(HistoryEnd.self) { end in
                nearEnd = end.map { $0 >= 0 && $0 <= height + 30 } ?? false
                if nearEnd { following = true }
            }
        }
    }
}
