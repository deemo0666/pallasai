import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Feature tiles

enum FeatureIconStyle: String, CaseIterable {
    case flat = "扁平双色", geometric = "极简几何", glass = "玻璃渐变"
}

/// A feature's graphic in the chosen style, every tone from the accent.
struct FeatureGlyph: View {
    let symbol: String
    let style: FeatureIconStyle
    let color: Color
    var size: CGFloat = 45

    var body: some View {
        let k = size / 45
        let shape = RoundedRectangle(cornerRadius: (style == .geometric ? 9 : 12.5) * k, style: .continuous)
        ZStack {
            switch style {
            case .flat:
                ZStack {
                    shape.fill(color.opacity(0.13))
                    Circle().fill(color.opacity(0.2)).frame(width: size * 0.66, height: size * 0.66).offset(x: size * 0.24, y: size * 0.26)
                }.clipShape(shape)
                Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(color)
            case .geometric:
                shape.strokeBorder(color.opacity(0.55), lineWidth: max(0.75, k))
                Image(systemName: symbol).fontWeight(.light).foregroundStyle(color)
            case .glass:
                shape.fill(LinearGradient(colors: [color.opacity(0.62), color], startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.fill(LinearGradient(colors: [.white.opacity(0.38), .clear], startPoint: .top, endPoint: .center))
                shape.strokeBorder(.white.opacity(0.45), lineWidth: max(0.5, k * 0.8))
                Image(systemName: symbol).foregroundStyle(.white).shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            }
        }.frame(width: size, height: size).font(.system(size: 21 * k, weight: .medium)).accessibilityHidden(true)
    }
}

// MARK: - Page parts shared by the 主题 pages

/// A card on a settings page: rows sit flush, 16 in from its edges.
struct ThemeCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A row in a card: the title, an optional value, a chevron when it opens something.
struct ThemeRow<Value: View>: View {
    let title: String
    var subtitle: String? = nil
    var chevron = true
    var action: (() -> Void)? = nil
    @ViewBuilder var value: () -> Value

    var body: some View {
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(ChatColors.ink)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(ChatColors.muted) }
            }
            Spacer(minLength: 8)
            value()
            if chevron && action != nil {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted.opacity(0.7))
                    .accessibilityHidden(true)
            }
        }.padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 52).contentShape(Rectangle())
    }
}

extension ThemeRow where Value == EmptyView {
    init(_ title: String, subtitle: String? = nil, chevron: Bool = true, action: (() -> Void)?) {
        self.init(title: title, subtitle: subtitle, chevron: chevron, action: action) { EmptyView() }
    }
}

/// Segments inside a card row (填满 | 居中): the settings segmented control.
struct ThemePills<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        SettingsSegmented(options: options, selection: $selection).fixedSize()
            .animation(.easeOut(duration: 0.18), value: selection)
    }
}

/// The name under a choice: the accent and heavier when chosen.
struct ThemeCaption: View {
    let text: String
    let selected: Bool

    init(_ text: String, selected: Bool) { self.text = text; self.selected = selected }

    var body: some View {
        Text(text).font(.caption.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(ChatColors.muted))
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}

/// One of a pair of previews (启动画面, 壁纸): the screen clipped to its corners, a
/// hairline edge, an accent ring 3 off it when chosen, the name under it.
struct ThemePhone<Screen: View>: View {
    let label: String
    let width: CGFloat
    let aspect: CGFloat
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                screen().frame(width: width, height: width / aspect)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5) }
                    .padding(5)
                    .overlay { RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.tint, lineWidth: 2).opacity(selected ? 1 : 0) }
                    .allowsHitTesting(false)
                ThemeCaption(label, selected: selected)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

enum ThemePhoneMetrics {
    #if os(macOS)
    static let aspect: CGFloat = 16 / 10
    static let width: CGFloat = 160
    #else
    /// A phone's width / height: the screen's own shape, kept within a sensible range.
    static var aspect: CGFloat {
        let screen = UIScreen.main.bounds.size
        return screen.height <= 0 ? 0.5 : min(max(screen.width / screen.height, 0.45), 0.62)
    }

    /// Each phone is a third of the card's inner width; the pair is centred 12 apart.
    static var width: CGFloat { max(60, (UIScreen.main.bounds.width - 32 - 56) / 3) }
    #endif
}

/// A brief notice over the bottom of a page (App 图标已选择…, 壁纸已更换).
struct ThemeNotice: Equatable {
    let id = UUID()
    let text: String
}

struct ThemeNoticeView: View {
    @Binding var notice: ThemeNotice?

    var body: some View {
        ZStack {
            if let notice {
                Text(notice.text).font(.subheadline.weight(.medium)).foregroundStyle(ChatColors.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 11).chatCapsule()
                    .padding(.horizontal, 24).padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice.id) {
                        AccessibilityNotification.Announcement(notice.text).post()
                        try? await Task.sleep(for: .seconds(2.6))
                        if self.notice?.id == notice.id { self.notice = nil }
                    }
            }
        }.animation(.easeOut(duration: 0.22), value: notice)
    }
}

// MARK: - 主题

#if os(iOS)
/// 设置 › 外观: a chat preview over 跟随系统 | 浅色 | 深色, the palette row, then 对话字号, 完成后收起过程
/// and the pages for 功能图标, 桌面图标, 聊天壁纸 and 启动画面. Everything applies at once.
struct ThemeSettings: View {
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("accentPalette") private var palette = AccentPalette.graphite
    @AppStorage("accentHue") private var hue = 0.58
    @AppStorage("accentChroma") private var chroma = AccentPalette.trackChroma
    @AppStorage("featureIconStyle") private var iconStyle = FeatureIconStyle.flat
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @AppStorage("collapseChatSteps") private var collapseSteps = true
    @AppStorage("wallpaperEnabled") private var wallpaperOn = false
    @AppStorage("launchArtworkEnabled") private var launchOn = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIcon = UIApplication.shared.alternateIconName ?? "AppIcon"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ThemeCard {
                    VStack(spacing: 12) {
                        ThemeChatPreview(palette: palette, hue: hue, chroma: chroma)
                        SettingsSegmented(options: [(0, String(localized: "跟随系统")), (1, String(localized: "浅色")), (2, String(localized: "深色"))],
                                          selection: $appearance, expand: true)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("themeMode")
                    }.padding(14)
                }
                ThemeCard {
                    ThemePalettePicker(palette: $palette, hue: hue, chroma: chroma)
                    if palette == .custom {
                        ThemeCustomAccent(hue: $hue, chroma: $chroma)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                ThemeCard {
                    SettingsSegmentedRow(symbol: "text", title: String(localized: "对话字号"),
                                         options: ChatTypeSize.allCases.map { ($0, $0.rawValue.localized) }, selection: $typeSize)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .accessibilityElement(children: .contain).accessibilityIdentifier("chatFontSize")
                    SettingsDivider()
                    SettingsToggleRow(symbol: "fold", title: String(localized: "完成后收起过程"), isOn: $collapseSteps).padding(.horizontal, 16)
                    SettingsDivider()
                    NavigationLink { ThemeDetailPage(title: String(localized: "功能图标")) { _ in
                        ThemeCard { ThemeTileStylePicker(style: $iconStyle, accent: palette.color(hue: hue)) }
                    } } label: {
                        SettingsRowLabel(symbol: "grid", title: String(localized: "功能图标"), value: iconStyle.rawValue.localized).padding(.horizontal, 16)
                    }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("themeFeatureIcon")
                    if UIApplication.shared.supportsAlternateIcons {
                        SettingsDivider()
                        NavigationLink { ThemeDetailPage(title: String(localized: "桌面图标")) { notify in
                            ThemeCard { ThemeAppIconPicker(current: $currentIcon, notify: notify) }
                        } } label: {
                            SettingsRowLabel(symbol: "app", title: String(localized: "桌面图标"),
                                             value: ThemeAppIconPicker.icons.first { $0.0 == currentIcon }?.1).padding(.horizontal, 16)
                        }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("themeAppIcon")
                    }
                    SettingsDivider()
                    NavigationLink { ThemeDetailPage(title: String(localized: "聊天壁纸")) { notify in ThemeCard { WallpaperSettings(notify: notify) } } } label: {
                        SettingsRowLabel(symbol: "image", title: String(localized: "聊天壁纸"),
                                         value: wallpaperOn ? String(localized: "已开启") : String(localized: "无")).padding(.horizontal, 16)
                    }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("themeWallpaper")
                    SettingsDivider()
                    NavigationLink { ThemeDetailPage(title: String(localized: "启动画面")) { notify in ThemeCard { LaunchArtworkSettings(notify: notify) } } } label: {
                        SettingsRowLabel(symbol: "phone", title: String(localized: "启动画面"),
                                         value: launchOn ? String(localized: "已开启") : String(localized: "默认")).padding(.horizontal, 16)
                    }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("themeLaunch")
                }
            }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 32)
        }
        .tint(palette.color(hue: hue))
        .settingsPage(String(localized: "外观"))
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { currentIcon = UIApplication.shared.alternateIconName ?? "AppIcon" }
        }
    }
}
#endif

/// A page under 外观 with its own brief notices at the bottom.
struct ThemeDetailPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: (@escaping (String) -> Void) -> Content
    @AppStorage("accentPalette") private var palette = AccentPalette.graphite
    @AppStorage("accentHue") private var hue = 0.58
    @AppStorage("accentChroma") private var chroma = AccentPalette.trackChroma
    @State private var notice: ThemeNotice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content { notice = ThemeNotice(text: $0) }
            }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 32)
        }
        .tint(palette.color(hue: hue, chroma: chroma))
        .settingsPage(title)
        .overlay(alignment: .bottom) { ThemeNoticeView(notice: $notice) }
    }
}

/// The chat in miniature: the page's gradient, the person's bubble in the accent, a reply.
struct ThemeChatPreview: View {
    let palette: AccentPalette
    let hue: Double
    let chroma: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tones = palette.tones(dark: scheme == .dark, hue: hue, chroma: chroma)
        VStack(alignment: .leading, spacing: 8) {
            Text("下午三点取快递").padding(.horizontal, 11).padding(.vertical, 6)
                .background(tones.bubble.color, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("好的，已经加到周五清单。")
        }
        .font(.subheadline).foregroundStyle(ChatColors.ink)
        .padding(12).frame(maxWidth: .infinity, minHeight: 104)
        .background(ChatColors.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// The four launcher icons, the one on the home screen ringed in the accent.
struct ThemeAppIconPicker: View {
    @Binding var current: String
    var notify: (String) -> Void

    static let icons: [(String, String)] = [("AppIcon", String(localized: "雾蓝")), ("Midnight", String(localized: "夜幕")), ("Frost", String(localized: "霜白")), ("Ink", String(localized: "墨"))]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Self.icons, id: \.0) { name, title in
                let selected = current == name
                Button { select(name) } label: {
                    VStack(spacing: 3) {
                        Image(name + "Preview").resizable().aspectRatio(1, contentMode: .fit).frame(maxWidth: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12.6, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 12.6, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5) }
                            .padding(5)
                            .overlay { RoundedRectangle(cornerRadius: 17.6, style: .continuous).strokeBorder(.tint, lineWidth: 2).opacity(selected ? 1 : 0) }
                        ThemeCaption(title, selected: selected)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("appIcon." + name)
            }
        }.padding(.horizontal, 11).padding(.top, 11).padding(.bottom, 16)
    }

    private func select(_ name: String) {
        guard name != current else { return }
        #if os(macOS)
        if Self.applyDockIcon(name) {
            current = name
        } else {
            notify(String(localized: "没能更换，稍后再试"))
        }
        #else
        UIApplication.shared.setAlternateIconName(name == "AppIcon" ? nil : name) { error in
            DispatchQueue.main.async {
                current = error == nil ? name : UIApplication.shared.alternateIconName ?? "AppIcon"
                notify(error == nil ? String(localized: "App 图标已更换，回到主屏幕就能看到") : String(localized: "没能更换，稍后再试"))
            }
        }
        #endif
    }
}

#if os(macOS)
extension ThemeAppIconPicker {
    static let dockIconKey = "dockIcon"
    static let defaultIcon = "AppIcon"

    @MainActor @discardableResult
    static func applyDockIcon(_ name: String) -> Bool {
        if name == defaultIcon {
            NSApplication.shared.applicationIconImage = nil
            return true
        }
        guard icons.contains(where: { $0.0 == name }),
              let image = NSImage(named: name + "Preview") else { return false }
        NSApplication.shared.applicationIconImage = NSImage(size: image.size, flipped: false) { bounds in
            let shape = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
            let radius = shape.width * 0.22
            NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).addClip()
            image.draw(in: shape)
            return true
        }
        return true
    }
}
#endif

// MARK: 配色

/// One row: six presets + 自定义 (a hue wheel). Each disc is the accent in the current brightness;
/// the chosen one gets a ring of its own colour.
struct ThemePalettePicker: View {
    @Binding var palette: AccentPalette
    let hue: Double
    let chroma: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(AccentPalette.allCases, id: \.self) { value in
                swatch(value)
            }
        }.padding(.horizontal, 12.5).padding(.vertical, 16)
    }

    private func swatch(_ value: AccentPalette) -> some View {
        let dark = scheme == .dark
        let selected = palette == value
        let color = value.tones(dark: dark, hue: hue, chroma: chroma).seed.color
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { palette = value }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 2).opacity(selected ? 1 : 0)
                    if value == .custom {
                        Circle().fill(AngularGradient(colors: AccentPalette.wheel(dark: dark), center: .center)).frame(width: 30, height: 30)
                        Circle().fill(ChatColors.chip).frame(width: 18.6, height: 18.6)
                        Circle().fill(color).frame(width: 13.2, height: 13.2)
                    } else {
                        Circle().fill(color).frame(width: 30, height: 30)
                    }
                    Circle().strokeBorder(ChatColors.ink.opacity(0.08), lineWidth: 0.5).frame(width: 30, height: 30)
                }.frame(width: 39, height: 39)
                ThemeCaption(value.rawValue.localized, selected: selected)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(String(localized: "配色：") + value.rawValue.localized)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

/// 自定义: a hue track and six suggestions, both drawn in guarded colours.
struct ThemeCustomAccent: View {
    @Binding var hue: Double
    @Binding var chroma: Double
    @Environment(\.colorScheme) private var scheme
    @State private var dragging: Double?
    @State private var sent = Date.distantPast

    var body: some View {
        VStack(spacing: 14) {
            track
            HStack(spacing: 0) {
                ForEach(AccentPalette.suggestions.indices, id: \.self) { index in
                    let (degrees, value, name) = AccentPalette.suggestions[index]
                    if index > 0 { Spacer(minLength: 0) }
                    chip(degrees, value, name)
                }
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }

    private var degrees: Double { dragging ?? hue * 360 }

    private var track: some View {
        let dark = scheme == .dark
        let current = AccentPalette.derived(hue: degrees, chroma: AccentPalette.trackChroma, dark: dark).seed.color
        return GeometryReader { proxy in
            let width = proxy.size.width
            let x = 13 + min(max(degrees / 360, 0), 1) * (width - 26)
            ZStack(alignment: .topLeading) {
                Capsule().fill(LinearGradient(colors: AccentPalette.wheel(dark: dark), startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, width - 14), height: 12).position(x: width / 2, y: 18)
                ZStack {
                    Circle().fill(dark ? ChatColors.ink : Color.white).shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    Circle().fill(current).padding(4)
                }.frame(width: 26, height: 26).position(x: x, y: 18)
            }.frame(width: width, height: 36).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                set(value.location.x, width: width, end: false)
            }.onEnded { value in
                set(value.location.x, width: width, end: true)
            })
        }.frame(height: 36)
        .accessibilityElement()
        .accessibilityLabel("色相")
        .accessibilityValue("\(Int(degrees.rounded()))°")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 15.0 : -15
            commit(((hue * 360 + step).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        }
    }

    private func set(_ x: CGFloat, width: CGFloat, end: Bool) {
        let value = min(max((x - 13) / max(1, width - 26), 0), 1) * 360
        dragging = end ? nil : value
        let now = Date()
        if end || now.timeIntervalSince(sent) > 0.1 {
            sent = now
            commit(value)
        }
    }

    private func commit(_ degrees: Double, chroma value: Double = AccentPalette.trackChroma) {
        var next = degrees / 360
        // Only the chroma changing still has to reach views that watch the hue.
        if abs(next - hue) < 1e-9 && value != chroma { next += 1e-7 }
        chroma = value
        hue = next
    }

    private func chip(_ degrees: Double, _ value: Double, _ name: String) -> some View {
        let color = AccentPalette.derived(hue: degrees, chroma: value, dark: scheme == .dark).seed.color
        let selected = abs(hue * 360 - degrees) < 0.01 && abs(chroma - value) < 0.0001
        return Button { commit(degrees, chroma: value) } label: {
            ZStack {
                Circle().stroke(color, lineWidth: 2).frame(width: 29, height: 29).opacity(selected ? 1 : 0)
                Circle().fill(color).frame(width: 22, height: 22)
                Circle().strokeBorder(ChatColors.ink.opacity(0.08), lineWidth: 0.5).frame(width: 22, height: 22)
            }.frame(width: 36, height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: 功能图标

/// Three square previews, one per style, each a 2 × 2 grid of feature tiles (终端, 自动化, 模型,
/// 社区); the chosen one ringed in the accent.
private struct ThemeTileStylePicker: View {
    @Binding var style: FeatureIconStyle
    let accent: Color
    @Environment(\.colorScheme) private var scheme

    private static let sample = ["apple.terminal", "gearshape.2", "cpu", "person.2"]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(FeatureIconStyle.allCases, id: \.self) { value in
                option(value)
            }
        }.padding(16)
    }

    private func option(_ value: FeatureIconStyle) -> some View {
        let selected = style == value
        return Button { style = value } label: {
            VStack(spacing: 8) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in
                            let side = proxy.size.width
                            let tile = side * 0.28, gap = side * 0.1
                            VStack(spacing: gap) {
                                HStack(spacing: gap) {
                                    FeatureGlyph(symbol: Self.sample[0], style: value, color: accent, size: tile)
                                    FeatureGlyph(symbol: Self.sample[1], style: value, color: accent, size: tile)
                                }
                                HStack(spacing: gap) {
                                    FeatureGlyph(symbol: Self.sample[2], style: value, color: accent, size: tile)
                                    FeatureGlyph(symbol: Self.sample[3], style: value, color: accent, size: tile)
                                }
                            }.frame(width: side, height: proxy.size.height)
                        }
                    }
                    .background((scheme == .dark ? Color.white.opacity(0.05) : ChatColors.ink.opacity(0.04)),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(ChatColors.line), lineWidth: selected ? 2 : 1)
                    }
                ThemeCaption(value.rawValue.localized, selected: selected)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(value.rawValue.localized).accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}
