// 聊天里的运行时动效：输入中指示、思考图形、状态点、展开、流式出现、思考胶囊、工具行和
// 逐字显现。

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Motion {
    static let stdCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0), endControlPoint: UnitPoint(x: 0, y: 1))
    static func std(_ duration: Double) -> Animation { .timingCurve(0.2, 0, 0, 1, duration: duration) }
    /// 进场：快出慢停。
    static func enter(_ duration: Double) -> Animation { .timingCurve(0.05, 0.7, 0.1, 1, duration: duration) }
    /// 刚发出的气泡从输入框升起。
    static let riseSpring = Animation.spring(duration: 0.42, bounce: 0.18)
    /// 弹出（回到底部按钮、角标）。
    static let popSpring = Animation.spring(duration: 0.38, bounce: 0.2)
    /// 滑块、键位落位。
    static let thumbSpring = Animation.spring(duration: 0.32, bounce: 0.15)
}

extension AnyTransition {
    /// 展开揭示：高度由布局动画撑开，内容在后 70% 淡入；收起时在前 70% 淡出。
    static func reveal(_ duration: Double = Motion.collapse) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: duration * 0.7).delay(duration * 0.3)),
                    removal: .opacity.animation(.easeIn(duration: duration * 0.7)))
    }

    /// 键位换图：新图从 0.4 倍弹到原大并淡入。
    static var keySwap: AnyTransition { .scale(scale: 0.4).combined(with: .opacity) }
    /// 发送键离开：纸飞机朝右上飞走并淡出。
    static var sendAway: AnyTransition {
        .asymmetric(insertion: .keySwap, removal: .offset(x: 16, y: -16).combined(with: .opacity))
    }
}

/// 进行中的工具：一段 108° 的细弧，1.1 秒转一圈。
struct QuietArc: View {
    var size: CGFloat = 14

    var body: some View {
        TimelineView(.animation(paused: Motion.reduced)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle().trim(from: 0, to: 0.3)
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .padding(0.8)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 一笔一笔画出来的对勾（280ms，easeOutCubic）。
struct DrawnCheck: View {
    var size: CGFloat = 14
    @State private var drawn: CGFloat = 0

    var body: some View {
        CheckShape().trim(from: 0, to: drawn)
            .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 2 / 24), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .onAppear {
                if Motion.reduced { drawn = 1 } else { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.28)) { drawn = 1 } }
            }
            .accessibilityHidden(true)
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.53))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.74))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.3))
            return path
        }
    }
}

/// 呼吸：不透明度在 1 和 `low` 之间往返，每个方向 `half` 秒（标准缓动）。
struct Breathing: ViewModifier {
    var active: Bool
    var low: Double = 0.35
    var half: Double = 1.2

    func body(content: Content) -> some View {
        if active && !Motion.reduced {
            TimelineView(.animation(minimumInterval: PerformanceSettings.shared.frameInterval(1 / 30))) { context in
                let phase = (context.date.timeIntervalSinceReferenceDate / half).truncatingRemainder(dividingBy: 2)
                let x = phase < 1 ? phase : 2 - phase
                content.opacity(1 - (1 - low) * Motion.stdCurve.value(at: x))
            }
        } else {
            content
        }
    }
}

extension View {
    func breathing(_ active: Bool, low: Double = 0.35, half: Double = 1.2) -> some View {
        modifier(Breathing(active: active, low: low, half: half))
    }
}

/// 等第一个字时的三个点：一个 1.2 秒的循环，三点相位各差 1/3。
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: PerformanceSettings.shared.frameInterval(1 / 60), paused: Motion.reduced)) { context in
            let t = Motion.reduced ? 0.25 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = 0.5 + 0.5 * sin(2 * .pi * (t + Double(i) / 3))
                    let scale = 0.55 + 0.45 * wave
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .scaleEffect(scale).opacity(0.35 + 0.65 * scale)
                }
            }
        }
        .frame(minHeight: StreamRow.minHeight)
        .accessibilityLabel("正在回复")
    }
}

/// 「思考中」上一道亮光：开始思考 0.6 秒后第一次，之后每 4 秒扫一次，每次 1 秒。
struct SweepLabel: View {
    let text: String
    let active: Bool
    @State private var start = Date()

    var body: some View {
        if active && !Motion.reduced {
            TimelineView(.animation(minimumInterval: PerformanceSettings.shared.frameInterval(1 / 60))) { context in
                let t = context.date.timeIntervalSince(start) - 0.6
                let cycle = t >= 0 ? t.truncatingRemainder(dividingBy: 4) : 4
                let s = cycle < 1 ? -1 + 2 * cycle : -1.0
                Text(text).foregroundStyle(LinearGradient(colors: [ChatColors.secondary, ChatColors.ink, ChatColors.secondary],
                                                          startPoint: UnitPoint(x: s, y: 0.5), endPoint: UnitPoint(x: s + 1, y: 0.5)))
            }
        } else {
            Text(text).foregroundStyle(ChatColors.secondary)
        }
    }
}

/// 第一次出现时：淡入并从下方 8 点升到位（240ms）；用户刚发的气泡从 36 点下、0.94 倍
/// 弹簧升起（420ms，回弹 0.18）。只在创建时决定播不播，之后重算不再打断。
/// 不在前台时不播：后台建出来的行直接显示，回到前台时还没显示的行也立刻显示，不会停在透明。
struct StreamEntrance: ViewModifier {
    let rise: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var shown: Bool

    init(play: Bool, rise: Bool = false) {
        self.rise = rise
        #if os(macOS)
        let active = NSApp?.isActive == true
        #else
        let active = UIApplication.shared.applicationState == .active
        #endif
        _shown = State(initialValue: !play || Motion.reduced || !active)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || !rise ? 1 : 0.94, anchor: .bottomTrailing)
            .offset(y: shown ? 0 : rise ? 36 : 8)
            .onAppear {
                guard !shown else { return }
                if scenePhase != .active {
                    UITrace.note("entrance skipped: scene \(scenePhase)")
                    shown = true; return
                }
                withAnimation(rise ? Motion.riseSpring : Motion.std(Motion.standard)) { shown = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && !shown {
                    UITrace.note("entrance still hidden on return: shown now")
                    shown = true
                }
            }
            .task {
                // Watchdog: a row that has not appeared 2 s after it was made is shown and reported.
                try? await Task.sleep(for: .seconds(2))
                if !shown {
                    UITrace.note("entrance stuck 2 s: onAppear never ran, scene \(scenePhase); shown now")
                    shown = true
                }
            }
    }
}

/// 哪些行是这次打开对话之后才来的：只有这些行播进场动画，滚回来重建时也不再播。
final class EntranceLedger {
    private var baseline: Set<String>?
    private var played: Set<String> = []
    private var session: String??

    /// 第一次看到的行是已有历史；还没送达的提问除外（新对话的第一条也要升起）。换了对话重新算。
    /// True when this call set a new baseline (the conversation was opened or reloaded).
    @discardableResult
    func prime(_ ids: [String], pending: Set<String>, session: String? = nil) -> Bool {
        if self.session != .some(session) {
            self.session = .some(session)
            baseline = nil
            played = []
        }
        guard baseline == nil, !ids.isEmpty else { return false }
        baseline = Set(ids).subtracting(pending)
        return true
    }

    /// 末尾几行里新来的一行，第一次问到时返回 true。
    func play(_ id: String, index: Int, count: Int) -> Bool {
        guard let baseline, !baseline.contains(id), index >= count - 4, !played.contains(id) else { return false }
        played.insert(id)
        return true
    }
}

/// 打开时淡入（切换对话 160ms）。
struct FadeInOnAppear: ViewModifier {
    var duration = Motion.quick
    @State private var shown = Motion.reduced

    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Motion.std(duration)) { shown = true } }
    }
}

/// 换了对话：整页 160ms 淡入。
struct FadeInOnChange<Key: Equatable>: ViewModifier {
    let key: Key
    @State private var opacity = 1.0

    func body(content: Content) -> some View {
        content.opacity(opacity)
            .onChange(of: key) { _, _ in
                guard !Motion.reduced else { return }
                opacity = 0
                Task { @MainActor in withAnimation(Motion.std(Motion.quick)) { opacity = 1 } }
            }
    }
}

/// 首次出现逐项错开：每项晚 30ms，前 8 项才错开；升 20 点用弹簧，透明度 240ms。
struct StaggeredRise: ViewModifier {
    let index: Int
    @State private var shown = Motion.reduced

    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 20)
            .onAppear {
                guard !shown else { return }
                let delay = Double(min(index, 8)) * 0.03
                withAnimation(Motion.riseSpring.delay(delay)) { shown = true }
            }
    }
}

// MARK: - 流式回复的逐字显现

/// 逐字显现的节奏：基础每秒 120 字，积压时加速到 0.4 秒内追上；流结束后剩下的 0.15 秒内落完。
final class RevealPacer {
    private(set) var shown: Double
    private var last: Date?
    private(set) var lastGrowth = Date()
    private var known = 0
    /// 当前速度（字/秒），决定淡入尾巴有多长。
    private(set) var rate: Double = 120

    init(startAt count: Int) {
        shown = Double(count)
        known = count
    }

    func advance(to target: Int, live: Bool, now: Date) -> Int {
        if target != known {
            if target > known { lastGrowth = now }
            known = target
        }
        let dt = last.map { min(0.1, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        let backlog = Double(target) - shown
        guard backlog > 0 else { shown = Double(target); return target }
        rate = max(120, backlog / (live ? 0.4 : 0.15))
        shown = min(Double(target), shown + rate * dt)
        return Int(shown)
    }

    func caughtUp(_ target: Int) -> Bool { Int(shown) >= target }

    func revealAll(_ count: Int) {
        shown = Double(count)
        known = count
        last = nil
        lastGrowth = Date()
    }
}

private struct CloseSearchKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    /// 搜索页由外壳以淡入页打开时，关闭它的方法。
    var closeSearch: (() -> Void)? {
        get { self[CloseSearchKey.self] }
        set { self[CloseSearchKey.self] = newValue }
    }
}

/// 流式回复：按节奏逐字显现、末尾一段渐显；没有新字超过 0.9 秒时左下角亮一个呼吸的小点。
/// 只有在本次显示时从空开始的回复才逐字显现，已经写好的直接整段显示。
struct StreamingAnswer: View {
    let text: String
    let font: Font
    let live: Bool
    /// 显现推进时（跟随到底部用）。
    var onReveal: (() -> Void)?
    @State private var pacer: RevealPacer

    init(text: String, font: Font, live: Bool, onReveal: (() -> Void)? = nil) {
        self.text = text
        self.font = font
        self.live = live
        self.onReveal = onReveal
        // 刚开头的回复从头显现；滚回来重建时已经写了一大段，直接显示。
        _pacer = State(initialValue: RevealPacer(startAt: live && !Motion.reduced && text.count < 64 ? 0 : text.count))
    }

    var body: some View {
        let target = text.count
        let settled = !live && pacer.caughtUp(target)
        if settled {
            ChatAnswer(text: text, font: font)
        } else if Motion.reduced {
            ChatAnswer(text: text, font: font)
                .onChange(of: target, initial: true) { _, count in
                    pacer.revealAll(count)
                    onReveal?()
                }
        } else {
            TimelineView(.animation(minimumInterval: PerformanceSettings.shared.frameInterval(1 / 60))) { context in
                let shown = pacer.advance(to: target, live: live, now: context.date)
                let stalled = live && shown >= target && context.date.timeIntervalSince(pacer.lastGrowth) > 0.9
                ChatAnswer(text: String(text.prefix(shown)), font: font)
                    .environment(\.answerTailFade, shown < target || live ? min(Double(shown), pacer.rate * 0.24) : 0)
                    .overlay(alignment: .bottomLeading) {
                        Circle().fill(ChatColors.muted.opacity(0.7)).frame(width: 5, height: 5)
                            .padding(.leading, 1).offset(y: 11)
                            .opacity(stalled ? 1 : 0)
                            .breathing(stalled, low: 0.25, half: 1.2)
                            .animation(Motion.std(Motion.standard), value: stalled)
                            .accessibilityHidden(true)
                    }
                    .background { Color.clear.onChange(of: shown) { _, _ in onReveal?() } }
            }
        }
    }
}

/// 打开一段对话时直接停在最新一行（iOS 18 起；只管初始位置，内容少时仍从顶上排）。
struct StartAtEnd: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}
