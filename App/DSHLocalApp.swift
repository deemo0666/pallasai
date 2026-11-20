import SwiftUI
import PhotosUI

@main
struct DSHLocalApp: App {
    @State private var launchAsset = LaunchAsset.selected()

    init() {
        MemoryDream.shared.registerBackgroundTask()
        TurnKeepAlive.shared.register()
        DueTasks.shared.register()
        ImageTiming.startStallWatch()
        let defaults = UserDefaults.standard
        Self.configureHostDefaults(defaults)
        Self.retireDirectChat(defaults)
        DSBotNotifications.install()
        if defaults.bool(forKey: "embeddedHostSelected"), defaults.object(forKey: "restoreHost") as? Bool != false, EmbeddedEngine.enabled {
            Task { _ = try? await EmbeddedEngine.shared.start() }
        }
    }

    static func configureHostDefaults(_ defaults: UserDefaults) {
        defaults.register(defaults: ["embeddedHostSelected": true, EmbeddedEngine.enabledKey: true])
        // Older installs stored false even when no remote host had ever been selected.
        if (defaults.string(forKey: "lastSSHProfile") ?? "").isEmpty,
           defaults.bool(forKey: EmbeddedEngine.enabledKey) {
            defaults.set(true, forKey: "embeddedHostSelected")
        }
    }

    /// 本机直连 merged into 本机引擎: its conversations go, and a phone left on it opens 本机引擎.
    private static func retireDirectChat(_ defaults: UserDefaults) {
        if defaults.bool(forKey: "activeHostType"), EmbeddedEngine.enabled { defaults.set(true, forKey: "embeddedHostSelected") }
        for key in ["activeHostType", "accountMode", "accountModel", "searchWeb", "browserEnabled", "visualReplies"] {
            defaults.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "local-conversations.json"))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ClientShell().accessibilityHidden(launchAsset != nil)
                if let launchAsset { LaunchPlayback(asset: launchAsset) { self.launchAsset = nil } }
            }.task { HostedLibrary.shared.resume() }
            // The Shortcuts app's answer to run_shortcut; ClientShell ignores this link.
            .onOpenURL { url in
                ShortcutRunner.shared.handle(url)
            }
            .modifier(SettingsRuntime())
        }
    }
}

struct ChatView: View {
    @ObservedObject var chat: Conversation
    @ObservedObject private var notifyOffer = NotificationOffer.shared
    @Environment(\.showChatBrowser) private var showBrowser
    let menu: () -> Void
    let share: (UUID) -> Void
    @Binding var panel: HostPanel?
    @State private var address = ""
    let hostName: String
    let hostDetail: String
    let subagents: (count: Int, running: Int)
    let switchHost: () -> Void
    let disconnect: () -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var picking = false
    @State private var extras = false
    @State private var composing = false
    @State private var token = ""
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @Binding var connectByAddress: Bool
    /// Offline with a host to go back to (the empty state's 「重新连接」).
    var reconnect: (() -> Void)? = nil
    /// A connection is on its way although `chat.phase` may still read offline (the engine starting,
    /// an SSH tunnel opening, the pause before an automatic reconnect).
    var connectingSoon = false
    /// That connection goes back to the conversation on screen: keep its messages up meanwhile.
    var resuming = false
    var configureAI: (() -> Void)? = nil
    /// The DeepSeek sign-in page (only where this phone can sign in: 本机).
    var signIn: (() -> Void)? = nil
    /// 用 ChatGPT 登录 (only on 本机).
    var chatGPT: (() -> Void)? = nil
    /// The host is this phone itself: it starts, it does not connect.
    var onPhone = false
    /// 本机 cannot start again in this process: only reopening the app helps, so nothing offers a retry.
    var relaunch = false
    @State private var plusOpen = false
    @State private var folderGrantsOpen = false
    @State private var afterPlus: PlusAction?
    @ObservedObject private var fullAutoStore = FullAuto.shared
    @State private var confirmFullAuto = false
    @State private var cameraOpen = false
    @State private var usageOpen = false
    @State private var todosOpen = false
    @State private var queued: String?
    /// The queued message waits for the engine to start (or the connection to open), not for a turn.
    @State private var queuedForStart = false
    /// `/` 指令和 `@` 引用的候选。
    @StateObject private var palette = ComposerPalette()
    /// 按住说话。
    @StateObject private var voice = VoiceRecorder()
    /// The send key's look when the hold began: it must not swap under the finger.
    @State private var talkKey: String?
    /// The field is 按住 说话 instead of the text editor (🎤 / ⌨️ beside ＋), kept across launches.
    @AppStorage("composerVoiceMode") private var voiceMode = false
    /// The field's text when dictation began; the words go after it.
    @State private var dictationBase: String?
    /// What dictation last wrote into the field: anything else there means the person changed it.
    @State private var dictationWritten: String?
    /// 这一轮在手机上开始的时刻（主机没给出本轮开始时间时，活动条从这里计时）。
    @State private var runStart = Date()
    @Environment(\.scenePhase) private var scenePhase


    private var isOnline: Bool { chat.phase == .ready || chat.phase == .replying }
    private var isConnecting: Bool { chat.phase == .connecting || (chat.phase == .offline && connectingSoon) }
    /// The composer is up while starting too: a message sent then waits and goes once the chat is ready.
    private var canType: Bool { isOnline || (isConnecting && !relaunch) }

    /// 消息铺满整页，顶栏和输入框浮在上面：内容从玻璃下面滚过。
    var body: some View {
        Group {
            let online = isOnline
            if chat.creatingSession || !(online || (resuming && isConnecting)) || chat.messages.isEmpty {
                ChatWelcome(host: chat.creatingSession || chat.workspace.isEmpty ? "" : URL(fileURLWithPath: chat.workspace).lastPathComponent,
                            offline: !online, chooseHost: switchHost,
                            connecting: isConnecting, reconnect: chat.phase == .offline && !isConnecting ? reconnect : nil,
                            chooseWorkspace: online && !chat.creatingSession ? { panel = .workspaces } : nil,
                            needsAI: online && chat.needsModelSetup == true, configureAI: configureAI, signIn: signIn, chatGPT: chatGPT,
                            suggest: online && !chat.creatingSession && chat.needsModelSetup == false && !chat.botSession && chat.draftIsEmpty ? { useExample($0) } : nil,
                            onPhone: onPhone, relaunch: relaunch, failed: chat.notice != nil)
            } else {
                HostMessageHistory(chat: chat, font: typeSize.font, share: share)
                    .id(chat.connection?.sessionGeneration)
                    .modifier(FadeInOnChange(key: chat.connection?.sessionID))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { composing = false })
        .modifier(FloatingBars(top: header, bottom: bottomBar))
        .background(ChatWallpaper().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: chat.switchingSession) { _, switching in
            if switching { composing = false; palette.close() }
        }
        .onChange(of: composing) { _, editing in
            if editing && chat.creatingSession { voiceMode = false }
        }
        #if DEBUG
        .onAppear { PhotoBench.listen { datas in attachPhotos(datas.map { data in { data } }) } }
        #endif
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            extras = false; plusOpen = false; photos = []
            attachPhotos(items.map { item in { try? await item.loadTransferable(type: Data.self) } })
        }
        .sheet(isPresented: $connectByAddress) {
            NavigationStack {
                Form {
                    Section("用主机地址连接") {
                        TextField("主机地址", text: $address).keyboardType(.URL).accessibilityIdentifier("address")
                        SecureField("启动令牌", text: $token).accessibilityIdentifier("token")
                        Button("连接主机") {
                            let credential = token
                            token = ""; connectByAddress = false
                            // Only now does the device in use go: opening this form changes nothing.
                            disconnect()
                            Task { await chat.connect(address: address, token: credential) }
                        }.disabled(address.isEmpty || token.isEmpty || chat.phase == .connecting)
                    }.listRowBackground(ChatColors.chip)
                }.textInputAutocapitalization(.never).autocorrectionDisabled().scrollContentBackground(.hidden)
                    .background(ChatColors.canvas.ignoresSafeArea()).navigationTitle("主机地址")
                    .toolbar { Button("取消") { connectByAddress = false } }
            }.presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let selected) = result { chat.attach(files: selected) }
        }
        .onChange(of: chat.pendingAttachment) { _, attached in
            guard let attached else { return }
            chat.attach(files: [attached]); chat.pendingAttachment = nil
        }
        .onChange(of: chat.phase) { old, new in if new == .replying && old != .replying { runStart = Date() } }
        .sheet(isPresented: $plusOpen, onDismiss: runAfterPlus) { plusPanel }
        .alert("打开全自动？", isPresented: $confirmFullAuto) {
            Button("取消", role: .cancel) {}
            Button("打开全自动") { chat.setFullAuto(true) }
        } message: { Text("这个对话会一路做完：不再确认、不再提问，打电话、付款、发送也直接执行，已存的账号密码和短信验证码会自动填写。") }
        .sheet(isPresented: $folderGrantsOpen) { NavigationStack { AuthorizedFoldersPage() } }
        .sheet(isPresented: $usageOpen) { usageSheet }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraCapture { captured in
                cameraOpen = false
                guard let captured else { return }
                Task {
                    if let photo = await Task.detached(priority: .userInitiated, operation: { DraftAttachment.photo(captured) }).value {
                        _ = await HostImage.thumbnail(photo)
                        chat.attach([photo])
                    }
                }
            }.ignoresSafeArea()
        }
        .task(id: "\(chat.connection?.sessionGeneration.uuidString ?? "")/\(chat.phase == .replying)/\(chat.switchingSession)/\(scenePhase)") {
            guard scenePhase == .active else { return }
            await chat.refreshSessionModes()
        }
    }

    /// Photos from the library: each is read, shrunk and re-encoded for the host off the main
    /// thread, then all go into the tray together.
    private func attachPhotos(_ loads: [() async -> Data?]) {
        Task {
            var picked: [DraftAttachment] = []
            for load in loads {
                guard let data = await load() else { continue }
                if let photo = await Task.detached(priority: .userInitiated, operation: { DraftAttachment.photo(data) }).value {
                    _ = await HostImage.thumbnail(photo)
                    picked.append(photo)
                }
            }
            ImageTiming.measure("attach", "count=\(picked.count)") { chat.attach(picked) }
        }
    }

    /// 顶栏：浮在消息上的玻璃胶囊；输入时让开。
    private var header: some View {
        let online = isOnline
        return ChatHeadingBar(aside: composing) {
            ChatHeading(title: chat.creatingSession ? String(localized: "新对话") : online ? chat.title : hostName,
                        subtitle: headerSubtitle(online), online: online,
                        menu: menu, detail: { online ? (panel = .details) : switchHost() },
                        detailLabel: online ? String(localized: "对话详情") : String(localized: "切换设备"), tone: headerTone(online), busy: headerBusy) {
                if online, !chat.creatingSession, subagents.count > 0 {
                    Button { panel = .subagents } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                            Text("\(subagents.count)").font(.subheadline.monospacedDigit())
                        }.padding(.horizontal, 13).frame(height: 44).chatCapsule()
                            .overlay(alignment: .topTrailing) {
                                if subagents.running > 0 { Circle().fill(Color.orange).frame(width: 8, height: 8).offset(x: -4, y: 4) }
                            }
                    }.buttonStyle(.pressable).foregroundStyle(ChatColors.ink)
                        .accessibilityLabel(subagents.running > 0 ? "\(subagents.count) 个子任务，\(subagents.running) 个运行中" : "\(subagents.count) 个子任务")
                        .accessibilityIdentifier("headerSubagents")
                }
                // A new conversation has nothing to leave; the button appears once it has messages.
                if online && !chat.creatingSession && !chat.messages.isEmpty {
                    ChatIcon(label: String(localized: "新对话"), symbol: "square.and.pencil") { Task { await chat.openSession(nil) } }
                }
            }
        }.disabled(chat.switchingSession)
    }

    /// 输入区：提示、待办条和输入框，浮在消息下沿。
    @ViewBuilder private var bottomBar: some View {
        let online = isOnline && !chat.creatingSession
        VStack(spacing: 0) {
            if let notice = chat.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    Text(notice).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button { chat.notice = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .buttonStyle(.plain).accessibilityLabel("关闭")
                }.padding(.horizontal, 14).padding(.vertical, 10).chatCard().padding(.horizontal, 16).padding(.bottom, 6)
                    .foregroundStyle(ChatColors.ink).accessibilityIdentifier("chatNotice")
                    .transition(.reveal(Motion.standard))
            }
            if notifyOffer.showing {
                NotificationOfferCard(offer: notifyOffer).transition(.reveal(Motion.standard))
            }
            if canType && !chat.creatingSession { dock }
            if online, let activity = RunActivity.of(chat) {
                ActivityStrip(activity: activity, since: chat.traces.last(where: \.running)?.start ?? runStart,
                              onTap: { panel = .details })
                    // Rises out from behind the composer, which is drawn over it.
                    .transition(.offset(y: 44))
            }
            if !canType {
                // Where the composer will be. Starting, or waiting for the app to be reopened: nothing to
                // tap. Otherwise a tap tries again (or picks a device when there is none to go back to).
                if isConnecting || relaunch {
                    offlineBar.accessibilityElement(children: .combine)
                } else {
                    Button { if let reconnect { reconnect() } else { switchHost() } } label: { offlineBar }
                        .buttonStyle(.plain).accessibilityIdentifier("offlineBar")
                }
            }
            if online { PaletteToast(palette: palette) }
            if online && palette.isOpen { ComposerPaletteView(palette: palette) { pickPalette($0) }.transition(.opacity.combined(with: .offset(y: 10))) }
            if online && voice.recording && !voice.handsFree { TalkPreview(live: voice.live, cancelling: voice.zone == .cancel).transition(.opacity.combined(with: .offset(y: 10))) }
            if canType { composer }
        }
        .animation(Motion.std(Motion.quick), value: palette.isOpen)
        .animation(Motion.std(Motion.quick), value: voice.recording)
        // Pills and the todo bar rise out from behind the composer and sink back (240ms).
        .animation(Motion.std(Motion.standard), value: dockState)
        .animation(Motion.std(Motion.standard), value: chat.notice)
    }

    private var dockState: [Bool] {
        [chat.sessionModes.risky, queued != nil, !chat.todos.isEmpty, chat.autoApprove, chat.fullAuto, chat.phase == .replying]
    }
}


private enum PlusAction { case camera, file, permission, folders, fullAuto }

extension ChatView {
    fileprivate func headerSubtitle(_ online: Bool) -> String {
        if chat.switchingSession { return String(localized: "正在创建会话…") }
        switch chat.phase {
        case .connecting: return String(localized: "正在连接")
        case .offline:
            if connectingSoon { return onPhone ? String(localized: "正在启动…") : String(localized: "正在连接") }
            return onPhone && (relaunch || chat.notice != nil) ? String(localized: "没能启动") : String(localized: "未连接")
        case .replying: return chat.stopRequest != nil ? String(localized: "正在停止") : chat.interactions.isEmpty ? String(localized: "生成中") : String(localized: "等你确认")
        case .ready: return chat.interactions.isEmpty ? hostDetail : String(localized: "等你确认")
        }
    }

    /// 正在连接、正在停止、生成中：顶栏状态点呼吸。
    fileprivate var headerBusy: Bool {
        if chat.switchingSession { return true }
        switch chat.phase {
        case .connecting: return true
        case .offline: return connectingSoon
        case .replying: return chat.stopRequest != nil || chat.interactions.isEmpty
        case .ready: return false
        }
    }

    fileprivate func headerTone(_ online: Bool) -> Color? {
        if !chat.interactions.isEmpty { return .orange }
        switch chat.phase {
        case .replying: return .accentColor
        case .connecting: return .orange
        case .offline: return connectingSoon ? .orange : nil
        default: return nil
        }
    }

    private var placeholder: String {
        if !chat.creatingSession && chat.phase == .replying { return String(localized: "生成中 · 可直接插话") }
        return String(localized: "给 Pallas 发消息…")
    }

    private var draftEmpty: Bool {
        chat.draftIsEmpty && chat.attachments.isEmpty
    }

    /// What stands where the composer will be while there is no connection.
    private var offlineBar: some View {
        HStack {
            ComposerIcon(symbol: "plus").opacity(0.5)
            Text(offlineBarText).font(.body).foregroundStyle(ChatColors.muted).lineLimit(1)
            Spacer()
            ComposerIcon(symbol: "arrow.up").opacity(0.5)
        }.padding(5).chatCapsule().padding(.horizontal, 16).padding(.bottom, 5)
    }

    private var offlineBarText: String {
        if relaunch { return String(localized: "请重新打开 Pallas Agent") }
        if isConnecting { return onPhone ? String(localized: "正在启动…") : String(localized: "正在连接…") }
        if reconnect == nil { return String(localized: "点这里选择设备") }
        return chat.notice != nil ? String(localized: "没连上，点这里重试") : String(localized: "点这里连接")
    }

    /// An example from the empty state: into the composer, for the person to edit and send.
    fileprivate func useExample(_ text: String) {
        chat.draft = text
        voiceMode = false
        composing = true
    }

    // MARK: Composer

    /// Keep the editing surface and its controls stable while the keyboard moves.
    /// Model selection lives below the glass, independent of first-responder changes.
    @ViewBuilder var composer: some View {
        let creating = chat.creatingSession
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                if !creating && !chat.attachments.isEmpty {
                    ComposerTray(items: chat.attachments) { chat.removeAttachment($0.id) }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                HStack(alignment: .bottom, spacing: 6) {
                    if !creating && VoiceRecorder.supported { voiceToggle }
                    if !creating && voiceMode && VoiceRecorder.supported {
                        HoldToTalkBar(recorder: voice, begin: startTalking, end: stopTalking)
                    } else {
                        // The text field, with the dictation mic inside on the right.
                        HStack(alignment: .bottom, spacing: 0) {
                            ChatDraftEditor(text: chat.typedDraft, composing: $composing,
                                            identifier: "hostComposer", placeholder: placeholder, handle: palette.editor,
                                            onCaret: creating ? nil : { palette.update(text: $0, caret: $1, host: chat.connection) })
                                .id(chat.draftID)
                            if !creating && VoiceRecorder.supported {
                                DictationKey(recorder: voice, tap: toggleDictation).padding(.trailing, 4).padding(.bottom, 5)
                            }
                        }
                    }
                    // While holding 按住 说话, ＋ gives way to ✏️ and ✕: slide right onto one before letting go.
                    if creating {
                        ProgressView().controlSize(.small).frame(width: 36, height: 36)
                    } else if voice.recording && !voice.handsFree {
                        TalkTarget(kind: .edit, recorder: voice) { endTalk(.edit) }
                        TalkTarget(kind: .cancel, recorder: voice) { endTalk(.cancel) }
                    } else {
                        plusButton
                    }
                    if !creating && sendKey != "idle" { sendButton }
                }
            }
            .padding(5)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))

            if isOnline && !creating {
                HStack(spacing: 6) {
                    modelChip
                    ComposerModeMenu(chat: chat) { composing = false; panel = .permission }
                    Spacer(minLength: 0)
                    contextRing
                }
            }
        }
        .disabled(chat.switchingSession && !creating)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, voice.recording { voice.held = false; voice.cancel(); talkKey = nil; dictationBase = nil; dictationWritten = nil }
        }
        .onReceive(WidgetLink.shared.$request) { takeWidgetLink($0) }
        // Opened cold from a widget, the chat starts before the composer may take the link.
        .onChange(of: canType) { _, ready in if ready { takeWidgetLink(WidgetLink.shared.request) } }
        // A link arrives before the app is active, when the field cannot take the keyboard yet.
        .onChange(of: scenePhase) { _, phase in if phase == .active { takeWidgetLink(WidgetLink.shared.request) } }
        .onAppear { voice.stoppedOnItsOwn = { if voice.handsFree { finishDictation() } else { endTalk(voice.zone) } } }
        .onReceive(voice.live.$transcript) { words in
            // Dictation writes as it hears, until the person types into the field themselves.
            guard voice.handsFree, voice.recording, let base = dictationBase, !words.isEmpty else { return }
            guard chat.draft == (dictationWritten ?? base) else { stopDictationWriting(); return }
            let text = VoiceRecorder.appending(words, to: base)
            chat.draft = text
            dictationWritten = text
        }
        .padding(.horizontal, 16).padding(.bottom, 5)
        .buttonStyle(PressableStyle(scale: 0.9)).foregroundStyle(ChatColors.ink)
        .animation(Motion.std(Motion.standard), value: chat.attachments.isEmpty)
        .animation(Motion.std(Motion.quick), value: voice.recording)
        .animation(Motion.std(Motion.quick), value: voiceMode)
    }

    private var plusButton: some View {
        Button { composing = false; plusOpen = true } label: { ComposerIcon(symbol: "plus") }
            .accessibilityLabel(String(localized: "添加图片或文件")).accessibilityIdentifier("composerPlus")
    }

    private var modelChip: some View {
        ModelPill(model: chat.modelLabel, effort: chat.modelEffort) { composing = false; panel = .models }
            .accessibilityIdentifier("hostModelSelector")
    }

    @ViewBuilder private var contextRing: some View {
        if let meter = chat.contextMeter, meter.window > 0 {
            let fraction = min(1, max(0, Double(meter.used) / Double(meter.window)))
            let percent = Int((fraction * 100).rounded())
            Button { usageOpen = true } label: { ContextRing(fraction: fraction) }
                .accessibilityLabel(String(localized: "对话长度已用 \(percent)%")).accessibilityIdentifier("contextRing")
        }
    }

    /// 停止 / 空 / 发送之间换图：新图从 0.4 倍弹出，发送的纸飞机朝右上飞走。
    private var sendKey: String { talkKey ?? (chat.phase == .replying && draftEmpty ? "stop" : draftEmpty ? "idle" : "send") }

    private var sendButton: some View {
        ZStack {
            sendButtonKey.transition(sendKey == "send" ? .sendAway : .keySwap)
                .id(sendKey)
        }
        .frame(width: 36, height: 36)
        .animation(Motion.thumbSpring, value: sendKey)
    }

    @ViewBuilder private var sendButtonKey: some View {
        if sendKey == "stop" {
            Button { Task { await chat.stopTurn() } } label: { ComposerIcon(symbol: "stop.fill", active: true) }
                .accessibilityLabel(String(localized: "停止本轮")).accessibilityIdentifier("stopHostTurn").disabled(chat.stopRequest != nil)
        } else if sendKey == "idle" {
            ComposerIcon(symbol: "arrow.up").opacity(0.5).accessibilityLabel(String(localized: "发送")).accessibilityAddTraits(.isButton)
        } else if chat.phase == .replying {
            // Tap: 插话. Long press: choose how (插话 / 中断并发送 / 排队), as in DSH.
            Menu {
                Button { submit(.steer) } label: { Label(String(localized: "插话 · 不打断，AI 下一步会看到"), systemImage: "text.bubble") }
                Button { submit(.interrupt) } label: { Label(String(localized: "中断并发送 · 停下当前任务，先处理这条"), systemImage: "stop.circle") }
                Button { submit(.queue) } label: { Label(String(localized: "排队 · 本轮结束后发送"), systemImage: "clock") }
            } label: { ComposerIcon(symbol: "arrow.up", active: true) } primaryAction: { submit(.steer) }
                .accessibilityLabel("发送").accessibilityHint(String(localized: "长按选择发送方式")).disabled(chat.forking)
        } else {
            Button { submit(.normal) } label: { ComposerIcon(symbol: "arrow.up", active: true) }
                .accessibilityLabel(String(localized: "发送")).disabled((chat.phase != .ready && !isConnecting) || chat.forking)
        }
    }

    // MARK: Voice input (像微信：🎤 切到按住说话)

    /// 🔈 / ⌨️ at the far left: switches the field between typing and 按住 说话. Asks for the microphone the
    /// first time, so the first hold already records.
    private var voiceToggle: some View {
        Button { toggleVoice() } label: { ComposerIcon(symbol: voiceMode ? "keyboard" : "speaker.wave.2") }
            .accessibilityLabel(voiceMode ? String(localized: "切换到键盘") : String(localized: "语音输入"))
            .accessibilityIdentifier("voiceToggle")
    }

    private func toggleVoice() {
        if voice.recording && voice.handsFree { finishDictation() }
        if voiceMode { voiceMode = false; composing = true; return }
        composing = false
        palette.close()
        Task {
            if await voice.prepare() { voiceMode = true }
            else { chat.notice = String(localized: "没有麦克风或语音识别权限，请在系统设置里打开。") }
        }
    }

    /// 问 Pallas from a widget or control: the field gets the keyboard, or dictation starts.
    private func takeWidgetLink(_ request: WidgetLink.Request?) {
        guard let request, canType, scenePhase == .active else { return }
        WidgetLink.shared.request = nil
        voiceMode = false
        switch request {
        case .type: composing = true
        case .speak: if VoiceRecorder.supported { toggleDictation() } else { composing = true }
        }
    }

    // MARK: Dictation (the mic in the field)

    private func toggleDictation() {
        if voice.recording && voice.handsFree { finishDictation(); return }
        guard !voice.held, !voice.recording else { return }
        composing = false
        palette.close()
        dictationBase = chat.draft
        dictationWritten = nil
        voice.handsFree = true; voice.held = true; voice.origin = nil
        startTalking()
    }

    /// Stops listening; the words are already in the field and get their final form — unless the field
    /// was sent or edited meanwhile, which the last words must not undo.
    private func finishDictation() {
        voice.held = false
        Task {
            let said = await voice.finish()
            defer { dictationBase = nil; dictationWritten = nil }
            guard let said, let base = dictationBase, chat.draft == (dictationWritten ?? base) else { return }
            if said.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                chat.notice = String(localized: "没听清，请再说一次。")
            } else {
                chat.draft = VoiceRecorder.appending(said, to: base)
            }
        }
    }

    /// Dictation lets go of the field: listening stops and nothing more is written into it.
    private func stopDictationWriting() {
        guard dictationBase != nil else { return }
        dictationBase = nil
        dictationWritten = nil
        if voice.recording && voice.handsFree { voice.held = false; voice.cancel() }
    }

    /// A tap on ✏️ or ✕: the talking ends there.
    private func endTalk(_ zone: TalkZone) {
        voice.held = false
        stopTalking(zone)
    }

    private func startTalking() {
        guard !voice.recording else { return }
        palette.close()
        // Holding: the send key must not swap under the finger. Dictating fills the field, so it may.
        if !voice.handsFree { talkKey = sendKey }
        UIImpactFeedbackGenerator(style: voice.handsFree ? .light : .medium).impactOccurred()
        let hints = ["Pallas", hostName]
        Task {
            let started = await voice.begin(hints: hints)
            if started != .recording { UITrace.note("voice begin \(started)"); voice.held = false; dictationBase = nil }
            switch started {
            case .recording: break
            case .askedPermission, .released: talkKey = nil
            case .denied:
                talkKey = nil
                chat.notice = String(localized: "没有麦克风或语音识别权限，请在系统设置里打开。")
            case .unavailable:
                talkKey = nil
                chat.notice = String(localized: "语音识别暂时不可用。")
            case .downloading:
                talkKey = nil
                chat.notice = String(localized: "正在下载语音识别模型，请稍后再试。")
            }
        }
    }

    /// Release: send (插话 while replying), drop, or put the words in the composer to edit.
    private func stopTalking(_ zone: TalkZone) {
        guard voice.recording else { talkKey = nil; return }
        if zone == .cancel {
            voice.cancel(); talkKey = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        Task {
            let said = await voice.finish()
            talkKey = nil
            guard let said else { return }
            guard !said.isEmpty else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                chat.notice = String(localized: "没听清，请再说一次。")
                return
            }
            let typed = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let sendable = typed.isEmpty && (chat.phase == .ready || chat.phase == .replying) && !chat.forking
            guard zone == .send, sendable else {
                chat.draft += said
                voiceMode = false
                composing = true
                return
            }
            chat.draft = said
            submit(chat.phase == .replying ? .steer : .normal)
        }
    }

    fileprivate func submit(_ how: SendHow) {
        guard !chat.switchingSession else { return }
        // Sent while dictating (or before its last words came in): what is sent is what the field shows.
        stopDictationWriting()
        let text = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if chat.attachments.isEmpty, let typed = SlashCommand.resolve(palette.commands, line: text), typed.command.source != .skill {
            chat.draft = ""; composing = false; palette.close()
            runCommand("/" + typed.command.name + (typed.command.source == .app ? "" : typed.rest)); return
        }
        let attached = chat.attachments
        guard !text.isEmpty || !attached.isEmpty else { return }
        // No model to answer: the message stays in the field and the person goes to sign in.
        if chat.needsModelSetup == true, signIn != nil || configureAI != nil {
            composing = false
            if let configureAI { configureAI() } else { signIn?() }
            return
        }
        chat.attachments = []
        chat.draft = ""; composing = false
        if !isOnline { sendOnceReady(text, attachments: attached); return }
        switch how {
        case .normal: Task { await chat.send(text, attachments: attached) }
        case .steer: Task { await chat.send(text, attachments: attached, steer: true) }
        case .interrupt, .queue:
            queued = text.isEmpty ? String(localized: "附件") : text
            Task {
                let host = chat.connection
                if how == .interrupt { await chat.stopTurn() }
                var waited = 0
                while chat.phase == .replying, chat.connection === host, waited < 1200 {
                    try? await Task.sleep(for: .milliseconds(250)); waited += 1
                }
                queued = nil
                guard chat.connection === host, chat.phase == .ready else {
                    chat.draft = text; chat.attach(attached); chat.notice = String(localized: "排队的消息没有发出，已放回输入框。"); return
                }
                await chat.send(text, attachments: attached)
            }
        }
    }

    /// Sent while the engine starts: shown as queued, sent the moment the chat is ready. If it never gets
    /// there, or there turns out to be no model to answer, the message goes back into the field.
    private func sendOnceReady(_ text: String, attachments attached: [DraftAttachment]) {
        queued = text.isEmpty ? String(localized: "附件") : text
        queuedForStart = true
        Task {
            var waited = 0
            while chat.phase != .ready, waited < 360 { try? await Task.sleep(for: .milliseconds(250)); waited += 1 }
            // The model list arrives just after the connection.
            var listed = 0
            while chat.phase == .ready, chat.needsModelSetup == nil, listed < 20 { try? await Task.sleep(for: .milliseconds(150)); listed += 1 }
            queued = nil; queuedForStart = false
            guard chat.phase == .ready, chat.needsModelSetup != true else {
                chat.draft = text; chat.attach(attached)
                if chat.phase == .ready, let action = configureAI ?? signIn { action() }
                else { chat.notice = String(localized: "排队的消息没有发出，已放回输入框。") }
                return
            }
            await chat.send(text, attachments: attached)
        }
    }

    /// A palette row: commands run, everything else was inserted at the caret.
    fileprivate func pickPalette(_ item: PaletteItem) {
        guard let line = palette.pick(item) else { return }
        runCommand(line)
    }

    /// `/new` and `/model` are the app's; the rest go to the host (`commands/execute`).
    fileprivate func runCommand(_ line: String) {
        switch line {
        case "/new": composing = false; Task { await chat.openSession(nil) }
        case "/model": composing = false; panel = .models
        default:
            if let host = chat.connection {
                Task {
                    await palette.run(line, on: host)
                    if chat.connection === host { await chat.refreshSessionModes() }
                }
            }
        }
    }

    // MARK: Dock above the composer

    @ViewBuilder var dock: some View {
        if queued != nil || !chat.todos.isEmpty || chat.autoApprove || chat.fullAuto {
            VStack(spacing: 6) {
                if chat.fullAuto {
                    ComposerFullAutoStatus { chat.setFullAuto(false) }
                        .transition(.offset(y: 14).combined(with: .opacity))
                } else if chat.autoApprove {
                    ComposerApprovalStatus { chat.setAutoApprove(false) }
                        .transition(.offset(y: 14).combined(with: .opacity))
                }
                if let queued {
                    ComposerQueuedMessage(text: queued, starting: queuedForStart)
                        .transition(.offset(y: 14).combined(with: .opacity))
                }
                if !chat.todos.isEmpty {
                    ComposerTodoList(todos: chat.todos, running: chat.phase == .replying, expanded: $todosOpen)
                        .transition(.offset(y: 14).combined(with: .opacity))
                }
            }.padding(.horizontal, 16).padding(.bottom, 6)
        }
    }

    // MARK: ＋ panel and usage

    var plusPanel: some View {
        // 权限 and 先列计划 sit beside the model.
        HStack(spacing: 8) {
            PhotosPicker(selection: $photos, maxSelectionCount: max(1, chat.attachmentRoom), matching: .images) { plusTile(String(localized: "相册"), "photo.on.rectangle", .blue) }
            Button { afterPlus = .camera; plusOpen = false } label: { plusTile(String(localized: "拍照"), "camera", .orange) }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button { afterPlus = .file; plusOpen = false } label: { plusTile(String(localized: "文件"), "folder", .teal) }
            if let host = chat.connection, EmbeddedEngine.shared.owns(host) {
                Button { afterPlus = .folders; plusOpen = false } label: { plusTile(String(localized: "授权文件夹"), "folder.badge.plus", .teal) }
                Button {
                    if chat.fullAuto { chat.setFullAuto(false) } else { afterPlus = .fullAuto; plusOpen = false }
                } label: { plusTile(String(localized: "全自动"), chat.fullAuto ? "bolt.fill" : "bolt", .orange, on: chat.fullAuto) }
                    .accessibilityIdentifier("plusFullAuto")
            }
        }.buttonStyle(.plain).disabled(chat.botSession)
        .padding(16).padding(.top, 8).frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ChatColors.ink)
        .background(ChatColors.panel.ignoresSafeArea())
        .presentationDetents([.height(160)]).presentationDragIndicator(.visible).presentationCornerRadius(28)
    }

    private func plusTile(_ title: String, _ symbol: String, _ tint: Color, on: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(on ? .white : tint)
                .frame(width: 60, height: 60).background(on ? tint : tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.caption).foregroundStyle(ChatColors.ink)
        }.frame(maxWidth: .infinity).contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    fileprivate func runAfterPlus() {
        guard let action = afterPlus else { return }
        afterPlus = nil
        switch action {
        case .camera: cameraOpen = true
        case .file: picking = true
        case .permission: panel = .permission
        case .folders: folderGrantsOpen = true
        case .fullAuto: confirmFullAuto = true
        }
    }

    var usageSheet: some View {
        NavigationStack {
            ComposerUsage(chat: chat, canCompact: chat.phase == .ready) {
                usageOpen = false
                Task { await chat.compactFromComposer() }
            }
            .navigationTitle(String(localized: "用量")).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(String(localized: "完成")) { usageOpen = false } }
        }.presentationDetents([.medium])
    }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if count >= 1000 { return "\(Int((Double(count) / 1000).rounded()))K" }
        return "\(count)"
    }

}

/// The system camera, for the ＋ panel's 拍照.
struct CameraCapture: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
