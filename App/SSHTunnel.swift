@preconcurrency import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH

private struct PinnedKey: NIOSSHClientServerAuthenticationDelegate {
    let digest: String
    var checked: ((Bool) -> Void)? = nil
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fields = String(openSSHPublicKey: hostKey).split(separator: " ")
        if fields.count > 1, let bytes = Data(base64Encoded: String(fields[1])) {
            let actual = Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            if actual == digest { checked?(true); validationCompletePromise.succeed(()); return }
        }
        checked?(false)
        validationCompletePromise.fail(HostError(String(localized: "主机指纹和上次不一致，已断开"), code: "ssh/host-key-changed"))
    }
}

/// Reads the key a server presents and stops before any credential is sent.
private final class CapturedKey: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SSHHostKey?
    var value: SSHHostKey? { lock.withLock { key } }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = SSHHostKey(hostKey)
        lock.withLock { key = presented }
        validationCompletePromise.fail(HostError(String(localized: "已读到主机指纹。")))
    }
}

/// A server's host key as shown here: the type (ED25519, RSA, ECDSA) and
/// the OpenSSH fingerprint (`SHA256:…`, as `ssh-keygen -lf` prints it).
struct SSHHostKey: Equatable {
    let type: String
    let fingerprint: String

    init(type: String, fingerprint: String) { self.type = type; self.fingerprint = fingerprint }

    init?(_ key: NIOSSHPublicKey) {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        guard fields.count > 1, let bytes = Data(base64Encoded: String(fields[1])) else { return nil }
        let algorithm = String(fields[0])
        type = algorithm.contains("ed25519") ? "ED25519" : algorithm.contains("rsa") ? "RSA" : algorithm.contains("ecdsa") ? "ECDSA" : algorithm.uppercased()
        fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// The file `ssh-keygen -lf` reads on the server for this type.
    var publicFile: String {
        switch type {
        case "RSA": "ssh_host_rsa_key.pub"
        case "ECDSA": "ssh_host_ecdsa_key.pub"
        default: "ssh_host_ed25519_key.pub"
        }
    }
}

private final class ForwardBytes: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    init(to peer: Channel) { self.peer = peer }
    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let local = context.channel
        peer.writeAndFlush(unwrapInboundIn(data)).whenComplete { result in
            switch result {
            // Next loop turn: a write that completes at once would otherwise read the next pending
            // SSH frame inside this call, one level deeper per frame, until a burst (a screenshot
            // in the stream) overflows the event loop's stack.
            case .success: local.eventLoop.execute { local.read() }
            case .failure: local.close(promise: nil)
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

struct HostProfile: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case ssh, paired }
    var id = UUID()
    var kind = Kind.ssh
    var name = ""
    var address = ""
    var port = 22
    var username = ""
    var fingerprint = ""
    var connectionMethod: String { kind == .paired ? String(localized: "扫码配对") : String(localized: "手动 SSH") }
    var harnessPort = 3080
    /// The pinned key's type (ED25519, RSA, ECDSA), when it was confirmed on this phone.
    var hostKeyType: String?
    /// Set when this phone starts DSH over SSH (`SSHLaunch.start`); nil connects to a running `dsh web`.
    var launchCommand: String?
    var workingDirectory: String?
    /// Where a paired computer also answered on an older version: its tailnet address alone. Read when `alternateAddresses` is nil.
    var alternateAddress: String?
    /// The paired computer's other addresses (other LANs, its tailnet), from its pairing code or its last connection.
    var alternateAddresses: [String]?

    /// Every address this computer may answer on, the saved one first.
    var addresses: [String] { [address] + (alternateAddresses ?? alternateAddress.map { [$0] } ?? []) }

    /// A paired computer Bonjour found at a new address: connect there first from now on.
    static func moved(to address: String, port: Int, for id: UUID) {
        guard let stored = UserDefaults.standard.data(forKey: "hostProfiles"),
              var hosts = try? JSONDecoder().decode([HostProfile].self, from: stored),
              let index = hosts.firstIndex(where: { $0.id == id && $0.kind == .paired }) else { return }
        hosts[index].alternateAddresses = hosts[index].addresses.filter { $0 != address && PairedReach.isTailnet($0) }
        hosts[index].alternateAddress = nil
        hosts[index].address = address
        hosts[index].port = port
        if let saved = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(saved, forKey: "hostProfiles") }
    }

    /// Keeps the addresses a paired computer reported, so a later connection can use whichever answers.
    static func remember(addresses reported: [String], for id: UUID) {
        guard let stored = UserDefaults.standard.data(forKey: "hostProfiles"),
              var hosts = try? JSONDecoder().decode([HostProfile].self, from: stored),
              let index = hosts.firstIndex(where: { $0.id == id && $0.kind == .paired }) else { return }
        let others = PairedReach.valid(reported).filter { $0 != hosts[index].address }
        guard !others.isEmpty, hosts[index].alternateAddresses != others else { return }
        hosts[index].alternateAddresses = others
        if let saved = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(saved, forKey: "hostProfiles") }
    }
}

/// Which of a paired computer's addresses answers now. All are tried at once; the first in order (LAN
/// before tailnet) that accepts a connection wins, without waiting for the ones after it to time out.
enum PairedReach {
    /// IPv4 literals only, each once.
    static func valid(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { address in
            let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
            return pieces.count == 4 && pieces.allSatisfy { part in
                guard let byte = UInt8(part) else { return false }
                return String(byte) == part
            } && seen.insert(address).inserted
        }
    }

    static func isTailnet(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// LAN addresses first (in the given order), then tailnet ones: home Wi-Fi is faster than the detour.
    static func ordered(_ addresses: [String]) -> [String] {
        let unique = valid(addresses)
        return unique.filter { !isTailnet($0) } + unique.filter(isTailnet)
    }

    /// The preferred address that answers on `port`, or nil when none does within `timeout`.
    /// A single address is returned unchecked unless `checkingOne`.
    static func pick(_ addresses: [String], port: Int, timeout: TimeAmount = .seconds(4), checkingOne: Bool = false) async -> String? {
        guard !addresses.isEmpty else { return nil }
        guard addresses.count > 1 || checkingOne else { return addresses.first }
        let race = Race(addresses)
        return await withCheckedContinuation { continuation in
            race.start(continuation)
            for (index, address) in addresses.enumerated() {
                Task.detached { race.record(index, await answers(address, port: port, timeout: timeout)) }
            }
        }
    }

    private static func answers(_ host: String, port: Int, timeout: TimeAmount) async -> Bool {
        guard let channel = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout).connect(host: host, port: port).get() else { return false }
        try? await channel.close()
        return true
    }

    private final class Race: @unchecked Sendable {
        private let addresses: [String]
        private var results: [Bool?]
        private var continuation: CheckedContinuation<String?, Never>?
        private let lock = NSLock()
        init(_ addresses: [String]) { self.addresses = addresses; results = Array(repeating: nil, count: addresses.count) }
        func start(_ continuation: CheckedContinuation<String?, Never>) { lock.withLock { self.continuation = continuation } }
        func record(_ index: Int, _ answered: Bool) {
            lock.withLock {
                results[index] = answered
                guard let continuation else { return }
                // The first address still possible: answered → it wins; unknown → wait; none left → nil.
                if let first = results.firstIndex(where: { $0 != false }) {
                    guard results[first] == true else { return }
                    continuation.resume(returning: addresses[first])
                } else {
                    continuation.resume(returning: nil)
                }
                self.continuation = nil
            }
        }
    }
}

final class SSHTunnel {
    let client: SSHClient
    let listener: Channel
    let address: String
    let token: String
    /// Where a paired computer said it answers, in its order of preference; empty for a manual SSH host.
    private(set) var reportedAddresses: [String] = []
    private init(client: SSHClient, listener: Channel, token: String, port: Int) {
        self.client = client
        self.listener = listener
        self.token = token
        address = "http://127.0.0.1:" + String(port)
    }

    /// A single-use key from a paired computer for this phone to join its Pallas mesh.
    func meshInvite() async throws -> (controlURL: String, authKey: String) {
        let output = try await RemoteDSH.withTimeout(client, seconds: 40) {
            try await self.client.executeCommand("sh -lc 'dsh-local-mesh-invite'", maxResponseSize: 4096)
        }
        let reply = try JSONSerialization.jsonObject(with: Data(output.readableBytesView)) as? [String: Any]
        guard let url = reply?["controlURL"] as? String, let key = reply?["authKey"] as? String else {
            throw HostError(String(localized: "这台电脑暂时不能开通在外面连接。"), code: reply?["error"] as? String ?? "mesh")
        }
        return (url, key)
    }

    func close() async {
        try? await listener.close()
        try? await client.close()
    }

    /// Logs in, finds (or, by the profile or [ask], starts) DSH on the host and
    /// forwards a local port to it. Each stage goes to `SSHReports` for 网络详情.
    static func open(_ profile: HostProfile, secret: String, passphrase: String, token: String, invite: String? = nil,
                     ask: (@Sendable (SSHLaunchQuestion) async -> Bool)? = nil) async throws -> SSHTunnel {
        let report = SSHReportRecorder(profile)
        do { return try await open(profile, secret: secret, passphrase: passphrase, token: token, invite: invite, ask: ask, report: report) }
        catch { throw report.fail(error) }
    }

    /// A logged-in SSH connection to a saved computer and nothing else: Pallas on a paired computer
    /// also answers the Claude desktop bridge (`pallas-claude`, see ClaudeDesktop) on it.
    static func client(_ profile: HostProfile, secret: String, passphrase: String) async throws -> SSHClient {
        let report = SSHReportRecorder(profile)
        do {
            let client = try await connect(profile, secret: secret, passphrase: passphrase, invite: nil, report: report)
            report.succeed(detail: nil)
            return client
        } catch { throw report.fail(error) }
    }

    /// Logs in on the preferred address that answers, with the pinned host key.
    private static func connect(_ profile: HostProfile, secret: String, passphrase: String, invite: String?,
                                report: SSHReportRecorder) async throws -> SSHClient {
        let auth: SSHAuthenticationMethod
        var secondAuth: SSHAuthenticationMethod?
        let login: String
        if profile.kind == .paired {
            guard let bytes = Data(base64Encoded: secret) else { throw HostError(String(localized: "无法读取设备身份。")) }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            let user = invite.map { "pair-" + $0 } ?? profile.username
            auth = .ed25519(username: user, privateKey: key)
            if invite == nil { secondAuth = .ed25519(username: user, privateKey: key) }
            login = String(localized: "设备身份 · Ed25519")
        } else if SSHUserKey.looksLikePrivateKey(secret) {
            let key: SSHUserKey
            do { key = try SSHUserKey.parse(secret, passphrase: passphrase) } catch { report.enter(.login); throw error }
            auth = key.authentication(username: profile.username)
            login = String(localized: "私钥 · ") + key.label + (key.label.hasPrefix("RSA") ? String(localized: "（rsa-sha2-512 / 256）") : "") + " · " + key.fingerprint
        } else {
            auth = .passwordBased(username: profile.username, password: secret)
            login = String(localized: "密码")
        }
        report.set { $0.login = login }
        let pin = profile.fingerprint.hasPrefix("SHA256:") ? String(profile.fingerprint.dropFirst(7)) : profile.fingerprint
        guard !pin.isEmpty, !profile.address.isEmpty, (1...65535).contains(profile.port) else { throw HostError(String(localized: "还没有确认主机指纹")) }
        let validator = PinnedKey(digest: pin) { same in
            report.advance(to: .hostKey)
            if same { report.advance(to: .login, detail: String(localized: "与记住的指纹一致")) }
        }
        // A paired computer answers on several addresses (LAN, tailnet): use the preferred one that answers now.
        var hosts = [profile.address]
        var sshPort = profile.port
        var relocation: (address: String, port: Int)?
        if profile.kind == .paired {
            hosts = PairedReach.ordered(profile.addresses)
            if hosts.isEmpty { hosts = [profile.address] }
            // A pairing code was just read, so its addresses are current; otherwise check even a single one,
            // because a computer that moved is found again by Bonjour (same host key, checked below).
            if let best = await PairedReach.pick(hosts, port: profile.port, checkingOne: invite == nil) {
                hosts = [best] + hosts.filter { $0 != best }
            } else if invite == nil, let moved = await PallasHostFinder.locate(pin: pin) {
                hosts = [moved.address] + hosts.filter { $0 != moved.address }
                sshPort = moved.port
                relocation = moved
            }
            if hosts[0] != profile.address || sshPort != profile.port {
                report.set { $0.sshEndpoint = (profile.username.isEmpty ? "" : profile.username + "@") + hosts[0] + ":" + String(sshPort) }
            }
        }
        let client: SSHClient
        var authenticated = hosts[0]
        do {
            client = try await SSHClient.connect(host: hosts[0], port: sshPort, authenticationMethod: auth,
                                                 hostKeyValidator: .custom(validator), reconnect: .never, connectTimeout: .seconds(10))
        } catch {
            // The next address, same pinned key and device identity (a pairing invite is used once, so not then).
            guard hosts.count > 1, let secondAuth, !Task.isCancelled else { throw error }
            let other = hosts[1]
            let otherPort = profile.port
            authenticated = other
            report.enter(.connect)
            report.set { $0.sshEndpoint = (profile.username.isEmpty ? "" : profile.username + "@") + other + ":" + String(otherPort) }
            client = try await SSHClient.connect(host: other, port: otherPort, authenticationMethod: secondAuth,
                                                 hostKeyValidator: .custom(validator), reconnect: .never, connectTimeout: .seconds(10))
        }
        if Task.isCancelled { try? await client.close(); throw CancellationError() }
        if let relocation, authenticated == relocation.address {
            HostProfile.moved(to: relocation.address, port: relocation.port, for: profile.id)
        }
        return client
    }

    private static func open(_ profile: HostProfile, secret: String, passphrase: String, token: String, invite: String?,
                             ask: (@Sendable (SSHLaunchQuestion) async -> Bool)?, report: SSHReportRecorder) async throws -> SSHTunnel {
        let client = try await connect(profile, secret: secret, passphrase: passphrase, invite: invite, report: report)
        report.advance(to: .probe, detail: profile.username.isEmpty ? nil : String(localized: "用户 ") + profile.username)
        do {
            var target = profile.harnessPort
            var credential = token
            var reported: [String] = []
            if profile.kind == .paired {
                let output = try await RemoteDSH.withTimeout(client, seconds: 20) {
                    try await client.executeCommand("sh -lc 'dsh-local-endpoint'", maxResponseSize: 8192)
                }
                let endpoint = try JSONSerialization.jsonObject(with: Data(output.readableBytesView)) as? Object
                guard let port = endpoint?["port"] as? Int, let issued = endpoint?["token"] as? String, !issued.isEmpty
                else { throw HostError(String(localized: "电脑没有给出可用的入口。")) }
                target = port
                credential = issued
                if let addresses = endpoint?["addresses"] as? [String] { reported = PairedReach.valid(addresses) }
                else if let other = endpoint?["alternate"] as? String { reported = PairedReach.valid([profile.address, other]) }
                HostProfile.remember(addresses: reported, for: profile.id)
                report.skip(.launch, detail: String(localized: "由配对的电脑提供入口"))
                report.set { $0.outcome = String(localized: "配对电脑上的 Pallas 服务") }
            } else {
                let found = try await resolveDSH(client, profile: profile, ask: ask, report: report)
                target = found.port
                credential = found.token ?? token
            }
            guard (1...65535).contains(target) else { throw HostError(String(localized: "服务端口无效。")) }
            try Task.checkCancellation()
            report.set { $0.remoteEndpoint = "127.0.0.1:" + String(target) }
            report.advance(to: .tunnel)
            let targetPort = target
            let listener = try await ServerBootstrap(group: client.eventLoop)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelInitializer { local in
                    local.eventLoop.makeFutureWithTask {
                        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
                        let channel = try await client.createDirectTCPIPChannel(using: .init(targetHost: "127.0.0.1", targetPort: targetPort, originatorAddress: origin)) { remote in
                            remote.setOption(ChannelOptions.autoRead, value: false).flatMap {
                                remote.pipeline.addHandler(ForwardBytes(to: local))
                            }
                        }
                        try await local.pipeline.addHandler(ForwardBytes(to: channel)).get()
                        channel.read()
                        local.read()
                    }
                }.bind(host: "127.0.0.1", port: 0).get()
            guard let port = listener.localAddress?.port else {
                try? await listener.close()
                throw HostError(String(localized: "无法建立本地端口。"))
            }
            if Task.isCancelled {
                try? await listener.close()
                throw CancellationError()
            }
            report.set { $0.localEndpoint = "127.0.0.1:" + String(port) }
            report.succeed(detail: "127.0.0.1:\(port) → 127.0.0.1:\(targetPort)")
            let tunnel = SSHTunnel(client: client, listener: listener, token: credential, port: port)
            tunnel.reportedAddresses = reported
            return tunnel
        } catch { try? await client.close(); throw error }
    }

    /// Where DSH is on a manual SSH host: the configured running `dsh web`, the
    /// instance this app started before, or a new one (by the profile or [ask]).
    private static func resolveDSH(_ client: SSHClient, profile: HostProfile, ask: (@Sendable (SSHLaunchQuestion) async -> Bool)?,
                                   report: SSHReportRecorder) async throws -> (port: Int, token: String?) {
        let use: (RemoteDSH.Endpoint, String) -> (port: Int, token: String?) = { endpoint, outcome in
            report.set { $0.outcome = outcome; if let path = endpoint.dshPath { $0.dshPath = path } }
            return (endpoint.port, endpoint.token)
        }
        switch profile.launch {
        case .existing:
            if await RemoteDSH.listening(client, port: profile.harnessPort) {
                report.skip(.launch, detail: String(localized: "端口 \(profile.harnessPort) 上已有服务"))
                report.set { $0.outcome = String(localized: "使用已在运行的服务") }
                return (profile.harnessPort, nil)
            }
            let probe = try await RemoteDSH.probe(client, command: SSHLaunch.defaultCommand)
            report.set { $0.dshPath = probe.dshPath }
            if let earlier = probe.reusable, await RemoteDSH.listening(client, port: earlier.port) {
                report.skip(.launch, detail: String(localized: "端口 \(profile.harnessPort) 没有服务，改用之前通过 SSH 启动的服务"))
                return use(earlier, String(localized: "使用之前通过 SSH 启动的服务"))
            }
            let question = SSHLaunchQuestion(host: profile.name.isEmpty ? profile.address : profile.name, port: profile.harnessPort, dshPath: probe.dshPath)
            guard let ask, await ask(question) else {
                throw HostError(String(localized: "端口 \(profile.harnessPort) 上没有 Pallas 服务在运行"), code: "ssh/dsh-not-running",
                                detail: probe.dshPath.map { String(localized: "主机上有 \($0)。在主机上运行 dsh web，或将启动方式改为「通过 SSH 启动」。") }
                                    ?? String(localized: "主机上也没有找到 dsh 命令，请先在主机上安装。"))
            }
            report.advance(to: .launch, detail: String(localized: "端口 \(profile.harnessPort) 没有服务，按你的选择启动"))
            let started = try await RemoteDSH.start(client, command: SSHLaunch.defaultCommand, directory: nil)
            return use(started, String(localized: "已通过 SSH 启动（pid \(started.pid ?? 0)）"))
        case .start(let command, let directory):
            let probe = try await RemoteDSH.probe(client, command: command)
            report.set { $0.dshPath = probe.dshPath }
            if let earlier = probe.reusable, await RemoteDSH.listening(client, port: earlier.port) {
                report.skip(.launch, detail: String(localized: "之前通过 SSH 启动的服务还在运行"))
                return use(earlier, String(localized: "使用之前通过 SSH 启动的服务"))
            }
            report.advance(to: .launch, detail: probe.pid == nil ? String(localized: "主机上没有通过 SSH 启动的服务") : String(localized: "启动命令变了，重新启动"))
            let begun = Date()
            let started = try await RemoteDSH.start(client, command: command, directory: directory)
            return use(started, String(format: String(localized: "已通过 SSH 启动（pid %d，用时 %.1f 秒）"), started.pid ?? 0, Date().timeIntervalSince(begun)))
        }
    }

    /// Connects only far enough to read the server's host key (trust on first use).
    static func hostKey(_ profile: HostProfile) async throws -> SSHHostKey {
        guard !profile.address.isEmpty, (1...65535).contains(profile.port) else { throw HostError(String(localized: "填写主机地址（IP 或域名）")) }
        let capture = CapturedKey()
        do {
            let client = try await SSHClient.connect(host: profile.address, port: profile.port,
                                                    authenticationMethod: .passwordBased(username: profile.username.isEmpty ? "dsh" : profile.username, password: ""),
                                                    hostKeyValidator: .custom(capture), reconnect: .never, connectTimeout: .seconds(10))
            try? await client.close()
        } catch {
            if let key = capture.value { return key }
            throw SSHFailure.explain(error, at: .connect)
        }
        if let key = capture.value { return key }
        throw HostError(String(localized: "没能读到主机指纹"))
    }

    static func identity() -> (secret: String, username: String) {
        let key = Curve25519.Signing.PrivateKey()
        let pub = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        let bytes = Data(base64Encoded: String(pub.split(separator: " ")[1]))!
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (key.rawRepresentation.base64EncodedString(), "device-" + digest.prefix(16))
    }
}
