import AppIntents
import CoreSpotlight
import Foundation

/// The conversations Siri, Shortcuts and Spotlight know about: a copy of the drawer's list (per host) and
/// the last reply of each, kept on the device so an intent can answer while no engine is connected.
@MainActor
final class ConversationIndex {
    static let shared = ConversationIndex()
    /// 设置 → 隐私与分享 → 在搜索中显示对话.
    static let searchableKey = "spotlightConversations"
    static let activityType = "io.github.maao514.harborchat.conversation"
    #if os(macOS)
    static let searchableByDefault = false
    #else
    static let searchableByDefault = true
    #endif
    private static let versionKey = "spotlightConversationsVersion"
    private static let version = 2

    struct Record: Codable, Equatable {
        let id: String
        var scope: String
        var title: String
        var updated: Date
        var result: String?
        var resultAt: Date?
    }

    private(set) var records: [String: Record] = [:]
    #if os(macOS)
    private let file = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "pallas.mac")
        .appending(path: "intent-conversations.json")
    #else
    private let file = URL.applicationSupportDirectory.appending(path: "intent-conversations.json")
    #endif
    private var searchChanges: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Record].self, from: data) {
            records = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    var searchable: Bool { UserDefaults.standard.object(forKey: Self.searchableKey) as? Bool ?? Self.searchableByDefault }

    /// Newest first.
    var recent: [Record] { records.values.sorted { $0.updated > $1.updated } }

    /// The host listed its conversations: replace that host's records with them.
    func update(_ rows: [HostSessionRow], scope: String) {
        let listed = rows.filter { !$0.blank && !$0.subagent && $0.parent == nil }
        let ids = Set(listed.map(\.id))
        let gone = records.values.filter { $0.scope == scope && !ids.contains($0.id) }.map(\.id)
        var changed: [Record] = []
        for row in listed {
            let before = records[row.id]
            var record = (before?.scope == scope ? before : nil)
                ?? Record(id: row.id, scope: scope, title: row.title, updated: row.updatedDate)
            record.title = row.title
            record.updated = max(row.updatedDate, record.resultAt ?? .distantPast)
            if before != record { records[row.id] = record; changed.append(record) }
        }
        for id in gone { records[id] = nil }
        // What the index holds changed shape (2: no 「Pallas」 keyword on every item): write it all again once.
        if UserDefaults.standard.integer(forKey: Self.versionKey) < Self.version {
            UserDefaults.standard.set(Self.version, forKey: Self.versionKey)
            changed = Array(records.values)
        }
        guard !changed.isEmpty || !gone.isEmpty else { return }
        save()
        index(changed)
        deindex(gone)
        PallasShortcuts.updateAppShortcutParameters()
    }

    /// A turn finished: its last reply becomes the conversation's result.
    func recordResult(session: String, scope: String, title: String?, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !text.isEmpty else { return }
        let now = Date()
        let before = records[session]
        var record = (before?.scope == scope ? before : nil)
            ?? Record(id: session, scope: scope, title: title ?? String(localized: "新对话"), updated: now)
        if let title, !title.isEmpty { record.title = title }
        record.result = text; record.resultAt = now; record.updated = now
        records[session] = record
        save()
        index([record])
    }

    func turnEnded(_ turn: Conversation.CompletedTurn, scope: String) {
        let reply = turn.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = turn.notice {
            let message = reason.kind == "aborted" ? String(localized: "已停止。")
                : reason.message ?? String(localized: "还没有办完的结果。")
            IntentRouter.shared.turnEnded(requests: turn.requests, result: .failure(IntentFailure(message)))
        } else if reply.isEmpty {
            IntentRouter.shared.turnEnded(requests: turn.requests,
                                          result: .failure(IntentFailure(String(localized: "还没有办完的结果。"))))
        } else {
            recordResult(session: turn.session, scope: scope, title: turn.title, text: reply)
            IntentRouter.shared.turnEnded(requests: turn.requests, result: .success(reply))
        }
    }

    /// Conversations deleted for good on their host.
    func remove(_ ids: some Sequence<String>, scope: String) {
        let ids = ids.filter { records[$0]?.scope == scope }
        guard !ids.isEmpty else { return }
        for id in ids { records[id] = nil }
        save()
        deindex(ids)
        PallasShortcuts.updateAppShortcutParameters()
    }

    /// The switch in 隐私与分享.
    func setSearchable(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.searchableKey)
        if on { index(Array(records.values)) } else { deindexAll() }
    }

    func match(_ text: String) -> [Record] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return recent }
        return recent.filter { $0.title.localizedStandardContains(needle) || ($0.result?.localizedStandardContains(needle) ?? false) }
    }

    private func save() {
        do {
            #if os(macOS)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Array(records.values)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #else
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(records.values)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
        } catch { Log.engine.error("conversation index save failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Spotlight

    private static let domain = "conversations"
    #if os(macOS)
    private let searchIndex = CSSearchableIndex(name: ConversationIndex.domain)
    #else
    private let searchIndex = CSSearchableIndex.default()
    #endif

    private func updateSearch(_ operation: @escaping (CSSearchableIndex) async -> Void) {
        let previous = searchChanges
        let searchIndex = searchIndex
        searchChanges = Task {
            await previous?.value
            await operation(searchIndex)
        }
    }

    func reindex(_ identifiers: [String]? = nil) async {
        index(identifiers.map { ids in ids.compactMap { records[$0] } } ?? Array(records.values))
        await searchChanges?.value
    }

    private func index(_ list: [Record]) {
        guard searchable, !list.isEmpty else { return }
        let entities = list.map(ConversationEntity.init)
        updateSearch { search in
            if #available(iOS 18, macOS 15, *) {
                try? await search.indexAppEntities(entities)
            } else {
                let items = entities.map { entity in
                    CSSearchableItem(uniqueIdentifier: entity.id, domainIdentifier: Self.domain, attributeSet: entity.searchAttributes)
                }
                try? await search.indexSearchableItems(items)
            }
        }
    }

    private func deindex(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        updateSearch { search in
            if #available(iOS 18, macOS 15, *) {
                try? await search.deleteAppEntities(identifiedBy: ids, ofType: ConversationEntity.self)
            }
            try? await search.deleteSearchableItems(withIdentifiers: ids)
        }
    }

    private func deindexAll() {
        updateSearch { search in
            if #available(iOS 18, macOS 15, *) {
                try? await search.deleteAppEntities(ofType: ConversationEntity.self)
            }
            try? await search.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        }
    }
}
