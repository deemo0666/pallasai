import SwiftUI
import ImageIO
import PhotosUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor
final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()
    private let file: URL
    @Published private(set) var image: PlatformImage?

    init(directory: URL? = nil) {
        let support = URL.applicationSupportDirectory
        #if os(macOS)
        let location = directory ?? support.appending(path: Bundle.main.bundleIdentifier ?? "pallas.mac")
        file = location.appending(path: "chat-wallpaper.jpg")
        image = NSImage(contentsOf: file)
        #else
        file = (directory ?? support).appending(path: "chat-wallpaper.jpg")
        image = UIImage(contentsOfFile: file.path)
        #endif
    }

    nonisolated static let limit = 15 * 1024 * 1024
    nonisolated static func read(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw HostError(String(localized: "图片超过 15 MB")) }
        return data
    }

    func replace(_ data: Data) throws {
        guard data.count <= Self.limit else { throw HostError(String(localized: "图片超过 15 MB")) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let id = CGImageSourceGetType(source) as String? else {
            throw HostError(String(localized: "这张图片打不开，换一张试试"))
        }
        guard [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(id) else { throw HostError(String(localized: "支持 PNG、JPEG 和 WebP")) }
        guard let bitmap = RasterFrames.frame(source, 0, pixels: 2400),
              let bytes = RasterFrames.encode(bitmap, as: .jpeg, quality: 0.91) else {
            throw HostError(String(localized: "这张图片打不开，换一张试试"))
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #if os(macOS)
        try bytes.write(to: file, options: .atomic)
        image = NSImage(data: bytes)
        #else
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        image = UIImage(data: bytes)
        #endif
    }
}

struct WallpaperCanvas: View {
    let image: PlatformImage
    let zoom: Double
    let x: Double
    let y: Double
    let blur: Double
    let veil: Double
    /// Off for the position editor, which shows the picture itself.
    var veiled = true
    @Environment(\.colorScheme) private var scheme

    static func overflow(image: CGSize, viewport: CGSize, zoom: Double) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = max(viewport.width / image.width, viewport.height / image.height) * max(1, zoom)
        return CGSize(width: max(0, (image.width * scale - viewport.width) / 2),
                      height: max(0, (image.height * scale - viewport.height) / 2))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let extra = Self.overflow(image: image.size, viewport: size, zoom: zoom)
            Image(platformImage: image).resizable()
                .frame(width: size.width + 2 * extra.width, height: size.height + 2 * extra.height)
                .blur(radius: blur, opaque: true)
                .position(x: size.width / 2 + extra.width * x, y: size.height / 2 + extra.height * y)
                .frame(width: size.width, height: size.height).clipped()
                .overlay((scheme == .dark ? Color.black : Color.white).opacity(veiled ? 0.52 + 0.42 * veil : 0))
        }.accessibilityHidden(true)
    }
}

struct ChatWallpaper: View {
    var drawer = false
    @ObservedObject private var store = WallpaperStore.shared
    @AppStorage("wallpaperEnabled") private var enabled = false
    @AppStorage("wallpaperZoom") private var zoom = 1.0
    @AppStorage("wallpaperX") private var x = 0.0
    @AppStorage("wallpaperY") private var y = 0.0
    @AppStorage("wallpaperBlur") private var blur = 0.0
    @AppStorage("wallpaperDark") private var dark = 0.45
    @AppStorage("wallpaperLight") private var light = 0.45
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            if drawer { ChatColors.panel } else { ChatColors.canvas }
            if enabled, let image = store.image {
                WallpaperCanvas(image: image, zoom: zoom, x: x, y: y, blur: blur, veil: scheme == .dark ? dark : light)
            }
        }.allowsHitTesting(false)
    }
}

private struct WallpaperPhoto: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            WallpaperPhoto(data: try WallpaperStore.read(file.file))
        }
    }
}

/// 设置 › 主题 › 壁纸: the default backdrop or the person's own picture as two small phones (the
/// launch screen's card, same grid); where the picture sits, how soft and how calm, replace it,
/// preview it.
struct WallpaperSettings: View {
    var notify: (String) -> Void = { _ in }
    /// The stored blur is a radius; the slider shows it as a share of this.
    static let maxBlur = 16.0

    @ObservedObject private var store = WallpaperStore.shared
    @AppStorage("wallpaperEnabled") private var enabled = false
    @AppStorage("wallpaperZoom") private var zoom = 1.0
    @AppStorage("wallpaperX") private var x = 0.0
    @AppStorage("wallpaperY") private var y = 0.0
    @AppStorage("wallpaperBlur") private var blur = 0.0
    @AppStorage("wallpaperDark") private var dark = 0.45
    @AppStorage("wallpaperLight") private var light = 0.45
    @Environment(\.colorScheme) private var scheme
    @State private var photos = false
    @State private var photo: PhotosPickerItem?
    @State private var crop = false
    @State private var preview = false
    @State private var importing = false
    #if os(macOS)
    @State private var files = false
    @State private var issue: String?
    #endif

    var body: some View {
        controls
        .photosPicker(isPresented: $photos, selection: $photo, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photo) { _, item in
            guard let item, !importing else { return }
            importing = true
            Task {
                defer { importing = false; photo = nil }
                do {
                    guard let selection = try await item.loadTransferable(type: WallpaperPhoto.self) else {
                        throw HostError(String(localized: "这张图片打不开，换一张试试"))
                    }
                    try replace(selection.data)
                } catch { report(error) }
            }
        }
        #if os(macOS)
        .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
            guard !importing else { return }
            importing = true
            Task {
                defer { importing = false }
                do {
                    let url = try result.get()
                    let data = try await Task.detached { try WallpaperStore.read(url) }.value
                    try replace(data)
                } catch { report(error) }
            }
        }
        .sheet(isPresented: $crop) { cropEditor.desktopSheet(width: 680, height: 490) }
        .sheet(isPresented: $preview) { WallpaperPreview().desktopSheet(width: 680, height: 460) }
        #else
        .fullScreenCover(isPresented: $crop) { cropEditor }
        .fullScreenCover(isPresented: $preview) { WallpaperPreview() }
        #endif
    }

    private func replace(_ data: Data) throws {
        try store.replace(data)
        zoom = 1; x = 0; y = 0; enabled = true
        #if os(macOS)
        issue = nil
        #else
        notify(String(localized: "壁纸已更换"))
        #endif
    }

    private func report(_ error: Error) {
        let text = (error as? HostError)?.message ?? String(localized: "这张图片打不开，换一张试试")
        #if os(macOS)
        issue = text
        #else
        notify(text)
        #endif
    }

    @ViewBuilder private var cropEditor: some View {
        if let image = store.image {
            WallpaperCrop(image: image, zoom: zoom, x: x, y: y) { z, dx, dy in
                zoom = z; x = dx; y = dy
            }
        }
    }

    #if os(macOS)
    private var controls: some View {
        Form {
            Section {
                if let image = store.image {
                    Toggle("自定义", isOn: $enabled).accessibilityIdentifier("customWallpaper")
                    if enabled {
                        WallpaperCanvas(image: image, zoom: zoom, x: x, y: y, blur: blur, veil: scheme == .dark ? dark : light)
                            .frame(height: 136).clipShape(.rect(cornerRadius: 8))
                        Button("调整位置") { crop = true }
                            .accessibilityValue("\(Int((zoom * 100).rounded()))%")
                        Slider(value: Binding(get: { blur / Self.maxBlur }, set: { blur = $0 * Self.maxBlur }), in: 0...1, step: 0.05) {
                            Text("模糊")
                        }
                        Slider(value: scheme == .dark ? $dark : $light, in: 0...1, step: 0.05) {
                            Text(scheme == .dark ? "压暗" : "提亮")
                        }
                    }
                }
                Menu(store.image == nil ? String(localized: "选择图片") : String(localized: "更换图片")) {
                    Button("文件") { files = true }.accessibilityIdentifier("wallpaperImportFile")
                    Button("相册") { photos = true }
                }.accessibilityIdentifier("wallpaperImport")
                Button("预览") { preview = true }.accessibilityIdentifier("previewWallpaper")
                if let issue { MacErrorLine(message: issue) }
            }
        }
        .formStyle(.grouped)
        .disabled(importing)
    }
    #else
    private var controls: some View {
        let on = enabled && store.image != nil
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                ThemePhone(label: String(localized: "默认"), width: ThemePhoneMetrics.width, aspect: ThemePhoneMetrics.aspect, selected: !on) {
                    enabled = false
                } screen: {
                    ZStack { ChatColors.canvas; WallpaperSketch() }
                }.accessibilityIdentifier("defaultWallpaper")
                ThemePhone(label: String(localized: "自定义"), width: ThemePhoneMetrics.width, aspect: ThemePhoneMetrics.aspect, selected: on) {
                    if store.image == nil { photos = true } else { enabled = true }
                } screen: {
                    customScreen
                }.accessibilityIdentifier("customWallpaper")
            }.frame(maxWidth: .infinity).padding(.horizontal, 11).padding(.top, 11).padding(.bottom, 16)
            if on {
                ThemeRow(String(localized: "调整位置")) { crop = true }
                    .accessibilityValue("\(Int((zoom * 100).rounded()))%")
                WallpaperSliderRow(title: String(localized: "模糊"), value: Binding(get: { min(1, blur / Self.maxBlur) }, set: { blur = $0 * Self.maxBlur }))
                WallpaperSliderRow(title: scheme == .dark ? String(localized: "压暗") : String(localized: "提亮"), value: scheme == .dark ? $dark : $light)
                ThemeRow(String(localized: "更换图片")) { photos = true }.disabled(importing)
            }
            ThemeRow(String(localized: "预览")) { preview = true }.accessibilityIdentifier("previewWallpaper")
        }
        .animation(.easeInOut(duration: 0.25), value: on)
    }

    @ViewBuilder private var customScreen: some View {
        ZStack {
            if let image = store.image {
                let scale = ThemePhoneMetrics.width / max(1, UIScreen.main.bounds.width)
                WallpaperCanvas(image: image, zoom: zoom, x: x, y: y, blur: blur * scale, veil: scheme == .dark ? dark : light)
                WallpaperSketch()
            } else {
                ChatColors.muted.opacity(0.14)
                if !importing { Image(systemName: "photo.badge.plus").font(.system(size: 22)).foregroundStyle(ChatColors.muted) }
            }
            if importing {
                ChatColors.chip.opacity(0.6)
                ProgressView()
            }
        }
    }
    #endif
}

#if os(iOS)
/// A title with its percent, the slider under it, landing on 5% steps. Neutral, like every slider
/// in settings: the accent stays with the switches.
private struct WallpaperSliderRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        let percent = "\(Int((value * 100).rounded()))%"
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.body).foregroundStyle(ChatColors.ink)
                Spacer(minLength: 12)
                Text(percent).font(.subheadline).monospacedDigit().foregroundStyle(ChatColors.muted)
            }.accessibilityHidden(true)
            Slider(value: Binding(get: { min(max(value, 0), 1) }, set: { next in
                let snapped = (next * 20).rounded() / 20
                if snapped != (value * 20).rounded() / 20 { UISelectionFeedbackGenerator().selectionChanged() }
                value = snapped
            }), in: 0...1, step: 0.05) { Text(title) }
                .tint(ChatColors.muted)
                .accessibilityValue(percent)
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }
}

/// A sketch of the chat at the phone's scale: the header (menu key, title capsule, model key), the
/// person's bubble, the reply's lines, and the composer with its send key.
private struct WallpaperSketch: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let screen = UIScreen.main.bounds.size
        let insets = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets
        Canvas { context, size in
            let s = size.width / max(1, screen.width)
            let topInset = (insets?.top ?? 47) * s, bottomInset = (insets?.bottom ?? 34) * s
            let w = size.width, h = size.height
            let glass = GraphicsContext.Shading.color(ChatColors.chip.opacity(0.9))
            let edge = GraphicsContext.Shading.color(ChatColors.line)
            let ink = GraphicsContext.Shading.color(ChatColors.ink.opacity(dark ? 0.5 : 0.42))
            let faint = GraphicsContext.Shading.color(ChatColors.muted.opacity(0.5))
            func pill(_ r: CGRect) -> Path { Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2) }
            func chrome(_ r: CGRect) { context.fill(pill(r), with: glass); context.stroke(pill(r), with: edge, lineWidth: max(0.5, s)) }
            func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ shading: GraphicsContext.Shading) {
                context.fill(pill(CGRect(x: x, y: y, width: width, height: height)), with: shading)
            }
            let top = topInset + 6 * s
            chrome(CGRect(x: 12 * s, y: top, width: 44 * s, height: 44 * s))
            chrome(CGRect(x: 64 * s, y: top, width: w * 0.46, height: 44 * s))
            line(80 * s, top + 12 * s, w * 0.28, 9 * s, ink)
            line(80 * s, top + 26 * s, w * 0.14, 7 * s, faint)
            chrome(CGRect(x: w - 56 * s, y: top, width: 44 * s, height: 44 * s))
            let bubbleTop = top + 104 * s
            let bubble = CGRect(x: w - 16 * s - w * 0.6, y: bubbleTop, width: w * 0.6, height: 64 * s)
            context.fill(Path(roundedRect: bubble, cornerRadius: 22 * s), with: .color(ChatColors.user))
            line(bubble.minX + 18 * s, bubbleTop + 18 * s, w * 0.42, 10 * s, ink)
            line(bubble.minX + 18 * s, bubbleTop + 36 * s, w * 0.26, 10 * s, ink)
            let reply = bubbleTop + 104 * s
            for (index, share) in [0.82, 0.88, 0.76, 0.52].enumerated() {
                line(16 * s, reply + CGFloat(index) * 26 * s, (w - 32 * s) * share, 11 * s, ink)
            }
            line(16 * s, reply + 112 * s, w * 0.18, 8 * s, faint)
            let composer = CGRect(x: 12 * s, y: h - bottomInset - 64 * s, width: w - 24 * s, height: 52 * s)
            chrome(composer)
            line(composer.minX + 22 * s, composer.midY - 5 * s, w * 0.36, 10 * s, faint)
            context.fill(Path(ellipseIn: CGRect(x: composer.maxX - 44 * s, y: composer.midY - 18 * s, width: 36 * s, height: 36 * s)), with: .style(.tint))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
#endif

/// 壁纸 › 预览: a short conversation on the backdrop in use, over the whole screen, drawn with the
/// chat's own materials. A tap anywhere closes it.
private struct WallpaperPreview: View {
    @Environment(\.dismiss) private var dismiss
    private var bubbleWidth: CGFloat {
        #if os(macOS)
        440
        #else
        UIScreen.main.bounds.width * 0.78
        #endif
    }

    @ViewBuilder
    var body: some View {
        let sample = ZStack(alignment: .top) {
            ChatWallpaper().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("下周去杭州玩三天，帮我列一份行李清单。")
                        .font(.body).lineSpacing(5).foregroundStyle(ChatColors.ink)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(ChatColors.user, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(maxWidth: bubbleWidth, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(ChatColors.muted)
                        Text("查看了 2 份天气预报").font(.subheadline).foregroundStyle(ChatColors.muted)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                        .background(ChatColors.chip.opacity(0.87), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.55) }
                        .padding(.top, 20)
                    Text("按三天两晚准备：换洗衣物三套、折叠伞、充电器和充电宝、常用药和证件。")
                        .font(.body).lineSpacing(6).foregroundStyle(ChatColors.ink).padding(.top, 14)
                    Text("那几天多雨，建议带一双防水的鞋。")
                        .font(.subheadline).lineSpacing(5).foregroundStyle(ChatColors.muted).padding(.top, 8)
                    Text("刚刚").font(.caption2).foregroundStyle(ChatColors.muted.opacity(0.8)).padding(.top, 10)
                }.padding(.horizontal, 16).padding(.top, 72).padding(.bottom, 110)
            }.scrollDisabled(true)
            HStack(spacing: 8) {
                key("line.3.horizontal")
                VStack(alignment: .leading, spacing: 1) {
                    Text("整理旅行清单").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("预览").font(.caption2).foregroundStyle(ChatColors.muted)
                }.padding(.horizontal, 16).frame(height: 44).chatCapsule()
                Spacer(minLength: 0)
                key("square.and.pencil")
            }.foregroundStyle(ChatColors.ink).padding(.horizontal, 12).padding(.top, 6)
            VStack {
                Spacer()
                HStack {
                    Text("给 Pallas Agent 发消息…").font(.body).foregroundStyle(ChatColors.muted).lineLimit(1).padding(.leading, 20)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(.tint, in: Circle()).padding(.trailing, 8)
                }.frame(height: 52).chatCapsule().padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        #if os(macOS)
        NavigationStack {
            sample.navigationTitle("预览")
                .toolbar { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        #else
        sample.contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityAction(.escape) { dismiss() }
            .accessibilityAction(named: "关闭") { dismiss() }
        #endif
    }

    private func key(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17)).frame(width: 44, height: 44).chatCapsule().accessibilityHidden(true)
    }
}

/// 壁纸 › 调整位置: the picture itself over the screen; drag and pinch, 复原 to start over, 完成 keeps it.
private struct WallpaperCrop: View {
    let image: PlatformImage
    @State var zoom: Double
    @State var x: Double
    @State var y: Double
    let save: (Double, Double, Double) -> Void
    @GestureState private var pinch = CGFloat(1)
    @GestureState private var drag = CGSize.zero
    @Environment(\.dismiss) private var dismiss

    private func shift(_ base: Double, _ delta: CGFloat, _ range: CGFloat) -> Double {
        range > 0 ? min(1, max(-1, base + delta / range)) : 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                let scale = max(1, min(5, zoom * pinch))
                let extra = WallpaperCanvas.overflow(image: image.size, viewport: proxy.size, zoom: scale)
                WallpaperCanvas(image: image, zoom: scale, x: shift(x, drag.width, extra.width), y: shift(y, drag.height, extra.height),
                                blur: 0, veil: 0, veiled: false)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                        x = shift(x, value.translation.width, extra.width); y = shift(y, value.translation.height, extra.height)
                    })
                    .simultaneousGesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }.onEnded { value in
                        zoom = min(5, max(1, zoom * value.magnification))
                    })
            }.ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.18))
                .ignoresSafeArea().allowsHitTesting(false)
            #if os(macOS)
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Slider(value: $zoom, in: 1...5) { Text("缩放") }
                        .accessibilityValue("\(Int((zoom * 100).rounded()))%")
                    HStack {
                        Button("复原", action: reset)
                        Spacer()
                        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button("完成") { save(zoom, x, y); dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .padding(16)
            }
            #else
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).chatCapsule()
                    }.buttonStyle(.plain).foregroundStyle(ChatColors.ink).accessibilityLabel("取消")
                    Spacer()
                    Button { save(zoom, x, y); dismiss() } label: {
                        Text("完成").font(.body.weight(.semibold)).foregroundStyle(.tint).padding(.horizontal, 20).frame(height: 44).chatCapsule()
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 12).padding(.top, 6)
                Spacer()
                HStack(spacing: 0) {
                    Text("拖动、双指缩放").font(.subheadline.weight(.medium)).foregroundStyle(ChatColors.ink).padding(.leading, 18).padding(.trailing, 10)
                    Rectangle().fill(ChatColors.line).frame(width: 1, height: 16)
                    Button(action: reset) {
                        Text("复原").font(.subheadline.weight(.medium)).foregroundStyle(.tint).padding(.leading, 12).padding(.trailing, 18).frame(height: 40)
                    }.buttonStyle(.plain)
                }.frame(height: 40).chatCapsule().padding(.bottom, 20)
            }
            #endif
        }
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.25)) { zoom = 1; x = 0; y = 0 }
    }
}
