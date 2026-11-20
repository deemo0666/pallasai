import SwiftUI

enum HostPanel: String, Identifiable, CaseIterable {
    case details = "对话详情", deliverables = "产出的文件", sessions = "设备上的对话", search = "搜索对话", models = "切换模型", files = "文件", workspaces = "文件夹", plugins = "插件清单", actions = "工具记录", tasks = "自动化任务", goal = "计划与目标", terminal = "终端", export = "导出对话", subagents = "子任务", config = "运行参数", bundles = "插件", skills = "技能", bots = "AI 团队", permission = "权限", jobs = "后台命令"
    var symbol: String {
        switch self {
        case .details: "info.circle"
        case .permission: "lock.shield"
        case .jobs: "gearshape.2"
        case .deliverables: "doc.on.doc"
        case .sessions: "bubble.left.and.bubble.right"
        case .search: "magnifyingglass"
        case .models: "cpu"
        case .files: "doc.text.magnifyingglass"
        case .workspaces: "folder"
        case .plugins: "list.bullet.indent"
        case .actions: "list.bullet.rectangle"
        case .tasks: "calendar.badge.clock"
        case .goal: "scope"
        case .terminal: "terminal"
        case .export: "archivebox"
        case .subagents: "point.3.connected.trianglepath.dotted"
        case .config: "slider.horizontal.3"
        case .bundles: "puzzlepiece.extension"
        case .skills: "book"
        case .bots: "antenna.radiowaves.left.and.right"
        }
    }
    var id: Self { self }
}

private struct HostRow: Identifiable {
    let id: String
    let name: String
    var detail = ""
    var group = ""
    var efforts: [String] = []
    var defaultEffort: String?
}

private struct HostSkill: Identifiable {
    let name: String
    let description: String
    let usage: String?
    let path: String?
    let manualOnly: Bool
    var id: String { name }

    init(_ metadata: Object) throws {
        guard let name = metadata["name"] as? String, !name.isEmpty,
              name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let description = metadata["description"] as? String else { throw HostError(String(localized: "没能读取技能。请稍后重试。")) }
        self.name = name
        self.description = description
        usage = metadata["whenToUse"] as? String
        path = metadata["path"] as? String
        manualOnly = metadata["modelInvocable"] as? Bool == false
    }

    func workspacePath(in root: String) -> String? {
        guard let path, root.hasPrefix("/"), path.hasPrefix("/") else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty || relative.split(separator: "/").contains("..") ? nil : relative
    }
}

struct HostPanelView: View {
    let panel: HostPanel
    @ObservedObject var chat: Conversation
    let host: Harness
    var editingDefaults = false
    /// 由外壳推入：已经在根导航栈里，用系统的返回。
    var pushed = false
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [HostRow] = []
    @State private var note: String?
    @State private var search = ""
    @State private var hits: [HostRow] = []
    @State private var searchNote: String?
    @State private var searching = false
    @State private var skills: [HostSkill] = []
    @State private var activeSkill: HostSkill?
    @State private var installingSkill = false
    @State private var removingSkill: HostSkill?
    @State private var fileText: String?
    @State private var selectedFile: String?
    @State private var fileVersion: String?
    @State private var nextLine: Int?
    @State private var loading = false
    @State private var defaults: HostModelDefaultSettings?
    @State private var draftDefault: HostModelDefault?
    @State private var defaultModelID = ""
    @State private var modelGroup = ""
    @State private var editingID: String?
    @State private var title = ""

    private var activeModelID: String {
        if editingDefaults, let draftDefault { return draftDefault.provider + "/" + draftDefault.model }
        return chat.modelName.isEmpty ? defaultModelID : chat.modelProvider + "/" + chat.modelName
    }
    private var activeEffort: String? { editingDefaults ? draftDefault?.effort : chat.modelEffort }
    private func shownEffort(for row: HostRow) -> String? { editingDefaults ? activeEffort : (activeEffort ?? row.defaultEffort) }
    private var canEditModel: Bool { !loading && (!editingDefaults || defaults?.writable == true) }
    private var skillRoot: URL? { host.localEngineHome?.appending(path: "skills", directoryHint: .isDirectory) }

    /// 对话详情 and the entries that open it on one of its tabs.
    private var detailsTab: SessionTab? {
        switch panel {
        case .details, .actions: .trajectory
        case .goal: .progress
        case .subagents: .subagents
        default: nil
        }
    }

    private var heading: String {
        if editingDefaults { return String(localized: "新对话默认模型") }
        return detailsTab == nil ? panel.rawValue.localized : String(localized: "对话详情")
    }

    private var searchPrompt: String {
        switch panel {
        case .sessions, .search: String(localized: "搜索对话")
        case .skills: String(localized: "搜索技能")
        case .models: String(localized: "搜索模型")
        default: String(localized: "搜索插件")
        }
    }

    var body: some View {
        if pushed { page } else { NavigationStack { page } }
    }

    private var page: some View {
        content
        .safeAreaInset(edge: .top, spacing: 0) {
            if let event = chat.interactions.first {
                HostInteractionView(event: event, chat: chat).id(event["eventId"] as? String)
            }
        }.navigationTitle(heading)
        .task { await load() }
        .toolbar {
            if editingDefaults {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveDefault() }.disabled(!canEditModel || draftDefault == defaults?.value || !rows.contains { $0.id == activeModelID })
                }
            } else if !pushed { ToolbarItem { Button("完成") { dismiss() } } }
        }
        .alert("重命名对话", isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
            TextField("名称", text: $title)
            Button("保存") {
                if let id = editingID { Task {
                    do { _ = try await host.call("session/rename", ["sessionId": id, "title": title]); await load() }
                    catch { note = error.localizedDescription }
                } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        if let tab = detailsTab {
            SessionDetailsView(chat: chat, host: host, initial: tab) { dismiss() }
        } else {
            switch panel {
            case .bots: BotPanel(host: host) { id in dismiss(); Task { await chat.openSession(id, bot: true) } }
            case .deliverables: HostDeliverablesView(chat: chat, host: host)
            case .config: HostSettings(host: host)
            case .bundles: HostPluginsScreen(host: host)
            case .tasks: HostTasks(host: host) { id in dismiss(); Task { await chat.openSession(id) } }
            case .terminal: TerminalPanel(host: host)
            case .permission: HostPermissionView(host: host)
            case .jobs: HostJobsView(host: host)
            case .workspaces: HostWorkspacesView(host: host, chat: chat)
            case .files: WorkspaceBrowserPage(chat: chat, host: host)
            case .export: SessionExportView(chat: chat, host: host)
            default: listContent
            }
        }
    }

    private var listContent: some View {
        listLayout
        .task(id: panel == .search ? search : "") { await searchContent() }
        .sheet(isPresented: $installingSkill) {
            if let skillRoot { SkillInstallSheet(root: skillRoot) { Task { await reloadSkills() } } }
        }
        .confirmationDialog(String(localized: "删除技能「\(removingSkill?.name ?? "")」？"),
                            isPresented: Binding(get: { removingSkill != nil }, set: { if !$0 { removingSkill = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let skill = removingSkill, let folder = SkillInstall.installedFolder(forSkillPath: skill.path, root: skillRoot) else { return }
                do {
                    try SkillInstall.remove(folder)
                    activeSkill = nil
                    Task { await reloadSkills() }
                } catch { note = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder private var listLayout: some View {
        #if os(macOS)
        if panel == .skills {
            VStack(alignment: .leading, spacing: 12) {
                if activeSkill == nil {
                    HStack {
                        TextField("搜索技能", text: $search)
                            .textFieldStyle(.roundedBorder)
                        if skillRoot != nil { skillInstallButton }
                    }
                }
                if let note { Text(note).foregroundStyle(.red) }
                if loading { ProgressView() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        skillRows
                        selectedFileContents
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(16)
        } else { conventionalList }
        #else
        conventionalList
        #endif
    }

    private var conventionalList: some View {
        List {
            if let note { Text(note).foregroundStyle(.red) }
            if loading { ProgressView() }
            if panel == .sessions {
                Button("新对话") { dismiss(); Task { await chat.openSession(nil) } }
            }
            if panel == .models {
                if editingDefaults {
                    if draftDefault?.remember != nil {
                        Picker("新对话默认", selection: Binding(get: { draftDefault?.remember ?? true }, set: { draftDefault?.remember = $0 })) {
                            Text("沿用上次").tag(true); Text("固定默认").tag(false)
                        }.pickerStyle(.segmented).disabled(!canEditModel)
                    } else if defaults != nil { LabeledContent("新对话默认", value: String(localized: "沿用上次")) }
                    if defaults?.writable == false { Text("这台设备的设置是只读的。") }
                    if note != nil { Button("重新加载") { Task { await load() } }.disabled(loading) }
                }
                let providers = rows.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if providers.count > 1 {
                    Picker("模型服务", selection: $modelGroup) {
                        ForEach(providers, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            if panel == .skills { skillRows }
            if fileText != nil {
                selectedFileContents
            } else if panel == .search {
                searchRows
            } else {
                ForEach(rows.filter { (panel != .models || $0.group == modelGroup) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { row in
                    rowButton(row)
                }
                if panel == .models, let active = rows.first(where: { $0.id == activeModelID && $0.group == modelGroup }), !active.efforts.isEmpty {
                    Section("思考深度") {
                        if editingDefaults {
                            Button { selectModel(active, effort: nil) } label: {
                                HStack {
                                    Text("模型默认"); Spacer()
                                    if activeEffort == nil { Image(systemName: "checkmark") }
                                }
                            }.disabled(!canEditModel).accessibilityAddTraits(activeEffort == nil ? .isSelected : [])
                        }
                        ForEach(active.efforts, id: \.self) { effort in
                            Button { selectModel(active, effort: effort) } label: {
                                HStack {
                                    Text(ModelBudget.effortLabel(effort)); Spacer()
                                    if effort == shownEffort(for: active) { Image(systemName: "checkmark") }
                                }
                            }.disabled(!canEditModel).accessibilityIdentifier("hostEffort-" + effort)
                                .accessibilityAddTraits(effort == shownEffort(for: active) ? .isSelected : [])
                        }
                    }
                }
            }
        }.searchable(text: $search, prompt: Text(searchPrompt))
    }

    @ViewBuilder private var selectedFileContents: some View {
        if let fileText {
            if let selectedFile, let nextLine {
                Button("读取更多行") { Task { await readFile(selectedFile, offset: nextLine) } }.disabled(loading)
            }
            Text(verbatim: fileText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private var skillInstallButton: some View {
        Button { installingSkill = true } label: { Label("安装技能", systemImage: "plus") }
            .accessibilityIdentifier("hostSkillInstall")
    }

    /// The engine notices the folder change on its own; give its watcher a moment before asking.
    private func reloadSkills() async {
        for delay in [0.6, 1.5] {
            try? await Task.sleep(for: .seconds(delay))
            await load()
        }
    }

    private func rowButton(_ row: HostRow) -> some View {
        Button { select(row) } label: {
            VStack(alignment: .leading) {
                HStack {
                    Text(verbatim: row.name)
                    if panel == .models, row.id == activeModelID {
                        Image(systemName: "checkmark")
                    }
                }
                if !row.detail.isEmpty { Text(verbatim: row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.disabled(loading || panel == .plugins || (panel == .models && !canEditModel))
        .accessibilityAddTraits(panel == .models && row.id == activeModelID ? .isSelected : [])
        .swipeActions {
            if panel == .sessions || panel == .search { Button("重命名") { title = row.name; editingID = row.id } }
        }
    }

    /// 搜索对话: title matches from the list, then the Host's message-text matches.
    @ViewBuilder private var searchRows: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            ForEach(rows) { rowButton($0) }
        } else {
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let titled = rows.filter { row in terms.allSatisfy { row.name.lowercased().contains($0) } }
            let extra = hits.filter { hit in !titled.contains { $0.id == hit.id } }
            ForEach(titled) { rowButton($0) }
            ForEach(extra) { rowButton($0) }
            if searching { Text("正在搜索消息内容…").font(.caption).foregroundStyle(ChatColors.muted) }
            if let searchNote { Text(searchNote).font(.caption).foregroundStyle(ChatColors.muted) }
            if !searching, !loading, titled.isEmpty, extra.isEmpty {
                HostEmptyState(symbol: "magnifyingglass", title: String(localized: "没有相关对话"))
            }
        }
    }

    @ViewBuilder private var skillRows: some View {
        if let skill = activeSkill {
            Button("返回技能列表") {
                activeSkill = nil; selectedFile = nil; fileText = nil; fileVersion = nil; nextLine = nil; note = nil
            }
            Section("/" + skill.name) {
                Text(skill.description)
                if let usage = skill.usage { LabeledContent("适用", value: usage) }
                if skill.manualOnly { Text("仅手动调用").font(.caption) }
                if fileText == nil, let relative = skill.workspacePath(in: chat.workspace) {
                    Button("查看技能内容") {
                        selectedFile = relative; Task { await readFile(relative, offset: 1) }
                    }.disabled(loading)
                }
            }
            Button("在对话里用") {
                let command = "/" + skill.name + " "
                guard chat.connection === host else { return }
                if chat.draft == "/" + skill.name { chat.draft = command }
                else if !chat.draft.hasPrefix(command) { chat.draft = command + chat.draft }
                dismiss()
            }
            Button("新对话里用") {
                dismiss()
                Task { if chat.connection === host { await chat.openSession(nil, initialDraft: "/" + skill.name + " ") } }
            }
            if SkillInstall.installedFolder(forSkillPath: skill.path, root: skillRoot) != nil {
                Button("删除技能", role: .destructive) { removingSkill = skill }.accessibilityIdentifier("hostSkillRemove")
            }
        } else {
            #if os(iOS)
            if skillRoot != nil { skillInstallButton }
            #endif
            let matches = skills.filter { item in
                search.isEmpty || [item.name, item.description, item.usage ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
            }
            if !loading, note == nil, matches.isEmpty {
                Text(search.isEmpty ? "还没有技能" : "没有匹配的技能").foregroundStyle(.secondary)
            }
            ForEach(matches) { skill in
                Button { activeSkill = skill } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("/" + skill.name).font(.headline)
                        #if os(iOS)
                        Text(skill.description).font(.subheadline).foregroundStyle(.secondary)
                        #endif
                        if skill.manualOnly { Text("仅手动调用").font(.caption) }
                    }
                }.accessibilityIdentifier("hostSkill-" + skill.name)
            }
        }
    }

    private func select(_ row: HostRow) {
        switch panel {
        case .sessions, .search: dismiss(); Task { await chat.openSession(row.id) }
        case .models: selectModel(row, effort: nil)
        default: break
        }
    }

    private func selectModel(_ row: HostRow, effort: String?) {
        guard canEditModel else { return }
        if editingDefaults {
            draftDefault?.provider = row.group; draftDefault?.model = row.name; draftDefault?.effort = effort
            return
        }
        loading = true; note = nil
        Task {
            defer { loading = false }
            do { try await chat.selectModel(on: host, provider: row.group, model: row.name, effort: effort) }
            catch { note = error.localizedDescription }
        }
    }

    private func saveDefault() {
        guard canEditModel, let defaults, let draftDefault else { return }
        loading = true; note = nil
        Task {
            defer { loading = false }
            do {
                self.defaults = try await defaults.save(draftDefault, on: host)
                if chat.connection === host { dismiss() }
            }
            catch { self.defaults = nil; note = error.localizedDescription }
        }
    }

    private func readFile(_ file: String, offset: Int) async {
        loading = true
        defer { loading = false }
        do {
            let page = try await host.rpc("workspaceFiles/read", args: ["workspaceFileScopeId": host.sessionID, "path": file, "range": ["offset": offset]])
            guard selectedFile == file else { return }
            guard let text = page["text"] as? String, let lines = page["lines"] as? Int, let version = page["version"] as? String else {
                throw HostError(String(localized: "此文件无法作为文本显示。"))
            }
            guard offset == 1 || version == fileVersion else {
                nextLine = nil
                throw HostError(String(localized: "文件已更改，请重新打开。"))
            }
            fileVersion = version
            fileText = offset == 1 ? text : (fileText ?? "") + (lines > 0 ? "\n" + text : "")
            nextLine = page["eof"] as? Bool == false && lines > 0 ? offset + lines : nil
            note = nil
        } catch { if selectedFile == file { note = error.localizedDescription } }
    }

    private func searchContent() async {
        guard panel == .search else { return }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        hits = []; searchNote = nil
        guard !query.isEmpty, query.count <= 500 else { searching = false; return }
        searching = true
        defer { searching = false }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let value = try await host.call("session/search", ["query": query])
            try Task.checkCancellation()
            let titles = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            hits = (value["items"] as? [Object] ?? []).compactMap { item in
                guard let id = item["sessionId"] as? String else { return nil }
                return HostRow(id: id, name: titles[id] ?? String(localized: "未命名对话"), detail: item["snippet"] as? String ?? "")
            }
            if value["hasMore"] as? Bool == true { searchNote = String(localized: "内容匹配仅列出最相关的 20 个对话") }
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            let disabled = (error as? HostError)?.code == "gateway/internal"
            searchNote = disabled ? String(localized: "这台设备仅支持按标题搜索") : String(localized: "内容搜索失败，仅显示标题匹配")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        note = nil
        rows = []
        do {
            switch panel {
            case .sessions, .search:
                let data = try await host.sessionList()
                rows = (data["items"] as? [Object] ?? []).compactMap { item in
                    guard let id = item["sessionId"] as? String, item["origin"] as? String != "subagent" else { return nil }
                    let values = (item["projections"] as? Object)?["values"] as? Object
                    let name = (values?["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? String(localized: "未命名对话")
                    return HostRow(id: id, name: name, detail: item["cwd"] as? String ?? "")
                }
            case .models:
                do { try await chat.reloadAvailableModels(on: host) }
                catch {
                    guard chat.modelCatalog != nil else { throw error }
                    note = HostError.explain(error)
                }
                guard let catalog = chat.modelCatalog else { return }
                defaultModelID = catalog.fallback.map { $0.channel + "/" + $0.model } ?? ""
                rows = catalog.channels.flatMap(\.models).map { model in
                    HostRow(id: model.channel + "/" + model.model, name: model.model, detail: model.channel, group: model.channel,
                            efforts: model.efforts.map(\.id), defaultEffort: model.defaultEffort)
                }
                if editingDefaults {
                    defaults = nil; draftDefault = nil
                    let settings = try await HostModelDefaultSettings.read(host)
                    defaults = settings; draftDefault = settings.value
                }
                let selectedProvider = editingDefaults ? draftDefault?.provider : (chat.modelProvider.isEmpty ? catalog.fallback?.channel : chat.modelProvider)
                modelGroup = rows.first(where: { $0.group == selectedProvider })?.group ?? rows.first?.group ?? ""
            case .plugins:
                let data = try await host.rpc("pluginInventory/list", args: [:])
                rows = (data["entries"] as? [Object] ?? []).compactMap { item in
                    guard let name = item["moduleName"] as? String, let id = item["entryId"] as? String else { return nil }
                    return HostRow(id: id, name: name, detail: item["enabled"] as? Bool == true ? String(localized: "已启用") : String(localized: "已停用"))
                }
            case .skills:
                let data = try await host.call("skills/list", ["sessionId": host.sessionID])
                guard let items = data["skills"] as? [Object] ?? data["items"] as? [Object] else { throw HostError(String(localized: "没能读取技能。请稍后重试。")) }
                skills = try items.map(HostSkill.init)
            default: break
            }
        } catch { if !Task.isCancelled { note = error.localizedDescription } }
    }
}

// MARK: - 插件

/// One `pluginManager/listBundles` row.
struct HostPluginBundle: Identifiable {
    enum Group { case installed, official, onDemand, hidden }
    let raw: Object
    var id: String { name }
    var name: String { raw["name"] as? String ?? "" }
    var official: Bool { raw["official"] as? Bool == true }
    var installed: Bool { raw["installed"] as? Bool == true }
    var enabled: Bool { raw["enabled"] as? Bool == true }
    var optional: Bool { raw["optional"] as? Bool == true }
    var removable: Bool { raw["removable"] as? Bool == true }
    var availability: String { raw["availability"] as? String ?? "profile" }
    var version: String? { raw["version"] as? String }
    var source: String? { raw["source"] as? String }
    var readOnlyReason: String? { raw["readOnlyReason"] as? String }
    var installSpec: String? { (raw["installTarget"] as? Object)?["spec"] as? String }
    var meta: Object? { raw["meta"] as? Object }
    var title: String { HostPanelFormat.localized(meta?["title"]) ?? name }
    var summary: String? { HostPanelFormat.localized(meta?["description"]) ?? raw["description"] as? String }
    var components: [String] {
        (raw["rows"] as? [Object] ?? []).map { HostPanelFormat.localized(($0["meta"] as? Object)?["title"]) ?? $0["moduleName"] as? String ?? "" }
    }
    var isOnDemand: Bool { official && !installed && availability == "missing" && installSpec != nil }
    var switchable: Bool { readOnlyReason == nil && (installed || optional) }
    var group: Group {
        if official && PluginPolicy.hiddenOfficial.contains(name) { return .hidden }
        if installed { return official ? .official : .installed }
        if optional { return .official }
        if isOnDemand { return .onDemand }
        if raw["error"] is Object, enabled, !official { return .installed }
        return .hidden
    }
    var errorText: String {
        guard let error = raw["error"] as? Object else { return installed && availability == "missing" ? String(localized: "插件文件缺失，重新安装可修复") : "" }
        switch error["code"] as? String {
        case "not-bundle": return String(localized: "这不是能用的插件，没有启用")
        case "incompatible-version": return String(localized: "和当前版本不匹配，没有启用。更新插件后再试")
        default: return String(localized: "没能启用。卸载后重新安装试试")
        }
    }
    /// The raw code and diagnostic behind `errorText`, for the folded 详情.
    var errorDetail: String? { (raw["error"] as? Object).flatMap(HostPluginStore.detail) }
}

/// One market entry from dshfind's format-1 index.
struct HostMarketPlugin: Identifiable {
    let name: String
    let title: String
    let summary: String?
    let author: String?
    let category: String?
    let featured: Bool
    let webOnly: Bool
    let version: String
    let spec: String
    let registry: String?
    let homepage: String?
    let repository: String?
    let haystack: String
    var id: String { name }
}

/// The market catalog: categories and every plugin.
struct HostMarketCatalog {
    static let index = URL(string: "https://api.dshfind.com/market/dsh-index.json")!
    let categories: [(id: String, title: String)]
    let plugins: [HostMarketPlugin]

    static func fetch() async throws -> Self {
        var request = URLRequest(url: index, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw HostError((error as? URLError)?.code == .timedOut ? String(localized: "连接超时，请稍后重试") : String(localized: "连不上插件市场，请检查网络")) }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw HostError(String(localized: "插件市场暂时打不开，请稍后重试"))
        }
        guard data.count <= 32 * 1024 * 1024, let root = try? JSONSerialization.jsonObject(with: data) as? Object,
              root["format"] as? Int == 1, let rows = root["plugins"] as? [Object] else { throw HostError(String(localized: "插件市场暂时打不开，请稍后重试")) }
        return parse(root, rows)
    }

    private static let webCategories: Set<String> = ["ui", "skin", "skins", "theme", "themes", "client", "clients", "web", "webui", "web-ui"]

    static func parse(_ root: Object, _ rows: [Object]) -> Self {
        let declared = ((root["metadata"] as? Object)?["categories"] as? Object) ?? [:]
        var categories: [(id: String, title: String)] = []
        for (id, value) in declared {
            if let title = HostPanelFormat.localized((value as? Object)?["title"]) { categories.append((id, title)) }
        }
        var seen = Set<String>()
        var plugins: [HostMarketPlugin] = []
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty, seen.insert(name).inserted else { continue }
            let versions = (row["versions"] as? [Object] ?? []).compactMap { entry -> (String, Object)? in
                guard let version = entry["version"] as? String, let source = entry["source"] as? Object else { return nil }
                return (version, source)
            }.sorted { $0.0.compare($1.0, options: .numeric) == .orderedDescending }
            guard let (version, source) = versions.first else { continue }
            let spec: String
            switch source["type"] as? String {
            case "npm": spec = name + "@" + version
            case "git":
                guard let url = source["url"] as? String, url.hasPrefix("https://"), let commit = source["commit"] as? String else { continue }
                spec = "git+" + (url.hasSuffix(".git") ? url : url + ".git") + "#" + commit + ((source["path"] as? String).map { "&path:/" + $0 } ?? "")
            default: continue
            }
            let meta = row["metadata"] as? Object ?? [:]
            let category = meta["category"] as? String
            let labels = meta["labels"] as? [String] ?? []
            let title = HostPanelFormat.localized(row["title"]) ?? name
            let summary = HostPanelFormat.localized(row["description"])
            let keywords = meta["keywords"] as? [String] ?? []
            let author = row["author"] as? String
            let web = (category.map { webCategories.contains($0.lowercased()) } ?? false)
                || name.range(of: #"(?:client-ui|web-ui|webui|(?:^|[-/])(?:themes?|skins?)(?:-|$))"#, options: .regularExpression) != nil
            let haystack = ([name, title, summary ?? "", author ?? ""] + keywords).joined(separator: "\n").lowercased()
            plugins.append(HostMarketPlugin(name: name, title: title, summary: summary, author: author, category: category,
                                            featured: labels.contains("featured"), webOnly: web, version: version, spec: spec,
                                            registry: source["registry"] as? String, homepage: row["homepage"] as? String,
                                            repository: (row["repository"] as? Object)?["url"] as? String, haystack: haystack))
        }
        let used = Set(plugins.compactMap(\.category))
        return Self(categories: categories.filter { used.contains($0.id) }.sorted { $0.title < $1.title }, plugins: plugins)
    }
}

/// Shared state of the 插件 page: the host's bundles, the market and running installs.
@MainActor
final class HostPluginStore: ObservableObject {
    static let inventoryChanged = Notification.Name("PallasHostPluginInventoryChanged")
    let host: Harness
    @Published var bundles: [HostPluginBundle]?
    @Published var listError: String?
    @Published var market: HostMarketCatalog?
    @Published var marketError: String?
    @Published var working: Set<String> = []
    @Published var notice: String?
    @Published var failures: [String: String] = [:]
    /// The raw code and diagnostic behind a failure, shown folded under 详情.
    @Published var details: [String: String] = [:]
    private var installs: [String: String] = [:]
    private static var activeChanges: [ObjectIdentifier: Set<String>] = [:]

    var stagesOnlinePackages: Bool {
        #if os(iOS)
        host.usesEmbeddedEngine
        #else
        false
        #endif
    }

    init(host: Harness) { self.host = host }

    private func beginChange(_ name: String) -> Bool {
        guard Self.activeChanges[ObjectIdentifier(host), default: []].insert(name).inserted else { return false }
        working.insert(name)
        return true
    }

    private func endChange(_ name: String) {
        let key = ObjectIdentifier(host)
        Self.activeChanges[key]?.remove(name)
        if Self.activeChanges[key]?.isEmpty == true { Self.activeChanges[key] = nil }
        working.remove(name)
    }

    func refresh() async {
        do {
            let value = try await host.rpcValue("pluginManager/listBundles", args: [:])
            bundles = (value as? [Object] ?? []).map(HostPluginBundle.init)
            listError = nil
        } catch {
            if bundles == nil { listError = HostError.explain(error) } else { notice = String(localized: "刷新失败：") + error.localizedDescription }
        }
    }

    private func refreshAfterChange() async {
        await refresh()
        NotificationCenter.default.post(name: Self.inventoryChanged, object: self)
    }

    func loadMarket() async {
        marketError = nil
        do { market = try await HostMarketCatalog.fetch() } catch { marketError = error.localizedDescription }
    }

    func bundle(named name: String) -> HostPluginBundle? { bundles?.first { $0.name == name } }

    /// The plugin manager's refusal in words a person can act on. The code and the
    /// diagnostic are `detail`'s, never part of this sentence.
    nonisolated static func explain(_ error: Object) -> String {
        switch error["code"] as? String {
        case "incompatible-version": return String(localized: "这个插件和当前版本不匹配。换一个版本，或更新后再装。")
        case "not-bundle": return String(localized: "这不是 Pallas Agent 能用的插件。请到插件市场里找。")
        case "unsupported-platform": return String(localized: "这个插件不支持这台设备。")
        case "already-installed", "ambiguous-install": return String(localized: "这台设备已经装了同名插件。先卸载旧的再装。")
        case "invalid-spec": return String(localized: "安装来源无效。请从插件市场重新安装。")
        case "management-required": return String(localized: "这台设备的插件由管理员统一管理，这里改不了。请联系管理员。")
        case "bundle-in-use", "stop-profile": return String(localized: "插件正在使用中。等相关对话结束后再试。")
        case "not-removable": return String(localized: "这个插件是自带的，不能卸载。")
        default: return String(localized: "没能完成。请稍后重试。")
        }
    }

    /// The refusal's code and diagnostic as they came, for the folded 详情.
    nonisolated static func detail(_ error: Object) -> String? {
        let parts = [error["code"] as? String, error["diagnostic"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// `installed`, `update` or nil (not installed).
    func status(of plugin: HostMarketPlugin) -> String? {
        guard let bundle = bundles?.first(where: { $0.name == plugin.name && ($0.installed || $0.availability == "profile") }) else { return nil }
        if let installed = bundle.version, plugin.version.compare(installed, options: .numeric) == .orderedDescending { return "update" }
        return "installed"
    }

    private func outcome(_ result: Object, done: String) -> String {
        if let error = result["error"] as? Object { return Self.explain(error) }
        switch result["application"] as? String {
        case "restart-required":
            return done + (host.usesEmbeddedEngine ? String(localized: "，重新打开 Pallas Agent 后生效") : String(localized: "，重启电脑上的服务后生效"))
        case "failed": return String(localized: "没能完成。请稍后重试。")
        case "cancelled": return String(localized: "已取消安装")
        default: return done
        }
    }

    func setEnabled(_ bundle: HostPluginBundle, _ on: Bool) async {
        guard beginChange(bundle.name) else { return }
        defer { endChange(bundle.name) }
        do {
            let result = try await host.rpc("pluginManager/setBundleEnabled", args: ["name": bundle.name, "enabled": on])
            if result["error"] != nil || ["restart-required", "failed"].contains(result["application"] as? String ?? "") {
                notice = outcome(result, done: on ? String(localized: "已启用「\(bundle.title)」") : String(localized: "已停用「\(bundle.title)」"))
            }
        } catch { notice = HostError.explain(error) }
        await refreshAfterChange()
    }

    /// The desktop Harness can update versioned registry packages directly.
    func needsReplacing(_ name: String, spec: String? = nil) -> Bool {
        guard bundle(named: name)?.installed == true, host.usesEmbeddedEngine else { return false }
        #if os(macOS)
        return spec.flatMap { registryVersion(name: name, spec: $0) } == nil
        #else
        return true
        #endif
    }

    /// `replacing` removes the installed version first (the person agreed to that); the new
    /// version is downloaded and checked before the old one goes.
    func install(name: String, title: String, spec: String, registry: String?, replacing: Bool = false) async {
        guard beginChange(name) else { return }
        failures[name] = nil; details[name] = nil
        defer { endChange(name) }
        if let refusal = await PluginPolicy.refusal(spec: spec, registry: registry) { failures[name] = refusal; return }
        #if os(macOS)
        if let version = registryVersion(name: name, spec: spec) {
            await updateRegistry(name: name, title: title, version: version, registry: registry)
            return
        }
        #endif
        let replace = needsReplacing(name, spec: spec)
        if replace, !replacing { failures[name] = Self.explain(["code": "already-installed"]); return }
        var spec = spec, registry = registry
        // 本机引擎起不了 pnpm：App 下载并暂存，引擎按已构建目录导入。
        var staged: URL?
        if stagesOnlinePackages, !spec.hasPrefix("/") {
            do { staged = try await PluginDownload.stage(spec: spec, registry: registry).folder }
            catch {
                failures[name] = error.localizedDescription
                details[name] = (error as? PluginDownload.Failure)?.code
                return
            }
            spec = staged!.path; registry = nil
        }
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        let localPath = spec.hasPrefix("/")
        var enabled = true
        #if os(macOS)
        let previousBundle = bundle(named: name)
        let home = host.localEngineHome
        let previous = home.flatMap { LocalPluginFiles.installedImport(named: name, in: $0) }
        var restoreSpec: String?
        if replace, let home, let previousBundle {
            enabled = previousBundle.enabled
            do { restoreSpec = try LocalPluginFiles.restoreSpec(for: previousBundle, in: home) }
            catch { failures[name] = error.localizedDescription; return }
        }
        var snapshot: URL?
        if localPath, let home {
            let folder = URL(filePath: spec, directoryHint: .isDirectory)
            do {
                let retained = try await Task.detached { try LocalPluginFiles.retain(folder, in: home) }.value
                snapshot = retained
                spec = "file:" + retained.path
            } catch { failures[name] = error.localizedDescription; return }
        }
        #endif
        if replace {
            let removal = try? await host.rpc("pluginManager/removeBundle", args: ["name": name])
            guard let removal, removal["error"] == nil, ["applied", "restart-required"].contains(removal["application"] as? String ?? "") else {
                failures[name] = String(localized: "没能卸载旧版本。请稍后重试。")
                details[name] = (removal?["error"] as? Object).flatMap(Self.detail)
                #if os(macOS)
                if removal != nil, let home { LocalPluginFiles.removeIfUnused(snapshot, in: home) }
                #endif
                return
            }
        }
        let request = UUID().uuidString
        installs[name] = request
        var options: Object = ["enabled": enabled, "requestId": request]
        if !localPath { options["saveExact"] = true }
        if let registry { options["registry"] = registry }
        var result: Object?
        do { result = try await host.rpc("pluginManager/installBundle", args: ["spec": spec, "options": options]) }
        catch let error as HostError where error.code != nil {
            failures[name] = String(localized: "没能安装。请稍后重试。")
            details[name] = [error.code, error.message, error.detail].compactMap { $0 }.joined(separator: "\n")
        }
        catch {
            // The answer was lost (a timeout): ask the Host for the running install's result.
            result = try? await host.rpc("pluginManager/waitForInstall", args: ["requestId": request])
            if result == nil { failures[name] = error.localizedDescription }
        }
        installs[name] = nil
        if let result {
            reportInstall(result, name: name, title: title)
            #if os(macOS)
            if let restoreSpec, failures[name] != nil || result["application"] as? String == "cancelled" {
                await restore(name: name, spec: restoreSpec, enabled: previousBundle?.enabled == true,
                              removeFailedVersion: result["stage"] as? String == "enable")
            }
            if let home {
                LocalPluginFiles.removeIfUnused(snapshot, in: home)
                LocalPluginFiles.removeIfUnused(previous, in: home)
            }
            #endif
        }
        #if os(iOS)
        if replace, failures[name] != nil { failures[name] = (failures[name] ?? "") + String(localized: "旧版本已卸载，可以重新安装。") }
        #endif
        await refreshAfterChange()
    }

    private func reportInstall(_ result: Object, name: String, title: String) {
        let text = outcome(result, done: String(localized: "已安装「\(title)」"))
        if result["error"] != nil || result["application"] as? String == "failed" {
            failures[name] = text
            details[name] = (result["error"] as? Object).flatMap(Self.detail)
        } else { notice = text }
    }

    #if os(macOS)
    private func registryVersion(name: String, spec: String) -> String? {
        guard host.usesEmbeddedEngine, bundle(named: name)?.raw["updatable"] as? Bool == true,
              let target = PluginPolicy.npmName(spec), target.name == name else { return nil }
        return target.version
    }

    private func updateRegistry(name: String, title: String, version: String, registry: String?) async {
        let request = UUID().uuidString
        installs[name] = request
        defer { installs[name] = nil }
        var options: Object = ["requestId": request]
        if let registry { options["registry"] = registry }
        do {
            let update = try await host.rpc("pluginManager/updateBundle", args: ["name": name, "version": version, "options": options])
            guard let result = update["result"] as? Object else { throw HostError(String(localized: "没能安装。请稍后重试。")) }
            reportInstall(result, name: name, title: title)
            if let restored = update["restore"] as? Object { reportRestoration(restored, name: name) }
        } catch { failures[name] = HostError.explain(error) }
        await refreshAfterChange()
    }

    private func restore(name: String, spec: String, enabled: Bool, removeFailedVersion: Bool) async {
        if removeFailedVersion {
            let removed = try? await host.rpc("pluginManager/removeBundle", args: ["name": name])
            guard let removed, removed["error"] == nil, ["applied", "restart-required"].contains(removed["application"] as? String ?? "") else {
                reportRestoration(nil, name: name)
                return
            }
        }
        let restored = try? await host.rpc("pluginManager/installBundle", args: ["spec": spec, "options": ["enabled": enabled, "saveExact": true]])
        reportRestoration(restored, name: name)
    }

    private func reportRestoration(_ result: Object?, name: String) {
        if let result, result["error"] == nil, ["applied", "restart-required"].contains(result["application"] as? String ?? "") {
            failures[name] = (failures[name] ?? String(localized: "已取消安装")) + " " + String(localized: "旧版本已恢复。")
        } else { failures[name] = (failures[name] ?? String(localized: "已取消安装")) + " " + String(localized: "旧版本已卸载，可以重新安装。") }
    }
    #endif

    func cancel(_ name: String) async {
        guard let request = installs[name] else { return }
        _ = try? await host.rpc("pluginManager/cancelInstall", args: ["requestId": request])
    }

    func remove(_ bundle: HostPluginBundle) async {
        guard beginChange(bundle.name) else { return }
        defer { endChange(bundle.name) }
        #if os(macOS)
        let home = host.localEngineHome
        let directory = home.flatMap { LocalPluginFiles.installedImport(named: bundle.name, in: $0) }
        #endif
        do {
            let result = try await host.rpc("pluginManager/removeBundle", args: ["name": bundle.name])
            notice = outcome(result, done: String(localized: "已卸载「\(bundle.title)」"))
            #if os(macOS)
            if let home { LocalPluginFiles.removeIfUnused(directory, in: home) }
            #endif
        } catch { notice = String(localized: "没能卸载。请稍后重试。") }
        await refreshAfterChange()
    }
}

/// The letter avatar of a plugin.
private struct PluginAvatar: View {
    let title: String
    var size: CGFloat = 40
    var body: some View {
        Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Color.accentColor)
            .frame(width: size, height: size).background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// A plugin failure in words, with the raw code and diagnostic folded under 详情.
struct PluginFailureText: View {
    let message: String
    var detail: String? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).foregroundStyle(.red)
            if let detail, !detail.isEmpty {
                DisclosureGroup("详情", isExpanded: $expanded) {
                    Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(ChatColors.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).foregroundStyle(ChatColors.muted)
            }
        }
    }
}

private struct PluginBadge: View {
    let label: String
    var body: some View {
        Text(label).font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

/// 插件: 已安装 (third-party bundles, then 官方, toggle only) and 插件市场; 导入 in the toolbar
/// holds the three ways to bring a plugin in from outside the market.
struct HostPluginsScreen: View {
    let host: Harness
    private enum Tab: String { case installed = "已安装", market = "插件市场" }
    @StateObject private var store: HostPluginStore
    /// Set right before the page is shown to land on 插件市场 (设置 › 手机操控 › 去插件市场).
    static var startOnMarket = false
    @State private var tab: Tab
    @State private var query = ""
    @State private var category: String?
    @State private var opened: String?
    @State private var importingShare = false
    @State private var importingArchive = false
    @State private var importingFolder = false

    init(host: Harness, initialBundle: String? = nil) {
        self.host = host
        _store = StateObject(wrappedValue: HostPluginStore(host: host))
        _tab = State(initialValue: Self.startOnMarket ? .market : .installed)
        _opened = State(initialValue: initialBundle)
        Self.startOnMarket = false
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 14) {
                tabs
                Spacer(minLength: 8)
                importMenu
            }.padding(.horizontal, 16).padding(.vertical, 8)
            #endif
            rows
        }
        .background(ChatColors.canvas.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .screenLeading) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新")
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { importMenu }
            #endif
        }
        .sheet(isPresented: $importingShare) {
            PluginShareInputSheet(host: host, store: store) { name in importingShare = false; opened = name }
        }
        .sheet(isPresented: $importingArchive) {
            PluginArchiveImportSheet(host: host, store: store) { name in importingArchive = false; opened = name }
        }
        .modifier(LocalPluginImport(store: store, picking: $importingFolder))
        .refreshable { await reload() }
        .task { await store.refresh() }
        .task(id: tab) { if tab == .market, store.market == nil { await store.loadMarket() } }
        .navigationTitle("插件")
        .navigationDestination(item: $opened) { HostPluginBundleDetail(store: store, name: $0) }
    }

    private var rows: some View {
        List {
            #if os(iOS)
            Section { tabs }.listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            #endif
            if let notice = store.notice { Section { Text(notice).font(.callout) }.listRowBackground(ChatColors.chip) }
            switch tab {
            case .installed: installed
            case .market: marketRows
            }
        }.groupedList().scrollContentBackground(.hidden)
    }

    private var tabs: some View {
        Picker("插件", selection: $tab) {
            Text(Tab.installed.rawValue.localized).tag(Tab.installed)
            Text(Tab.market.rawValue.localized).tag(Tab.market)
        }.pickerStyle(.segmented).accessibilityIdentifier("pluginsTabs")
    }

    private var importMenu: some View {
        Menu {
            Button { importingShare = true } label: { Label("分享链接或分享码", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("pluginImportShare")
            Button { importingArchive = true } label: { Label("离线插件包", systemImage: "shippingbox") }
                .accessibilityIdentifier("pluginImportArchive")
            if host.usesEmbeddedEngine {
                Button { importingFolder = true } label: { Label("电脑上的插件文件夹", systemImage: "folder") }
                    .accessibilityIdentifier("pluginImportFolder")
            }
        } label: { Text("导入") }.accessibilityIdentifier("pluginImportMenu")
    }

    private func reload() async {
        store.notice = nil
        if tab == .installed { await store.refresh() } else { await store.loadMarket(); await store.refresh() }
    }

    @ViewBuilder private var installed: some View {
        if let bundles = store.bundles {
            let mine = bundles.filter { $0.group == .installed }
            let official = bundles.filter { $0.group == .official } + bundles.filter { $0.group == .onDemand }
            if mine.isEmpty {
                Section {
                    HostEmptyState(symbol: "puzzlepiece.extension", title: String(localized: "还没装第三方插件"),
                                   action: (String(localized: "逛逛插件市场"), { tab = .market }))
                }.listRowBackground(Color.clear)
            } else {
                Section("已安装") { ForEach(mine) { bundleRow($0) } }.listRowBackground(ChatColors.chip)
            }
            if !official.isEmpty {
                Section { ForEach(official) { bundleRow($0) } } header: { Text("官方") }.listRowBackground(ChatColors.chip)
            }
        } else if let error = store.listError {
            Section {
                HostEmptyState(symbol: "exclamationmark.triangle", title: String(localized: "没能读取插件列表"), message: error, action: (String(localized: "重试"), { Task { await store.refresh() } }))
            }.listRowBackground(Color.clear)
        } else {
            Section { ProgressView("正在读取插件…").frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
        }
    }

    private func bundleRow(_ bundle: HostPluginBundle) -> some View {
        let listed = store.market?.plugins.first { $0.name == bundle.name }
        let update = listed.map { store.status(of: $0) == "update" } ?? false
        let error = bundle.errorText
        let busy = store.working.contains(bundle.name)
        #if os(macOS)
        let line = error
        #else
        let line = busy ? String(localized: "安装中") : !error.isEmpty ? error : [bundle.version, bundle.summary].compactMap { $0 }.joined(separator: " · ")
        #endif
        return NavigationLink { HostPluginBundleDetail(store: store, name: bundle.name) } label: {
            HStack(spacing: 12) {
                PluginAvatar(title: bundle.title)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(verbatim: bundle.title).font(.body.weight(.medium)).foregroundStyle(ChatColors.ink).lineLimit(1)
                        if bundle.official { PluginBadge(label: String(localized: "官方")) }
                        if update { PluginBadge(label: String(localized: "有更新")) }
                    }
                    if !line.isEmpty { Text(verbatim: line).font(.caption).foregroundStyle(error.isEmpty ? ChatColors.muted : Color.red).lineLimit(2) }
                }
                Spacer(minLength: 6)
                #if os(macOS)
                if let version = bundle.version { Text(verbatim: version).foregroundStyle(.secondary) }
                #endif
                if busy { ProgressView() }
                else if bundle.isOnDemand {
                    Text("安装").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 12).padding(.vertical, 5).background(Color.accentColor.opacity(0.14), in: Capsule())
                } else if bundle.switchable {
                    Toggle(bundle.title, isOn: Binding(get: { bundle.enabled }, set: { on in Task { await store.setEnabled(bundle, on) } }))
                        .labelsHidden()
                }
            }
        }.accessibilityIdentifier("pluginBundle-" + bundle.name)
    }

    @ViewBuilder private var marketRows: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ChatColors.muted)
                TextField("搜索插件", text: $query).noAutomaticCapitalization().autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ChatColors.muted) }
                        .buttonStyle(.plain).accessibilityLabel("清除")
                }
            }
        }.listRowBackground(ChatColors.chip)
        if let market = store.market {
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let matching = market.plugins.filter { plugin in
                (category == nil || plugin.category == category) && (terms.isEmpty || terms.allSatisfy { plugin.haystack.contains($0) })
            }
            let shown = matching.filter { !$0.webOnly }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(String(localized: "全部"), selected: category == nil) { category = nil }
                        ForEach(market.categories.filter { item in market.plugins.contains { $0.category == item.id && !$0.webOnly } }, id: \.id) { item in
                            chip(item.title, selected: category == item.id) { category = category == item.id ? nil : item.id }
                        }
                    }.padding(.vertical, 2)
                }
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            if shown.isEmpty {
                Section {
                    HostEmptyState(symbol: "magnifyingglass", title: trimmed.isEmpty ? String(localized: "这个分类下没有插件") : String(localized: "没有找到「\(trimmed)」"))
                }.listRowBackground(Color.clear)
            } else {
                Section("全部") {
                    ForEach(Array(shown.prefix(300))) { plugin in marketRow(plugin) }
                }.listRowBackground(ChatColors.chip)
            }
        } else if let error = store.marketError {
            Section {
                HostEmptyState(symbol: "exclamationmark.triangle", title: String(localized: "没能打开插件市场"), message: error, action: (String(localized: "重试"), { Task { await store.loadMarket() } }))
            }.listRowBackground(Color.clear)
        } else {
            Section { ProgressView("正在打开插件市场…").frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : ChatColors.ink)
                .background(selected ? Color.accentColor : ChatColors.chip, in: Capsule())
                .overlay(Capsule().strokeBorder(ChatColors.line, lineWidth: selected ? 0 : 0.6))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func marketRow(_ plugin: HostMarketPlugin) -> some View {
        let status = store.status(of: plugin)
        let failed = store.failures[plugin.name]
        #if os(macOS)
        let line = failed ?? ""
        #else
        let line = failed.map { $0 + String(localized: " · 点开查看") } ?? [plugin.author, plugin.summary].compactMap { $0 }.joined(separator: " · ")
        #endif
        let label = store.working.contains(plugin.name) ? String(localized: "安装中") : status == "installed" ? String(localized: "已安装") : status == "update" ? String(localized: "更新") : String(localized: "安装")
        let tint: Color = status == "installed" ? ChatColors.muted : .accentColor
        return NavigationLink { HostMarketPluginDetail(store: store, plugin: plugin) } label: {
            HStack(spacing: 12) {
                PluginAvatar(title: plugin.title)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(verbatim: plugin.title).font(.body.weight(.medium)).foregroundStyle(ChatColors.ink).lineLimit(1)
                        if plugin.featured { PluginBadge(label: String(localized: "推荐")) }
                    }
                    if !line.isEmpty { Text(verbatim: line).font(.caption).foregroundStyle(failed == nil ? ChatColors.muted : Color.red).lineLimit(2) }
                }
                Spacer(minLength: 6)
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    .padding(.horizontal, 12).padding(.vertical, 5).background(tint.opacity(0.13), in: Capsule())
            }
        }
    }
}

/// 插件详情 of an installed (or on-demand) bundle.
struct HostPluginBundleDetail: View {
    @ObservedObject var store: HostPluginStore
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false

    var body: some View {
        List {
            if let bundle = store.bundle(named: name) {
                let listed = store.market?.plugins.first { $0.name == name }
                let update = listed.flatMap { store.status(of: $0) == "update" ? $0 : nil }
                let busy = store.working.contains(name)
                Section {
                    HStack(spacing: 14) {
                        PluginAvatar(title: bundle.title, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: bundle.title).font(.title3.weight(.semibold)).lineLimit(2)
                            HStack(spacing: 4) {
                                if bundle.official { PluginBadge(label: String(localized: "官方")) }
                                if update != nil { PluginBadge(label: String(localized: "有更新")) }
                            }
                        }
                    }
                    if let summary = bundle.summary { Text(verbatim: summary).font(.callout).textSelection(.enabled) }
                    if !bundle.errorText.isEmpty {
                        PluginFailureText(message: bundle.errorText, detail: bundle.errorDetail)
                    }
                }.listRowBackground(Color.clear)
                if bundle.switchable {
                    Section {
                        Toggle("启用", isOn: Binding(get: { bundle.enabled }, set: { on in Task { await store.setEnabled(bundle, on) } }))
                            .disabled(busy)
                    }.listRowBackground(ChatColors.chip)
                }
                if bundle.enabled { Section { PluginSettingsLinks(host: store.host, bundle: bundle) }.listRowBackground(ChatColors.chip) }
                Section {
                    if let version = bundle.version { LabeledContent("版本", value: version) }
                    if let update {
                        NavigationLink { HostMarketPluginDetail(store: store, plugin: update) } label: { LabeledContent("有更新", value: update.version) }
                    }
                }.listRowBackground(ChatColors.chip)
                if let home = store.host.localEngineHome, bundle.installed, bundle.availability == "profile" {
                    Section { LocalPluginShare(name: name, home: home) }.listRowBackground(ChatColors.chip)
                }
                if bundle.isOnDemand, let spec = bundle.installSpec {
                    Section {
                        Button(busy ? "安装中…" : "安装") {
                            Task { await store.install(name: name, title: bundle.title, spec: spec, registry: nil) }
                        }.disabled(busy).frame(maxWidth: .infinity)
                    }.listRowBackground(ChatColors.chip)
                } else if bundle.removable {
                    Section {
                        Button("卸载", role: .destructive) { removing = true }.disabled(busy).frame(maxWidth: .infinity)
                    }.listRowBackground(ChatColors.chip)
                }
                if let failure = store.failures[name] { Section { PluginFailureText(message: failure, detail: store.details[name]) } }
                Section {
                    DisclosureGroup("更多信息") {
                        LabeledContent("包名") { Text(verbatim: bundle.name).font(.caption.monospaced()).textSelection(.enabled) }
                        if let source = bundle.source { LabeledContent("来源") { Text(verbatim: source).font(.caption).textSelection(.enabled) } }
                        if !bundle.components.isEmpty {
                            LabeledContent("组件") { Text(verbatim: bundle.components.joined(separator: String(localized: "、"))).font(.caption) }
                        }
                    }
                }.listRowBackground(ChatColors.chip)
            } else {
                Section { HostEmptyState(symbol: "puzzlepiece.extension", title: String(localized: "插件已不在这台设备上")) }.listRowBackground(Color.clear)
            }
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("插件详情").inlineNavigationTitle()
        .confirmationDialog("卸载「\(store.bundle(named: name)?.title ?? name)」？", isPresented: $removing, titleVisibility: .visible) {
            Button("卸载", role: .destructive) {
                guard let bundle = store.bundle(named: name) else { return }
                Task {
                    await store.remove(bundle)
                    if store.bundle(named: name) == nil { dismiss() }
                }
            }
        } message: { Text("插件会从这台设备上移除，它保存的数据和设置不会删除。") }
    }
}

/// 插件详情 of a market entry: what it is, where it comes from, 安装 / 更新到 x.
struct HostMarketPluginDetail: View {
    @ObservedObject var store: HostPluginStore
    let plugin: HostMarketPlugin
    /// nil while checking; "" when it may be installed.
    @State private var refusal: String?
    @State private var confirmingReplace = false

    var body: some View {
        let status = store.status(of: plugin)
        let installed = store.bundle(named: plugin.name)
        let busy = store.working.contains(plugin.name)
        List {
            Section {
                HStack(spacing: 14) {
                    PluginAvatar(title: plugin.title, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: plugin.title).font(.title3.weight(.semibold)).lineLimit(2)
                        if let author = plugin.author { Text(verbatim: author).font(.caption).foregroundStyle(ChatColors.muted) }
                        HStack(spacing: 4) {
                            if plugin.featured { PluginBadge(label: String(localized: "推荐")) }
                            if status == "update" { PluginBadge(label: String(localized: "有更新")) }
                        }
                    }
                }
                if let summary = plugin.summary { Text(verbatim: summary).font(.callout).textSelection(.enabled) }
            }.listRowBackground(Color.clear)
            Section {
                LabeledContent("版本", value: plugin.version)
                if let version = installed?.version { LabeledContent("已装版本", value: version) }
                if let homepage = plugin.homepage, let url = URL(string: homepage), url.scheme == "https" { Link("主页", destination: url) }
            }.listRowBackground(ChatColors.chip)
            if let failure = store.failures[plugin.name] { Section { PluginFailureText(message: failure, detail: store.details[plugin.name]) } }
            else if let refusal, !refusal.isEmpty, status != "installed" { Section { Text(refusal).foregroundStyle(.red) } }
            Section {
                if busy {
                    HStack {
                        ProgressView(); Text("安装中…"); Spacer()
                        Button("取消") { Task { await store.cancel(plugin.name) } }
                    }
                } else if status == "installed" {
                    Text("已安装").foregroundStyle(ChatColors.muted).frame(maxWidth: .infinity)
                } else if refusal == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else if refusal?.isEmpty == false {
                    Text("不能安装").foregroundStyle(ChatColors.muted).frame(maxWidth: .infinity)
                } else {
                    Button(status == "update" ? "更新到 \(plugin.version)" : store.failures[plugin.name] != nil ? "重试安装" : "安装") {
                        if store.needsReplacing(plugin.name, spec: plugin.spec) { confirmingReplace = true }
                        else { Task { await store.install(name: plugin.name, title: plugin.title, spec: plugin.spec, registry: plugin.registry) } }
                    }.frame(maxWidth: .infinity)
                }
            }.listRowBackground(ChatColors.chip)
            Section {
                DisclosureGroup("更多信息") {
                    LabeledContent("包名") { Text(verbatim: plugin.name).font(.caption.monospaced()).textSelection(.enabled) }
                    LabeledContent("来源", value: plugin.spec.hasPrefix("git+") ? "Git" : "npm")
                    if let repository = plugin.repository, let url = URL(string: repository), url.scheme == "https" { Link("代码仓库", destination: url) }
                }
            }.listRowBackground(ChatColors.chip)
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("插件详情").inlineNavigationTitle()
        .confirmationDialog("更新「\(plugin.title)」？", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("卸载旧版本并安装") {
                Task { await store.install(name: plugin.name, title: plugin.title, spec: plugin.spec, registry: plugin.registry, replacing: true) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("会先卸载旧版本，再安装新版本。插件保存的数据和设置会保留。") }
        .task { refusal = await PluginPolicy.refusal(spec: plugin.spec, registry: plugin.registry) ?? "" }
    }
}
