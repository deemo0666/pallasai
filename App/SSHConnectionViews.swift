import SwiftUI

// MARK: - 启动 DSH？

/// Asks whether to start DSH on a host whose configured `dsh web` is not running.
@MainActor
final class SSHLaunchPrompt: Identifiable {
    let id = UUID()
    let question: SSHLaunchQuestion
    private var completion: ((Bool) -> Void)?
    init(_ question: SSHLaunchQuestion, decide: @escaping (Bool) -> Void) { self.question = question; completion = decide }
    func decide(_ start: Bool) { let pending = completion; completion = nil; pending?(start) }

    /// A closure for `SSHTunnel.open(ask:)` that shows the question through [prompt].
    static func asker(_ prompt: Binding<SSHLaunchPrompt?>) -> @Sendable (SSHLaunchQuestion) async -> Bool {
        { question in await present(question, in: prompt) }
    }

    private static func present(_ question: SSHLaunchQuestion, in prompt: Binding<SSHLaunchPrompt?>) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { done in
            prompt.wrappedValue = SSHLaunchPrompt(question) { done.resume(returning: $0) }
        }
    }
}

extension View {
    func sshLaunchPrompt(_ prompt: Binding<SSHLaunchPrompt?>) -> some View {
        alert("在主机上启动服务？", isPresented: Binding(get: { prompt.wrappedValue != nil }, set: { if !$0 { prompt.wrappedValue?.decide(false); prompt.wrappedValue = nil } }),
              presenting: prompt.wrappedValue) { request in
            Button("取消", role: .cancel) { request.decide(false); prompt.wrappedValue = nil }
            Button("启动并连接") { request.decide(true); prompt.wrappedValue = nil }
        } message: { request in
            let problem = String(localized: "「\(request.question.host)」的端口 \(String(request.question.port)) 上没有服务在运行。")
            #if os(macOS)
            Text(problem + "\n\n" + String(localized: "可以通过 SSH 运行 dsh web（只监听主机本地）。") +
                 (request.question.dshPath.map { "\n" + $0 } ?? ""))
            #else
            Text(problem + (request.question.dshPath.map { String(localized: "\n\n主机上找到了 \($0)，可以由手机通过 SSH 启动（运行 dsh web，只监听主机本地）。") } ?? String(localized: "\n\n可以由手机通过 SSH 运行 dsh web（只监听主机本地）。")))
            #endif
        }
    }
}

// MARK: - 网络详情

/// The last connection to one SSH host: endpoints, login and DSH launch, and
/// each stage with its time; a failed stage is marked.
struct SSHConnectionDetail: View {
    let profileID: UUID
    @ObservedObject private var store = SSHReports.shared

    var body: some View {
        List {
            if let report = store.reports[profileID] {
                Section {
                    LabeledContent("状态") {
                        if report.finished == nil { Text("连接中…") }
                        else if let failure = report.failure { Text("在「\(failure.title)」这一步失败").foregroundStyle(DrawerPalette.danger) }
                        else { Text("已连接") }
                    }
                    LabeledContent("时间") { Text(report.started.formatted(date: .abbreviated, time: .standard)) }
                    if let message = report.failureMessage {
                        Text(message).font(.footnote).foregroundStyle(DrawerPalette.danger).textSelection(.enabled)
                    }
                } header: { Text("上次连接") }
                Section("端点") {
                    row("SSH", report.sshEndpoint)
                    if let remote = report.remoteEndpoint { row(String(localized: "服务（主机上）"), remote) }
                    if let local = report.localEndpoint { row(String(localized: "本机转发端口"), local) }
                }
                Section("连接方式") {
                    row(String(localized: "登录"), report.login.isEmpty ? "—" : report.login)
                    if let key = report.hostKey { row(String(localized: "主机指纹"), key) }
                    row(String(localized: "服务"), report.mode)
                    if let outcome = report.outcome { row(String(localized: "结果"), outcome) }
                    if let path = report.dshPath { row(String(localized: "dsh 位置"), path) }
                }
                Section("各阶段") {
                    ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: step.skipped == true ? "arrow.turn.down.right" : step.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(step.skipped == true ? ChatColors.muted : step.ok ? Color.green : DrawerPalette.danger)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.stage.title)
                                if let detail = step.detail { Text(detail).font(.caption).foregroundStyle(ChatColors.muted) }
                            }
                            Spacer(minLength: 4)
                            if step.seconds > 0.05 { Text(String(format: String(localized: "%.1f 秒"), step.seconds)).font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted) }
                        }
                    }
                }
            } else {
                Text("还没有连接过这台主机").foregroundStyle(ChatColors.muted)
            }
        }
        .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("网络详情").inlineNavigationTitle()
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(verbatim: value).font(.callout.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }
}

/// One line for the SSH form: how the last connection went.
struct SSHConnectionSummary: View {
    let profileID: UUID
    @ObservedObject private var store = SSHReports.shared

    var body: some View {
        if let report = store.reports[profileID] {
            NavigationLink { SSHConnectionDetail(profileID: profileID) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("网络详情")
                    Text(summary(report)).font(.caption).foregroundStyle(report.failure == nil ? ChatColors.muted : DrawerPalette.danger).lineLimit(2)
                }
            }.accessibilityIdentifier("sshNetworkDetail")
        }
    }

    private func summary(_ report: SSHConnectionReport) -> String {
        if report.finished == nil { return String(localized: "连接中…") }
        if let failure = report.failure { return String(localized: "上次在「\(failure.title)」这一步失败") }
        return [report.remoteEndpoint.map { String(localized: "服务") + " " + $0 }, report.outcome].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Present the failure at the connection entry point, never in an unrelated conversation.
extension View {
    func remoteConnectionAlert(_ error: Binding<HostError?>) -> some View {
        alert(error.wrappedValue?.message ?? String(localized: "没有连上"),
              isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }),
              presenting: error.wrappedValue) { _ in
            Button("好", role: .cancel) { error.wrappedValue = nil }
        } message: { failure in
            Text(failure.detail ?? String(localized: "检查设置后再试一次。"))
        }
    }
}
