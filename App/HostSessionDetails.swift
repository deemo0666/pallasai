import SwiftUI

/// Number and time wording shared by the host panels.
enum HostPanelFormat {
    /// `812`, `8.4K`, `43K`, `1.25M`.
    static func tokens(_ n: Int) -> String {
        func trim(_ text: String) -> String {
            guard text.contains(".") else { return text }
            var out = text
            while out.hasSuffix("0") { out.removeLast() }
            if out.hasSuffix(".") { out.removeLast() }
            return out
        }
        let sign = n < 0 ? "-" : "", value = abs(n)
        if value < 1000 { return sign + String(value) }
        if value < 1_000_000 {
            let k = Double(value) / 1000
            let text = trim(String(format: k >= 100 ? "%.0f" : "%.1f", k))
            if text != "1000" { return sign + text + "K" }
        }
        return sign + trim(String(format: "%.2f", Double(value) / 1_000_000)) + "M"
    }

    /// `12%`; above 0 but under 1% reads `<1%`.
    static func percent(_ fraction: Double) -> String {
        fraction > 0 && fraction < 0.01 ? "<1%" : "\(Int((fraction * 100).rounded()))%"
    }

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / 1024 / 1024)
    }

    /// `09:30`, `昨天 09:30`, `10月25日`, `2024/10/25`.
    static func fileTime(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hm = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if days <= 0 { return hm }
        if days == 1 { return String(localized: "昨天 ") + hm }
        if parts.year == calendar.component(.year, from: now) { return String(localized: "\(parts.month ?? 0)月\(parts.day ?? 0)日") }
        return "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    /// The modified time a workspace file version (`dev:ino:size:mtimeNs:ctimeNs`) carries.
    static func modified(fromVersion version: String) -> Date? {
        let parts = version.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), let ns = Double(parts[3]) else { return nil }
        let date = Date(timeIntervalSince1970: ns / 1_000_000_000)
        guard Calendar.current.component(.year, from: date) >= 1990, date < .now.addingTimeInterval(86400) else { return nil }
        return date
    }

    /// A Host `LocalizedText` (a string, or `{zh, en, …}`) in the interface language when it has it.
    static func localized(_ value: Any?) -> String? {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }
        guard let map = value as? [String: Any] else { return nil }
        let texts = map.compactMapValues { $0 as? String }.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        return AppLanguage.pick(texts)
    }
}

/// A capsule status label (进行中, 已完成, 出错 …).
struct HostStateChip: View {
    enum Tone { case busy, ok, error, idle, warn }
    let label: String
    var tone: Tone = .idle
    var body: some View {
        let color: Color = switch tone {
        case .busy: .accentColor
        case .ok: .green
        case .error: .red
        case .warn: .orange
        case .idle: ChatColors.muted
        }
        Text(label).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
    }
}

// MARK: - 对话详情

/// The tabs of 对话详情, in order.
enum SessionTab: String, CaseIterable, Identifiable {
    case trajectory = "过程", changes = "改动", files = "文件", progress = "进度", context = "对话长度", subagents = "子任务"
    var id: Self { self }
}

/// One round of the conversation: the prompt that started it and its tool calls.
struct SessionTurnTrace: Identifiable {
    let turn: Int
    var prompt: String?
    var steps: [ChatStep] = []
    var running = false
    var id: Int { turn }
}

/// Every edit of one file the conversation made with its write and edit tools.
struct SessionFileChange: Identifiable {
    let path: String
    var added = 0
    var removed = 0
    var edits = 0
    var created = false
    var lastTurn: Int?
    var diffs: [ToolFileChange] = []
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

enum SessionTrace {
    /// Tools that dispatch or steer a subagent.
    static let agentTools: Set<String> = ["subagent", "subagent_fork", "send_message", "interrupt_agent", "workflow", "ralph"]

    static func turn(of step: ChatStep) -> Int? { Int(step.id.prefix { $0 != "/" }) }

    static func turns(_ messages: [Message], live: Bool) -> [SessionTurnTrace] {
        var order: [Int] = [], traces: [Int: SessionTurnTrace] = [:], prompt: String?
        for message in messages {
            if message.outgoing { prompt = message.prompt ?? message.text; continue }
            guard let turn = message.turn else { continue }
            if traces[turn] == nil {
                traces[turn] = SessionTurnTrace(turn: turn, prompt: prompt)
                order.append(turn); prompt = nil
            }
            if let tool = message.tool { traces[turn]?.steps.append(tool) }
        }
        var result = order.compactMap { traces[$0] }
        if live, !result.isEmpty { result[result.count - 1].running = true }
        return result
    }

    static func counts(_ change: ToolFileChange) -> (added: Int, removed: Int) {
        if let patch = change.patch {
            return (patch.filter { $0.prefix == "+" }.count, patch.filter { $0.prefix == "−" }.count)
        }
        func lines(_ text: String?) -> Int { text.map { $0.isEmpty ? 0 : $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0 }
        return (lines(change.after), lines(change.before))
    }

    static func relative(_ path: String, workspace: String) -> String {
        let root = ShareText.redacted(workspace)
        return !root.isEmpty && path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    static func changes(_ steps: [ChatStep], workspace: String) -> [SessionFileChange] {
        var order: [String] = [], files: [String: SessionFileChange] = [:]
        for step in steps where step.state == "ok" {
            for change in step.files ?? [] {
                let path = relative(change.path, workspace: workspace)
                if files[path] == nil { files[path] = SessionFileChange(path: path, created: change.before == nil); order.append(path) }
                let (added, removed) = counts(change)
                files[path]?.added += added; files[path]?.removed += removed
                files[path]?.edits += 1; files[path]?.lastTurn = turn(of: step)
                files[path]?.diffs.append(change)
            }
        }
        return order.compactMap { files[$0] }
    }
}

/// `+12 −3` in the diff colours.
private struct DiffCounts: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: 6) {
            if added > 0 || removed == 0 { Text("+\(added)").foregroundStyle(.green) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
        }.font(.caption.monospacedDigit().weight(.medium))
    }
}

/// 对话详情: the head (title, rounds, steps, changed files) over capsule tabs —
/// 轨迹 / 改动 / 文件 / 进度 / 上下文, plus 子代理 once the conversation sent one out.
struct SessionDetailsView: View {
    @ObservedObject var chat: Conversation
    let host: Harness
    let close: () -> Void
    private let initialTab: SessionTab
    @State private var tab: SessionTab
    @State private var lineage: [HostSubagentNode] = []
    /// A subagent's conversation, read-only: the engine refuses to open a child as a session of its own.
    @State private var viewing: HostSubagentNode?
    @State private var projections: Object = [:]
    @State private var projectionsLoaded = false
    @State private var projectionsError: String?
    @State private var revision = 0
    @State private var planWanted: Bool?
    @State private var planIssue: String?

    init(chat: Conversation, host: Harness, initial: SessionTab, close: @escaping () -> Void) {
        self.chat = chat; self.host = host; self.close = close
        initialTab = initial
        _tab = State(initialValue: initial)
    }

    private var agentCalls: [ChatStep] { chat.actions.filter { SessionTrace.agentTools.contains($0.name) } }
    private var tabs: [SessionTab] {
        let delegated = !agentCalls.isEmpty || !lineage.isEmpty || initialTab == .subagents
        return SessionTab.allCases.filter { $0 != .subagents || delegated }
    }

    var body: some View {
        let turns = SessionTrace.turns(chat.messages, live: chat.phase == .replying)
        let changed = SessionTrace.changes(chat.actions, workspace: chat.workspace)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chat.title.isEmpty ? String(localized: "未命名对话") : chat.title).font(.title2.weight(.semibold)).foregroundStyle(ChatColors.ink).lineLimit(2)
                    Text(turns.isEmpty ? "还没有完整的一轮" : turns.last?.running == true ? "共 \(turns.count) 轮 · 进行中" : "共 \(turns.count) 轮")
                        .font(.subheadline).foregroundStyle(ChatColors.muted)
                    HStack(spacing: 12) {
                        stat("\(turns.reduce(0) { $0 + $1.steps.count })", String(localized: "步骤"))
                        stat("\(changed.count)", String(localized: "改动文件"))
                    }.padding(.top, 8)
                }.padding(.vertical, 4)
                Picker("对话详情", selection: $tab) {
                    ForEach(tabs) { Text($0.rawValue.localized).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("sessionDetailTabs")
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            switch tab {
            case .trajectory: trajectory(turns)
            case .changes: changes(changed)
            case .files:
                if !chat.deliverables.isEmpty {
                    Section("产出的文件") {
                        ForEach(chat.deliverables.prefix(6)) { file in
                            NavigationLink { HostDeliverablePreview(host: host, file: file) } label: {
                                Label { Text(verbatim: (file.path as NSString).lastPathComponent).lineLimit(1) } icon: { Image(systemName: file.symbol) }
                            }
                        }
                    }.listRowBackground(ChatColors.chip)
                }
                WorkspaceBrowserRows(chat: chat, host: host)
            case .progress: progress
            case .context: context
            case .subagents: subagents
            }
        }
        .groupedList().scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .inlineNavigationTitle()
        #if os(iOS)
        .toolbar {
            if EmbeddedEngine.shared.hasTerminal(host) {
                ToolbarItem(placement: .screenLeading) {
                    NavigationLink { TerminalPanel(host: host).navigationTitle("终端") } label: { Image(systemName: "terminal") }
                        .accessibilityLabel("终端")
                }
            }
        }
        #endif
        .navigationDestination(item: $viewing) { node in SubagentTranscript(host: host, node: node) }
        .task(id: revision) { await loadProjections() }
        .task { await loadLineage() }
        .refreshable { revision += 1; await loadLineage() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.medium)).foregroundStyle(ChatColors.ink)
            Text(label).font(.caption).foregroundStyle(ChatColors.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(ChatColors.chip.opacity(0.87), in: RoundedRectangle(cornerRadius: 14))
    }

    // 轨迹: one card per round, newest first; the newest opens.
    @ViewBuilder private func trajectory(_ turns: [SessionTurnTrace]) -> some View {
        if turns.isEmpty && !chat.hasOlder {
            Section { HostEmptyState(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: String(localized: "还没有完整的一轮")) }
                .listRowBackground(Color.clear)
        }
        let ordered = Array(turns.reversed())
        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, trace in
            Section { SessionTurnCard(trace: trace, chat: chat, host: host, expanded: index == 0) }
                .listRowBackground(ChatColors.chip)
        }
        if chat.hasOlder {
            Section {
                if chat.loadingOlder { ProgressView().frame(maxWidth: .infinity) }
                else { Button("加载更早的轮次") { Task { await chat.loadOlder() } }.frame(maxWidth: .infinity) }
            }.listRowBackground(Color.clear)
        }
    }

    // 改动: one merged diff per file, tagged with the round that last changed it.
    @ViewBuilder private func changes(_ files: [SessionFileChange]) -> some View {
        if files.isEmpty {
            Section { HostEmptyState(symbol: "plusminus", title: String(localized: "还没有改过文件")) }
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(files) { file in
                    NavigationLink { SessionDiffPage(file: file) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: file.created ? "doc.badge.plus" : "doc.text")
                                .foregroundStyle(file.created ? Color.green : Color.accentColor).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: file.name).foregroundStyle(ChatColors.ink).lineLimit(1)
                                let line = [file.directory.isEmpty ? nil : file.directory, file.lastTurn.map { String(localized: "第 \($0) 轮") },
                                            file.edits > 1 ? String(localized: "修改 \(file.edits) 次") : nil].compactMap { $0 }.joined(separator: " · ")
                                if !line.isEmpty { Text(verbatim: line).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1).truncationMode(.middle) }
                            }
                            Spacer(minLength: 8)
                            DiffCounts(added: file.added, removed: file.removed)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("修改了 \(files.count) 个文件")
                    Spacer()
                    DiffCounts(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
                }
            }
            .listRowBackground(ChatColors.chip)
        }
    }

    // 进度: the goal, plan mode and the todo list.
    @ViewBuilder private var progress: some View {
        let goalValue = projections["goal"] as? Object
        let goal = goalValue?["goal"] as? Object
        let plan = projections["plan"] as? Object
        let planActive = plan?["active"] as? Bool == true, planPending = plan?["pending"] as? Bool == true
        let todos = (projections["todos"] as? [Object] ?? []).map { ($0["content"] as? String ?? "", $0["status"] as? String ?? "pending") }
        if let projectionsError { Section { Text(projectionsError).foregroundStyle(.red) } }
        if !projectionsLoaded && projectionsError == nil {
            Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
        } else if goal?["objective"] as? String == nil && todos.isEmpty && !planActive {
            Section { HostEmptyState(symbol: "checklist", title: String(localized: "还没有目标或待办")) }
                .listRowBackground(Color.clear)
            Section { GoalView(host: host, goal: nil) { revision += 1 } }.listRowBackground(ChatColors.chip)
        } else {
            if let goal, let objective = goal["objective"] as? String {
                let phase = goal["phase"] as? String ?? "active"
                let rounds = goalValue?["roundsStarted"] as? Int ?? 0
                let blocked = (goal["blockedReason"] as? Object)?["message"] as? String
                let symbol = phase == "complete" ? "checkmark.circle.fill" : phase == "blocked" ? "exclamationmark.triangle.fill" : phase == "paused" ? "pause.circle" : "scope"
                let tint: Color = phase == "complete" ? .green : phase == "blocked" ? .orange : phase == "paused" ? ChatColors.muted : .accentColor
                let state = phase == "complete" ? String(localized: "已完成") : phase == "blocked" ? (blocked.map { String(localized: "受阻：") + $0 } ?? String(localized: "受阻")) : phase == "paused" ? String(localized: "已暂停") : phase == "active" ? String(localized: "进行中") : phase
                Section("目标") {
                    Text(verbatim: objective).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Image(systemName: symbol).foregroundStyle(tint)
                        Text(state)
                        Spacer()
                        Text((goal["maxGoalRounds"] as? Int).map { "第 \(rounds) / \($0) 轮" } ?? "第 \(rounds) 轮")
                            .font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted)
                    }
                    GoalView(host: host, goal: goal) { revision += 1 }
                }.listRowBackground(ChatColors.chip)
            } else {
                Section { GoalView(host: host, goal: nil) { revision += 1 } }.listRowBackground(ChatColors.chip)
            }
            if !todos.isEmpty {
                let done = todos.filter { $0.1 == "completed" }.count
                Section {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        let symbol = todo.1 == "completed" ? "checkmark.circle.fill" : todo.1 == "in_progress" ? "circle.dotted.circle" : "circle"
                        let tint: Color = todo.1 == "completed" ? .green : todo.1 == "in_progress" ? .accentColor : ChatColors.muted
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol).foregroundStyle(tint)
                            Text(verbatim: todo.0).foregroundStyle(todo.1 == "completed" ? ChatColors.muted : ChatColors.ink)
                                .fontWeight(todo.1 == "in_progress" ? .semibold : .regular)
                        }.accessibilityElement(children: .ignore)
                            .accessibilityLabel(todo.0 + "," + (todo.1 == "completed" ? String(localized: "已完成") : todo.1 == "in_progress" ? String(localized: "进行中") : String(localized: "未开始")))
                    }
                } header: {
                    HStack {
                        Text("待办"); Spacer()
                        ProgressView(value: Double(done), total: Double(max(todos.count, 1))).frame(width: 64)
                        Text("\(done)/\(todos.count)").monospacedDigit()
                    }
                }.listRowBackground(ChatColors.chip)
            }
        }
        if projectionsLoaded { planRow(active: planActive, pending: planPending) }
    }

    /// 计划模式, switched with `/plan` and `/plan off` like the composer's card.
    private func planRow(active: Bool, pending: Bool) -> some View {
        Section {
            Toggle(isOn: Binding(get: { planWanted ?? active }, set: { next in
                guard planWanted == nil else { return }
                planWanted = next; planIssue = nil
                Task {
                    do {
                        let value = try await host.rpcValue("commands/execute", args: ["agentId": host.sessionID, "line": next ? "/plan" : "/plan off", "submittedAttachments": [] as [Any]]) as? Object
                        if (value?["result"] as? Object)?["kind"] as? String == "error" { planIssue = ((value?["result"] as? Object)?["text"] as? String) ?? String(localized: "没能切换") }
                        try? await Task.sleep(for: .milliseconds(400))
                    } catch { planIssue = error.localizedDescription }
                    planWanted = nil; revision += 1
                }
            })) {
                HStack(spacing: 10) {
                    Image(systemName: "map").foregroundStyle(Color.accentColor)
                    Text(pending || planWanted != nil ? "正在切换计划模式" : "计划模式")
                }
            }.disabled(planWanted != nil).accessibilityIdentifier("planMode")
            if let planIssue { Text(planIssue).font(.caption).foregroundStyle(.red) }
        }.listRowBackground(ChatColors.chip)
    }

    // 上下文: the context window and this conversation's tokens.
    @ViewBuilder private var context: some View {
        let tokens = projections["tokenUsage"] as? Object ?? [:]
        let pressure = projections["contextPressure"] as? Object ?? [:]
        let breakdown = projections["contextBreakdown"] as? Object ?? [:]
        let stats = projections["sessionStats"] as? Object ?? [:]
        let uncached = Self.number(tokens, "uncachedInputTokens") ?? 0, cacheRead = Self.number(tokens, "cacheReadTokens") ?? 0
        let cacheWrite = Self.number(tokens, "cacheWriteTokens") ?? 0, output = Self.number(tokens, "outputTokens") ?? 0
        let input = uncached + cacheRead + cacheWrite
        if let projectionsError { Section { Text(projectionsError).foregroundStyle(.red) } }
        Section("对话长度") {
            if let window = Self.number(pressure, "contextWindow"), window > 0 {
                let used = Self.number(pressure, "pressureTokens") ?? 0
                let fraction = min(max(Double(used) / Double(window), 0), 1)
                let tone: Color = fraction > 0.85 ? .red : fraction >= 0.6 ? .orange : .accentColor
                HStack(alignment: .firstTextBaseline) {
                    Text(HostPanelFormat.percent(fraction)).font(.title.monospacedDigit().weight(.medium)).foregroundStyle(fraction >= 0.6 ? tone : ChatColors.ink)
                    Spacer()
                    Text(HostPanelFormat.tokens(used) + " / " + HostPanelFormat.tokens(window)).font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted)
                }
                ProgressView(value: fraction).tint(tone)
                let parts = [(String(localized: "系统 "), "systemTokens"), (String(localized: "工具 "), "toolsTokens"), (String(localized: "消息 "), "messageTokens")].compactMap { label, key -> String? in
                    guard let count = Self.number(breakdown, key), count > 0 else { return nil }
                    return label + HostPanelFormat.tokens(count)
                }
                if !parts.isEmpty { Text(parts.joined(separator: " · ")).font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted) }
                if fraction > 0.85 { Text("对话长度快满了，可以在输入框下方压缩对话").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("发送消息后显示").foregroundStyle(ChatColors.muted)
            }
        }.listRowBackground(ChatColors.chip)
        Section("本对话") {
            HStack {
                usage(HostPanelFormat.tokens(input), String(localized: "输入"))
                usage(HostPanelFormat.tokens(output), String(localized: "输出"))
                usage(input == 0 ? "—" : HostPanelFormat.percent(Double(cacheRead) / Double(input)), String(localized: "缓存命中"))
            }
            let turns = Self.number(stats, "turns") ?? 0
            let notes = [turns > 0 ? String(localized: "共 \(turns) 轮") : nil, cacheWrite > 0 ? String(localized: "写入缓存 ") + HostPanelFormat.tokens(cacheWrite) : nil].compactMap { $0 }
            if !notes.isEmpty { Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(ChatColors.muted) }
        }.listRowBackground(ChatColors.chip)
    }

    private static func number(_ map: Object, _ key: String) -> Int? { (map[key] as? NSNumber)?.intValue }

    private func usage(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            Text(label).font(.caption).foregroundStyle(ChatColors.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // 子代理: the lineage first (a row opens its conversation), then the dispatch log.
    @ViewBuilder private var subagents: some View {
        let calls = Array(agentCalls.reversed())
        if calls.isEmpty && lineage.isEmpty {
            Section { HostEmptyState(symbol: "point.3.connected.trianglepath.dotted", title: String(localized: "没有派出子任务")) }.listRowBackground(Color.clear)
        }
        if !lineage.isEmpty {
            Section {
                HostSubagentRows(nodes: lineage) { node in viewing = node }
            } header: { Text("\(lineage.count) 个子任务") } footer: {
                if let line = HostSubagentNode.summary(lineage) { Text(line) }
            }.listRowBackground(ChatColors.chip)
        }
        if !calls.isEmpty {
            Section {
                ForEach(calls) { step in
                    ToolDetails(step: step, live: chat.isToolRunning(step), workspace: chat.workspace, host: host,
                                title: step.summary ?? step.displayName)
                }
            } header: { if !lineage.isEmpty { Text("分派记录") } }
            .listRowBackground(ChatColors.chip)
        }
    }

    private func loadProjections() async {
        do {
            let value = try await host.rpcValue("session/projections", args: ["request": ["sessionId": host.sessionID]])
            try Task.checkCancellation()
            projections = (value as? Object)?["values"] as? Object ?? [:]
            projectionsError = nil
        } catch { if !Task.isCancelled { projectionsError = error.localizedDescription } }
        if !Task.isCancelled { projectionsLoaded = true }
    }

    private func loadLineage() async {
        guard let data = try? await host.sessionList() else { return }
        lineage = HostSubagentNode.lineage(of: host.sessionID, items: data["items"] as? [Object] ?? [])
    }
}

/// One round on 轨迹: 第 N 轮, its state, the prompt and its step count; open, its tool calls.
private struct SessionTurnCard: View {
    let trace: SessionTurnTrace
    @ObservedObject var chat: Conversation
    let host: Harness
    @State var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(trace.steps) { step in
                ToolDetails(step: step, live: chat.isToolRunning(step), workspace: chat.workspace, host: host)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("第 \(trace.turn) 轮").font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted)
                    if trace.running { HostStateChip(label: String(localized: "进行中"), tone: .busy) }
                }
                if let prompt = trace.prompt?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !prompt.isEmpty {
                    Text(verbatim: prompt).font(.body).foregroundStyle(ChatColors.ink).lineLimit(2)
                }
                if !trace.steps.isEmpty { Text("\(trace.steps.count) 步").font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted) }
            }.padding(.vertical, 2)
        }.tint(ChatColors.muted)
    }
}

/// 对话改动 for one file: every edit's diff, oldest first.
private struct SessionDiffPage: View {
    let file: SessionFileChange
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    var body: some View {
        List {
            Section {
                HStack {
                    Text(verbatim: file.path).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer(); DiffCounts(added: file.added, removed: file.removed)
                }
            }.listRowBackground(ChatColors.chip)
            ForEach(Array(file.diffs.enumerated()), id: \.offset) { index, change in
                Section {
                    if let patch = change.patch {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(patch.indices, id: \.self) { i in
                                let line = patch[i]
                                Text(verbatim: line.prefix + " " + line.text)
                                    .foregroundStyle(line.prefix == "+" ? Color.green : line.prefix == "−" ? Color.red : ChatColors.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(line.prefix == "+" ? Color.green.opacity(0.08) : line.prefix == "−" ? Color.red.opacity(0.08) : Color.clear)
                            }
                        }.font(typeSize.font.monospaced()).textSelection(.enabled)
                    } else {
                        if let before = change.before {
                            Text("更改前").font(.caption).foregroundStyle(ChatColors.muted)
                            Text(verbatim: before).font(typeSize.font.monospaced()).textSelection(.enabled)
                        }
                        Text("更改后").font(.caption).foregroundStyle(ChatColors.muted)
                        Text(verbatim: change.after).font(typeSize.font.monospaced()).textSelection(.enabled)
                    }
                } header: { if file.diffs.count > 1 { Text("第 \(index + 1) 次改动") } }
                .listRowBackground(ChatColors.chip)
            }
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
            .navigationTitle("对话改动").inlineNavigationTitle()
    }
}

// MARK: - 子代理

/// A child conversation in the lineage, with its own children.
struct HostSubagentNode: Identifiable, Hashable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.parent == b.parent }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(parent) }
    enum RunState { case running, completed, failed, idle }
    let id: String
    /// The session that started it; a subagent opens only through this address.
    let parent: String
    let label: String
    let title: String?
    let mode: String
    let state: RunState
    var children: [HostSubagentNode]

    var openable: Bool { mode != "external" }
    var stateLabel: String {
        switch state { case .running: String(localized: "运行中"); case .completed: String(localized: "已完成"); case .failed: String(localized: "出错"); case .idle: String(localized: "未运行") }
    }
    var tone: HostStateChip.Tone {
        switch state { case .running: .busy; case .completed: .ok; case .failed: .error; case .idle: .idle }
    }
    var modeLabel: String {
        switch mode { case "one-shot": String(localized: "一次性"); case "continuable": String(localized: "可继续"); case "external": String(localized: "外部任务"); default: String(localized: "子任务") }
    }
    var flattened: [HostSubagentNode] { [self] + children.flatMap(\.flattened) }

    /// 「1 个运行中 · 含 2 个下级」.
    static func summary(_ nodes: [HostSubagentNode]) -> String? {
        let all = nodes.flatMap(\.flattened)
        let running = all.filter { $0.state == .running }.count, failed = all.filter { $0.state == .failed }.count, nested = all.count - nodes.count
        let text = [running > 0 ? String(localized: "\(running) 个运行中") : nil, failed > 0 ? String(localized: "\(failed) 个出错") : nil, nested > 0 ? String(localized: "含 \(nested) 个下级") : nil].compactMap { $0 }
        return text.isEmpty ? nil : text.joined(separator: " · ")
    }

    /// The children of `parent` from `session/list`: the parent's catalog first, then listed children it does not name.
    static func lineage(of parent: String, items: [Object]) -> [HostSubagentNode] {
        var sessions: [String: Object] = [:], children: [String: [Object]] = [:]
        for item in items {
            guard let id = item["sessionId"] as? String else { continue }
            sessions[id] = item
            if item["origin"] as? String == "subagent", let parent = item["parentSessionId"] as? String { children[parent, default: []].append(item) }
        }
        var visited: Set<String> = [parent]
        func values(_ id: String) -> Object? { (sessions[id]?["projections"] as? Object)?["values"] as? Object }
        func build(_ parent: String, depth: Int) -> [HostSubagentNode] {
            guard depth <= 8 else { return [] }
            var entries: [(id: String, mode: String, label: String?)] = (values(parent)?["subagentCatalog"] as? [Object] ?? []).compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (id, row["mode"] as? String ?? "unknown", label?.isEmpty == false ? label : nil)
            }
            let named = Set(entries.map(\.id))
            let extra = (children[parent] ?? []).filter { !named.contains($0["sessionId"] as? String ?? "") }
                .sorted { (($0["updatedAt"] as? NSNumber)?.doubleValue ?? 0) < (($1["updatedAt"] as? NSNumber)?.doubleValue ?? 0) }
            for item in extra {
                guard let id = item["sessionId"] as? String else { continue }
                let identity = values(id)?["subagent"] as? Object
                entries.append((id, identity?["mode"] as? String ?? "unknown", identity?["label"] as? String))
            }
            var nodes: [HostSubagentNode] = []
            for entry in entries where visited.insert(entry.id).inserted {
                let summary = sessions[entry.id], projection = values(entry.id)
                let identity = projection?["subagent"] as? Object
                let title = (projection?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = entry.label ?? (identity?["label"] as? String) ?? title
                let mode = entry.mode == "unknown" ? (identity?["mode"] as? String ?? entry.mode) : entry.mode
                let state: RunState
                if mode == "external" || summary == nil { state = .idle }
                else if summary?["running"] as? Bool == true { state = .running }
                else {
                    switch (projection?["subagentTiming"] as? Object)?["lastTurnCompleted"] as? Bool {
                    case true?: state = .completed
                    case false?: state = .failed
                    case nil: state = .idle
                    }
                }
                let display = (name ?? "").isEmpty ? String(localized: "子任务") : name ?? String(localized: "子任务")
                nodes.append(HostSubagentNode(id: entry.id, parent: parent, label: display, title: title == display || title?.isEmpty == true ? nil : title,
                                              mode: mode, state: state, children: build(entry.id, depth: depth + 1)))
            }
            return nodes
        }
        return build(parent, depth: 0)
    }
}

/// The lineage rows: indented by depth, a state capsule, › on what can be opened.
struct HostSubagentRows: View {
    let nodes: [HostSubagentNode]
    let open: (HostSubagentNode) -> Void

    private static func flatten(_ nodes: [HostSubagentNode], depth: Int) -> [(node: HostSubagentNode, depth: Int)] {
        nodes.flatMap { node in [(node, depth)] + flatten(node.children, depth: depth + 1) }
    }

    var body: some View {
        ForEach(Self.flatten(nodes, depth: 0), id: \.node.id) { item in
            let node = item.node
            Button { if node.openable { open(node) } } label: {
                HStack(spacing: 10) {
                    Text(String(node.label.prefix(1)).uppercased()).font(.subheadline.weight(.semibold)).foregroundStyle(ChatColors.ink)
                        .frame(width: 30, height: 30).background(ChatColors.muted.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: node.label).foregroundStyle(ChatColors.ink).lineLimit(1)
                        Text([node.modeLabel, node.children.isEmpty ? nil : String(localized: "\(node.children.count) 个下级")].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    HostStateChip(label: node.stateLabel, tone: node.tone)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted).opacity(node.openable ? 1 : 0)
                }.padding(.leading, CGFloat(item.depth) * 18).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!node.openable)
                .accessibilityElement(children: .ignore).accessibilityLabel(node.label + String(localized: "，") + node.stateLabel)
                .accessibilityAddTraits(.isButton).accessibilityIdentifier("subagent-" + node.id)
        }
    }
}
