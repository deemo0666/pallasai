import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// The master switch, one switch per event kind, and access to system notification settings.
struct NotificationSettingsPage: View {
    @AppStorage("notifyEnabled") private var enabled = true
    @AppStorage("notifyDone") private var done = true
    @AppStorage("notifyFailed") private var failed = true
    @AppStorage("notifyApproval") private var approval = true
    @AppStorage("notifyQuestion") private var question = true
    @AppStorage("notifyBot") private var bot = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        List {
            if enabled, status == .denied {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("系统通知已关闭", systemImage: "bell.slash").font(.subheadline.weight(.semibold))
                        #if os(iOS)
                        Text("App 在后台时收不到任何提醒").font(.caption)
                        #endif
                        Button { openSystemSettings() } label: { Label("去开启", systemImage: "chevron.right").labelStyle(.titleOnly) }
                            .font(.subheadline.weight(.medium))
                    }.foregroundStyle(SettingsStyle.warning).padding(.vertical, 4)
                }.listRowBackground(SettingsStyle.warning.opacity(0.12))
            }
            Section {
                SettingsToggleRow(title: String(localized: "允许通知"), isOn: Binding(get: { enabled }, set: { turn($0) }))
                    .accessibilityIdentifier("notifyEnabled")
                #if os(macOS)
                if enabled, status == .notDetermined || status == .provisional {
                    Button("打开通知") { Task { await refresh(ask: true) } }
                }
                #endif
            }.listRowBackground(ChatColors.chip)
            Section {
                SettingsToggleRow(title: String(localized: "一轮完成"), isOn: $done)
                SettingsToggleRow(title: String(localized: "出错或被停下"), isOn: $failed)
                SettingsToggleRow(title: String(localized: "等你确认"), isOn: $approval)
                SettingsToggleRow(title: String(localized: "向你提问"), isOn: $question)
                SettingsToggleRow(title: String(localized: "AI 团队消息"), isOn: $bot)
            } header: { Text("提醒") }
                .disabled(!enabled).listRowBackground(ChatColors.chip)
            Section {
                Button { openSystemSettings() } label: {
                    #if os(macOS)
                    SettingsRowLabel(title: String(localized: "系统通知设置"))
                    #else
                    SettingsRowLabel(title: String(localized: "声音、横幅与锁屏"))
                    #endif
                }.accessibilityIdentifier("notifySystem")
            } header: { Text("系统设置") }
                .listRowBackground(ChatColors.chip)
        }
        .settingsPage(String(localized: "通知"))
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            #if os(macOS)
            await refresh(ask: false)
            #else
            await refresh(ask: true)
            #endif
        }
    }

    private func turn(_ on: Bool) {
        enabled = on
        if on { Task { await refresh(ask: true) } }
    }

    private func refresh(ask: Bool) async {
        let center = UNUserNotificationCenter.current()
        var current = await center.notificationSettings().authorizationStatus
        #if os(macOS)
        let canAsk = current == .notDetermined || current == .provisional
        #else
        let canAsk = current == .notDetermined
        #endif
        if ask, enabled, canAsk {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            current = await center.notificationSettings().authorizationStatus
            #if os(macOS)
            NotificationOffer.shared.settled()
            #endif
        }
        status = current
    }

    private func openSystemSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #else
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #endif
    }
}
