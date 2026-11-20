import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// The model's `lan_services` tool (Embedded/engine/lan.cjs): browse and resolve Bonjour services,
/// forward a loopback port to one, and publish a local server. Every request is a JSON
/// object with `action`; the answer is the JSON text the model reads.
@MainActor
final class LanServices {
    #if os(iOS)
    static let shared = LanServices()
    #endif

    /// The most items open at once.
    static let limit = 32

    /// Names a browse saw in this app run, for `connect` / `resolve` by name without `type`.
    private var seen: [String: LanService] = [:]
    private var items: [String: LanItem] = [:]
    private var order: [String] = []
    private var counter = 0
    #if os(iOS)
    private var inBackground = false

    /// Whether a service is published now. Pairing with siboot happens in Settings, so Pallas
    /// stays alive in the background while one is.
    var advertising: Bool { items.values.contains(where: \.isAdvertisement) }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LanServices.shared.inBackground = true }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LanServices.shared.foreground() }
        }
    }
    #endif

    struct Request: Decodable, Sendable {
        let lanRequest: UUID
        let args: Args
        let approval: String?
        struct Args: Decodable, Sendable {
            let action: String
            let type: String?
            let name: String?
            let domain: String?
            let host: String?
            let port: Int?
            let txt: [String]?
            let timeout: Double?
            let p2p_only: Bool?
            let category: String?
            let id: String?
            let all: Bool?
        }
    }

    typealias AuthorizeAdvertisement = (String, UInt16) async throws -> Void

    /// The answer text for one request; failures become `{ok:false, error:{code,message}}` too.
    func perform(_ args: Request.Args, authorizeAdvertisement: AuthorizeAdvertisement = { _, _ in }) async -> String {
        var envelope: [String: Any] = ["tool": "lan_services", "action": args.action,
                                       "timestamp": ISO8601DateFormatter().string(from: Date())]
        do {
            try Task.checkCancellation()
            envelope["data"] = try await run(args, authorizeAdvertisement: authorizeAdvertisement)
            envelope["ok"] = true
        } catch let error as LanError {
            envelope["ok"] = false
            envelope["error"] = ["code": error.code, "message": error.message]
        } catch is CancellationError {
            envelope["ok"] = false
            envelope["error"] = ["code": "cancelled", "message": "The request was cancelled."]
        } catch {
            envelope["ok"] = false
            envelope["error"] = ["code": "internal_error", "message": error.localizedDescription]
        }
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func run(_ args: Request.Args, authorizeAdvertisement: AuthorizeAdvertisement) async throws -> [String: Any] {
        switch args.action {
        case "types": return try types(category: args.category)
        case "browse": return try await browse(args)
        case "resolve": return try await resolve(args)
        case "connect": return try await connect(args)
        case "advertise": return try await advertise(args, authorize: authorizeAdvertisement)
        case "list": return list()
        case "stop": return try stop(args)
        default: throw LanError("invalid_args", "Unknown action. Use one of: types, browse, resolve, connect, advertise, list, stop.")
        }
    }

    // MARK: Arguments

    private func checkedType(_ raw: String?, tcpOnly: Bool) throws -> String {
        guard let raw else { throw LanError("invalid_args", "Pass type, for example _http._tcp. Call types to see the declared ones.") }
        let type = BonjourCatalog.normalize(raw)
        guard BonjourCatalog.wellFormed(type) else {
            throw LanError("invalid_args", "type must look like _name._tcp or _name._udp (letters, digits and -).")
        }
        guard BonjourCatalog.declared.contains(type) else {
            #if os(macOS)
            throw LanError("not_declared", "Pallas can only use its declared Bonjour types. Call types for the list.")
            #else
            throw LanError("not_declared", "iOS lets this app use only the Bonjour types it declares; \(type) is not one of them. Call types for the list.")
            #endif
        }
        if tcpOnly, type.hasSuffix("._udp") {
            throw LanError("invalid_args", "Only TCP services can be resolved, connected or advertised; \(type) is UDP and can only be browsed.")
        }
        return type
    }

    private func timeout(_ value: Double?, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard value > 0, value <= 60 else { throw LanError("invalid_args", "timeout must be more than 0 and at most 60 seconds.") }
        return value
    }

    private func checkedPort(_ value: Int?) throws -> UInt16 {
        guard let value, (1...65535).contains(value) else { throw LanError("invalid_args", "port must be 1–65535.") }
        return UInt16(value)
    }

    // MARK: types / browse

    private func types(category: String?) throws -> [String: Any] {
        let declared = BonjourCatalog.declared
        var entries: [[String: Any]] = declared.map { type in
            let entry = BonjourCatalog.entry(type)
            return ["type": type, "category": entry?.category ?? "other", "description": entry?.summary ?? "",
                    "declared": true, "browse_only": entry?.browseOnly ?? type.hasSuffix("._udp")]
        }
        var out: [String: Any] = ["source": "Info.plist NSBonjourServices", "restricted": true]
        if let category {
            let wanted = category.lowercased()
            guard BonjourCatalog.categories.contains(wanted) else {
                throw LanError("invalid_args", "Unknown category. Use one of: " + BonjourCatalog.categories.joined(separator: ", ") + ".")
            }
            entries = entries.filter { $0["category"] as? String == wanted }
            out["category"] = wanted
        }
        out["entries"] = entries
        out["types"] = entries.compactMap { $0["type"] }
        return out
    }

    private func browse(_ args: Request.Args) async throws -> [String: Any] {
        let type = try checkedType(args.type, tcpOnly: false)
        let seconds = try timeout(args.timeout, default: 3)
        let domain = args.domain ?? "local."
        let p2p = args.p2p_only ?? false
        let found = try await LanBrowse.browse(type: type, domain: domain, seconds: seconds, peerToPeerOnly: p2p)
        for service in found.services { seen[service.name] = service }
        var out: [String: Any] = [
            "type": type, "domain": domain, "count": found.services.count, "p2p_only": p2p, "waited_seconds": seconds,
            "services": found.services.map { service in
                ["name": service.name, "type": service.type, "domain": service.domain, "txt": service.txt,
                 "interfaces": service.interfaces.map(LanBrowse.describe)] as [String: Any]
            },
        ]
        if let warning = found.warning { out["warning"] = warning }
        return out
    }

    // MARK: Targets

    /// Where `connect` / `resolve` go, and how the model's answer names it.
    private struct Target {
        let endpoint: NWEndpoint
        let interface: NWInterface?
        let summary: [String: Any]
    }

    private func target(_ args: Request.Args) throws -> Target {
        let p2p = args.p2p_only ?? false
        // A blank host or port 0 is a field the caller left unused.
        let givenHost = args.host.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if givenHost != nil || (args.port ?? 0) != 0 {
            guard args.name == nil else { throw LanError("invalid_args", "Pass either name or host and port, not both.") }
            guard let host = givenHost?.trimmingCharacters(in: .whitespaces) else {
                throw LanError("invalid_args", "host and port go together.")
            }
            let port = try checkedPort(args.port)
            var interface: NWInterface?
            if p2p {
                interface = seen.values.lazy.flatMap(\.interfaces).first(where: LanBrowse.isPeerToPeer)
                guard interface != nil else { throw LanError("not_available", "No peer-to-peer (AWDL) link has been seen yet. Browse first.") }
            }
            return Target(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
                          interface: interface, summary: ["host": host, "port": Int(port)])
        }
        guard let name = args.name, !name.isEmpty else {
            throw LanError("invalid_args", "Pass name (a service from browse) or host and port.")
        }
        let domain = args.domain ?? "local."
        let type: String
        let known = seen[name]
        if let raw = args.type { type = try checkedType(raw, tcpOnly: true) }
        else if let known { type = try checkedType(known.type, tcpOnly: true) }
        else { throw LanError("invalid_args", "\(name) has not been seen by a browse in this app run. Browse first or pass type.") }
        var interface: NWInterface?
        if p2p {
            interface = known?.interfaces.first(where: LanBrowse.isPeerToPeer)
            guard interface != nil else { throw LanError("not_available", "\(name) has not been seen on a peer-to-peer (AWDL) link. Browse with p2p_only first.") }
        }
        return Target(endpoint: .service(name: name, type: type, domain: domain, interface: interface), interface: interface,
                      summary: ["service": name, "type": type, "domain": domain])
    }

    private func resolve(_ args: Request.Args) async throws -> [String: Any] {
        let target = try target(args)
        let seconds = try timeout(args.timeout, default: 5)
        let started = Date()
        let path = try await LanBrowse.connectOnce(to: target.endpoint, parameters: LanBrowse.tcp(interface: target.interface), seconds: seconds)
        return ["target": target.summary, "connected": true, "p2p_only": args.p2p_only ?? false,
                "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100, "path": LanBrowse.describe(path)]
    }

    // MARK: connect / advertise

    private func nextID(_ prefix: String) throws -> String {
        guard items.values.filter({ $0.state != .stopped }).count < Self.limit else {
            throw LanError("not_available", "At most \(Self.limit) forwards and advertisements can be open. Stop one first.")
        }
        counter += 1
        return prefix + "-" + String(counter)
    }

    private func connect(_ args: Request.Args) async throws -> [String: Any] {
        let target = try target(args)
        let id = try nextID("fwd")
        let item = LanItem.forward(id: id, target: target.endpoint, interface: target.interface, summary: target.summary,
                                   p2p: args.p2p_only ?? false)
        return try await start(item)
    }

    private func advertise(_ args: Request.Args, authorize: AuthorizeAdvertisement) async throws -> [String: Any] {
        if args.p2p_only == true { throw LanError("invalid_args", "advertise has no p2p_only: a published service is offered on every link.") }
        let type = try checkedType(args.type, tcpOnly: true)
        guard let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name.utf8.count <= 63 else {
            throw LanError("invalid_args", "name must be 1–63 bytes.")
        }
        let serverPort = try checkedPort(args.port)
        var txt: [String: String] = [:]
        for raw in args.txt ?? [] {
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty, raw.utf8.count <= 255,
                  first.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else {
                throw LanError("invalid_args", "Each txt entry is key=value, key printable ASCII without =, at most 255 bytes.")
            }
            let key = String(first)
            guard txt[key] == nil else { throw LanError("invalid_args", "txt has \(key) twice.") }
            txt[key] = parts.count > 1 ? String(parts[1]) : ""
        }
        try await authorize(name, serverPort)
        try Task.checkCancellation()
        let id = try nextID("adv")
        #if os(iOS)
        guard let hostPort = GuestForward.open(serverPort) else {
            throw LanError("not_available", "Linux is not running, or it refused the forward. Start the server with bash first (listening on 0.0.0.0:\(serverPort)), then advertise.")
        }
        #else
        let hostPort = serverPort
        #endif
        let item = LanItem.advertisement(id: id, type: type, name: name, txt: txt, guestPort: serverPort, hostPort: hostPort)
        let result = try await start(item)
        return result
    }

    private func start(_ item: LanItem) async throws -> [String: Any] {
        // Reserve the slot before starting so concurrent tool calls share the same limit.
        items[item.id] = item
        order.append(item.id)
        do {
            try await item.start()
            try Task.checkCancellation()
            guard items[item.id] === item else { throw CancellationError() }
            return item.report()
        } catch {
            remove([item.id])
            throw error
        }
    }

    // MARK: list / stop / lifecycle

    private func list() -> [String: Any] {
        let open = order.compactMap { items[$0] }
        var result: [String: Any] = ["advertisements": open.filter(\.isAdvertisement).map { $0.report() },
                                     "forwards": open.filter { !$0.isAdvertisement }.map { $0.report() },
                                     "declared_types": BonjourCatalog.declared]
        #if os(iOS)
        result["app_in_background"] = inBackground
        #endif
        return result
    }

    private func stop(_ args: Request.Args) throws -> [String: Any] {
        let ids: [String]
        if args.all == true { ids = order }
        else if let id = args.id {
            guard items[id] != nil else { throw LanError("invalid_args", "No open item \(id). Call list for the ids.") }
            ids = [id]
        } else { throw LanError("invalid_args", "Pass id, or all: true.") }
        remove(ids)
        return ["stopped": ids, "count": ids.count]
    }

    func close() {
        remove(order)
        seen.removeAll()
    }

    private func remove(_ ids: [String]) {
        for id in ids { items.removeValue(forKey: id)?.stop() }
        order.removeAll { ids.contains($0) }
    }

    #if os(iOS)
    /// iOS takes a suspended app's listeners: start the failed ones again.
    private func foreground() {
        inBackground = false
        for item in items.values where item.state == .failed && item.restartsOnForeground {
            Task { try? await item.start() }
        }
    }
    #endif
}

#if os(iOS)
/// Finds `dsh_guest_forward` in DshSystem (Embedded/native/guest.m), loaded once the engine runs.
enum GuestForward {
    private typealias Function = @convention(c) (UInt16, UInt16) -> UInt16
    private static var function: Function? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dsh_guest_forward") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }
    /// A loopback port QEMU forwards to `guestPort` in Linux, or nil.
    static func open(_ guestPort: UInt16) -> UInt16? {
        guard let port = function?(guestPort, 0), port != 0 else { return nil }
        return port
    }
    static func close(_ hostPort: UInt16) { _ = function?(0, hostPort) }
}
#endif

/// One open forward or advertisement: a listener and the connections it pipes.
@MainActor
final class LanItem {
    enum State: String { case starting, ready, failed, stopped }
    enum Kind {
        case forward(target: NWEndpoint, interface: NWInterface?, summary: [String: Any], p2p: Bool)
        case advertisement(type: String, name: String, txt: [String: String], serverPort: UInt16, hostPort: UInt16)
    }

    let id: String
    let kind: Kind
    private(set) var state = State.starting
    private(set) var failedReason: String?
    private var listener: NWListener?
    /// For a forward, the loopback port, kept across restarts.
    private var localPort: UInt16?
    private var registeredName: String?
    private var lastPath: NWPath?
    private var accepted = 0, failedConnections = 0
    private var lastError: String?
    private var open = Set<ObjectIdentifier>()
    private var pipes: [ObjectIdentifier: Splice] = [:]
    private var confirmed = false

    var isAdvertisement: Bool { if case .advertisement = kind { return true }; return false }
    var restartsOnForeground: Bool { state == .failed }

    private init(id: String, kind: Kind) { self.id = id; self.kind = kind }

    static func forward(id: String, target: NWEndpoint, interface: NWInterface?, summary: [String: Any], p2p: Bool) -> LanItem {
        LanItem(id: id, kind: .forward(target: target, interface: interface, summary: summary, p2p: p2p))
    }

    static func advertisement(id: String, type: String, name: String, txt: [String: String], guestPort serverPort: UInt16, hostPort: UInt16) -> LanItem {
        LanItem(id: id, kind: .advertisement(type: type, name: name, txt: txt, serverPort: serverPort, hostPort: hostPort))
    }

    /// Starts listening; answers once ready (advertisements: once registered, or after 8 s).
    func start() async throws {
        try Task.checkCancellation()
        listener?.cancel()
        state = .starting
        failedReason = nil
        registeredName = nil
        confirmed = false
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        switch kind {
        case .forward:
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: localPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        case .advertisement:
            parameters.includePeerToPeer = true
        }
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { fail("could not create the listener: \(error)"); throw LanError("not_available", "The listener could not start: \(error).") }
        self.listener = listener
        if case let .advertisement(type, name, txt, _, _) = kind {
            listener.service = NWListener.Service(name: name, type: type, domain: nil, txtRecord: NWTXTRecord(txt))
            listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
                guard case let .add(endpoint) = change, case let .service(registered, _, _, _) = endpoint else { return }
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    self.registeredName = registered
                    self.confirmed = true
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] inbound in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { inbound.cancel(); return }
                self.accept(inbound)
            }
        }
        let once = Once<Void>()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .cancelled = state { once.finish(.failure(CancellationError())) }
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.state = .ready
                    if let port = listener.port?.rawValue, case .forward = self.kind { self.localPort = port }
                    once.finish(.success(()))
                case .failed(let error):
                    once.finish(.failure(LanBrowse.refusal(error) ?? LanError("not_available", "The listener failed: \(error.debugDescription).")))
                    self.fail(error.debugDescription)
                case .waiting(let error):
                    if let denied = LanBrowse.refusal(error) {
                        once.finish(.failure(denied))
                        self.fail("local network access denied")
                    }
                case .cancelled:
                    if self.state != .stopped && self.state != .failed { self.fail("the listener was closed") }
                default: break
                }
            }
        }
        listener.start(queue: LanQueue.queue)
        LanQueue.queue.asyncAfter(deadline: .now() + 10) {
            once.finish(.failure(LanError("not_available", "The listener did not start within 10 seconds.")))
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { once.set($0) }
        } onCancel: {
            once.finish(.failure(CancellationError()))
            listener.cancel()
        }
        if isAdvertisement {
            for _ in 0..<80 where !confirmed {
                guard self.listener === listener else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(100))
            }
            #if os(macOS)
            guard confirmed else { throw LanError("not_available", "Bonjour did not confirm the advertisement.") }
            #endif
        }
    }

    private func fail(_ reason: String) {
        guard state != .stopped else { return }
        state = .failed
        failedReason = reason
        listener?.cancel()
        listener = nil
    }

    func stop() {
        state = .stopped
        listener?.cancel()
        listener = nil
        for pipe in pipes.values { pipe.cancel() }
        pipes.removeAll()
        #if os(iOS)
        if case let .advertisement(_, _, _, _, hostPort) = kind { GuestForward.close(hostPort) }
        #endif
    }

    private func accept(_ inbound: NWConnection) {
        guard state == .ready else { inbound.cancel(); return }
        accepted += 1
        let outbound: NWConnection
        switch kind {
        case let .forward(target, interface, _, _):
            outbound = NWConnection(to: target, using: LanBrowse.tcp(interface: interface))
        case let .advertisement(_, _, _, _, hostPort):
            #if os(macOS)
            let host: NWEndpoint.Host = "localhost"
            #else
            let host: NWEndpoint.Host = .ipv4(.loopback)
            #endif
            outbound = NWConnection(to: .hostPort(host: host, port: NWEndpoint.Port(rawValue: hostPort)!), using: .tcp)
        }
        let pipe = Splice(inbound, outbound)
        let key = ObjectIdentifier(pipe)
        pipes[key] = pipe
        pipe.start { [weak self] path in
            Task { @MainActor in if let path { self?.lastPath = path } }
        } ended: { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                self.pipes.removeValue(forKey: key)
                if let failure { self.failedConnections += 1; self.lastError = failure }
            }
        }
    }

    func report() -> [String: Any] {
        var out: [String: Any] = ["id": id, "state": state.rawValue, "accepted": accepted,
                                  "open_connections": pipes.count, "failed_connections": failedConnections]
        switch kind {
        case let .forward(_, _, summary, p2p):
            out["kind"] = "connect"
            out["target"] = summary
            out["p2p_only"] = p2p
            if let localPort {
                out["local_port"] = Int(localPort)
                out["address"] = "127.0.0.1:\(localPort)"
                #if os(iOS)
                // Linux reaches the phone's loopback through QEMU's gateway.
                out["linux_address"] = "10.0.2.2:\(localPort)"
                #endif
            }
            if let lastPath { out["last_path"] = LanBrowse.describe(lastPath) }
        case let .advertisement(type, name, txt, serverPort, hostPort):
            out["kind"] = "advertise"
            out["type"] = type
            out["requested_name"] = name
            out["name"] = registeredName ?? name
            #if os(iOS)
            out["guest_port"] = Int(serverPort)
            out["host_port"] = Int(hostPort)
            #else
            out["server_port"] = Int(serverPort)
            #endif
            out["txt"] = txt
            if let port = listener?.port?.rawValue { out["listener_port"] = Int(port) }
            if state == .ready && !confirmed { out["warning"] = "registration not confirmed within 8 seconds" }
        }
        if let lastError { out["last_error"] = lastError }
        if state == .failed {
            out["failed_reason"] = failedReason ?? "unknown"
            #if os(iOS)
            out["restarts_on_foreground"] = restartsOnForeground
            #endif
        }
        return out
    }
}

/// Copies bytes both ways between two connections until both sides have finished.
final class Splice: @unchecked Sendable {
    private let a: NWConnection, b: NWConnection
    private let lock = NSLock()
    private var finished = 0
    private var over = false
    private var failed = false
    private var ended: ((String?) -> Void)?

    init(_ a: NWConnection, _ b: NWConnection) { self.a = a; self.b = b }

    /// `ended` gets nil on a clean close, else what failed.
    func start(path: @escaping (NWPath?) -> Void, ended: @escaping (String?) -> Void) {
        self.ended = ended
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                path(self.b.currentPath)
                self.a.start(queue: LanQueue.queue)
                self.pump(self.a, self.b)
                self.pump(self.b, self.a)
            case .failed(let error): self.end("target: \(error.debugDescription)")
            case .cancelled: self.end(nil)
            case .waiting(let error): self.end("target: \(error.debugDescription)")
            default: break
            }
        }
        a.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.end("client: \(error.debugDescription)") }
        }
        b.start(queue: LanQueue.queue)
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sent in
                    if let sent { self.end("send: \(sent.debugDescription)") }
                    else if complete { self.half(to) }
                    else { self.pump(from, to) }
                })
            } else if let error { self.end("receive: \(error.debugDescription)") }
            else if complete { self.half(to) }
            else { self.pump(from, to) }
        }
    }

    /// One direction is done: pass the end on, and close once both are.
    private func half(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        lock.lock(); finished += 1; let both = finished >= 2; lock.unlock()
        if both { end(nil) }
    }

    private func end(_ failure: String?) {
        lock.lock()
        guard !over else { lock.unlock(); return }
        over = true
        let callback = ended
        ended = nil
        lock.unlock()
        a.cancel(); b.cancel()
        callback?(failure)
    }

    func cancel() { end(nil) }
}
