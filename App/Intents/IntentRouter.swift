import Combine
import Foundation

/// Routes system actions to the app's live conversation.
@MainActor
final class IntentRouter: ObservableObject {
    static let shared = IntentRouter()

    enum Action: Equatable {
        /// Send `text`; into `session` when given and free, else into a new conversation.
        case ask(String, session: String?, scope: String?, waitForReply: Bool)
        case newConversation
        case open(String, scope: String)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let action: Action
    }

    /// Where the request ended up.
    struct Outcome {
        let session: String
        let scope: String
        let title: String?
        var requestID: UUID? = nil
    }

    @Published private(set) var pending: Request?
    private var waiting: [UUID: CheckedContinuation<Outcome, Error>] = [:]
    private typealias Reply = AsyncThrowingStream<String, Error>
    private var replies: [UUID: (stream: Reply, continuation: Reply.Continuation)] = [:]

    /// Queued for the shell; fails if it is not taken up within `timeout`.
    func submit(_ action: Action, timeout: Duration = .seconds(45)) async throws -> Outcome {
        let request = Request(action: action)
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(request.id, .failure(IntentFailure(String(localized: "Pallas Agent 没能及时连上引擎。"))))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let old = pending { finish(old.id, .failure(IntentFailure(String(localized: "被新的请求取代了。")))) }
                waiting[request.id] = continuation
                if case .ask(_, _, _, true) = action {
                    replies[request.id] = Reply.makeStream(bufferingPolicy: .bufferingNewest(1))
                }
                pending = request
            }
        } onCancel: {
            Task { @MainActor in self.finish(request.id, .failure(CancellationError())) }
        }
    }

    /// The shell took the request up.
    func take(_ id: UUID) -> Action? {
        guard let request = pending, request.id == id else { return nil }
        pending = nil
        return request.action
    }

    func finish(_ id: UUID, _ result: Result<Outcome, Error>) {
        if pending?.id == id { pending = nil }
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        if case .failure(let error) = result {
            replies.removeValue(forKey: id)?.continuation.finish(throwing: error)
        }
        continuation.resume(with: result)
    }

    func checkPending(_ id: UUID) throws {
        guard waiting[id] != nil else { throw CancellationError() }
    }

    /// The stream is registered before dispatch, so a fast reply can arrive before the intent starts waiting.
    func reply(to id: UUID, timeout: Duration) async throws -> String {
        guard let reply = replies[id] else { throw CancellationError() }
        defer { replies[id] = nil }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            reply.continuation.finish(throwing: IntentFailure(String(localized: "还在办，结果出来后会在 Pallas Agent 里。")))
        }
        defer { deadline.cancel() }
        var iterator = reply.stream.makeAsyncIterator()
        guard let text = try await iterator.next() else { throw CancellationError() }
        return text
    }

    /// The shell saw a turn end.
    func turnEnded(requests: Set<UUID>, result: Result<String, Error>) {
        for id in requests {
            guard let reply = replies[id] else { continue }
            switch result {
            case .success(let text):
                reply.continuation.yield(text)
                reply.continuation.finish()
            case .failure(let error): reply.continuation.finish(throwing: error)
            }
        }
    }
}

struct IntentFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
