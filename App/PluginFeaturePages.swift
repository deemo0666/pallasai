// 「全部功能 → 插件」里的 Cordis、智能体团队和思考过程翻译。
//
// - Cordis：`dynamicCordisRunner/inventory` 列出主机上的动态插件，本对话的排前面；可停止、移除。
//   运行许可沿用主机：等待批准的插件只显示状态，批准在 DSH 网页版完成。
// - 智能体团队：需要官方 bundle `dsh-experimental-agent-team-profile`；成员和任务来自当前对话的
//   `agentTeam` projection，页面打开时每 3 秒重读一次。
// - 思考过程翻译：需要 `dsh-experimental-cot-translation-bundle`；`cotTranslation/limits` 给出可用的
//   翻译服务，设置用通用插件设置表单读写 `cot-translation`。
// 主机缺少相应能力时，页面显示原因；能启用的官方组件给出「启用」。

import SwiftUI

/// The three cards, then one per installed third-party plugin, in the 插件 section of 全部功能.
#if os(iOS)
struct PluginFeatureCards: View {
    let host: Harness?
    let chat: Conversation
    @StateObject private var installed = InstalledPlugins()

    var body: some View {
        // The first card always shows, so it carries the load: it runs whenever 全部功能 opens.
        PluginFeatureCard(title: "Cordis", symbol: "cube", host: host) { if let host { CordisPage(host: host) } }
            .task(id: host.map(ObjectIdentifier.init)) { await installed.load(host) }
        PluginFeatureCard(title: String(localized: "智能体团队"), symbol: "person.3", host: host) { if let host { AgentTeamPage(host: host) } }
        PluginFeatureCard(title: String(localized: "思考过程翻译"), symbol: "text", host: host) { if let host { CotTranslationPage(host: host) } }
        if let store = installed.store {
            ForEach(installed.bundles) { bundle in
                PluginFeatureCard(title: bundle.title, symbol: "blocks", host: host) {
                    HostPluginBundleDetail(store: store, name: bundle.name)
                }.accessibilityIdentifier("pluginCard-" + bundle.name)
            }
        }
    }
}
#endif

/// The plugins installed on the host (not DSH 官方), for their cards; a plugin installed meanwhile
/// shows up the next time 全部功能 opens.
@MainActor
final class InstalledPlugins: ObservableObject {
    @Published private(set) var bundles: [HostPluginBundle] = []
    private(set) var store: HostPluginStore?

    func load(_ host: Harness?) async {
        guard let host else { store = nil; bundles = []; return }
        if store?.host !== host { store = HostPluginStore(host: host); bundles = [] }
        guard let store else { return }
        await store.refresh()
        guard !Task.isCancelled, self.store === store else { return }
        update(from: store)
    }

    func update(from store: HostPluginStore) {
        guard let entries = store.bundles else { return }
        self.store = store
        bundles = entries.filter { $0.group == .installed }
    }
}

#if os(iOS)
private struct PluginFeatureCard<Destination: View>: View {
    let title: String
    let symbol: String
    let host: Harness?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            FeatureTileLabel(title: title, symbol: symbol, enabled: host != nil)
        }.buttonStyle(.pressable).disabled(host == nil).accessibilityLabel(title).accessibilityHint(host == nil ? "先连接一台设备" : "")
    }
}

#endif

/// An official optional bundle a feature needs: missing, off (with 启用), or on.
struct OptionalBundleGate: View {
    let host: Harness
    let name: String
    let feature: String
    @Binding var enabled: Bool?
    @State private var bundle: HostPluginBundle?
    @State private var missing = false
    @State private var working = false
    @State private var issue: String?

    var body: some View {
        Group {
            if missing {
                OfflineMessage(symbol: "nosign", title: String(localized: "这台设备没有\(feature)"), detail: String(localized: "更新这台设备上的服务后再试。"))
            } else if let bundle, !bundle.enabled {
                VStack(spacing: 10) {
                    OfflineMessage(symbol: "power", title: String(localized: "\(feature)未启用"), detail: bundle.readOnlyReason == nil ? nil : String(localized: "这台设备不允许在这里启用它。"))
                    if bundle.readOnlyReason == nil, bundle.switchable {
                        Button(working ? "正在启用…" : "启用") { enable(bundle) }.prominentButton().disabled(working)
                            .accessibilityIdentifier("enableBundle")
                    }
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                }
            } else if let issue, bundle == nil {
                OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取插件列表"), detail: issue) { Task { await load() } }
            } else if bundle == nil {
                // Something must show while checking: an empty Group in a List never runs its task.
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let rows = (try await host.rpcValue("pluginManager/listBundles", args: [:]) as? [Object] ?? []).map(HostPluginBundle.init)
            bundle = rows.first { $0.name == name }
            missing = bundle == nil
            enabled = bundle?.enabled == true
            issue = nil
        } catch { issue = HostError.explain(error); enabled = false }
    }

    private func enable(_ bundle: HostPluginBundle) {
        working = true; issue = nil
        Task {
            defer { working = false }
            do {
                let result = try await host.rpc("pluginManager/setBundleEnabled", args: ["name": bundle.name, "enabled": true])
                if result["application"] as? String == "restart-required" { issue = String(localized: "已保存，重新打开后生效。") }
                if let error = result["error"] as? Object { issue = HostPluginStore.explain(error) }
            } catch { issue = String(localized: "没能启用：") + HostError.explain(error) }
            await load()
        }
    }
}

// MARK: - Cordis

struct CordisPage: View {
    let host: Harness
    private struct Row: Identifiable {
        let raw: Object
        var id: String { (raw["agentId"] as? String ?? "") + "/" + (raw["pluginId"] as? String ?? "") }
        var pluginID: String { raw["pluginId"] as? String ?? "" }
        var agentID: String { raw["agentId"] as? String ?? "" }
        var shown: Object? {
            let packages = raw["packages"] as? [Object] ?? []
            let pick = raw["nextPackageId"] as? String ?? raw["currentPackageId"] as? String
            return packages.first { $0["packageId"] as? String == pick } ?? packages.last
        }
        var name: String { shown?["name"] as? String ?? pluginID }
        var purpose: String? { shown?["purpose"] as? String }
        var running: Bool { raw["activeRun"] is Object }
        var latest: Object? { raw["latestRun"] as? Object }
        var awaiting: Bool { latest?["status"] as? String == "awaiting-approval" }
        var status: (String, Color) {
            if awaiting { return (String(localized: "等待批准"), .orange) }
            if latest?["status"] as? String == "failed", latest?["packageId"] as? String == shown?["packageId"] as? String {
                let phase = (latest?["error"] as? Object)?["phase"] as? String ?? ""
                return (phase == "approval" ? String(localized: "未获批准") : phase.hasPrefix("client") ? String(localized: "界面部分失败") : String(localized: "运行失败"), .red)
            }
            if running { return (String(localized: "运行中"), SettingsStyle.ok) }
            if latest?["status"] as? String == "starting-host" { return (String(localized: "启动中"), .accentColor) }
            return (String(localized: "未运行"), ChatColors.muted)
        }
    }

    @State private var rows: [Row]?
    @State private var unavailable: String?
    @State private var issue: String?
    @State private var working: String?
    @State private var removing: Row?

    init(host: Harness) { self.host = host }

    var body: some View {
        List {
            if let unavailable {
                OfflineMessage(symbol: "nosign", title: String(localized: "这台设备不能使用 Cordis"), detail: unavailable).listRowBackground(Color.clear)
            } else if let rows {
                let mine = rows.filter { $0.agentID == host.sessionID }, others = rows.filter { $0.agentID != host.sessionID }
                if rows.isEmpty {
                    Section {
                        HostEmptyState(symbol: "cube", title: String(localized: "还没有动态插件"))
                    }.listRowBackground(Color.clear)
                }
                if !mine.isEmpty { Section("这个对话") { ForEach(sorted(mine)) { row($0) } }.listRowBackground(ChatColors.chip) }
                if !others.isEmpty { Section("其他对话") { ForEach(sorted(others)) { row($0) } }.listRowBackground(ChatColors.chip) }
                if let issue { Section { Text(issue).foregroundStyle(.red) } }
            } else { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
        }
        .groupedList().scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("Cordis").inlineNavigationTitle()
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .refreshable { await load() }
        .confirmationDialog("移除「\(removing?.name ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { row in
            Button("移除", role: .destructive) { act("undefineFromPanel", row) }
        } message: { _ in Text("插件会从它所在的对话里删除。") }
    }

    private func sorted(_ rows: [Row]) -> [Row] { rows.sorted { $0.awaiting && !$1.awaiting } }

    private func row(_ row: Row) -> some View {
        let status = row.status
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: row.name).font(.body.weight(.medium))
                Spacer()
                Text(status.0).font(.caption.weight(.semibold)).foregroundStyle(status.1)
            }
            if let purpose = row.purpose { Text(verbatim: purpose).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(2) }
            if row.awaiting { Text("等待在电脑的网页版里批准运行。").font(.caption).foregroundStyle(.orange) }
            if let message = (row.latest?["error"] as? Object)?["message"] as? String { Text(verbatim: message).font(.caption).foregroundStyle(.red).lineLimit(3) }
            HStack {
                Button("停止") { act("stopFromPanel", row) }.disabled(!row.running || working != nil)
                Button("移除", role: .destructive) { removing = row }.disabled(working != nil)
                if working == row.id { ProgressView() }
            }.buttonStyle(.bordered).font(.caption)
        }.padding(.vertical, 4).accessibilityIdentifier("cordis-" + row.pluginID)
    }

    private func load() async {
        do {
            let value = try await host.rpcValue("dynamicCordisRunner/inventory", args: [:])
            rows = (value as? [Object] ?? []).map(Row.init)
            unavailable = nil
        } catch let error as HostError {
            if rows == nil { unavailable = error.code == nil ? error.message : String(localized: "更新这台设备上的服务后再试。") }
        } catch { if rows == nil { unavailable = error.localizedDescription } }
    }

    private func act(_ method: String, _ row: Row) {
        working = row.id; issue = nil
        Task {
            defer { working = nil }
            do {
                let result = try await host.rpc("dynamicCordisRunner/" + method, args: ["agentId": row.agentID, "pluginId": row.pluginID])
                if result["ok"] as? Bool != true, let reason = result["reason"] as? String { issue = reason == "not-running" ? String(localized: "插件已经停了。") : String(localized: "没能完成。请稍后重试。") }
            } catch { issue = HostError.explain(error) }
            await load()
        }
    }
}

// MARK: - 智能体团队

struct AgentTeamPage: View {
    let host: Harness
    @State private var enabled: Bool?
    @State private var team: Object?
    @State private var noTeam = false
    @State private var issue: String?
    static let bundle = "@deepseek-ai/dsh-experimental-agent-team-profile"

    var body: some View {
        List {
            if enabled != true {
                OptionalBundleGate(host: host, name: Self.bundle, feature: String(localized: "智能体团队"), enabled: $enabled).listRowBackground(Color.clear)
            } else if let team {
                let members = team["members"] as? [Object] ?? []
                let tasks = (team["tasks"] as? [Object] ?? []).filter { $0["status"] as? String != "deleted" }
                Section("成员") {
                    ForEach(Array(members.enumerated()), id: \.offset) { _, member in memberRow(member) }
                }.listRowBackground(ChatColors.chip)
                Section("任务") {
                    if tasks.isEmpty { Text("还没有任务").foregroundStyle(ChatColors.muted) }
                    ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: task["subject"] as? String ?? "—")
                                if let owner = task["ownerName"] as? String { Text(verbatim: owner).font(.caption).foregroundStyle(ChatColors.muted) }
                            }
                            Spacer()
                            Text(Self.taskStatus(task["status"] as? String)).font(.caption).foregroundStyle(ChatColors.muted)
                        }
                    }
                }.listRowBackground(ChatColors.chip)
                if let failure = team["failure"] as? String { Section { Text(verbatim: failure).foregroundStyle(.red) } }
            } else if noTeam {
                Section {
                    HostEmptyState(symbol: "person.3", title: String(localized: "这个对话还没有团队"))
                }.listRowBackground(Color.clear)
            } else if let issue {
                OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取团队"), detail: issue) { Task { await load() } }.listRowBackground(Color.clear)
            } else { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
        }
        .groupedList().scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("智能体团队").inlineNavigationTitle()
        .task(id: enabled) {
            guard enabled == true else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
    }

    private func memberRow(_ member: Object) -> some View {
        let phase = member["phase"] as? String
        let (label, color): (String, Color) = phase == "provisioning" ? (String(localized: "准备中"), .orange) : phase == "failed" ? (String(localized: "失败"), .red) : (String(localized: "在线"), SettingsStyle.ok)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: member["name"] as? String ?? "—").font(.body.weight(.medium))
                    if member["role"] as? String == "lead" { HostStateChip(label: String(localized: "负责人"), tone: .busy) }
                }
                if let error = member["error"] as? String { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("teamMember-" + (member["name"] as? String ?? ""))
    }

    private static func taskStatus(_ status: String?) -> String {
        switch status {
        case "pending": String(localized: "待领取")
        case "in_progress": String(localized: "进行中")
        case "completed": String(localized: "已完成")
        default: status ?? "—"
        }
    }

    private func load() async {
        do {
            let value = try await host.rpc("session/projections", args: ["request": ["sessionId": host.sessionID]])
            let projection = (value["values"] as? Object)?["agentTeam"] as? Object
            let members = projection?["members"] as? [Object] ?? []
            if let projection, !members.isEmpty { team = projection; noTeam = false } else { team = nil; noTeam = true }
            issue = nil
        } catch { if !Task.isCancelled { issue = HostError.explain(error) } }
    }
}

// MARK: - 思考过程翻译

struct CotTranslationPage: View {
    let host: Harness
    @State private var enabled: Bool?
    @State private var limits: Object?
    @State private var issue: String?
    static let bundle = "@deepseek-ai/dsh-experimental-cot-translation-bundle"

    private static func provider(_ id: String) -> String { copy(offered: nil)["provider"]?.options[id] ?? id }

    /// The host names these fields only by key; the wording here is the app's.
    static func copy(offered: [String]?) -> [String: ConfigCopy] {
        ["provider": ConfigCopy(title: String(localized: "翻译服务"), options: ["bing": String(localized: "Bing 翻译"), "google": String(localized: "Google 翻译"), "deepseek-account": String(localized: "DeepSeek 账号（付费）"),
                                                       "deepseek-official": String(localized: "DeepSeek API（付费）")], offered: offered.map(Set.init)),
         "targetLanguage": ConfigCopy(title: String(localized: "目标语言"), detail: String(localized: "auto，或 zh、en、ja 等语言代码"))]
    }

    var body: some View {
        Group {
            if enabled != true {
                List { OptionalBundleGate(host: host, name: Self.bundle, feature: String(localized: "思考过程翻译"), enabled: $enabled).listRowBackground(Color.clear) }
                    .scrollContentBackground(.hidden)
            } else {
                VStack(spacing: 0) {
                    if let limits {
                        let providers = (limits["availableProviders"] as? [String] ?? []).map(Self.provider)
                        Text([String(localized: "每段最多 \(limits["maxTextChars"] as? Int ?? 4000) 字"), providers.isEmpty ? nil : String(localized: "可用：") + providers.joined(separator: String(localized: "、"))].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(ChatColors.muted).padding(.horizontal, 16).padding(.top, 8)
                    } else if let issue {
                        Text(issue).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.top, 8)
                    }
                    PluginSettingsForm(host: host, ns: "cot-translation", title: String(localized: "思考过程翻译"), copy: Self.copy(offered: limits?["availableProviders"] as? [String]))
                }
            }
        }
        .background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("思考过程翻译").inlineNavigationTitle()
        .task(id: enabled) {
            guard enabled == true else { return }
            do { limits = try await host.rpc("cotTranslation/limits", args: [:]); issue = nil }
            catch { issue = String(localized: "没能读取翻译服务信息。请稍后重试。") }
        }
    }
}
