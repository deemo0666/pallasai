import SwiftUI

/// What a Bot is doing, as the chat says it: 「正在运行命令」.
private enum BotWords {
    static func work(_ work: Object?, activity: String?) -> String? {
        guard let work else { return activity == "thinking" ? String(localized: "正在思考") : nil }
        if work["switching"] as? Bool == true { return String(localized: "正在整理笔记") }
        guard let tool = work["tool"] as? String else { return String(localized: "正在思考") }
        switch tool {
        case "bash", "pwsh", "shell", "run_code": return String(localized: "正在运行命令")
        case "read", "read_file", "fs_read", "view", "list", "glob", "grep": return String(localized: "正在读取文件")
        case "write", "edit", "str_replace_editor", "apply_patch": return String(localized: "正在修改文件")
        case "web_search": return String(localized: "正在联网搜索")
        case "web_fetch", "read_browser": return String(localized: "正在看网页")
        case "message_bot": return String(localized: "正在联系其他 Bot")
        case "group_relay", "post_to_group", "read_group_chat": return String(localized: "正在群里沟通")
        case "remember", "forget": return String(localized: "正在整理记忆")
        case "recall", "read_own_chat": return String(localized: "正在翻看记录")
        case "create_bot", "update_bot", "create_group", "update_group": return String(localized: "正在安排团队")
        case "ask_user", "show_view": return String(localized: "正在准备问你")
        default: return String(localized: "正在干活")
        }
    }

    static func created(_ row: Object) -> Double { (row["createdAt"] as? NSNumber)?.doubleValue ?? 0 }
}

/// The DS Bot team of the host, as `dsBot` `state` answers it.
@MainActor
final class BotTeamStore: ObservableObject {
    let host: Harness
    let inbox: DSBotInbox?
    @Published var state: Object?
    @Published var issue: String?
    @Published var busy = false
    init(host: Harness, inbox: DSBotInbox? = nil) {
        self.host = host
        self.inbox = inbox
    }

    var bots: [Object] { state?["bots"] as? [Object] ?? [] }
    var rooms: [Object] { state?["rooms"] as? [Object] ?? [] }
    var mainIDs: [String] { state?["mainBotIds"] as? [String] ?? [] }
    var readOnly: String? { state?["readOnly"] as? String }
    var work: Object { state?["work"] as? Object ?? [:] }
    func bot(_ id: String?) -> Object? { bots.first { $0["id"] as? String == id } }
    func isMain(_ id: String) -> Bool { mainIDs.contains(id) }

    func refresh() async {
        do {
            let value = try await host.bot("state", ["locale": AppLanguage.code, "avatars": "ref"]) as? Object
            state = value; issue = nil
            if let value, let inbox, inbox.host === host { inbox.applyState(value) }
        } catch { issue = error.localizedDescription }
    }

    @discardableResult
    func change(_ method: String, _ args: Object) async -> Any? {
        busy = true
        defer { busy = false }
        do {
            let value = try await host.bot(method, args)
            await refresh()
            return value
        } catch { issue = error.localizedDescription; return nil }
    }
}

/// DS Bot: the main Bots first, then the others; the group chats; 新建 Bot / 新建群聊.
struct BotPanel: View {
    let host: Harness
    let open: (String) -> Void
    @StateObject private var store: BotTeamStore
    @State private var newRoom = false
    @State private var details: String?
    @State private var editingRoom: String?

    init(host: Harness, inbox: DSBotInbox? = nil, open: @escaping (String) -> Void) {
        self.host = host; self.open = open
        _store = StateObject(wrappedValue: BotTeamStore(host: host, inbox: inbox))
    }

    var body: some View {
        List {
            if let state = store.state {
                #if os(iOS)
                Section {
                    Text([String(localized: "\(store.bots.count) 个 Bot"), store.rooms.isEmpty ? nil : String(localized: "\(store.rooms.count) 个群聊")].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(ChatColors.muted)
                }.listRowBackground(Color.clear)
                #endif
                if let issue = store.issue { Section { Text(issue).foregroundStyle(.red) } }
                let mains = store.mainIDs.compactMap(store.bot)
                let others = store.bots.filter { !store.isMain($0["id"] as? String ?? "") }.sorted { BotWords.created($0) > BotWords.created($1) }
                Section("Bot") {
                    ForEach(Array((mains + others).enumerated()), id: \.offset) { _, bot in botRow(bot, questions: state["questions"] as? Object ?? [:]) }
                    NavigationLink { NewBotPage(store: store) } label: { Label("新建 Bot", systemImage: "plus") }
                        .disabled(store.readOnly != nil)
                }.listRowBackground(ChatColors.chip)
                Section {
                    ForEach(Array(store.rooms.sorted { BotWords.created($0) > BotWords.created($1) }.enumerated()), id: \.offset) { _, room in roomRow(room) }
                    Button { newRoom = true } label: { Label("新建群聊", systemImage: "person.3") }
                        .disabled(store.readOnly != nil || store.bots.count < 2)
                } header: { Text("群聊") } footer: { if let readOnly = store.readOnly { Text(readOnly) } }
                .listRowBackground(ChatColors.chip)
            } else if let issue = store.issue {
                Section {
                    HostEmptyState(symbol: "exclamationmark.triangle", title: String(localized: "没能读取 AI 团队"), message: issue, action: (String(localized: "重试"), { Task { await store.refresh() } }))
                }.listRowBackground(Color.clear)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
        }
        .groupedList().scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .disabled(store.busy).task { await store.refresh() }.refreshable { await store.refresh() }
        .sheet(isPresented: $newRoom) {
            NewRoomSheet(store: store) { newRoom = false }.desktopSheet(width: 460, height: 380)
        }
        .navigationDestination(item: $details) { id in BotDetailsPage(store: store, id: id, open: open) }
        .navigationDestination(item: $editingRoom) { id in RoomSettingsPage(store: store, id: id) }
        #if os(macOS)
        .toolbar {
            Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
        }
        #endif
    }

    private func avatar(_ name: String, working: Bool, color: String? = nil) -> some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()).font(.headline).foregroundStyle(ChatColors.ink)
            .frame(width: 40, height: 40).background(ChatColors.muted.opacity(0.14), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if working { Circle().fill(Color.accentColor).frame(width: 11, height: 11).overlay(Circle().strokeBorder(ChatColors.chip, lineWidth: 2)) }
            }.accessibilityHidden(true)
    }

    @ViewBuilder private func botRow(_ bot: Object, questions: Object) -> some View {
        if let id = bot["id"] as? String {
            let name = bot["name"] as? String ?? id
            let work = (store.work["bots"] as? Object)?[id] as? Object
            let doing = BotWords.work(work, activity: (store.state?["activity"] as? Object)?[id] as? String)
            let session = bot["sessionId"] as? String
            let asked = questions[session ?? ""] != nil || questions[id] != nil
            let role = bot["role"] as? String ?? ""
            let room = (work?["roomId"] as? String).flatMap { roomID in store.rooms.first { $0["id"] as? String == roomID }?["name"] as? String }
            let line = doing.map { room == nil ? $0 : $0 + " · " + room! } ?? (asked ? String(localized: "等你回答") : bot["waiting"] as? Bool == true ? String(localized: "选一个模型开始") : role.isEmpty ? String(localized: "还没有对话") : role)
            let tint: Color = doing != nil ? .accentColor : asked || bot["waiting"] as? Bool == true ? .orange : ChatColors.muted
            HStack(spacing: 12) {
                Button { open(session ?? id) } label: {
                    HStack(spacing: 12) {
                        avatar(name, working: work != nil)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(verbatim: name).font(.body.weight(.medium)).foregroundStyle(ChatColors.ink)
                                if store.isMain(id) { HostStateChip(label: String(localized: "主"), tone: .busy) }
                            }
                            #if os(macOS)
                            if doing != nil || asked || bot["waiting"] as? Bool == true {
                                Text(verbatim: line).font(.callout).foregroundStyle(tint).lineLimit(1)
                            }
                            #else
                            Text(verbatim: line).font(.caption).foregroundStyle(tint).lineLimit(1)
                            #endif
                        }
                        Spacer(minLength: 0)
                        if let inbox = store.inbox { DSBotUnreadBadge(inbox: inbox, conversation: id) }
                    }.contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([name, store.isMain(id) ? String(localized: "主 Bot") : nil, line].compactMap { $0 }.joined(separator: String(localized: "，")))
                }.buttonStyle(.borderless)
                Button { details = id } label: { Image(systemName: "info.circle").font(.title3) }
                    .buttonStyle(.borderless).accessibilityLabel(name + String(localized: " · 资料")).accessibilityIdentifier("botDetails-" + id)
            }
            .contextMenu {
                Button(store.isMain(id) ? "取消主 Bot" : "设为主 Bot") { Task { await store.change("set-main", ["id": id, "main": !store.isMain(id)]) } }
                Button("复制 Bot") { Task { await store.change("duplicate-bot", ["id": id]) } }
            }
        }
    }

    @ViewBuilder private func roomRow(_ room: Object) -> some View {
        if let id = room["id"] as? String {
            let name = room["name"] as? String ?? id
            let members = room["members"] as? [String] ?? []
            let working = ((store.work["rooms"] as? Object)?[id] as? [Object] ?? []).map { store.bot($0["botId"] as? String)?["name"] as? String ?? "Bot" }
            let waiting = (store.work["approvals"] as? [Object] ?? []).contains { $0["roomId"] as? String == id && $0["answerable"] as? Bool == true }
            let preview = (room["preview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = waiting ? String(localized: "有成员等你批准") : !working.isEmpty ? (working.count == 1 ? working[0] + String(localized: " 正在干活") : working.prefix(2).joined(separator: String(localized: "、")) + String(localized: " 正在干活"))
                : preview.isEmpty ? String(localized: "\(members.count) 位成员") : preview
            Button { open(room["sessionId"] as? String ?? id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.fill").font(.callout).foregroundStyle(ChatColors.muted)
                        .frame(width: 40, height: 40).background(ChatColors.muted.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name).font(.body.weight(.medium)).foregroundStyle(ChatColors.ink)
                        #if os(macOS)
                        if waiting || !working.isEmpty {
                            Text(verbatim: line).font(.callout).foregroundStyle(waiting ? Color.orange : Color.accentColor).lineLimit(1)
                        }
                        #else
                        Text(verbatim: line).font(.caption).foregroundStyle(waiting ? Color.orange : working.isEmpty ? ChatColors.muted : Color.accentColor).lineLimit(1)
                        #endif
                    }
                    Spacer(minLength: 0)
                    if let inbox = store.inbox { DSBotUnreadBadge(inbox: inbox, conversation: id) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .contextMenu {
                Button("编辑") { editingRoom = id }
                Button("删除", role: .destructive) { Task { await store.change("delete-room", ["id": id]) } }
            }
        }
    }
}

/// A Bot's details: 资料, 用量, 记忆, 设为主 Bot and 删除 Bot.
private struct BotDetailsPage: View {
    @ObservedObject var store: BotTeamStore
    let id: String
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var instructions = ""
    @State private var folder = ""
    @State private var usage: Object?
    @State private var usageError: String?
    @State private var memory: Object?
    @State private var memoryError: String?
    @State private var newMemory = ""
    @State private var adding = false
    @State private var deleting = false
    @State private var loaded = false

    var body: some View {
        List {
            if let bot = store.bot(id) {
                let title = bot["name"] as? String ?? id
                Section {
                    HStack(spacing: 14) {
                        Text(String(title.prefix(1)).uppercased()).font(.title2.weight(.semibold))
                            .frame(width: 60, height: 60).background(ChatColors.muted.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(verbatim: title).font(.title3.weight(.semibold))
                                if store.isMain(id) { HostStateChip(label: String(localized: "主"), tone: .busy) }
                            }
                            if let role = bot["role"] as? String, !role.isEmpty { Text(verbatim: role).font(.subheadline).foregroundStyle(ChatColors.muted) }
                        }
                    }
                    Button("打开对话") { open(bot["sessionId"] as? String ?? id) }
                }.listRowBackground(Color.clear)
                Section("资料") {
                    TextField("名字", text: $name, prompt: Text("比如：写手"))
                    TextField("角色", text: $role, prompt: Text("一句话说它是做什么的"))
                    TextField("说明", text: $instructions, prompt: Text("它该怎么做事"), axis: .vertical).lineLimit(2...8)
                    TextField("文件夹", text: $folder, prompt: Text("团队文件夹")).noAutomaticCapitalization().autocorrectionDisabled()
                    Button("保存") { save(bot) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !changed(bot))
                }.listRowBackground(ChatColors.chip)
                Section {
                    if let usage {
                        usageRow(String(localized: "近 24 小时"), usage["day"] as? Object)
                        usageRow(String(localized: "近 7 天"), usage["week"] as? Object)
                        usageRow(String(localized: "近 30 天"), usage["month"] as? Object)
                        if usage["scanning"] as? Bool == true { Text("正在统计历史对话，数据稍后补全。").font(.caption).foregroundStyle(ChatColors.muted) }
                    } else if let usageError { Text(usageError).font(.caption).foregroundStyle(ChatColors.muted) }
                    else { ProgressView().frame(maxWidth: .infinity) }
                } header: {
                    HStack { Text("用量"); Spacer(); Button("刷新") { Task { await loadUsage() } }.font(.caption) }
                }.listRowBackground(ChatColors.chip)
                Section {
                    if let memory {
                        let entries = memory["entries"] as? [Object] ?? []
                        if let summary = (memory["summary"] as? Object)?["text"] as? String, !summary.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("概要").font(.caption).foregroundStyle(ChatColors.muted)
                                Text(verbatim: summary).font(.callout)
                            }
                        }
                        if entries.isEmpty { Text("还没有记忆").foregroundStyle(ChatColors.muted) }
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            Text(verbatim: entry["text"] as? String ?? "").font(.callout).textSelection(.enabled)
                        }
                    } else if let memoryError { Text("没能读取记忆").foregroundStyle(ChatColors.muted); Text(memoryError).font(.caption) }
                    else { ProgressView().frame(maxWidth: .infinity) }
                    Button { adding = true } label: { Label("添加记忆", systemImage: "plus") }
                } header: { Text(((memory?["entries"] as? [Any])?.count).map { "记忆 · \($0)" } ?? "记忆") }
                .listRowBackground(ChatColors.chip)
                Section {
                    Button(store.isMain(id) ? "取消主 Bot" : "设为主 Bot") { Task { await store.change("set-main", ["id": id, "main": !store.isMain(id)]) } }
                    Button("复制 Bot") { Task { await store.change("duplicate-bot", ["id": id]) } }
                    Button("删除 Bot", role: .destructive) { deleting = true }
                }.listRowBackground(ChatColors.chip)
            } else {
                Section { HostEmptyState(symbol: "person.crop.circle.badge.questionmark", title: String(localized: "这个 Bot 已不在")) }.listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle(store.bot(id)?["name"] as? String ?? "Bot").inlineNavigationTitle()
        .disabled(store.busy || store.readOnly != nil)
        .task {
            guard !loaded, let bot = store.bot(id) else { return }
            loaded = true
            name = bot["name"] as? String ?? ""; role = bot["role"] as? String ?? ""
            instructions = bot["instructions"] as? String ?? ""; folder = bot["workDir"] as? String ?? ""
            await loadUsage(); await loadMemory()
        }
        .alert("添加记忆", isPresented: $adding) {
            TextField("比如：回复尽量简短", text: $newMemory)
            Button("添加") {
                let text = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
                newMemory = ""
                guard !text.isEmpty else { return }
                Task {
                    if let value = try? await store.host.bot("memory-add", ["botId": id, "text": text]) as? Object { memory = value }
                    else { await loadMemory() }
                }
            }
            Button("取消", role: .cancel) { newMemory = "" }
        }
        .confirmationDialog("删除「\(store.bot(id)?["name"] as? String ?? "Bot")」？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除 Bot", role: .destructive) { Task { await store.change("delete-bot", ["id": id]); dismiss() } }
        } message: { Text("它的对话还在，记忆会移到归档里。") }
    }

    private func changed(_ bot: Object) -> Bool {
        name != bot["name"] as? String ?? "" || role != bot["role"] as? String ?? "" || instructions != bot["instructions"] as? String ?? ""
            || folder != bot["workDir"] as? String ?? ""
    }

    private func save(_ bot: Object) {
        var args: Object = ["id": id]
        if name != bot["name"] as? String ?? "" { args["name"] = name.trimmingCharacters(in: .whitespaces) }
        if role != bot["role"] as? String ?? "" { args["role"] = role }
        if instructions != bot["instructions"] as? String ?? "" { args["instructions"] = instructions }
        if folder != bot["workDir"] as? String ?? "" { args["workDir"] = folder }
        Task { await store.change("update-bot", args) }
    }

    private func usageRow(_ label: String, _ totals: Object?) -> some View {
        let number = { (key: String) in (totals?[key] as? NSNumber)?.intValue ?? 0 }
        let tokens = number("input") + number("cacheRead") + number("cacheWrite") + number("output")
        return HStack {
            Text(label)
            Spacer()
            Text(String(localized: "用量 ") + HostPanelFormat.tokens(tokens) + String(localized: " · \(number("calls")) 次调用")).font(.callout.monospacedDigit()).foregroundStyle(ChatColors.muted)
        }
    }

    private func loadUsage() async {
        do { usage = try await store.host.bot("usage-summary", ["botId": id, "timeZone": TimeZone.current.identifier]) as? Object; usageError = nil }
        catch { usageError = error.localizedDescription }
    }

    private func loadMemory() async {
        do { memory = try await store.host.bot("memory-view", ["botId": id]) as? Object; memoryError = nil }
        catch { memoryError = error.localizedDescription }
    }
}

/// 新建 Bot: 名字, 角色, 说明.
private struct NewBotPage: View {
    @ObservedObject var store: BotTeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var instructions = ""
    @State private var creating = false

    var body: some View {
        Form {
            Section("资料") {
                TextField("名字", text: $name, prompt: Text("比如：写手"))
                TextField("角色", text: $role, prompt: Text("一句话说它是做什么的"))
                TextField("说明", text: $instructions, prompt: Text("它该怎么做事，有什么要注意的"), axis: .vertical).lineLimit(3...10)
            }.listRowBackground(ChatColors.chip)
            if let issue = store.issue, creating == false, store.state == nil { Section { Text(issue).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("新建 Bot").inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if creating { ProgressView() } else {
                    Button("创建") {
                        creating = true
                        var args: Object = ["name": name.trimmingCharacters(in: .whitespaces)]
                        if !role.isEmpty { args["role"] = role }
                        if !instructions.isEmpty { args["instructions"] = instructions }
                        Task {
                            let created = await store.change("create-bot", args)
                            creating = false
                            if created != nil { dismiss() }
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// 新建群聊: an optional name and at least two Bots.
private struct NewRoomSheet: View {
    @ObservedObject var store: BotTeamStore
    let done: () -> Void
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("群名（可选）", text: $name)
                Section {
                    ForEach(Array(store.bots.enumerated()), id: \.offset) { _, bot in
                        if let id = bot["id"] as? String {
                            Toggle(bot["name"] as? String ?? id, isOn: Binding(get: { members.contains(id) }, set: { on in
                                if on { members.insert(id) } else { members.remove(id) }
                            }))
                        }
                    }
                } header: {
                    #if os(macOS)
                    Text(members.count < 2 ? "至少选两个 Bot" : "成员 · 已选 \(members.count)")
                    #else
                    Text(members.isEmpty ? "成员" : "成员 · 已选 \(members.count)")
                    #endif
                } footer: {
                    #if os(iOS)
                    if members.count < 2 { Text("至少选两个 Bot") }
                    #endif
                }
            }.navigationTitle("新建群聊").inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    if creating { ProgressView() } else {
                        Button("创建") {
                            creating = true
                            var args: Object = ["members": Array(members)]
                            let trimmed = name.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { args["name"] = trimmed }
                            Task { let created = await store.change("create-room", args); creating = false; if created != nil { done() } }
                        }.disabled(members.count < 2)
                    }
                }
            }
        }
    }
}

/// A group chat's name and 工作目录.
private struct RoomSettingsPage: View {
    @ObservedObject var store: BotTeamStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""

    var body: some View {
        Form {
            TextField("名称", text: $name)
            TextField("文件夹", text: $folder, prompt: Text("团队文件夹")).noAutomaticCapitalization().autocorrectionDisabled()
        }
        .navigationTitle("群聊").inlineNavigationTitle()
        .onAppear {
            let room = store.rooms.first { $0["id"] as? String == id }
            name = room?["name"] as? String ?? ""; folder = room?["workDir"] as? String ?? ""
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await store.change("update-room", ["id": id, "name": name, "workDir": folder]); dismiss() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
