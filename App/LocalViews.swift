import SwiftUI
import UserNotifications
import WebKit

// MARK: - 设置

/// The hub's categories, each a page of its own. The raw values name the rows for UI tests
/// (`settingsGroup.<raw>`) and keep their old spelling: `ai` is 对话, `hosts` is 高级.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case account, abilities, ai, appearance, general, help, hosts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: String(localized: "账号与模型")
        case .ai: String(localized: "对话")
        case .abilities: String(localized: "能力")
        case .appearance: String(localized: "外观")
        case .general: String(localized: "通用")
        case .hosts: String(localized: "高级")
        case .help: String(localized: "帮助与关于")
        }
    }

    var symbol: String {
        switch self {
        case .account: "key"
        case .ai: "shield"
        case .abilities: "tap"
        case .appearance: "half"
        case .general: "sliders"
        case .hosts: "wrench"
        case .help: "info"
        }
    }
}

/// What the hub shows next to rows that depend on the connected host.
private struct HostFacts: Equatable {
    var permission: String?
    var permissionRisky = false
    var plugins: Int?
}

/// 设置: search, a card with the three things to set up (账号, 手机操控, 我的电脑), then one row
/// per category — 账号与模型, 能力, 对话, 外观, 通用, 帮助与关于, 高级 — each opening its own page.
struct PreferencesView: View {
    @ObservedObject var remote: Conversation
    /// The active host's name (overview card, 运行参数, 模型).
    var hostName: String? = nil
    /// Opens 我的电脑; the host list lives outside settings.
    var openRemoteHosts: (() -> Void)? = nil
    /// 手机操控页的「去插件市场」和「回到对话里说一句」，由外壳接上。
    var openPluginMarket: (() -> Void)? = nil
    var askInChat: ((String) -> Void)? = nil
    /// 本机运行 switched on or off: the shell connects to it or lets it go.
    var engineChanged: ((Bool) -> Void)? = nil
    /// The host in use is this phone's own engine.
    var onPhone = false
    @ObservedObject private var account = DeepSeekAccount.shared
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    private var claudeSignedIn: Bool { false }
    @AppStorage("thirdPartySaved") private var thirdPartySaved = 0
    @AppStorage(EmbeddedEngine.enabledKey) private var engineEnabled = true
    @AppStorage("accentPalette") private var paletteName = "石墨"
    @AppStorage("hostProfiles") private var profileData = Data()
    @AppStorage("notifyEnabled") private var notifyEnabled = true
    @AppStorage("settingsSearchRecent") private var recentText = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var route: SettingsTarget?
    @State private var category: SettingsCategory?
    /// A row opened from a category page.
    @State private var pageRoute: SettingsTarget?
    /// Two columns: the hub on the left, `selected` beside it.
    @State private var split = false
    @State private var selected = SettingsCategory.account
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var thirdPartyCount = 0
    @State private var facts = HostFacts()
    @State private var notifyStatus: UNAuthorizationStatus?
    /// 本机运行 is about to be switched off: asks first.
    @State private var confirmEngineOff = false

    private var host: Harness? { remote.connection }
    private var hostLabel: String { hostName ?? String(localized: "我的电脑") }
    private var searching: Bool { searchFocused || !query.isEmpty }
    private var recent: [String] { recentText.split(separator: "\n").map(String.init) }
    private var hostCount: Int {
        ((try? JSONDecoder().decode([HostProfile].self, from: profileData)) ?? []).count
    }
    /// Computers and paired phones / iPads, for 我的设备.
    private var deviceCount: Int {
        hostCount
    }
    private var version: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        GeometryReader { proxy in
            let column = SplitLayout.column(for: proxy.size, regular: sizeClass == .regular)
            Group {
                if let column {
                    HStack(spacing: 0) {
                        hubColumn.frame(width: column)
                        Rectangle().fill(ChatColors.line).frame(width: 0.5).ignoresSafeArea(edges: .bottom)
                        splitDetail.frame(maxWidth: .infinity)
                    }
                } else {
                    hubColumn
                }
            }.onChange(of: column != nil, initial: true) { _, on in split = on }
        }
        .settingsPage(String(localized: "设置"))
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $route) { destination($0) }
        .navigationDestination(item: $category) { categoryPage($0) }
        .task(id: host.map { ObjectIdentifier($0) }) { await loadFacts() }
        .task(id: scenePhase) {
            if scenePhase == .active { notifyStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        }
        .onAppear(perform: refreshKeyState)
        .onChange(of: thirdPartySaved) { _, _ in refreshKeyState() }
    }

    private var hubColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                searchField.padding(.bottom, 14)
                if searching { searchResults } else { hub }
            }.padding(.horizontal, 16).padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The right column of the split view: the chosen category's rows (外观 is its own page).
    @ViewBuilder private var splitDetail: some View {
        if selected == .appearance {
            ThemeSettings()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(selected.title).font(.title.weight(.bold)).padding(.horizontal, 4).padding(.bottom, 14)
                        .accessibilityAddTraits(.isHeader)
                    SettingsCard { categoryRows(selected) }
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
            }
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                LineGlyph(name: "search").foregroundStyle(ChatColors.muted)
                TextField("搜索设置", text: $query).focused($searchFocused).submitLabel(.search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ChatColors.muted) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }.padding(.horizontal, 14).frame(minHeight: 44)
                .background(ChatColors.segmentWell, in: Capsule())
            if searching {
                Button("取消") { query = ""; searchFocused = false }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SettingsCard(title: String(localized: "常用")) {
                HStack(spacing: 8) {
                    ForEach([String(localized: "深色模式"), String(localized: "权限"), String(localized: "字号")], id: \.self) { word in
                        Button { query = word } label: {
                            Text(word).font(.subheadline).padding(.horizontal, 14).frame(minHeight: 34)
                                .background(ChatColors.segmentWell, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(12)
            }
            if !recent.isEmpty {
                SettingsCard(title: String(localized: "最近")) {
                    ForEach(Array(recent.enumerated()), id: \.element) { index, word in
                        if index > 0 { SettingsDivider() }
                        Button { query = word } label: {
                            SettingsRowLabel(symbol: "clock", title: word, chevron: false).padding(.horizontal, 16)
                        }.buttonStyle(SettingsRowStyle())
                    }
                }
            }
        } else {
            let hits = SettingsSpot.hits(query)
            if hits.isEmpty {
                VStack(spacing: 10) {
                    LineGlyph(name: "search", size: 28).foregroundStyle(ChatColors.muted)
                    Text("没有找到相关设置").foregroundStyle(ChatColors.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                SettingsCard {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, spot in
                        if index > 0 { SettingsDivider(inset: 16) }
                        Button { open(spot) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(spot.title).foregroundStyle(ChatColors.ink)
                                Text(spot.path.joined(separator: " › ")).font(.caption).foregroundStyle(ChatColors.muted)
                            }.padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(SettingsRowStyle())
                            .accessibilityLabel(spot.title).accessibilityHint(spot.path.joined(separator: " › "))
                    }
                }
            }
        }
    }

    private func open(_ spot: SettingsSpot) {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        recentText = ([word] + recent.filter { $0 != word }).prefix(5).joined(separator: "\n")
        query = ""; searchFocused = false
        switch spot.target {
        case .textSize, .foldTurns: if split { selected = .appearance } else { route = .theme }
        case .engine: if split { selected = .hosts } else { category = .hosts }
        case .language: if split { selected = .general } else { category = .general }
        case .remoteHosts: openRemoteHosts?()
        default: route = spot.target
        }
    }

    // MARK: Hub

    @ViewBuilder private var hub: some View {
        setupCard.padding(.bottom, 18)
        SettingsCard {
            ForEach(Array(SettingsCategory.allCases.enumerated()), id: \.element) { index, group in
                if index > 0 { SettingsDivider() }
                let value = categoryValue(group)
                let chosen = split && selected == group
                Button {
                    if split { selected = group } else if group == .appearance { route = .theme } else { category = group }
                } label: {
                    SettingsRowLabel(symbol: group.symbol, title: group.title, value: value.text,
                                     valueColor: value.color, dot: value.dot, chevron: !split, selected: chosen).padding(.horizontal, 16)
                        .background(chosen ? ChatColors.selected : Color.clear)
                }.buttonStyle(SettingsRowStyle()).accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityLabel(group.title).accessibilityValue(value.text ?? "")
                    .accessibilityIdentifier("settingsGroup." + group.rawValue)
            }
        }
        Text(verbatim: "Pallas Agent").font(.caption.weight(.semibold)).foregroundStyle(ChatColors.muted)
            .frame(maxWidth: .infinity).padding(.top, 8)
    }

    /// 已登录, nothing with a key of one's own, else 未登录.
    private var accountValue: String? {
        if account.signedIn || (onPhone && (chatGPT.signedIn || claudeSignedIn)) { return String(localized: "已登录") }
        return thirdPartyCount > 0 ? nil : String(localized: "未登录")
    }

    /// The short current value on a category row.
    private func categoryValue(_ group: SettingsCategory) -> (text: String?, color: Color?, dot: Color?) {
        switch group {
        case .account: (accountValue, nil, nil)
        case .appearance: (paletteName.localized, nil, Color.accentColor)
        case .help:
            if let newer = UpdateChecker.shared.newer { (String(localized: "有新版 ") + newer.version, Color.accentColor, nil) }
            else { (version, nil, nil) }
        case .ai, .abilities, .general, .hosts: (nil, nil, nil)
        }
    }

    /// The three things a person sets up, each with its state and the page that does it:
    /// 账号 (signed in, or a key of their own), 手机操控 and 我的设备.
    private var setupCard: some View {
        let onComputer = !onPhone && linkLabel.on
        let signedIn = account.signedIn || (onPhone && (chatGPT.signedIn || claudeSignedIn))
        return HStack(spacing: 0) {
            stateCell("key", String(localized: "账号"),
                      signedIn ? String(localized: "已登录") : thirdPartyCount > 0 ? String(localized: "已填 API Key") : String(localized: "去登录"),
                      pending: !signedIn && thirdPartyCount == 0) {
            route = onPhone && claudeSignedIn && !account.signedIn && !chatGPT.signedIn ? .claude
                : onPhone && !account.signedIn ? .chatGPT : .account
        }
                .accessibilityIdentifier("setupAccount")
            stateCell("desktop", String(localized: "我的设备"),
                      onComputer ? String(localized: "已连接 ") + hostLabel : deviceCount > 0 ? String(localized: "\(deviceCount) 台") : String(localized: "去连接"),
                      pending: !onComputer && deviceCount == 0) { openRemoteHosts?() }
                .disabled(openRemoteHosts == nil).accessibilityIdentifier("preferencesProvider")
        }.background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// One cell of the setup card; `pending` tints the value as something still to do.
    private func stateCell(_ symbol: String, _ title: String, _ value: String, pending: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                LineGlyph(name: symbol, size: 20).foregroundStyle(ChatColors.ink).padding(.bottom, 3)
                Text(title).font(.footnote).foregroundStyle(ChatColors.muted).lineLimit(1).minimumScaleFactor(0.75)
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(pending ? Color.accentColor : ChatColors.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }.padding(.leading, 16).padding(.trailing, 4).padding(.top, 14).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(SettingsRowStyle())
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(value)
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Category pages

    private func link(_ target: SettingsTarget, _ symbol: String, _ title: String,
                      value: String? = nil, valueColor: Color? = nil, dot: Color? = nil) -> some View {
        Button { if split { route = target } else { pageRoute = target } } label: {
            SettingsRowLabel(symbol: symbol, title: title, value: value, valueColor: valueColor, dot: dot).padding(.horizontal, 16)
        }.buttonStyle(SettingsRowStyle())
            .accessibilityLabel(title).accessibilityValue(value ?? "")
    }

    @ViewBuilder private func categoryPage(_ group: SettingsCategory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCard { categoryRows(group) }
            }.padding(.horizontal, 16).padding(.top, 8)
        }
        .settingsPage(group.title)
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $pageRoute) { destination($0) }
    }

    @ViewBuilder private func categoryRows(_ group: SettingsCategory) -> some View {
        switch group {
        case .account:
            if onPhone {
                link(.chatGPT, "key", "ChatGPT", value: chatGPT.signedIn ? String(localized: "已登录") : String(localized: "未登录"))
                    .accessibilityIdentifier("settingsChatGPT")
                SettingsDivider()
            }
            link(.thirdParty, "box", String(localized: "使用自己的 API Key"), value: thirdPartyCount > 0 ? String(localized: "\(thirdPartyCount) 个") : nil)
                .accessibilityIdentifier("settingsThirdParty")
            SettingsDivider()
            link(.account, "key", String(localized: "DeepSeek 账号"), value: account.signedIn ? String(localized: "已登录") : String(localized: "未登录"))
                .accessibilityIdentifier("settingsAccount")
            SettingsDivider()
            link(.models, "spark", String(localized: "模型")).accessibilityIdentifier("settingsModels")
        case .abilities:
            Button { openRemoteHosts?() } label: {
                SettingsRowLabel(symbol: "desktop", title: String(localized: "我的设备"),
                                 value: deviceCount > 0 ? String(localized: "\(deviceCount) 台") : nil).padding(.horizontal, 16)
            }.buttonStyle(SettingsRowStyle()).disabled(openRemoteHosts == nil).accessibilityIdentifier("settingsComputers")
            #if os(iOS)
            SettingsDivider()
            link(.connectors, "envelope", String(localized: "连接器")).accessibilityIdentifier("settingsConnectors")
            #endif
            SettingsDivider()
            link(.webSearch, "globe", String(localized: "联网搜索"))
            SettingsDivider()
            link(.plugins, "blocks", String(localized: "插件"), value: facts.plugins.flatMap { $0 > 0 ? String(localized: "\($0) 个") : nil })
            if EmbeddedEngine.available {
                SettingsDivider()
                link(.memory, "brain", String(localized: "记忆"), value: MemoryFiles.phone.settings().enabled ? String(localized: "已开启") : String(localized: "未开启"))
                    .accessibilityIdentifier("settingsMemory")
                SettingsDivider()
                link(.folders, "folder", String(localized: "授权文件夹")).accessibilityIdentifier("settingsFolders")
            }
        case .ai:
            link(.permission, "shield", String(localized: "权限"), value: facts.permission,
                 valueColor: facts.permissionRisky ? SettingsStyle.warning : nil)
                .accessibilityIdentifier("preferencesPermission")
        case .appearance: EmptyView()
        case .general:
            LanguageRow()
            SettingsDivider()
            link(.interface, "panel", String(localized: "界面"))
            SettingsDivider()
            link(.notifications, "bell", String(localized: "通知"), value: notifyValue.text, valueColor: notifyValue.color)
            SettingsDivider()
            link(.privacy, "share", String(localized: "隐私与分享"))
        case .help:
            link(.about, "info", String(localized: "关于"), value: UpdateChecker.shared.newer.map { String(localized: "有新版 ") + $0.version } ?? version)
        case .hosts:
            if EmbeddedEngine.available {
                SettingsToggleRow(symbol: "phone", title: String(localized: "本机运行"),
                                  isOn: Binding(get: { engineEnabled }, set: { on in
                                      if on { engineEnabled = true; engineChanged?(true) } else { confirmEngineOff = true }
                                  }))
                    .padding(.horizontal, 16).accessibilityIdentifier("settingsEngine")
                    .alert(String(localized: "关闭本机运行？"), isPresented: $confirmEngineOff) {
                        Button(String(localized: "关闭"), role: .destructive) { engineEnabled = false; engineChanged?(false) }
                        Button(String(localized: "取消"), role: .cancel) {}
                    } message: { Text("关闭后，这台手机不能自己聊天，只能连接电脑使用。") }
                SettingsDivider()
            }
            link(.engineStatus, "cpu", String(localized: "本机运行状态")).accessibilityIdentifier("settingsEngineStatus")
            SettingsDivider()
            link(.engineParams, "sliders", String(localized: "运行参数"), value: hostLabel)
            SettingsDivider()
            link(.diagnostics, "wrench", String(localized: "诊断")).accessibilityIdentifier("settingsDiagnostics")
            SettingsDivider()
            link(.performance, "bolt", String(localized: "性能"), value: PerformanceSettings.shared.mode.title)
                .accessibilityIdentifier("settingsPerformance")
        }
    }

    private var linkLabel: (text: String, warn: Bool, on: Bool) {
        switch remote.phase {
        case .ready, .replying: (String(localized: "已连接"), false, true)
        case .connecting: (String(localized: "正在连接…"), false, false)
        case .offline: remote.notice == nil ? (String(localized: "未连接"), false, false) : (String(localized: "连接失败"), true, false)
        }
    }


    private var notifyValue: (text: String, color: Color?) {
        if !notifyEnabled { return (String(localized: "已关闭"), ChatColors.muted.opacity(0.7)) }
        if notifyStatus == .denied { return (String(localized: "系统已关闭"), SettingsStyle.warning) }
        return (String(localized: "已开启"), nil)
    }

    private func refreshKeyState() {
        thirdPartyCount = ThirdPartyProviders.configured().count
    }

    private func loadFacts() async {
        guard let host else { facts = HostFacts(); return }
        var next = HostFacts()
        if let state = try? await HostPermissionState.read(host, session: nil), !state.invalidDefault, !state.hostDefault.isEmpty {
            let option = state.options.first { $0.value == state.hostDefault } ?? PermissionOption(value: state.hostDefault)
            next.permission = option.title
            next.permissionRisky = option.risk != nil
        }
        if let bundles = try? await host.rpcValue("pluginManager/listBundles", args: [:]) as? [Object] {
            next.plugins = bundles.filter { $0["installed"] as? Bool != false }.count
        }
        guard !Task.isCancelled else { return }
        facts = next
    }

    @ViewBuilder private func destination(_ target: SettingsTarget) -> some View {
        switch target {
        case .account: DeepSeekAccountPage()
        case .chatGPT: ChatGPTAccountPage()
        case .claude, .decisionAI, .phone, .phoneCall, .observe, .tailscale: EmptyView()
        case .thirdParty: ThirdPartyListPage()
        case .models: HostModelsPage(remote: remote, host: host, hostLabel: hostLabel)
        case .permission: HostPermissionView(host: host)
        case .memory: MemoryPage()
        case .webSearch:
            if let host { HostWebSearchPage(host: host) }
            else { OfflineFeaturePage(title: String(localized: "联网搜索")) }
        case .plugins:
            if let host { HostPluginsScreen(host: host).navigationTitle("插件") } else { OfflineFeaturePage(title: String(localized: "插件")) }
        case .folders: AuthorizedFoldersPage()
        case .theme: ThemeSettings()
        case .interface, .enterSends, .quickPanel, .tableTint: InterfaceSettings()
        case .notifications: NotificationSettingsPage()
        case .privacy: PrivacySettingsPage(host: host, hostLabel: hostLabel)
        case .connectors:
            #if os(iOS)
            ConnectorsPage()
            #else
            EmptyView()
            #endif
        case .performance: PerformanceSettingsPage()
        case .engineStatus: EngineStatusPage(remote: remote)
        case .diagnostics: DiagnosticsPage(remote: remote)
        case .sharedLinks: SharedLinksView()
        case .engineParams:
            if let host { HostSettings(host: host, hostLabel: hostLabel) } else { OfflineFeaturePage(title: String(localized: "运行参数")) }
        case .about: AboutSettingsPage()
        case .community: CommunityPage(remote: remote)
        case .licenses: ThirdPartyLicensesPage()
        case .textSize, .foldTurns, .remoteHosts, .engine, .language: EmptyView()
        }
    }
}

// MARK: - Pages the hub opens

/// 通用 › 语言：跟随系统或选一种界面语言，选了就存，重新打开 App 后生效。
struct LanguageRow: View {
    @State private var choice = AppLanguageChoice.current
    @State private var relaunch = false

    var body: some View {
        Menu {
            Picker(String(localized: "语言"), selection: Binding(get: { choice }, set: { value in
                guard value != choice else { return }
                choice = value
                relaunch = value.apply()
            })) {
                ForEach(AppLanguageChoice.allCases) { Text(verbatim: $0.title).tag($0) }
            }
        } label: {
            SettingsRowLabel(symbol: "character.bubble", title: String(localized: "语言"), value: choice.title).padding(.horizontal, 16)
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityIdentifier("settingsLanguage")
        .alert(String(localized: "重新打开 Pallas Agent 后切换语言"), isPresented: $relaunch) {
            Button(String(localized: "稍后"), role: .cancel) {}
            Button(String(localized: "退出 App")) { exit(0) }
        }
        .onAppear { choice = AppLanguageChoice.current }
    }
}
