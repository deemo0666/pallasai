import Combine
import Foundation
import OSLog

#if os(macOS)
private typealias TaskConfirmation = MacTaskConfirmation
#else
private typealias TaskConfirmation = PhoneConfirmation
#endif

/// 本机 → 电脑: the engine's `mac_task` tool. One task goes to DSH on a computer saved in 远程主机,
/// in a conversation of its own there; the reply and the files that conversation presented come back.
@MainActor
final class MacTask: ObservableObject {
    static let shared = MacTask()

    /// What one task is doing, for the live panel under its `mac_task` row.
    struct Live {
        enum Stage: Equatable { case connecting, asking, uploading(Int), working, fetching(Int), finished }
        let task: String
        let sessionID: String?
        let callID: String?
        let host: String
        let started = Date()
        var stage = Stage.connecting
        /// The computer agent's tool calls, in order.
        var steps: [ChatStep] = []
        /// Its latest words before the final answer ("我先看看…").
        var note = ""
        var screenshot: PlatformImage?
        var screenshotTime: Date?
    }

    @Published private(set) var live: [UUID: Live] = [:]

    /// The panel for a `mac_task` row with this task text.
    func live(for task: String, stepID: String, sessionID: String?) -> Live? {
        if let sessionID, let exact = live.values.first(where: {
            $0.sessionID == sessionID && ($0.callID.map { stepID.hasSuffix("/" + $0) } ?? false)
        }) { return exact }
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        // Older replies and transcripts may not carry the call identity.
        let nearby = live.values.filter { $0.sessionID == nil || sessionID == nil }
        if let exact = nearby.first(where: { $0.task == task }) { return exact }
        let head = String(task.prefix(40))
        return head.count >= 12 ? nearby.first(where: { $0.task.hasPrefix(head) }) : nil
    }

    private func update(_ key: UUID, _ change: (inout Live) -> Void) {
        guard var entry = live[key] else { return }
        change(&entry)
        live[key] = entry
    }

    struct Request: Decodable, Sendable {
        let macRequest: UUID
        let task: String
        let host: String?
        let files: [Outgoing]?
        let workspace: String?
        let sessionId: String?
        let callId: String?
        /// The calling conversation's approval policy: "never" under full access.
        let approval: String?
    }

    /// One file to send along: an image the person attached (`path`, in the engine's attachment
    /// store, with its display `name`) or a file the model named in the workspace (`workspacePath`).
    struct Outgoing: Decodable, Sendable {
        let path: String?
        let name: String?
        let workspacePath: String?
    }

    /// 权限 → 电脑任务: run without asking each time.
    static let autoAllowKey = "macTaskAutoAllow"

    struct Cancel: Decodable { let macCancel: UUID }

    private var running: [UUID: Task<String, Error>] = [:]

    func begin(_ request: Request, in roots: FileRoots) -> Task<String, Error> {
        if let work = running[request.macRequest] { return work }
        let work = Task {
            defer { running[request.macRequest] = nil }
            return try await perform(request, in: roots)
        }
        running[request.macRequest] = work
        return work
    }

    #if os(iOS)
    func run(_ request: Request) async throws -> String {
        let roots = FileRoots(workspace: URL.documentsDirectory.appending(path: "workspace"),
                              attachments: URL.applicationSupportDirectory.appending(path: "DSH/attachments"),
                              alias: "/root/workspace")
        let work = begin(request, in: roots)
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    #endif

    /// The tool call ended on the engine's side (stopped turn or timeout).
    func cancel(_ id: UUID) {
        TaskConfirmation.shared.cancel(id)
        running[id]?.cancel()
    }

    static var savedHosts: [HostProfile] {
        guard let data = UserDefaults.standard.data(forKey: "hostProfiles") else { return [] }
        return (try? JSONDecoder().decode([HostProfile].self, from: data)) ?? []
    }

    /// The saved computer to use: the named one, or the only one.
    static func pick(_ wanted: String?, from hosts: [HostProfile]) throws -> HostProfile {
        func label(_ host: HostProfile) -> String { host.name.isEmpty ? host.address : host.name }
        guard !hosts.isEmpty else {
            throw HostError(String(localized: "还没有连接过电脑，先在「我的电脑」里连接一次。"), code: "mac_no_host")
        }
        let names = hosts.map(label).joined(separator: String(localized: "、"))
        if let wanted = wanted?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
            let matches = hosts.filter { label($0).caseInsensitiveCompare(wanted) == .orderedSame || $0.address.caseInsensitiveCompare(wanted) == .orderedSame }
            guard matches.count == 1 else {
                throw HostError(String(localized: "没找到这个名字的电脑。连接过的电脑：") + names, code: "mac_host_unknown")
            }
            return matches[0]
        }
        guard hosts.count == 1 else {
            throw HostError(String(localized: "连接过多台电脑，请说明用哪一台：") + names, code: "mac_host_ambiguous")
        }
        return hosts[0]
    }

    private func perform(_ request: Request, in roots: FileRoots) async throws -> String {
        try Task.checkCancellation()
        let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.count <= 20000 else {
            throw HostError(String(localized: "任务内容为空或过长。"), code: "mac_invalid_arguments")
        }
        let profile = try Self.pick(request.host, from: Self.savedHosts)
        let name = profile.name.isEmpty ? profile.address : profile.name
        let key = request.macRequest
        // Finished panels stay for this launch, a few at most.
        for old in live.filter({ $0.value.stage == .finished }).sorted(by: { $0.value.started < $1.value.started }).dropLast(5) {
            live[old.key] = nil
        }
        live[key] = Live(task: task, sessionID: request.sessionId, callID: request.callId, host: name)
        defer { update(key) { $0.stage = .finished } }
        guard !profile.fingerprint.isEmpty else {
            throw HostError(String(localized: "这台电脑还没有核对过身份，先在「我的电脑」里连接一次。"), code: "mac_host_untrusted")
        }

        let filesToSend = request.files ?? []
        guard filesToSend.count <= 12 else {
            throw HostError(String(localized: "一次最多发送 12 个文件。"), code: "mac_invalid_arguments")
        }
        let outgoing = try filesToSend.map(roots.resolve)

        // Full access in this conversation, or 自动允许: no question for the task nor for the computer's approvals.
        let automatic = UserDefaults.standard.bool(forKey: Self.autoAllowKey) || request.approval == "never"
        if !automatic {
            update(key) { $0.stage = .asking }
            // One short sentence in the dialog and the notification; the whole instruction is under the step's row.
            var shown = Self.gist(task)
            if !outgoing.isEmpty { shown += String(localized: "（附 \(outgoing.count) 个文件）") }
            // Asked right after the phone part of the turn: ask in Pallas Agent once it is back in front.
            let answer = await ask(String(localized: "让电脑「\(name)」做这件事：\(shown)"), owner: key, seriousText: task)
            try Task.checkCancellation()
            switch answer {
            case .allowed: break
            case .denied: throw HostError(String(localized: "没有得到允许，电脑上什么都没做。"), code: "mac_denied")
            case .timedOut: throw HostError(String(localized: "等了太久没有回答，电脑上什么都没做。"), code: "mac_confirm_timeout")
            #if os(iOS)
            case .unavailable: throw HostError(String(localized: "Pallas Agent 不在前台，通知也没打开，没法问你。"), code: "mac_confirm_unavailable")
            #endif
            }
        }
        try Task.checkCancellation()
        update(key) { $0.stage = .connecting }

        let secrets = try HostVault.secrets(profile.id)
        let tunnel: SSHTunnel
        do { tunnel = try await SSHTunnel.open(profile, secret: secrets.secret, passphrase: secrets.passphrase, token: secrets.token) }
        catch {
            try Task.checkCancellation()
            let failure = SSHFailure.explain(error, at: .connect)
            throw HostError(failure.message, code: "mac_unreachable", detail: failure.detail)
        }
        guard let host = try? Harness(address: tunnel.address) else {
            await tunnel.close()
            throw HostError(String(localized: "主机地址无效。"), code: "mac_unreachable")
        }
        do {
            _ = try await host.connect(token: tunnel.token)
        } catch {
            host.close()
            await tunnel.close()
            try Task.checkCancellation()
            throw HostError(String(localized: "电脑没有接受连接。确认电脑开着、电脑上的服务在运行。"), code: "mac_unreachable", detail: error.localizedDescription)
        }
        var submitted = false
        var finished = false
        defer {
            let stop = submitted && !finished
            // A task of its own: this one may already be cancelled, and the computer should stop too.
            Task {
                if stop { await Self.stopRemote(host, requestID: key) }
                host.close()
                await tunnel.close()
            }
        }
        var receipts: [HostFileReference] = []
        if !outgoing.isEmpty { update(key) { $0.stage = .uploading(outgoing.count) } }
        for file in outgoing {
            try Task.checkCancellation()
            do { receipts.append(try await Self.upload(file, to: host)) }
            catch {
                try Task.checkCancellation()
                throw HostError(String(localized: "文件没能传到电脑：") + file.name, code: "mac_upload_failed", detail: error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        Log.connection.notice("mac task started session=\(Log.session(host.sessionID), privacy: .public) sent=\(receipts.count, privacy: .public)")
        submitted = true
        try await host.send(task, receipts: receipts, requestID: key)
        update(key) { $0.stage = .working }
        var shotTask: Task<Void, Never>?
        defer { shotTask?.cancel() }

        var reply = "", final = false, client = "", ended: TurnNotice?
        var presented: [HostDeliverable] = []
        while true {
            try Task.checkCancellation()
            let item = try await host.next()
            if let ask = item["interaction"] as? Object {
                if ask["type"] as? String == "ready" { client = ask["clientId"] as? String ?? ""; continue }
                guard ask["type"] as? String == "waterfall", let id = ask["eventId"] as? String else { continue }
                let mine = ask["agentId"] as? String == host.sessionID
                if mine, ask["event"] as? String == "user-questions/request" {
                    throw HostError(String(localized: "电脑那边有问题要问你，请切换到这台电脑，在它的对话里回答。"), code: "mac_needs_answer")
                }
                var outcome: Object = ["kind": "next"]
                if mine, ask["event"] as? String == "approval/request" {
                    outcome = ["kind": "result", "value": automatic ? "allowed-once" : try await approve(ask, on: name, key: key)]
                }
                _ = try await host.rpcValue("$events/result", args: ["clientId": client, "eventId": id, "outcome": outcome])
                continue
            }
            guard let event = item["event"] as? Object, let data = event["data"] as? Object else { continue }
            presented += HostDeliverable.files(in: event).filter { !$0.generated }
            if let record = Message.toolRecord(event)?.tool {
                update(key) { entry in
                    if let index = entry.steps.firstIndex(where: { $0.id == record.id }) {
                        if record.state != "running" { entry.steps[index].state = record.state; entry.steps[index].images = record.images }
                    } else if record.state == "running" { entry.steps.append(record) }
                }
                // The newest screenshot the computer took, fetched beside the stream.
                if let image = record.images?.last {
                    let when = Date()
                    shotTask?.cancel()
                    shotTask = Task { [weak self] in
                        guard let data = try? await host.imageData(image), !Task.isCancelled,
                              let picture = await HostImage.thumbnail(data, maxPixels: 720), !Task.isCancelled else { return }
                        self?.update(key) { entry in
                            guard (entry.screenshotTime ?? .distantPast) <= when else { return }
                            entry.screenshot = picture; entry.screenshotTime = when
                        }
                    }
                }
            }
            switch event["type"] as? String {
            case "assistant/message":
                if let message = Message.assistant(event), !message.text.isEmpty, message.finalAnswer || !final {
                    reply = message.text; final = message.finalAnswer
                    if !message.finalAnswer { update(key) { $0.note = message.text } }
                }
            case "turn/end":
                ended = TurnNotice.turnEnd(data)
                finished = true
            default: break
            }
            if finished { break }
        }

        var files: [[String: String]] = []
        var seen = Set<String>()
        if !presented.isEmpty { update(key) { $0.stage = .fetching(min(presented.count, 8)) } }
        for file in presented.prefix(8) where seen.insert(file.path).inserted {
            try Task.checkCancellation()
            var row = ["macPath": file.path]
            do { row["workspacePath"] = try roots.keep(try await host.downloadWorkspaceFile(file.path)) }
            catch { try Task.checkCancellation(); row["error"] = error.localizedDescription }
            files.append(row)
        }
        var result: Object = ["host": name, "reply": reply, "files": files]
        if !outgoing.isEmpty { result["sent"] = outgoing.map(\.name) }
        if let ended { result["ended"] = [ended.kind, ended.code, ended.message].compactMap { $0 }.joined(separator: " · ") }
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes])
        Log.connection.notice("mac task ended session=\(Log.session(host.sessionID), privacy: .public) files=\(files.count, privacy: .public)")
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func stopRemote(_ host: Harness, requestID: UUID) async {
        let session = host.sessionID
        let result = try? await host.call("session/cancel", ["sessionId": session])
        guard result?["accepted"] as? Bool != true else { return }
        // A stop can arrive after the prompt was submitted but before the remote turn starts.
        let state = try? await host.call("session/state", ["sessionId": session])
        if let queued = (state?["queue"] as? [Object])?.first(where: {
            ($0["rpcId"] as? String).flatMap(UUID.init(uuidString:)) == requestID
        }), let id = queued["id"] as? String {
            let removal = try? await host.call("session/updateQueue", ["sessionId": session, "itemId": id, "action": ["kind": "remove"]])
            if removal?["accepted"] as? Bool == true { return }
        }
        _ = try? await host.call("session/cancel", ["sessionId": session])
    }

    /// One approval the computer agent asks for, put to the person: "allowed-once" or "rejected".
    private func approve(_ event: Object, on host: String, key: UUID) async throws -> String {
        let request = event["request"] as? Object ?? [:]
        let call = request["callId"] as? String ?? "-"
        let step = live[key]?.steps.last { $0.id.hasSuffix("/" + call) }
        let named = step ?? (request["toolName"] as? String).map { ChatStep(id: "", name: $0, arguments: "", result: "", state: "running") }
        let what = named.map { [$0.verb, $0.summary(in: "")].filter { !$0.isEmpty }.joined(separator: " · ") } ?? String(localized: "一项操作")
        update(key) { $0.stage = .asking }
        defer { update(key) { $0.stage = .working } }
        let answer = await ask(String(localized: "电脑「\(host)」要做这一步：\(what)"), owner: key, seriousText: what)
        try Task.checkCancellation()
        return answer == .allowed ? "allowed-once" : "rejected"
    }

    private func ask(_ question: String, owner: UUID, seriousText: String) async -> TaskConfirmation.Outcome {
        #if os(macOS)
        await TaskConfirmation.shared.ask(question, owner: owner)
        #else
        await TaskConfirmation.shared.ask(question, owner: owner)
        #endif
    }

    /// The task in one short sentence for the question: its first sentence, cut at 60 characters.
    nonisolated static func gist(_ task: String) -> String {
        let flat = task.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var first = flat
        if let stop = flat.firstIndex(where: { "。！？!?；;".contains($0) }), flat.distance(from: flat.startIndex, to: stop) >= 6 {
            first = String(flat[..<stop])
        }
        return first.count > 60 ? String(first.prefix(60)) + "…" : (first.count < flat.count ? first + "…" : first)
    }

    /// A file to send, checked to lie in the workspace or the attachment store.
    struct Resolved { let url: URL; let name: String }

    struct FileRoots {
        let workspace: URL
        let attachments: URL
        var alias: String? = nil

        private func check(_ url: URL, under root: URL, shown: String) throws -> URL {
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path
            let path = url.resolvingSymlinksInPath().standardizedFileURL
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard path.path.hasPrefix(prefix), (try? path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw HostError(String(localized: "找不到要发送的文件：") + shown, code: "mac_file_missing")
            }
            return path
        }

        func resolve(_ file: Outgoing) throws -> Resolved {
            if let path = file.path {
                let url = try check(URL(fileURLWithPath: path), under: attachments, shown: file.name ?? path)
                let name = (file.name ?? "").replacingOccurrences(of: "/", with: "_")
                return Resolved(url: url, name: ["", ".", ".."].contains(name) ? url.lastPathComponent : name)
            }
            guard let given = file.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty else {
                throw HostError(String(localized: "要发送的文件没有路径。"), code: "mac_invalid_arguments")
            }
            let absolute: URL
            if let alias, given.hasPrefix(alias + "/") {
                absolute = workspace.appending(path: String(given.dropFirst(alias.count + 1)))
            } else if given.hasPrefix("/") {
                let prefixes = [workspace.path, workspace.resolvingSymlinksInPath().path].map {
                    $0.hasSuffix("/") ? $0 : $0 + "/"
                }
                guard prefixes.contains(where: { given.hasPrefix($0) }) else {
                    throw HostError(String(localized: "只能发送 Pallas Agent 文件夹里的文件：") + given, code: "mac_file_outside")
                }
                absolute = URL(fileURLWithPath: given)
            } else {
                absolute = workspace.appending(path: given)
            }
            let url = try check(absolute, under: workspace, shown: given)
            return Resolved(url: url, name: absolute.lastPathComponent)
        }

        /// Return the file in the same path namespace as the calling engine.
        func keep(_ downloaded: URL) throws -> String {
            let fm = FileManager.default
            defer { try? fm.removeItem(at: downloaded.deletingLastPathComponent()) }
            let directory = workspace.resolvingSymlinksInPath().appending(path: "mac-" + UUID().uuidString)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appending(path: downloaded.lastPathComponent)
            do { try fm.moveItem(at: downloaded, to: file) }
            catch { try? fm.removeItem(at: directory); throw error }
            if let alias { return alias + "/" + directory.lastPathComponent + "/" + file.lastPathComponent }
            return file.path
        }
    }

    /// Uploads under the file's own name (attachment objects are stored by digest).
    private static func upload(_ file: Resolved, to host: Harness) async throws -> HostFileReference {
        guard file.url.lastPathComponent != file.name else { return try await host.upload(file: file.url) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-send-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(file.name)
        try FileManager.default.copyItem(at: file.url, to: copy)
        return try await host.upload(file: copy)
    }

}
