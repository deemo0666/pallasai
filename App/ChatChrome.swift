import SwiftUI

extension View {
    func chatCard() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func chatInput() -> some View {
        self.textFieldStyle(.plain).padding(.horizontal, 13).frame(minHeight: 48)
            .background(ChatColors.muted.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatColors.line, lineWidth: 0.8))
    }

    func chatCapsule() -> some View { glass(Capsule()) }

    /// `.borderedProminent` in the ink primary colour, with a label that reads on it: pages set
    /// `ChatColors.ink` as their foreground, which would otherwise draw the label in the fill's own brightness.
    func prominentButton() -> some View { modifier(ProminentButton()) }

    /// 浮在内容上的玻璃（顶栏胶囊、输入框）。
    func glass<S: InsettableShape>(_ shape: S) -> some View { modifier(GlassChrome(shape: shape)) }
}

private struct ProminentButton: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).tint(ChatColors.primary)
            .foregroundStyle(enabled ? ChatColors.onPrimary : Color.secondary)
    }
}

/// 玻璃：模糊背后的内容 → 半透明填充 → 发丝描边和顶边高光 → 只画在形状外面的投影
/// （画在里面会透过玻璃把中间染灰）。系统「降低透明度」时换成近乎不透明的填充。
struct GlassChrome<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var systemSolid
    /// 「设置 › 性能」关了玻璃模糊时也一样。
    private var solid: Bool { systemSolid || !PerformanceSettings.shared.blur }

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background {
                ZStack {
                    if !solid { shape.fill(.ultraThinMaterial) }
                    shape.fill(dark ? Color(red: 0.13, green: 0.14, blue: 0.16).opacity(solid ? 0.97 : 0.78)
                                    : Color.white.opacity(solid ? 0.97 : 0.82))
                }
            }
            .overlay {
                // Dark glass needs an edge to stand off the page; light glass has its shadow.
                if dark { shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5).allowsHitTesting(false) }
            }
            .background {
                shape.fill(Color.black).shadow(color: .black.opacity(dark ? 0.3 : 0.06), radius: 10, y: 3)
                .mask { Rectangle().padding(-48).overlay { shape.blendMode(.destinationOut) }.compositingGroup() }
                .allowsHitTesting(false)
            }
    }
}

struct ChatIcon: View {
    let label: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .regular))
                .frame(width: 44, height: 44).chatCapsule()
        }.buttonStyle(.pressable).foregroundStyle(ChatColors.ink).accessibilityLabel(label)
    }
}

struct ChatHeading<Trailing: View>: View {
    let title: String
    let subtitle: String
    let online: Bool
    let menu: () -> Void
    let detail: () -> Void
    let detailLabel: String
    /// Dot colour for states other than connected (生成中, 等你确认, 连接已断开 …).
    var tone: Color? = nil
    /// 生成中、正在连接、正在停止：状态点呼吸。
    var busy = false
    @ViewBuilder var trailing: () -> Trailing

    static var connectedTone: Color { Color(red: 0.48, green: 0.76, blue: 0.64) }


    @Environment(\.sidebarDocked) private var docked

    var body: some View {
        HStack(spacing: 7) {
            if let docked {
                ChatIcon(label: docked ? String(localized: "收起侧栏") : String(localized: "显示侧栏"), symbol: "sidebar.left", action: menu)
            } else {
                ChatIcon(label: String(localized: "对话列表"), symbol: "line.3.horizontal", action: menu)
            }
            // Like DSH, the title pill is as wide as its text; long titles truncate.
            Button(action: detail) {
                // The pill's width follows its text (240ms) while the words crossfade; the dot breathes while busy.
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).contentTransition(.opacity)
                    HStack(spacing: 4) {
                        Circle().fill(tone ?? (online ? Self.connectedTone : ChatColors.muted)).frame(width: 6, height: 6)
                            .breathing(busy)
                        Text(subtitle).font(.caption2).foregroundStyle(ChatColors.muted).lineLimit(1).contentTransition(.opacity)
                    }
                }.padding(.horizontal, 16).frame(height: 44)
                .animation(Motion.std(Motion.standard), value: title)
                .animation(Motion.std(Motion.standard), value: subtitle)
                .chatCapsule()
            }.buttonStyle(.pressable).layoutPriority(1)
                .accessibilityLabel(detailLabel).accessibilityIdentifier("chatTitle").accessibilityValue(title + String(localized: "，") + subtitle)
            Spacer(minLength: 0)
            trailing()
        }.foregroundStyle(ChatColors.ink).padding(.horizontal, 16).padding(.vertical, 6)
    }
}

/// 输入框：聚焦时展开成两行（280ms），圆角 28 → 20；第二行放 ＋、模型胶囊和按键。
struct ComposerShell<Content: View, Footer: View>: View {
    var composing = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 6, content: content)
            if composing { HStack(spacing: 6, content: footer) }
        }
        .padding(5).glass(RoundedRectangle(cornerRadius: composing ? 20 : 28, style: .continuous)).padding(.horizontal, 12).padding(.bottom, 5)
        .animation(Motion.collapseCurve, value: composing)
    }
}

/// The context ring next to send: share of the model window in use, orange from 60%.
struct ContextRing: View {
    let fraction: Double
    var body: some View {
        let value = min(1, max(0, fraction))
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(ChatColors.muted.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: value)
                    .stroke(value >= 0.6 ? Color.orange : ChatColors.muted, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }.frame(width: 16, height: 16)
            Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted)
        }.frame(height: 36).padding(.horizontal, 4)
    }
}

struct ComposerIcon: View {
    let symbol: String
    var active = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 36, height: 36)
            .foregroundStyle(active ? ChatColors.onPrimary : ChatColors.ink)
            .background(active ? ChatColors.primary : Color.clear, in: Circle())
    }
}

struct FilterChips: View {
    @Binding var selection: RemoteSessionFilter
    var options = RemoteSessionFilter.allCases
    var unreadCount = 0
    var body: some View {
        HStack(spacing: 7) {
            ForEach(options, id: \.self) { value in
                Button { selection = value } label: {
                    HStack(spacing: 3) {
                        Text(value.rawValue.localized)
                        if value == .unread && unreadCount > 0 { Text("\(unreadCount)") }
                    }.font(.caption.weight(.semibold))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .foregroundStyle(value == selection ? ChatColors.onPrimary : ChatColors.muted)
                        .background(value == selection ? ChatColors.primary : ChatColors.segmentWell, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel(value.rawValue.localized)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

/// When a screen is wide enough for two columns (iPad in landscape, an unfolded phone), and how wide
/// the left one is: 320 on a big screen, half on a smaller one so the split falls on the fold.
/// Portrait iPads and phones keep one column.
enum SplitLayout {
    static func column(for size: CGSize, regular: Bool) -> CGFloat? {
        guard regular, size.width > size.height, size.width >= 700 else { return nil }
        return size.width < 1000 ? (size.width / 2).rounded() : 320
    }
}

/// Whether the conversation list sits beside the chat (nil: it slides over it, as on iPhone).
private struct SidebarDockedKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    /// nil on a phone; true while the docked list shows, false once it is folded away.
    var sidebarDocked: Bool? {
        get { self[SidebarDockedKey.self] }
        set { self[SidebarDockedKey.self] = newValue }
    }
}

/// One 全部功能 entry: a line icon on a 52 pt card-coloured square, the name under it.
struct FeatureTileLabel: View {
    let title: String
    let symbol: String
    var enabled = true

    var body: some View {
        VStack(spacing: 6) {
            LineGlyph(name: symbol, size: 24).foregroundStyle(ChatColors.ink)
                .frame(width: 52, height: 52)
                .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(title).font(.system(size: 12)).foregroundStyle(ChatColors.ink)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
        }.frame(maxWidth: .infinity).opacity(enabled ? 1 : 0.4).contentShape(Rectangle())
    }
}

/// The Pallas logo: a black-and-white cat head on a 22 × 14 pixel grid, drawn in body colour.
struct CatMark: Shape {
    private static let rows = [
        ".####............####.",
        "##..##..######..##..##",
        "##..##############..##",
        "######################",
        "######################",
        "####...########...####",
        "######...####...######",
        "#######..####..#######",
        "######################",
        "##...#####..#####...##",
        ".###..####..####..###.",
        ".##..####.##.####..##.",
        "..##################..",
        "....##############....",
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 22, rect.height / 14)
        let origin = CGPoint(x: rect.midX - 11 * scale, y: rect.midY - 7 * scale)
        var path = Path()
        for (y, row) in Self.rows.enumerated() {
            // One rect per run of pixels, so no hairline seams show between neighbours.
            var x = 0
            let pixels = Array(row)
            while x < pixels.count {
                guard pixels[x] == "#" else { x += 1; continue }
                var end = x
                while end < pixels.count, pixels[end] == "#" { end += 1 }
                path.addRect(CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale,
                                    width: CGFloat(end - x) * scale, height: scale * 1.02))
                x = end
            }
        }
        return path
    }
}

/// The new conversation's empty state: a faint cat head, the greeting for the hour,
/// one short line, then what fits the state: sign-in when there is no model, examples to tap and
/// the folder chip when ready, 「重试」 when the connection failed, nothing when only reopening helps.
struct ChatWelcome: View {
    let host: String
    let offline: Bool
    let chooseHost: () -> Void
    /// Still connecting (offline but on the way).
    var connecting = false
    /// Offline with a host to go back to: the one primary pill.
    var reconnect: (() -> Void)? = nil
    /// Online: the workspace chip opens the workspace switcher.
    var chooseWorkspace: (() -> Void)? = nil
    var needsAI = false
    /// The page where a model gets added by hand (own API key; a computer's model list).
    var configureAI: (() -> Void)? = nil
    /// The DeepSeek sign-in page, where this phone can sign in (本机).
    var signIn: (() -> Void)? = nil
    /// 用 ChatGPT 登录 (本机).
    var chatGPT: (() -> Void)? = nil
    /// Puts an example in the composer; it is not sent.
    var suggest: ((String) -> Void)? = nil
    /// The host is this phone itself: it starts, it does not connect.
    var onPhone = false
    /// Nothing here can bring it back: the app has to be reopened.
    var relaunch = false
    /// The last attempt went wrong (an error is showing), as opposed to never having been made.
    var failed = false

    /// One example per thing it can do: apps on the phone, files, the computer, a timed task.
    /// `label` is the chip; `text` is what goes into the composer.
    /// These show until (and unless) `StarterIdeas` has written a set for this moment.
    static var examples: [StarterIdeas.Example] {
        [.init(symbol: "calendar", label: String(localized: "明天下午三点加个会"), text: String(localized: "打开日历，帮我加一个明天下午三点的会")),
         .init(symbol: "folder", label: String(localized: "整理授权的文件夹"), text: String(localized: "整理我授权的文件夹，告诉我里面有什么")),
         .init(symbol: "alarm", label: String(localized: "每天八点提醒看天气"), text: String(localized: "每天早上八点提醒我看天气")),
         .init(symbol: "desktopcomputer", label: String(localized: "找电脑上最近下载的文件"), text: String(localized: "在我的电脑上找出最近下载的文件"))]
    }

    @ObservedObject private var ideas = StarterIdeas.shared
    private var shownExamples: [StarterIdeas.Example] { ideas.examples ?? Self.examples }

    static func greeting(at date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: String(localized: "早上好")
        case 11..<13: String(localized: "中午好")
        case 13..<18: String(localized: "下午好")
        case 18..<23: String(localized: "晚上好")
        default: String(localized: "夜深了")
        }
    }

    private var subtitle: String {
        if !offline {
            if !needsAI { return String(localized: "今天想做点什么？") }
            return configureAI != nil || signIn != nil ? String(localized: "接入模型后就能开始") : String(localized: "还没有可用的模型")
        }
        if relaunch { return String(localized: "请关掉 Pallas Agent 再重新打开") }
        if connecting { return onPhone ? String(localized: "正在启动…") : String(localized: "正在连接…") }
        if reconnect == nil || !failed { return String(localized: "未连接") }
        return onPhone ? String(localized: "没能启动") : String(localized: "没能连上")
    }

    /// The offline pill: try again where that can work, otherwise pick another device.
    private var offlineAction: String {
        if reconnect == nil { return String(localized: "切换设备") }
        return failed ? String(localized: "重试") : String(localized: "连接")
    }

    var body: some View {
        // Its spacers' minimums add up to about 345 pt. Above a tall keyboard (微信输入法 is
        // 348 pt) less is left, and a VStack that cannot shrink overflows both ends: the header
        // slides under the status bar and the composer's bottom row under the keyboard. Scroll then,
        // from the bottom.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.defaultScrollAnchor(.bottom)
                .scrollBounceBehavior(.basedOnSize).scrollDismissesKeyboard(.interactively)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            CatMark().fill(ChatColors.tertiary).frame(width: 55, height: 35).padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(Self.greeting()).font(.system(size: 32, weight: .semibold)).modifier(StaggeredRise(index: 0))
            Text(subtitle).font(.body).foregroundStyle(ChatColors.secondary).padding(.top, 6)
                .contentTransition(.opacity).modifier(StaggeredRise(index: 1))
            if offline && connecting {
                // Same height as the pill below, so nothing jumps when the connection settles.
                ConnectingDots().frame(minHeight: 40).padding(.top, 12)
                    .transition(.opacity).accessibilityHidden(true)
            } else if offline {
                // Reopening the app is the only way back: no button that would fail again.
                if !relaunch {
                    Button(action: reconnect ?? chooseHost) {
                        Text(offlineAction).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).frame(minHeight: 40)
                            .foregroundStyle(ChatColors.onPrimary).background(ChatColors.primary, in: Capsule())
                    }.buttonStyle(.pressable).padding(.top, 12).accessibilityIdentifier("emptyReconnect")
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            } else if needsAI {
                setup
            }
            if ready {
                // Things to ask sit right above the composer, where the thumb already is.
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: 6) {
                    if showsFolder, let chooseWorkspace { folderRow(chooseWorkspace).padding(.horizontal, 16) }
                    if suggest != nil { exampleList }
                }.frame(maxWidth: 600, alignment: .leading).padding(.bottom, 10)
            } else {
                Spacer(minLength: 40)
                Spacer(minLength: 0).frame(maxHeight: 60)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(ChatColors.ink)
        .animation(Motion.reduced ? nil : Motion.std(Motion.standard), value: subtitle)
        .animation(Motion.reduced ? nil : Motion.std(Motion.standard), value: offline)
    }

    /// No model yet: an OpenAI key first (the default service for new phones), a DeepSeek sign-in second.
    @ViewBuilder private var setup: some View {
        VStack(spacing: 6) {
            if let chatGPT {
                Button(action: chatGPT) {
                    Text("用 ChatGPT 登录").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).frame(minHeight: 40)
                        .foregroundStyle(ChatColors.onPrimary).background(ChatColors.primary, in: Capsule())
                }.buttonStyle(.pressable).accessibilityIdentifier("emptyChatGPT")
            }
            if let configureAI {
                Button(action: configureAI) {
                    if chatGPT == nil {
                        Text(signIn != nil ? "接入 OpenAI" : "管理模型").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).frame(minHeight: 40)
                            .foregroundStyle(ChatColors.onPrimary).background(ChatColors.primary, in: Capsule())
                    } else {
                        Text("使用自己的 API Key").font(.subheadline).foregroundStyle(ChatColors.muted)
                            .padding(.horizontal, 14).frame(minHeight: 40).contentShape(Rectangle())
                    }
                }.buttonStyle(.pressable).accessibilityIdentifier("emptyConfigureAI")
            }
            if let signIn {
                Button(action: signIn) {
                    Text("登录 DeepSeek 账号").font(.subheadline).foregroundStyle(ChatColors.muted)
                        .padding(.horizontal, 14).frame(minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.pressable).accessibilityIdentifier("emptySignIn")
            }
        }.padding(.top, 12)
    }

    /// Online with a model: the examples and the folder show.
    private var ready: Bool { !offline && !needsAI }

    /// On this phone the one folder is the app's own 「workspace」, which means nothing to its owner;
    /// any other folder (and every computer's) is worth naming.
    private var showsFolder: Bool { !host.isEmpty && !(onPhone && host == "workspace") }

    /// Which folder a new conversation works in; a tap switches.
    private func folderRow(_ choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(verbatim: host).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }.font(.footnote.weight(.medium)).foregroundStyle(ChatColors.secondary)
                .padding(.horizontal, 4).frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.pressable)
            .accessibilityLabel(String(localized: "文件夹：") + host).accessibilityHint("切换文件夹").accessibilityIdentifier("emptyWorkspace")
            .modifier(StaggeredRise(index: 2))
    }

    /// Things to ask for, one tap away from the composer: two rows of chips that scroll sideways
    /// when they do not fit (larger type, longer languages).
    private var exampleList: some View {
        let examples = shownExamples
        let half = (examples.count + 1) / 2
        return VStack(alignment: .leading, spacing: 8) {
            exampleRow(examples, Array(examples.indices.prefix(half)))
            exampleRow(examples, Array(examples.indices.dropFirst(half)))
        }
        .modifier(StaggeredRise(index: 3))
        .task { await ideas.refresh() }
    }

    private func exampleRow(_ examples: [StarterIdeas.Example], _ indices: [Int]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(indices, id: \.self) { index in
                    let example = examples[index]
                    Button { suggest?(example.text) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: example.symbol).font(.system(size: 14)).foregroundStyle(ChatColors.tertiary)
                            Text(example.label).font(.subheadline).lineLimit(1)
                        }.padding(.horizontal, 14).frame(height: 40)
                            .background(ChatColors.chip, in: Capsule())
                    }.buttonStyle(.pressable).accessibilityLabel(example.text).accessibilityIdentifier("emptyExample-\(index)")
                }
            }.padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// Three dots breathing in turn while the engine connects: quieter than a spinner, and the same
/// footprint every frame.
private struct ConnectingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin((t * 2 * .pi / 1.2) - Double(index) * 0.7) + 1) / 2
                    Circle().fill(ChatColors.muted)
                        .frame(width: 7, height: 7)
                        .opacity(Motion.reduced ? 0.6 : 0.25 + 0.6 * phase)
                        .scaleEffect(Motion.reduced ? 1 : 0.8 + 0.25 * phase)
                }
            }
        }
    }
}

/// 顶栏这一层：手机横放、键盘弹出时上移并淡出（240ms），把位置让给消息。
struct ChatHeadingBar<Content: View>: View {
    let aside: Bool
    @ViewBuilder let content: Content
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        let away = aside && vertical == .compact
        content
            .opacity(away ? 0 : 1)
            .offset(y: away ? -11 : 0)
            .frame(height: away ? 8 : nil, alignment: .top)
            .allowsHitTesting(!away)
            .accessibilityHidden(away)
            .animation(Motion.std(Motion.standard), value: away)
    }
}

/// 顶栏和输入区浮在消息上：消息铺满整页，从它们下面滚过；滚到下面的内容在边缘淡出
/// （iOS 26 起用系统的滚动边缘效果）。
struct FloatingBars<Top: View, Bottom: View>: ViewModifier {
    let top: Top
    let bottom: Bottom

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) { top }
                .safeAreaBar(edge: .bottom, spacing: 0) { bottom }
                .scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) { top }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
        }
    }
}
