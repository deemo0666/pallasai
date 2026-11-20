import BackgroundTasks
import UIKit
import UserNotifications

/// Keeps the on-phone engine running when the person leaves Pallas Agent mid-reply. iOS suspends an
/// app about 30 seconds after it leaves the screen, and the engine runs inside the app, so a turn
/// used to stop until the app came back (an hour, once). Leaving with a turn open asks iOS for a
/// continued-processing task, which shows the reply's progress in the system's own banner; if iOS
/// ends it anyway, a notification says the reply is paused. A reply that finishes in the background
/// says so too.
@MainActor
final class TurnKeepAlive {
    static let shared = TurnKeepAlive()

    /// Sessions with an open turn, as the engine reports them.
    private(set) var active = 0
    private var registered = false
    private var task: BGTask?
    private var submitted = false
    private var bridge = UIBackgroundTaskIdentifier.invalid
    private var heartbeat: Timer?
    private var leftAt: Date?
    private static let units: Int64 = 10_000
    /// Long turns are fine; a turn the engine never closed must not hold the phone forever.
    private static let limit: TimeInterval = 30 * 60
    nonisolated static let doneKind = "turn-done"
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "dsh") + ".turn" }
    /// The newest reply's text, set by the shell that holds the conversation; its first sentence
    /// becomes the body of the "replied" notification.
    var replyPreview: (() -> String?)?
    /// The conversation on screen, set with `replyPreview`; tapping "办好了" opens it again.
    var replySession: (() -> String?)?
    private var leftSession: String?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TurnKeepAlive.shared.leaving() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TurnKeepAlive.shared.back() }
        }
    }

    /// At launch, before the app finishes launching, as BGTaskScheduler requires.
    func register() {
        guard #available(iOS 26, *), !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { TurnKeepAlive.shared.started(task) }
        }
    }

    func update(_ count: Int) {
        let was = active
        active = max(0, count)
        if active > 0, was == 0 { offerNotificationsIfLong() }
        guard active == 0, was > 0 else { return }
        if UIApplication.shared.applicationState != .active, leftAt != nil {
            let first = ReplyNotificationPreview.firstSentence(replyPreview?())
            // The Apple model's one line comes a moment after the turn ends; without it, the reply's first sentence.
            let ended = Date().addingTimeInterval(-1)
            let hold = UIApplication.shared.beginBackgroundTask(withName: "Reply summary")
            let session = leftSession
            Task {
                let line = AppleModel.available ? await AppleModelSummaries.shared.line(after: ended, wait: 2.5) : nil
                notify(String(localized: "办好了"), body: line ?? first, id: "turn-done", session: session)
                try? await Task.sleep(for: .milliseconds(300))
                if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) }
            }
        }
        end(success: true)
    }

    private func leaving() {
        guard active > 0 else { return }
        Task { await NotificationOffer.shared.quietIfUnasked() }
        guard task == nil, !submitted, bridge == .invalid else { return }
        // So does pairing: its banner carries the pairing code, and one banner is enough.
        guard !LanServices.shared.advertising else { return }
        leftAt = Date()
        leftSession = replySession?()
        bridge = UIApplication.shared.beginBackgroundTask(withName: "Reply") { [weak self] in
            MainActor.assumeIsolated { self?.expired() }
        }
        guard #available(iOS 26, *), registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: String(localized: "Pallas Agent 正在回复"),
                                                       subtitle: String(localized: "回到 Pallas Agent 查看进度"))
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request); submitted = true }
        catch { Log.engine.notice("reply keep-alive not submitted: \(error.localizedDescription, privacy: .public)") }
    }

    private func started(_ task: BGTask) {
        guard #available(iOS 26, *), let task = task as? BGContinuedProcessingTask, active > 0, submitted else {
            task.setTaskCompleted(success: false)
            return
        }
        self.task = task
        task.progress.totalUnitCount = Self.units
        task.progress.completedUnitCount = 1
        task.expirationHandler = { Task { @MainActor in TurnKeepAlive.shared.expired() } }
        // iOS marks a continued task that reports no progress for about 38 seconds as stalled.
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { TurnKeepAlive.shared.tick() }
        }
        if bridge != .invalid { UIApplication.shared.endBackgroundTask(bridge); bridge = .invalid }
        Log.engine.notice("reply keep-alive running")
    }

    private func tick() {
        guard #available(iOS 26, *), let task = task as? BGContinuedProcessingTask else { return }
        if let leftAt, Date().timeIntervalSince(leftAt) > Self.limit { expired(); return }
        task.progress.completedUnitCount = min(Self.units - 1, task.progress.completedUnitCount + 1)
    }

    private func expired() {
        guard leftAt != nil else { return }
        Log.engine.notice("reply keep-alive ended by iOS, turns open \(self.active, privacy: .public)")
        if active > 0 { notify(String(localized: "回复已暂停，打开 Pallas Agent 继续"), id: "turn-paused") }
        end(success: false)
    }

    private func back() {
        guard leftAt != nil || task != nil || bridge != .invalid else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["turn-paused"])
        end(success: true)
    }

    private func end(success: Bool) {
        heartbeat?.invalidate(); heartbeat = nil
        if #available(iOS 26, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Self.units
        }
        task?.setTaskCompleted(success: success)
        task = nil
        submitted = false
        leftAt = nil
        leftSession = nil
        if bridge != .invalid { UIApplication.shared.endBackgroundTask(bridge); bridge = .invalid }
    }

    /// A reply still running a few seconds in, on screen, is the first good moment to offer
    /// notifications: the card asks, then iOS.
    private func offerNotificationsIfLong() {
        guard UIApplication.shared.applicationState == .active else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard active > 0, UIApplication.shared.applicationState == .active else { return }
            await NotificationOffer.shared.offer()
        }
    }

    /// Only when the person allowed notifications.
    private func notify(_ title: String, body: String? = nil, id: String, session: String? = nil) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard [.authorized, .provisional, .ephemeral].contains(await center.notificationSettings().authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let body { content.body = body }
            if let session {
                content.userInfo = ["kind": Self.doneKind, "session": session]
                content.sound = .default
            }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
