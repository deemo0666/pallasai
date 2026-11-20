import AppIntents
import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

/// A Pallas conversation, as Siri, Shortcuts and Spotlight see it.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("对话"))
    static let defaultQuery = ConversationQuery()

    let id: String
    /// The host it lives on (`embedded` or a saved host).
    let scope: String
    @Property(title: LocalizedStringResource("标题")) var title: String
    @Property(title: LocalizedStringResource("更新时间")) var updatedAt: Date
    @Property(title: LocalizedStringResource("最后结果")) var lastResult: String?

    init(id: String, scope: String, title: String, updatedAt: Date, lastResult: String?) {
        self.id = id
        self.scope = scope
        self.title = title
        self.updatedAt = updatedAt
        self.lastResult = lastResult
    }

    init(_ record: ConversationIndex.Record) {
        self.init(id: record.id, scope: record.scope, title: record.title, updatedAt: record.updated, lastResult: record.result)
    }

    var displayRepresentation: DisplayRepresentation {
        if let lastResult, !lastResult.isEmpty {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(String(lastResult.prefix(80)))")
        }
        return DisplayRepresentation(title: "\(title)")
    }

    /// What Spotlight shows and searches.
    var searchAttributes: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .text)
        set.title = title
        set.displayName = title
        set.contentDescription = lastResult
        set.contentModificationDate = updatedAt
        return set
    }
}

@available(iOS 18, macOS 15, *)
extension ConversationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.displayName = title
        set.contentDescription = lastResult
        set.contentModificationDate = updatedAt
        return set
    }
}

struct ConversationQuery: EntityStringQuery {
    func entities(for identifiers: [ConversationEntity.ID]) async throws -> [ConversationEntity] {
        await MainActor.run {
            identifiers.compactMap { ConversationIndex.shared.records[$0].map(ConversationEntity.init) }
        }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        await MainActor.run { ConversationIndex.shared.match(string).prefix(30).map(ConversationEntity.init) }
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        await MainActor.run { ConversationIndex.shared.recent.prefix(15).map(ConversationEntity.init) }
    }
}

@available(iOS 27, macOS 27, *)
extension ConversationQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        await ConversationIndex.shared.reindex(identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await ConversationIndex.shared.reindex()
    }
}

/// The last reply of a conversation, for a shortcut to pass on (「Pallas 查到的单号 → 发信息」).
struct TaskResultEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("任务结果"))
    static let defaultQuery = TaskResultQuery()

    /// The conversation's id: one result per conversation, its latest.
    let id: String
    @Property(title: LocalizedStringResource("内容")) var text: String
    @Property(title: LocalizedStringResource("对话")) var conversationTitle: String
    @Property(title: LocalizedStringResource("完成时间")) var finishedAt: Date

    init(id: String, text: String, conversationTitle: String, finishedAt: Date) {
        self.id = id
        self.text = text
        self.conversationTitle = conversationTitle
        self.finishedAt = finishedAt
    }

    init?(_ record: ConversationIndex.Record) {
        guard let text = record.result, !text.isEmpty else { return nil }
        self.init(id: record.id, text: text, conversationTitle: record.title, finishedAt: record.resultAt ?? record.updated)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(text.prefix(80)))", subtitle: "\(conversationTitle)")
    }
}

struct TaskResultQuery: EntityQuery {
    func entities(for identifiers: [TaskResultEntity.ID]) async throws -> [TaskResultEntity] {
        await MainActor.run { identifiers.compactMap { ConversationIndex.shared.records[$0].flatMap(TaskResultEntity.init) } }
    }

    func suggestedEntities() async throws -> [TaskResultEntity] {
        await MainActor.run {
            ConversationIndex.shared.records.values.compactMap(TaskResultEntity.init)
                .sorted { $0.finishedAt > $1.finishedAt }.prefix(15).map { $0 }
        }
    }
}

/// Marks the chat as showing this conversation, so Siri knows what 「这个对话」 is (iOS 18.4).
struct ConversationAnnotation: ViewModifier {
    let session: String?

    func body(content: Content) -> some View {
        if #available(iOS 18.4, macOS 15.4, *) {
            content.appEntityIdentifier(session.map { EntityIdentifier(for: ConversationEntity.self, identifier: $0) })
        } else {
            content
        }
    }
}
