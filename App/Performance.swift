// 设置 › 通用 › 性能：档位、刷新率、玻璃模糊和界面动效，存为本机设置。
// Motion（`Motion.reduced`、面板的显示刷新）、ChatMotion（逐字显现、扫光）和毛玻璃材质读取这里；
// 自动档在设备发热或低电量模式时临时换成轻量；系统「减弱动态效果」始终优先。

import Combine
import Observation
import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PerformanceMode: String, CaseIterable, Identifiable {
    case auto, full, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: String(localized: "自动")
        case .full: String(localized: "完整")
        case .light: String(localized: "轻量")
        }
    }
}

enum RefreshPreference: String, CaseIterable, Identifiable {
    case auto, max, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: String(localized: "自动")
        case .max: String(localized: "最高")
        case .system: String(localized: "系统")
        }
    }
}

/// The saved choices and what they come to now. Read inside a view's body, a property makes that
/// view follow its changes (Observation).
@Observable
final class PerformanceSettings {
    static let shared = PerformanceSettings()
    static let modeKey = "performanceMode", refreshKey = "performanceRefresh"
    static let blurKey = "performanceBlur", animationsKey = "performanceAnimations"

    var mode: PerformanceMode { didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) } }
    var refresh: RefreshPreference { didSet { defaults.set(refresh.rawValue, forKey: Self.refreshKey) } }
    /// Nil follows the mode.
    var blurChoice: Bool? { didSet { store(blurChoice, Self.blurKey) } }
    var animationsChoice: Bool? { didSet { store(animationsChoice, Self.animationsKey) } }

    /// Kept up to date from the system's notifications while the app is running.
    var thermalHot: Bool
    var lowPower: Bool
    var systemReduceMotion: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var systemUpdates: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(PerformanceMode.init(rawValue:)) ?? .auto
        refresh = defaults.string(forKey: Self.refreshKey).flatMap(RefreshPreference.init(rawValue:)) ?? .auto
        blurChoice = defaults.object(forKey: Self.blurKey) as? Bool
        animationsChoice = defaults.object(forKey: Self.animationsKey) as? Bool
        thermalHot = Self.hot(ProcessInfo.processInfo.thermalState)
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        systemReduceMotion = Self.systemPrefersReducedMotion
    }

    static var systemPrefersReducedMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    @MainActor func observeSystem() {
        guard systemUpdates == nil else { return }
        #if os(macOS)
        let motion = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        #else
        let motion = NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)
        #endif
        let thermal = NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
        let power = NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
        systemUpdates = Publishers.Merge3(thermal, power, motion).receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshSystemState()
        }
        refreshSystemState()
    }

    @MainActor private func refreshSystemState() {
        let hot = Self.hot(ProcessInfo.processInfo.thermalState)
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        let still = Self.systemPrefersReducedMotion
        if thermalHot != hot { thermalHot = hot }
        if lowPower != low { lowPower = low }
        if systemReduceMotion != still { systemReduceMotion = still }
    }

    private func store(_ value: Bool?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    static func hot(_ state: ProcessInfo.ThermalState) -> Bool { state == .serious || state == .critical }

    /// 自动档 is lightweight for now (warm device or Low Power Mode).
    var cooling: Bool { mode == .auto && (thermalHot || lowPower) }
    var lightweight: Bool { mode == .light || cooling }
    var blur: Bool { blurChoice ?? !lightweight }
    var animations: Bool { animationsChoice ?? !lightweight }
    /// Motion goes straight to its end: the system setting always wins over the app's.
    var reduceMotion: Bool { systemReduceMotion || !animations }

    /// The shortest step of the chat's timelines (逐字显现, 扫光).
    func frameInterval(_ base: Double) -> Double {
        if lightweight { return max(base, 1.0 / 30) }
        return refresh == .max ? min(base, 1.0 / 120) : base
    }

    /// What the panel animations ask the display for.
    var panelFrameRange: CAFrameRateRange {
        // 系统 asks for the usual 60 Hz: a link that declares nothing got only 13–25 frames a
        // second for the drawer on wode16.
        if refresh == .system || lightweight { return CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) }
        return CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    }
}

struct PerformanceRuntime: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    private let settings = PerformanceSettings.shared

    func body(content: Content) -> some View {
        let still = settings.reduceMotion
        content
            .transaction {
                if still {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
            }
            .task { settings.observeSystem() }
            #if os(macOS)
            .background {
                if settings.refresh == .max && scenePhase == .active { MacDisplayRefresh() }
            }
            #endif
    }
}

#if os(iOS)
/// 最高: while the app is in front, a display link asks for 120 Hz on every frame.
@MainActor
final class RefreshRateHold {
    static let shared = RefreshRateHold()
    private var link: CADisplayLink?
    private let target = Target()

    private final class Target: NSObject {
        @objc func step(_ link: CADisplayLink) {}
    }

    func apply(hold: Bool) {
        if hold, link == nil {
            let link = CADisplayLink(target: target, selector: #selector(Target.step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !hold {
            link?.invalidate()
            link = nil
        }
    }
}

/// Counts the frames a display link asking for 120 Hz gets in one second: what the screen gives
/// the app right now (60 under Low Power Mode or 「限制帧速率」).
@MainActor
final class RefreshProbe: NSObject {
    private var link: CADisplayLink?
    private var count = 0
    private var done: ((Int) -> Void)?

    func measure() async -> Int {
        await withCheckedContinuation { continuation in
            done = { continuation.resume(returning: $0) }
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.link?.invalidate()
                self.link = nil
                self.done?(self.count)
                self.done = nil
            }
        }
    }

    @objc private func step(_ link: CADisplayLink) { count += 1 }
}
#endif

struct PerformanceSettingsPage: View {
    @Bindable private var settings = PerformanceSettings.shared
    @State private var measured: Int?
    #if os(macOS)
    @State private var maximum: Int?
    #endif

    var body: some View {
        List {
            Section {
                ForEach(PerformanceMode.allCases) { mode in
                    Button { settings.mode = mode } label: {
                        HStack(spacing: 12) {
                            Text(mode.title).foregroundStyle(ChatColors.ink)
                            Spacer(minLength: 8)
                            Image(systemName: settings.mode == mode ? "largecircle.fill.circle" : "circle")
                                .font(.title3).foregroundStyle(settings.mode == mode ? Color.accentColor : ChatColors.muted.opacity(0.6))
                        }.frame(minHeight: 54).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(settings.mode == mode ? [.isSelected, .isButton] : .isButton)
                        .accessibilityIdentifier("performanceMode-" + mode.rawValue)
                }
            } footer: { if let modeFooter { Text(modeFooter) } }.listRowBackground(ChatColors.chip)

            Section {
                HStack {
                    Text("刷新率")
                    Spacer()
                    SettingsSegmented(options: RefreshPreference.allCases.map { ($0, $0.title) }, selection: $settings.refresh).fixedSize()
                }.accessibilityElement(children: .contain).accessibilityIdentifier("performanceRefresh")
                screenRate
            }.listRowBackground(ChatColors.chip)

            Section {
                Toggle("玻璃模糊", isOn: Binding(get: { settings.blur }, set: { settings.blurChoice = $0 }))
                    .accessibilityIdentifier("performanceBlur")
                Toggle(isOn: Binding(get: { settings.animations }, set: { settings.animationsChoice = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("界面动效")
                        if settings.systemReduceMotion {
                            Text("系统已打开「减弱动态效果」，动效保持关闭").font(.caption).foregroundStyle(SettingsStyle.warning)
                        }
                    }
                }.accessibilityIdentifier("performanceAnimations")
                if settings.blurChoice != nil || settings.animationsChoice != nil {
                    Button("效果跟随档位") { settings.blurChoice = nil; settings.animationsChoice = nil }
                        .accessibilityIdentifier("performanceFollowMode")
                }
            } header: { Text("界面效果") }.listRowBackground(ChatColors.chip)
        }
        .groupedList()
        .settingsPage(String(localized: "性能"))
        .inlineNavigationTitle()
    }

    private var screenRate: some View {
        #if os(macOS)
        let maximum = self.maximum
        #else
        let maximum: Int? = UIScreen.main.maximumFramesPerSecond
        #endif
        return LabeledContent("屏幕") {
            if let maximum {
                Text(String(localized: "最高 \(maximum) Hz") + (measured.map { String(localized: " · 请求最高时实测 \($0) Hz") } ?? ""))
            }
        }
        .accessibilityIdentifier("performanceScreenRate")
        #if os(macOS)
        .background {
            MacDisplayRefresh { maximum, measured in
                self.maximum = maximum
                self.measured = measured
            }
            .id(settings.lowPower)
        }
        #else
        .task { measured = await RefreshProbe().measure() }
        #endif
    }

    private var modeFooter: String? {
        if settings.mode == .auto && settings.thermalHot { return String(localized: "设备正在发热，已临时减少效果，降温后恢复。") }
        if settings.mode == .auto && settings.lowPower { return String(localized: "低电量模式已打开，已临时减少效果。") }
        return nil
    }
}
