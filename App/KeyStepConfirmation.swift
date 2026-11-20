import LocalAuthentication
import SwiftUI
import UserNotifications

/// 关键步骤先问我: opening an app, and sending, deleting or paying, wait for the person's answer.
/// The first open of a turn happens with Pallas Agent in front and asks there; later steps ask by notification,
/// because bringing Pallas Agent to the front stops the turn's control.
@MainActor
final class PhoneConfirmation: ObservableObject {
    static let shared = PhoneConfirmation()

    /// `faceID` asks like `ask`, and paying, sending, deleting or ordering also needs Face ID (or the passcode) to allow.
    enum Mode: String { case ask, faceID, auto }
    static let modeKey = "phoneConfirmMode"
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .ask }
    /// Key steps wait for the person.
    static var asks: Bool { mode != .auto }

    /// The name of the `faceID` choice, after what this iPhone unlocks with.
    static var faceIDTitle: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return String(localized: "付款和发送要按指纹")
        case .faceID: return String(localized: "付款和发送要刷脸")
        default: return String(localized: "付款和发送要输密码")
        }
    }
    /// False until the person has picked a mode, which the first switch-on asks for.
    static var chosen: Bool { UserDefaults.standard.string(forKey: modeKey) != nil }

    static let category = "phone-confirm"
    private static let allowAction = "allow"
    private static let tokenKey = "phoneConfirm"
    private static let limit: Duration = .seconds(120)
    /// A second banner goes out this long after the first, for a person who missed it.
    private static let remindAfter: TimeInterval = 90

    enum Outcome { case allowed, denied, timedOut, unavailable }

    struct Question: Identifiable {
        let id: UUID
        let step: String
        /// Allowing needs the device owner: Face ID, else the passcode.
        let owner: Bool
        /// 「这一轮都允许」 is offered next to 允许.
        var all = false
    }

    /// The question shown inside Pallas Agent.
    @Published private(set) var question: Question?
    private var waiting: [UUID: (owner: UUID, resume: CheckedContinuation<Bool?, Never>)] = [:]
    /// Face ID or passcode checks still on screen, by question.
    private var checking: [UUID: LAContext] = [:]
    /// Questions answered 「这一轮都允许」, until their `ask` reads the answer.
    private var allowedAll: Set<UUID> = []

    static func registerCategory() {
        // On the Lock Screen, 允许 asks for Face ID or the passcode first.
        let allow = UNNotificationAction(identifier: allowAction, title: String(localized: "允许"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: String(localized: "不允许"), options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [allow, deny], intentIdentifiers: [], options: [.customDismissAction]),
        ])
    }

    /// Whether banners can reach the person; asks iOS the first time.
    static func requestNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .ephemeral: return true
        case .notDetermined, .provisional: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    /// `serious`: the step pays, sends, deletes or orders; in the `faceID` mode allowing it in Pallas Agent needs the device owner.
    /// A notification cannot ask for Face ID while another app is in front; its 允许 needs the iPhone unlocked.
    func ask(_ step: String, owner: UUID, serious: Bool = false) async -> Outcome {
        await ask(step, owner: owner, serious: serious, offerAll: false).outcome
    }

    /// `offerAll`: the question inside Pallas Agent also offers 「这一轮都允许」, and `all` says it was picked.
    /// Banners and the Live Activity keep 允许 / 不允许, which allow this step only.
    func ask(_ step: String, owner: UUID, serious: Bool = false, offerAll: Bool) async -> (outcome: Outcome, all: Bool) {
        cancel(owner)
        let token = UUID()
        if UIApplication.shared.applicationState == .active {
            question = Question(id: token, step: step, owner: serious && Self.mode == .faceID, all: offerAll && !(serious && Self.mode == .faceID))
        } else if !(serious && Self.mode == .faceID), await TaskActivity.shared.ask(step, token: token) {
            // 允许 / 不允许 are on the Live Activity (`AllowStepIntent`), which answers without bringing Pallas Agent forward.
            // The reminder still goes out as a banner, whose long-press buttons answer even when the Live Activity's cannot.
            await Self.remind(step, token: token)
        } else {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .ephemeral else { return (.unavailable, false) }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "要继续这一步吗？")
            // Opening the banner brings Pallas Agent to the front, which ends the turn: the buttons are under a long press.
            content.body = step + "\n" + String(localized: "长按这条通知来回答。")
            content.categoryIdentifier = Self.category
            content.sound = .default
            content.userInfo = [Self.tokenKey: token.uuidString]
            // Gets through a Focus: the step waits on this answer.
            content.interruptionLevel = .timeSensitive
            do { try await center.add(UNNotificationRequest(identifier: Self.identifier(token), content: content, trigger: nil)) }
            catch { return (.unavailable, false) }
            // Nothing can count down on a banner, so a second one says the wait is about to end.
            await Self.remind(step, token: token)
        }
        let answer: Bool? = await withCheckedContinuation { continuation in
            waiting[token] = (owner, continuation)
            Task {
                try? await Task.sleep(for: Self.limit)
                self.answer(token, allowed: nil)
            }
        }
        let all = allowedAll.remove(token) != nil
        switch answer {
        case true?: return (.allowed, all)
        case false?: return (.denied, false)
        case nil: return (.timedOut, false)
        }
    }

    /// The banner that says the wait is about to end, `remindAfter` from now.
    private static func remind(_ step: String, token: UUID) async {
        let reminder = UNMutableNotificationContent()
        reminder.title = String(localized: "还在等你回答")
        reminder.body = step + "\n" + String(localized: "30 秒后就不再等了，这一步不会执行。")
        reminder.categoryIdentifier = category
        reminder.sound = .default
        reminder.userInfo = [tokenKey: token.uuidString]
        reminder.interruptionLevel = .timeSensitive
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminderIdentifier(token), content: reminder,
                                                          trigger: UNTimeIntervalNotificationTrigger(timeInterval: remindAfter, repeats: false)))
    }

    /// `allowed` nil: nobody answered in time. `all`: 「这一轮都允许」.
    func answer(_ token: UUID, allowed: Bool?, all: Bool = false) {
        if question?.id == token { question = nil }
        if all, allowed == true, waiting[token] != nil { allowedAll.insert(token) }
        TaskActivity.shared.answered(token)
        // Timed out or cancelled while iOS was asking: take its sheet away.
        checking.removeValue(forKey: token)?.invalidate()
        let banners = [Self.identifier(token), Self.reminderIdentifier(token)]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: banners)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: banners)
        waiting.removeValue(forKey: token)?.resume.resume(returning: allowed)
    }

    /// 允许 in Pallas Agent: a step that needs the device owner runs only after Face ID or the passcode.
    func allow(_ question: Question) {
        guard question.owner else { return answer(question.id, allowed: true) }
        // Hidden while iOS asks; a failed or cancelled check does not allow the step.
        if self.question?.id == question.id { self.question = nil }
        let context = LAContext()
        checking[question.id] = context
        Task {
            let allowed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: question.step)) ?? false
            guard checking.removeValue(forKey: question.id) != nil else { return }
            answer(question.id, allowed: allowed)
        }
    }

    /// The turn lost the phone while it waited: the step is not allowed.
    func cancel(_ owner: UUID) {
        for (token, entry) in waiting where entry.owner == owner { answer(token, allowed: false) }
    }

    /// A notification's buttons. Tapping the banner opens Pallas Agent, which stops the turn anyway
    /// (phone control stops on `willEnterForeground`), so its question is already answered "no" by then.
    func respond(token raw: String?, action: String) {
        guard let raw, let token = UUID(uuidString: raw) else { return }
        answer(token, allowed: action == Self.allowAction)
    }

    /// The Live Activity's buttons.
    func respond(token raw: String, allowed: Bool) {
        guard let token = UUID(uuidString: raw), waiting[token] != nil else { return }
        answer(token, allowed: allowed)
    }

    nonisolated static func token(in info: [AnyHashable: Any]) -> String? { info[tokenKey] as? String }

    private static func identifier(_ token: UUID) -> String { "phone-confirm-" + token.uuidString }
    private static func reminderIdentifier(_ token: UUID) -> String { identifier(token) + "-again" }

    /// How long a question waits, as the in-app question says it.
    static var waitNote: String { String(localized: "2 分钟内没有回答，这一步就不执行。") }

    /// True when 关键步骤先问我 is chosen but iOS will not show the banner that asks: the same test `ask` makes,
    /// so quiet (provisional) delivery and a never-answered prompt count too, and the person hears it before a task, not in the middle.
    static func cannotAsk() async -> Bool {
        guard asks else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status != .authorized && status != .ephemeral
    }

    // MARK: - App names

    /// Names of apps people know, by bundle identifier in lower case. iOS gives an app no way to look up another app's name.
    nonisolated private static func knownApp(_ id: String) -> String? {
        switch id {
        case "com.apple.mobilenotes": String(localized: "备忘录")
        case "com.apple.preferences": String(localized: "设置")
        case "com.apple.calculator": String(localized: "计算器")
        case "com.apple.mobilesafari": String(localized: "Safari")
        case "com.apple.mobilesms": String(localized: "信息")
        case "com.apple.mobilemail": String(localized: "邮件")
        case "com.apple.mobilecal": String(localized: "日历")
        case "com.apple.reminders": String(localized: "提醒事项")
        case "com.apple.camera": String(localized: "相机")
        case "com.apple.mobileslideshow": String(localized: "照片")
        case "com.apple.maps": String(localized: "地图")
        case "com.apple.mobiletimer": String(localized: "时钟")
        case "com.apple.weather": String(localized: "天气")
        case "com.apple.music": String(localized: "音乐")
        case "com.apple.appstore": String(localized: "App Store")
        case "com.apple.mobilephone": String(localized: "电话")
        case "com.apple.mobileaddressbook": String(localized: "通讯录")
        case "com.apple.documentsapp": String(localized: "文件")
        case "com.apple.shortcuts": String(localized: "快捷指令")
        case "com.apple.health": String(localized: "健康")
        case "com.apple.passbook": String(localized: "钱包")
        case "com.tencent.xin": String(localized: "微信")
        case "com.tencent.mqq": String(localized: "QQ")
        case "com.alipay.iphoneclient": String(localized: "支付宝")
        case "com.taobao.taobao4iphone": String(localized: "淘宝")
        case "com.ss.iphone.ugc.aweme": String(localized: "抖音")
        case "com.xingin.discover": String(localized: "小红书")
        case "com.sina.weibo": String(localized: "微博")
        case "com.meituan.imeituan": String(localized: "美团")
        case "com.360buy.jdmobile": String(localized: "京东")
        case "com.autonavi.amap": String(localized: "高德地图")
        case "com.xunmeng.pinduoduo": String(localized: "拼多多")
        case "com.laiwang.dingtalk": String(localized: "钉钉")
        default: nil
        }
    }

    /// What to call the app an `open` names: the name itself, a known app's name, or nil for an identifier nobody would recognise.
    nonisolated static func appName(_ app: String) -> String? {
        guard app.contains(".") else { return app }
        return knownApp(app.lowercased())
    }
}

/// Shows a key-step question while Pallas Agent is in front.
struct PhoneConfirmationPrompt: ViewModifier {
    @ObservedObject private var confirmation = PhoneConfirmation.shared

    func body(content: Content) -> some View {
        // Only the buttons answer; the question clears itself when answered or timed out.
        content.alert("要继续这一步吗？", isPresented: Binding(get: { confirmation.question != nil }, set: { _ in }),
                      presenting: confirmation.question) { question in
            Button("允许") { confirmation.allow(question) }
            if question.all { Button("这一轮都允许") { confirmation.answer(question.id, allowed: true, all: true) } }
            Button("不允许", role: .cancel) { confirmation.answer(question.id, allowed: false) }
        } message: { question in
            Text(verbatim: question.step + "\n" + PhoneConfirmation.waitNote)
        }
    }
}
