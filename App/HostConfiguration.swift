import SwiftUI
import CoreFoundation
import UniformTypeIdentifiers

// MARK: - Shared states

/// 「未连接」 and the like: a feature page with nothing to show yet.
/// A settings page whose feature needs a connected host.
struct OfflineFeaturePage: View {
    let title: String

    var body: some View {
        ScrollView { OfflineMessage().padding(16) }
            .settingsPage(title)
    }
}

// MARK: - 运行参数

/// The host's `settings/describe`, as the 引擎参数 pages read it.
private struct DescribedSettings {
    var sections: [Object] = []
    var writable = false

    func section(_ ns: String) -> Object? { sections.first { $0["ns"] as? String == ns } }
    func value(_ ns: String, _ key: String) -> Any? { (section(ns)?["value"] as? Object)?[key] }

    static func read(_ host: Harness) async throws -> Self {
        let data = try await host.rpc("settings/describe", args: [:])
        return Self(sections: data["namespaces"] as? [Object] ?? [], writable: data["writable"] as? Bool == true)
    }
}

/// `120000` ms → `2 分钟`.
private func formatMilliseconds(_ value: Double) -> String {
    func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
    if value < 1000 { return trim(value) + String(localized: " 毫秒") }
    let seconds = value / 1000
    if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return trim(seconds / 3600) + String(localized: " 小时") }
    if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return trim(seconds / 60) + String(localized: " 分钟") }
    return trim(seconds) + String(localized: " 秒")
}

/// 运行参数 (设置 › 高级): the host's run parameters (子任务, 并行步骤, 命令执行), its plugin
/// inventory, and every other settings section in the generic editor.
struct HostSettings: View {
    let host: Harness
    var hostLabel: String? = nil
    @State private var settings: DescribedSettings?
    @State private var issue: String?

    /// Sections with a page of their own elsewhere in 设置.
    private static let elsewhere: Set<String> = ["subagent", "agent-loop", "bash-sandbox", "pwsh-sandbox", "web", "web-search-deepseek",
                                                 "web-deepseek-api", "permission", "agent-default-model", "agent-preset-registry"]

    private struct RunRow: Identifiable {
        let ns: String, symbol: String, title: String, value: String?
        var id: String { ns }
    }

    private func runRows(_ settings: DescribedSettings) -> [RunRow] {
        let shell = settings.section("pwsh-sandbox") != nil && settings.section("bash-sandbox") == nil ? "pwsh-sandbox" : "bash-sandbox"
        let depth = settings.value("subagent", "maxDepth") as? Double
        let parallel = settings.value("agent-loop", "maxParallelToolCalls") as? Double
        let timeout = settings.value(shell, "timeoutMs") as? Double
        return [
            RunRow(ns: "subagent", symbol: "person.2", title: String(localized: "子任务"),
                   value: depth.map { $0 == $0.rounded() ? String(localized: "\(Int($0)) 层") : String(localized: "\($0) 层") }),
            RunRow(ns: "agent-loop", symbol: "arrow.triangle.2.circlepath", title: String(localized: "并行步骤"), value: parallel.map { String(localized: "\(Int($0)) 个") }),
            RunRow(ns: shell, symbol: "timer", title: String(localized: "命令执行"), value: timeout.map(formatMilliseconds)),
        ].filter { settings.section($0.ns) != nil }
    }

    var body: some View {
        List {
            if let hostLabel {
                Section { Text(hostLabel).font(.subheadline).foregroundStyle(ChatColors.muted) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            if let settings {
                let rows = runRows(settings)
                if !rows.isEmpty {
                    Section("运行") {
                        ForEach(rows) { row in
                            if let section = settings.section(row.ns) {
                                NavigationLink { NamespaceEditor(host: host, section: section, writable: settings.writable, title: row.title) } label: {
                                    SettingsRowLabel(symbol: row.symbol, title: row.title, value: row.value, chevron: false, tinted: false)
                                }
                            }
                        }
                    }.listRowBackground(ChatColors.chip)
                }
                Section("插件") {
                    NavigationLink { PluginInventoryPage(host: host) } label: {
                        SettingsRowLabel(symbol: "list.bullet.indent", title: String(localized: "插件清单"), chevron: false, tinted: false)
                    }
                    ForEach(settings.sections.indices, id: \.self) { index in
                        let section = settings.sections[index]
                        if let ns = section["ns"] as? String, !Self.elsewhere.contains(ns) {
                            NavigationLink { NamespaceEditor(host: host, section: section, writable: settings.writable) } label: {
                                SettingsRowLabel(symbol: "puzzlepiece.extension", title: ns, chevron: false, tinted: false)
                            }
                        }
                    }
                }.listRowBackground(ChatColors.chip)
            } else if let issue {
                OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取设置"), detail: issue) { Task { await load() } }
                    .listRowBackground(Color.clear)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .settingsPage(String(localized: "运行参数"))
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { settings = try await DescribedSettings.read(host); issue = nil }
        catch { if !Task.isCancelled { issue = HostError.explain(error) } }
    }
}

/// One settings value: JSON for plain values, a protected field for credentials.
private struct SettingsValueEditor: View {
    let host: Harness
    let ns: String
    let revision: Int?
    let path: [String]
    let secret: Bool
    let writable: Bool
    var title: String? = nil
    let initial: Any?
    let saved: (Object) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var busy = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                if secret { SecureField("新凭据", text: $draft) }
                else { TextEditor(text: $draft).font(.body.monospaced()).frame(minHeight: 120) }
                if let issue { Text(issue).foregroundStyle(.red) }
                if writable {
                    Button("保存") { save(unset: false) }
                    Button("恢复默认值", role: .destructive) { save(unset: true) }
                }
            }.autocorrectionDisabled().noAutomaticCapitalization().disabled(busy)
            .navigationTitle(title ?? path.joined(separator: "."))
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.desktopSheet(width: 500, height: 330)
        .onAppear {
            if !secret, let initial, let bytes = try? JSONSerialization.data(withJSONObject: initial, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]) {
                draft = String(decoding: bytes, as: UTF8.self)
            }
        }
        .onDisappear { draft = "" }
    }

    private func save(unset: Bool) {
        guard let revision else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var op: Object = ["op": unset ? "unset" : "set", "path": path]
                if !unset {
                    if secret { op["value"] = draft }
                    else { op["value"] = try JSONSerialization.jsonObject(with: Data(draft.utf8), options: [.fragmentsAllowed]) }
                }
                let section = try await host.rpc("settings/mutate", args: ["ns": ns, "ops": [op], "expectedRevision": revision])
                issue = nil
                saved(section)
                dismiss()
            } catch { issue = (error as? HostError)?.message ?? String(localized: "无法保存，请检查输入格式或重新打开设置。") }
        }
    }
}

private struct ValueEdit: Identifiable {
    let path: [String]
    let secret: Bool
    let title: String?
    var id: String { path.joined(separator: ".") }
}

private struct NamespaceEditor: View {
    let host: Harness
    @State var section: Object
    let writable: Bool
    var title: String? = nil
    @State private var editing: ValueEdit?
    private var ns: String { section["ns"] as? String ?? "" }
    private var values: Object { section["value"] as? Object ?? [:] }
    private var secrets: [[String]] { (section["secrets"] as? [Object] ?? []).compactMap { $0["path"] as? [String] } }

    var body: some View {
        Form {
            ForEach(values.keys.sorted(), id: \.self) { key in
                // Nested credential slots have individual protected editors.
                if !secrets.contains(where: { $0.first == key }) {
                    Button(key) { editing = ValueEdit(path: [key], secret: false, title: nil) }
                }
            }
            ForEach(secrets, id: \.self) { key in
                Button { editing = ValueEdit(path: key, secret: true, title: nil) } label: { Label(key.joined(separator: "."), systemImage: "key") }
            }
        }.navigationTitle(title ?? ns)
        .sheet(item: $editing) { edit in
            SettingsValueEditor(host: host, ns: ns, revision: section["revision"] as? Int, path: edit.path, secret: edit.secret,
                                writable: writable, title: edit.title, initial: edit.secret ? nil : values[edit.path[0]]) { section = $0 }
        }
    }
}

/// 插件清单: every loaded plugin entry and whether it is on.
struct PluginInventoryPage: View {
    let host: Harness
    private struct Entry: Identifiable { let id: String, name: String, enabled: Bool }
    @State private var entries: [Entry]?
    @State private var issue: String?

    var body: some View {
        List {
            if let entries {
                Section {
                    ForEach(entries) { entry in
                        SettingsRowLabel(title: entry.name, value: entry.enabled ? String(localized: "已启用") : String(localized: "已停用"), chevron: false)
                            .accessibilityElement(children: .combine)
                    }
                }.listRowBackground(ChatColors.chip)
            } else if let issue {
                OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取插件清单"), detail: issue) { Task { await load() } }
                    .listRowBackground(Color.clear)
            } else { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
        }.settingsPage(String(localized: "插件清单")).task { await load() }
    }

    private func load() async {
        do {
            let data = try await host.rpc("pluginInventory/list", args: [:])
            entries = (data["entries"] as? [Object] ?? []).compactMap { item in
                guard let name = item["moduleName"] as? String, let id = item["entryId"] as? String else { return nil }
                return Entry(id: id, name: name, enabled: item["enabled"] as? Bool == true)
            }
            issue = nil
        } catch { if !Task.isCancelled { issue = HostError.explain(error) } }
    }
}

/// 导入 › 电脑上的插件文件夹: stages a folder the person picked for the in-process Harness, then
/// lets its plugin manager validate, register and activate the bundle. Attach it to the page
/// that owns the 导入 menu; `picking` opens the folder picker and `report` gets the outcome.
struct LocalPluginImport: ViewModifier {
    @ObservedObject var store: HostPluginStore
    @Binding var picking: Bool
    @State private var selected: URL?
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                do { selected = try result.get(); confirming = true }
                catch { if (error as NSError).code != NSUserCancelledError { store.notice = String(localized: "没能读取这个文件夹。") } }
            }
            .confirmationDialog("导入并启用这个插件？", isPresented: $confirming, titleVisibility: .visible) {
                Button("导入并启用") { if let selected { install(selected) } }
                Button("取消", role: .cancel) { selected = nil }
            } message: {
                Text(String(localized: "文件夹：") + (selected?.lastPathComponent ?? "") + String(localized: "。插件会在本机运行，并拥有 Pallas Agent 的权限。"))
            }
    }

    nonisolated static func stage(_ directory: URL) throws -> URL {
        let fm = FileManager.default
        let inbox = fm.temporaryDirectory.appendingPathComponent("DSHPluginImport", isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let dest = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &coordinationError) { source in
            do { try fm.copyItem(at: source, to: dest) } catch { copyError = error }
        }
        if let error = copyError ?? coordinationError {
            try? fm.removeItem(at: dest)
            throw error
        }
        return dest
    }

    private func install(_ directory: URL) {
        Task {
            defer { selected = nil }
            do {
                let staged = try await Task.detached { try Self.stage(directory) }.value
                defer { try? FileManager.default.removeItem(at: staged) }
                let package = try PluginArchiveImportSheet.describe(staged, file: directory.lastPathComponent)
                await store.install(name: package.name, title: package.title ?? package.name, spec: staged.path, registry: nil)
                if let failure = store.failures[package.name] { store.notice = failure }
            } catch { store.notice = String(localized: "没能导入这个文件夹。请确认它是插件文件夹后重试。") }
        }
    }
}

/// Path and manifest reads shared by package export and local desktop imports.
enum LocalPluginFiles {
    static func profile(in home: URL) -> URL { home.appending(path: "profiles/web", directoryHint: .isDirectory) }

    static func dependencies(at profile: URL) throws -> [String: String] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: profile.appending(path: "package.json")))
        guard let record = value as? Object else { throw CocoaError(.fileReadCorruptFile) }
        guard let raw = record["dependencies"] else { return [:] }
        guard let dependencies = raw as? [String: String] else { throw CocoaError(.fileReadCorruptFile) }
        return dependencies
    }

    #if os(macOS)
    private static func imports(in home: URL) -> URL { home.appending(path: "plugin-imports", directoryHint: .isDirectory) }

    /// pnpm's file dependency can be read again on later installs, so it points at the app-owned snapshot.
    nonisolated static func retain(_ folder: URL, in home: URL) throws -> URL {
        let fm = FileManager.default
        let directory = imports(in: home)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do { try fm.copyItem(at: folder, to: destination) }
        catch { try? fm.removeItem(at: destination); throw error }
        return destination
    }

    static func installedImport(named name: String, in home: URL) -> URL? {
        let profile = profile(in: home)
        guard let spec = (try? dependencies(at: profile))?[name] else { return nil }
        return importURL(spec, profile: profile, home: home)
    }

    static func restoreSpec(for bundle: HostPluginBundle, in home: URL) throws -> String {
        let profile = profile(in: home)
        guard let recorded = try dependencies(at: profile)[bundle.name], !recorded.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for prefix in ["file:", "link:"] where recorded.hasPrefix(prefix) {
            let url = URL(filePath: String(recorded.dropFirst(prefix.count)), relativeTo: profile).standardizedFileURL
            return prefix + url.path
        }
        if recorded.contains(":") { return recorded }
        return bundle.name + "@" + (bundle.version ?? recorded)
    }

    static func removeIfUnused(_ directory: URL?, in home: URL) {
        guard let directory else { return }
        let profile = profile(in: home)
        guard let dependencies = try? dependencies(at: profile),
              !dependencies.values.contains(where: { importURL($0, profile: profile, home: home) == directory.standardizedFileURL }) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func importURL(_ spec: String, profile: URL, home: URL) -> URL? {
        guard spec.hasPrefix("file:") else { return nil }
        let path = String(spec.dropFirst(5))
        let url = URL(filePath: path, directoryHint: .isDirectory, relativeTo: profile).standardizedFileURL
        guard url.deletingLastPathComponent().path == imports(in: home).path,
              UUID(uuidString: url.lastPathComponent) != nil else { return nil }
        return url
    }
    #endif
}

/// Exports the installed plugin package directory; profile settings and credentials
/// live outside that directory. The archive is built before presenting the share sheet.
struct LocalPluginShare: View {
    let name: String
    let home: URL
    @State private var preparing = false
    @State private var archive: URL?
    @State private var sharing = false
    @State private var failure: String?

    var body: some View {
        Button {
            preparing = true
            failure = nil
            Task {
                defer { preparing = false }
                do {
                    archive = try await Task.detached(priority: .userInitiated) { try Self.export(name, home: home) }.value
                    sharing = true
                } catch { failure = error.localizedDescription }
            }
        } label: {
            Label(preparing ? "正在打包…" : "分享插件包", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .disabled(preparing)
        .sheet(isPresented: $sharing, onDismiss: {
            if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            archive = nil
        }) {
            if let archive {
                #if os(macOS)
                VStack(spacing: 14) {
                    Text(archive.lastPathComponent).font(.headline)
                    ShareLink(item: archive)
                    Button("保存") {
                        Task {
                            do { if try await MacFileExport.save(archive) != nil { sharing = false } }
                            catch { failure = error.localizedDescription; sharing = false }
                        }
                    }
                    Button("完成") { sharing = false }
                }.padding(24)
                #else
                ExportShareSheet(items: [archive])
                #endif
            }
        }
        if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
    }

    nonisolated static func export(_ name: String, home: URL = .applicationSupportDirectory.appending(path: "DSH", directoryHint: .isDirectory)) throws -> URL {
        let fm = FileManager.default
        guard name.utf8.count <= 214,
              name.range(of: #"\A(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*\z"#,
                         options: .regularExpression) != nil else { throw HostError(String(localized: "这个插件不能分享。")) }
        let profile = LocalPluginFiles.profile(in: home)
        let dependency = try LocalPluginFiles.dependencies(at: profile)[name]
        #if os(macOS)
        guard dependency != nil else { throw HostError(String(localized: "这个插件不能分享。")) }
        #else
        guard dependency == "file:node_modules/" + name else {
            throw HostError(String(localized: "这个插件不能分享。"))
        }
        #endif
        let modules = profile.resolvingSymlinksInPath().appending(path: "node_modules", directoryHint: .isDirectory)
        let package = modules.appending(path: name).resolvingSymlinksInPath().standardizedFileURL
        let direct = modules.appending(path: name).path
        #if os(macOS)
        let installed = package.path.hasPrefix(modules.path + "/.pnpm/") && package.path.hasSuffix("/node_modules/" + name)
        #else
        let installed = false
        #endif
        guard package.path == direct || installed else {
            throw HostError(String(localized: "插件目录已变更，请刷新后重试。"))
        }
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let slug = name.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "/", with: "-")
        let snapshot = temp.appendingPathComponent(slug, isDirectory: true)
        do {
            try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: snapshot) }
            try copyPackage(package, into: snapshot)
            let info = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.appendingPathComponent("package.json"))) as? Object
            guard info?["name"] as? String == name, let dsh = info?["dsh"] as? Object,
                  let bundle = dsh["bundle"] as? Object else { throw HostError(String(localized: "这个插件的文件不完整，不能分享。")) }
            let patches = (bundle["patch"] as? String).map { [$0] } ?? bundle["patch"] as? [String] ?? []
            for patch in patches {
                let file = snapshot.appendingPathComponent(patch).standardizedFileURL
                guard file.path.hasPrefix(snapshot.standardizedFileURL.path + "/"),
                      try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw HostError(String(localized: "这个插件的文件不完整，不能分享。"))
                }
            }
            guard !patches.isEmpty else { throw HostError(String(localized: "这个插件的文件不完整，不能分享。")) }
            let archive = temp.appendingPathComponent(slug + ".zip")
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: snapshot, options: .forUploading, error: &coordinationError) { zipped in
                do { try fm.copyItem(at: zipped, to: archive) } catch { copyError = error }
            }
            if let error = copyError ?? coordinationError { throw error }
            return archive
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private nonisolated static func copyPackage(_ source: URL, into destination: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys)) {
            let leaf = file.lastPathComponent
            if [".git", ".DS_Store", ".npmrc", ".env"].contains(leaf) || leaf.hasPrefix(".env.") { continue }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw HostError(String(localized: "插件内含符号链接，无法安全导出。")) }
            let target = destination.appendingPathComponent(leaf)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                try copyPackage(file, into: target)
            } else if values.isRegularFile == true {
                try fm.copyItem(at: file, to: target)
            } else { throw HostError(String(localized: "插件包含无法导出的特殊文件。")) }
        }
    }
}

#if os(iOS)
// MARK: - 模型

/// A provider's first letter in a disc.
private struct Monogram: View {
    let name: String
    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.subheadline.weight(.semibold)).foregroundStyle(ChatColors.ink)
            .frame(width: 32, height: 32).background(ChatColors.muted.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

/// 模型: 新对话默认, DeepSeek (opening the account page), the host's own
/// 模型服务 (`llm-pi-ai` routes) and, on this phone, 决策 AI for phone control.
struct HostModelsPage: View {
    @ObservedObject var remote: Conversation
    let host: Harness?
    let hostLabel: String
    @ObservedObject private var account = DeepSeekAccount.shared
    @ObservedObject private var chatGPT = ChatGPTAccount.shared

    @State private var defaults: HostModelDefaultSettings?
    @State private var defaultsLoaded = false
    private var catalog: [ModelOption] { remote.modelCatalog?.channels.flatMap(\.models) ?? [] }
    private var catalogLoaded: Bool { remote.modelCatalog != nil }
    @State private var channels: [HostModelService]?
    @State private var unsupported = false
    @State private var channelIssue: String?
    @State private var catalogIssue: String?
    @State private var saving = false
    @State private var saveIssue: String?
    @State private var editingDefaults = false
    @State private var revision = 0

    private var deepSeekReady: Bool { catalog.contains { $0.channel.hasPrefix("deepseek") } }

    private var summary: String? {
        guard host != nil, let channels else { return nil }
        let official = showsChatGPT ? 2 : 1
        let ready = (deepSeekReady ? 1 : 0) + (showsChatGPT && chatGPT.signedIn ? 1 : 0)
            + channels.filter { $0.health == .ready }.count
        return hostLabel + String(localized: " · \(official + channels.count) 个模型服务 · \(ready) 个可用")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let summary {
                    Text(summary).font(.subheadline).foregroundStyle(ChatColors.muted).padding(.horizontal, 4).padding(.bottom, 20)
                }
                defaultsCard
                SettingsCard(title: String(localized: "官方")) {
                    if showsChatGPT { chatGPTRow; SettingsDivider() }
                    deepSeekRow
                }
                if host == nil {
                    OfflineMessage(symbol: "wifi.slash", title: String(localized: "未连接"))
                } else if unsupported {
                    OfflineMessage(symbol: "nosign", title: String(localized: "这台设备不支持添加模型服务"), detail: String(localized: "更新电脑上的服务后再试"))
                } else if let channelIssue, channels == nil {
                    OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取模型服务"), detail: channelIssue) { revision += 1 }
                } else if let channels, let host {
                    SettingsCard(title: String(localized: "自定义")) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            if index > 0 { SettingsDivider() }
                            NavigationLink { HostChannelForm(host: host, route: channel.id, conversation: remote) { revision += 1 } } label: { channelRow(channel).contentShape(Rectangle()) }
                                .buttonStyle(.plain).accessibilityIdentifier("channel-" + channel.id)
                        }
                        if !channels.isEmpty { SettingsDivider() }
                        NavigationLink { HostChannelForm(host: host, route: nil, conversation: remote) { revision += 1 } } label: {
                            Label("添加模型服务", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(.horizontal, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("channelAdd")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }.padding(16)
        }
        .foregroundStyle(ChatColors.ink)
        .background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("模型").navigationBarTitleDisplayMode(.large)
        .task(id: "\(revision)/\(chatGPT.revision)") { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editingDefaults, onDismiss: { revision += 1 }) {
            if let host { HostPanelView(panel: .models, chat: remote, host: host, editingDefaults: true).id(ObjectIdentifier(host)) }
        }
    }

    // MARK: 新对话默认

    private var defaultDescription: String {
        guard let value = defaults?.value, !value.model.isEmpty else { return String(localized: "选择模型") }
        let name = catalog.first { $0.channel == value.provider && $0.model == value.model }?.name ?? value.provider + " / " + value.model
        return [name, value.effort.map(ModelBudget.effortLabel)].compactMap { $0 }.joined(separator: " · ")
    }

    private var defaultReason: String? {
        if host == nil { return String(localized: "未连接") }
        if !defaultsLoaded { return String(localized: "加载中") }
        guard let defaults else { return String(localized: "这台设备不能改默认模型") }
        if !defaults.writable { return String(localized: "这台设备的设置是只读的") }
        if !catalogLoaded { return catalogIssue == nil ? String(localized: "加载中") : String(localized: "模型列表加载失败") }
        return nil
    }

    private var canEditDefaults: Bool { host != nil && defaults?.writable == true && catalogLoaded && !saving }

    private var defaultsCard: some View {
        let remember = defaults?.value.remember
        return SettingsCard(title: remember ?? true ? String(localized: "新对话默认（上次选择）") : String(localized: "新对话默认（固定）"), footer: saveIssue ?? catalogIssue) {
            if let flag = remember {
                SettingsSegmented(options: [(true, String(localized: "沿用上次")), (false, String(localized: "固定默认"))],
                             selection: Binding(get: { flag }, set: { saveMode($0) }), expand: true, enabled: { _ in canEditDefaults })
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            }
            Button { editingDefaults = true } label: {
                SettingsRowLabel(symbol: "cpu", title: defaultDescription,
                                 subtitle: saving ? String(localized: "正在保存并确认默认值…") : defaultReason, chevron: canEditDefaults, tinted: false)
                    .padding(.horizontal, 16).padding(.vertical, 4)
            }.buttonStyle(.plain).disabled(!canEditDefaults).accessibilityIdentifier("modelsNewChatDefault")
        }
    }

    private func saveMode(_ remember: Bool) {
        guard let host, let current = defaults, current.writable, current.value.remember != remember else { return }
        var desired = current.value
        desired.remember = remember
        saving = true; saveIssue = nil
        Task {
            defer { saving = false }
            do { defaults = try await current.save(desired, on: host) }
            catch { saveIssue = (error as? HostError)?.message ?? String(localized: "没能确认默认模型已保存。刷新后再看看。") }
        }
    }

    // MARK: 模型服务

    /// 用 ChatGPT 登录 feeds this phone's engine only.
    private var showsChatGPT: Bool { host.map { EmbeddedEngine.shared.owns($0) } ?? true }

    private var chatGPTRow: some View {
        NavigationLink { ChatGPTAccountPage() } label: {
            HStack(spacing: 12) {
                Monogram(name: "ChatGPT")
                Text(verbatim: "ChatGPT").foregroundStyle(ChatColors.ink)
                Spacer()
                Text(chatGPT.signedIn ? String(localized: "可用") : String(localized: "去登录")).font(.subheadline)
                    .foregroundStyle(chatGPT.signedIn ? ChatColors.muted : Color.accentColor)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted.opacity(0.6))
            }.frame(minHeight: 54).padding(.horizontal, 16).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("modelsChatGPT")
    }


    /// DeepSeek always opens the account page: signing in there is what makes it usable.
    private var deepSeekRow: some View {
        let ready = host != nil ? deepSeekReady || account.signedIn : account.signedIn
        return NavigationLink { DeepSeekAccountPage() } label: {
            HStack(spacing: 12) {
                Monogram(name: "DeepSeek")
                Text("DeepSeek").foregroundStyle(ChatColors.ink)
                Spacer()
                Text(ready ? String(localized: "可用") : String(localized: "去登录")).font(.subheadline).foregroundStyle(ready ? ChatColors.muted : Color.accentColor)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted.opacity(0.6))
            }.frame(minHeight: 54).padding(.horizontal, 16).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("modelsDeepSeek")
    }

    private func channelRow(_ channel: HostModelService) -> some View {
        let detail = channel.health != .ready ? channel.health.label
            : [Self.protocolLabel(channel.api), channel.models > 0 ? String(localized: "\(channel.models) 个模型") : nil].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 12) {
            Monogram(name: channel.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: channel.name)
                Text(detail).font(.caption)
                    .foregroundStyle(channel.health == .missingKey ? SettingsStyle.warning : channel.health == .misconfigured ? .red : ChatColors.muted)
            }
            Spacer()
            Circle().fill(channel.health.color).frame(width: 8, height: 8)
        }.frame(minHeight: 54).padding(.horizontal, 16)
            .accessibilityElement(children: .combine).accessibilityLabel(channel.name + String(localized: "，") + channel.health.label)
    }

    private static func protocolLabel(_ api: String?) -> String? {
        switch api {
        case "openai-completions": String(localized: "OpenAI 兼容")
        case "anthropic-messages": String(localized: "Anthropic 兼容")
        case "openai-responses": "Responses"
        default: nil
        }
    }

    private func load() async {
        guard let host else { return }
        async let catalogRefresh: Void = remote.reloadAvailableModels(on: host)
        defaults = try? await HostModelDefaultSettings.read(host)
        defaultsLoaded = true
        do { try await catalogRefresh; catalogIssue = nil }
        catch { if !Task.isCancelled { catalogIssue = error.localizedDescription } }
        guard !Task.isCancelled else { return }
        do {
            let services = try await HostModelService.list(on: host)
            unsupported = services == nil
            channels = services ?? []
            channelIssue = nil
        } catch {
            if !Task.isCancelled { channelIssue = HostError.explain(error) }
        }
    }
}
#endif

// MARK: - 联网搜索（主机）

/// 联网搜索: app-owned engines default to the conversation's model service.
/// Hosts using the DeepSeek providers keep their search/fetch choices and connection fields.
struct HostWebSearchPage: View {
    let host: Harness
    @State private var settings: DescribedSettings?
    @State private var issue: String?
    @State private var busy = false
    @State private var editing: ValueEdit?
    @State private var advanced = false
    @State private var searchModel = ""

    private static let messagesNs = "web-search-deepseek", apiNs = "web-deepseek-api"
    private static let followingProvider = "pallas-web-search"
    private var modelSettings: WebSearchSettings? { host.localEngineHome.map(WebSearchSettings.init(home:)) }
    private var followsModel: Bool { settings?.value("web", "searchProvider") as? String == Self.followingProvider }
    private var switchable: Bool { !followsModel && settings?.section("web") != nil && settings?.section(Self.apiNs) != nil }
    private var newAPI: Bool { switchable && settings?.value("web", "searchProvider") as? String == "deepseek-search-api" }
    private var ns: String { newAPI ? Self.apiNs : Self.messagesNs }

    var body: some View {
        SettingsList {
            if settings != nil, followsModel {
                Section {
                    SettingsRowLabel(title: String(localized: "搜索服务"), value: String(localized: "跟随当前模型"), chevron: false)
                        .accessibilityIdentifier("webSearchFollowsModel")
                    if let modelSettings {
                        NavigationLink {
                            WebSearchModelPage(models: openAIModels, selected: searchModel, settings: modelSettings) { searchModel = $0 }
                        } label: {
                            SettingsRowLabel(title: String(localized: "联网搜索模型"), value: searchModel.isEmpty ? String(localized: "自动") : searchModel, chevron: false)
                        }.accessibilityIdentifier("webSearchModel")
                    }
                }.listRowBackground(ChatColors.chip)
                if let issue { Text(issue).foregroundStyle(.red).listRowBackground(ChatColors.chip) }
            } else if let settings {
                if modelSettings != nil, settings.section("web") != nil {
                    Section {
                        Button("跟随当前模型") { useProvider(search: Self.followingProvider, fetch: "http") }
                            .disabled(!settings.writable || busy).accessibilityIdentifier("webSearchRestoreFollowing")
                    }.listRowBackground(ChatColors.chip)
                }
                if switchable {
                    Section {
                        Toggle("更快的搜索", isOn: Binding(get: { newAPI }, set: { useNewAPI($0) }))
                            .disabled(!settings.writable || busy).accessibilityIdentifier("webSearchNewApi")
                    }.listRowBackground(ChatColors.chip)
                }
                if let section = settings.section(ns) {
                    Section {
                        DisclosureGroup("高级", isExpanded: $advanced) {
                            fieldRow(section, key: "apiKey", title: "API Key")
                            fieldRow(section, key: "baseURL", title: String(localized: "服务地址"))
                            fieldRow(section, key: newAPI ? "count" : "maxUses", title: newAPI ? String(localized: "每次搜索结果数") : String(localized: "每次请求最多搜索"))
                        }.accessibilityIdentifier("webSearchAdvanced")
                    }.listRowBackground(ChatColors.chip)
                } else {
                    OfflineMessage(symbol: "nosign", title: String(localized: "这台设备没有联网搜索设置")).listRowBackground(Color.clear)
                }
                if let issue { Text(issue).foregroundStyle(.red).listRowBackground(ChatColors.chip) }
            } else if let issue {
                OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取设置"), detail: issue) { Task { await load() } }
                    .listRowBackground(Color.clear)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .settingsPage(String(localized: "联网搜索"))
        .task(id: ObjectIdentifier(host)) {
            settings = nil
            await load()
        }
        .sheet(item: $editing) { edit in
            if let section = settings?.section(ns) {
                SettingsValueEditor(host: host, ns: ns, revision: section["revision"] as? Int, path: edit.path, secret: edit.secret,
                                    writable: settings?.writable == true, title: edit.title,
                                    initial: edit.secret ? nil : (section["value"] as? Object)?[edit.path[0]]) { _ in Task { await load() } }
            }
        }
    }

    private func fieldRow(_ section: Object, key: String, title: String) -> some View {
        let secret = (section["secrets"] as? [Object] ?? []).first { ($0["path"] as? [String]) == [key] }
        let value: String
        if let secret { value = secret["set"] as? Bool == true ? String(localized: "已配置") : String(localized: "未配置") }
        else if let raw = (section["value"] as? Object)?[key] { value = (raw as? NSNumber)?.stringValue ?? (raw as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "默认") }
        else { value = String(localized: "默认") }
        return Button { editing = ValueEdit(path: [key], secret: secret != nil, title: title) } label: {
            SettingsRowLabel(title: title, value: value)
        }.disabled(settings?.writable != true)
    }

    private func useNewAPI(_ on: Bool) {
        useProvider(search: on ? "deepseek-search-api" : "deepseek-official", fetch: on ? "deepseek-fetch-api" : "http")
    }

    private func useProvider(search: String, fetch: String) {
        guard let revision = settings?.section("web")?["revision"] as? Int else { return }
        let ops: [Object] = [["op": "set", "path": ["searchProvider"], "value": search],
                             ["op": "set", "path": ["fetchProvider"], "value": fetch]]
        busy = true
        Task {
            defer { busy = false }
            var failure: String?
            do { _ = try await host.rpc("settings/mutate", args: ["ns": "web", "ops": ops, "expectedRevision": revision]) }
            catch { failure = HostError.explain(error) }
            await load()
            issue = failure
        }
    }

    /// The models of the OpenAI channels web-search.cjs searches with (ChatGPT's first), without repeats.
    private var openAIModels: [String] {
        let providers = (settings?.value("llm-pi-ai", "providers") as? Object) ?? [:]
        var seen = Set<String>(), list: [String] = []
        let routes = providers.keys.sorted { ($0 == ChatGPTChannel.route ? 0 : 1, $0) < ($1 == ChatGPTChannel.route ? 0 : 1, $1) }
        for route in routes {
            guard let profile = providers[route] as? Object, let base = profile["baseURL"] as? String,
                  let url = URLComponents(string: base), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "api.openai.com", url.port == nil || url.port == 443,
                  url.user == nil, url.password == nil,
                  let reference = profile["apiKeyEnv"] as? String, !reference.isEmpty else { continue }
            for entry in profile["models"] as? [Any] ?? [] {
                guard let id = (entry as? String) ?? ((entry as? Object)?["id"] as? String), !id.isEmpty, seen.insert(id).inserted else { continue }
                list.append(id)
            }
        }
        return list
    }

    private func load() async {
        searchModel = modelSettings?.model ?? ""
        do {
            let described = try await DescribedSettings.read(host)
            guard !Task.isCancelled else { return }
            settings = described
            issue = nil
        }
        catch { if !Task.isCancelled { issue = HostError.explain(error) } }
    }
}

/// The managed engine reads this file on each search. Missing or empty means automatic.
struct WebSearchSettings {
    let home: URL
    private var file: URL { home.appending(path: "web-search.json") }

    var model: String {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? Object else { return "" }
        return (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func save(model: String) throws {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ["model": value], options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
    }
}

/// 联网搜索模型: 自动, the OpenAI channels' models, or any model id typed in.
private struct WebSearchModelPage: View {
    let models: [String]
    let selected: String
    let settings: WebSearchSettings
    let changed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var issue = false

    var body: some View {
        SettingsList {
            Section {
                row(String(localized: "自动"), id: "")
                ForEach(models, id: \.self) { row($0, id: $0) }
                if !selected.isEmpty, !models.contains(selected) { row(selected, id: selected) }
            }.listRowBackground(ChatColors.chip)
            if issue { Text("没能保存").foregroundStyle(.red) }
            Section {
                HStack {
                    TextField("其他模型", text: $custom)
                        .noAutomaticCapitalization().autocorrectionDisabled().submitLabel(.done)
                        .onSubmit(useCustom).accessibilityIdentifier("webSearchCustomModel")
                    Button("使用", action: useCustom).disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.listRowBackground(ChatColors.chip)
        }
        .settingsPage(String(localized: "联网搜索模型"))
    }

    private func row(_ title: String, id: String) -> some View {
        Button { pick(id) } label: {
            HStack {
                Text(verbatim: title).foregroundStyle(ChatColors.ink)
                Spacer()
                if id == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(id == selected ? .isSelected : [])
    }

    private func useCustom() {
        let value = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        pick(value)
    }

    private func pick(_ id: String) {
        do {
            try settings.save(model: id)
            changed(id)
            dismiss()
        } catch {
            issue = true
        }
    }
}
