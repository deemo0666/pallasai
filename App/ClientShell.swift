import SwiftUI

struct ClientShell: View {
    @StateObject private var remote = Conversation()
    @AppStorage("embeddedHostSelected") private var embedded = true
    @AppStorage(EmbeddedEngine.enabledKey) private var engineEnabled = true
    /// The conversation last open on 本机引擎: reconnecting goes back to it.
    @State private var engineSession: String?
    /// When the engine's connection last dropped on its own: automatic reconnects stop after three a minute.
    @State private var dropReconnects: [Date] = []
    @State private var startingEngine = false
    /// Offline only until a connection that is already on its way starts: the first frame before the
    /// launch restore runs, and the pause before reconnecting after a drop. The chat then says
    /// 「正在连接」 instead of flashing 「没能连上引擎 · 重新连接」.
    @State private var connectPending = ClientShell.restoresOnLaunch()
    /// That pending reconnect goes back to the conversation on screen: keep showing its messages.
    @State private var resumePending = false
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("hostProfiles") private var profileData = Data()
    @AppStorage("lastSSHProfile") private var lastProfile = ""
    @AppStorage("restoreHost") private var restoreHost = true
    @State private var tunnel: SSHTunnel?
    /// A paired computer just connected that this phone could also reach from anywhere.
    @State private var meshOffer: HostProfile?
    @State private var hostTrust: HostKeyPrompt?
    @State private var connectingID: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionError: HostError?
    private var hosts: [HostProfile] { (try? JSONDecoder().decode([HostProfile].self, from: profileData)) ?? [] }
    @AppStorage("accentPalette") private var palette = AccentPalette.graphite
    @AppStorage("accentHue") private var hue = 0.58
    @AppStorage("featureIconStyle") private var iconStyle = FeatureIconStyle.flat
    @State private var connectByAddress = false
    /// 「切换设备」里的「高级」展开着（用主机地址连接）。
    @State private var hostAdvancedOpen = false
    /// Signing in or out changes which models 本机 has: the chat's empty state follows at once.
    @ObservedObject private var account = DeepSeekAccount.shared
    @ObservedObject private var chatGPT = ChatGPTAccount.shared
    @State private var browserRoute: BrowserRoute?
    private func scenePhaseChanged(from old: ScenePhase, to phase: ScenePhase) {
        UITrace.note("scene \(old) -> \(phase) chat=\(remote.phase) session=\(Log.session(remote.connection?.sessionID))")
        if phase == .background { finishHostArchive() }
        if phase == .active { Task { await reviveEmbedded() } }
    }

    /// When the engine's model channels sync again: connecting, saving a key, signing in or out.
    private var channelSyncID: String {
        "\(embedded)/\(remote.connection.map { "\(ObjectIdentifier($0))" } ?? "")/\(remote.phase == .ready || remote.phase == .replying)/\(thirdPartySaved)/\(chatGPT.revision)"
    }
    /// The first-launch setup covers the chat until it is finished or passed over.
    @State private var onboarding = Onboarding.needed
    private enum AfterDismiss { case browser, address, settings, configureAI, account, quickPanel, feature(HostPanel), replay(ReplayDocument), share, manageHosts }
    /// 外壳推入的二级页：从右侧推入，可从左缘右滑返回。
    @State private var path: [ShellRoute] = []
    /// 从卡片打开的页面由卡片展开（iOS 18 起）。
    @Namespace private var cardZoom
    /// 模型和权限用底部弹层，其余主机功能推入。
    @State private var sheetPanel: HostPanel?
    @State private var afterDismiss: AfterDismiss?
    /// 侧栏与快捷面板的打开进度（跟手拖动、弹簧落位）。
    @State private var panels = SidePanels()
    @AppStorage(QuickEntry.swipeKey) private var quickSwipe = true
    @AppStorage("wallpaperEnabled") private var wallpaperOn = false
    @AppStorage(QuickEntry.enabledKey) private var quickEntries = QuickEntry.defaultEnabled
    /// 第三方接入每保存一次加一：本机引擎据此重新同步渠道。
    @AppStorage("thirdPartySaved") private var thirdPartySaved = 0
    private var liveHost: Harness? { remote.phase == .ready || remote.phase == .replying ? remote.connection : nil }
    private var quickTitle: String? { liveHost == nil ? nil : remote.title }
    @State private var subagents: (generation: UUID?, count: Int, running: Int) = (nil, 0, 0)
    private var harnessName: String { embedded ? String(localized: "本机") : hosts.first(where: { $0.id.uuidString == lastProfile })?.name ?? String(localized: "我的电脑") }
    /// 「名字 · SSH|远程 · 文件夹」 as in DSH; the phone's own engine is just 「本机」.
    private var headerDetail: String {
        let folder = remote.workspace.isEmpty ? "" : URL(fileURLWithPath: remote.workspace).lastPathComponent
        if embedded { return folder.isEmpty ? String(localized: "本机") : String(localized: "本机 · ") + folder }
        return [harnessName, tunnel != nil ? "SSH" : "", folder].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// The SSH host in use, for the 远程主机 page's 「正在使用」 card.
    private var activeRemote: ActiveRemoteHost? {
        guard !embedded else { return nil }
        let connected = remote.phase == .ready || remote.phase == .replying
        let status: String? = connected ? nil : remote.phase == .connecting ? String(localized: "正在连接…") : remote.notice
        if tunnel != nil, let profile = hosts.first(where: { $0.id.uuidString == lastProfile }) {
            return ActiveRemoteHost(name: profile.name.isEmpty ? profile.address : profile.name, address: profile.address,
                                    connected: connected, status: status, profileID: profile.id)
        }
        return nil
    }
    /// Something is connecting even though `remote.phase` may still read offline.
    private var connectingSoon: Bool { connectPending || startingEngine || connectingID != nil }
    private static func restoresOnLaunch() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "restoreHost") as? Bool ?? true else { return false }
        return (defaults.bool(forKey: "embeddedHostSelected") && EmbeddedEngine.enabled)
            || !(defaults.string(forKey: "lastSSHProfile") ?? "").isEmpty
    }
    private var canReconnect: Bool {
        (embedded && EmbeddedEngine.enabled) || hosts.contains { $0.id.uuidString == lastProfile }
    }
    private func reconnectLast() async {
        if embedded, EmbeddedEngine.enabled { await activateEmbedded(resume: engineSession, because: "reconnect-button"); return }
        if let host = hosts.first(where: { $0.id.uuidString == lastProfile }) {
            connectionTask = Task { await reconnect(host) }
        }
    }
    /// The drawer's host pill: 已连接 / 正在连接 / 连接失败 / 未连接.
    private var hostState: (text: String, color: Color) {
        switch remote.phase {
        case .ready, .replying: return (String(localized: "已连接"), ChatHeading<EmptyView>.connectedTone)
        case .connecting: return (String(localized: "正在连接"), .orange)
        case .offline where connectingSoon: return (String(localized: "正在连接"), .orange)
        case .offline: return (remote.notice != nil ? String(localized: "连接失败") : String(localized: "未连接"), remote.notice != nil ? .red : ChatColors.muted)
        }
    }

    @State private var search = ""
    @State private var searching = false
    @State private var selectingRows = false
    @State private var hostShare: (host: Harness, row: HostSessionRow)?
    @State private var hostShareMessages: [Message]?
    @State private var shareFocus: UUID?
    @State private var shareLoadFailed: String?
    @State private var externalReplay: ReplayDocument?
    @State private var pairLink: PairLink?
    @State private var importIssue: String?
    @State private var page: Page?
    @State private var feature: HostPanel?
    @State private var pluginShare: PluginShareRequest?
    @State private var pluginArchive: PluginArchiveRequest?
    @State private var filter = RemoteSessionFilter.all
    private var hostScope: String {
        if embedded { return "embedded" }
        if tunnel != nil { return lastProfile }
        return remote.connection?.origin.absoluteString ?? ""
    }
    @State private var issue: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The list sits beside the chat (wide screens), and whether it is folded away there.
    @State private var docked = false
    @State private var sidebarCollapsed = false
    @State private var hostArchive: (host: Harness, rows: [HostSessionRow], id: UUID)?
    @State private var archiveTask: Task<Void, Never>?
    private enum Page: String, Identifiable { case share, hosts; var id: Self { self } }
    private enum ShellRoute: Hashable {
        case features, settings, manageHosts, sessionInfo, configureAI, account
        case panel(HostPanel, fromCard: Bool)
        var fromCard: Bool { if case .panel(_, true) = self { true } else { false } }
    }

    var body: some View {
        NavigationStack(path: $path) {
        GeometryReader { bounds in
            ZStack(alignment: .leading) {
                if let dock = SplitLayout.column(for: bounds.size, regular: sizeClass == .regular) {
                    // Wide screens: the list stays beside the chat; the header's button folds it away.
                    HStack(spacing: 0) {
                        if !sidebarCollapsed {
                            drawerColumn(width: dock)
                                .background(ChatColors.page.ignoresSafeArea())
                                .transition(.move(edge: .leading))
                            Rectangle().fill(ChatColors.line).frame(width: 0.5).ignoresSafeArea()
                        }
                        chatView.environment(\.sidebarDocked, !sidebarCollapsed)
                    }
                    .onAppear { docked = true; if panels.drawerShown { panels.close(.drawer) } }
                    .onDisappear { docked = false }
                } else {
                    chatView
                    .accessibilityHidden(panels.drawerShown || panels.quickShown)
                    .allowsHitTesting(!panels.drawerShown && !panels.quickShown)
                    .modifier(SideParallax(panels: panels, drawerWidth: drawerWidth(bounds), quickWidth: quickWidth(bounds)))
                    if panels.drawerShown {
                        PanelScrim(panels: panels, side: .drawer, label: String(localized: "关闭侧栏")) { close() }
                        drawerColumn(width: drawerWidth(bounds))
                        .background {
                            ZStack {
                                SlidingGlass(panels: panels, side: .drawer, shape: UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28))
                                if wallpaperOn {
                                    ChatWallpaper(drawer: true).clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28))
                                }
                            }.ignoresSafeArea(.container, edges: .vertical)
                        }
                        .modifier(PanelSlide(panels: panels, side: .drawer, width: drawerWidth(bounds)))
                    }
                }
                if panels.quickShown {
                    PanelScrim(panels: panels, side: .quick, label: String(localized: "关闭快捷面板")) { panels.close(.quick) }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        QuickPanel(title: quickTitle, hostName: harnessName, workspace: remote.workspace,
                                   model: remote.modelName, host: liveHost, choose: openQuickEntry, changeModel: openQuickModel,
                                   close: { panels.close(.quick) }, expand: { push(.sessionInfo) })
                            .frame(width: quickWidth(bounds))
                            .background {
                                SlidingGlass(panels: panels, side: .quick, shape: UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28))
                                    .ignoresSafeArea(.container, edges: .vertical)
                            }
                            .modifier(PanelSlide(panels: panels, side: .quick, width: quickWidth(bounds)))
                    }
                }
            }
            // 搜索对话：淡入并从下方 2% 升起（240ms），收起 160ms 淡出。
            .overlay {
                ZStack {
                    if searching {
                        Group {
            if let host = remote.connection {
                HostSessionSearchPage(host: host, hostName: harnessName) { id in
                    guard remote.connection === host else { return }
                    close()
                    if id != host.sessionID { Task { await remote.openSession(id) } }
                }
            }
                        }
                        .background(ChatColors.canvas.ignoresSafeArea())
                        .environment(\.closeSearch, { withAnimation(Motion.std(Motion.quick)) { searching = false } })
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: bounds.size.height * 0.02)).animation(Motion.enter(Motion.standard)),
                            removal: .opacity.combined(with: .offset(y: bounds.size.height * 0.02)).animation(.timingCurve(0.3, 0, 0.8, 0.15, duration: Motion.quick))))
                    }
                }
            }
            // 聊天挪开时露出的边：垫一层同样的背景。
            .background { ChatWallpaper().ignoresSafeArea() }
            .background {
                SidePanelSwipe(panels: panels, active: path.isEmpty && !searching, drawer: !docked,
                               quick: quickSwipe && (!QuickEntry.enabled(quickEntries).isEmpty || quickTitle != nil),
                               drawerWidth: drawerWidth(bounds), quickWidth: quickWidth(bounds))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: ShellRoute.self) { destination($0) }
        }
        // 外壳推入的页面和它们再推入的页面都能用：回到聊天、切到本机引擎。
        .environment(\.shellActions, ShellActions(returnToChat: { path.removeAll() }, useEngine: { resume in
            issue = nil
            await activateEmbedded(resume: resume ? remote.connection?.sessionID ?? engineSession : nil, because: "settings", preserveNavigation: resume)
            return issue
        }))
        .onChange(of: feature) { _, panel in
            guard let panel else { return }
            feature = nil
            if panel == .models || panel == .permission { sheetPanel = panel } else { push(.panel(panel, fromCard: false)) }
        }
        .sheet(item: $sheetPanel) { panel in
            if let host = remote.connection {
                if panel == .models {
                    // With no model on 本机, the sheet leads to the sign-in page or to an API key of one's own.
                    HostModelSheet(chat: remote, host: host,
                                   signIn: embedded ? { sheetPanel = nil; push(.account) } : nil,
                                   ownKey: embedded ? { sheetPanel = nil; push(.configureAI) } : nil,
                                   chatGPT: embedded ? { sheetPanel = nil; Task { if let issue = await ChatGPTAccount.shared.signIn() { remote.notice = issue } } } : nil) {
                        SheetPage { HostModelsPage(remote: remote, host: host, hostLabel: harnessName) }
                    }.id(ObjectIdentifier(host))
                } else {
                    HostPanelView(panel: panel, chat: remote, host: host)
                        .presentationCornerRadius(28).presentationDetents([.fraction(0.73), .large])
                }
            }
        }
        .task(id: "\(hostScope)/\(remote.connection?.sessionGeneration.uuidString ?? "")/\(remote.phase)/\(scenePhase)") {
            guard scenePhase == .active else { subagents.generation = nil; return }
            guard let host = liveHost, !host.sessionID.isEmpty else { return }
            let generation = host.sessionGeneration
            if remote.phase == .replying, subagents.generation == generation { return }
            guard let all = try? await HostSessionRow.list(host), !Task.isCancelled,
                  remote.connection === host, host.sessionGeneration == generation else { return }
            let children = all.filter { $0.parent == host.sessionID }
            subagents = (generation, children.count, children.filter(\.running).count)
            if remote.phase == .ready {
                _ = HostReadHistory.update(all, current: host.sessionID, scope: hostScope)
                ConversationIndex.shared.update(all, scope: hostScope)
            }
        }
        // 本机引擎用设置里的第三方接入：连上时、保存后各同步一次。
        .task(id: channelSyncID) {
            guard embedded, remote.phase == .ready || remote.phase == .replying, let host = remote.connection else { return }
            do {
                var syncIssue: Error?
                do { try await remote.syncModelChannels(on: host) }
                catch { syncIssue = error }
                guard !Task.isCancelled, remote.connection === host else { return }
                try await remote.applyPendingAccountActivations(on: host)
                try await remote.applyPendingModelActivation(on: host)
                await remote.refreshModelCatalog(on: host)
                if let syncIssue { throw syncIssue }
            }
            catch {
                guard !Task.isCancelled, remote.connection === host else { return }
                remote.notice = String(localized: "模型服务没能同步到本机：") + error.localizedDescription
            }
        }
        .environment(\.showChatBrowser, { url in browserRoute = BrowserRoute(url: url) })
        .fullScreenCover(item: $browserRoute) { route in BrowserView(initialURL: route.url) }
        .sheet(item: $page, onDismiss: showNextPage) { page in
            switch page {
            case .hosts:
                VStack(alignment: .leading, spacing: 0) {
                    Text("切换设备").font(.title3.weight(.semibold)).foregroundStyle(ChatColors.ink).padding(.horizontal, 24).padding(.top, 30)
                    List {
                        Section {
                            if EmbeddedEngine.available {
                                Button { Task { await activateEmbedded(because: "host-picker") } } label: {
                                    HostChoiceRow(title: String(localized: "本机"), subtitle: engineEnabled ? nil : String(localized: "已在设置里关闭本机运行"), icon: "iphone",
                                                  status: embedded ? hostState.text : nil, statusColor: hostState.color,
                                                  selected: embedded)
                                }.accessibilityIdentifier("chooseEmbeddedHost").disabled(!engineEnabled)
                            }
                            ForEach(hosts) { host in
                                let active = lastProfile == host.id.uuidString && tunnel != nil
                                Button { connectionTask = Task { await reconnect(host, interactive: true) } } label: {
                                    HostChoiceRow(title: host.name.isEmpty ? host.address : host.name, subtitle: host.connectionMethod + " · " + host.address,
                                                  icon: "terminal", status: active ? hostState.text : nil, statusColor: hostState.color, selected: active)
                                }
                            }
                        }.listRowBackground(ChatColors.chip)
                        Section {
                            Button { showAfterDismiss(.manageHosts) } label: {
                                HStack {
                                    Label(hosts.isEmpty ? "连接设备" : "我的设备", systemImage: "desktopcomputer")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted)
                                }
                            }.accessibilityIdentifier("manageHosts")
                        }.listRowBackground(ChatColors.chip)
                        // Connecting by address is for people who run their own host. It stays folded, and
                        // opening the form leaves the device in use alone: only 「连接主机」 there switches.
                        Section {
                            Button { withAnimation(Motion.std(Motion.quick)) { hostAdvancedOpen.toggle() } } label: {
                                HStack {
                                    Text("高级")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted)
                                        .rotationEffect(.degrees(hostAdvancedOpen ? 90 : 0))
                                }
                            }.accessibilityIdentifier("hostAdvanced")
                            if hostAdvancedOpen {
                                Button("使用主机地址连接") { close(); showAfterDismiss(.address) }
                                    .accessibilityIdentifier("hostConnectByAddress")
                            }
                        }.listRowBackground(ChatColors.chip)
                        if connectingID != nil || startingEngine { ProgressView() }
                        if let issue { Text(issue).foregroundStyle(.red) }
                    }.foregroundStyle(ChatColors.ink).scrollContentBackground(.hidden).background(ChatColors.panel.ignoresSafeArea())
                        .disabled(connectingID != nil || startingEngine)
                    if connectingID != nil {
                        Button("取消", role: .cancel) { cancelConnection() }.padding()
                    }
                }.background(ChatColors.panel.ignoresSafeArea()).presentationCornerRadius(28).presentationDetents([.height(420), .large]).presentationDragIndicator(.visible)
                .onDisappear { cancelConnection(); hostAdvancedOpen = false }
                .remoteConnectionAlert($connectionError)
                .hostKeyPrompt($hostTrust)
            case .share:
                if (hostShare != nil ? hostShareMessages == nil : remote.hasOlder) || shareLoadFailed != nil {
                    VStack {
                        if let shareLoadFailed { Text(shareLoadFailed); Button("重试") { self.shareLoadFailed = nil } }
                        else { ProgressView("正在加载对话历史…") }
                    }.task(id: shareLoadFailed == nil) {
                        if shareLoadFailed == nil {
                            do {
                                if let target = hostShare {
                                    let rows = try await Conversation.shareHistory(on: target.host, session: target.row.id)
                                    try Task.checkCancellation()
                                    hostShareMessages = rows
                                } else { try await remote.loadShareHistory() }
                            } catch { if !Task.isCancelled { shareLoadFailed = error.localizedDescription } }
                        }
                    }
                } else {
                TranscriptPanel(host: hostShare?.host ?? remote.connection, imageSession: hostShare?.row.id, title: hostShare?.row.title ?? remote.title,
                                turns: (hostShareMessages ?? remote.messages).map { LocalTurn(id: $0.id, outgoing: $0.outgoing, text: $0.text, thinking: $0.thinking.isEmpty ? nil : $0.thinking, steps: $0.tool.map { [$0] }, images: $0.images.isEmpty ? nil : $0.images) }, focusedTurn: shareFocus,
                                continueChat: { transcript in self.page = nil; continueReplay(transcript) },
                                openDocument: { document in showAfterDismiss(.replay(document)) })
                }
            }
        }
        .task {
            connectPending = false
            TurnKeepAlive.shared.replyPreview = { [weak remote] in remote?.messages.last(where: { !$0.outgoing && $0.tool == nil })?.text }
            TurnKeepAlive.shared.replySession = { [weak remote] in remote?.connection?.sessionID }
            guard restoreHost else { return }
            if embedded, EmbeddedEngine.enabled { await activateEmbedded(because: "launch"); return }
            if let host = hosts.first(where: { $0.id.uuidString == lastProfile }) {
                connectionTask = Task { await reconnect(host) }
            }
        }

        .remoteConnectionAlert(Binding(get: { page == nil ? connectionError : nil }, set: { connectionError = $0 }))
        .tint(palette.color(hue: hue))
        .task(id: hostArchive?.id) {
            guard hostArchive != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            finishHostArchive()
        }
        .onChange(of: scenePhase) { old, phase in scenePhaseChanged(from: old, to: phase) }
        .onChange(of: remote.connection?.sessionID) { _, id in if embedded, let id { engineSession = id } }
        .modifier(ChatGPTWelcome())
        .overlay {
            if onboarding { OnboardingFlow(finish: finishOnboarding).transition(.opacity) }
        }
        .animation(Motion.reduced ? nil : Motion.std(Motion.standard), value: onboarding)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, chatGPT.signedIn { Task { _ = try? await chatGPT.accessToken() } }
        }
        // Signed in (or out): read the model list again now, so the chat stops asking to sign in.
        .onChange(of: account.signedIn) { _, signedIn in
            guard embedded, let host = liveHost else { return }
            Task {
                await remote.refreshModelCatalog(on: host)
                // The engine may take a moment to see the new credential.
                guard signedIn, remote.needsModelSetup == true else { return }
                try? await Task.sleep(for: .seconds(2))
                if remote.connection === host { await remote.refreshModelCatalog(on: host) }
            }
        }
        .onChange(of: remote.phase) { old, new in
            guard new == .offline, old == .ready || old == .replying else { return }
            if willReconnectAfterDrop { connectPending = true; resumePending = true }
            Task { await reconnectAfterDrop() }
        }
        .onReceive(remote.completedTurns) { ConversationIndex.shared.turnEnded($0, scope: hostScope) }
        .onOpenURL { url in
            if WidgetLink.shared.take(url) { page = nil; panels.snap(.drawer, open: false); return }
            if let request = PluginShareRequest.make(url) { pluginShare = request; return }
            if let request = PluginArchiveRequest.make(url) { pluginArchive = request; return }
            // A computer's pairing code scanned with the system camera.
            if url.scheme == "dshlocal", url.host == "lan" || url.host == "peer", url.path == "/pair" { pairLink = PairLink(code: url.absoluteString); return }
            do {
                if url.isFileURL {
                    externalReplay = try ReplayDocument.read(url)
                } else if let link = ReplayLink(url) {
                    Task {
                        do { let doc = try await link.open(); page = nil; panels.snap(.drawer, open: false); externalReplay = doc }
                        catch { importIssue = error.localizedDescription }
                    }
                }
                if externalReplay != nil { page = nil; panels.snap(.drawer, open: false) }
            } catch { importIssue = error.localizedDescription }
        }
        .fullScreenCover(item: $externalReplay) { ReplayView(document: $0, continueChat: continueReplay) }
        .fullScreenCover(item: $pairLink) { link in
            LanPairPage(code: link.code) { profile, tunnel in pairLink = nil; activate(profile, link: tunnel) }
        }
        .modifier(SystemEntryPoints(session: activitySession, title: activitySession.flatMap { ConversationIndex.shared.records[$0]?.title } ?? quickTitle,
                                    scope: hostScope, pairedHost: SystemEntryPoints.pairedFingerprint(hosts.first { $0.id.uuidString == hostScope }),
                                    run: { await runIntent($0) }, reopen: reopen))
        .onReceive(DSBotNotifications.shared.$route) { route in if let route { Task { await openBotRoute(route) } } }
        .onReceive(DSBotNotifications.shared.$replySession) { session in if let session { Task { await openReply(session) } } }
        // DS Bot unread counts and notifications start with the connection, not the first time the drawer opens.
        .task(id: remote.phase == .ready || remote.phase == .replying ? remote.connection.map(ObjectIdentifier.init) : nil) {
            if let host = remote.connection, remote.phase == .ready || remote.phase == .replying { _ = DSBotInbox.of(host, scope: hostScope, hostName: harnessName) }
        }
        .sheet(item: $pluginShare) { PluginShareEntrySheet(host: liveHost, request: $0) { _ in pluginShare = nil; feature = .bundles } }
        .sheet(item: $pluginArchive) { PluginArchiveEntrySheet(host: liveHost, request: $0) { _ in pluginArchive = nil; feature = .bundles } }
        .alert("无法打开回放", isPresented: Binding(get: { importIssue != nil }, set: { if !$0 { importIssue = nil } })) {
            Button("好") { importIssue = nil }
        } message: { Text(importIssue ?? "") }
        .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
    }

    /// A tapped DS Bot notification: switch to the host that sent it (本机 or an SSH host), then open the Bot.
    private func openBotRoute(_ route: DSBotRoute) async {
        DSBotNotifications.shared.route = nil
        if route.scope != hostScope {
            if route.scope == "embedded" { await activateEmbedded(because: "dsbot-notification") }
            else if let profile = hosts.first(where: { $0.id.uuidString == route.scope }) { await reconnect(profile) }
            else { remote.notice = String(localized: "这条 Bot 通知来自一台现在连不上的设备。"); return }
            for _ in 0..<60 where !(route.scope == hostScope && (remote.phase == .ready || remote.phase == .replying)) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard route.scope == hostScope, let host = remote.connection else { return }
        let inbox = DSBotInbox.of(host, scope: hostScope, hostName: harnessName)
        guard let session = await route.destination(in: inbox), remote.connection === host else { return }
        close(); page = nil; path.removeAll()
        if host.sessionID == session, remote.botSession {
            inbox.markRead(route.conversation)
        } else if await remote.openSession(session, bot: true) {
            inbox.markRead(route.conversation)
        }
    }

    /// A tapped "办好了": back to 本机 and the conversation whose reply finished.
    private func openReply(_ session: String) async {
        DSBotNotifications.shared.replySession = nil
        UITrace.note("open finished reply session=\(Log.session(session))")
        if hostScope != "embedded" {
            await activateEmbedded(because: "reply-notification")
            for _ in 0..<60 where !(hostScope == "embedded" && (remote.phase == .ready || remote.phase == .replying)) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard hostScope == "embedded", let host = remote.connection else { return }
        close(); page = nil; path.removeAll()
        if host.sessionID != session || remote.botSession { await remote.openSession(session) }
    }

    private func openQuickModel() {
        panels.close(.quick)
        if liveHost != nil { feature = .models }
    }

    private func openQuickEntry(_ entry: QuickEntry) {
        panels.close(.quick)
        switch entry {
        case .settings, .settingsSearch: push(.settings)
        case .features: push(.features)
        case .browser: browserRoute = BrowserRoute(url: nil)
        case .hosts: page = .hosts
        case .share: openShare(nil)
        case .plugins: feature = .bundles
        case .terminal: feature = .terminal
        case .workspace: feature = .files
        }
    }

    private var featureGrid: some View {
        let connected = remote.connection != nil
        let title = connected ? remote.title : nil
        return ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button { path.removeAll() } label: {
                        HStack(spacing: 12) {
                            LineGlyph(name: "list", size: 21).foregroundStyle(ChatColors.onPrimary)
                                .frame(width: 40, height: 40)
                                .background(ChatColors.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? (title != nil ? String(localized: "未命名对话") : String(localized: "还没打开对话")))
                                    .font(.body.weight(.semibold)).foregroundStyle(ChatColors.ink).lineLimit(1)
                                Text(title != nil ? harnessName : String(localized: "先在聊天里打开或新建一个")).font(.footnote).foregroundStyle(ChatColors.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if title != nil { LineGlyph(name: "right", size: 15).foregroundStyle(ChatColors.muted.opacity(0.6)) }
                        }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }.buttonStyle(.pressable).disabled(title == nil).accessibilityIdentifier("featuresConversation")
                        .padding(.bottom, 20)
                    featureSection(String(localized: "当前对话")) {
                        hostFeature(.details, "info", connected); hostFeature(.deliverables, "box", connected)
                        hostFeature(.files, "folder", connected)
                        if liveHost.map(EmbeddedEngine.shared.hasTerminal) ?? true { hostFeature(.terminal, "term", connected) }
                        hostFeature(.export, "share", connected); hostFeature(.jobs, "clock", connected)
                        hostFeature(.goal, "target", connected)
                        hostFeature(.subagents, "branch", connected)
                        featureCard(String(localized: "引用文件和对话"), connected ? nil : String(localized: "先连接一台设备"), "at", enabled: connected) {
                            if !remote.draft.hasSuffix("@") { remote.draft += remote.draft.isEmpty || remote.draft.hasSuffix(" ") ? "@" : " @" }
                            path.removeAll()
                        }
                    }
                    featureSection(String(localized: "自动化与插件")) {
                        hostFeature(.tasks, "retry", connected)
                        hostFeature(.bundles, "blocks", connected); hostFeature(.skills, "bolt", connected)
                        PluginFeatureCards(host: liveHost, chat: remote)
                        if let liveHost { BotFeatureCard(inbox: DSBotInbox.of(liveHost, scope: hostScope, hostName: harnessName)) { hostFeature(.bots, "bot", connected) } }
                        else { hostFeature(.bots, "bot", connected) }
                        NavigationLink { CommunityPage(remote: remote) } label: { FeatureTileLabel(title: String(localized: "社区"), symbol: "people") }
                            .buttonStyle(.pressable).accessibilityLabel("社区")
                    }
                    featureSection(String(localized: "工具")) {
                        hostFeature(.search, "search", connected); hostFeature(.workspaces, "side", connected)
                        featureCard(String(localized: "内置浏览器"), nil, "globe") { showAfterDismiss(.browser) }
                        featureCard(String(localized: "快捷入口"), nil, "panel") { showAfterDismiss(.quickPanel) }
                        featureCard(String(localized: "分享与恢复"), nil, "up") { showAfterDismiss(.share) }
                    }
                }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 28)
            }
            .background(ChatColors.page.ignoresSafeArea()).navigationTitle("全部功能").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAfterDismiss(.settings) } label: { LineGlyph(name: "nut", size: 20) }
                        .accessibilityLabel("设置").accessibilityIdentifier("featuresSettings")
                }
            }
    }

    private func featureSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted).padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 4), spacing: 12) { content() }
        }.padding(.bottom, 18)
    }

    /// A host feature; without a connected host it stays visible but disabled, as in DSH.
    private func hostFeature(_ panel: HostPanel, _ symbol: String, _ connected: Bool) -> some View {
        let route = ShellRoute.panel(panel, fromCard: true)
        return featureCard(panel.rawValue.localized, connected ? nil : String(localized: "先连接一台设备"), symbol, enabled: connected) {
            push(route)
        }.modifier(ZoomSource(id: route, namespace: cardZoom, cornerRadius: 16))
    }

    private func featureCard(_ title: String, _ summary: String?, _ symbol: String, enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) { FeatureTileLabel(title: title, symbol: symbol, enabled: enabled) }
            .buttonStyle(.pressable).disabled(!enabled).accessibilityLabel(title).accessibilityHint(summary ?? "")
    }

    /// 弹层开着就等它收起再去；推入的页面直接叠上去，返回时回到原页。
    private func showAfterDismiss(_ destination: AfterDismiss) {
        if page != nil {
            afterDismiss = destination
            page = nil
        } else {
            open(destination)
        }
    }

    private func showNextPage() {
        hostShare = nil
        hostShareMessages = nil
        guard let destination = afterDismiss else { return }
        afterDismiss = nil
        open(destination)
    }

    private func open(_ destination: AfterDismiss) {
        switch destination {
        case .browser: browserRoute = BrowserRoute(url: nil)
        case .quickPanel: path.removeAll(); panels.open(.quick)
        case .share: openShare(nil)
        case .manageHosts: push(.manageHosts)
        case .address: path.removeAll(); connectByAddress = true
        case .configureAI: push(.configureAI)
        case .account: push(.account)
        case .settings: push(.settings)
        case .feature(let panel): feature = panel
        case .replay(let document): externalReplay = document
        }
    }

    /// The first-launch setup is over: the chat shows, with what the person chose there under way.
    private func finishOnboarding(_ outcome: Onboarding.Outcome) {
        UserDefaults.standard.set(true, forKey: Onboarding.doneKey)
        onboarding = false
        switch outcome {
        case .chat: break
        case .phoneControl:
            // The component comes from the plugin market; this sentence then sets it up.
            remote.draft = String(localized: "开通手机操控")
            if liveHost != nil { HostPluginsScreen.startOnMarket = true; feature = .bundles }
        case .ask(let text):
            // In the field meanwhile: the account's models reach the engine a moment after signing in.
            remote.draft = text
            Task {
                var waited = 0
                while !(remote.phase == .ready && remote.needsModelSetup == false), waited < 80 {
                    try? await Task.sleep(for: .milliseconds(250)); waited += 1
                }
                guard remote.phase == .ready, remote.needsModelSetup == false, remote.draft == text else { return }
                remote.draft = ""
                await remote.send(text)
            }
        }
    }

    /// 推入二级页。侧栏或快捷面板开着时先留着，等新页盖住后再收起，返回时落在聊天上。
    private func push(_ route: ShellRoute) {
        guard path.last != route else { return }
        path.append(route)
        guard panels.drawerShown || panels.quickShown else { return }
        Task { @MainActor [panels] in
            try? await Task.sleep(for: .seconds(Motion.slow))
            panels.snap(.drawer, open: false)
            panels.snap(.quick, open: false)
        }
    }

    private var chatView: some View {
                ChatView(chat: remote, menu: show, share: openShare, panel: $feature,
                         hostName: harnessName,
                         hostDetail: headerDetail,
                         subagents: subagents.generation == remote.connection?.sessionGeneration ? (subagents.count, subagents.running) : (0, 0),
                         switchHost: { page = .hosts }, disconnect: { disconnectHost() }, connectByAddress: $connectByAddress,
                         reconnect: canReconnect ? { Task { await reconnectLast() } } : nil,
                         connectingSoon: connectingSoon, resuming: resumePending || (startingEngine && engineSession != nil && remote.phase == .offline),
                         configureAI: { push(.configureAI) },
                         // Signing in happens on this phone; a computer's models are set up on the computer.
                         signIn: embedded ? { push(.account) } : nil,
                         chatGPT: embedded ? { Task { if let issue = await ChatGPTAccount.shared.signIn() { remote.notice = issue } } } : nil,
                         onPhone: embedded, relaunch: embedded && EmbeddedEngine.shared.needsRelaunch)
                    .modifier(ConversationAnnotation(session: activitySession))
    }

    /// The conversation list: header, search, the rows, then the host and the two round buttons.
    private func drawerColumn(width: CGFloat) -> some View {
                    VStack(alignment: .leading, spacing: 12) {
                        if !selectingRows {
                        HStack(spacing: 8) {
                            CatMark().fill(ChatColors.ink).frame(width: 28, height: 18).accessibilityHidden(true)
                            Text(verbatim: "Pallas Agent").font(.title3.weight(.semibold))
                            Spacer()
                            Button { newChat() } label: {
                                LineGlyph(name: "compose", size: 20).foregroundStyle(ChatColors.onPrimary)
                                    .frame(width: 40, height: 40).background(ChatColors.primary, in: Circle())
                            }.buttonStyle(.pressable).accessibilityLabel("新对话")
                                .accessibilityIdentifier("newDrawerConversation").disabled(remote.connection == nil)
                        }.padding(.horizontal, 16)
                        Button { withAnimation(Motion.enter(Motion.standard)) { searching = true } } label: {
                            HStack(spacing: 8) {
                                LineGlyph(name: "search")
                                Text("搜索对话").font(.subheadline)
                                Spacer()
                            }.foregroundStyle(ChatColors.muted).padding(.horizontal, 14).frame(height: 44)
                                .background(ChatColors.segmentWell, in: Capsule()).contentShape(Capsule())
                        }.buttonStyle(.plain).padding(.horizontal, 16).accessibilityLabel("搜索对话").accessibilityIdentifier("drawerSearch")
                            .disabled(remote.connection == nil)
                        }
                        if let batch = hostArchive {
                            HStack {
                                Text(batch.rows.count == 1 ? String(localized: "已归档「") + batch.rows[0].title + String(localized: "」") : String(localized: "已归档 \(batch.rows.count) 个对话")).lineLimit(1)
                                Spacer()
                                Button("撤销") { hostArchive = nil }
                            }.padding(.horizontal)
                        }
                        if let issue { Text(issue).font(.caption).padding(.horizontal) }
                        Group {
                            if let host = remote.connection, remote.phase == .ready || remote.phase == .replying {
                                DSBotSidebarRows(host: host, scope: hostScope, hostName: harnessName, currentSession: host.sessionID, botSession: remote.botSession) { id in
                                    close(); Task { await remote.openSession(id, bot: true) }
                                }.id(ObjectIdentifier(host))
                                RemoteSessionRows(host: host, scope: hostScope, workspace: remote.workspace, query: "", open: { id in
                                    guard remote.connection === host else { return }
                                    close()
                                    if id != host.sessionID { Task { await remote.openSession(id) } }
                                }, share: { row in
                                    close(); openShare(nil); hostShare = (host, row)
                                }, archive: { rows in
                                    if !rows.isEmpty { hostArchive = (host, rows, UUID()) }
                                }, deleted: { ids in
                                    if remote.connection === host, ids.contains(host.sessionID) { Task { await remote.openSession(nil) } }
                                }, archiveBusy: hostArchive != nil || archiveTask != nil, filter: $filter,
                                   newChat: { newChat() }, manageWorkspaces: { close(); feature = .workspaces },
                                   hostName: harnessName, selectionChanged: { selectingRows = $0 })
                                    .id(ObjectIdentifier(host))
                            } else { Spacer() }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                        if !selectingRows {
                        VStack(spacing: 8) {
                            Button { page = .hosts } label: {
                                HStack(spacing: 10) {
                                    SettingsIconDisc(symbol: embedded ? "phone" : "desktop")
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(harnessName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        HStack(spacing: 4) {
                                            Circle().fill(hostState.color).frame(width: 6, height: 6)
                                            Text(hostState.text).font(.caption2).foregroundStyle(ChatColors.muted).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    LineGlyph(name: "updown", size: 15).foregroundStyle(ChatColors.muted)
                                }.padding(.leading, 6).padding(.trailing, 12).frame(height: 44)
                                    .background(ChatColors.chip, in: Capsule()).contentShape(Capsule())
                            }.buttonStyle(.pressable).accessibilityIdentifier("switchHost")
                                .accessibilityLabel(String(localized: "当前设备：") + harnessName + String(localized: "，") + hostState.text + String(localized: "。切换设备"))
                            HStack(spacing: 8) {
                                drawerButton(String(localized: "全部功能"), "grid", id: "drawerFeatures") { push(.features) }
                                drawerButton(String(localized: "设置"), "nut", id: "drawerSettings") { push(.settings) }
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 8)
                        }
                    }.padding(.top, 10).frame(width: width)
                    .foregroundStyle(ChatColors.ink)
    }

    /// A 44 pt capsule at the foot of the drawer, icon and name (全部功能, 设置): the two share a row.
    private func drawerButton(_ label: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                LineGlyph(name: symbol, size: 18)
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }.foregroundStyle(ChatColors.ink).frame(maxWidth: .infinity).frame(height: 44)
                .background(ChatColors.chip, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.pressable).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    @ViewBuilder private func destination(_ route: ShellRoute) -> some View {
        Group {
            switch route {
            case .features: featureGrid
            case .configureAI:
                if embedded {
                    if ThirdPartyProviders.load().isEmpty { DirectAccessPage(providerID: nil) }
                    else { ThirdPartyListPage() }
                }
                else { HostModelsPage(remote: remote, host: remote.connection, hostLabel: harnessName) }
            case .account: DeepSeekAccountPage()
            case .settings:
                PreferencesView(remote: remote, hostName: harnessName, openRemoteHosts: { push(.manageHosts) },
                                openPluginMarket: liveHost == nil ? nil : { HostPluginsScreen.startOnMarket = true; feature = .bundles },
                                askInChat: { line in remote.draft = line; path.removeAll() },
                                engineChanged: setEngine, onPhone: embedded)
            case .manageHosts:
                HostLibrary(connected: { profile, link in activate(profile, link: link) },
                            active: activeRemote,
                            switchToPhone: activeRemote == nil || !engineEnabled ? nil : { Task { await activateEmbedded(because: "switch-to-phone") } },
                            pushed: true,
                            connectByAddress: { path.removeAll(); showAfterDismiss(.address) })
            case .sessionInfo:
                ScrollView {
                    QuickSessionInfo(title: quickTitle ?? String(localized: "新对话"), hostName: harnessName,
                                     workspace: remote.workspace, model: remote.modelName) { feature = .models }.padding()
                }.background(ChatColors.canvas.ignoresSafeArea()).navigationTitle("对话信息")
            case .panel(let panel, _):
                if let host = remote.connection {
                    HostPanelView(panel: panel, chat: remote, host: host, pushed: true)
                } else {
                    ContentUnavailableView("设备已断开", systemImage: "bolt.horizontal.circle", description: Text("重新连接后再打开。"))
                }
            }
        }
        .toolbarRole(.editor)
        .modifier(ZoomDestination(id: route, namespace: cardZoom, enabled: route.fromCard))
    }

    private func openShare(_ focus: UUID?) {
        hostShare = nil
        hostShareMessages = nil
        shareFocus = focus
        shareLoadFailed = nil
        page = .share
    }

    /// 回放或对话文件的「接着聊」：在当前主机开一个新对话，原来的记录作为 conversation.md 附上。
    private func continueReplay(_ transcript: String) {
        panels.snap(.drawer, open: false)
        externalReplay = nil
        page = nil
        path.removeAll()
        guard remote.connection != nil else {
            remote.notice = String(localized: "先连上本机或一台电脑，再接着聊。")
            return
        }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "conversation.md")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(transcript.utf8).write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            remote.notice = String(localized: "没能准备对话记录：") + error.localizedDescription
            return
        }
        Task {
            guard await remote.openSession(nil, initialDraft: String(localized: "接着附件里这段对话聊：")) else { return }
            remote.pendingAttachment = file
        }
    }

    /// Back in front: iOS may have taken 本机引擎's listener while the app was suspended. When the
    /// engine no longer answers, reconnect to the same conversation.
    private func reviveEmbedded() async {
        guard embedded, EmbeddedEngine.enabled, !startingEngine, remote.phase != .connecting,
              let endpoint = EmbeddedEngine.shared.endpoint else { return }
        if remote.phase != .offline, await EmbeddedEngine.answers(endpoint) {
            UITrace.note("revive: engine answers, no reconnect")
            return
        }
        guard embedded else { return }
        UITrace.note("revive: reconnect chat=\(remote.phase) session=\(Log.session(remote.connection?.sessionID ?? engineSession))")
        await activateEmbedded(resume: remote.connection?.sessionID ?? engineSession, because: "foreground", preserveNavigation: true)
    }

    /// The engine's connection dropped on its own while the app is in front (an error, not the user
    /// switching conversations or hosts): reconnect to the same conversation, at most three times a
    /// minute so a failing engine cannot spin.
    private var willReconnectAfterDrop: Bool {
        embedded && EmbeddedEngine.enabled && UIApplication.shared.applicationState == .active && remote.notice != nil
            && dropReconnects.filter { Date().timeIntervalSince($0) < 60 }.count < 3
    }

    private func reconnectAfterDrop() async {
        try? await Task.sleep(for: .seconds(1))
        // Cleared in the same turn `activateEmbedded` marks itself as starting: no offline frame between.
        defer { connectPending = false; resumePending = false }
        guard embedded, EmbeddedEngine.enabled, UIApplication.shared.applicationState == .active,
              remote.phase == .offline, remote.notice != nil else { return }
        let now = Date()
        dropReconnects = dropReconnects.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard dropReconnects.count <= 3 else {
            Log.engine.error("connection keeps dropping; automatic reconnect paused")
            return
        }
        await activateEmbedded(resume: engineSession, because: "dropped", preserveNavigation: true)
    }

    /// 设置 › 本机引擎: on connects to it when nothing else is in use; off lets it go.
    private func setEngine(_ on: Bool) {
        if on {
            if remote.connection == nil { Task { await activateEmbedded(because: "setting") } }
        } else if embedded {
            disconnectHost()
        }
    }

    private func finishHostArchive() {
        guard let batch = hostArchive else { return }
        hostArchive = nil
        var background = UIBackgroundTaskIdentifier.invalid
        func endBackgroundTask() {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        }
        background = UIApplication.shared.beginBackgroundTask(withName: "Host session archive") {
            archiveTask?.cancel()
            endBackgroundTask()
        }
        archiveTask = Task {
            defer {
                endBackgroundTask()
                archiveTask = nil
            }
            for row in batch.rows {
                guard !Task.isCancelled, remote.connection === batch.host else {
                    issue = String(localized: "归档中断，请重新连接后检查对话列表。")
                    return
                }
                do { try await batch.host.setArchived(true, session: row.id) }
                catch { issue = String(localized: "归档「") + row.title + String(localized: "」失败，已停止本批操作。") + error.localizedDescription; return }
            }
        }
    }

    private func releaseTunnel() {
        guard let link = tunnel else { return }
        tunnel = nil
        Task { await link.close() }
    }

    /// Connects to 本机引擎, first making it listen again if iOS took its listener while the app was
    /// suspended. `resume` reconnects to that conversation quietly, keeping open pages and the draft;
    /// only when that conversation does not open at all does a new one open instead.
    private func activateEmbedded(resume session: String? = nil, because reason: String, preserveNavigation: Bool = false) async {
        guard EmbeddedEngine.enabled else { return }
        guard !startingEngine, !preserveNavigation || remote.phase != .connecting else {
            Log.engine.notice("reconnect (\(reason, privacy: .public)) skipped: already connecting")
            return
        }
        if session == nil, embedded, remote.connection != nil, remote.phase == .ready || remote.phase == .replying {
            if !preserveNavigation { close(); page = nil }
            return
        }
        Log.engine.notice("reconnect (\(reason, privacy: .public)) session=\(Log.session(session), privacy: .public)")
        cancelConnection()
        startingEngine = true
        do {
            let endpoint = try await EmbeddedEngine.shared.reachable()
            let unsent = session == nil ? "" : remote.draft
            disconnectHost()
            embedded = true
            if session == nil && !preserveNavigation { close(); page = nil; path.removeAll() }
            Task {
                var opened = false
                // `connect` sets `.connecting` before it first suspends, so the chat never sees a frame
                // of 「未连接」 between the engine answering and the connection starting.
                startingEngine = false
                await remote.connect(address: endpoint.address, token: endpoint.token, existing: session) {
                    opened = true
                    if !unsent.isEmpty, remote.draft.isEmpty { remote.draft = unsent }
                }
                // `connect` returns only when the connection ends. A conversation that opened and
                // later dropped is not replaced; only one that never opened is.
                guard session != nil, !opened, embedded, remote.connection == nil, remote.phase == .offline else { return }
                Log.engine.error("conversation \(Log.session(session), privacy: .public) did not open; starting a new one")
                engineSession = nil
                await remote.connect(address: endpoint.address, token: endpoint.token)
            }
        } catch {
            startingEngine = false
            Log.engine.error("reconnect (\(reason, privacy: .public)) failed: \(Log.reason(error), privacy: .public)")
            issue = error.localizedDescription
            if page == nil { remote.notice = issue }
        }
    }

    private func disconnectHost() {
        cancelConnection()
        embedded = false
        remote.disconnect()
        releaseTunnel()
        if !lastProfile.isEmpty { lastProfile = "" }
    }

    private func activate(_ host: HostProfile, link: SSHTunnel) {
        embedded = false
        issue = nil
        connectionError = nil
        remote.disconnect()
        releaseTunnel()
        tunnel = link
        if lastProfile != host.id.uuidString { lastProfile = host.id.uuidString }
        close()
        page = nil
        path.removeAll()
        Task {
            connectingID = nil
            var opened = false
            await remote.connect(address: link.address, token: link.token) {
                opened = true
            }
            if tunnel === link, remote.phase == .offline {
                if !opened, let notice = remote.notice {
                    connectionError = HostError(String(localized: "没能连上这台电脑"), detail: notice)
                }
                releaseTunnel()
            }
        }
    }

    private func reconnect(_ profile: HostProfile, interactive: Bool = false) async {
        guard connectingID == nil else { return }
        if tunnel != nil, lastProfile == profile.id.uuidString, remote.connection != nil {
            close(); page = nil; return
        }
        connectingID = profile.id
        issue = nil
        var handedOff = false
        defer { if !handedOff && !Task.isCancelled { connectingID = nil } }
        do {
            var host = profile
            if interactive {
                guard let accepted = try await HostKeyPrompt.verify(profile, remember: true, stored: $profileData, prompt: $hostTrust) else { return }
                host = accepted
            }
            try Task.checkCancellation()
            let id = host.id.uuidString
            let link = try await SSHTunnel.open(host, secret: Vault.read(id), passphrase: Vault.read(id + "/pass"), token: Vault.read(id + "/token"))
            guard !Task.isCancelled else { await link.close(); return }
            handedOff = true
            activate(host, link: link)
        } catch {
            guard !Task.isCancelled else { return }
            let failure = SSHFailure.explain(error, at: .connect)
            connectionError = HostError(failure.message, code: failure.code,
                detail: "\(profile.name.isEmpty ? profile.address : profile.name) · \(profile.address):\(profile.port)\n" + (failure.detail ?? ""))
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connectingID = nil
        hostTrust?.decide(false)
        hostTrust = nil
    }

    private func show() {
        if docked { withAnimation(Motion.std(Motion.standard)) { sidebarCollapsed.toggle() } } else { panels.open(.drawer) }
    }
    private func close() { panels.close(.drawer) }
    /// 侧栏 320 宽，至少给聊天留 56。
    private func drawerWidth(_ bounds: GeometryProxy) -> CGFloat {
        min(320 + bounds.safeAreaInsets.leading, bounds.size.width - 56)
    }
    /// 快捷面板 260 宽；打开着对话时要放会话信息，360。
    private func quickWidth(_ bounds: GeometryProxy) -> CGFloat {
        min((quickTitle == nil ? 260 : 360) + bounds.safeAreaInsets.trailing, bounds.size.width - 56)
    }
    private func newChat() {
        close()
        Task { await remote.openSession(nil, workspace: RemoteSessionRows.selectedWorkspace(scope: hostScope)) }
    }

    // MARK: Siri, Shortcuts, Spotlight, Handoff

    /// The conversation on screen, for Handoff and for Siri to know what 「这个」 is.
    private var activitySession: String? {
        guard let host = remote.connection, !remote.botSession, !host.sessionID.isEmpty,
              remote.phase == .ready || remote.phase == .replying else { return nil }
        return host.sessionID
    }

    /// A Spotlight result or a Handoff: open that conversation.
    private func reopen(_ session: String, scope: String?) {
        let scope = scope ?? ConversationIndex.shared.records[session]?.scope ?? hostScope
        Task { _ = try? await IntentRouter.shared.submit(.open(session, scope: scope)) }
    }

    private func runIntent(_ id: UUID) async {
        let router = IntentRouter.shared
        guard let action = router.take(id) else { return }
        Log.engine.notice("intent \(String(describing: action), privacy: .private) begins")
        do { router.finish(id, .success(try await perform(action, requestID: id))) }
        catch {
            Log.engine.error("intent failed: \(error.localizedDescription, privacy: .public)")
            router.finish(id, .failure(error))
        }
    }

    private func perform(_ action: IntentRouter.Action, requestID: UUID) async throws -> IntentRouter.Outcome {
        var scope: String?
        switch action {
        case .ask(_, _, let wanted, _): scope = wanted
        case .open(_, let wanted): scope = wanted
        case .newConversation: scope = nil
        }
        try await readyHost(scope: scope)
        try IntentRouter.shared.checkPending(requestID)
        guard let host = remote.connection else { throw IntentFailure(String(localized: "Pallas Agent 没能连上引擎。")) }
        close(); page = nil; path.removeAll()
        searching = false
        let workspace = RemoteSessionRows.selectedWorkspace(scope: hostScope)
        switch action {
        case .newConversation:
            guard await remote.openSession(nil, workspace: workspace) else {
                throw IntentFailure(remote.notice ?? String(localized: "没能打开这个对话。"))
            }
        case .open(let session, _):
            if host.sessionID != session || remote.botSession { await remote.openSession(session) }
            if remote.connection?.sessionID != session { throw IntentFailure(remote.notice ?? String(localized: "没能打开这个对话。")) }
        case .ask(let text, let session, _, _):
            if let session, session != host.sessionID || remote.botSession { await remote.openSession(session) }
            // A request on its own, or one whose conversation is busy, starts a conversation of its own.
            if session == nil || remote.phase != .ready || remote.botSession || remote.connection?.sessionID != session {
                guard await remote.openSession(nil, workspace: workspace) else {
                    throw IntentFailure(remote.notice ?? String(localized: "没能打开这个对话。"))
                }
            }
            guard remote.phase == .ready, remote.connection === host else { throw IntentFailure(String(localized: "Pallas Agent 正忙，稍后再试。")) }
            try IntentRouter.shared.checkPending(requestID)
            await remote.send(text, requestID: requestID)
            guard remote.connection === host, remote.messages.contains(where: { $0.requestID == requestID && !$0.failed }) else {
                throw IntentFailure(remote.notice ?? String(localized: "没能发出去。"))
            }
        }
        guard let current = remote.connection else { throw IntentFailure(String(localized: "Pallas Agent 没能连上引擎。")) }
        return IntentRouter.Outcome(session: current.sessionID, scope: hostScope, title: remote.title, requestID: requestID)
    }

    /// Connected and idle enough to take a request, on the host `scope` names when it names one.
    private func readyHost(scope: String?) async throws {
        func live() -> Bool {
            remote.connection != nil && (remote.phase == .ready || remote.phase == .replying) && !remote.switchingSession
                && (scope == nil || scope == hostScope)
        }
        if live() { return }
        if let scope, scope != hostScope {
            if scope == "embedded" { await activateEmbedded(because: "intent") }
            else if let profile = hosts.first(where: { $0.id.uuidString == scope }) { await reconnect(profile) }
            else { throw IntentFailure(String(localized: "这个对话所在的设备现在连不上。")) }
        }
        for attempt in 0..<120 where !live() {
            // Nothing on its way after the first seconds: start 本机引擎 (what the app opens on by default).
            if attempt == 12, remote.phase == .offline, !connectPending, !startingEngine, embedded, scope == nil || scope == "embedded" {
                await activateEmbedded(because: "intent")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard live() else { throw IntentFailure(String(localized: "Pallas Agent 没能连上引擎。")) }
    }
}


private struct HostChoiceRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    var status: String? = nil
    var statusColor: Color = .green
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 28).foregroundStyle(ChatColors.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if let status {
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(status).font(.caption).foregroundStyle(ChatColors.muted)
                }
            }
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }.padding(.vertical, 5).accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityValue([subtitle ?? "", status ?? ""].filter { !$0.isEmpty }.joined(separator: String(localized: "，")))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A pairing code that reached the app as a link.
struct PairLink: Identifiable {
    let id = UUID()
    let code: String
}

/// The DS Bot card, shown only while the host answers the DS Bot API (hidden once it is known to have none).
private struct BotFeatureCard<Card: View>: View {
    @ObservedObject var inbox: DSBotInbox
    @ViewBuilder let card: () -> Card
    var body: some View { if inbox.available != false { card() } }
}
