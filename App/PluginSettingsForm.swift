// 插件设置：按主机给的 schema 生成表单。
//
// 数据来自 `settings/describe` 里与插件条目同名的 namespace（本机引擎和远程主机都有，只含
// live 字段），写回用 `settings/mutate {ns, ops, expectedRevision}`，保存后以主机回的 namespace
// 为准重新显示。schema 是 schemastery 的 JSON（`{uid, refs}`）：布尔 → 开关，数字 → 数值，
// 字符串 → 文本，全由常量组成的 union → 单选，`role: secret` → 密钥（只写不读）。其余类型只读。
// 改回继承值时发 `unset`。主机覆盖层（value 与 base+user 不同）锁住对应字段。

import SwiftUI

struct ConfigField: Identifiable {
    enum Kind {
        case toggle
        case number(min: Double?, max: Double?, step: Double?)
        case text(multiline: Bool)
        case choice([(value: AnyHashable, label: String)])
        case secret
        case readOnly
    }
    let key: String
    let title: String
    let detail: String?
    let kind: Kind
    let fallback: Any?
    var id: String { key }
}

enum ConfigSchema {
    /// The fields of an object schema, in declaration order (schemastery numbers refs as it builds them).
    static func fields(_ schema: Object?) -> [ConfigField] {
        guard let schema, let refs = schema["refs"] as? Object else { return [] }
        let uid = (schema["uid"] as? NSNumber)?.stringValue ?? (schema["uid"] as? String) ?? ""
        func node(_ id: Any?) -> Object? {
            let key = (id as? NSNumber)?.stringValue ?? (id as? String) ?? ""
            return refs[key] as? Object
        }
        guard var root = node(uid) else { return [] }
        while root["type"] as? String == "transform", let inner = node(root["inner"]) { root = inner }
        guard root["type"] as? String == "object", let dict = root["dict"] as? Object else { return [] }
        let ordered = dict.sorted { (($0.value as? NSNumber)?.intValue ?? 0) < (($1.value as? NSNumber)?.intValue ?? 0) }
        return ordered.compactMap { key, ref in
            guard var field = node(ref) else { return nil }
            while field["type"] as? String == "transform", let inner = node(field["inner"]) { field = inner }
            let meta = field["meta"] as? Object ?? [:]
            if meta["hidden"] as? Bool == true || meta["role"] as? String == "credential-ref" { return nil }
            let described = HostPanelFormat.localized(meta["description"])
            let title = HostPanelFormat.localized(meta["title"]) ?? described ?? key
            let detail = HostPanelFormat.localized(meta["title"]) != nil ? described : nil
            let kind: ConfigField.Kind
            let options = (field["list"] as? [Any] ?? []).compactMap(node)
            switch field["type"] as? String {
            case _ where meta["role"] as? String == "secret": kind = .secret
            case "union" where options.contains { ($0["meta"] as? Object)?["role"] as? String == "secret" }: kind = .secret
            case "boolean": kind = .toggle
            case "number": kind = .number(min: (meta["min"] as? NSNumber)?.doubleValue, max: (meta["max"] as? NSNumber)?.doubleValue,
                                          step: (meta["step"] as? NSNumber)?.doubleValue)
            case "string": kind = .text(multiline: meta["role"] as? String == "textarea")
            case "union" where !options.isEmpty && options.allSatisfy({ $0["type"] as? String == "const" }):
                kind = .choice(options.compactMap { option in
                    guard let value = option["value"] as? AnyHashable else { return nil }
                    let label = HostPanelFormat.localized((option["meta"] as? Object)?["description"]) ?? "\(value)"
                    return (value, label)
                })
            default: kind = .readOnly
            }
            return ConfigField(key: key, title: title, detail: detail, kind: kind, fallback: meta["default"])
        }
    }
}

/// App-side wording for a namespace whose schema only has English keys (like `cot-translation`).
struct ConfigCopy {
    var title: String
    var detail: String? = nil
    var options: [String: String] = [:]
    /// Option values the host can use right now; the others stay selectable but say so.
    var offered: Set<String>? = nil
}

extension ConfigSchema {
    static func relabel(_ fields: [ConfigField], copy: [String: ConfigCopy]) -> [ConfigField] {
        fields.map { field in
            guard let words = copy[field.key] else { return field }
            var kind = field.kind
            if case .choice(let options) = field.kind {
                kind = .choice(options.map { option in
                    let value = "\(option.value.base)"
                    let label = words.options[value] ?? option.label
                    return (option.value, words.offered.map { $0.contains(value) } ?? true ? label : label + String(localized: "（这台设备暂不可用）"))
                })
            }
            return ConfigField(key: field.key, title: words.title, detail: words.detail ?? field.detail, kind: kind, fallback: field.fallback)
        }
    }

    /// The fields a `settings/rejected` message names (`… (at targetLanguage)`).
    static func rejectedKeys(_ message: String?) -> [String] {
        guard let message else { return [] }
        var keys: [String] = []
        for match in message.matches(of: /\(at ([A-Za-z0-9_.-]+)\)/) {
            let key = String(match.1).split(separator: ".").first.map(String.init) ?? ""
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }
}

/// One namespace as `settings/describe` serves it.
struct ConfigDocument {
    let ns: String
    let schema: Object?
    let value: Object
    let base: Object
    let user: Object
    let revision: Int?
    let writable: Bool
    let secrets: [String: Bool]

    init(section: Object, writable: Bool) {
        ns = section["ns"] as? String ?? ""
        schema = section["schema"] as? Object
        value = section["value"] as? Object ?? [:]
        base = section["base"] as? Object ?? [:]
        user = section["user"] as? Object ?? [:]
        revision = section["revision"] as? Int
        self.writable = writable
        var secrets: [String: Bool] = [:]
        for item in section["secrets"] as? [Object] ?? [] {
            if let path = item["path"] as? [String], let key = path.first, path.count == 1 {
                secrets[key] = item["set"] as? Bool ?? item["configured"] as? Bool ?? false
            }
        }
        self.secrets = secrets
    }

    /// A field a host overlay sets: what is in force differs from the base and user layers.
    func locked(_ key: String) -> Bool {
        guard let live = value[key] else { return false }
        let layered = user[key] ?? base[key]
        return layered.map { !(($0 as? NSObject)?.isEqual(live) ?? false) } ?? false
    }

    static func read(_ host: Harness, ns: String) async throws -> Self? {
        let described = try await host.rpc("settings/describe", args: [:])
        guard let section = (described["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == ns }) else { return nil }
        return Self(section: section, writable: described["writable"] as? Bool == true)
    }

    /// The namespaces of `names` that have at least one field the form can show.
    static func configurable(_ host: Harness, among names: [String]) async -> [String] {
        guard let described = try? await host.rpc("settings/describe", args: [:]) else { return [] }
        let sections = described["namespaces"] as? [Object] ?? []
        return names.filter { name in
            sections.contains { $0["ns"] as? String == name && !ConfigSchema.fields($0["schema"] as? Object).isEmpty }
        }
    }
}

/// The form for one settings namespace; plugins, 思考过程翻译 and other plugin-owned settings share it.
struct PluginSettingsForm: View {
    let host: Harness
    let ns: String
    var title: String? = nil
    var copy: [String: ConfigCopy] = [:]
    @State private var document: ConfigDocument?
    @State private var fields: [ConfigField] = []
    @State private var draft: [String: Any] = [:]
    @State private var secretDraft: [String: String] = [:]
    @State private var missing = false
    @State private var issue: String?
    @State private var notice: String?
    @State private var saving = false

    private var editable: Bool { document?.writable == true && document?.revision != nil && !saving }
    private var changed: Bool { !pendingOps().isEmpty }
    private var shown: [ConfigField] { ConfigSchema.relabel(fields, copy: copy) }

    var body: some View {
        Form {
            if let document {
                if !document.writable {
                    Section { Text("这台设备的设置是只读的。").foregroundStyle(ChatColors.muted) }
                }
                Section {
                    ForEach(shown) { field in row(field, document) }
                }
                Section {
                    Button(saving ? "正在保存…" : "保存") { save() }.disabled(!editable || !changed)
                        .accessibilityIdentifier("pluginSettingsSave")
                    if changed { Button("放弃修改", role: .destructive) { draft = [:]; secretDraft = [:]; issue = nil } }
                }
                if let notice { Section { Text(notice).accessibilityIdentifier("pluginSettingsNotice") } }
                if let issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("pluginSettingsIssue") } }
            } else if missing {
                OfflineMessage(symbol: "slider.horizontal.3", title: String(localized: "没有可修改的设置"), detail: String(localized: "这台设备没有提供「\(ns)」的设置，或插件未启用。"))
            } else if let issue {
                OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取设置"), detail: issue) { Task { await load() } }
            } else { ProgressView().frame(maxWidth: .infinity) }
        }
        .navigationTitle(title ?? ns).inlineNavigationTitle()
        .task { await load() }
        .refreshable { await load() }
        .autocorrectionDisabled().noAutomaticCapitalization()
    }

    @ViewBuilder private func row(_ field: ConfigField, _ document: ConfigDocument) -> some View {
        let locked = document.locked(field.key)
        let enabled = editable && !locked
        let current = draft[field.key] ?? document.value[field.key] ?? field.fallback
        VStack(alignment: .leading, spacing: 4) {
            switch field.kind {
            case .toggle:
                Toggle(field.title, isOn: Binding(get: { current as? Bool ?? false }, set: { draft[field.key] = $0 })).disabled(!enabled)
            case .number(let low, let high, let step):
                LabeledContent(field.title) {
                    TextField("数值", text: Binding(get: { Self.number(current) }, set: { draft[field.key] = Double($0).map { Self.fit($0, step) } ?? $0 }))
                        .decimalKeyboard().multilineTextAlignment(.trailing).disabled(!enabled)
                }
                if low != nil || high != nil {
                    Text([String(localized: "范围"), low.map { Self.number($0) }, "–", high.map { Self.number($0) }].compactMap { $0 }.joined(separator: " "))
                        .font(.caption).foregroundStyle(ChatColors.muted)
                }
            case .text(let multiline):
                Text(field.title).font(.subheadline)
                TextField(field.title, text: Binding(get: { current as? String ?? "" }, set: { draft[field.key] = $0 }), axis: multiline ? .vertical : .horizontal)
                    .disabled(!enabled).accessibilityIdentifier("pluginSetting-" + field.key)
            case .choice(let options):
                Picker(field.title, selection: Binding<AnyHashable>(get: { (current as? AnyHashable) ?? options.first?.value ?? AnyHashable("") }, set: { draft[field.key] = $0.base })) {
                    ForEach(options.indices, id: \.self) { index in Text(options[index].label).tag(options[index].value) }
                }.disabled(!enabled).accessibilityIdentifier("pluginSetting-" + field.key)
            case .secret:
                LabeledContent(field.title, value: document.secrets[field.key] == true ? String(localized: "已配置") : String(localized: "未配置"))
                SecureField("输入新密钥以替换", text: Binding(get: { secretDraft[field.key] ?? "" }, set: { secretDraft[field.key] = $0 }))
                    .disabled(!enabled).accessibilityIdentifier("pluginSecret-" + field.key)
                if document.secrets[field.key] == true, enabled {
                    Button("清除已保存的密钥", role: .destructive) { secretDraft[field.key] = "\u{0}" }
                }
            case .readOnly:
                LabeledContent(field.title, value: Self.summary(current))
            }
            if let detail = field.detail { Text(detail).font(.caption).foregroundStyle(ChatColors.muted) }
            if locked { Text("已被这台设备固定，这里改不了").font(.caption).foregroundStyle(SettingsStyle.warning) }
        }
    }

    private static func number(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return value.map { "\($0)" } ?? "" }
        let double = number.doubleValue
        return double == double.rounded() ? String(Int(double)) : String(double)
    }

    private static func fit(_ value: Double, _ step: Double?) -> Any { step == 1 ? Int(value) as Any : value as Any }

    private static func summary(_ value: Any?) -> String {
        guard let value else { return String(localized: "默认") }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) { return String(decoding: data, as: UTF8.self) }
        return "—"
    }

    /// The edits as `settings/mutate` ops: `unset` when a value goes back to what it inherits.
    private func pendingOps() -> [Object] {
        guard let document else { return [] }
        var ops: [Object] = []
        for field in fields {
            if case .secret = field.kind {
                guard let typed = secretDraft[field.key], !typed.isEmpty else { continue }
                ops.append(typed == "\u{0}" ? ["op": "unset", "path": [field.key]] : ["op": "set", "path": [field.key], "value": typed])
                continue
            }
            guard var value = draft[field.key] else { continue }
            if case .number = field.kind, let text = value as? String { guard let parsed = Double(text) else { continue }; value = parsed }
            let shown = document.value[field.key] ?? field.fallback
            if let shown, (shown as? NSObject)?.isEqual(value) == true { continue }
            let inherited = document.base[field.key] ?? field.fallback
            if let inherited, (inherited as? NSObject)?.isEqual(value) == true, document.user[field.key] != nil {
                ops.append(["op": "unset", "path": [field.key]])
            } else { ops.append(["op": "set", "path": [field.key], "value": value]) }
        }
        return ops
    }

    private static var readFailure: String { String(localized: "没能读取设置：") }

    private func load() async {
        do {
            guard let read = try await ConfigDocument.read(host, ns: ns) else { missing = true; document = nil; return }
            missing = false
            document = read
            fields = ConfigSchema.fields(read.schema)
            if fields.isEmpty { missing = true; document = nil }
            if issue?.hasPrefix(Self.readFailure) == true { issue = nil }
        } catch { if !Task.isCancelled { issue = Self.readFailure + HostError.explain(error) } }
    }

    private func save() {
        guard let document, let revision = document.revision else { return }
        let ops = pendingOps()
        guard !ops.isEmpty else { return }
        saving = true; issue = nil; notice = nil
        Task {
            defer { saving = false }
            do {
                let section = try await host.rpc("settings/mutate", args: ["ns": ns, "ops": ops, "expectedRevision": revision])
                let saved = ConfigDocument(section: section, writable: document.writable)
                self.document = saved
                fields = ConfigSchema.fields(saved.schema ?? document.schema)
                // Only the edits the host now reports drop out of the draft; anything else stays for another try.
                let unconfirmed = draft.filter { key, value in !(((saved.value[key] ?? saved.base[key]) as? NSObject)?.isEqual(value) ?? false) }.map(\.key)
                draft = draft.filter { unconfirmed.contains($0.key) }
                secretDraft = [:]
                await load()
                notice = unconfirmed.isEmpty ? String(localized: "已保存。") : String(localized: "这几项没有存上：") + unconfirmed.joined(separator: String(localized: "、"))
            } catch let error as HostError where error.code == "settings/conflict" {
                await load()
                issue = String(localized: "设置已在别处改变，已重新读取。你的修改还在，请核对后再保存。")
            } catch let error as HostError where error.code == "settings/rejected" {
                let named = ConfigSchema.rejectedKeys(error.detail).map { key in shown.first { $0.key == key }?.title ?? key }
                issue = named.isEmpty ? String(localized: "没能保存。") + (error.detail.map { "\n" + $0 } ?? "")
                    : String(localized: "没能保存：「") + named.joined(separator: String(localized: "」「")) + String(localized: "」的值不符合要求，修改还在，请改正后再保存。")
            } catch {
                issue = String(localized: "没能保存：") + HostError.explain(error)
            }
        }
    }
}

/// 设置 rows for an installed bundle: one per bundle row that has a settings namespace with fields.
struct PluginSettingsLinks: View {
    let host: Harness
    let bundle: HostPluginBundle
    @State private var namespaces: [String] = []
    @State private var loaded = false

    private var rowIDs: [String] { (bundle.raw["rows"] as? [Object] ?? []).compactMap { $0["rowId"] as? String } }

    var body: some View {
        Group {
            // The lookup hangs off a row that is always there first: an empty section never runs a task.
            if !loaded {
                Label(String(localized: "正在读取插件设置…"), systemImage: "slider.horizontal.3").foregroundStyle(ChatColors.muted)
                    .task {
                        namespaces = bundle.enabled ? await ConfigDocument.configurable(host, among: rowIDs.isEmpty ? [bundle.name] : rowIDs) : []
                        loaded = true
                    }
            }
            ForEach(namespaces, id: \.self) { ns in
                NavigationLink { PluginSettingsForm(host: host, ns: ns, title: namespaces.count == 1 ? bundle.title + String(localized: " 设置") : ns) } label: {
                    Label(namespaces.count == 1 ? String(localized: "插件设置") : String(localized: "设置 · ") + ns, systemImage: "slider.horizontal.3")
                }.accessibilityIdentifier("pluginSettings-" + ns)
            }
        }
    }
}
