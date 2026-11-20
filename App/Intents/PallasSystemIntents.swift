import AppIntents
import SwiftUI

// iOS 26 and later: a result card shown right in Siri and Spotlight, and the system schemas
// Apple Intelligence's Siri uses to search and open conversations.

@available(iOS 26, macOS 26, *)
struct TaskResultSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Pallas 的结果"
    static let isDiscoverable = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: LocalizedStringResource("结果"))
    var result: TaskResultEntity

    init() {}

    init(result: TaskResultEntity) { self.result = result }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: TaskResultCard(title: result.conversationTitle, text: result.text, finishedAt: result.finishedAt))
    }
}

/// The card: the conversation's title, then the reply.
struct TaskResultCard: View {
    let title: String
    let text: String
    let finishedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: title).font(.headline).lineLimit(1)
                Spacer()
                Text(finishedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: text).font(.body).lineLimit(8)
        }
        .padding()
    }
}

@available(iOS 26, macOS 26, *)
struct ShowLatestResultIntent: AppIntent {
    static let title: LocalizedStringResource = "显示 Pallas 的结果"
    static let description = IntentDescription(LocalizedStringResource("不用打开 App，直接看到 Pallas Agent 最近办完的结果。"))
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: LocalizedStringResource("对话"))
    var conversation: ConversationEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TaskResultEntity> & ShowsSnippetIntent {
        let entity = try GetLatestResultIntent.latest(in: conversation)
        return .result(value: entity, snippetIntent: TaskResultSnippetIntent(result: entity))
    }
}

// `.system.searchInApp` is left out: iOS 27 Siri took it as Pallas's catch-all and sent a plain
// 「帮我做点事」 to the conversation search instead of 让 Pallas 办.

// `.system.open` is left out: a target entity may have one OpenIntent only, and `OpenConversationIntent`
// has to stay available from iOS 17, below what the schema macro needs.

/// Where the system lets people pick their own assistant (iOS 26.2), the side button can start Pallas.
#if os(iOS)
@available(iOS 26.2, *)
@AppIntent(schema: .assistant.activate)
struct ActivatePallasIntent {
    static let supportedModes: IntentModes = .foreground
    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentRouter.shared.submit(.newConversation)
        return .result()
    }
}
#endif
