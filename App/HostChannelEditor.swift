// 主机的自定义模型渠道：`llm-pi-ai` 的 `providers.<route>`。
//
// 字段和接口协议的选项取自主机 `settings/describe` 给的 schema；API Key 不进设置文件，用
// `credentials/set {ref, value}` 存进主机凭据，渠道里只记引用名（`apiKeyEnv`）。编辑时「保留原 API Key」
// 不碰凭据，「替换 API Key」写入新值；表单从不回填原 API Key。新建写整个渠道，编辑只写改了的字段，都带
// `expectedRevision`；主机拒绝或版本冲突时草稿保留，显示原因并读回最新版本号。

import SwiftUI

/// What the host's schema says a channel may hold.
struct ChannelSchema {
    var fields: Set<String> = []
    var apis: [String] = []
    var modelFields: Set<String> = []

    init(_ schema: Object?) {
        guard let schema, let refs = schema["refs"] as? Object else { return }
        func node(_ id: Any?) -> Object? { refs[(id as? NSNumber)?.stringValue ?? (id as? String) ?? ""] as? Object }
        guard let root = node(schema["uid"]), let providers = node((root["dict"] as? Object)?["providers"]),
              let profile = node(providers["inner"]), let dict = profile["dict"] as? Object else { return }
        fields = Set(dict.keys)
        if let api = node(dict["api"]) {
            apis = (api["list"] as? [Any] ?? []).compactMap(node).compactMap { $0["value"] as? String }
        }
        if let models = node(dict["models"]), let item = node(models["inner"]), let keys = item["dict"] as? Object { modelFields = Set(keys.keys) }
    }
}

struct HostModelService: Identifiable {
    enum Health {
        case ready, missingKey, misconfigured, inactive

        var label: String {
            switch self {
            case .ready: String(localized: "可用")
            case .missingKey: String(localized: "缺少 API Key")
            case .misconfigured: String(localized: "配置有误")
            case .inactive: String(localized: "未启用")
            }
        }

        var color: Color {
            switch self {
            case .ready: SettingsStyle.ok
            case .missingKey: SettingsStyle.warning
            case .misconfigured: .red
            case .inactive: ChatColors.muted.opacity(0.5)
            }
        }
    }

    static let namespace = "llm-pi-ai"
    let id: String
    let name: String
    let api: String?
    let models: Int
    let health: Health

    /// Nil when the host does not expose an editable model-service namespace.
    @MainActor static func list(on host: Harness) async throws -> [Self]? {
        let described = try await host.rpc("settings/describe", args: [:])
        guard let section = (described["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == namespace }) else {
            return nil
        }
        let profiles = ((section["value"] as? Object)?["providers"] as? Object ?? [:]).sorted { $0.key < $1.key }
        // Managed subscriptions have their own sign-in and credential workflow.
        let custom = profiles.filter { entry in
            let profile = entry.value as? Object
            let key = profile?["apiKeyEnv"] as? String ?? ""
            let claude = false
            return !(["openai-codex", "anthropic"].contains(entry.key) && key.isEmpty)
                && !ChatGPTChannel.owns(route: entry.key, profile: profile) && !claude
        }
        let refs = custom.compactMap { ($0.value as? Object)?["apiKeyEnv"] as? String }.filter { !$0.isEmpty }
        let credentials: Object = refs.isEmpty ? [:] : ((try? await host.rpc("credentials/describe", args: ["refs": refs])) ?? [:])
        let listed = try? await host.rpcValue("llm/listProviders", args: [:]) as? [Object]
        let registered = listed.map { Set($0.compactMap { $0["id"] as? String }) }
        let configurable = (try? await host.rpcValue("llm/listConfigurableProviders", args: [:]) as? [Object]) ?? []
        let misconfigured = Set(configurable.compactMap { item -> String? in
            guard item["settingsNs"] as? String == namespace, item["error"] is String else { return nil }
            return item["provider"] as? String
        })
        try Task.checkCancellation()
        return custom.map { entry in
            let route = entry.key
            let profile = entry.value as? Object ?? [:]
            let ref = profile["apiKeyEnv"] as? String
            let health: Health
            if misconfigured.contains(route) { health = .misconfigured }
            else if let ref, !ref.isEmpty, (credentials[ref] as? Object)?["configured"] as? Bool != true { health = .missingKey }
            else if let registered, !registered.contains(route) { health = .inactive }
            else { health = .ready }
            let name = (profile["displayName"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? route
            return Self(id: route, name: name, api: profile["api"] as? String,
                        models: (profile["models"] as? [Any])?.count ?? 0, health: health)
        }
    }
}

struct HostChannelForm: View {
    let host: Harness
    /// The route being edited; nil for a new channel.
    let route: String?
    var conversation: Conversation? = nil
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum KeyMode: Hashable { case keep, replace }

    @State private var schema = ChannelSchema(nil)
    @State private var revision: Int?
    @State private var writable = false
    @State private var loaded = false
    @State private var original: Object = [:]
    @State private var inUserLayer = false
    @State private var inBase = false
    @State private var keyConfigured = false
    @State private var savedRoute: String?

    @State private var name = ""
    @State private var api = ""
    @State private var baseURL = ""
    @State private var models = ""
    @State private var keyMode = KeyMode.keep
    @State private var key = ""

    @State private var makeDefault = false
    @State private var defaultModel = ""
    @State private var saving = false
    @State private var issue: String?
    @State private var notice: String?
    @State private var catalogCount: Int?
    @State private var deleting = false

    private var editingRoute: String? { route ?? savedRoute }
    private var creating: Bool { editingRoute == nil }
    private static let namespace = HostModelService.namespace

    var body: some View {
        Form {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                if !writable { Section { Text("这台设备的模型设置是只读的。").foregroundStyle(ChatColors.muted) } }
                Section("模型服务") {
                    if schema.fields.contains("displayName") {
                        TextField("名称", text: $name).accessibilityIdentifier("channelName")
                    }
                    if !schema.apis.isEmpty {
                        Picker("接口协议", selection: $api) {
                            ForEach(schema.apis, id: \.self) { Text(Self.apiLabel($0)).tag($0) }
                        }.accessibilityIdentifier("channelApi")
                    }
                    if schema.fields.contains("baseURL") {
                        TextField("服务地址（https://…）", text: $baseURL).urlKeyboard().accessibilityIdentifier("channelBaseURL")
                    }
                }
                if schema.fields.contains("models") {
                    Section {
                        TextField("每行一个模型 ID，可写成「ID | 显示名」", text: $models, axis: .vertical).lineLimit(2...8)
                            .font(.callout.monospaced()).accessibilityIdentifier("channelModels")
                    } header: { Text("模型") }
                }
                Section {
                    if creating {
                        SecureField("API Key", text: $key).accessibilityIdentifier("channelKey")
                    } else {
                        LabeledContent("当前 API Key", value: keyConfigured ? String(localized: "已保存") : String(localized: "未配置"))
                        Picker("API Key", selection: $keyMode) {
                            Text("保留原 API Key").tag(KeyMode.keep)
                            Text("替换 API Key").tag(KeyMode.replace)
                        }.pickerStyle(.segmented).accessibilityIdentifier("channelKeyMode")
                        if keyMode == .replace { SecureField("新的 API Key", text: $key).accessibilityIdentifier("channelKey") }
                    }
                } header: { Text("API Key") }
                if conversation != nil {
                    Section {
                        Toggle("设为默认模型", isOn: $makeDefault)
                        Picker("默认模型", selection: $defaultModel) {
                            Text("选择模型").tag("")
                            ForEach(modelRows, id: \.id) { row in Text(row.name ?? row.id).tag(row.id) }
                        }
                    }
                }
                Section {
                    Button(saving ? "正在保存…" : creating ? "添加模型服务" : "保存") { save() }
                        .disabled(saving || !writable || !valid || (makeDefault && !modelRows.contains { $0.id == defaultModel })).accessibilityIdentifier("channelSave")
                    if !creating, inUserLayer, !inBase {
                        Button("删除模型服务", role: .destructive) { deleting = true }.disabled(saving || !writable)
                    }
                }
                if let notice { Section { Text(notice).accessibilityIdentifier("channelNotice") } }
                if let issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("channelIssue") } }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(creating ? "添加模型服务" : "编辑模型服务").inlineNavigationTitle()
        .autocorrectionDisabled().noAutomaticCapitalization()
        .task { await load(fill: true) }
        .confirmationDialog("删除这个模型服务？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) { remove() }
        } message: { Text("模型服务和它的 API Key 都会删除。") }
    }

    private var modelRows: [(id: String, name: String?)] {
        models.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let id = parts.first, !id.isEmpty else { return nil }
            return (id, parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
        }
    }

    private var valid: Bool {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces))
        let urlOK = !schema.fields.contains("baseURL") || (url?.host != nil && ["https", "http"].contains(url?.scheme ?? ""))
        let keyOK = creating ? !key.isEmpty : keyMode == .keep || !key.isEmpty
        return urlOK && keyOK && (!schema.fields.contains("models") || !modelRows.isEmpty)
            && (!schema.fields.contains("displayName") || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private static func apiLabel(_ api: String) -> String {
        switch api {
        case "openai-completions": String(localized: "OpenAI 兼容（Chat Completions）")
        case "openai-responses": "OpenAI Responses"
        case "anthropic-messages": String(localized: "Anthropic 兼容（Messages）")
        default: api
        }
    }

    // MARK: Reading

    /// Reads the namespace; `fill` replaces the draft with the host's channel (not after a refused save).
    private func load(fill: Bool) async {
        do {
            let described = try await host.rpc("settings/describe", args: [:])
            guard let section = (described["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == Self.namespace }) else {
                issue = String(localized: "这台设备不支持添加模型服务。"); loaded = true; return
            }
            writable = described["writable"] as? Bool == true
            schema = ChannelSchema(section["schema"] as? Object)
            revision = section["revision"] as? Int
            if let editingRoute {
                let profile = (((section["value"] as? Object)?["providers"] as? Object)?[editingRoute] as? Object) ?? [:]
                original = profile
                inUserLayer = ((section["user"] as? Object)?["providers"] as? Object)?[editingRoute] != nil
                inBase = ((section["base"] as? Object)?["providers"] as? Object)?[editingRoute] != nil
                if let ref = profile["apiKeyEnv"] as? String, !ref.isEmpty,
                   let creds = try? await host.rpc("credentials/describe", args: ["refs": [ref]]) {
                    keyConfigured = (creds[ref] as? Object)?["configured"] as? Bool == true
                } else { keyConfigured = false }
                if fill {
                    name = profile["displayName"] as? String ?? ""
                    api = profile["api"] as? String ?? schema.apis.first ?? ""
                    baseURL = profile["baseURL"] as? String ?? ""
                    models = (profile["models"] as? [Object] ?? []).compactMap { model in
                        guard let id = model["id"] as? String else { return nil }
                        return (model["name"] as? String).map { id + " | " + $0 } ?? id
                    }.joined(separator: "\n")
                }
            } else if fill, api.isEmpty {
                api = schema.apis.first(where: { $0 == "openai-completions" }) ?? schema.apis.first ?? ""
            }
            loaded = true
        } catch {
            loaded = true
            issue = String(localized: "没能读取模型服务：") + HostError.explain(error)
        }
    }

    /// `custom-<slug>`, `-2`, `-3`… until free.
    private func newRoute(_ taken: Set<String>) -> String {
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let stem = "custom-" + (slug.isEmpty ? "channel" : String(slug.prefix(32)))
        var candidate = stem, n = 2
        while taken.contains(candidate) { candidate = stem + "-\(n)"; n += 1 }
        return candidate
    }

    private static func keyRef(_ route: String) -> String {
        route.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + "_API_KEY"
    }

    private func modelValues() -> [Object] {
        let existing = Dictionary((original["models"] as? [Object] ?? []).compactMap { m in (m["id"] as? String).map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        return modelRows.map { row in
            var model = existing[row.id] ?? [:]
            model["id"] = row.id
            if let name = row.name, schema.modelFields.isEmpty || schema.modelFields.contains("name") { model["name"] = name } else { model.removeValue(forKey: "name") }
            return model
        }
    }

    // MARK: Writing

    private func save() {
        guard let revision else { return }
        saving = true; issue = nil; notice = nil
        Task {
            defer { saving = false }
            var stage = "settings"
            do {
                if let route = editingRoute {
                    var ops: [Object] = []
                    func set(_ field: String, _ value: Any, changed: Bool) {
                        if changed, schema.fields.contains(field) { ops.append(["op": "set", "path": ["providers", route, field], "value": value]) }
                    }
                    let trimmedName = name.trimmingCharacters(in: .whitespaces), trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
                    set("displayName", trimmedName, changed: trimmedName != original["displayName"] as? String ?? "")
                    set("api", api, changed: api != original["api"] as? String ?? "")
                    set("baseURL", trimmedURL, changed: trimmedURL != original["baseURL"] as? String ?? "")
                    let values = modelValues()
                    set("models", values, changed: !((original["models"] as? NSArray)?.isEqual(to: values) ?? false))
                    var ref = original["apiKeyEnv"] as? String
                    if keyMode == .replace, ref?.isEmpty ?? true {
                        ref = Self.keyRef(route)
                        ops.append(["op": "set", "path": ["providers", route, "apiKeyEnv"], "value": ref!])
                    }
                    if !ops.isEmpty {
                        _ = try await host.rpcValue("settings/mutate", args: ["ns": Self.namespace, "ops": ops, "expectedRevision": revision])
                    }
                    if keyMode == .replace, let ref {
                        stage = "key"
                        _ = try await host.rpcValue("credentials/set", args: ["ref": ref, "value": key])
                    }
                    if ops.isEmpty && keyMode == .keep && conversation == nil { notice = String(localized: "没有改动。"); return }
                } else {
                    let described = try await host.rpc("settings/describe", args: [:])
                    let section = (described["namespaces"] as? [Object])?.first { $0["ns"] as? String == Self.namespace }
                    let taken = Set((((section?["value"] as? Object)?["providers"] as? Object) ?? [:]).keys)
                    let route = newRoute(taken)
                    let ref = Self.keyRef(route)
                    var profile: Object = ["apiKeyEnv": ref, "models": modelValues()]
                    if schema.fields.contains("displayName") { profile["displayName"] = name.trimmingCharacters(in: .whitespaces) }
                    if schema.fields.contains("api"), !api.isEmpty { profile["api"] = api }
                    if schema.fields.contains("baseURL") { profile["baseURL"] = baseURL.trimmingCharacters(in: .whitespaces) }
                    _ = try await host.rpcValue("settings/mutate", args: ["ns": Self.namespace, "expectedRevision": revision,
                                                                          "ops": [["op": "set", "path": ["providers", route], "value": profile]]])
                    savedRoute = route
                    stage = "key"
                    _ = try await host.rpcValue("credentials/set", args: ["ref": ref, "value": key])
                }
                key = ""; keyMode = .keep
                await load(fill: true)
                await readCatalog()
                notice = String(localized: "已保存") + (catalogCount.map { String(localized: "，这个模型服务现有 \($0) 个可选模型。") } ?? String(localized: "。"))
                if let conversation, let route = editingRoute, let model = modelRows.first(where: { $0.id == defaultModel }) ?? modelRows.first {
                    stage = "activation"
                    try await conversation.activateConfiguredModel(on: host, provider: route, model: model.id, explicit: makeDefault)
                }
                saved()
                if let conversation { await conversation.refreshModelCatalog(on: host) }
            } catch let error as HostError where error.code == "settings/conflict" {
                await load(fill: false)
                issue = String(localized: "这个模型服务刚在别处被改过。你的修改还在，核对最新内容后再保存。")
            } catch {
                if stage == "activation" {
                    saved()
                    issue = String(localized: "接入已保存，但默认模型未完全生效：") + HostError.explain(error)
                } else if stage == "key" {
                    await load(fill: false)
                    issue = String(localized: "模型服务已保存，但 API Key 没有存上：") + HostError.explain(error) + String(localized: "\n再点一次保存只会重试 API Key。")
                    keyMode = .replace
                } else {
                    issue = String(localized: "没能保存：") + HostError.explain(error) + String(localized: "\n草稿已保留。")
                }
            }
        }
    }

    private func readCatalog() async {
        guard let route = editingRoute, let catalog = try? await host.rpc("session/modelCatalog", args: [:]) else { catalogCount = nil; return }
        catalogCount = HostModelCatalog(catalog).channels.first { $0.id == route }?.models.count ?? 0
    }

    private func remove() {
        guard let route = editingRoute, let revision else { return }
        saving = true; issue = nil
        Task {
            defer { saving = false }
            do {
                _ = try await host.rpcValue("settings/mutate", args: ["ns": Self.namespace, "expectedRevision": revision,
                                                                      "ops": [["op": "unset", "path": ["providers", route]]]])
                if let ref = original["apiKeyEnv"] as? String, !ref.isEmpty { _ = try? await host.rpcValue("credentials/unset", args: ["ref": ref]) }
                saved()
                dismiss()
            } catch let error as HostError where error.code == "settings/conflict" {
                await load(fill: false)
                issue = String(localized: "这个模型服务刚在别处被改过，已重新读取。核对后再删除。")
            } catch { issue = String(localized: "没能删除：") + HostError.explain(error) }
        }
    }
}
