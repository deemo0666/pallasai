import Combine
import Foundation
@preconcurrency import Citadel
import NIOCore

#if os(macOS)
private typealias ClaudeConfirmation = MacTaskConfirmation
#else
private typealias ClaudeConfirmation = PhoneConfirmation
#endif

/// 本机 → 电脑上的 Claude 桌面版: the engine's `claude_sessions` and `claude_desktop` tools. Pallas on
/// a paired computer answers `pallas-claude` on the pairing SSH connection (Tools/HostPairing,
/// claude-desktop.js): `catalog` lists the desktop's Code sessions; `send` hands one message to a
/// session (running, asleep or new) and streams what it does, read from its transcript, until its
/// turn ends.
@MainActor
final class ClaudeDesktop: ObservableObject {
    static let shared = ClaudeDesktop()
    static let localEnabledKey = "claudeDesktopEnabled"
    typealias LocalCommand = @MainActor (_ verb: String, _ payload: Object) throws -> AsyncThrowingStream<Object, Error>

    /// One tool call the Claude session made, for the live panel.
    struct Step: Identifiable, Equatable {
        let id: String
        let name: String
        let summary: String
        var state: String
    }

    /// What one message is doing, for the live panel under its `claude_desktop` row.
    struct Live {
        enum Stage: Equatable { case connecting, asking, sending, working, finished }
        let host: String
        let message: String
        let originSessionID: String?
        let callID: String?
        var title = ""
        var stage = Stage.connecting
        var steps: [Step] = []
        /// The session's latest words before its final answer.
        var note = ""
        /// A question the session put to the person (AskUserQuestion), answered on the computer.
        var question: String?
        let started = Date()
    }

    @Published private(set) var live: [UUID: Live] = [:]

    func live(for message: String, stepID: String, sessionID: String?) -> Live? {
        if let sessionID, let exact = live.values.first(where: {
            $0.originSessionID == sessionID && ($0.callID.map { stepID.hasSuffix("/" + $0) } ?? false)
        }) { return exact }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return live.values.first { $0.message == text && ($0.originSessionID == nil || sessionID == nil) }
    }

    private func update(_ key: UUID, _ change: (inout Live) -> Void) {
        guard var entry = live[key] else { return }
        change(&entry)
        live[key] = entry
    }

    struct Request: Decodable, Sendable {
        let claudeRequest: UUID
        /// "catalog" or "send".
        let kind: String
        let message: String?
        let action: String?
        let sessionId: String?
        let cwd: String?
        let projectName: String?
        let title: String?
        let reason: String?
        let host: String?
        let confidence: Double?
        let localAvailable: Bool?
        let originSessionId: String?
        let callId: String?
    }

    struct Cancel: Decodable { let claudeCancel: UUID }

    private var running: [UUID: Task<String, Error>] = [:]
    private var localRequests: Set<UUID> = []

    func begin(_ request: Request, local: LocalCommand? = nil) -> Task<String, Error> {
        let id = request.claudeRequest
        if let work = running[id] { return work }
        let work = Task {
            defer { running[id] = nil; localRequests.remove(id) }
            try Task.checkCancellation()
            let computer = try Self.computer(request, local: local)
            if case .local = computer { localRequests.insert(id) }
            switch request.kind {
            case "catalog": return try await catalog(computer)
            case "send": return try await send(request, to: computer)
            default: throw HostError(String(localized: "任务内容为空或过长。"), code: "claude_invalid_arguments")
            }
        }
        running[id] = work
        return work
    }

    func run(_ request: Request) async throws -> String {
        let work = begin(request)
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// The engine stopped following. The native bridge also cancels any local process it started for this request.
    func cancel(_ id: UUID) {
        ClaudeConfirmation.shared.cancel(id)
        running[id]?.cancel()
    }

    func cancelLocalRequests() {
        for id in localRequests { cancel(id) }
    }

    // MARK: Connection

    private enum Computer {
        case local(LocalCommand)
        case paired(HostProfile)

        var name: String {
            switch self {
            case .local: String(localized: "本机")
            case .paired(let profile): profile.name.isEmpty ? profile.address : profile.name
            }
        }

        var selection: String {
            switch self {
            case .local: "local"
            case .paired(let profile): profile.id.uuidString
            }
        }
    }

    private static func computer(_ request: Request, local: LocalCommand?) throws -> Computer {
        let wanted = request.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let local, wanted.caseInsensitiveCompare("local") == .orderedSame || (wanted.isEmpty && request.localAvailable == true) {
            return .local(local)
        }
        let saved = MacTask.savedHosts
        let paired = saved.filter { $0.kind == .paired && !$0.fingerprint.isEmpty }
        if paired.isEmpty, !saved.isEmpty {
            throw HostError(String(localized: "Mac 上的 Claude 需要扫码配对的电脑，先在「我的电脑」里扫码连接。"), code: "claude_needs_paired_host")
        }
        if let id = UUID(uuidString: wanted), let profile = paired.first(where: { $0.id == id }) { return .paired(profile) }
        return .paired(try MacTask.pick(wanted, from: paired))
    }

    private enum Connection {
        case local(LocalCommand)
        case paired(SSHClient)

        func close() {
            if case .paired(let client) = self { Task { try? await client.close() } }
        }
    }

    private static func connect(_ computer: Computer) async throws -> Connection {
        switch computer {
        case .local(let command):
            return .local(command)
        case .paired(let profile):
            return .paired(try await connectPaired(profile))
        }
    }

    private static func connectPaired(_ profile: HostProfile) async throws -> SSHClient {
        let secrets = try HostVault.secrets(profile.id)
        do { return try await SSHTunnel.client(profile, secret: secrets.secret, passphrase: secrets.passphrase) }
        catch {
            try Task.checkCancellation()
            let failure = SSHFailure.explain(error, at: .connect)
            throw HostError(failure.message, code: "mac_unreachable", detail: failure.detail)
        }
    }

    private static var outdated: HostError {
        HostError(String(localized: "电脑上的 Pallas 配对服务需要更新，才能连接 Claude 桌面版。"), code: "claude_bridge_unavailable")
    }

    private static func fetchCatalog(_ connection: Connection) async throws -> Object {
        let object: Object
        switch connection {
        case .local(let command):
            var catalog: Object?
            for try await event in try command("catalog", [:]) {
                if let error = bridgeError(event) { throw explain(error) }
                if event["e"] as? String == "catalog" { catalog = event["value"] as? Object }
            }
            try Task.checkCancellation()
            guard let catalog else { throw outdated }
            object = catalog
        case .paired(let client):
            let output: ByteBuffer
            do {
                output = try await RemoteDSH.withTimeout(client, seconds: 20) {
                    try await client.executeCommand("pallas-claude catalog", maxResponseSize: 4 << 20)
                }
            } catch {
                try Task.checkCancellation()
                throw outdated
            }
            guard let catalog = try? JSONSerialization.jsonObject(with: Data(output.readableBytesView)) as? Object else { throw outdated }
            object = catalog
        }
        if object["claude"] as? Bool == false {
            throw HostError(String(localized: "这台电脑上没有找到 Claude Code 命令行。"), code: "claude_not_installed")
        }
        return object
    }

    // MARK: catalog

    private func catalog(_ computer: Computer) async throws -> String {
        let connection = try await Self.connect(computer)
        defer { connection.close() }
        let object = try await Self.fetchCatalog(connection)
        let now = Date().timeIntervalSince1970 * 1000
        let home = Self.home(object)
        let sessions: [Object] = (object["sessions"] as? [Object] ?? []).map { session in
            var row: Object = [
                "id": session["id"] as? String ?? "",
                "title": session["title"] as? String ?? "",
                "folder": Self.short(session["cwd"] as? String ?? "", home: home),
                "state": (session["state"] as? String).map { $0 == "busy" ? "running" : $0 } ?? "asleep",
                "last_active": Self.ago(now - (session["lastActivityAt"] as? Double ?? now)),
            ]
            if let summary = session["summary"] as? Object, let detail = summary["detail"] as? String, !detail.isEmpty {
                row["last_turn"] = [summary["status"] as? String, detail].compactMap { $0 }.joined(separator: ": ")
            }
            return row
        }
        let result: Object = [
            "computer": computer.name,
            "host": computer.selection,
            "sessions": sessions,
            "projects": (object["projects"] as? [String] ?? []).map { Self.short($0, home: home) },
            "new_projects_in": Self.short(object["newProjectRoot"] as? String ?? "", home: home),
        ]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes])
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The computer's home folder, read off the new-project folder (~/Developer).
    private static func home(_ catalog: Object) -> String {
        ((catalog["newProjectRoot"] as? String) as NSString?)?.deletingLastPathComponent ?? ""
    }

    private static func short(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func expand(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/"), !home.isEmpty else { return path }
        return home + path.dropFirst(1)
    }

    private static func ago(_ milliseconds: Double) -> String {
        let age = milliseconds.isFinite ? milliseconds : 0
        let minutes = Int(min(Double(Int32.max), max(0, age) / 60000))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / 1440) days ago"
    }

    // MARK: send

    private func send(_ request: Request, to computer: Computer) async throws -> String {
        let message = (request.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 20000 else {
            throw HostError(String(localized: "任务内容为空或过长。"), code: "claude_invalid_arguments")
        }
        let action = request.action ?? ""
        guard ["continue", "new_session", "new_project"].contains(action) else {
            throw HostError(String(localized: "任务内容为空或过长。"), code: "claude_invalid_arguments")
        }
        let name = computer.name
        let key = request.claudeRequest
        for old in live.filter({ $0.value.stage == .finished }).sorted(by: { $0.value.started < $1.value.started }).dropLast(5) {
            live[old.key] = nil
        }
        live[key] = Live(host: name, message: message, originSessionID: request.originSessionId, callID: request.callId)
        defer { update(key) { $0.stage = .finished } }

        let connection = try await Self.connect(computer)
        defer { connection.close() }
        let catalog = try await Self.fetchCatalog(connection)
        let home = Self.home(catalog)

        // What the person is asked about, and what goes to the computer.
        var payload: Object = ["message": message, "action": action]
        #if os(macOS)
        payload["source"] = "mac"
        #endif
        var question: String
        let gist = MacTask.gist(message)
        switch action {
        case "continue":
            let sessions = catalog["sessions"] as? [Object] ?? []
            guard let id = request.sessionId, let session = sessions.first(where: { $0["id"] as? String == id }) else {
                throw HostError(String(localized: "电脑上没有这个 Claude 会话。"), code: "claude_session_not_found")
            }
            let title = session["title"] as? String ?? id
            update(key) { $0.title = title }
            payload["sessionId"] = id
            question = String(localized: "发给 Mac 上的 Claude「\(title)」：\(gist)")
        case "new_session":
            let folder = Self.expand((request.cwd ?? "").trimmingCharacters(in: .whitespaces), home: home)
            guard !folder.isEmpty else { throw HostError(String(localized: "任务内容为空或过长。"), code: "claude_invalid_arguments") }
            payload["cwd"] = folder
            if let title = request.title { payload["title"] = title }
            update(key) { $0.title = request.title ?? (folder as NSString).lastPathComponent }
            question = String(localized: "在 Mac 上新开 Claude 会话（\((folder as NSString).lastPathComponent)）：\(gist)")
        default:
            let project = (request.projectName ?? "").trimmingCharacters(in: .whitespaces)
            payload["projectName"] = project
            if let title = request.title { payload["title"] = title }
            update(key) { $0.title = request.title ?? project }
            question = String(localized: "在 Mac 上新建项目「\(project)」交给 Claude：\(gist)")
        }

        // A sure follow-up goes straight away; a guess, or a new folder on the computer, is asked first.
        if action == "new_project" || (request.confidence ?? 0.5) < 0.8 {
            update(key) { $0.stage = .asking }
            let answer = await ClaudeConfirmation.shared.ask(question, owner: key)
            try Task.checkCancellation()
            switch answer {
            case .allowed: break
            case .denied: throw HostError(String(localized: "没有得到允许，电脑上什么都没做。"), code: "claude_denied")
            case .timedOut: throw HostError(String(localized: "等了太久没有回答，电脑上什么都没做。"), code: "claude_confirm_timeout")
            #if os(iOS)
            case .unavailable: throw HostError(String(localized: "Pallas Agent 不在前台，通知也没打开，没法问你。"), code: "claude_confirm_unavailable")
            #endif
            }
        }
        try Task.checkCancellation()
        update(key) { $0.stage = .sending }

        var outcome = Outcome()
        do {
            try await Self.events(connection, payload: payload) { event in
                handle(event, key: key, home: home, into: &outcome)
            }
        } catch let error as HostError where outcome.error == nil {
            throw error
        } catch {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        if let error = outcome.error { throw Self.explain(error) }
        if outcome.ended == nil && outcome.reply == nil { outcome.ended = "connection_lost" }

        var result: Object = ["computer": name, "host": computer.selection, "route": outcome.route ?? ""]
        if let session = outcome.session { result["session"] = session }
        result["reply"] = outcome.reply ?? ""
        if !outcome.tools.isEmpty { result["steps"] = outcome.tools }
        if let question = outcome.question { result["question"] = question }
        if let ended = outcome.ended { result["ended"] = ended }
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes])
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func events(_ connection: Connection, payload: Object, _ handle: (Object) -> Void) async throws {
        switch connection {
        case .local(let command):
            for try await event in try command("send", payload) {
                try Task.checkCancellation()
                handle(event)
            }
        case .paired(let client):
            let json = try JSONSerialization.data(withJSONObject: payload)
            let encoded = json.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let stream: AsyncThrowingStream<ExecCommandOutput, Error>
            do {
                stream = try await RemoteDSH.withTimeout(client, seconds: 20) {
                    try await client.executeCommandStream("pallas-claude send " + encoded)
                }
            } catch {
                try Task.checkCancellation()
                throw outdated
            }
            var pending = Data()
            for try await chunk in stream {
                try Task.checkCancellation()
                guard case .stdout(let buffer) = chunk else { continue }
                pending.append(contentsOf: buffer.readableBytesView)
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    if let event = try? JSONSerialization.jsonObject(with: line) as? Object { handle(event) }
                    pending.removeSubrange(...newline)
                }
                guard pending.count <= 256 * 1024 else { throw outdated }
            }
        }
    }

    private struct Outcome {
        var session: Object?
        var route: String?
        var reply: String?
        var tools: [String] = []
        var question: String?
        var ended: String?
        var error: (code: String, message: String)?
    }

    private func handle(_ event: Object, key: UUID, home: String, into outcome: inout Outcome) {
        switch event["e"] as? String {
        case "target":
            let title = event["title"] as? String ?? ""
            outcome.session = ["id": event["id"] as? String ?? "", "title": title, "folder": Self.short(event["cwd"] as? String ?? "", home: home)]
            if !title.isEmpty { update(key) { $0.title = title } }
        case "route":
            outcome.route = event["route"] as? String
        case "received":
            update(key) { $0.stage = .working }
        case "text":
            let text = event["text"] as? String ?? ""
            update(key) { $0.note = text }
        case "tool":
            let step = Step(id: event["id"] as? String ?? UUID().uuidString, name: event["name"] as? String ?? "", summary: event["summary"] as? String ?? "", state: "running")
            outcome.tools.append(step.summary.isEmpty ? step.name : step.name + ": " + step.summary)
            update(key) { $0.stage = .working; $0.steps.append(step) }
        case "tool_done":
            let id = event["id"] as? String
            let ok = event["ok"] as? Bool ?? true
            update(key) { entry in
                if let index = entry.steps.firstIndex(where: { $0.id == id }) { entry.steps[index].state = ok ? "ok" : "failed" }
            }
        case "question":
            let text = event["text"] as? String ?? ""
            outcome.question = text
            update(key) { $0.question = text }
        case "end":
            outcome.reply = event["reply"] as? String ?? ""
        case "timeout":
            outcome.ended = "still_running_after_30_min"
        case "process_failed":
            outcome.error = ("claude_failed", event["detail"] as? String ?? "")
        case "error":
            outcome.error = Self.bridgeError(event)
        default: break
        }
    }

    private static func bridgeError(_ event: Object) -> (code: String, message: String)? {
        guard event["e"] as? String == "error" else { return nil }
        return (event["code"] as? String ?? "claude_failed", event["message"] as? String ?? "")
    }

    private static func explain(_ error: (code: String, message: String)) -> HostError {
        switch error.code {
        case "session_not_found": HostError(String(localized: "电脑上没有这个 Claude 会话。"), code: "claude_session_not_found")
        case "invalid_project_name": HostError(String(localized: "项目名只能用字母、数字、空格和 . _ -。"), code: "claude_invalid_project_name")
        case "project_exists": HostError(String(localized: "这个项目文件夹已经存在。"), code: "claude_project_exists")
        case "invalid_folder": HostError(String(localized: "电脑上没有这个项目文件夹。"), code: "claude_invalid_folder")
        case "claude_not_installed": HostError(String(localized: "这台电脑上没有找到 Claude Code 命令行。"), code: "claude_not_installed")
        case "claude_local_disabled": HostError(String(localized: "请在设置中开启「连接本机 Claude 会话」。"), code: error.code)
        default: HostError(String(localized: "Claude 没能在电脑上运行。"), code: error.code, detail: error.message)
        }
    }
}
