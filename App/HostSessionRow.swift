import CryptoKit
import Foundation

struct HostSessionRow: Identifiable {
    let id: String
    let title: String
    var created: Int64?
    let updated: Int64
    let running: Bool
    let available: Bool
    let parent: String?
    let subagent: Bool
    let cwd: String?
    var snippet: String?
    /// Never prompted. DSH only creates a conversation on its first message, so these stay out of the list.
    let blank: Bool

    init(_ object: Object) throws {
        guard let id = object["sessionId"] as? String, !id.isEmpty,
              let updated = object["updatedAt"] as? Int64, let running = object["running"] as? Bool else {
            throw HostError(String(localized: "设备对话列表缺少必要字段。"))
        }
        self.id = id
        created = object["createdAt"] as? Int64
        self.updated = updated
        self.running = running
        available = object["agentAvailable"] as? Bool == true
        parent = object["parentSessionId"] as? String
        subagent = object["origin"] as? String == "subagent"
        cwd = object["cwd"] as? String
        blank = object["blank"] as? Bool == true
        let values = (object["projections"] as? Object)?["values"] as? Object
        let named = (values?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = !named.isEmpty ? named : object["blank"] as? Bool == true ? String(localized: "新对话") : String(localized: "未命名对话")
    }

    var updatedDate: Date { Date(timeIntervalSince1970: Double(updated) / 1000) }

    @MainActor func creationTime(on host: Harness) async throws -> Int64 {
        if let created { return created }
        let snapshot = try await host.snapshot(session: id, maxMessages: 1)
        guard let created = (snapshot["header"] as? Object)?["createdAt"] as? Int64 else {
            throw HostError(String(localized: "设备未提供对话创建时间。"))
        }
        return created
    }

    static func list(_ host: Harness) async throws -> [Self] {
        let result = try await host.sessionList()
        guard let items = result["items"] as? [Object] else { throw HostError(String(localized: "设备未返回对话列表。")) }
        return try items.map(Self.init)
    }
}

@MainActor
struct HostReadHistory: Codable {
    let baseline: Int64
    private var seen: [String: Int64] = [:]

    func unread(_ row: HostSessionRow, current: String) -> Bool {
        row.id != current && !row.running && row.updated > (seen[row.id] ?? baseline)
    }

    private static func key(for scope: String) -> String {
        "host-session-read-" + Data(SHA256.hash(data: Data(scope.utf8))).base64EncodedString()
    }

    static func forget(_ scope: String) {
        UserDefaults.standard.removeObject(forKey: key(for: scope))
        HostFolderLibrary.forget(scope)
    }

    static func forgetDeleted(_ ids: Set<String>, scope: String) throws {
        try HostFolderLibrary(scope: scope).forgetDeleted(ids)
        let key = key(for: scope)
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        var history = try JSONDecoder().decode(Self.self, from: data)
        for id in ids { history.seen.removeValue(forKey: id) }
        UserDefaults.standard.set(try JSONEncoder().encode(history), forKey: key)
    }

    /// Rows seen running in the last listing, per scope. The host's `updatedAt` moves only when a prompt is sent,
    /// so a reply finishing elsewhere shows up only as running → not running.
    private static var running: [String: Set<String>] = [:]

    static func update(_ rows: [HostSessionRow], current: String, scope: String) -> Self {
        let key = key(for: scope)
        let previous = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        var record = previous ?? Self(baseline: rows.map(\.updated).max() ?? 0)
        var changed = false
        let wasRunning = running[scope] ?? []
        running[scope] = Set(rows.filter(\.running).map(\.id))
        for row in rows where !row.running && row.id != current && wasRunning.contains(row.id) {
            // Unread until opened: seen just below the row's time.
            if (record.seen[row.id] ?? record.baseline) >= row.updated { record.seen[row.id] = row.updated - 1; changed = true }
        }
        if let active = rows.first(where: { $0.id == current }), active.updated > (record.seen[current] ?? record.baseline) {
            record.seen[current] = active.updated
        } else if previous != nil && !changed { return record }
        if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: key) }
        return record
    }
}

enum RemoteSessionFilter: String, CaseIterable { case all = "全部", running = "运行中", waiting = "待确认", unread = "未读" }
