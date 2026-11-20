import Darwin
import Foundation
import UIKit

@MainActor
final class EmbeddedEngine {
    struct Endpoint: Equatable {
        let address: String
        let token: String

        /// `http://127.0.0.1:<port>/?token=…`, the only shape the engine reports.
        init?(url raw: String?) {
            guard let raw, let url = URLComponents(string: raw),
                  url.scheme == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil,
                  let port = url.port, url.path == "/", let token = url.queryItems?.first(where: { $0.name == "token" })?.value,
                  !token.isEmpty else { return nil }
            address = "http://127.0.0.1:\(port)"
            self.token = token
        }
    }

    static let shared = EmbeddedEngine()
    private static var bootstrap: URL? {
        Bundle.main.url(forResource: "start", withExtension: "cjs", subdirectory: "DSHEngine")
    }
    static var available: Bool { bootstrap != nil }
    /// 设置 › 本机引擎. Off: the app neither starts nor connects to it.
    nonisolated static let enabledKey = "embeddedEngineEnabled"
    static var enabled: Bool { available && UserDefaults.standard.object(forKey: enabledKey) as? Bool != false }

    /// What every failure that only a fresh process gets past tells the person to do.
    nonisolated static var reopenAdvice: String { String(localized: "请关掉 Pallas Agent 再重新打开。") }
    private static let stoppedError = HostError(String(localized: "本机已停止运行。") + reopenAdvice, code: "engine_stopped")
    private static let probe = URLSession(configuration: .ephemeral)

    // NodeMobile supports a single runtime for the lifetime of a process.
    private var launch: Task<Endpoint, Error>?
    private var starting: CheckedContinuation<Endpoint, Error>?
    private var moving: CheckedContinuation<Endpoint, Error>?
    private var relistening: Task<Endpoint, Error>?
    #if DEBUG && !targetEnvironment(simulator)
    private var fixtureStart: Task<UInt16, Error>?
    private var fixtureReply: AsyncStream<UInt16>.Continuation?
    #endif
    /// Held for the process's life: the engine reads its end, and a released `Pipe` closes both.
    private var commands: Pipe?
    private var hostWatch: NSObjectProtocol?
    /// The count of confirmed computers the engine last heard, so unrelated defaults changes stay quiet.
    private var toldMacHosts: Int?
    private var toldPeerDevices: Int?
    // Include queued main-actor requests when a turn ends during cancellation.
    private var phoneRequests: [UUID: Int] = [:]
    private var endingPhoneTurns = Set<UUID>()
    /// Each turn's request the host is answering now, so a key-step question can hold it open.
    private var answeringPhone: [UUID: String] = [:]
    /// Where the engine listens now; the listener can move (`relisten`).
    private(set) var endpoint: Endpoint?
    /// The runtime ended; only a fresh app process can start it again.
    private(set) var stopped = false
    /// The one launch this process gets reported an error or timed out: asking again repeats it.
    private(set) var startFailed = false
    /// Trying again cannot work until the app is reopened, so nothing should offer a retry.
    var needsRelaunch: Bool { stopped || startFailed }

    var runningAddress: String? { endpoint?.address }

    /// The on-phone engine has no PTY backend (its shell is the Linux guest, one command at a time), so terminals exist only on computers.
    func hasTerminal(_ host: Harness) -> Bool { !owns(host) }

    func owns(_ host: Harness) -> Bool {
        guard let runningAddress, let endpoint = URL(string: runningAddress) else { return false }
        return host.origin.scheme == endpoint.scheme && host.origin.host == endpoint.host && host.origin.port == endpoint.port
    }

    func start() async throws -> Endpoint {
        if let launch {
            _ = try await launch.value
            guard !stopped, let endpoint else { throw Self.stoppedError }
            return endpoint
        }
        guard let script = Self.bootstrap, let frameworks = Bundle.main.privateFrameworksURL else {
            throw HostError(String(localized: "这个安装包不完整，请重新安装 Pallas Agent。"))
        }
        let fm = FileManager.default
        let home = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let reports = Pipe(), orders = Pipe()
        // A write after the runtime ended fails with EPIPE instead of killing the app.
        _ = fcntl(orders.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        commands = orders
        toldPeerDevices = nil
        macHostsChanged()
        fullAutoChanged()
        accountsChanged()
        hostWatch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EmbeddedEngine.shared.macHostsChanged() }
        }
        let args = ["node", "--jitless", "--expose-internals", script.path,
                    home.appendingPathComponent("DSH").path, docs.appendingPathComponent("workspace").path,
                    String(reports.fileHandleForWriting.fileDescriptor), String(orders.fileHandleForReading.fileDescriptor),
                    Self.phoneEngineState, Self.uiNames,
                    UIApplication.shared.applicationState == .background ? "no" : "yes"]
        let launch = Task { () throws -> Endpoint in
            try await withCheckedThrowingContinuation { continuation in
                starting = continuation
                Self.read(reports.fileHandleForReading) { line in
                    DispatchQueue.main.async { MainActor.assumeIsolated { EmbeddedEngine.shared.receive(line) } }
                }
                Thread.detachNewThread {
                    guard let node = dlopen(frameworks.appendingPathComponent("NodeMobile.framework/NodeMobile").path, RTLD_NOW | RTLD_LOCAL),
                          let symbol = dlsym(node, "node_start") else {
                        try? reports.fileHandleForWriting.close()
                        return
                    }
                    typealias Start = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
                    let start = unsafeBitCast(symbol, to: Start.self)
                    let strings = args.map { strdup($0) }
                    defer { strings.forEach { free($0) } }
                    var argv = strings + [nil]
                    _ = start(Int32(args.count), &argv)
                    // The runtime has ended: the reader sees end of file.
                    try? reports.fileHandleForWriting.close()
                }
                Task {
                    try? await Task.sleep(for: .seconds(90))
                    guard let pending = starting else { return }
                    starting = nil
                    startFailed = true
                    pending.resume(throwing: HostError(String(localized: "启动用了太久。") + Self.reopenAdvice, code: "engine_timeout"))
                }
            }
        }
        self.launch = launch
        Log.engine.notice("engine starting")
        return try await launch.value
    }

    /// The endpoint, answering: the engine started if it has not been, and made to listen again
    /// when iOS took its listener away while the app was suspended.
    func reachable() async throws -> Endpoint {
        let endpoint = try await start()
        if await Self.answers(endpoint) { return endpoint }
        Log.engine.error("engine not answering at \(Self.port(endpoint), privacy: .public); asking it to listen again")
        return try await relisten()
    }

    private static func port(_ endpoint: Endpoint) -> String { String(endpoint.address.split(separator: ":").last ?? "-") }

    /// Whether anything answers HTTP at `endpoint`: any status counts.
    static func answers(_ endpoint: Endpoint) async -> Bool {
        guard let url = URL(string: endpoint.address + "/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        return (try? await probe.data(for: request))?.1 is HTTPURLResponse
    }

    /// The pages the engine's prompts send the person to, named as this interface shows them (`ui-names.cjs`).
    private static var uiNames: String {
        let path = { (steps: [String]) in steps.joined(separator: " → ") }
        let names = ["remoteHost": String(localized: "我的设备"), "authorizedFolders": String(localized: "授权文件夹"),
                     "pluginMarket": path([String(localized: "全部功能"), String(localized: "插件"), String(localized: "插件市场")]),
                     "importPlugin": path([String(localized: "全部功能"), String(localized: "插件"), String(localized: "已安装"),
                                           String(localized: "导入离线插件包")]),
                     "phoneControl": path([String(localized: "设置"), String(localized: "手机操控")])]
        guard let data = try? JSONSerialization.data(withJSONObject: names) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static var phoneEngineState: String { "off" }

    /// Tells the engine which conversations are 全自动.
    func fullAutoChanged() {
        guard !stopped, let commands else { return }
        try? commands.fileHandleForWriting.write(contentsOf: Data(FullAuto.shared.engineLine.utf8))
    }

    /// Tells the engine which sign-ins 全自动 may type: ids, names and account names, never passwords.
    func accountsChanged() {
        guard !stopped, let commands else { return }
        try? commands.fileHandleForWriting.write(contentsOf: Data(SavedAccounts.shared.engineLine.utf8))
    }

    /// Tells a running engine whether Pallas Agent is on screen: with phone control on, 自动化任务 that
    /// come due wait for it (Embedded/engine/schedule-hold.cjs).
    func frontChanged(_ front: Bool) {
        guard !stopped, let commands else { return }
        try? commands.fileHandleForWriting.write(contentsOf: Data(("{\"appFront\":\"" + (front ? "yes" : "no") + "\"}\n").utf8))
    }

    /// Tells a running engine how many saved computers have a confirmed key, so it offers `mac_task` only when one can answer.
    func macHostsChanged() {
        let saved = UserDefaults.standard.data(forKey: "hostProfiles").flatMap { try? JSONDecoder().decode([HostProfile].self, from: $0) } ?? []
        let count = saved.filter { !$0.fingerprint.isEmpty }.count
        let devices = 0
        guard !stopped, let commands else { return }
        if devices != toldPeerDevices {
            toldPeerDevices = devices
            try? commands.fileHandleForWriting.write(contentsOf: Data("{\"peerDevices\":\(devices)}\n".utf8))
        }
        guard count != toldMacHosts else { return }
        toldMacHosts = count
        try? commands.fileHandleForWriting.write(contentsOf: Data("{\"macHosts\":\(count)}\n".utf8))
    }

    /// Tells a running engine which authorized Files folders are open to its file tools, and where.
    func foldersChanged() {
        Task {
            let rows = await AuthorizedFolders.shared.holdAll()
            guard !stopped, let commands,
                  let bytes = try? JSONSerialization.data(withJSONObject: ["folders": rows], options: [.withoutEscapingSlashes]) else { return }
            try? commands.fileHandleForWriting.write(contentsOf: bytes + Data("\n".utf8))
        }
    }

    /// Asks the engine for a memory pass (`auto`, `now`) or to put back the files before the last one
    /// (`restore`); it answers with a `memoryDreamReply` line. False when no engine is running.
    func memoryDream(_ id: String, mode: String) -> Bool {
        guard !stopped, endpoint != nil, let commands,
              let bytes = try? JSONSerialization.data(withJSONObject: ["memoryDream": id, "mode": mode]) else { return false }
        do { try commands.fileHandleForWriting.write(contentsOf: bytes + Data("\n".utf8)) } catch { return false }
        return true
    }

    /// Asks the engine's default chat model for the new conversation's examples; it answers with a
    /// `starterIdeasReply` line. False when no engine is running.
    func starterIdeas(_ id: String, system: String, input: String) -> Bool {
        guard !stopped, endpoint != nil, let commands,
              let bytes = try? JSONSerialization.data(withJSONObject: ["starterIdeas": id, "system": system, "input": input]) else { return false }
        do { try commands.fileHandleForWriting.write(contentsOf: bytes + Data("\n".utf8)) } catch { return false }
        return true
    }

    /// The person is deciding on a key step of this turn: the engine keeps waiting for its answer.
    func holdPhoneRequest(_ owner: UUID) {
        guard !stopped, let commands, let request = answeringPhone[owner] else { return }
        try? commands.fileHandleForWriting.write(contentsOf: Data(("{\"calculatorWait\":\"" + request + "\"}\n").utf8))
    }

    /// Has the engine listen again (same port when free) and returns where it listens now.
    func relisten() async throws -> Endpoint {
        if let relistening { return try await relistening.value }
        let task = Task { () throws -> Endpoint in
            guard !stopped, let commands else {
                Log.engine.error("relisten refused: runtime has ended")
                throw Self.stoppedError
            }
            return try await withCheckedThrowingContinuation { continuation in
                moving = continuation
                do { try commands.fileHandleForWriting.write(contentsOf: Data("relisten\n".utf8)) }
                catch { moving = nil; continuation.resume(throwing: error); return }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    guard let pending = moving else { return }
                    moving = nil
                    Log.engine.error("relisten timed out")
                    pending.resume(throwing: HostError(String(localized: "本机没有回应，请再试一次。"), code: "engine_timeout"))
                }
            }
        }
        relistening = task
        defer { relistening = nil }
        return try await task.value
    }

    #if DEBUG && !targetEnvironment(simulator)
    /// Asks the local Node runtime for the loopback port it actually bound.
    func claudeOAuthFixturePort() async throws -> UInt16 {
        if let fixtureStart { return try await fixtureStart.value }
        let task = Task { () throws -> UInt16 in
            _ = try await start()
            guard !stopped, let commands else { throw Self.stoppedError }
            let (ports, receiver) = AsyncStream<UInt16>.makeStream()
            fixtureReply = receiver
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                receiver.finish()
            }
            defer {
                timeout.cancel()
                receiver.finish()
                fixtureReply = nil
            }
            try commands.fileHandleForWriting.write(contentsOf: Data("claude-oauth-fixture\n".utf8))
            for await port in ports { return port }
            throw HostError(String(localized: "连接失败"))
        }
        fixtureStart = task
        defer { fixtureStart = nil }
        return try await task.value
    }
    #endif

    /// One line the engine reported; nil at end of file, when the runtime has ended.
    private func receive(_ line: String?) {
        guard let line else {
            Log.engine.fault("engine runtime ended")
            TurnKeepAlive.shared.update(0)
            stopped = true
            #if DEBUG && !targetEnvironment(simulator)
            fixtureReply?.finish()
            #endif
            starting?.resume(throwing: HostError(String(localized: "没能启动。") + Self.reopenAdvice, code: "engine_stopped")); starting = nil
            moving?.resume(throwing: Self.stoppedError); moving = nil
            return
        }
        let data = Data(line.utf8)
        if let count = (try? JSONDecoder().decode([String: Int].self, from: data))?["turnsActive"] {
            TurnKeepAlive.shared.update(count)
            if count == 0 { DueTasks.shared.turnsEnded() }
            return
        }
        if let row = try? JSONDecoder().decode([String: String].self, from: data) {
            #if DEBUG && !targetEnvironment(simulator)
            if let reply = row["claudeOAuthFixture"] {
                if let port = UInt16(reply), port > 0 { fixtureReply?.yield(port) }
                fixtureReply?.finish()
                return
            }
            #endif
            if let session = row["appleModelSummary"], let value = row["value"] {
                AppleModelSummaries.shared.note(value, session: session)
                return
            }
            if let task = row["taskWaiting"] {
                DueTasks.shared.waiting(task: task, session: row["session"])
                return
            }
        }
        struct FolderEnvelope: Decodable { let folderRequest: UUID }
        if let envelope = try? JSONDecoder().decode(FolderEnvelope.self, from: data), let commands {
            Task {
                var reply = ["folderReply": envelope.folderRequest.uuidString.lowercased()]
                do {
                    let request = try JSONDecoder().decode(FolderRequest.self, from: data)
                    let workspace = URL.documentsDirectory.appending(path: "workspace", directoryHint: .isDirectory)
                    reply["value"] = try await AuthorizedFolders.shared.perform(request.args, workspace: workspace)
                } catch is DecodingError {
                    reply["error"] = String(localized: "folder_invalid_arguments: 请检查操作、相对路径及分页参数。")
                } catch {
                    reply["error"] = ((error as? HostError)?.code ?? "folder_read_failed") + ": " + error.localizedDescription
                }
                do {
                    var bytes = try JSONEncoder().encode(reply)
                    bytes.append(10)
                    try commands.fileHandleForWriting.write(contentsOf: bytes)
                } catch { /* The engine closed its pipe; the calling tool has ended. */ }
            }
            return
        }
        if let request = try? JSONDecoder().decode(AppleModel.Request.self, from: data), let commands {
            Task {
                let reply = await AppleModel.reply(to: request)
                do {
                    var bytes = try JSONEncoder().encode(reply)
                    bytes.append(10)
                    try commands.fileHandleForWriting.write(contentsOf: bytes)
                } catch { /* The engine closed its pipe; it names the conversation itself. */ }
            }
            return
        }
        if let request = try? JSONDecoder().decode(LanServices.Request.self, from: data), let commands {
            Task {
                let value = await LanServices.shared.perform(request.args)
                do {
                    var bytes = try JSONEncoder().encode(["lanReply": request.lanRequest.uuidString.lowercased(), "value": value])
                    bytes.append(10)
                    try commands.fileHandleForWriting.write(contentsOf: bytes)
                } catch { /* The engine closed its pipe; the calling tool has ended. */ }
            }
            return
        }
        if let request = try? JSONDecoder().decode(ShortcutRunner.Request.self, from: data), let commands {
            Task {
                let value = await ShortcutRunner.shared.perform(request)
                do {
                    var bytes = try JSONEncoder().encode(["shortcutReply": request.shortcutRequest.uuidString.lowercased(), "value": value])
                    bytes.append(10)
                    try commands.fileHandleForWriting.write(contentsOf: bytes)
                } catch { /* The engine closed its pipe; the calling tool has ended. */ }
            }
            return
        }
        if let cancel = try? JSONDecoder().decode(AppleData.Cancel.self, from: data) {
            AppleData.shared.cancel(cancel.appleDataCancel)
            return
        }
        if let request = try? JSONDecoder().decode(AppleData.Request.self, from: data), let commands {
            Task {
                let value = await AppleData.shared.perform(request)
                do {
                    var bytes = try JSONEncoder().encode(["appleDataReply": request.appleDataRequest.uuidString.lowercased(), "value": value])
                    bytes.append(10)
                    try commands.fileHandleForWriting.write(contentsOf: bytes)
                } catch { /* The engine closed its pipe; the calling tool has ended. */ }
            }
            return
        }
        if let cancel = try? JSONDecoder().decode(ShortcutRunner.Cancel.self, from: data) {
            ShortcutRunner.shared.cancel(cancel.shortcutCancel)
            return
        }
        if let cancel = try? JSONDecoder().decode(ClaudeDesktop.Cancel.self, from: data) {
            ClaudeDesktop.shared.cancel(cancel.claudeCancel)
            return
        }
        if let request = try? JSONDecoder().decode(ClaudeDesktop.Request.self, from: data), let commands {
            Task {
                var reply = ["claudeReply": request.claudeRequest.uuidString.lowercased()]
                do { reply["value"] = try await ClaudeDesktop.shared.run(request) }
                catch is CancellationError { reply["error"] = "claude_desktop_cancelled" }
                catch { reply["error"] = ((error as? HostError)?.code ?? "claude_desktop_failed") + ": " + HostError.explain(error) }
                do {
                    var bytes = try JSONEncoder().encode(reply)
                    bytes.append(10)
                    try commands.fileHandleForWriting.write(contentsOf: bytes)
                } catch { /* The engine closed its pipe; the calling tool has ended. */ }
            }
            return
        }
        if let cancel = try? JSONDecoder().decode(MacTask.Cancel.self, from: data) {
            MacTask.shared.cancel(cancel.macCancel)
            return
        }
        if let request = try? JSONDecoder().decode(MacTask.Request.self, from: data), let commands {
            Task {
                var reply = ["macReply": request.macRequest.uuidString.lowercased()]
                do { reply["value"] = try await MacTask.shared.run(request) }
                catch is CancellationError { reply["error"] = "mac_task_cancelled" }
                catch { reply["error"] = ((error as? HostError)?.code ?? "mac_task_failed") + ": " + HostError.explain(error) }
                do {
                    var bytes = try JSONEncoder().encode(reply)
                    bytes.append(10)
                    try commands.fileHandleForWriting.write(contentsOf: bytes)
                } catch { /* The engine closed its pipe; the calling tool has ended. */ }
            }
            return
        }
        guard let row = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        if let id = row["starterIdeasReply"] {
            StarterIdeas.shared.engineAnswered(id, row["value"] ?? "")
            return
        }
        if let id = row["memoryDreamReply"] {
            MemoryDream.shared.finish(id, row)
            return
        }
        if let reported = Endpoint(url: row["url"]) {
            let before = endpoint.map(Self.port) ?? "-"
            Log.engine.notice("engine listening at \(Self.port(reported), privacy: .public) (was \(before, privacy: .public))")
            endpoint = reported
            starting?.resume(returning: reported); starting = nil
            foldersChanged()
            MemoryDream.shared.engineReady()
            moving?.resume(returning: reported); moving = nil
        } else if let code = row["error"] {
            Log.engine.error("engine start failed: \(code, privacy: .public)")
            // The code stays in the log and on the error; the person reads what to do next.
            if starting != nil { startFailed = true }
            starting?.resume(throwing: HostError(String(localized: "没能启动。") + Self.reopenAdvice, code: code)); starting = nil
        } else if let state = row["relisten"] {
            Log.engine.error("relisten failed: \(state, privacy: .public) \(row["code"] ?? "-", privacy: .public)")
            moving?.resume(throwing: HostError(String(localized: "没能恢复连接，请再试一次。"), code: "engine_relisten")); moving = nil
        }
    }

    /// Reads `handle` line by line on a thread of its own; nil once the writer has closed it.
    nonisolated private static func read(_ handle: FileHandle, deliver: @escaping @Sendable (String?) -> Void) {
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { deliver(nil); return }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 0x0A) {
                    deliver(String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...end)
                }
            }
        }
    }
}
