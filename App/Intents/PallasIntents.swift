import AppIntents
import SwiftUI

/// 「让 Pallas 办」: Siri, Shortcuts, Spotlight and the Action button hand a request to Pallas Agent.
/// Phone control needs Pallas in front, so the intent opens the app and starts the task there.
struct AskPallasIntent: AppIntent {
    static let title: LocalizedStringResource = "让 Pallas 办"
    static let description = IntentDescription(LocalizedStringResource("把一件事交给 Pallas Agent 去办。"))
    static let openAppWhenRun = true
    /// Someone else's voice at a locked phone must not start a task.
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: LocalizedStringResource("要办的事"),
               description: LocalizedStringResource("交给 Pallas 的整件事，原话照录。"),
               inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: IntentDialog(LocalizedStringResource("要 Pallas 办什么？")))
    var request: String

    @Parameter(title: LocalizedStringResource("对话"))
    var conversation: ConversationEntity?

    @Parameter(title: LocalizedStringResource("等待回复"), default: false)
    var waitForReply: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("让 Pallas 办 \(\.$request)") {
            \.$conversation
            \.$waitForReply
        }
    }

    init() {}

    init(request: String) { self.request = request }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ConversationEntity> & ProvidesDialog {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw $request.needsValueError(IntentDialog(LocalizedStringResource("要 Pallas 办什么？"))) }
        let outcome = try await IntentRouter.shared.submit(.ask(text, session: conversation?.id,
                                                                scope: conversation?.scope, waitForReply: waitForReply))
        let title = outcome.title ?? ConversationIndex.shared.records[outcome.session]?.title ?? String(localized: "新对话")
        if waitForReply {
            guard let id = outcome.requestID else { throw CancellationError() }
            let reply = try await IntentRouter.shared.reply(to: id, timeout: .seconds(600))
            let entity = ConversationEntity(id: outcome.session, scope: outcome.scope, title: title, updatedAt: Date(), lastResult: reply)
            return .result(value: entity, dialog: IntentDialog(stringLiteral: reply))
        }
        let entity = ConversationEntity(id: outcome.session, scope: outcome.scope, title: title, updatedAt: Date(), lastResult: nil)
        return .result(value: entity, dialog: IntentDialog(LocalizedStringResource("已开始，Pallas 正在办。")))
    }
}

struct NewConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "新对话"
    static let description = IntentDescription(LocalizedStringResource("在 Pallas Agent 里开一个新对话。"))
    static let openAppWhenRun = true
    #if os(macOS)
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentRouter.shared.submit(.newConversation)
        return .result()
    }
}

struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "打开对话"
    static let description = IntentDescription(LocalizedStringResource("在 Pallas Agent 里打开一个对话。"))
    static let openAppWhenRun = true
    #if os(macOS)
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication
    #endif

    @Parameter(title: LocalizedStringResource("对话"))
    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentRouter.shared.submit(.open(target.id, scope: target.scope))
        return .result()
    }
}

#if os(macOS)
struct StopMacControlIntent: AppIntent {
    static let title: LocalizedStringResource = "停止操控 Mac"
    static let description = IntentDescription(LocalizedStringResource("让 Pallas Agent 停止操作 Mac。"))
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let chat = MacSystemActions.shared.chat
        guard chat.canStop else { return .result(dialog: IntentDialog(LocalizedStringResource("现在没有任务在运行。"))) }
        chat.stop()
        return .result(dialog: IntentDialog(LocalizedStringResource("已停止。")))
    }
}
#endif

/// The last reply of a conversation (the most recent one when none is chosen), to pass on in a shortcut.
struct GetLatestResultIntent: AppIntent {
    static let title: LocalizedStringResource = "获取 Pallas 的结果"
    static let description = IntentDescription(LocalizedStringResource("取出 Pallas Agent 最近一次办完的结果。"))
    static let openAppWhenRun = false
    /// Results can be private: not from the Lock Screen.
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: LocalizedStringResource("对话"))
    var conversation: ConversationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("获取 \(\.$conversation) 的结果")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TaskResultEntity> & ProvidesDialog {
        let entity = try Self.latest(in: conversation)
        return .result(value: entity, dialog: IntentDialog(stringLiteral: entity.text))
    }

    @MainActor
    static func latest(in conversation: ConversationEntity?) throws -> TaskResultEntity {
        let index = ConversationIndex.shared
        let record: ConversationIndex.Record?
        if let conversation {
            let entry = index.records[conversation.id]
            record = entry?.scope == conversation.scope ? entry : nil
        } else {
            record = index.records.values.filter { $0.result != nil }.max { ($0.resultAt ?? $0.updated) < ($1.resultAt ?? $1.updated) }
        }
        guard let record, let entity = TaskResultEntity(record) else { throw IntentFailure(String(localized: "还没有办完的结果。")) }
        return entity
    }
}
