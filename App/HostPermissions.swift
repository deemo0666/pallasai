import SwiftUI

/// One selectable preset from `permissionPresets/catalog`.
struct PermissionOption: Identifiable, Equatable {
    let value: String
    let name: String
    let detail: String?
    var id: String { value }

    init(value: String, name: String = "", detail: String? = nil) {
        self.value = value; self.name = name; self.detail = detail
    }

    init?(_ object: Object) {
        guard let value = object["value"] as? String, !value.isEmpty else { return nil }
        self.init(value: value, name: object["name"] as? String ?? "", detail: object["description"] as? String)
    }

    /// The official names of the built-in presets; others keep the host's name.
    var title: String {
        switch value {
        case "read-only": String(localized: "只看不改")
        case "workspace-write": String(localized: "改动先问我")
        case "danger-full-access": String(localized: "全部放行")
        case "auto": String(localized: "AI 帮我把关")
        case "custom": String(localized: "自定义")
        default: name.isEmpty ? value : name
        }
    }

    var hint: String? {
        switch value {
        case "read-only", "workspace-write", "danger-full-access", "auto": nil
        default: detail.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Presets that stop asking before commands run need a confirmation first.
    var risk: (title: String, body: String, action: String)? {
        switch value {
        case "danger-full-access": (String(localized: "开启全部放行？"), String(localized: "执行命令、改动文件（包括授权文件夹里的文件）、让电脑执行任务之前，都不再问你。"), String(localized: "开启全部放行"))
        case "auto": (String(localized: "开启 AI 帮我把关？"), String(localized: "每次操作由 AI 判断放不放行，可能误判。"), String(localized: "开启 AI 帮我把关"))
        default: nil
        }
    }
}

/// What the 权限 page shows: the presets, the session's current one and the
/// default for new sessions, all as the host reports them.
struct HostPermissionState: Equatable {
    static let namespace = "permission"

    var options: [PermissionOption]
    var defaultOptions: [PermissionOption]
    /// `permission.defaultPreset`, else the catalog's default.
    var hostDefault: String
    /// The session's `permissions` projection; nil without a session.
    var current: String?
    /// Revision of the `permission` namespace; nil when the host can't write it.
    var revision: Int?
    /// The stored default is the session-only Auto preset, which the catalog refuses.
    var invalidDefault: Bool

    static func read(_ host: Harness, session: String?) async throws -> Self {
        let described = try? await host.rpc("settings/describe", args: [:])
        let section = (described?["namespaces"] as? [Object])?.first { $0["ns"] as? String == namespace }
        let stored = (section?["value"] as? Object)?["defaultPreset"] as? String
        var options: [PermissionOption] = [], defaults: [PermissionOption] = [], catalogDefault = ""
        var invalid = false
        do {
            let catalog = try await host.rpc("permissionPresets/catalog", args: [:])
            options = (catalog["options"] as? [Object] ?? []).compactMap(PermissionOption.init)
            // Older catalogs omit defaultOptions. Auto is a session-only preset.
            if let list = catalog["defaultOptions"] as? [Object] { defaults = list.compactMap(PermissionOption.init) }
            else { defaults = options.filter { $0.value != "auto" } }
            catalogDefault = catalog["defaultPreset"] as? String ?? ""
        } catch {
            // Earlier clients could store Auto as the default; the catalog then fails.
            // Keep the explicit reset reachable instead of a dead page.
            guard stored == "auto" else { throw error }
            invalid = true
        }
        var current: String?
        if let session, !session.isEmpty {
            let projections = try? await host.call("session/projections", ["sessionId": session])
            current = ((projections?["values"] as? Object)?["permissions"] as? Object)?["currentValue"] as? String
        }
        let writable = described?["writable"] as? Bool != false
        return Self(options: options, defaultOptions: defaults, hostDefault: stored ?? catalogDefault, current: current,
                    revision: writable ? section?["revision"] as? Int : nil, invalidDefault: invalid)
    }
}

/// 权限: the current conversation's preset (`/permission`) and the default for
/// new conversations (`permission.defaultPreset`). Without a host it says so.
struct HostPermissionView: View {
    let host: Harness?
    @State private var state: HostPermissionState?
    @State private var note: String?
    @State private var busy = false
    @State private var confirming: Change?
    @State private var folderCount: Int?
    @AppStorage(AuthorizedFolders.bookmarksKey) private var folderBookmarks = Data()
    @AppStorage(MacTask.autoAllowKey) private var macAutoAllow = false
    #if os(macOS)
    private var local: Bool { host?.usesEmbeddedEngine == true }
    #else
    /// Full access was chosen and iCloud Drive is not open to Pallas yet: iOS lets only the person grant it.
    @State private var pickingICloud = false
    /// Phone control belongs to the engine running on this iPhone.
    private var local: Bool { host.map { EmbeddedEngine.shared.owns($0) } ?? false }
    #endif

    private struct Change: Identifiable {
        let option: PermissionOption
        let isDefault: Bool
        var id: String { (isDefault ? "default:" : "current:") + option.value }
    }

    private var session: String? { host.flatMap { $0.sessionID.isEmpty ? nil : $0.sessionID } }

    var body: some View {
        Form {
            if host == nil {
                OfflineMessage().listRowBackground(Color.clear)
            } else if let note {
                Section {
                    Text(note).foregroundStyle(.red).accessibilityIdentifier("permissionIssue")
                    Button("重新加载") { Task { await load() } }
                }.listRowBackground(ChatColors.chip)
            }
            if let state {
                if session != nil, !state.invalidDefault {
                    Section {
                        ForEach(state.options) { option in
                            row(option, selected: option.value == state.current, id: "permissionCurrent-" + option.value) {
                                request(Change(option: option, isDefault: false))
                            }
                        }
                    } header: { Text("这个对话") }.listRowBackground(ChatColors.chip)
                }
                if state.invalidDefault {
                    Section {
                        Label("新对话的默认权限已失效", systemImage: "lock.shield")
                        if state.revision != nil { Button("恢复默认") { resetDefault() }.accessibilityIdentifier("permissionResetDefault") }
                    }.listRowBackground(ChatColors.chip)
                } else {
                    Section {
                        ForEach(state.defaultOptions) { option in
                            row(option, selected: option.value == state.hostDefault, id: "permissionDefault-" + option.value) {
                                request(Change(option: option, isDefault: true))
                            }.disabled(state.revision == nil)
                        }
                    } header: { Text("新对话") } footer: {
                        if state.revision == nil { Text("这台设备不允许改新对话的权限。") }
                    }.listRowBackground(ChatColors.chip)
                }
            } else if note == nil, host != nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if local {
                // The same kind of choice as the conversation presets above: ask first, or let it through.
                Section {
                    choice(String(localized: "每次先问我"), selected: !macAutoAllow, id: "macTaskAsk") { macAutoAllow = false }
                    choice(String(localized: "全部放行"), selected: macAutoAllow, id: "macTaskAutoAllow") { macAutoAllow = true }
                } header: { Text("电脑任务") }.listRowBackground(ChatColors.chip)
            }
            #if os(iOS)
            if local {
                Section {
                    NavigationLink { SavedAccountsPage() } label: {
                        LabeledContent("账号密码", value: SavedAccounts.shared.accounts.isEmpty ? "" : String(localized: "\(SavedAccounts.shared.accounts.count) 个"))
                    }.accessibilityIdentifier("permissionAccounts")
                } header: { Text("全自动") }.listRowBackground(ChatColors.chip)
            }
            #endif
            if local {
                Section {
                    NavigationLink { AuthorizedFoldersPage() } label: {
                        LabeledContent("授权文件夹", value: folderCount.map { String(localized: "\($0) 个") } ?? "")
                    }.accessibilityIdentifier("permissionFolders")
                } header: { Text("文件") }.listRowBackground(ChatColors.chip)
            }
            #if os(iOS)
            SystemAccessSection()
            #endif
        }
        .disabled(busy)
        .settingsPage(String(localized: "权限"))
        .task { await load() }
        #if os(iOS)
        .fileImporter(isPresented: $pickingICloud, allowedContentTypes: [.folder]) { result in
            Task {
                do {
                    try await AuthorizedFolders.shared.authorize(result.get())
                    folderCount = (try? await AuthorizedFolders.shared.grants())?.count
                    EmbeddedEngine.shared.foldersChanged()
                } catch { if (error as NSError).code != NSUserCancelledError { note = HostError.explain(error) } }
            }
        }
        #endif
        .task(id: folderBookmarks) {
            if local { folderCount = (try? await AuthorizedFolders.shared.grants())?.count }
        }
        .alert(confirming?.option.risk?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { change in
            Button(change.option.risk?.action ?? String(localized: "开启"), role: .destructive) { apply(change) }
            Button("取消", role: .cancel) {}
        } message: { change in Text(change.option.risk?.body ?? "") }
    }

    private func choice(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(verbatim: title).foregroundStyle(ChatColors.ink)
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint).opacity(selected ? 1 : 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ option: PermissionOption, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: option.title).foregroundStyle(ChatColors.ink)
                    if let hint = option.hint { Text(verbatim: hint).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(2) }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint).opacity(selected ? 1 : 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func request(_ change: Change) {
        guard !busy else { return }
        if change.option.risk != nil { confirming = change } else { apply(change) }
    }

    private func apply(_ change: Change) {
        confirming = nil
        busy = true; note = nil
        Task {
            defer { busy = false }
            do {
                if change.isDefault { try await setDefault(change.option.value) } else { try await setCurrent(change.option.value) }
                #if os(iOS)
                if local, change.option.value == "danger-full-access", !(await AuthorizedFolders.shared.hasICloudDrive()) { pickingICloud = true }
                #endif
            } catch { note = HostError.explain(error) }
        }
    }

    /// `/permission <preset>` through `commands/execute`, then the session's own
    /// projection decides what the page shows.
    private func setCurrent(_ value: String) async throws {
        guard let session, let host else { return }
        let reply = try await host.rpc("commands/execute", args: ["agentId": session, "line": "/permission " + value,
                                                                  "submittedAttachments": [] as [Any]])
        let result = reply["result"] as? Object
        guard result?["kind"] as? String == "success" else {
            await load()
            throw HostError((result?["text"] as? String).flatMap { $0.isEmpty ? nil : String(localized: "切换失败：") + $0 } ?? String(localized: "权限没有切换成功。"))
        }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            let confirmed = try await HostPermissionState.read(host, session: session)
            state = confirmed
            if confirmed.current == value { return }
        }
        throw HostError(String(localized: "权限没有换成你选的，重新加载后再看。"))
    }

    private func setDefault(_ value: String) async throws {
        guard let revision = state?.revision, let host else { throw HostError(String(localized: "这台设备不允许改新对话的权限。")) }
        _ = try await host.rpc("settings/mutate", args: ["ns": HostPermissionState.namespace, "expectedRevision": revision,
                                                         "ops": [["op": "set", "path": ["defaultPreset"], "value": value]]])
        let confirmed = try await HostPermissionState.read(host, session: session)
        state = confirmed
        guard confirmed.hostDefault == value else { throw HostError(String(localized: "新对话的权限没有换成你选的，重新加载后再看。")) }
    }

    private func resetDefault() {
        guard let revision = state?.revision, let host, !busy else { return }
        busy = true; note = nil
        Task {
            defer { busy = false }
            do {
                _ = try await host.rpc("settings/mutate", args: ["ns": HostPermissionState.namespace, "expectedRevision": revision,
                                                                 "ops": [["op": "unset", "path": ["defaultPreset"]]]])
                await load()
            } catch { note = error.localizedDescription }
        }
    }

    private func load() async {
        guard let host else { return }
        do {
            state = try await HostPermissionState.read(host, session: session)
            note = nil
        } catch { if !Task.isCancelled { note = String(localized: "没能读取权限设置。") + error.localizedDescription } }
    }
}
