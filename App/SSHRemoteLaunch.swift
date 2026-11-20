@preconcurrency import Citadel
import Foundation
import NIO
import NIOSSH

// MARK: - Connection stages and report

/// Where an SSH connection is, for 网络详情 and for failure messages.
enum SSHStage: String, Codable, CaseIterable {
    case connect, hostKey, login, probe, launch, tunnel, auth

    var title: String {
        switch self {
        case .connect: String(localized: "连接主机")
        case .hostKey: String(localized: "核对主机指纹")
        case .login: String(localized: "SSH 登录")
        case .probe: String(localized: "查找服务")
        case .launch: String(localized: "启动服务")
        case .tunnel: String(localized: "转发端口")
        case .auth: String(localized: "服务认证")
        }
    }
}

/// What the last connection to one SSH host did: the endpoints actually used,
/// how it logged in and reached DSH, and the stage that failed. Holds no secrets
/// (tokens in log lines are masked).
struct SSHConnectionReport: Codable, Equatable {
    struct Step: Codable, Equatable {
        var stage: SSHStage
        var ok: Bool
        var detail: String?
        var seconds: Double
        /// Not needed this time (a running DSH made 启动 DSH unnecessary).
        var skipped: Bool?
    }

    var started = Date()
    var finished: Date?
    var sshEndpoint = ""
    var login = ""
    var hostKey: String?
    var mode = ""
    var dshPath: String?
    var remoteEndpoint: String?
    var localEndpoint: String?
    var outcome: String?
    var steps: [Step] = []
    var failure: SSHStage?
    var failureMessage: String?

    var succeeded: Bool { finished != nil && failure == nil }
}

/// The latest report per saved host, kept on this phone (UserDefaults) so the
/// details survive a restart.
@MainActor
final class SSHReports: ObservableObject {
    static let shared = SSHReports()
    @Published private(set) var reports: [UUID: SSHConnectionReport] = [:]
    private let key = "sshConnectionReports"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([UUID: SSHConnectionReport].self, from: data) { reports = saved }
    }

    func update(_ id: UUID, _ report: SSHConnectionReport) {
        reports[id] = report
        if let data = try? JSONEncoder().encode(reports) { UserDefaults.standard.set(data, forKey: key) }
    }

    func forget(_ id: UUID) {
        reports[id] = nil
        if let data = try? JSONEncoder().encode(reports) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Collects the steps of one `SSHTunnel.open` and publishes them as they happen.
final class SSHReportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var report: SSHConnectionReport
    private var stage: SSHStage = .connect
    private var stageStarted = Date()
    private let id: UUID?
    /// A computer paired by its code: its failures are told without the words of the SSH underneath.
    private let paired: Bool

    init(_ profile: HostProfile) {
        id = profile.kind == .ssh ? profile.id : nil
        paired = profile.kind == .paired
        report = SSHConnectionReport()
        report.sshEndpoint = (profile.username.isEmpty ? "" : profile.username + "@") + profile.address + ":" + String(profile.port)
        report.hostKey = profile.fingerprint.isEmpty ? nil : [profile.hostKeyType, profile.fingerprint].compactMap { $0 }.joined(separator: " ")
        report.mode = profile.kind == .paired ? String(localized: "扫码配对") : profile.launch.title
        publish()
    }

    var current: SSHStage { lock.withLock { stage } }

    /// Moves to [next] without marking the stages in between (a key that can't be read fails 「SSH 登录」).
    func enter(_ next: SSHStage) { lock.withLock { stage = next; stageStarted = Date() } }

    func set(_ change: (inout SSHConnectionReport) -> Void) {
        lock.withLock { change(&report) }
        publish()
    }

    /// Finishes the current stage successfully and starts [next].
    func advance(to next: SSHStage, detail: String? = nil) {
        lock.withLock {
            guard stage != next else { return }
            report.steps.append(.init(stage: stage, ok: true, detail: detail, seconds: Date().timeIntervalSince(stageStarted)))
            stage = next
            stageStarted = Date()
        }
        publish()
    }

    /// Finishes the current stage, notes [skipped] as not needed and moves past it.
    func skip(_ skipped: SSHStage, detail: String) {
        lock.withLock {
            report.steps.append(.init(stage: stage, ok: true, detail: nil, seconds: Date().timeIntervalSince(stageStarted)))
            report.steps.append(.init(stage: skipped, ok: true, detail: detail, seconds: 0, skipped: true))
            let all = SSHStage.allCases
            stage = all.firstIndex(of: skipped).map { all.index(after: $0) < all.endIndex ? all[all.index(after: $0)] : skipped } ?? skipped
            stageStarted = Date()
        }
        publish()
    }

    func succeed(detail: String? = nil) {
        lock.withLock {
            report.steps.append(.init(stage: stage, ok: true, detail: detail, seconds: Date().timeIntervalSince(stageStarted)))
            report.finished = Date()
        }
        publish()
    }

    /// Records the failure and returns the error to throw: the stage's name first.
    func fail(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let explained = SSHFailure.explain(error, at: current)
        lock.withLock {
            report.steps.append(.init(stage: stage, ok: false, detail: explained.message, seconds: Date().timeIntervalSince(stageStarted)))
            report.failure = stage
            report.failureMessage = HostError.explain(explained)
            report.finished = Date()
        }
        publish()
        if paired { return Self.plain(current, explained) }
        return HostError(String(localized: "\(current.title)失败：\(explained.message)"), code: explained.code, detail: explained.detail)
    }

    /// A paired computer's failure in the person's words: what happened, then what to check. The codes
    /// (`pair/…`) say which case it was; `pair/refused` during pairing means the code was used or ran out.
    private static func plain(_ stage: SSHStage, _ cause: HostError) -> HostError {
        // A failure during host-key validation means the key has changed.
        if cause.code == "ssh/host-key-changed" || stage == .hostKey {
            return HostError(String(localized: "这台电脑和上次连接的不是同一台，已断开"), code: "pair/identity",
                             detail: String(localized: "如果你重装过电脑上的程序，请删除这台电脑，再重新扫码连接。"))
        }
        switch stage {
        case .connect, .hostKey:
            return HostError(String(localized: "连不上这台电脑"), code: "pair/unreachable",
                             detail: String(localized: "确认电脑已开机，两台设备连着同一个 Wi-Fi，防火墙允许连接。"))
        case .login:
            return HostError(String(localized: "电脑没有认出这台设备"), code: "pair/refused",
                             detail: String(localized: "请在电脑上重新显示配对码，再扫一次。"))
        case .probe, .launch, .tunnel, .auth:
            return HostError(String(localized: "连上了电脑，但它还没有准备好"), code: "pair/not-ready",
                             detail: String(localized: "请把电脑上的程序重新打开，再试一次。"))
        }
    }

    /// Adds the DSH sign-in that the caller ran through the finished tunnel.
    static func recordAuth(_ id: UUID, ok: Bool, detail: String?) {
        Task { @MainActor in
            guard var report = SSHReports.shared.reports[id] else { return }
            report.steps.removeAll { $0.stage == .auth }
            report.steps.append(.init(stage: .auth, ok: ok, detail: detail, seconds: 0))
            if !ok { report.failure = .auth; report.failureMessage = detail }
            SSHReports.shared.update(id, report)
        }
    }

    private func publish() {
        guard let id else { return }
        let snapshot = lock.withLock { report }
        Task { @MainActor in SSHReports.shared.update(id, snapshot) }
    }
}

enum SSHFailure {
    /// Plain words for what Citadel and NIO throw.
    static func explain(_ error: Error, at stage: SSHStage) -> HostError {
        if let host = error as? HostError { return host }
        if let network = error as? NIOConnectionError {
            if let failure = network.connectionErrors.first { return explain(failure.error, at: .connect) }
            if network.dnsAError != nil || network.dnsAAAAError != nil {
                return HostError(String(localized: "找不到主机地址"), code: "ssh/dns", detail: String(localized: "检查主机地址。如果地址来自 VPN 或组网工具，确认本机也已连接。"))
            }
        }
        let text = String(describing: error)
        switch stage {
        case .connect:
            if text.contains("connectTimeout") || text.contains("timeout") { return HostError(String(localized: "连接超时"), code: "ssh/timeout", detail: String(localized: "确认主机开着，地址和端口没有写错，主机的 SSH 服务已打开。")) }
            if text.contains("connection refused") || text.contains("Connection refused") || text.contains("ECONNREFUSED") {
                return HostError(String(localized: "主机拒绝连接"), code: "ssh/refused", detail: String(localized: "确认主机的 SSH 服务已打开，端口没有写错。"))
            }
            return HostError(String(localized: "连不上主机"), code: "ssh/network", detail: String(localized: "检查本机和主机的网络、主机地址和端口，然后重试。"))
        case .login:
            if text.contains("allAuthenticationOptionsFailed") { return HostError(String(localized: "服务器拒绝登录"), code: "ssh/auth", detail: String(localized: "用户名、密码或私钥不对，或者主机不接受这种登录方式。")) }
            return HostError(String(localized: "没能登录"), detail: redact(text))
        default:
            return HostError(error.localizedDescription, detail: text == error.localizedDescription ? nil : redact(text))
        }
    }

    static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"token=[^\s&#"']+"#, with: "token=•••", options: .regularExpression)
    }
}

// MARK: - Launch modes

/// How a manual SSH host reaches DSH: a `dsh web` that is already running (its
/// port and launch token typed in the form), or one this app starts over SSH.
enum SSHLaunch: Equatable {
    case existing
    case start(command: String, directory: String?)

    static let defaultCommand = "dsh web"

    var title: String {
        switch self {
        case .existing: String(localized: "连接已在运行的服务")
        case .start: String(localized: "通过 SSH 启动")
        }
    }
}

extension HostProfile {
    var launch: SSHLaunch {
        get {
            guard let command = launchCommand else { return .existing }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .start(command: trimmed.isEmpty ? SSHLaunch.defaultCommand : trimmed, directory: directory?.isEmpty == false ? directory : nil)
        }
        set {
            switch newValue {
            case .existing: launchCommand = nil; workingDirectory = nil
            case .start(let command, let directory): launchCommand = command; workingDirectory = directory
            }
        }
    }
}

// MARK: - Remote DSH

/// What the phone asks before it starts DSH on a host the person set up as
/// 「连接已在运行的 dsh web」.
struct SSHLaunchQuestion: Sendable {
    let host: String
    let port: Int
    let dshPath: String?
}

/// Starts, finds and reuses the `dsh web` this phone runs on an SSH host.
///
/// It lives in `~/.dsh-local/remote/` (mode 700): `pid`, `stamp` (the
/// process start time, so a recycled pid is not mistaken for ours), `command`
/// and `log`. The server runs under `nohup` bound to the host's loopback with
/// an OS-chosen port, so it outlives the SSH session; the port and launch token
/// come from the `?token=` line it prints.
enum RemoteDSH {
    struct Endpoint: Sendable {
        let port: Int
        let token: String
        let pid: Int?
        let reused: Bool
        let home: String?
        let dshPath: String?
    }

    struct Probe: Sendable {
        var home: String?
        var dshPath: String?
        var pid: Int?
        var sameCommand = false
        var launchLine: String?
        var reusable: Endpoint? {
            guard let pid, sameCommand, let line = launchLine, let url = RemoteDSH.launchURL(line) else { return nil }
            return Endpoint(port: url.port, token: url.token, pid: pid, reused: true, home: home, dshPath: dshPath)
        }
    }

    static let marker = "@dshlocal"
    static let stateDirectory = "$HOME/.dsh-local/remote"

    // MARK: Scripts (POSIX sh)

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Shared helpers: the state directory, start stamps and whether a pid is ours.
    private static let helpers = #"""
    umask 077
    S="$HOME/.dsh-local/remote"
    say() { printf '@dshlocal %s\n' "$*"; }
    stamp() {
      if [ -r "/proc/$1/stat" ]; then
        T=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20) && [ -n "$T" ] && printf '%s\n' "$T"
      else
        ps -o lstart= -p "$1" 2>/dev/null
      fi
    }
    mine() {
      [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
      [ -f "$S/stamp" ] || return 1
      [ "$(stamp "$1")" = "$(cat "$S/stamp" 2>/dev/null)" ]
    }
    finddsh() {
      command -v dsh >/dev/null 2>&1 && return 0
      for d in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.volta/bin" "$HOME/.bun/bin" "$HOME/Library/pnpm" \
               "$HOME/.local/share/pnpm" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin \
               "$HOME"/.local/share/fnm/node-versions/*/installation/bin; do
        if [ -x "$d/dsh" ]; then PATH="$d:$PATH"; export PATH; return 0; fi
      done
      return 1
    }
    lastline() { grep -E 'https?://[^ ]*[?&]token=' "$S/log" 2>/dev/null | tail -n 1; }
    """#

    /// Reports `$HOME`, where `dsh` is, and the instance this phone started, if any.
    static func probeScript(command: String) -> String {
        helpers + "\n" + #"""
        say home "$HOME"
        if finddsh; then say dsh "$(command -v dsh)"; fi
        P=$(cat "$S/pid" 2>/dev/null)
        if mine "$P"; then
          say alive "$P"
        """# + "\n  [ \"$(cat \"$S/command\" 2>/dev/null)\" = \(quote(command)) ] && say same\n" + #"""
          say url "$(lastline)"
        fi
        exit 0
        """#
    }

    /// Stops our previous instance, starts `<command> --host 127.0.0.1 --port 0
    /// --no-open` and waits up to [seconds] for its launch line.
    static func startScript(command: String, directory: String?, seconds: Int = 60) -> String {
        var lines = [helpers, #"""
        say home "$HOME"
        mkdir -p "$S" 2>/dev/null && chmod 700 "$S" 2>/dev/null || { say nodir; exit 0; }
        P=$(cat "$S/pid" 2>/dev/null)
        if mine "$P"; then
          command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$P" 2>/dev/null
          kill "$P" 2>/dev/null
          n=0; while kill -0 "$P" 2>/dev/null && [ $n -lt 10 ]; do sleep 1; n=$((n+1)); done
          mine "$P" && kill -9 "$P" 2>/dev/null
        fi
        rm -f "$S/pid" "$S/stamp"
        """#]
        if command == SSHLaunch.defaultCommand {
            lines.append("if finddsh; then say dsh \"$(command -v dsh)\"; else say nodsh; exit 0; fi")
        }
        if let directory, !directory.isEmpty {
            let path = directory == "~" ? "\"$HOME\"" : directory.hasPrefix("~/") ? "\"$HOME\"/" + quote(String(directory.dropFirst(2))) : quote(directory)
            lines.append("cd \(path) 2>/dev/null || say nocwd")
        }
        lines.append("printf '%s' \(quote(command)) > \"$S/command\"")
        lines.append(": > \"$S/log\"")
        lines.append("NO_COLOR=1; export NO_COLOR")
        // The engine's /feedback upload to its vendor stays off on computers this phone starts it on.
        lines.append("DSH_TELEMETRY_DISABLED=1; export DSH_TELEMETRY_DISABLED")
        // macOS's nohup refuses to run outside a login console; ignoring SIGHUP in the child does the same job.
        lines.append("N=; nohup true </dev/null >/dev/null 2>&1 && N=nohup")
        lines.append("$N /bin/sh -c \(quote("trap '' HUP; " + command + " --host 127.0.0.1 --port 0 --no-open")) </dev/null >>\"$S/log\" 2>&1 &")
        lines.append(#"""
        P=$!
        stamp "$P" > "$S/stamp"
        printf '%s\n' "$P" > "$S/pid"
        say started "$P"
        """#)
        lines.append("n=0\nwhile [ $n -lt \(max(5, min(seconds, 600))) ]; do")
        lines.append(#"""
          L=$(lastline)
          if [ -n "$L" ]; then say url "$L"; exit 0; fi
          if ! kill -0 "$P" 2>/dev/null; then say exited; tail -n 20 "$S/log" 2>/dev/null | sed 's/^/@dshlocal log /'; exit 0; fi
          sleep 1; n=$((n+1))
        done
        say timeout
        tail -n 20 "$S/log" 2>/dev/null | sed 's/^/@dshlocal log /'
        exit 0
        """#)
        return lines.joined(separator: "\n")
    }

    // MARK: Parsing

    static func tagged(_ output: String) -> [(String, String)] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
            guard line.hasPrefix(marker + " ") else { return nil }
            let rest = line.dropFirst(marker.count + 1)
            guard let space = rest.firstIndex(of: " ") else { return (String(rest), "") }
            return (String(rest[..<space]), String(rest[rest.index(after: space)...]))
        }
    }

    /// The port and token in `dsh web: http://127.0.0.1:PORT/?token=…`.
    static func launchURL(_ line: String) -> (port: Int, token: String)? {
        guard let range = line.range(of: #"https?://[^\s]+"#, options: .regularExpression),
              let components = URLComponents(string: String(line[range])),
              let port = components.port, (1...65535).contains(port),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty else { return nil }
        return (port, token)
    }

    static func parseProbe(_ output: String) -> Probe {
        var probe = Probe()
        for (key, value) in tagged(output) {
            switch key {
            case "home": probe.home = value.isEmpty ? nil : value
            case "dsh": probe.dshPath = value.isEmpty ? nil : value
            case "alive": probe.pid = Int(value.trimmingCharacters(in: .whitespaces))
            case "same": probe.sameCommand = true
            case "url": probe.launchLine = value.isEmpty ? nil : value
            default: break
            }
        }
        return probe
    }

    static func parseStart(_ output: String, command: String) throws -> Endpoint {
        var home: String?, dsh: String?, pid: Int?, line: String?
        var missing = false, exited = false, timedOut = false, noDirectory = false
        var log: [String] = []
        for (key, value) in tagged(output) {
            switch key {
            case "home": home = value
            case "dsh": dsh = value
            case "started": pid = Int(value)
            case "url": line = value
            case "nodsh": missing = true
            case "nodir": noDirectory = true
            case "exited": exited = true
            case "timeout": timedOut = true
            case "log": log.append(value)
            default: break
            }
        }
        if let line, let url = launchURL(line) {
            return Endpoint(port: url.port, token: url.token, pid: pid, reused: false, home: home, dshPath: dsh)
        }
        let tail = SSHFailure.redact(log.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8).joined(separator: "\n"))
        if noDirectory { throw HostError(String(localized: "没能在主机上创建 ~/.dsh-local"), code: "ssh/dsh-state") }
        if missing {
            throw HostError(String(localized: "主机上没有找到 dsh 命令"), code: "ssh/dsh-missing",
                            detail: String(localized: "请先在主机上安装 dsh 命令，或在启动命令里写它的完整路径。"))
        }
        if exited {
            let notFound = tail.range(of: #"not found|No such file|ENOENT|can't open"#, options: [.regularExpression, .caseInsensitive]) != nil
            throw HostError(notFound ? String(localized: "主机上找不到命令「\(command)」") : String(localized: "服务启动后退出了"), code: "ssh/dsh-exited", detail: tail.isEmpty ? nil : tail)
        }
        if timedOut {
            throw HostError(String(localized: "等了 60 秒，服务还没就绪"), code: "ssh/dsh-timeout", detail: tail.isEmpty ? nil : tail)
        }
        throw HostError(String(localized: "没能启动服务"), code: "ssh/dsh-start", detail: tail.isEmpty ? nil : tail)
    }

    // MARK: Running

    /// Runs [script] under the remote account's login `sh`; returns its standard
    /// output (standard error is dropped: the script reports through tagged lines).
    static func run(_ client: SSHClient, _ script: String, timeout: Double) async throws -> String {
        let command = "sh -lc " + quote(script)
        return try await withTimeout(client, seconds: timeout) {
            var output = ""
            do {
                for try await chunk in try await client.executeCommandStream(command) {
                    if case .stdout(let bytes) = chunk { output += String(buffer: bytes) }
                }
            } catch is SSHClient.CommandFailed {}
            return output
        }
    }

    /// NIO futures do not observe Swift task cancellation. Close the transport before
    /// leaving the task group so an unanswered channel-open request cannot hold it open.
    static func withTimeout<T: Sendable>(_ client: SSHClient, seconds: Double,
                                         operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw HostError(String(localized: "主机没有在 \(Int(seconds)) 秒内回应"), code: "ssh/timeout")
                }
                defer { group.cancelAll() }
                do { return try await group.next()! }
                catch {
                    if error is CancellationError || (error as? HostError)?.code == "ssh/timeout" {
                        try? await client.close()
                    }
                    throw error
                }
            }
        } onCancel: {
            Task { try? await client.close() }
        }
    }

    /// True when something accepts connections on the host's 127.0.0.1:[port].
    static func listening(_ client: SSHClient, port: Int) async -> Bool {
        do {
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
            let channel = try await withTimeout(client, seconds: 10) {
                try await client.createDirectTCPIPChannel(
                    using: .init(targetHost: "127.0.0.1", targetPort: port, originatorAddress: origin)) { $0.eventLoop.makeSucceededVoidFuture() }
            }
            try? await channel.close()
            return true
        } catch { return false }
    }

    static func probe(_ client: SSHClient, command: String) async throws -> Probe {
        parseProbe(try await run(client, probeScript(command: command), timeout: 20))
    }

    static func start(_ client: SSHClient, command: String, directory: String?) async throws -> Endpoint {
        try parseStart(try await run(client, startScript(command: command, directory: directory), timeout: 90), command: command)
    }
}

