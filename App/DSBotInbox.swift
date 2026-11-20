// DS Bot 的侧栏行、未读和通知。
//
// 未读按「主机 + 会话（群聊 ID，否则 Bot ID）」记：每条 `notice` 带主机内递增的 `seq`，
// 收到后记进该会话的未读列表；打开这个 Bot 时把它的最新 seq 记为已读。每台主机存一个游标
// `{boot, seq}`：feed 的 `hello` 同一 boot 且 seq 更大时用 `notices {boot, since}` 补齐断线期间
// 的通知；boot 变了（插件重启）就从新的 seq 重新开始。seq 不大于游标、或已经收过的通知一律忽略，
// 所以重连重放同一事件不会重复计数，也不会重复弹通知。
// 通知遵守「设置 → 通知」的总开关和「DS Bot 消息」开关；点通知会切到发出它的主机再打开 Bot。

import CryptoKit
import SwiftUI
import UserNotifications

@MainActor
final class DSBotInbox: ObservableObject {
    private static var inboxes: [String: DSBotInbox] = [:]

    /// The inbox of `scope` (the drawer's host scope), following `host` while it is connected.
    static func of(_ host: Harness, scope: String, hostName: String) -> DSBotInbox {
        let inbox = inboxes[scope] ?? DSBotInbox(scope: scope)
        inboxes[scope] = inbox
        inbox.hostName = hostName
        if inbox.host !== host { inbox.attach(host) }
        return inbox
    }

    let scope: String
    var hostName = ""
    private(set) weak var host: Harness?
    /// nil while checking; false when the host has no DS Bot.
    @Published private(set) var available: Bool?
    @Published private(set) var bots: [Object] = []
    @Published private(set) var record: Record
    /// The conversation on screen (its notices count as read at once).
    var viewing: String? { didSet { if let viewing { markRead(viewing) } } }
    #if os(macOS)
    var visibleSession: (() -> String?)?
    #endif
    private var feed: Task<Void, Never>?

    struct Record: Codable, Equatable {
        var boot: String?
        var seq = 0
        var lastRead: [String: Int] = [:]
        var pending: [String: [Int]] = [:]
        var names: [String: String] = [:]
        var sessions: [String: String] = [:]

        /// A feed `hello`: true when notices since the cursor must be fetched. A first contact or a
        /// restarted plugin (another boot) starts from its current seq; nothing older counts as new.
        mutating func hello(boot: String?, seq: Int) -> Bool {
            if let boot, self.boot == boot { return seq > self.seq }
            self.boot = boot; self.seq = seq
            return false
        }

        /// Takes one notice; returns the conversation to notify about, or nil (already seen, read on screen, or not a message).
        mutating func accept(_ notice: Object, viewing: String?) -> String? {
            guard let seq = notice["seq"] as? Int, seq > self.seq else { return nil }
            self.seq = seq
            guard let conversation = Self.conversation(in: notice) else { return nil }
            let room = notice["roomId"] as? String != nil
            if let name = notice[room ? "title" : "name"] as? String { names[conversation] = name }
            // A group approval can name the member's work session. The group's own
            // session comes from the team state and stays the destination for the notice.
            if !room, let session = notice["sessionId"] as? String, !session.isEmpty {
                sessions[conversation] = session
            }
            if viewing == conversation { lastRead[conversation] = seq; return nil }
            guard ["message", "group", "done", "question", "approval", "view"].contains(notice["kind"] as? String ?? "message") else { return nil }
            pending[conversation] = Array(((pending[conversation] ?? []) + [seq]).suffix(99))
            return conversation
        }

        static func conversation(in notice: Object) -> String? {
            guard let id = notice["roomId"] as? String ?? notice["botId"] as? String, !id.isEmpty else { return nil }
            return id
        }

        mutating func read(_ conversation: String) {
            lastRead[conversation] = max(lastRead[conversation] ?? 0, pending[conversation]?.max() ?? 0)
            pending[conversation] = []
        }
    }

    private var key: String { "dsbot-inbox-" + Data(SHA256.hash(data: Data(scope.utf8))).prefix(12).base64EncodedString() }

    private init(scope: String) {
        self.scope = scope
        let key = "dsbot-inbox-" + Data(SHA256.hash(data: Data(scope.utf8))).prefix(12).base64EncodedString()
        record = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: key) }
    }

    func unread(_ conversation: String) -> Int { record.pending[conversation]?.count ?? 0 }
    var totalUnread: Int { record.pending.values.reduce(0) { $0 + $1.count } }

    func session(for conversation: String) -> String? { record.sessions[conversation] }

    static func knowsSession(_ session: String, scope: String) -> Bool {
        inboxes[scope]?.record.sessions.values.contains(session) == true
    }

    func markRead(_ conversation: String) {
        guard record.pending[conversation]?.isEmpty == false else { return }
        record.read(conversation)
        save()
        let id = DSBotNotifications.identifier(scope: scope, conversation: conversation)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Marks the conversation whose Bot session this is as read.
    func opened(session: String) {
        let conversations = record.sessions.filter { $0.value == session }.keys
        for id in conversations { markRead(id) }
    }

    // MARK: Feed

    private func attach(_ host: Harness) {
        self.host = host
        feed?.cancel()
        available = nil
        feed = Task { [weak self] in await self?.run() }
    }

    func stop() { feed?.cancel(); feed = nil }

    func resume() {
        guard feed == nil, let host else { return }
        attach(host)
    }

    private func run() async {
        // Giving up (no DS Bot here) leaves room for `resume()` to try again later; a replaced feed is cancelled and keeps its successor.
        defer { if !Task.isCancelled { feed = nil } }
        var delay = 0.5
        while !Task.isCancelled, let host, host.pluginRoute("api/bot/feed") != nil {
            do {
                #if os(macOS)
                let platform = "macos"
                #else
                let platform = "ios"
                #endif
                let hello = try await host.bot("hello", ["client": ["name": "dsh-local", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0", "platform": platform], "api": [1]]) as? Object
                guard !Task.isCancelled, self.host === host else { return }
                guard hello?["api"] as? Int == 1 else { available = false; return }
                available = true
                await readState()
                try Task.checkCancellation()
                try await listen(host)
                delay = 0.5
            } catch let error as HostError where error.code == "bot_unavailable" {
                guard !Task.isCancelled, self.host === host else { return }
                available = false; return
            } catch {
                if Task.isCancelled { return }
                if available == nil { available = false }
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = [0.5, 1, 2, 5, 10].first { $0 > delay } ?? 10
        }
    }

    func readState() async {
        guard let host, let state = try? await host.bot("state", ["avatars": "ref", "locale": AppLanguage.code]) as? Object,
              !Task.isCancelled, self.host === host else { return }
        applyState(state)
    }

    func applyState(_ state: Object) {
        let rows = state["bots"] as? [Object] ?? []
        let mains = (state["mainBotIds"] as? [String] ?? []).compactMap { id in rows.first { $0["id"] as? String == id } }
        let mainIDs = Set(mains.compactMap { $0["id"] as? String })
        bots = mains + rows.filter { !mainIDs.contains($0["id"] as? String ?? "") }
        for row in rows + (state["rooms"] as? [Object] ?? []) {
            guard let id = row["id"] as? String else { continue }
            record.names[id] = row["name"] as? String ?? id
            if let session = row["sessionId"] as? String, !session.isEmpty { record.sessions[id] = session }
        }
        #if os(macOS)
        if let session = visibleSession?() { opened(session: session) }
        #endif
        save()
    }

    /// One `GET api/bot/feed` until it ends.
    private func listen(_ host: Harness) async throws {
        guard let (session, base) = host.pluginRoute("api/bot/feed") else { throw HostError(String(localized: "这台设备收不到 AI 团队的消息。")) }
        var request = base
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HostError(String(localized: "收不到 AI 团队的消息。请稍后重试。")) }
        // Lines are split here, not with `bytes.lines`: that sequence skips the empty lines that end each event.
        var parser = DSBotFeedParser()
        var line: [UInt8] = []
        for try await byte in bytes {
            guard byte == 0x0A else { line.append(byte); continue }
            if line.last == 0x0D { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if let (event, value) = parser.take(text) {
                guard !Task.isCancelled, self.host === host else { return }
                try await handle(event, value)
            }
        }
    }

    private func handle(_ event: String, _ value: Object) async throws {
        switch event {
        case "hello":
            let boot = value["boot"] as? String
            if record.hello(boot: boot, seq: value["seq"] as? Int ?? 0), let boot { try await catchUp(boot) } else { save() }
        case "notice": accept(value)
        case "revision", "live", "room": await readState()
        default: break
        }
    }

    private func catchUp(_ boot: String) async throws {
        guard let host else { return }
        guard let reply = try await host.bot("notices", ["boot": boot, "since": record.seq]) as? Object else {
            throw HostError(String(localized: "收不到 AI 团队的消息。请稍后重试。"))
        }
        guard !Task.isCancelled, self.host === host else { return }
        if reply["reset"] as? Bool == true || reply["boot"] as? String != boot {
            record.boot = reply["boot"] as? String; record.seq = reply["seq"] as? Int ?? record.seq; save(); return
        }
        for notice in reply["notices"] as? [Object] ?? [] { accept(notice) }
    }

    private func accept(_ notice: Object) {
        let room = notice["roomId"] as? String != nil
        #if os(macOS)
        let onScreen: String?
        if let session = visibleSession?(), let id = Record.conversation(in: notice),
           (room ? record.sessions[id] : notice["sessionId"] as? String ?? record.sessions[id]) == session {
            onScreen = id
        } else { onScreen = nil }
        #else
        let onScreen = UIApplication.shared.applicationState == .active ? viewing : nil
        #endif
        guard let conversation = record.accept(notice, viewing: onScreen) else { save(); return }
        DSBotNotifications.post(scope: scope, hostName: hostName, conversation: conversation, room: room,
                                title: notice["title"] as? String ?? record.names[conversation] ?? String(localized: "AI 团队"),
                                text: notice["text"] as? String ?? "", session: record.sessions[conversation], kind: notice["kind"] as? String ?? "message")
        save()
    }
}

/// Server-sent events, one line at a time: an empty line ends an event.
struct DSBotFeedParser {
    private var event = "message", data = ""

    /// Takes one line (without its line break); returns an event when this line ends one.
    mutating func take(_ line: String) -> (String, Object)? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            let ready = data.isEmpty ? nil : flush()
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return ready
        }
        if line.hasPrefix("data:") { data += (data.isEmpty ? "" : "\n") + line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private mutating func flush() -> (String, Object)? {
        defer { event = "message"; data = "" }
        guard !data.isEmpty, let value = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? Object else { return nil }
        return (event, value)
    }
}

// MARK: - 通知

/// Where a tapped DS Bot notification goes.
struct DSBotRoute: Identifiable, Equatable, Sendable {
    let id = UUID()
    let scope: String
    let conversation: String
    let session: String?
    let room: Bool

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo["kind"] as? String, ["dsbot-room", "dsbot-bot"].contains(kind),
              let scope = userInfo["scope"] as? String, !scope.isEmpty,
              let conversation = userInfo["conversation"] as? String, !conversation.isEmpty else { return nil }
        self.scope = scope
        self.conversation = conversation
        room = kind == "dsbot-room"
        session = (userInfo["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    @MainActor func destination(in inbox: DSBotInbox) async -> String? {
        if room || (session == nil && inbox.session(for: conversation) == nil) { await inbox.readState() }
        return room ? inbox.session(for: conversation) : session ?? inbox.session(for: conversation)
    }
}

@MainActor
final class DSBotNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    #if os(iOS)
    static let shared = DSBotNotifications()
    @Published var route: DSBotRoute?
    /// A tapped "办好了": the 本机 conversation that finished.
    @Published var replySession: String?

    /// Installs the delegate (banners while the app is open, taps routed here).
    static func install() { UNUserNotificationCenter.current().delegate = shared }
    #endif

    nonisolated static func identifier(scope: String, conversation: String) -> String {
        "dsbot-" + Data(SHA256.hash(data: Data((scope + "\n" + conversation).utf8))).prefix(10).base64EncodedString()
    }

    static func post(scope: String, hostName: String, conversation: String, room: Bool, title: String, text: String, session: String?, kind: String) {
        if let request = request(scope: scope, hostName: hostName, conversation: conversation, room: room,
                                 title: title, text: text, session: session, kind: kind) {
            UNUserNotificationCenter.current().add(request)
        }
    }

    static func request(scope: String, hostName: String, conversation: String, room: Bool, title: String, text: String, session: String?, kind: String) -> UNNotificationRequest? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "notifyEnabled") as? Bool ?? true, defaults.object(forKey: "notifyBot") as? Bool ?? true else { return nil }
        let content = UNMutableNotificationContent()
        content.title = ShareText.redacted(title)
        content.subtitle = hostName
        content.body = text.isEmpty ? (kind == "question" ? String(localized: "有问题等你回答") : kind == "approval" ? String(localized: "有操作等你批准") : String(localized: "发来新消息")) : String(ShareText.redacted(text).prefix(140))
        content.threadIdentifier = identifier(scope: scope, conversation: conversation)
        content.sound = .default
        var info: [String: String] = ["kind": room ? "dsbot-room" : "dsbot-bot", "scope": scope, "conversation": conversation]
        if let session { info["session"] = session }
        content.userInfo = info
        // One notification per conversation: the newest replaces the one before.
        return UNNotificationRequest(identifier: identifier(scope: scope, conversation: conversation), content: content, trigger: nil)
    }

    #if os(iOS)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // With Pallas Agent in front the engine runs the task this very second; nothing to tap.
        if notification.request.content.userInfo["kind"] as? String == DueTasks.kind { return [] }
        return [.banner, .list, .sound]
    }

    /// UIKit wants the completion on the main thread: a button answered in the background (手机操控's key steps)
    /// otherwise aborts the app, which the async form of this method did.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let route = action == UNNotificationDefaultActionIdentifier ? DSBotRoute(userInfo: info) : nil
        let reply = [TurnKeepAlive.doneKind, DueTasks.kind].contains(info["kind"] as? String ?? "") ? info["session"] as? String : nil
        DispatchQueue.main.async { [route] in
            MainActor.assumeIsolated {
                if let route { DSBotNotifications.shared.route = route }
                else if let reply { DSBotNotifications.shared.replySession = reply }
            }
            completionHandler()
        }
    }
    #endif
}

// MARK: - 侧栏

/// The drawer's DS Bot rows (main Bots first), each with its unread count.
struct DSBotSidebarRows: View {
    let currentSession: String?
    let botSession: Bool
    let open: (String) -> Void
    let showTeam: (() -> Void)?
    @ObservedObject private var inbox: DSBotInbox
    @Environment(\.scenePhase) private var scenePhase

    init(host: Harness, scope: String, hostName: String, currentSession: String?, botSession: Bool, open: @escaping (String) -> Void) {
        self.init(inbox: DSBotInbox.of(host, scope: scope, hostName: hostName),
                  currentSession: currentSession, botSession: botSession, open: open)
    }

    init(inbox: DSBotInbox, currentSession: String?, botSession: Bool,
         showTeam: (() -> Void)? = nil, open: @escaping (String) -> Void) {
        self.inbox = inbox
        self.currentSession = currentSession
        self.botSession = botSession
        self.showTeam = showTeam
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if inbox.available == true {
                if let showTeam {
                    Button(action: showTeam) {
                        HStack {
                            Label("AI 团队", systemImage: HostPanel.bots.symbol)
                            Spacer()
                            DSBotUnreadBadge(inbox: inbox)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("open-bot-team")
                    .accessibilityLabel(unreadLabel(String(localized: "AI 团队"), count: inbox.totalUnread))
                } else if !inbox.bots.isEmpty {
                    DrawerEyebrow(String(localized: "AI 团队"))
                }
                ForEach(Array(inbox.bots.prefix(4).enumerated()), id: \.offset) { _, bot in row(bot) }
            }
        }
        #if os(iOS)
        .task(id: "\(currentSession ?? "")/\(botSession)") {
            if botSession, let currentSession {
                let conversation = inbox.record.sessions.first { $0.value == currentSession }?.key
                    ?? inbox.bots.first { $0["sessionId"] as? String == currentSession }?["id"] as? String
                inbox.viewing = conversation
            } else { inbox.viewing = nil }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in if phase == .active { inbox.resume() } }
        // A host that had no DS Bot when the app connected may have one now (a plugin installed since).
        .onAppear { inbox.resume() }
    }

    @ViewBuilder private func row(_ bot: Object) -> some View {
        if let id = bot["id"] as? String {
            let name = bot["name"] as? String ?? id
            let count = inbox.unread(id)
            let session = inbox.session(for: id) ?? id
            Button {
                #if os(iOS)
                inbox.markRead(id)
                #endif
                open(session)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.footnote).foregroundStyle(ChatColors.muted)
                        .frame(width: 28, height: 28).background(ChatColors.muted.opacity(0.12), in: Circle())
                    Text(verbatim: name).font(.subheadline).foregroundStyle(ChatColors.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    DSBotUnreadBadge(inbox: inbox, conversation: id)
                }.padding(.horizontal, 16).padding(.vertical, 6).contentShape(Rectangle())
                #if os(macOS)
                .background(DrawerRowFill(on: botSession && currentSession == session))
                #endif
            }.buttonStyle(.plain)
                .accessibilityLabel(unreadLabel(name, count: count))
                .accessibilityIdentifier("drawerBot-" + id)
        }
    }

    private func unreadLabel(_ title: String, count: Int) -> String {
        count > 0 ? String(localized: "\(title)，\(count) 条未读") : title
    }
}

struct DSBotUnreadBadge: View {
    @ObservedObject var inbox: DSBotInbox
    var conversation: String?

    var body: some View {
        let count = conversation.map(inbox.unread) ?? inbox.totalUnread
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20).background(Color.red, in: Capsule())
                .accessibilityLabel(String(localized: "\(count) 条未读"))
        }
    }
}
