// 设置 › 帮助与关于 › 诊断：引擎状态、版本、连接方式和这次运行的错误，生成可以复制的报告。
// 「问 AI」用同一份报告：用户先看过内容，再放进新对话的草稿，由用户自己发送。
// 报告只写下面列出的字段；API Key、令牌和登录信息不写进去，错误里带出来的也会打码。

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The fields a report may carry, collected once.
struct DiagnosticsReport {
    var created = Date()
    var app = AppVersion.label
    var system = DiagnosticsReport.systemVersion
    var device = DiagnosticsReport.machine
    var engine: EngineRunState = .notStarted
    var connectionKind = String(localized: "未连接")
    var connectionState = String(localized: "未连接")
    var notice: String?
    var thirdPartyKey = false
    var deepSeekSignedIn = false
    var performance = ""
    var errors: [AppLogLine] = []

    private static var systemVersion: String {
        #if os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let release = "macOS \(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? release : release + ".\(version.patchVersion)"
        #else
        UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        #endif
    }

    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    #if os(macOS)
    @MainActor static func collect(_ chat: MacConversation) async -> DiagnosticsReport {
        let state = await chat.engine.runState()
        let remote = chat.conversation
        return await collect(engine: state, kind: chat.connectionKind,
                             phase: chat.connecting ? .connecting : remote.phase, notice: remote.notice)
    }
    #else
    /// How the conversation in use is connected, from what the shell saved (no address).
    @MainActor private static func kind(_ remote: Conversation) -> String {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "embeddedHostSelected") { return String(localized: "本机引擎") }
        if !(defaults.string(forKey: "lastSSHProfile") ?? "").isEmpty { return "SSH" }
        return remote.connection == nil ? String(localized: "未连接") : String(localized: "主机地址")
    }

    @MainActor static func collect(_ remote: Conversation) async -> DiagnosticsReport {
        let engineLog = await AppLogReader.recent(categories: ["engine"])
        let state = await EmbeddedEngine.shared.runState(log: engineLog)
        return await collect(engine: state, kind: kind(remote), phase: remote.phase, notice: remote.notice)
    }
    #endif

    @MainActor private static func collect(engine: EngineRunState, kind: String, phase: Conversation.Phase,
                                           notice: String?) async -> DiagnosticsReport {
        var report = DiagnosticsReport()
        report.engine = engine
        report.connectionKind = kind
        switch phase {
        case .ready: report.connectionState = String(localized: "已连接")
        case .replying: report.connectionState = String(localized: "已连接 · 正在回复")
        case .connecting: report.connectionState = String(localized: "正在连接")
        case .offline: report.connectionState = notice == nil ? String(localized: "未连接") : String(localized: "连接失败")
        }
        report.notice = notice.map(ShareText.redacted)
        report.thirdPartyKey = !ThirdPartyProviders.configured().isEmpty
        report.deepSeekSignedIn = DeepSeekAccount.shared.signedIn
        let p = PerformanceSettings.shared
        report.performance = [p.mode.title + (p.cooling ? String(localized: "（临时轻量）") : ""), String(localized: "刷新率 ") + p.refresh.title,
                              String(localized: "模糊 ") + (p.blur ? String(localized: "开") : String(localized: "关")), String(localized: "动效 ") + (p.animations ? String(localized: "开") : String(localized: "关")),
                              String(localized: "系统减弱动态效果 ") + (p.systemReduceMotion ? String(localized: "开") : String(localized: "关"))].joined(separator: " · ")
        report.errors = Array(await AppLogReader.recent(problemsOnly: true).suffix(12))
        return report
    }

    var engineLine: String {
        var line = engine.label
        if case .running(let port, _) = engine { line += String(localized: "（127.0.0.1:") + port + String(localized: "）") }
        return line
    }

    /// The report as copied and as put in the draft. Masked once more as a whole.
    var text: String {
        var lines = [
            String(localized: "Pallas Agent 诊断报告"),
            String(localized: "生成时间：") + Self.stamp.string(from: created),
            String(localized: "App 版本：") + app,
            String(localized: "系统：") + system + " · " + device,
            String(localized: "本机引擎：") + engineLine,
            String(localized: "连接方式：") + connectionKind,
            String(localized: "连接状态：") + connectionState,
            String(localized: "第三方接入：") + (thirdPartyKey ? String(localized: "已保存 API Key（内容未导出）") : String(localized: "未设置")),
            String(localized: "DeepSeek 账号：") + (deepSeekSignedIn ? String(localized: "已登录") : String(localized: "未登录")),
            String(localized: "性能：") + performance,
        ]
        switch engine {
        case .failed(let message), .stopped(let message?): lines.append(String(localized: "引擎错误：") + message)
        default: break
        }
        if let notice { lines.append(String(localized: "当前提示：") + notice) }
        if errors.isEmpty {
            lines.append(String(localized: "最近错误：这次运行没有记录"))
        } else {
            lines.append(String(localized: "最近错误（这次运行，最多 12 条）："))
            for line in errors {
                lines.append("- " + line.date.formatted(date: .omitted, time: .standard) + " [" + line.category + "] " + line.message)
            }
        }
        return Self.redacted(lines.joined(separator: "\n"))
    }

    static func redacted(_ text: String) -> String {
        ShareText.localizedRedactions(ShareText.redacted(text))
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// What the draft of 问 AI starts with.
    static let askPrompt = String(localized: "下面是 Pallas Agent 的诊断报告。帮我看看哪里出了问题，以及该怎么处理：\n\n")
}

struct DiagnosticsPage: View {
    #if os(macOS)
    @ObservedObject var chat: MacConversation
    @AppStorage(MacLocalEngine.enabledKey) private var localEnabled = true
    @State private var refreshCount = 0
    private var refreshKey: String { "\(chat.conversation.phase)/\(chat.connecting)/\(localEnabled)/\(refreshCount)" }
    #else
    @ObservedObject var remote: Conversation
    private var refreshKey: String { "\(remote.phase)" }
    #endif
    @State private var report: DiagnosticsReport?
    @State private var preview: ReportPreview?

    fileprivate struct ReportPreview: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        SettingsList {
            if let report {
                Section("运行时") {
                    LabeledContent("App 版本", value: report.app)
                    LabeledContent("系统", value: report.system)
                    LabeledContent("设备", value: report.device)
                    LabeledContent("本机引擎", value: report.engineLine)
                    switch report.engine {
                    case .failed(let message), .stopped(let message?):
                        Text(verbatim: DiagnosticsReport.redacted(message)).font(.caption.monospaced())
                            .foregroundStyle(.red).textSelection(.enabled)
                    default: EmptyView()
                    }
                }.listRowBackground(ChatColors.chip)
                Section("连接") {
                    LabeledContent("方式", value: report.connectionKind)
                    LabeledContent("状态", value: report.connectionState)
                    if let notice = report.notice {
                        Text(verbatim: ShareText.localizedRedactions(notice)).font(.caption)
                            .foregroundStyle(ChatColors.muted).textSelection(.enabled)
                    }
                    LabeledContent("第三方接入", value: report.thirdPartyKey ? String(localized: "已设置") : String(localized: "未设置"))
                    LabeledContent("DeepSeek 账号", value: report.deepSeekSignedIn ? String(localized: "已登录") : String(localized: "未登录"))
                }.listRowBackground(ChatColors.chip)
                Section("最近错误") {
                    if report.errors.isEmpty {
                        Text("这次运行没有记录到错误").foregroundStyle(ChatColors.muted)
                    } else {
                        ForEach(report.errors.reversed()) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.date.formatted(date: .omitted, time: .standard) + " · " + line.category)
                                    .font(.caption2).foregroundStyle(ChatColors.muted)
                                Text(verbatim: ShareText.localizedRedactions(line.message)).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }.listRowBackground(ChatColors.chip)
                Section {
                    Button { preview = ReportPreview(text: report.text) } label: {
                        Label("预览并复制诊断报告", systemImage: "doc.on.clipboard")
                    }.accessibilityIdentifier("diagnosticsPreview")
                }.listRowBackground(ChatColors.chip)
            } else {
                Section { ProgressView("正在收集…").frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
        }
        .settingsPage(String(localized: "诊断"))
        .inlineNavigationTitle()
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button("刷新", systemImage: "arrow.clockwise") { refreshCount += 1 }
                    .accessibilityIdentifier("diagnosticsRefresh")
            }
        }
        #else
        .refreshable { await refresh() }
        #endif
        .task(id: refreshKey) { await refresh() }
        .sheet(item: $preview) {
            #if os(macOS)
            DiagnosticsReportSheet(text: $0.text, chat: chat)
            #else
            DiagnosticsReportSheet(text: $0.text, remote: remote)
            #endif
        }
    }

    private func refresh() async {
        #if os(macOS)
        let updated = await DiagnosticsReport.collect(chat)
        #else
        let updated = await DiagnosticsReport.collect(remote)
        #endif
        guard !Task.isCancelled else { return }
        report = updated
    }
}

/// The report as text, with 复制 and 放进新对话.
private struct DiagnosticsReportSheet: View {
    let text: String
    #if os(macOS)
    @ObservedObject var chat: MacConversation
    @Environment(\.openWindow) private var openWindow
    @State private var openingDraft = false
    @State private var draftError: String?
    private var canAsk: Bool { chat.canChangeSession && !openingDraft }
    #else
    @ObservedObject var remote: Conversation
    @Environment(\.shellActions) private var shell
    private var canAsk: Bool { remote.connection != nil && (remote.phase == .ready || remote.phase == .replying) }
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            content
                .background(ChatColors.panel.ignoresSafeArea())
                .navigationTitle("诊断报告").inlineNavigationTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }.presentationCornerRadius(28)
            .desktopSheet(width: 500, height: 470)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("diagnosticsReportText")
                    .padding(16)
            }
            VStack(spacing: 10) {
                Button {
                    PlatformPasteboard.copy(text)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制报告", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("diagnosticsCopy")
                Button(action: placeDraft) {
                    Label("放进新对话（不发送）", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity, minHeight: 44)
                }.prominentButton().buttonBorderShape(.capsule).disabled(!canAsk)
                    .accessibilityIdentifier("diagnosticsAskAI")
                #if os(macOS)
                if let draftError {
                    Text(verbatim: draftError).font(.callout).foregroundStyle(.red)
                }
                #else
                if !canAsk {
                    Text("连接后才能交给 AI。").font(.caption).foregroundStyle(ChatColors.muted)
                }
                #endif
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func placeDraft() {
        let draft = DiagnosticsReport.askPrompt + text
        #if os(macOS)
        guard canAsk else { return }
        openingDraft = true
        draftError = nil
        Task {
            defer { openingDraft = false }
            guard await chat.openSession(initialDraft: draft) else {
                draftError = chat.conversation.notice.map(DiagnosticsReport.redacted) ?? String(localized: "没能打开这个对话。")
                return
            }
            dismiss()
            openWindow(id: "pallas")
        }
        #else
        remote.startDraft(draft)
        dismiss()
        shell.returnToChat()
        #endif
    }
}
