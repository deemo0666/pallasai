import Compression
import CryptoKit
import Foundation

// 分享配置: a host's settings as a profile share code. The body is compact JSON
//   {"v":1,"kind":"profile","name":…,"created":…,"settings":{ns:{field:value}}}
// compressed with raw DEFLATE, base64url without padding, then "." and the
// first 6 bytes of SHA-256 over the JSON, base64url: `<data>.<sum>`. A `.dshlocal`
// file wraps the code in {"dshlocal":1,"kind":"profile","name":…,"code":…}.
// Only each namespace's user layer travels, cleaned of anything that is or
// looks like a credential, an account, telemetry or a local path.

enum ShareCodec {
    static let version = 1
    static let maxBodyBytes = 1024 * 1024
    static let maxCodeCharacters = 1024 * 1024

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func unbase64URL(_ text: String) throws -> Data {
        guard text.range(of: #"^[A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { throw HostError(String(localized: "分享码损坏（不是 base64url）")) }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard) else { throw HostError(String(localized: "分享码损坏（不是 base64url）")) }
        return data
    }

    static func checksum(_ body: Data) -> String { base64URL(Data(SHA256.hash(data: body).prefix(6))) }

    static func encode(_ json: Object) throws -> String {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes, .sortedKeys])
        guard let deflated = try? (body as NSData).compressed(using: .zlib) as Data else { throw HostError(String(localized: "没能压缩配置")) }
        return base64URL(deflated) + "." + checksum(body)
    }

    static func decode(_ code: String) throws -> Object {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxCodeCharacters else { throw HostError(String(localized: "分享码为空或太长")) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { throw HostError(String(localized: "分享码损坏（缺少校验）")) }
        let body = try inflate(try unbase64URL(String(parts[0])), limit: maxBodyBytes)
        guard checksum(body) == parts[1] else { throw HostError(String(localized: "分享码损坏（校验不符）")) }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? Object else { throw HostError(String(localized: "分享码的内容不是配置")) }
        return json
    }

    /// Raw DEFLATE, refusing output larger than [limit] (a zip-bomb guard).
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw HostError(String(localized: "没能解压分享码")) }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw HostError(String(localized: "分享码为空")) }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = data.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: chunk - stream.pointee.dst_size)
                guard output.count <= limit else { throw HostError(String(localized: "分享码内容太大")) }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK: continue
                default: throw HostError(String(localized: "分享码损坏（解压失败）"))
                }
            }
        }
    }

    /// A `.dshlocal` file's text for [payload].
    static func file(_ payload: Object, name: String?) throws -> String {
        var envelope: Object = ["dshlocal": version, "kind": payload["kind"] as? String ?? "profile", "code": try encode(payload)]
        if let name, !name.isEmpty { envelope["name"] = name }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The code inside whatever was pasted or opened: a bare code, a `.dshlocal`
    /// file, `dshlocal://share/profile?p=…`, or a landing link with `#p=…`.
    static func code(in text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? Object,
                  json["dshlocal"] is Int, let code = json["code"] as? String else { throw HostError(String(localized: "不是 Pallas Agent 分享文件")) }
            return code
        }
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            if components.queryItems?.contains(where: { $0.name == "gist" }) == true || components.fragment?.contains("gist=") == true {
                throw HostError(String(localized: "这个链接把配置放在 GitHub Gist 上，本 App 不读取外部存放的配置；请让对方导出 .dshlocal 文件"))
            }
            if let code = components.queryItems?.first(where: { $0.name == "p" })?.value { return code }
            if let fragment = components.fragment, let range = fragment.range(of: "p=") {
                return String(fragment[range.upperBound...].prefix { $0 != "&" })
            }
            throw HostError(String(localized: "链接里没有分享码"))
        }
        return trimmed
    }
}

// MARK: - What may leave the device

enum SettingsSanitizer {
    /// Namespaces bound to an account, a machine or telemetry: never offered.
    static func shareableNamespace(_ ns: String) -> Bool {
        ns.range(of: "account|credential|telemetry|analytics|anonymous|remote-access|remotes|webserver|gateway|otel|login|auth",
                 options: [.regularExpression, .caseInsensitive]) == nil
            && ns.range(of: #"^[A-Za-z0-9._:@/-]{1,80}$"#, options: .regularExpression) != nil
    }

    private static let secretWords: Set<String> = ["token", "secret", "password", "passwd", "passphrase", "cookie", "authorization", "apikey"]
    private static let keyQualifiers: Set<String> = ["api", "private", "secret", "access", "client", "session", "signing", "license"]

    /// `accessToken`, `client_secret`, `X-Api-Key`, `apiKey` hold secrets; `maxTokens`, `apiKeyEnv`, `keyId` don't.
    static func secretFieldName(_ key: String) -> Bool {
        let spaced = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        let words = spaced.components(separatedBy: CharacterSet(charactersIn: " _-.").union(.whitespaces)).filter { !$0.isEmpty }.map { $0.lowercased() }
        guard let last = words.last else { return false }
        if secretWords.contains(last) { return true }
        if last == "key" { return words.count == 1 || keyQualifiers.contains(words[words.count - 2]) }
        return false
    }

    /// Recognizable credentials: provider keys, tokens, private keys, JWTs, `key=value` pairs.
    private static let secretPatterns = [
        #"\bsk-[A-Za-z0-9_-]{16,}"#, #"\bsk-ant-[A-Za-z0-9_-]{16,}"#, #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bglpat-[A-Za-z0-9_-]{16,}"#, #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, #"\bAKIA[0-9A-Z]{16}\b"#, #"\bAIza[0-9A-Za-z_-]{35}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"(?i)\b(api[_-]?key|secret|token|password)\s*[:=]\s*["']?[^\s"']{8,}"#,
    ]

    static func containsSecret(_ text: String) -> Bool {
        secretPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static func absolutePath(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^(/|~/|~$|[A-Za-z]:[\\/]|\\\\|file:)"#, options: .regularExpression) != nil
    }

    /// A string value that must not be shared.
    static func unshareable(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if absolutePath(text) || containsSecret(text) { return true }
        if text.range(of: #"^(?i)bearer\s"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"^[A-Za-z0-9+/_=.-]{40,}$"#, options: .regularExpression) != nil,
           text.rangeOfCharacter(from: .decimalDigits) != nil, text.rangeOfCharacter(from: .letters) != nil, !text.contains(".") { return true }
        if let url = URLComponents(string: text), url.scheme != nil, let host = url.host, !host.isEmpty {
            if url.user != nil || url.password != nil { return true }
            if url.queryItems?.contains(where: { $0.name.range(of: "^(token|key|secret|sig|signature|password|access_token|auth|api_key|apikey)$",
                                                                options: [.regularExpression, .caseInsensitive]) != nil }) == true { return true }
        }
        return false
    }

    /// One namespace of `settings/describe`, cleaned: its user layer without
    /// secret fields, schema secrets, credential-like strings and local paths
    /// (credential *references* stay). Nil when the namespace is never shared.
    static func clean(_ section: Object) -> (values: Object, dropped: Int)? {
        guard let ns = section["ns"] as? String, shareableNamespace(ns) else { return nil }
        guard let user = section["user"] as? Object, !user.isEmpty else { return ([:], 0) }
        let schema = section["schema"] as? Object ?? [:]
        let refs = schema["refs"] as? Object ?? [:]
        let secretPaths = Set((section["secrets"] as? [Object] ?? []).compactMap { ($0["path"] as? [Any])?.map { "\($0)" }.joined(separator: "\u{0}") })
        var dropped = 0

        func node(_ ref: Any?) -> Object? {
            guard let id = ref as? Int, var node = refs[String(id)] as? Object else { return nil }
            // A transform or intersect wraps the node that describes the value.
            var hops = 0
            while hops < 4, ["transform"].contains(node["type"] as? String ?? ""), let inner = node["inner"] as? Int, let next = refs[String(inner)] as? Object {
                let meta = node["meta"]; node = next; if node["meta"] == nil { node["meta"] = meta }; hops += 1
            }
            return node
        }
        func role(_ node: Object?) -> String? { (node?["meta"] as? Object)?["role"] as? String }

        func scrub(_ value: Any, _ schema: Object?, _ path: [String], _ key: String?) -> Any? {
            if role(schema) == "secret" || secretPaths.contains(path.joined(separator: "\u{0}")) { return nil }
            let isRef = role(schema) == "credential-ref"
            if let key, !isRef, secretFieldName(key) { return nil }
            switch value {
            case let text as String:
                return unshareable(text) ? nil : text
            case let map as Object:
                var out: Object = [:]
                var removed = 0
                for (childKey, childValue) in map {
                    let fields = schema?["dict"] as? Object
                    let childSchema = node(fields?[childKey]) ?? (schema?["type"] as? String == "dict" ? node(schema?["inner"]) : nil)
                    if let cleaned = scrub(childValue, childSchema, path + [childKey], childKey) { out[childKey] = cleaned }
                    else { removed += 1; dropped += 1 }
                }
                return out.isEmpty && removed > 0 ? nil : out
            case let list as [Any]:
                var out: [Any] = []
                for (index, item) in list.enumerated() {
                    if let cleaned = scrub(item, node(schema?["inner"]), path + [String(index)], nil) { out.append(cleaned) } else { dropped += 1 }
                }
                return out.isEmpty && !list.isEmpty ? nil : out
            default:
                return value
            }
        }

        let root = (schema["uid"] as? Int).flatMap { refs[String($0)] as? Object }
        if root == nil { return (scrubbed(user).values, scrubbed(user).dropped.count) }
        let fields = root?["dict"] as? Object
        var values: Object = [:]
        for (key, value) in user {
            if let cleaned = scrub(value, node(fields?[key]), [key], key) { values[key] = cleaned } else { dropped += 1 }
        }
        return (values, dropped)
    }
}

extension SettingsSanitizer {
    /// Incoming values without a schema (an imported share): the same name and
    /// value rules, so a share never writes a credential-looking value to a host.
    static func scrubbed(_ values: Object) -> (values: Object, dropped: [String]) {
        var dropped: [String] = []
        func scrub(_ value: Any, _ path: [String], _ key: String?) -> Any? {
            if let key, secretFieldName(key) { dropped.append(path.joined(separator: ".")); return nil }
            switch value {
            case let text as String:
                if unshareable(text) { dropped.append(path.joined(separator: ".")); return nil }
                return text
            case let map as Object:
                var out: Object = [:]
                for (k, v) in map { if let cleaned = scrub(v, path + [k], k) { out[k] = cleaned } }
                return out.isEmpty && !map.isEmpty ? nil : out
            case let list as [Any]:
                let out = list.enumerated().compactMap { scrub($0.element, path + [String($0.offset)], nil) }
                return out.isEmpty && !list.isEmpty ? nil : out
            default: return value
            }
        }
        var out: Object = [:]
        for (key, value) in values { if let cleaned = scrub(value, [key], key) { out[key] = cleaned } }
        return (out, dropped)
    }
}

// MARK: - The profile

/// A profile share: what this app writes and reads.
struct ProfileSharePayload {
    var name: String?
    var created: Date?
    var settings: [String: Object]
    /// Parts this app shows but does not install (plugins, presets, skills, AGENTS.md).
    var plugins: [Object] = []
    var presets: [Object] = []
    var skills: [Object] = []
    var agentsMd: String?

    init(name: String?, created: Date?, settings: [String: Object]) { self.name = name; self.created = created; self.settings = settings }

    init(json: Object) throws {
        guard json["kind"] as? String == "profile" else { throw HostError(String(localized: "这不是配置分享（可能是插件或对话）")) }
        guard let version = json["v"] as? Int, version >= 1 else { throw HostError(String(localized: "分享码没有版本")) }
        guard version <= ShareCodec.version else { throw HostError(String(localized: "这个配置来自更新的版本，请先更新 App")) }
        name = (json["name"] as? String).map { String($0.prefix(40)) }
        created = (json["created"] as? String).flatMap { ISO8601DateFormatter.share.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        var settings: [String: Object] = [:]
        if let raw = json["settings"] {
            guard let map = raw as? Object else { throw HostError(String(localized: "配置里的设置格式不对")) }
            for (ns, value) in map {
                guard let values = value as? Object, ns.range(of: #"^[A-Za-z0-9._:@/-]{1,80}$"#, options: .regularExpression) != nil else {
                    throw HostError(String(localized: "配置里的设置格式不对"))
                }
                if SettingsSanitizer.shareableNamespace(ns) { settings[ns] = values }
            }
        }
        self.settings = settings
        plugins = json["plugins"] as? [Object] ?? []
        presets = json["presets"] as? [Object] ?? []
        skills = json["skills"] as? [Object] ?? []
        agentsMd = (json["agentsMd"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    var json: Object {
        var out: Object = ["v": ShareCodec.version, "kind": "profile"]
        if let name, !name.isEmpty { out["name"] = name }
        if let created { out["created"] = ISO8601DateFormatter.share.string(from: created) }
        if !settings.isEmpty { out["settings"] = settings }
        return out
    }

    var summary: String {
        [settings.isEmpty ? nil : String(localized: "\(settings.count) 项设置"), plugins.isEmpty ? nil : String(localized: "\(plugins.count) 个插件"),
         presets.isEmpty ? nil : String(localized: "\(presets.count) 个预设"), skills.isEmpty ? nil : String(localized: "\(skills.count) 个技能"), agentsMd == nil ? nil : "AGENTS.md"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

extension ISO8601DateFormatter {
    static let share: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// 分享配置 step 1: what the current host can put in a share.
struct ProfileExport {
    struct Item: Identifiable {
        let ns: String
        let fields: Int
        let dropped: Int
        let bytes: Int
        var id: String { ns }
    }
    let items: [Item]
    let settings: [String: Object]
    let skippedNamespaces: Int

    static func load(_ host: Harness) async throws -> ProfileExport {
        let described = try await host.rpc("settings/describe", args: [:])
        var items: [Item] = []
        var settings: [String: Object] = [:]
        var skipped = 0
        for section in described["namespaces"] as? [Object] ?? [] {
            guard let ns = section["ns"] as? String else { continue }
            guard let cleaned = SettingsSanitizer.clean(section) else {
                if !((section["user"] as? Object) ?? [:]).isEmpty { skipped += 1 }
                continue
            }
            guard !cleaned.values.isEmpty else { continue }
            settings[ns] = cleaned.values
            let bytes = (try? JSONSerialization.data(withJSONObject: [ns: cleaned.values]).count) ?? 0
            items.append(Item(ns: ns, fields: cleaned.values.count, dropped: cleaned.dropped, bytes: bytes))
        }
        return ProfileExport(items: items.sorted { $0.ns < $1.ns }, settings: settings, skippedNamespaces: skipped)
    }

    func payload(_ selected: Set<String>, name: String?) -> ProfileSharePayload {
        ProfileSharePayload(name: name, created: Date(), settings: settings.filter { selected.contains($0.key) })
    }
}

// MARK: - Import and restore

/// 导入配置: what applying a share would change on the target host.
struct ProfileImportPlan {
    struct Diff: Identifiable {
        /// Where the value goes: objects merge field by field, so other entries on the host stay.
        let path: [String]
        let from: Any?
        let to: Any
        var key: String { path.joined(separator: ".") }
        var id: String { key }
    }

    /// The leaves of [incoming] that differ from [current], descending into objects.
    /// [user] is the host's own layer, [current] the value with defaults filled in: a field the
    /// host sets itself compares with that, one it leaves to the default with the default.
    static func diffs(_ incoming: Object, _ current: Object?, user: Object? = nil, _ prefix: [String] = []) -> [Diff] {
        incoming.sorted { $0.key < $1.key }.flatMap { key, value -> [Diff] in
            let existing = user?[key] ?? current?[key]
            if let object = value as? Object, !object.isEmpty, existing == nil || existing is Object {
                return diffs(object, current?[key] as? Object, user: user?[key] as? Object, prefix + [key])
            }
            return same(existing, value) ? [] : [Diff(path: prefix + [key], from: existing, to: value)]
        }
    }

    static func value(at path: [String], in object: Object?) -> Any? {
        guard let first = path.first else { return object }
        let next = object?[first]
        return path.count == 1 ? next : value(at: Array(path.dropFirst()), in: next as? Object)
    }
    struct Change: Identifiable {
        enum Kind { case add, change, unavailable, readOnly }
        let ns: String
        let kind: Kind
        let diffs: [Diff]
        let revision: Int
        /// Permission and sandbox sections: shown, left unticked.
        let sensitive: Bool
        var id: String { ns }
        var applicable: Bool { kind == .add || kind == .change }
    }
    let changes: [Change]
    let unchanged: [String]
    /// Fields of the share that look like credentials or local paths: never written.
    let ignored: [String]

    static let sensitiveNamespaces: Set<String> = ["permission", "bash-sandbox", "pwsh-sandbox", "agent-loop", "subagent", "session-log-deepseek"]

    static func make(_ payload: ProfileSharePayload, on host: Harness) async throws -> ProfileImportPlan {
        let described = try await host.rpc("settings/describe", args: [:])
        let writable = described["writable"] as? Bool == true
        let sections = Dictionary((described["namespaces"] as? [Object] ?? []).compactMap { section in
            (section["ns"] as? String).map { ($0, section) }
        }, uniquingKeysWith: { first, _ in first })
        var changes: [Change] = []
        var unchanged: [String] = []
        var ignored: [String] = []
        for (ns, raw) in payload.settings.sorted(by: { $0.key < $1.key }) {
            let cleaned = SettingsSanitizer.scrubbed(raw)
            ignored += cleaned.dropped.map { ns + "." + $0 }
            let values = cleaned.values
            if values.isEmpty { continue }
            guard let section = sections[ns] else {
                changes.append(Change(ns: ns, kind: .unavailable, diffs: Self.diffs(values, nil),
                                      revision: 0, sensitive: false))
                continue
            }
            let current = section["value"] as? Object ?? [:]
            let diffs = Self.diffs(values, current, user: section["user"] as? Object)
            if diffs.isEmpty { unchanged.append(ns); continue }
            let adds = diffs.allSatisfy { Self.value(at: $0.path, in: section["user"] as? Object) == nil }
            changes.append(Change(ns: ns, kind: writable ? (adds ? .add : .change) : .readOnly, diffs: diffs,
                                  revision: section["revision"] as? Int ?? 0, sensitive: sensitiveNamespaces.contains(ns)))
        }
        return ProfileImportPlan(changes: changes, unchanged: unchanged, ignored: ignored)
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (try? JSONSerialization.data(withJSONObject: ["v": a], options: .sortedKeys)) == (try? JSONSerialization.data(withJSONObject: ["v": b], options: .sortedKeys))
        default: false
        }
    }

    /// Saves a restore point, then writes the ticked sections and reads them back.
    func apply(_ selected: Set<String>, on host: Harness, hostLabel: String, share: String?) async throws -> ProfileRestorePoint {
        let chosen = changes.filter { $0.applicable && selected.contains($0.ns) }
        guard !chosen.isEmpty else { throw HostError(String(localized: "没有选中要导入的设置")) }
        let described = try await host.rpc("settings/describe", args: [:])
        let sections = (described["namespaces"] as? [Object] ?? []).filter { chosen.map(\.ns).contains($0["ns"] as? String ?? "") }
        var point = ProfileRestorePoint(id: UUID(), created: Date(), host: hostLabel, share: share, namespaces: [:])
        for section in sections {
            guard let ns = section["ns"] as? String, let change = chosen.first(where: { $0.ns == ns }) else { continue }
            let user = section["user"] as? Object ?? [:]
            var before: Object = [:]
            for diff in change.diffs { if let value = Self.value(at: diff.path, in: user) { before[diff.path.joined(separator: "\u{0}")] = value } }
            point.namespaces[ns] = .init(paths: change.diffs.map(\.path), before: try JSONSerialization.data(withJSONObject: before))
        }
        try await ProfileRestorePoint.save(point)
        var failures: [String] = []
        for change in chosen {
            let ops: [Object] = change.diffs.map { ["op": "set", "path": $0.path, "value": $0.to] }
            do { _ = try await host.rpcValue("settings/mutate", args: ["ns": change.ns, "expectedRevision": change.revision, "ops": ops]) }
            catch { failures.append(change.ns + "：" + HostError.explain(error)) }
        }
        let after = try await host.rpc("settings/describe", args: [:])
        for change in chosen where !failures.contains(where: { $0.hasPrefix(change.ns + "：") }) {
            let read = (after["namespaces"] as? [Object])?.first { $0["ns"] as? String == change.ns }
            let value = read?["user"] as? Object ?? [:]
            if let wrong = change.diffs.first(where: { !Self.same(Self.value(at: $0.path, in: value), $0.to) }) { failures.append(change.ns + String(localized: "：读回的「\(wrong.key)」和导入的不一致")) }
        }
        if !failures.isEmpty { throw HostError(String(localized: "部分设置没有导入，已保留恢复点"), detail: failures.joined(separator: "\n")) }
        return point
    }
}

/// What a profile import replaced, kept in the app's data for 恢复.
struct ProfileRestorePoint: Codable, Identifiable {
    static let changed = Notification.Name("profileRestorePointsChanged")

    struct Section: Codable {
        /// The field paths the import wrote.
        let paths: [[String]]
        /// Their user-layer values before the import, keyed by the path joined with NUL; absent paths were unset.
        let before: Data
    }
    let id: UUID
    let created: Date
    let host: String
    let share: String?
    var namespaces: [String: Section]
    var restored: Date?

    private static var file: URL {
        #if os(macOS)
        let root = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "pallas.mac")
        #else
        let root = URL.applicationSupportDirectory
        #endif
        let folder = root.appending(path: "profile-share", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.appending(path: "restore-points.json")
    }

    static func all() -> [ProfileRestorePoint] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ProfileRestorePoint].self, from: data)) ?? []
    }

    @MainActor static func save(_ point: ProfileRestorePoint) throws {
        var points = all().filter { $0.id != point.id }
        points.insert(point, at: 0)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Array(points.prefix(10)))
        #if os(macOS)
        try data.write(to: file, options: .atomic)
        #else
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #endif
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Writes the saved values back (and unsets fields the import added).
    func restore(on host: Harness) async throws {
        let described = try await host.rpc("settings/describe", args: [:])
        var failures: [String] = []
        for (ns, section) in namespaces.sorted(by: { $0.key < $1.key }) {
            guard let current = (described["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == ns }) else {
                failures.append(ns + String(localized: "：设备上没有这个设置分区")); continue
            }
            let before = (try? JSONSerialization.jsonObject(with: section.before) as? Object) ?? [:]
            let restored = section.paths.compactMap { path -> Object? in
                before[path.joined(separator: "\u{0}")].map { ["op": "set", "path": path, "value": $0] }
            }
            let added = section.paths.filter { before[$0.joined(separator: "\u{0}")] == nil }
            let ops = restored + Self.removals(added, in: current["user"] as? Object ?? [:]).map { ["op": "unset", "path": $0] as Object }
            do { _ = try await host.rpcValue("settings/mutate", args: ["ns": ns, "expectedRevision": current["revision"] as? Int ?? 0, "ops": ops]) }
            catch { failures.append(ns + "：" + HostError.explain(error)) }
        }
        if !failures.isEmpty { throw HostError(String(localized: "没能全部恢复"), detail: failures.joined(separator: "\n")) }
        var done = self
        done.restored = Date()
        try await Self.save(done)
    }

    /// What to unset for fields the import added: the highest object that holds
    /// nothing but those fields (a whole new channel at once — unsetting its fields
    /// one by one leaves an empty entry the host may refuse); else the field itself.
    static func removals(_ added: [[String]], in user: Object) -> [[String]] {
        let imported = Set(added.map { $0.joined(separator: "\u{0}") })
        func leaves(_ value: Any, _ path: [String]) -> [[String]] {
            guard let object = value as? Object, !object.isEmpty else { return [path] }
            return object.flatMap { leaves($0.value, path + [$0.key]) }
        }
        var result: [[String]] = []
        for path in added {
            var chosen = path
            for length in 1..<max(path.count, 1) {
                let prefix = Array(path.prefix(length))
                guard let inside = ProfileImportPlan.value(at: prefix, in: user) as? Object else { continue }
                if leaves(inside, prefix).allSatisfy({ imported.contains($0.joined(separator: "\u{0}")) }) { chosen = prefix; break }
            }
            if result.contains(where: { chosen.starts(with: $0) }) { continue }
            result.removeAll { $0.starts(with: chosen) }
            result.append(chosen)
        }
        return result
    }
}
