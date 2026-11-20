import SwiftUI

/// What settings do for the whole app, put on the window's root: the daily update check, and the
/// performance choices from the shared runtime.
struct SettingsRuntime: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    private var performance: PerformanceSettings { PerformanceSettings.shared }

    func body(content: Content) -> some View {
        let hold = performance.refresh == .max && scenePhase == .active
        content
            .modifier(PerformanceRuntime())
            .task(id: hold) { RefreshRateHold.shared.apply(hold: hold) }
            .task {
                #if DEBUG
                // `-DSHDiagnosticsTestError <text>`: an error line through the real log, for checking what 诊断 masks.
                if let text = UserDefaults.standard.string(forKey: "DSHDiagnosticsTestError") {
                    Log.connection.error("test error: \(text, privacy: .public)")
                }
                #endif
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await UpdateChecker.shared.checkDailyIfDue()
            }
    }
}
