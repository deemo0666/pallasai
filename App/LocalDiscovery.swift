import Foundation
import Network

// Bonjour (mDNS / DNS-SD) for the app and for the model. Programs in the Linux guest and the
// engine only have plain sockets, and iOS lets no app send multicast without an entitlement
// Apple grants on request, so the app does the Bonjour work with Network.framework and hands
// out plain TCP on loopback: 127.0.0.1:<port> for the engine, 10.0.2.2:<port> inside Linux.

/// The service types this build may browse and publish. iOS accepts only those in Info.plist
/// `NSBonjourServices`; `entries` describes each for the model.
enum BonjourCatalog {
    struct Entry { let type: String; let category: String; let summary: String; let browseOnly: Bool }

    /// Computers running the Pallas Agent pairing plugin (`Tools/HostPairing/advertise.js`).
    static let pallasHost = "_pallas-host._tcp"

    static let entries: [Entry] = [
        .init(type: "_pallas-host._tcp", category: "pallas", summary: "Computers running DSH with the Pallas Agent pairing plugin", browseOnly: false),
        .init(type: "_pallas-peer._tcp", category: "pallas", summary: "Other phones and iPads running Pallas Agent nearby", browseOnly: true),
        .init(type: "_ictrl._tcp", category: "remote-control", summary: "Remote-control services (iControl and similar)", browseOnly: false),
        .init(type: "_remotepairing-pairable-host._tcp", category: "apple-devices", summary: "Apple devices ready to pair for remote development", browseOnly: false),
        .init(type: "_remotepairing._tcp", category: "apple-devices", summary: "Paired Apple devices offering remote development services", browseOnly: false),
        .init(type: "_remoted._tcp", category: "apple-devices", summary: "Apple remote device services", browseOnly: false),
        .init(type: "_hap._tcp", category: "smart-home", summary: "HomeKit accessories on IP", browseOnly: false),
        .init(type: "_matter._tcp", category: "smart-home", summary: "Commissioned Matter devices", browseOnly: false),
        .init(type: "_matterc._udp", category: "smart-home", summary: "Matter devices waiting to be commissioned", browseOnly: true),
        .init(type: "_hue._tcp", category: "smart-home", summary: "Philips Hue bridges", browseOnly: false),
        .init(type: "_airplay._tcp", category: "media", summary: "AirPlay receivers (Apple TV, smart TVs, speakers)", browseOnly: false),
        .init(type: "_googlecast._tcp", category: "media", summary: "Google Cast devices", browseOnly: false),
        .init(type: "_raop._tcp", category: "media", summary: "AirPlay audio receivers", browseOnly: false),
        .init(type: "_spotify-connect._tcp", category: "media", summary: "Spotify Connect speakers", browseOnly: false),
        .init(type: "_daap._tcp", category: "media", summary: "Shared music libraries (DAAP)", browseOnly: false),
        .init(type: "_dpap._tcp", category: "media", summary: "Shared photo libraries (DPAP)", browseOnly: false),
        .init(type: "_companion-link._tcp", category: "media", summary: "Apple devices offering Companion Link (remote, handoff)", browseOnly: false),
        .init(type: "_ipp._tcp", category: "printing", summary: "IPP printers", browseOnly: false),
        .init(type: "_ipps._tcp", category: "printing", summary: "IPP printers over TLS", browseOnly: false),
        .init(type: "_printer._tcp", category: "printing", summary: "LPD printers", browseOnly: false),
        .init(type: "_uscan._tcp", category: "printing", summary: "eSCL scanners", browseOnly: false),
        .init(type: "_scanner._tcp", category: "printing", summary: "Network scanners", browseOnly: false),
        .init(type: "_smb._tcp", category: "file-sharing", summary: "SMB file shares (Windows, macOS, NAS)", browseOnly: false),
        .init(type: "_afpovertcp._tcp", category: "file-sharing", summary: "AFP file shares", browseOnly: false),
        .init(type: "_nfs._tcp", category: "file-sharing", summary: "NFS exports", browseOnly: false),
        .init(type: "_webdav._tcp", category: "file-sharing", summary: "WebDAV servers", browseOnly: false),
        .init(type: "_http._tcp", category: "general", summary: "Web servers and device admin pages", browseOnly: false),
        .init(type: "_https._tcp", category: "general", summary: "Web servers over TLS", browseOnly: false),
        .init(type: "_ssh._tcp", category: "general", summary: "SSH servers", browseOnly: false),
        .init(type: "_sftp-ssh._tcp", category: "general", summary: "SFTP servers", browseOnly: false),
        .init(type: "_workstation._tcp", category: "general", summary: "Computers announcing themselves on the network", browseOnly: false),
    ]

    static var categories: [String] { Array(Set(entries.map(\.category))).sorted() + ["other"] }

    /// What Info.plist declares, in its order.
    static var declared: [String] {
        ((Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]) ?? []).map(normalize)
    }

    static func normalize(_ type: String) -> String {
        var text = type.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `_name._tcp` or `_name._udp`, name 1–62 letters, digits or `-`, not starting or ending with `-`.
    static func wellFormed(_ type: String) -> Bool {
        type.range(of: #"^_[a-z0-9]([a-z0-9-]{0,60}[a-z0-9])?\._(tcp|udp)$"#, options: .regularExpression) != nil
    }

    static func entry(_ type: String) -> Entry? { entries.first { $0.type == type } }
}

/// A failure the model reads: a fixed code and an English sentence that says what to do next.
struct LanError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// One service a browse saw.
struct LanService: Sendable {
    let name: String
    let type: String
    let domain: String
    let txt: [String: String]
    let interfaces: [NWInterface]
    let endpoint: NWEndpoint
}

enum LanBrowse {
    static func isPeerToPeer(_ interface: NWInterface) -> Bool {
        interface.name.hasPrefix("awdl") || interface.name.hasPrefix("llw")
    }

    static func describe(_ interface: NWInterface) -> [String: Any] {
        let kind: String
        switch interface.type {
        case .wifi: kind = "wifi"
        case .wiredEthernet: kind = "wired"
        case .cellular: kind = "cellular"
        case .loopback: kind = "loopback"
        case .other: kind = "other"
        @unknown default: kind = "unknown"
        }
        return ["name": interface.name, "type": kind, "peer_to_peer": isPeerToPeer(interface)]
    }

    /// Why Network.framework refused, as the model's error code.
    static func refusal(_ error: NWError, path: NWPath? = nil) -> LanError? {
        var denied = path?.unsatisfiedReason == .localNetworkDenied
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            denied = true
        }
        guard denied else { return nil }
        #if os(macOS)
        return LanError("authorization_denied", "macOS denied local network access. Ask the user to allow Pallas Agent under System Settings › Privacy & Security › Local Network, then try again.")
        #else
        return LanError("authorization_denied", "iOS denied local network access. Ask the user to allow Pallas Agent under Settings › Privacy & Security › Local Network, then try again.")
        #endif
    }

    /// Everything seen on `type` within `seconds`, sorted by name.
    static func browse(type: String, domain: String = "local.", seconds: Double, peerToPeerOnly: Bool = false) async throws -> (services: [LanService], warning: String?) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: domain), using: parameters)
        let once = Once<(services: [LanService], warning: String?)>()
        var warning: String?
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error):
                        once.finish(.failure(refusal(error) ?? LanError("not_available", "Browsing failed: \(error.debugDescription).")))
                        browser.cancel()
                    case .waiting(let error):
                        if let denied = refusal(error) { once.finish(.failure(denied)); browser.cancel() }
                        else { warning = "browser reported: \(error.debugDescription)" }
                    default: break
                    }
                }
                browser.start(queue: LanQueue.queue)
                LanQueue.queue.asyncAfter(deadline: .now() + seconds) {
                    let services = browser.browseResults.compactMap { result -> LanService? in
                        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                        var txt: [String: String] = [:]
                        if case let .bonjour(record) = result.metadata {
                            for (key, entry) in record.dictionary { txt[key] = entry }
                        }
                        let interfaces = Array(result.interfaces)
                        if peerToPeerOnly && !interfaces.contains(where: isPeerToPeer) { return nil }
                        return LanService(name: name, type: type, domain: domain, txt: txt, interfaces: interfaces, endpoint: result.endpoint)
                    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    once.finish(.success((services, warning)))
                    browser.cancel()
                }
            }
        } onCancel: {
            browser.cancel()
            once.finish(.failure(CancellationError()))
        }
    }

    /// TCP parameters for reaching a found service, pinned to `interface` when given.
    static func tcp(interface: NWInterface? = nil, ipv4: Bool = false) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let interface { parameters.requiredInterface = interface }
        if ipv4, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        return parameters
    }

    /// Connects once and reports the path, then closes again.
    static func connectOnce(to endpoint: NWEndpoint, parameters: NWParameters, seconds: Double) async throws -> NWPath {
        let connection = NWConnection(to: endpoint, using: parameters)
        let once = Once<NWPath>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let path = connection.currentPath { once.finish(.success(path)) }
                        else { once.finish(.failure(LanError("not_available", "The connection opened without a path."))) }
                        connection.cancel()
                    case .failed(let error):
                        once.finish(.failure(refusal(error, path: connection.currentPath) ?? LanError("not_available", "The connection failed: \(error.debugDescription).")))
                        connection.cancel()
                    case .waiting(let error):
                        if let denied = refusal(error, path: connection.currentPath) { once.finish(.failure(denied)); connection.cancel() }
                    default: break
                    }
                }
                connection.start(queue: LanQueue.queue)
                LanQueue.queue.asyncAfter(deadline: .now() + seconds) {
                    once.finish(.failure(LanError("not_available", "No connection within \(Int(seconds)) seconds.")))
                    connection.cancel()
                }
            }
        } onCancel: {
            connection.cancel()
            once.finish(.failure(CancellationError()))
        }
    }

    static func describe(_ path: NWPath) -> [String: Any] {
        var out: [String: Any] = [:]
        if let remote = path.remoteEndpoint { out["remote"] = "\(remote)" }
        if let local = path.localEndpoint { out["local"] = "\(local)" }
        let used = path.availableInterfaces.first
        if let used { out["interface"] = used.name }
        out["uses_peer_to_peer"] = used.map(isPeerToPeer) ?? false
        out["interfaces"] = path.availableInterfaces.map(describe)
        return out
    }
}

enum LanQueue { static let queue = DispatchQueue(label: "lan.bonjour") }

/// Resumes a continuation exactly once, whichever callback gets there first.
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early { lock.unlock(); continuation.resume(with: early); return }
        self.continuation = continuation
        lock.unlock()
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard early == nil else { lock.unlock(); return }
        early = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

// MARK: - Computers running the pairing plugin

/// A computer the pairing plugin publishes on this network.
struct PallasHost: Identifiable, Equatable {
    let name: String
    /// Its SSH host key fingerprint, as a pairing code carries it.
    let pin: String
    var id: String { pin }
}

enum PallasHostFinder {
    /// Computers that answer `_pallas-host._tcp` now. Empty when local network access is off.
    static func find(seconds: Double = 2) async -> [PallasHost] { await look(seconds: seconds).hosts }

    /// The same, and whether iOS refused the search because 本地网络 is off for this app.
    static func look(seconds: Double = 2) async -> (hosts: [PallasHost], denied: Bool) {
        let found: (services: [LanService], warning: String?)
        do { found = try await LanBrowse.browse(type: BonjourCatalog.pallasHost, seconds: seconds) }
        catch { return ([], (error as? LanError)?.code == "authorization_denied") }
        var seen = Set<String>()
        let hosts = found.services.compactMap { service -> PallasHost? in
            guard service.txt["v"] == "1", let pin = service.txt["pin"], !pin.isEmpty, seen.insert(pin).inserted else { return nil }
            return PallasHost(name: service.name, pin: pin)
        }
        return (hosts, false)
    }

    /// The IPv4 address and port where the computer with this host key answers now, if it is on this network.
    static func locate(pin: String, seconds: Double = 2.5) async -> (address: String, port: Int)? {
        guard let found = try? await LanBrowse.browse(type: BonjourCatalog.pallasHost, seconds: seconds) else { return nil }
        for service in found.services where service.txt["pin"] == pin {
            guard let path = try? await LanBrowse.connectOnce(to: service.endpoint, parameters: LanBrowse.tcp(ipv4: true), seconds: 4),
                  case let .hostPort(host, port)? = path.remoteEndpoint, case let .ipv4(address) = host else { continue }
            return (address.rawValue.map(String.init).joined(separator: "."), Int(port.rawValue))
        }
        return nil
    }
}
