import Foundation

struct HostError: LocalizedError {
    let message: String
    let code: String?
    /// The host's own explanation of a refused request, when it gave one.
    let detail: String?
    /// `detail` is protocol wording for logs and diagnostics; pages do not show it to the person.
    let internalDetail: Bool
    init(_ message: String, code: String? = nil, detail: String? = nil, internalDetail: Bool = false) {
        self.message = message.hostLocalized; self.code = code; self.detail = detail?.hostLocalized; self.internalDetail = internalDetail
    }
    var errorDescription: String? { message }

    /// The message plus the host's explanation, for pages that can show both.
    static func explain(_ error: Error) -> String {
        guard let host = error as? HostError, !host.internalDetail, let detail = host.detail, !detail.isEmpty else { return error.localizedDescription }
        return host.message + "\n" + detail
    }
}

extension HostError {
    /// Connection-layer failures. The user reads one plain sentence; the protocol wording stays in `detail` for logs and diagnostics.
    enum Wire {
        case timeout, lost, identity, unsupported, refused, garbled
        /// `local`: this iPhone's own engine; otherwise a connected computer.
        func text(local: Bool) -> String {
            switch self {
            case .timeout: local ? String(localized: "Pallas Agent 一直没有回应，请重新打开。") : String(localized: "电脑一直没有回应。稍后再试，或看看电脑是否开着。")
            case .lost: local ? String(localized: "Pallas Agent 没有回应，请重新打开。") : String(localized: "和电脑的连接断了。检查网络后重新连接。")
            case .identity: String(localized: "电脑的身份核对没有通过，已断开。在电脑上核实后再连接。")
            case .unsupported: local ? String(localized: "这个功能需要更新 Pallas Agent 后才能用。") : String(localized: "电脑上的版本太旧，不支持这个功能。更新后再试。")
            case .refused: local ? String(localized: "这次操作没有成功。") : String(localized: "电脑没有接受这次操作。")
            case .garbled: String(localized: "收到的数据不完整。重新连接后再试。")
            }
        }
    }
    static func wire(_ kind: Wire, _ technical: String, local: Bool = false, code: String? = nil) -> HostError {
        HostError(kind.text(local: local), code: code, detail: technical, internalDetail: true)
    }
}

typealias Object = [String: Any]

enum HostFileReference {
    case receipt(String)
}

/// One ephemeral login and a single ordered event stream for a fresh conversation.
@MainActor
final class Harness {
    typealias Items = AsyncThrowingStream<Object, Error>
    private let chatItems = Items.makeStream(bufferingPolicy: .bufferingOldest(4096))
    private var routes: [String: Items.Continuation] = [:]
    private var reader: Task<Void, Never>?

    private let http: URLSession
    var origin: URL { root }
    private let root: URL
    private var socket: URLSessionWebSocketTask?
    private(set) var sessionID = ""
    private(set) var sessionGeneration = UUID()
    private var sessionChannel: HarnessChannel?
    private var sessionReader: Task<Void, Never>?
    private var switchingSession = false

    private let interactionID = UUID().uuidString
    private let managedEngineHome: URL?

    init(address: String, managedEngineHome: URL? = nil) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw HostError(String(localized: "请输入主机地址，并将启动令牌填入单独的字段。"))
        }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw HostError(String(localized: "主机地址无效。")) }
        root = url
        self.managedEngineHome = managedEngineHome
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        http = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    private var closed = false

    /// The app owns the runtime and manages its model credentials.
    var usesEmbeddedEngine: Bool {
        #if os(iOS)
        EmbeddedEngine.shared.owns(self)
        #else
        managedEngineHome != nil
        #endif
    }

    var localEngineHome: URL? {
        #if os(iOS)
        usesEmbeddedEngine ? URL.applicationSupportDirectory.appending(path: "DSH", directoryHint: .isDirectory) : nil
        #else
        managedEngineHome
        #endif
    }
    private func wire(_ kind: HostError.Wire, _ technical: String, code: String? = nil) -> HostError {
        HostError.wire(kind, technical, local: usesEmbeddedEngine, code: code)
    }

    deinit { http.invalidateAndCancel() }

    private func requireOpen() throws {
        guard !closed else { throw HostError(String(localized: "连接已关闭。"), code: "connection-closed") }
    }

    func close() {
        guard !closed else { return }
        closed = true
        sessionReader?.cancel(); sessionReader = nil
        sessionChannel?.cancel(); sessionChannel = nil
        chatItems.continuation.finish(throwing: wire(.lost, "Connection closed"))
        imageCache.removeAllObjects()
        reader?.cancel()
        reader = nil
        for sink in routes.values { sink.finish(throwing: HostError(String(localized: "连接已关闭。"))) }
        routes.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        http.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    func authenticate(token: String, timeout: TimeInterval = 60) async throws {
        var login = URLComponents(url: root.appending(path: "connect"), resolvingAgainstBaseURL: false)!
        login.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "interactions", value: "answer")]
        guard let url = login.url else { throw HostError(String(localized: "启动令牌无效。")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (_, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              (300..<400).contains(status),
              http.configuration.httpCookieStorage?.cookies(for: root)?.isEmpty == false else {
            throw HostError(String(localized: "认证失败，请检查主机地址和启动令牌。"))
        }
    }

    func connect(token: String, existing: String? = nil, workspace: String? = nil) async throws -> Object {
        try requireOpen()
        try await authenticate(token: token)
        routes[interactionID] = chatItems.continuation
        let stream = makeSocket()
        socket = stream
        stream.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await stream.receive()
                    guard let self else { return }
                    try self.route(message)
                }
            } catch {
                guard let self else { return }
                for sink in self.routes.values { sink.finish(throwing: error) }
                self.routes.removeAll()
            }
        }
        let snapshot = try await switchSession(existing: existing, workspace: workspace)
        let events: Object = ["type": "open", "streamId": interactionID, "endpoint": "$events", "payload": ["args": [:] as Object]]
        try await sendFrame(events)
        return snapshot
    }

    /// Prepare the replacement subscription before releasing the old one. A refused create or
    /// follow leaves the old session usable. Never authenticates again or restarts the socket.
    func switchSession(existing: String?, workspace: String? = nil) async throws -> Object {
        try requireOpen()
        guard !switchingSession else { throw HostError(String(localized: "正在新建对话…")) }
        switchingSession = true
        defer { switchingSession = false }
        let target: String
        if let existing { target = existing }
        else {
            let created = try await call("session/create", workspace.map { ["workspaceId": $0] } ?? [:])
            guard let id = created["sessionId"] as? String, !id.isEmpty else {
                throw wire(.garbled, "session/create returned no session id")
            }
            target = id
        }
        let channel = try await stream("session/follow", args: ["request": [
            "address": ["kind": "session", "sessionId": target], "assistantStream": true, "maxMessages": 100]])
        do {
            let snapshot = try await channel.next()
            try Task.checkCancellation()
            try requireOpen()
            guard snapshot["type"] as? String == "snapshot" else {
                throw wire(.garbled, "session/follow sent no snapshot")
            }
            sessionReader?.cancel()
            sessionChannel?.cancel()
            sessionChannel = channel
            sessionID = target
            sessionGeneration = UUID()
            let generation = sessionGeneration.uuidString
            sessionReader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        var item = try await channel.next()
                        guard !Task.isCancelled, let self, self.sessionChannel === channel else { return }
                        item["_clientSessionID"] = target
                        item["_clientSessionGeneration"] = generation
                        if case .dropped = self.chatItems.continuation.yield(item) {
                            throw HostError(String(localized: "消息积压太多，请重新连接。"), detail: "session stream buffer full", internalDetail: true)
                        }
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.sessionChannel === channel else { return }
                    self.chatItems.continuation.finish(throwing: error)
                }
            }
            return snapshot
        } catch {
            channel.cancel()
            throw error
        }
    }

    private func makeSocket() -> URLSessionWebSocketTask {
        var endpoint = URLComponents(url: root.appending(path: "api/remote.mux"), resolvingAgainstBaseURL: false)!
        endpoint.scheme = root.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: endpoint.url!)
        if let cookies = http.configuration.httpCookieStorage?.cookies(for: root) {
            request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        }
        let task = http.webSocketTask(with: request)
        // The default 1 MiB fails the whole socket ("Message too long") on one large frame, and a
        // `session/follow` snapshot of 100 messages with their tool output passes that easily.
        task.maximumMessageSize = 64 << 20
        return task
    }

    /// This host's authenticated HTTP session for plugin routes (`api/bot/feed`); nil once closed.
    func pluginRoute(_ path: String, query: [URLQueryItem] = []) -> (session: URLSession, request: URLRequest)? {
        guard !closed, var parts = URLComponents(url: root.appending(path: path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        if let cookies = http.configuration.httpCookieStorage?.cookies(for: root) { request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies) }
        return (http, request)
    }

    func bot(_ endpoint: String, _ payload: Object = [:]) async throws -> Any {
        try requireOpen()
        var request = URLRequest(url: root.appending(path: "api/bot"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["endpoint": endpoint, "payload": payload])
        let (bytes, response) = try await http.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HostError(String(localized: "这台设备还不支持 DS Bot。"), code: "bot_unavailable") }
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? Object, result["ok"] as? Bool == true else {
            throw HostError(String(localized: "DS Bot 没有接受这次请求。"))
        }
        return result["value"] ?? NSNull()
    }

    func upload(file: URL) async throws -> HostFileReference {
        try requireOpen()
        var path = URLComponents(url: root.appending(path: "api/session/uploadFileBinary"), resolvingAgainstBaseURL: false)!
        path.queryItems = [.init(name: "sessionId", value: sessionID), .init(name: "name", value: file.lastPathComponent)]
        var request = URLRequest(url: path.url!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await http.upload(for: request, fromFile: file)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let result = try JSONSerialization.jsonObject(with: data) as? Object,
              result["ok"] as? Bool == true, let value = result["value"] as? Object, let receipt = value["receiptId"] as? String
        else { throw HostError(String(localized: "文件没有传上去，请重试。")) }
        return .receipt(receipt)
    }

    /// `session/prompt`. `mode` is "queue" (after the running turn) or "steer" (into the running turn).
    func send(_ text: String, image: Data? = nil, receipts: [HostFileReference] = [], requestID: UUID = UUID(), mode: String = "queue") async throws {
        var content: [Object] = text.isEmpty ? [] : [["type": "text", "text": text]]
        for case .receipt(let id) in receipts { content.append(["type": "file", "receiptId": id]) }
        if let image { content.append(["type": "image", "mediaType": "image/jpeg", "data": image.base64EncodedString()]) }
        let receipt = try await call("session/prompt", ["sessionId": sessionID, "requestId": requestID.uuidString,
            "mode": mode, "content": content, "clientTimeZone": TimeZone.current.identifier])
        guard receipt["accepted"] as? Bool == true else { throw HostError(String(localized: "没收到确认，消息可能没发出去。")) }
    }

    private func route(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw wire(.garbled, "unknown websocket message type")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let parsed = try JSONSerialization.jsonObject(with: data) as? Object
        if data.count > 100_000 { ImageTiming.log("ws-decode", start: start, "bytes=\(data.count)") }
        guard let packet = parsed, packet["streamId"] is String else { throw wire(.garbled, "packet without streamId") }
        routePacket(packet)
    }

    private func routePacket(_ packet: Object) {
        guard let id = packet["streamId"] as? String else { return }
        guard let sink = routes[id] else { return }
        if packet["type"] as? String == "item", let value = packet["value"] as? Object {
            let item = id == interactionID ? ["interaction": value] : value
            if case .dropped = sink.yield(item) {
                sink.finish(throwing: HostError(String(localized: "消息积压太多，请重新连接。"), detail: "stream buffer full", internalDetail: true))
                cancelStream(id)
            }
        } else {
            let info = packet["error"] as? Object
            let message = [info?["code"], info?["message"]].compactMap { $0 as? String }.joined(separator: " · ")
            routes.removeValue(forKey: id)?.finish(throwing: HostError(String(localized: "连接中断了，请重试。"), detail: message.isEmpty ? "stream ended by host" : message, internalDetail: true))
        }
    }

    func next() async throws -> Object {
        var iterator = chatItems.stream.makeAsyncIterator()
        while let item = try await iterator.next() {
            if let generation = item["_clientSessionGeneration"] as? String, generation != sessionGeneration.uuidString { continue }
            return item
        }
        throw wire(.lost, "session stream ended by host")
    }

    func stream(_ endpoint: String, args: Object) async throws -> HarnessChannel {
        let id = UUID().uuidString
        let pipe = Items.makeStream(bufferingPolicy: .bufferingOldest(1024))
        routes[id] = pipe.continuation
        do {
            try await sendFrame(["type": "open", "streamId": id, "endpoint": endpoint, "payload": ["args": args]])
            return HarnessChannel(host: self, id: id, items: pipe.stream)
        } catch {
            routes.removeValue(forKey: id)?.finish(throwing: error)
            throw error
        }
    }

    fileprivate func sendFrame(_ packet: Object) async throws {
        guard let socket else { throw HostError(String(localized: "连接已关闭。")) }
        try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: packet), as: UTF8.self)))
    }

    fileprivate func cancelStream(_ id: String) {
        routes.removeValue(forKey: id)?.finish()
        Task { try? await sendFrame(["type": "cancel", "streamId": id]) }
    }

    private var sessionListing: Task<Object, Error>?

    /// `session/list`. The host summarises every conversation it keeps (hundreds after a while, about
    /// 1 KB each), so callers asking at the same moment (a turn ending) share one request.
    func sessionList() async throws -> Object {
        if let sessionListing { return try await sessionListing.value }
        let listing = Task { try await rpc("session/list", args: ["_request": [:] as Object]) }
        sessionListing = listing
        defer { if sessionListing == listing { sessionListing = nil } }
        return try await listing.value
    }

    private let imageCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func setArchived(_ archived: Bool, session: String) async throws {
        var request: Object = ["sessionId": session]
        if archived { request["stopActivity"] = true }
        let result = try await call(archived ? "workspace/archiveSession" : "workspace/unarchiveSession", request)
        guard let ids = result["archivedSessionIds"] as? [String], ids.contains(session) == archived else {
            throw HostError(String(localized: "没收到归档结果，刷新后再看。"))
        }
    }

    /// Whether this host's engine has `workspace/deleteSession`. An empty id is refused before anything is touched.
    func checkDeletionSupport() async throws {
        do {
            _ = try await call("workspace/deleteSession", ["sessionId": ""])
        } catch let error as HostError where error.code == "gateway/bad-request" {
            return
        } catch let error as HostError where error.code == nil || error.code == "session/delete-unavailable" {
            throw wire(.unsupported, error.detail ?? error.message)
        }
        throw wire(.garbled, "delete probe was not refused")
    }

    /// Permanently deletes one idle top-level conversation; returns only once the host confirms.
    func deleteSession(_ id: String) async throws {
        let reply: Object
        do { reply = try await call("workspace/deleteSession", ["sessionId": id]) }
        catch let error as HostError {
            let code = error.code.map { $0.hasPrefix("session/delete-") ? String($0.dropFirst("session/delete-".count)) : $0 }
            let reason: String
            switch code {
            case "session-active": reason = String(localized: "这个对话还在运行，先停止再删除。")
            case "session-related": reason = String(localized: "这个对话有子任务或自动化任务，不能删除。")
            case "writer-held": reason = String(localized: "这个对话正被占用，稍后再试。")
            case "not-found": reason = String(localized: "这个对话已经不在了。")
            case "unavailable": reason = String(localized: "这台设备不支持永久删除。")
            case "failed": reason = String(localized: "删除没有完成，再试一次。")
            default: throw error
            }
            throw HostError(reason, code: code, detail: error.detail)
        }
        guard reply["deleted"] as? Bool == true, reply["sessionId"] as? String == id else {
            throw HostError(String(localized: "没收到删除结果，刷新后再看。"), code: "unconfirmed")
        }
    }

    func snapshot(session: String, maxMessages: Int, parent: String? = nil, mode: String = "unknown") async throws -> Object {
        // A subagent is read by its parent's address; as a session of its own the engine answers session/agent-busy.
        let address: Object = parent.map { ["kind": "subagent", "parentSessionId": $0, "childSessionId": session,
                                            "mode": ["one-shot", "continuable"].contains(mode) ? mode : "unknown"] }
            ?? ["kind": "session", "sessionId": session]
        let request: Object = ["address": address, "maxMessages": maxMessages]
        let channel = try await stream("session/follow", args: ["request": request])
        defer { channel.cancel() }
        let snapshot = try await channel.next()
        guard snapshot["type"] as? String == "snapshot" else { throw wire(.garbled, "no session snapshot") }
        return snapshot
    }

    func imageData(_ ref: HostImage, session: String? = nil) async throws -> Data {
        let session = session ?? sessionID
        guard ref.bytes <= 32 * 1024 * 1024 else { throw HostError(String(localized: "图片超过 32 MB，无法预览。")) }
        let key = "\(session):\(ref.id):\(ref.mediaType):\(ref.bytes):\(ref.width)x\(ref.height)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached as Data }
        func fetch(_ field: Object) async throws -> Object {
            var request = field
            request["sessionId"] = session
            // The JSON encoder may escape every slash in a base64 string.
            let limit = 8 * ((ref.bytes + 2) / 3) + 65536
            let value = try await ImageTiming.measure("fetch") { try await rpcValue("session/attachment", args: ["request": request], responseLimit: limit) }
            guard let reply = value as? Object else { throw HostError(String(localized: "没能读取图片。")) }
            return reply
        }
        let reply: Object
        do { reply = try await fetch(["attachment": ref.wire]) }
        catch let error as HostError where ["gateway/arguments-invalid", "gateway/input-invalid"].contains(error.code ?? "") {
            reply = try await fetch(["attachmentId": ref.id])
        }
        let data = try ImageTiming.measure("verify", "bytes=\(ref.bytes)") { try ref.data(from: reply) }
        imageCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    func call(_ method: String, _ request: Object) async throws -> Object {
        try await rpc(method, args: ["request": request])
    }

    func rpc(_ method: String, args: Object) async throws -> Object {
        let value = try await rpcValue(method, args: args)
        guard let object = value as? Object else { throw wire(.garbled, "reply is not an object") }
        return object
    }

    func downloadWorkspaceFile(_ path: String) async throws -> URL {
        let name = (path as NSString).lastPathComponent
        guard !["", ".", "..", "/"].contains(name), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw HostError(String(localized: "文件名有问题，没能下载。"))
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent(name)
        do {
            try Data().write(to: file)
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var offset = 0
            var version: String?
            var total: Int?
            let chunk = 64 * 1024
            while true {
                try Task.checkCancellation()
                let args: Object = ["workspaceFileScopeId": sessionID, "path": path, "options": ["range": ["offset": offset, "length": chunk]]]
                let result = try await rpcValue("workspaceFiles/readBytes", args: args, responseLimit: 2 * chunk + 32 * 1024)
                guard let page = result as? Object, let size = page["bytes"] as? Int, size >= 0,
                      let stamp = page["version"] as? String, !stamp.isEmpty, page["offset"] as? Int == offset,
                      let eof = page["eof"] as? Bool else { throw HostError(String(localized: "没能读取文件，请重试。")) }
                guard size <= 300 * 1024 * 1024 else { throw HostError(String(localized: "文件超过 300 MiB。")) }
                guard total == nil || total == size, version == nil || version == stamp else {
                    throw HostError(String(localized: "下载时文件变了，请重试。"))
                }
                let contents: Data?
                if let encoded = page["data"] as? String, encoded.utf8.count <= 4 * ((chunk + 2) / 3) {
                    contents = Data(base64Encoded: encoded)
                } else { contents = page["data"] as? Data }
                guard let contents, contents.count <= chunk, offset + contents.count <= size,
                      eof == (offset + contents.count == size), eof || !contents.isEmpty else { throw wire(.garbled, "incomplete file chunk") }
                try output.write(contentsOf: contents)
                if eof { return file }
                total = size; version = stamp; offset += contents.count
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func byteEnvelope(_ data: Data, contentType: String) throws -> Object {
        let invalid = HostError.wire(.garbled, "invalid multipart byte reply")
        guard let parameter = contentType.components(separatedBy: ";").dropFirst().map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.lowercased().hasPrefix("boundary=") }) else { throw invalid }
        let boundary = String(parameter.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !boundary.isEmpty, boundary.utf8.count <= 70, boundary.rangeOfCharacter(from: .controlCharacters) == nil else { throw invalid }
        let separator = Data(("--" + boundary).utf8)
        let newline = Data([13, 10]), headerEnd = newline + newline, nextPart = newline + separator
        guard data.starts(with: separator) else { throw invalid }
        var position = separator.count
        var parts: [String: Data] = [:]
        while !data[position...].starts(with: Data("--".utf8)) {
            guard parts.count < 2, data[position...].starts(with: newline),
                  let split = data.range(of: headerEnd, in: (position + newline.count)..<data.endIndex),
                  let headers = String(data: data[position..<split.lowerBound], encoding: .utf8),
                  let disposition = headers.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-disposition:") }),
                  let named = disposition.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("name=\"") && $0.hasSuffix("\"") }),
                  let end = data.range(of: nextPart, in: split.upperBound..<data.endIndex) else { throw invalid }
            let name = String(named.dropFirst(6).dropLast())
            guard parts[name] == nil else { throw invalid }
            parts[name] = data.subdata(in: split.upperBound..<end.lowerBound)
            position = end.upperBound
        }
        guard let metadata = parts.removeValue(forKey: "metadata"),
              var reply = try JSONSerialization.jsonObject(with: metadata) as? Object,
              let refs = reply["attachments"] as? [Object], refs.count == 1, let attachment = refs.first,
              attachment["path"] as? [String] == ["data"], attachment["codec"] as? String == "bytes",
              let name = attachment["part"] as? String, let bytes = parts[name],
              var result = reply["result"] as? Object, var value = result["value"] as? Object else { throw invalid }
        value["data"] = bytes; result["value"] = value; reply["result"] = result
        return reply
    }

    func rpcValue(_ method: String, args: Object, responseLimit: Int? = nil) async throws -> Any {
        try requireOpen()
        let rpcID = UUID().uuidString
        let envelope: Object = ["type": "client-request", "rpcId": rpcID, "method": method,
                                "payload": ["args": args]]
        var request = URLRequest(url: root.appending(path: "api/" + method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        request.httpBody = try JSONSerialization.data(withJSONObject: envelope)
        if (request.httpBody?.count ?? 0) > 100_000 { ImageTiming.log("json-encode", start: encodeStart, "\(method) bytes=\(request.httpBody?.count ?? 0)") }
        let netStart = DispatchTime.now().uptimeNanoseconds
        let (bytes, response): (Data, URLResponse)
        if let responseLimit {
            (bytes, response) = try await Self.boundedResponse(http, request, limit: responseLimit)
        } else { (bytes, response) = try await http.data(for: request) }
        if bytes.count > 100_000 || (request.httpBody?.count ?? 0) > 100_000 { ImageTiming.log("http", start: netStart, "\(method) in=\(bytes.count)") }
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        defer { if bytes.count > 100_000 { ImageTiming.log("json-decode", start: decodeStart, "\(method) bytes=\(bytes.count)") } }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw wire(.garbled, "rpc reply missing or malformed: " + method)
        }
        let reply: Object?
        if method == "workspaceFiles/readBytes", let type = http.value(forHTTPHeaderField: "Content-Type"), type.lowercased().hasPrefix("multipart/form-data;") {
            reply = try Self.byteEnvelope(bytes, contentType: type)
        } else { reply = try await Self.jsonReply(bytes) }
        guard reply?["rpcId"] as? String == rpcID, let result = reply?["result"] as? Object else {
            throw wire(.garbled, "rpc reply missing or malformed: " + method)
        }
        return try rpcResult(result, method: method)
    }

    // A session listing can be several MB. Decode it away from the main actor while the
    // drawer is closing and the new composer is taking keyboard input.
    private nonisolated static func jsonReply(_ data: Data) async throws -> Object? {
        try JSONSerialization.jsonObject(with: data) as? Object
    }

    private nonisolated static func boundedResponse(_ session: URLSession, _ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard response.expectedContentLength <= Int64(limit) else { throw HostError(String(localized: "内容太大，没能读取。")) }
        var body = Data()
        if response.expectedContentLength > 0 { body.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in stream {
            guard body.count < limit else { throw HostError(String(localized: "内容太大，没能读取。")) }
            body.append(byte)
        }
        return (body, response)
    }

    private func rpcResult(_ result: Object, method: String) throws -> Any {
        guard result["ok"] as? Bool == true else {
            let code = (result["error"] as? Object)?["code"] as? String ?? method
            // The code and the engine's wording stay in `code` and `detail`; pages that explain errors show the detail.
            throw HostError(HostError.Wire.refused.text(local: usesEmbeddedEngine), code: code, detail: (result["error"] as? Object)?["message"] as? String)
        }
        return result["value"] ?? NSNull()
    }
}

@MainActor
final class HarnessChannel {
    private weak var host: Harness?
    private let id: String
    private let items: Harness.Items
    fileprivate init(host: Harness, id: String, items: Harness.Items) {
        self.host = host; self.id = id; self.items = items
    }
    func next() async throws -> Object {
        var iterator = items.makeAsyncIterator()
        guard let item = try await iterator.next() else { throw HostError.wire(.lost, "stream closed", local: host?.usesEmbeddedEngine ?? false) }
        return item
    }
    func send(_ value: Object) async throws {
        guard let host else { throw HostError(String(localized: "连接已关闭。")) }
        try await host.sendFrame(["type": "item", "streamId": id, "value": value])
    }
    func cancel() { host?.cancelStream(id); host = nil }
}

/// What the Harness needs to offer for 导出对话日志: `GET /api/session.export?sessionId=…&includeDescendants=true`
/// with the host's session cookie, saved as `dsh-session-<id>.zip` in a temporary folder of its own.
protocol SessionLogExporting: AnyObject {
    func exportSessionLog(_ sessionID: String) async throws -> URL
}

extension Harness: SessionLogExporting {
    /// `GET /api/session.export?sessionId=…&includeDescendants=true`: the session and its
    /// subagents as a ZIP, over this host's authenticated HTTP session.
    func exportSessionLog(_ sessionID: String) async throws -> URL {
        try requireOpen()
        guard var parts = URLComponents(url: root.appending(path: "api/session.export"), resolvingAgainstBaseURL: false) else {
            throw HostError(String(localized: "主机地址无效。"))
        }
        parts.queryItems = [URLQueryItem(name: "sessionId", value: sessionID), URLQueryItem(name: "includeDescendants", value: "true")]
        guard let url = parts.url else { throw HostError(String(localized: "主机地址无效。")) }
        let (download, response) = try await http.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: download)
            throw HostError(String(localized: "没能导出对话（HTTP \(status)）。"), code: "session-export/http-\(status)")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let safe = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let file = folder.appending(path: "dsh-session-\(safe.isEmpty ? "export" : safe).zip")
        try FileManager.default.moveItem(at: download, to: file)
        return file
    }
}
