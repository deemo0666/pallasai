import Foundation
import notify
import WidgetKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import ActivityKit

/// Pallas Agent's Live Activity for a phone-control turn. Compiled into the app and into PallasWidgets.
struct PallasTaskAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// What the turn is doing now.
        var step: String
        /// 0...1. A turn has no known length, so this creeps forward with each command.
        var progress: Double
        /// The key step waiting for the person's answer, and the `PhoneConfirmation` token that answers it.
        var asking: String?
        var token: String?

        init(step: String, progress: Double, asking: String? = nil, token: String? = nil) {
            (self.step, self.progress, self.asking, self.token) = (step, progress, asking, token)
        }
    }

    /// The app being operated.
    var title: String
    /// `PallasShared.activityHeader` in the app's language, which can differ from the extension's.
    /// The runner looks for this exact line.
    var header: String

    init(title: String, header: String) {
        (self.title, self.header) = (title, header)
    }
}
#endif

/// The latest task, as the widgets show it. The app writes it into the shared App Group.
struct PallasRecentTask: Codable, Equatable {
    enum Status: String, Codable {
        case running, asking, done, stopped
        var live: Bool { self == .running || self == .asking }
    }
    var title: String
    var status: Status
    var step: String
    var updated: Date
    #if os(macOS)
    struct MacDetails: Codable, Equatable {
        var scope: String
        var session: String
        var processID: Int32?
        var stopTicket: UUID?
    }
    var mac: MacDetails?
    #endif

    init(title: String, status: Status, step: String, updated: Date) {
        (self.title, self.status, self.step, self.updated) = (title, status, step, updated)
    }

    #if os(macOS)
    mutating func markStopped() {
        status = .stopped
        step = ""
        mac?.processID = nil
        mac?.stopTicket = nil
    }
    #endif
}

enum PallasShared {
    /// The app's bundle identifier, also from inside the extension (`<app>.widgets`).
    static var appBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(".widgets") ? String(id.dropLast(".widgets".count)) : id
    }
    static let recentKind = "PallasRecentTask"

    #if os(macOS)
    static var group: String? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "PallasSharedGroup") as? String,
              let separator = name.firstIndex(of: "."), name.distance(from: name.startIndex, to: separator) == 10 else {
            return nil
        }
        return name
    }

    static let askURL = URL(string: "dshlocal-mac://ask")!
    static let openURL = URL(string: "dshlocal-mac://recent")!

    /// A widget's timeline can outlive the app that was running the turn.
    static func displayRecent() -> PallasRecentTask? {
        guard var task = readRecent() else { return nil }
        if task.status.live,
           task.mac?.processID.flatMap({ NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }) != appBundleID {
            task.markStopped()
        }
        return task
    }

    private static var stopFile: URL? { sharedContainer?.appending(path: "stop-recent-task") }

    static func requestMacStop(_ ticket: UUID) throws {
        guard displayRecent()?.mac?.stopTicket == ticket, let file = stopFile else { return }
        try Data(ticket.uuidString.utf8).write(to: file, options: .atomic)
        PallasSignal.post(PallasSignal.stopMacRecent)
    }

    static func pendingMacStop() -> UUID? {
        guard let file = stopFile, let value = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }
    #else
    /// Shared by the app and PallasWidgets only; the runner has its own `.screen` group.
    static var group: String { "group." + appBundleID + ".shared" }

    /// Links the app answers in `ClientShell.onOpenURL`.
    static let askURL = URL(string: "dshlocal://ask")!
    static let voiceURL = URL(string: "dshlocal://voice")!
    static let openURL = URL(string: "dshlocal://open")!
    /// 操作复盘 from the Action button: starts a screen recording, or ends the one running.
    static let recordURL = URL(string: "dshlocal://record")!

    /// The header line of the Live Activity. The runner finds this line at the top of the screen and shrinks
    /// the expanded Live Activity; iOS's own Live Activity for the background task
    /// shows the same line.
    static var activityHeader: String { String(localized: "Pallas Agent 手机操控") }
    #endif

    private static var sharedContainer: URL? {
        #if os(macOS)
        guard let group else { return nil }
        #endif
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    private static var recentFile: URL? { sharedContainer?.appending(path: "recent-task.json") }

    static func readRecent() -> PallasRecentTask? {
        guard let file = recentFile, let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PallasRecentTask.self, from: data)
    }

    /// `reload` asks the widgets to redraw; iOS limits how often that may happen while the app is in the background.
    @discardableResult
    static func writeRecent(_ task: PallasRecentTask, reload: Bool = true) -> Bool {
        guard let file = recentFile else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(task),
              (try? data.write(to: file, options: .atomic)) != nil else { return false }
        if reload { WidgetCenter.shared.reloadTimelines(ofKind: recentKind) }
        return true
    }
}


/// A control's intent may run in its extension while the app runs a turn in the background.
enum PallasSignal {
    static func name(_ signal: String) -> String {
        #if os(macOS)
        return (PallasShared.group ?? PallasShared.appBundleID) + ".signal." + signal
        #else
        return PallasShared.appBundleID + ".signal." + signal
        #endif
    }
    #if os(macOS)
    static let stopMacRecent = "mac.stop-recent"
    #else
    static let stopPhone = "phone.stop"
    #endif

    static func post(_ signal: String) { notify_post(name(signal)) }

    /// Calls `handler` on the main queue each time `signal` is posted, until `cancel`.
    static func observe(_ signal: String, _ handler: @escaping () -> Void) -> Int32 {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        notify_register_dispatch(name(signal), &token, .main) { _ in handler() }
        return token
    }

    static func cancel(_ token: Int32) {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }
}
