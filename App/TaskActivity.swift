import ActivityKit
import Foundation

/// The Live Activity of a phone-control turn, and the latest task the widgets show.
/// Phone control starts it when a turn takes the phone, moves it on with each command and ends it
/// when the phone is handed back; `PhoneConfirmation` puts its question and buttons on it.
@MainActor
final class TaskActivity {
    static let shared = TaskActivity()

    /// When our Live Activity shows. iOS shows its own for the background task in any case.
    /// `always`: for the whole turn. `asking`: only while a key step waits. `off`: never.
    enum Mode: String { case always, asking, off }
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: "taskActivityMode") ?? "") ?? .always }

    private var activity: Activity<PallasTaskAttributes>?
    private var title = ""
    private var state = PallasTaskAttributes.ContentState(step: "", progress: 0)
    private var steps = 0
    private var status = PallasRecentTask.Status.done
    /// The buttons' intents: run in the app they call these, run in PallasWidgets they signal.
    func install() {
        PallasIntentHandlers.answer = { allowed in self.answerShown(allowed: allowed) }
    }

    /// A turn took the phone. Pallas Agent is in front, which iOS requires to start a Live Activity.
    func begin(app: String?) {
        dismiss()
        title = app.flatMap(PhoneConfirmation.appName) ?? String(localized: "手机操控")
        steps = 0
        state = .init(step: String(localized: "开始操作"), progress: 0.02)
        record(.running)
        if Self.mode == .always { request() }
    }


    /// Puts the question and its buttons on the Live Activity. False when none can carry it,
    /// and the question goes out as a notification instead.
    func ask(_ step: String, token: UUID) async -> Bool {
        guard Self.mode != .off else { return false }
        state.asking = step
        state.token = token.uuidString
        record(.asking)
        if activity == nil { request() }
        guard let activity, activity.activityState == .active else {
            state.asking = nil
            state.token = nil
            return false
        }
        await activity.update(ActivityContent(state: state, staleDate: nil),
                              alertConfiguration: AlertConfiguration(title: "要继续这一步吗？", body: LocalizedStringResource(stringLiteral: step), sound: .default))
        return true
    }

    /// 允许 / 不允许 on the Live Activity: the question it shows now.
    private func answerShown(allowed: Bool) {
        guard let token = state.token else { return }
        PhoneConfirmation.shared.respond(token: token, allowed: allowed)
    }

    /// The question for `token` was answered, timed out or dropped.
    func answered(_ token: UUID) {
        guard state.token == token.uuidString else { return }
        state.asking = nil
        state.token = nil
        if Self.mode == .asking { dismiss() } else { push() }
        record(.running)
    }

    /// The turn handed the phone back.
    func end(stopped: Bool) {
        state.asking = nil
        state.token = nil
        state.progress = 1
        if stopped { state.step = String(localized: "已停止") }
        record(stopped ? .stopped : .done)
        guard let activity else { return }
        self.activity = nil
        let final = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(final, dismissalPolicy: .after(.now + 5 * 60)) }
    }

    private func request() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: PallasTaskAttributes(title: title, header: PallasShared.activityHeader),
                                            content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        } catch {
            Log.engine.notice("live activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func push() {
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    /// Ends what is left of an earlier turn, and any activity a previous launch left behind.
    private func dismiss() {
        let left = Activity<PallasTaskAttributes>.activities
        activity = nil
        for old in left { Task { await old.end(nil, dismissalPolicy: .immediate) } }
    }

    private func record(_ status: PallasRecentTask.Status) {
        let changed = status != self.status
        self.status = status
        PallasShared.writeRecent(PallasRecentTask(title: title, status: status, step: state.asking ?? state.step, updated: .now),
                                 reload: changed)
    }

}

/// `dshlocal://ask` and `dshlocal://voice` from the widgets and controls: the chat's composer takes them.
@MainActor
final class WidgetLink: ObservableObject {
    static let shared = WidgetLink()
    enum Request { case type, speak }
    @Published var request: Request?

    /// True when `url` is one of these links.
    func take(_ url: URL) -> Bool {
        // The bundle identifier is a scheme of its own too: another Pallas build on the phone also claims dshlocal.
        guard url.scheme == "dshlocal" || url.scheme == Bundle.main.bundleIdentifier?.lowercased() else { return false }
        switch url.host {
        case "ask": request = .type
        case "voice": request = .speak
        case "open": break
        default: return false
        }
        return true
    }
}
