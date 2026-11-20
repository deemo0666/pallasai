// 设置 › 本机运行状态：安装包里有没有引擎、它跑没跑、在哪儿监听、启动为什么失败。
// 进入页面不会启动引擎。

import OSLog
import SwiftUI

/// One line the app wrote to the system log during this run, credentials already masked.
struct AppLogLine: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    let category: String
    let level: String
    let message: String

    static func == (a: Self, b: Self) -> Bool { a.date == b.date && a.message == b.message }

    var isProblem: Bool { level == "error" || level == "fault" }
}

/// Reads back what this process logged under the app's subsystem (`Log`).
enum AppLogReader {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dsh-local"

    /// Newest last. `problemsOnly` keeps errors and faults.
    static func recent(categories: Set<String> = ["engine", "connection"], problemsOnly: Bool = false,
                       within seconds: TimeInterval = 6 * 3600, limit: Int = 40) async -> [AppLogLine] {
        await Task.detached(priority: .utility) { () -> [AppLogLine] in
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
            let start = store.position(date: Date().addingTimeInterval(-seconds))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            guard let entries = try? store.getEntries(at: start, matching: predicate) else { return [] }
            var lines: [AppLogLine] = []
            for case let entry as OSLogEntryLog in entries where categories.contains(entry.category) {
                let level: String
                switch entry.level {
                case .error: level = "error"
                case .fault: level = "fault"
                case .notice: level = "notice"
                case .info: level = "info"
                default: level = "debug"
                }
                if problemsOnly, level != "error", level != "fault" { continue }
                lines.append(AppLogLine(date: entry.date, category: entry.category, level: level, message: ShareText.redacted(entry.composedMessage)))
            }
            return Array(lines.suffix(limit))
        }.value
    }
}

enum EngineRunState: Equatable {
    case unavailable
    case disabled
    case notStarted
    case starting
    case running(port: String, answering: Bool)
    case failed(String)
    case stopped(String?)
}

#if os(iOS)
extension EmbeddedEngine {
    /// Where the engine stands, from its own state and this run's log. Probes the listener (one
    /// HEAD request to 127.0.0.1); never starts anything.
    func runState(log: [AppLogLine]) async -> EngineRunState {
        #if DEBUG
        // `-DSHEngineStatus unavailable | stopped | failed:<message>` shows the other states on a build with the engine.
        if let forced = UserDefaults.standard.string(forKey: "DSHEngineStatus") {
            if forced == "unavailable" { return .unavailable }
            if forced == "stopped" { return .stopped("engine runtime ended") }
            if forced.hasPrefix("failed:") { return .failed(ShareText.redacted(String(forced.dropFirst(7)))) }
        }
        #endif
        guard Self.available else { return .unavailable }
        guard Self.enabled else { return .disabled }
        let engine = log.filter { $0.category == "engine" }
        if stopped { return .stopped(engine.last { $0.level == "fault" || $0.message.contains("runtime ended") }?.message) }
        if let endpoint {
            let port = String(endpoint.address.split(separator: ":").last ?? "")
            return .running(port: port, answering: await Self.answers(endpoint))
        }
        guard let launch = engine.lastIndex(where: { $0.message == "engine starting" }) else { return .notStarted }
        let after = engine[engine.index(after: launch)...]
        if let failure = after.last(where: \.isProblem) { return .failed(failure.message) }
        return .starting
    }

    /// The message a failure code stands for, as the app shows it when connecting.
    static func explain(_ logged: String) -> String? {
        if logged.contains("engine_timeout") { return String(localized: "启动用了太久。") + reopenAdvice }
        if logged.contains("engine_stopped") || logged.contains("runtime ended") {
            return String(localized: "本机已停止运行。") + reopenAdvice
        }
        if logged.contains("engine start failed: ") { return String(localized: "没能启动。") + reopenAdvice }
        return nil
    }
}
#endif

extension EngineRunState {
    var label: String {
        switch self {
        case .unavailable: String(localized: "这个安装包不能在本机运行")
        case .disabled: String(localized: "已在设置里关闭")
        case .notStarted: String(localized: "未启动")
        case .starting: String(localized: "正在启动")
        case .running(_, true): String(localized: "运行中")
        case .running(_, false): String(localized: "运行中，但没有响应")
        case .failed: String(localized: "没能启动")
        case .stopped: String(localized: "已停止")
        }
    }

    var tone: Color {
        switch self {
        case .running(_, true): SettingsStyle.ok
        case .running(_, false), .starting: SettingsStyle.warning
        case .failed, .stopped: .red
        default: ChatColors.muted
        }
    }
}

/// 本机引擎状态.
struct EngineStatusPage: View {
    #if os(macOS)
    @ObservedObject var chat: MacConversation
    @AppStorage(MacLocalEngine.enabledKey) private var enabled = true

    private var available: Bool { chat.engine.available }
    private var inUse: Bool { chat.isLocal || chat.connectingToLocal }
    private var connected: Bool { chat.connected }
    private var refreshKey: String { "\(chat.conversation.phase)/\(chat.connecting)/\(enabled)" }
    private let symbol = "desktopcomputer"
    #else
    @ObservedObject var remote: Conversation
    @Environment(\.shellActions) private var shell
    @AppStorage("embeddedHostSelected") private var embedded = true
    @State private var working = false
    @State private var actionError: String?

    private var engine: EmbeddedEngine { EmbeddedEngine.shared }
    private var available: Bool { EmbeddedEngine.available }
    private var enabled: Bool { EmbeddedEngine.enabled }
    private var inUse: Bool { embedded && remote.connection.map { engine.owns($0) } == true }
    private var connected: Bool { remote.phase == .ready || remote.phase == .replying }
    private var refreshKey: String { "\(remote.phase)/\(embedded)" }
    private let symbol = "iphone"
    #endif

    @State private var state: EngineRunState?
    @State private var log: [AppLogLine] = []

    var body: some View {
        SettingsList {
            Section {
                HStack(spacing: 14) {
                    SettingsIconDisc(symbol: symbol, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本机运行").font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(state?.tone ?? ChatColors.muted).frame(width: 8, height: 8)
                            Text(state?.label ?? String(localized: "正在读取…")).font(.subheadline).foregroundStyle(ChatColors.muted)
                        }
                    }
                }.padding(.vertical, 6).accessibilityElement(children: .combine).accessibilityIdentifier("engineState")
            }.listRowBackground(ChatColors.chip)

            Section("状态") {
                LabeledContent("安装包", value: available && state != .unavailable ? String(localized: "可以在本机运行") : String(localized: "不能在本机运行"))
                LabeledContent("设置开关", value: enabled ? String(localized: "已开启") : String(localized: "已关闭"))
                if case .running(let port, _)? = state {
                    LabeledContent("监听") { Text(verbatim: "127.0.0.1:" + port).font(.callout.monospaced()) }
                }
                LabeledContent("正在使用", value: inUse ? (connected ? String(localized: "本机 · 已连接") : String(localized: "本机 · 未连接")) : String(localized: "其他设备或未连接"))
            }.listRowBackground(ChatColors.chip)

            if let state { actions(state) }

            #if os(iOS)
            if let actionError {
                Section { Text(verbatim: displayError(actionError)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    .listRowBackground(ChatColors.chip)
            }
            #endif

            Section {
                NavigationLink {
                    #if os(macOS)
                    DiagnosticsPage(chat: chat)
                    #else
                    DiagnosticsPage(remote: remote)
                    #endif
                } label: {
                    SettingsRowLabel(symbol: "stethoscope", title: String(localized: "诊断"), chevron: false, tinted: false)
                }.accessibilityIdentifier("engineDiagnostics")
            }.listRowBackground(ChatColors.chip)

            let events = log.filter { $0.category == "engine" }.suffix(8)
            if !events.isEmpty {
                Section("最近事件") {
                    ForEach(Array(events)) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(ChatColors.muted)
                            Text(verbatim: ShareText.localizedRedactions(line.message)).font(.caption.monospaced())
                                .foregroundStyle(line.isProblem ? Color.red : ChatColors.ink).textSelection(.enabled)
                        }
                    }
                }.listRowBackground(ChatColors.chip)
            }
        }
        .settingsPage(String(localized: "本机运行状态"))
        .inlineNavigationTitle()
        .task(id: refreshKey) {
            // Only reads: the engine's own state, its log, and a probe of a listener that already exists.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func refresh() async {
        #if os(macOS)
        async let events = AppLogReader.recent(categories: ["engine"])
        let updated = await chat.engine.runState()
        guard !Task.isCancelled else { return }
        state = updated
        let recent = await events
        guard !Task.isCancelled else { return }
        log = recent
        #else
        let events = await AppLogReader.recent(categories: ["engine"])
        let updated = await engine.runState(log: events)
        guard !Task.isCancelled else { return }
        log = events
        state = updated
        #endif
    }

    private func displayError(_ message: String) -> String {
        ShareText.localizedRedactions(ShareText.redacted(message))
    }

    @ViewBuilder private func actions(_ state: EngineRunState) -> some View {
        switch state {
        case .unavailable:
            Section {
                Text("这个安装包不能在本机运行。可以在「我的电脑」里连接一台电脑来用。").font(.callout)
            }.listRowBackground(ChatColors.chip)
        case .disabled:
            #if os(iOS)
            Section {
                Text("在设置里打开「本机运行」后，就能切到本机。").font(.callout)
            }.listRowBackground(ChatColors.chip)
            #else
            EmptyView()
            #endif
        case .failed(let message), .stopped(let message?):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("实际错误").font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted)
                    Text(verbatim: displayError(message)).font(.callout.monospaced()).textSelection(.enabled).accessibilityIdentifier("engineError")
                    #if os(iOS)
                    if let explained = EmbeddedEngine.explain(message), explained != message {
                        Text(explained).font(.callout)
                    }
                    #endif
                }.padding(.vertical, 4)
                #if os(macOS)
                connectButton(String(localized: "重新连接"), symbol: "arrow.clockwise", id: "engineReconnect")
                #else
                reopenGuide
                #endif
            }.listRowBackground(ChatColors.chip)
        case .stopped(nil):
            Section {
                #if os(macOS)
                connectButton(String(localized: "启动并切到本机"), symbol: symbol, id: "engineSwitch")
                #else
                reopenGuide
                #endif
            }.listRowBackground(ChatColors.chip)
        case .notStarted, .starting, .running:
            Section {
                if inUse && connected, case .running(_, true) = state {
                    Label("正在使用本机", systemImage: "checkmark.circle").foregroundStyle(SettingsStyle.ok)
                } else {
                    #if os(macOS)
                    macActions(state)
                    #else
                    iosActions(state)
                    #endif
                }
            }.listRowBackground(ChatColors.chip)
        }
    }

    #if os(macOS)
    @ViewBuilder private func macActions(_ state: EngineRunState) -> some View {
        switch state {
        case .starting:
            ProgressView().controlSize(.small)
        case .running(_, false):
            connectButton(String(localized: "重启本机引擎"), symbol: "arrow.clockwise", restart: true, id: "engineReconnect")
        case .running:
            connectButton(inUse ? String(localized: "重新连接") : String(localized: "切到本机"),
                          symbol: inUse ? "arrow.clockwise" : symbol,
                          id: inUse ? "engineReconnect" : "engineSwitch")
        default:
            connectButton(String(localized: "启动并切到本机"), symbol: symbol, id: "engineSwitch")
        }
    }

    private func connectButton(_ title: String, symbol: String, restart: Bool = false, id: String) -> some View {
        Button {
            chat.reconnectLocal(restart: restart)
        } label: {
            Label(title, systemImage: symbol)
        }.disabled(!chat.canConnect || !enabled).accessibilityIdentifier(id)
    }
    #else
    @ViewBuilder private func iosActions(_ state: EngineRunState) -> some View {
        if inUse {
            actionButton(String(localized: "重新连接"), symbol: "arrow.clockwise", resume: true, id: "engineReconnect")
        } else {
            actionButton(state == .notStarted ? String(localized: "启动并切到本机") : String(localized: "切到本机"), symbol: symbol, resume: false, id: "engineSwitch")
            if case .running(_, false) = state {
                actionButton(String(localized: "重新连接"), symbol: "arrow.clockwise", resume: true, id: "engineReconnect")
            }
        }
    }

    private var reopenGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("重新打开 Pallas Agent", systemImage: "arrow.uturn.backward.circle").font(.subheadline.weight(.semibold))
            Text("从屏幕底部上滑并停住，把 Pallas Agent 向上划掉，再从主屏幕打开。")
                .font(.callout).foregroundStyle(ChatColors.muted)
        }.padding(.vertical, 4).accessibilityIdentifier("engineReopenGuide")
    }

    private func actionButton(_ title: String, symbol: String, resume: Bool, id: String) -> some View {
        Button {
            Task {
                guard let use = shell.useEngine else { actionError = String(localized: "这里没法切换，请从侧栏的「切换设备」选择本机。"); return }
                working = true
                actionError = await use(resume)
                working = false
                await refresh()
            }
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if working { ProgressView() }
            }
        }.disabled(working).accessibilityIdentifier(id)
    }
    #endif
}
