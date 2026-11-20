import AppIntents
import Foundation

// The Live Activity's and the controls' buttons, compiled into the app and into PallasWidgets. iOS runs a
// `LiveActivityIntent` in the app's process without bringing it to the front, so the phone-control turn
// (which stops on `willEnterForeground`) goes on. They take no parameters: a parameter on the Live
// Activity's button did not reach the app (chronod "decode: missing data", wode16, iOS 27); the app
// knows which question its Live Activity shows.

/// Set by the app at launch; nil inside PallasWidgets.
@MainActor
enum PallasIntentHandlers {
    static var answer: ((Bool) -> Void)?
    static var stopPhone: (() -> Void)?
    static var recordScreen: (() async -> Void)?
}

#if os(iOS)
/// Pallas 录屏 on the Action button or in Control Center (常开旁听). While a recording runs, a press only
/// marks where a question starts and, the next press, where it ends; nothing comes to the front until
/// the answer. With no recording, it brings Pallas forward for the system picker, which needs the
/// person's tap.
struct RecordScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Pallas 录屏"
    static let isDiscoverable = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        if #available(iOS 26.0, *) { try await continueInForeground(alwaysConfirm: false) }
        // Run in the app, do the pending step now; run in PallasWidgets, the app does it on coming forward.
        await PallasIntentHandlers.recordScreen?()
        return .result()
    }
}
#endif

/// 允许 on the Live Activity.
struct AllowStepIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "允许这一步"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PallasIntentHandlers.answer?(true)
        return .result()
    }
}

/// 不允许 on the Live Activity.
struct DenyStepIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "不允许这一步"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PallasIntentHandlers.answer?(false)
        return .result()
    }
}

/// 停下手机操控, from Control Center, the Action button, the Lock Screen or the medium widget.
struct StopPhoneActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停下手机操控"
    // Only for the Live Activity and widget buttons; the App Intents one is what Shortcuts lists.
    static let isDiscoverable = false
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // Run in PallasWidgets (a control), the running app hears it by Darwin notification.
        if let stop = PallasIntentHandlers.stopPhone { stop() } else { PallasSignal.post(PallasSignal.stopPhone) }
        return .result()
    }
}
