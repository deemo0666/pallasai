// 动效 token（时长、曲线、弹簧）与左右面板（侧栏与快捷面板）的跟手拖动。

import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 动效原则：安静、短、跟手。反馈类不超过 160ms，结构类 240–340ms；
/// 系统打开「减弱动态效果」时一律直接到位。
enum Motion {
    static let quick = 0.16
    static let standard = 0.24
    static let collapse = 0.28
    static let emphasized = 0.34
    static let slow = 0.48

    /// 滑行：抽屉、胶囊位移这类跟手之后落位的运动，iOS 式长尾减速。
    static let glide = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.32, y: 0.72), endControlPoint: UnitPoint(x: 0, y: 1))
    static func glide(_ duration: Double) -> Animation { .timingCurve(0.32, 0.72, 0, 1, duration: duration) }
    /// 标准缓动（Material 3 standard）。
    static let std = Animation.timingCurve(0.2, 0, 0, 1, duration: standard)
    /// 思考块、工具行这类大块的折叠展开。
    static let collapseCurve = Animation.timingCurve(0.645, 0.045, 0.355, 1, duration: collapse)
    /// 按压落位。
    static let pressSpring = Animation.spring(duration: 0.15, bounce: 0)
    /// 松手回弹：按压回到原大小时越过一点点。
    static let releaseSpring = Animation.spring(duration: 0.32, bounce: 0.45)
    /// 尺寸、位置变化的落位。
    static let layoutSpring = Animation.spring(duration: 0.35, bounce: 0)
    /// 甩出去的面板：只有这里带一点回弹。
    static let fling = Spring(duration: 0.5, bounce: 0.15)
    /// 松手时快过它（点每秒）才算甩。
    static let minFlingVelocity: CGFloat = 50

    /// 系统「减弱动态效果」或「设置 › 性能」关了动效。
    static var reduced: Bool { PerformanceSettings.systemPrefersReducedMotion || PerformanceSettings.shared.reduceMotion }
}

#if os(iOS)
/// 侧栏（左）和快捷面板（右）的打开进度，0 为关、1 为全开。
///
/// 手指拖动时直接改进度，松手或点按时由显示刷新逐帧推进，所以动画可以随时被
/// 下一根手指接住，从当时的位置继续跟手，不会先跳到终点。每帧只有读进度的小视图
/// 重算；外壳只读 `drawerShown` / `quickShown`，它们只在 0 和大于 0 之间切换时变化。
@MainActor @Observable
final class SidePanels {
    enum Side: Hashable { case drawer, quick }

    private(set) var drawer: CGFloat = 0
    private(set) var quick: CGFloat = 0
    private(set) var drawerShown = false
    private(set) var quickShown = false

    @ObservationIgnored private var runs: [Side: Run] = [:]
    @ObservationIgnored private var link: CADisplayLink?

    private struct Run {
        let start: CFTimeInterval
        /// 已过的秒数 → 进度，以及是否结束。
        let step: (Double) -> (CGFloat, Bool)
    }

    func value(_ side: Side) -> CGFloat { side == .drawer ? drawer : quick }

    /// 按钮、遮罩：从当前位置滑到全开（340ms）或全关（240ms）。
    func open(_ side: Side) {
        Self.dismissKeyboard()
        slide(side, to: 1, duration: Motion.emphasized)
    }

    func close(_ side: Side) { slide(side, to: 0, duration: Motion.standard) }

    /// 不要动画：新页面已经盖住，或从外部链接跳转。
    func snap(_ side: Side, open: Bool) {
        stop(side)
        put(side, open ? 1 : 0)
    }

    func dragBegan(_ side: Side) {
        stop(side)
        Self.dismissKeyboard()
    }

    /// `distance`：朝打开方向移动的点数。
    func dragMoved(_ side: Side, by distance: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        put(side, value(side) + distance / width)
    }

    /// `velocity`：朝打开方向每秒多少点。甩了就按方向落位并接住手指的速度，否则看过没过一半。
    func dragEnded(_ side: Side, velocity: CGFloat, width: CGFloat) {
        if abs(velocity) >= Motion.minFlingVelocity, width > 0 {
            fling(side, to: velocity > 0 ? 1 : 0, velocity: velocity / width)
        } else if value(side) >= 0.5 {
            slide(side, to: 1, duration: Motion.emphasized)
        } else {
            slide(side, to: 0, duration: Motion.standard)
        }
    }

    private func put(_ side: Side, _ raw: CGFloat) {
        let next = min(max(raw, 0), 1)
        switch side {
        case .drawer:
            if drawer != next { drawer = next }
            if drawerShown != (next > 0) { drawerShown = next > 0 }
        case .quick:
            if quick != next { quick = next }
            if quickShown != (next > 0) { quickShown = next > 0 }
        }
    }

    private func slide(_ side: Side, to target: CGFloat, duration: Double) {
        stop(side)
        let from = value(side)
        guard from != target else { return }
        guard !Motion.reduced else { put(side, target); return }
        run(side) { elapsed in
            let progress = min(elapsed / duration, 1)
            return (from + (target - from) * CGFloat(Motion.glide.value(at: progress)), progress >= 1)
        }
    }

    /// `velocity`：进度每秒（手指速度除以面板宽度）。
    private func fling(_ side: Side, to target: CGFloat, velocity: CGFloat) {
        stop(side)
        guard !Motion.reduced else { put(side, target); return }
        let from = value(side)
        let distance = Double(target - from)
        let speed = Double(velocity)
        run(side) { elapsed in
            let position = from + CGFloat(Motion.fling.value(target: distance, initialVelocity: speed, time: elapsed))
            // 到了终点就停：回弹只塑造到达的那一下，面板不会越出屏幕边。
            let arrived = target > from ? position >= target : position <= target
            return arrived || elapsed > 2 ? (target, true) : (position, false)
        }
    }

    private func run(_ side: Side, _ step: @escaping (Double) -> (CGFloat, Bool)) {
        runs[side] = Run(start: CACurrentMediaTime(), step: step)
        guard link == nil else { return }
        let ticker = FrameTicker { [weak self] link in
            MainActor.assumeIsolated { self?.tick(link.targetTimestamp) }
        }
        let link = CADisplayLink(target: ticker, selector: #selector(FrameTicker.step(_:)))
        link.preferredFrameRateRange = PerformanceSettings.shared.panelFrameRange
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func tick(_ now: CFTimeInterval) {
        for (side, run) in runs {
            let (value, done) = run.step(max(0, now - run.start))
            put(side, value)
            if done { runs[side] = nil }
        }
        if runs.isEmpty { stopLink() }
    }

    private func stop(_ side: Side) {
        runs[side] = nil
        if runs.isEmpty { stopLink() }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private final class FrameTicker: NSObject {
    private let action: (CADisplayLink) -> Void
    init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
    @objc func step(_ link: CADisplayLink) { action(link) }
}

/// 面板按进度从屏外滑入：多走 24 点，圆角和阴影也一起藏到屏外。
struct PanelSlide: ViewModifier {
    let panels: SidePanels
    let side: SidePanels.Side
    let width: CGFloat

    func body(content: Content) -> some View {
        let hidden = (1 - panels.value(side)) * (width + 24)
        content.offset(x: side == .drawer ? -hidden : hidden)
    }
}

/// 面板拉出时，下面的聊天顺着同一方向挪开一点（面板位移的 14%）。只平移，不缩放。
struct SideParallax: ViewModifier {
    let panels: SidePanels
    let drawerWidth: CGFloat
    let quickWidth: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: Motion.reduced ? 0 : 0.14 * (panels.drawer * drawerWidth - panels.quick * quickWidth))
    }
}

/// 面板后面的遮罩：深浅随进度变化，点一下关上。
struct PanelScrim: View {
    let panels: SidePanels
    let side: SidePanels.Side
    let label: String
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color.black.opacity((scheme == .dark ? 0.48 : 0.32) * panels.value(side))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

/// 聊天上的左右滑：右滑拉出侧栏，左滑拉出快捷面板；已打开时两个方向都归这块面板，
/// 同一根手指可以来回拉，松手按速度或位置落位。
///
/// 手势挂在窗口上，只在没有弹层盖着时接触点。竖向为主的移动交给列表滚动；
/// 手指下的横向滚动内容（代码块、表格）还能朝这个方向滚时让给它；开关、滑块、
/// 分段控件和正在编辑的文字不抢。一旦开始，这根手指不再交给别的手势。
struct SidePanelSwipe: UIViewRepresentable {
    /// 按住说话时手指往左滑去 ✏️、✕，不能拉出面板。
    @MainActor static var paused = false
    let panels: SidePanels
    /// 聊天在最上面（没有推入的页面）。
    let active: Bool
    /// 右滑能拉出侧栏。
    let drawer: Bool
    /// 左滑能拉出快捷面板。
    let quick: Bool
    let drawerWidth: CGFloat
    let quickWidth: CGFloat

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Surface, context: Context) { view.config = self }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        var config: SidePanelSwipe?
        private var owner: SidePanels.Side?
        private var applied: CGFloat = 0
        /// 最近一次移动的时刻。手指停住再抬起时，系统报的仍是停住前的速度；
        /// 100ms 内没动过就当速度为零。
        private var lastMove: CFTimeInterval = 0
        private weak var touchView: UIView?
        /// 手指落下的位置。系统的平移量从识别成立那一刻才开始算，前面那段判定距离
        /// 会丢掉，面板就落后手指一截；按落点算，面板一开始就贴着手指。
        private var start: CGPoint = .zero
        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.delegate = self
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            pan.view?.removeGestureRecognizer(pan)
            window?.addGestureRecognizer(pan)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let config, config.active, window?.rootViewController?.presentedViewController == nil,
                  bounds.contains(touch.location(in: self)) else { return false }
            let panels = config.panels
            guard config.drawer || config.quick || panels.drawerShown || panels.quickShown else { return false }
            touchView = touch.view
            start = touch.location(in: self)
            return true
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            owner = nil
            guard let config, !SidePanelSwipe.paused else { return false }
            let point = pan.location(in: self)
            var move = CGPoint(x: point.x - start.x, y: point.y - start.y)
            if move == .zero { move = pan.velocity(in: self) }
            guard abs(move.x) > abs(move.y), !touchIsOnControl else { return false }
            let panels = config.panels
            if panels.drawerShown { owner = .drawer }
            else if panels.quickShown { owner = .quick }
            else if move.x > 0, config.drawer, !contentScrolls(right: true) { owner = .drawer }
            else if move.x < 0, config.quick, !contentScrolls(right: false) { owner = .quick }
            return owner != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

        private var touchIsOnControl: Bool {
            var view = touchView
            while let current = view {
                if current is UIControl { return true }
                if let text = current as? UITextView, text.isFirstResponder { return true }
                view = current.superview
            }
            return false
        }

        /// 手指下有能朝这个方向滚动的横向内容：手指向右时内容还能往回滚，向左时还能往后滚。
        private func contentScrolls(right: Bool) -> Bool {
            var view = touchView
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
                    let inset = scroll.adjustedContentInset
                    let offset = scroll.contentOffset.x + inset.left
                    let end = scroll.contentSize.width + inset.left + inset.right - scroll.bounds.width
                    if right ? offset > 0.5 : offset < end - 0.5 { return true }
                }
                view = current.superview
            }
            return false
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            guard let config, let owner else { return }
            let width = owner == .drawer ? config.drawerWidth : config.quickWidth
            let sign: CGFloat = owner == .drawer ? 1 : -1
            let x = pan.location(in: self).x - start.x
            switch pan.state {
            case .began:
                config.panels.dragBegan(owner)
                config.panels.dragMoved(owner, by: sign * x, width: width)
                applied = x
                lastMove = CACurrentMediaTime()
            case .changed:
                if x != applied { lastMove = CACurrentMediaTime() }
                config.panels.dragMoved(owner, by: sign * (x - applied), width: width)
                applied = x
            case .ended:
                let held = CACurrentMediaTime() - lastMove > 0.1
                config.panels.dragEnded(owner, velocity: held ? 0 : sign * pan.velocity(in: self).x, width: width)
                self.owner = nil
            case .cancelled, .failed:
                // 系统收走了手指（比如边缘手势）：没有「甩」，只看拉到了哪儿。
                config.panels.dragEnded(owner, velocity: 0, width: width)
                self.owner = nil
            default:
                break
            }
        }
    }
}

/// 卡片：从它打开的页面由它展开，返回时缩回它（iOS 18 起；更早的系统是普通推入）。
struct ZoomSource: ViewModifier {
    let id: AnyHashable
    let namespace: Namespace.ID
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.matchedTransitionSource(id: id, in: namespace) { $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
        } else {
            content
        }
    }
}

/// 推入的页面：`enabled` 时从同 id 的卡片展开。
struct ZoomDestination: ViewModifier {
    let id: AnyHashable
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *), enabled, !Motion.reduced {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
#endif

/// 按压反馈：按住缩到 0.97，松手弹回并略微越过原大小。滚动列表里系统会先等一下
/// 再显示按下，划过去不会闪。减弱动态效果时不缩放。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !Motion.reduced ? scale : 1)
            .animation(configuration.isPressed ? Motion.pressSpring : Motion.releaseSpring, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

#if os(iOS)
/// 滑进来的面板的底：移动时是不透明的面（移动中的模糊每帧都要重采样背后），停稳后
/// 120ms 内透出毛玻璃。没有自定义壁纸时用；有壁纸时侧栏照旧铺壁纸。
struct SlidingGlass<S: Shape>: View {
    let panels: SidePanels
    let side: SidePanels.Side
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        let atRest = panels.value(side) >= 1 && !solid && PerformanceSettings.shared.blur
        // Leaving rest is instant: a translucent panel moving over a moving chat smears it.
        // Only arriving eases the glass in, the blur appearing behind a still-opaque fill.
        ZStack {
            shape.fill(.regularMaterial).opacity(atRest ? 1 : 0)
            shape.fill(ChatColors.page.opacity(atRest ? (scheme == .dark ? 0.86 : 0.82) : 1))
        }
        .animation(atRest ? .easeOut(duration: 0.12) : nil, value: atRest)
        .allowsHitTesting(false)
    }
}
#endif
