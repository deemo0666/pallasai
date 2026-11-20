#if os(iOS)
import SwiftUI

/// 设置 › 能力 › 连接器: what the AI may read and change, found on this iPhone (system data, mail apps that are
/// installed), each with a switch for this phone's AI and one for paired computers.
struct ConnectorsPage: View {
    @ObservedObject private var mail = MailAccounts.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var installed: Set<ConnectorID> = []
    @State private var states: [ConnectorID: PermissionState] = [:]
    /// Bumped when a switch changes, so the rows read UserDefaults again.
    @State private var revision = 0

    private var found: [ConnectorID] { ConnectorID.allCases.filter { installed.contains($0) } }
    private var more: [ConnectorID] { ConnectorID.allCases.filter { !installed.contains($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCard(title: String(localized: "在这台手机上找到")) { rows(found) }
                if !more.isEmpty {
                    SettingsCard(title: String(localized: "更多连接器")) { rows(more) }
                }
            }.padding(.horizontal, 16).padding(.top, 8).id(revision)
        }
        .settingsPage(String(localized: "连接器"))
        .navigationBarTitleDisplayMode(.large)
        // Entering the page and coming back from 设置 or an app store: scan again.
        .task(id: scenePhase) { if scenePhase == .active { await scan() } }
    }

    @ViewBuilder private func rows(_ ids: [ConnectorID]) -> some View {
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
            if index > 0 { SettingsDivider() }
            NavigationLink {
                ConnectorDetailPage(connector: id, onChange: { revision += 1 })
            } label: {
                let value = value(id)
                SettingsRowLabel(symbol: id.symbol, title: id.title, value: value.text, valueColor: value.color).padding(.horizontal, 16)
            }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("connector-" + id.rawValue)
        }
    }

    private func value(_ id: ConnectorID) -> (text: String, color: Color?) {
        if let provider = id.mail {
            guard mail.account(provider) != nil else { return (String(localized: "未连接"), Color.accentColor) }
        } else if let state = states[id], state != .granted {
            return (state.label, state == .denied || state == .restricted ? SettingsStyle.warning : nil)
        }
        return (Connectors.allowed(id, .phone) ? String(localized: "已开启") : String(localized: "已关闭"), nil)
    }

    private func scan() async {
        installed = Set(ConnectorID.allCases.filter(\.installed))
        var next: [ConnectorID: PermissionState] = [:]
        for id in ConnectorID.allCases {
            if let permission = id.permission { next[id] = await SystemAccess.read(permission) }
        }
        states = next
        revision += 1
    }
}

/// One connector: its permission or account, and who may use it.
struct ConnectorDetailPage: View {
    let connector: ConnectorID
    var onChange: () -> Void = {}
    @ObservedObject private var mail = MailAccounts.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: PermissionState?
    @State private var phone = true
    @State private var computers = false
    @State private var failure: String?
    @State private var confirmDisconnect = false

    private static let danger = ChatColors.adaptive(0x942E2A, 0xFFB5AB)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCard { source }
                if usable {
                    SettingsCard(title: String(localized: "谁可以使用")) {
                        SettingsToggleRow(symbol: "phone", title: String(localized: "这台手机上的 AI"), isOn: Binding(
                            get: { phone }, set: { phone = $0; Connectors.set(connector, .phone, $0); onChange() }))
                            .padding(.horizontal, 16).accessibilityIdentifier("connectorPhone")
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8)
        }
        .settingsPage(connector.title)
        .navigationBarTitleDisplayMode(.large)
        .task(id: scenePhase) {
            phone = Connectors.allowed(connector, .phone)
            computers = Connectors.allowed(connector, .computer)
            if scenePhase == .active, let permission = connector.permission { state = await SystemAccess.read(permission) }
        }
        .alert(String(localized: "断开 \(connector.title)？"), isPresented: $confirmDisconnect) {
            Button(String(localized: "断开"), role: .destructive) { disconnect() }
            Button(String(localized: "取消"), role: .cancel) {}
        }
    }

    /// Mail needs an account; the system stores need their permission (日历 that may only add events is enough to add).
    private var usable: Bool {
        if let provider = connector.mail { return mail.account(provider) != nil }
        return state != nil && state != .denied && state != .restricted
    }

    @ViewBuilder private var source: some View {
        if let provider = connector.mail {
            if let account = mail.account(provider) {
                SettingsRowLabel(symbol: connector.symbol, title: account.address.isEmpty ? connector.title : account.address,
                                 value: String(localized: "已连接"), valueColor: SettingsStyle.ok, chevron: false).padding(.horizontal, 16)
                SettingsDivider()
                Button { confirmDisconnect = true } label: {
                    SettingsRowLabel(symbol: "xmark", title: String(localized: "断开连接"), danger: true, chevron: false).padding(.horizontal, 16)
                }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("connectorDisconnect")
            } else {
                Button { Task { await connect(provider) } } label: {
                    HStack(spacing: 12) {
                        SettingsIconDisc(symbol: connector.symbol, prominent: true)
                        Text(String(localized: "连接 \(connector.title)")).fontWeight(.semibold).foregroundStyle(ChatColors.ink)
                        Spacer(minLength: 8)
                        if mail.signingIn == provider { ProgressView() }
                        else { Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(ChatColors.muted) }
                    }.padding(.horizontal, 16).frame(minHeight: 62).contentShape(Rectangle())
                }.buttonStyle(SettingsRowStyle()).disabled(mail.signingIn != nil).accessibilityIdentifier("connectorConnect")
            }
            if let failure {
                Text(failure).font(.callout).foregroundStyle(Self.danger).padding(.horizontal, 16).padding(.bottom, 12)
            }
        } else if let permission = connector.permission {
            Button { Task { await ask(permission) } } label: {
                SettingsRowLabel(symbol: connector.symbol, title: String(localized: "系统权限"), value: state?.label ?? String(localized: "正在读取…"),
                                 valueColor: state == .granted ? SettingsStyle.ok : state == .denied ? SettingsStyle.warning : nil,
                                 chevron: state != .granted).padding(.horizontal, 16)
            }.buttonStyle(SettingsRowStyle()).disabled(state == nil || state == .granted).accessibilityIdentifier("connectorPermission")
        }
    }

    private func connect(_ provider: MailProvider) async {
        failure = nil
        failure = await mail.signIn(provider)
        if mail.account(provider) != nil {
            // A newly connected mailbox starts on for this phone; computers stay as the person set them.
            phone = Connectors.allowed(connector, .phone)
        }
        onChange()
    }

    private func disconnect() {
        guard let provider = connector.mail else { return }
        Task {
            await mail.signOut(provider)
            onChange()
        }
    }

    private func ask(_ permission: SystemPermission) async {
        if state == .denied {
            if let url = SystemAccess.settingsURL(for: permission) { openURL(url) }
            return
        }
        state = await SystemAccess.request(permission)
        onChange()
    }
}

#endif
