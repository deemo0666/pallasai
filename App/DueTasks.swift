import BackgroundTasks
import UIKit
import UserNotifications

/// 自动化任务 run on a timer inside the on-phone engine, and iOS suspends the app, timer included,
/// soon after it leaves the screen: on a locked phone a task ran only when Pallas Agent was next
/// opened, and nothing said so (7.5 minutes late on wode16, 2026-11-16). So every run time of an
/// active task also has a system notification, which iOS delivers whatever state the app is in;
/// tapping it opens the app, where the engine runs what is due. When iOS grants a background
/// refresh, due tasks run without anyone opening the app.
@MainActor
final class DueTasks {
    static let shared = DueTasks()
    nonisolated static let kind = "task-due"
    private static let prefix = "task-due:"
    private static let waitPrefix = "task-wait:"
    /// iOS keeps 64 pending notifications per app; the rest are left to phone control and DS Bot.
    private static let limit = 40
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "dsh") + ".tasks.due" }
    private var registered = false
    private var expired = false
    private var pass: Task<Void, Never>?
    /// Tasks whose run stopped to wait for the person; their turn stays open until Pallas Agent is in front.
    private var waitingTasks = Set<String>()

    /// One run time of one task.
    private struct Run {
        let task: ScheduleItem
        let at: Date
        var identifier: String { DueTasks.prefix + task.id + "@" + String(Int(at.timeIntervalSince1970)) }
    }

    /// At launch, before the app finishes launching, as BGTaskScheduler requires.
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { DueTasks.shared.woke(task) }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                EmbeddedEngine.shared.frontChanged(false)
                let hold = UIApplication.shared.beginBackgroundTask(withName: "Task notifications")
                DueTasks.shared.resync { if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) } }
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                EmbeddedEngine.shared.frontChanged(true)
                DueTasks.shared.waitingTasks.removeAll()
                DueTasks.shared.resync()
            }
        }
    }

    /// The engine finished its turns while the app was off screen: a task may just have run.
    func turnsEnded() {
        guard UIApplication.shared.applicationState != .active else { return }
        resync()
    }

    func resync(then done: (() -> Void)? = nil) {
        let earlier = pass
        pass = Task {
            await earlier?.value
            await sync()
            done?()
        }
    }

    // MARK: - The engine's task store

    /// Every task the on-phone engine keeps, in the shape `schedule/catalog` answers with. Read from
    /// its store so that this works before the engine has started and while no conversation is connected.
    static func stored() -> [ScheduleItem] {
        guard EmbeddedEngine.enabled,
              let home = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return [] }
        return (try? ScheduleItem.stored(in: home.appending(path: "DSH"))) ?? []
    }

    private static func overdue(_ tasks: [ScheduleItem], now: Date = .now) -> [ScheduleItem] {
        tasks.filter { $0.active && ($0.scheduledAt ?? .distantFuture) <= now }
    }

    /// The engine keeps only the next run. The simple repeats get the two after it as well, so a
    /// phone left alone for a day still says something the second morning.
    private static func runs(_ task: ScheduleItem, now: Date) -> [Run] {
        task.reminderDates(now: now).filter { $0 > now }.map { Run(task: task, at: $0) }
    }

    // MARK: - Notifications

    private func sync() async {
        let center = UNUserNotificationCenter.current()
        let tasks = Self.stored()
        let now = Date()
        let here = UIApplication.shared.applicationState == .active
        // With the person here the engine is catching up; otherwise only what has run since goes.
        let shown = await center.deliveredNotifications().map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: shown.filter {
            $0.hasPrefix(Self.prefix) ? here || Self.hasRun($0, tasks) : $0.hasPrefix(Self.waitPrefix) && here
        })
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        submitRefresh(tasks, now: now)
        guard UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool != false else { return }
        let runs = tasks.flatMap { Self.runs($0, now: now) }.sorted { $0.at < $1.at }.prefix(Self.limit)
        guard !runs.isEmpty else { return }
        if here { await NotificationOffer.shared.offer() } else { await NotificationOffer.shared.quietIfUnasked() }
        guard [.authorized, .provisional, .ephemeral].contains(await center.notificationSettings().authorizationStatus) else { return }
        for run in runs {
            let content = UNMutableNotificationContent()
            content.title = run.task.title
            content.body = String(localized: "到点了，点这里运行")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "tasks"
            content.userInfo = Self.info(run.task.sessionId)
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: run.at)
            try? await center.add(UNNotificationRequest(identifier: run.identifier, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }

    private static func info(_ session: String?) -> [String: String] {
        var info = ["kind": kind]
        if let session { info["session"] = session }
        return info
    }

    /// Whether the run a shown notification stands for has happened (or its task is gone or ended).
    private static func hasRun(_ identifier: String, _ tasks: [ScheduleItem]) -> Bool {
        let parts = identifier.dropFirst(prefix.count).split(separator: "@")
        guard parts.count == 2, let seconds = TimeInterval(parts[1]), let task = tasks.first(where: { $0.id == parts[0] }) else { return true }
        if let done = task.lastScheduledDelivery, done.timeIntervalSince1970 >= seconds - 1 { return true }
        return !task.active
    }

    /// After a run nobody was here for: what happened, in place of 「到点了」.
    private func report(_ task: ScheduleItem, finished: Bool) async {
        let center = UNUserNotificationCenter.current()
        guard UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool != false,
              [.authorized, .provisional, .ephemeral].contains(await center.notificationSettings().authorizationStatus) else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = finished ? String(localized: "已自动运行") : String(localized: "回复已暂停，打开 Pallas Agent 继续")
        content.sound = .default
        content.threadIdentifier = "tasks"
        let session = ((task.raw["lastDelivery"] as? Object)?["targetSessionId"] as? String) ?? task.sessionId
        content.userInfo = Self.info(session)
        try? await center.add(UNNotificationRequest(identifier: "task-ran:" + task.id, content: content, trigger: nil))
    }

    /// A task's run in the background reached for the phone and now waits for Pallas Agent to be
    /// in front (the engine says so): the person has to open it.
    func waiting(task id: String, session: String?) {
        waitingTasks.insert(id)
        Task {
            let center = UNUserNotificationCenter.current()
            guard UIApplication.shared.applicationState != .active,
                  UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool != false,
                  [.authorized, .provisional, .ephemeral].contains(await center.notificationSettings().authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = Self.stored().first { $0.id == id }?.title ?? String(localized: "自动化任务")
            content.body = String(localized: "要操作手机，打开 Pallas Agent 继续")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "tasks"
            content.userInfo = Self.info(session)
            try? await center.add(UNNotificationRequest(identifier: Self.waitPrefix + id, content: content, trigger: nil))
        }
    }

    // MARK: - Background refresh

    /// A task may need the screen, which no background run has. With phone control on, the engine
    /// holds a task off screen unless its completed runs so far never touched the phone, and keeps
    /// what it learned in this file (Embedded/engine/schedule-hold.cjs). A background run is only
    /// worth asking iOS for when a task would actually go.
    private static func screenFree() -> Set<String> {
        guard let home = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let data = try? Data(contentsOf: home.appendingPathComponent("DSH/ios-task-screen.json")),
              let runs = try? JSONSerialization.jsonObject(with: data) as? [String: [Bool]] else { return [] }
        return Set(runs.filter { !$0.value.isEmpty && !$0.value.contains(true) }.keys)
    }

    private static func runsOffScreen(_ tasks: [ScheduleItem]) -> [ScheduleItem] {
        guard EmbeddedEngine.enabled else { return [] }
        let free = screenFree()
        return tasks.filter { free.contains($0.id) }
    }

    private func submitRefresh(_ tasks: [ScheduleItem], now: Date) {
        guard registered else { return }
        guard let next = Self.runsOffScreen(tasks).filter(\.active).compactMap(\.scheduledAt).min() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = max(next, now)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { Log.engine.notice("task refresh not submitted: \(error.localizedDescription, privacy: .public)") }
    }

    /// iOS woke the app: the engine's timer delivers what is due as soon as it runs again, so this
    /// only has to keep the app awake until those turns are over.
    private func woke(_ task: BGTask) {
        expired = false
        task.expirationHandler = { Task { @MainActor in DueTasks.shared.expired = true } }
        Task {
            let due = Self.runsOffScreen(Self.overdue(Self.stored()))
            var finished = due.isEmpty
            if !due.isEmpty, (try? await EmbeddedEngine.shared.start()) != nil {
                Log.engine.notice("task refresh: \(due.count, privacy: .public) due")
                var quiet = 0
                // A run that waits for the person keeps its turn open; nothing more happens until they come.
                while !expired, quiet < 4, waitingTasks.isEmpty {
                    try? await Task.sleep(for: .milliseconds(500))
                    let waiting = Self.overdue(Self.stored()).contains { item in due.contains { $0.id == item.id } }
                    quiet = waiting || TurnKeepAlive.shared.active > 0 ? 0 : quiet + 1
                }
                finished = quiet >= 4
                let now = Self.stored()
                for item in due {
                    guard let after = now.first(where: { $0.id == item.id }), let at = item.scheduledAt,
                          let done = after.lastScheduledDelivery, done >= at.addingTimeInterval(-1), !waitingTasks.contains(item.id) else { continue }
                    await report(after, finished: finished)
                }
            }
            await sync()
            Log.engine.notice("task refresh ended, finished \(finished, privacy: .public)")
            task.setTaskCompleted(success: finished)
        }
    }
}
