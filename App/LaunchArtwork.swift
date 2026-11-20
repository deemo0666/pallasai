import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LaunchAsset: Sendable {
    private static let imageTypes: [UTType] = [.png, .jpeg, .webP, .gif]
    static let fileTypes = imageTypes + [.mpeg4Movie]

    let folder: URL
    let movie: Bool
    let poster: CGImage
    let edgeColor: Color
    var media: URL { folder.appending(path: movie ? "clip.mp4" : "image") }

    init?(folder: URL) {
        guard let source = CGImageSourceCreateWithURL(folder.appending(path: "poster.jpg") as CFURL, nil),
              let poster = RasterFrames.frame(source, 0, pixels: 400) else { return nil }
        self.folder = folder
        self.poster = poster
        edgeColor = Self.edgeColor(of: poster)
        movie = FileManager.default.fileExists(atPath: folder.appending(path: "clip.mp4").path)
        guard FileManager.default.fileExists(atPath: media.path) else { return nil }
    }

    static func importFile(_ url: URL, into root: URL) async throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let cap = 30 * 1024 * 1024
        let data = try handle.read(upToCount: cap + 1) ?? Data()
        guard data.count <= cap else { throw HostError(String(localized: "文件超过 30 MB")) }
        let folder = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let poster: CGImage
            if let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String? {
                guard imageTypes.contains(where: { $0.identifier == type }) else { throw HostError(String(localized: "支持 PNG、JPEG、WebP、GIF 和 MP4")) }
                guard data.count <= 8 * 1024 * 1024 else { throw HostError(String(localized: "图片超过 8 MB")) }
                guard let first = RasterFrames.frame(source, 0, pixels: 400) else { throw HostError(String(localized: "无法读取这个文件")) }
                poster = first
                try data.write(to: folder.appending(path: "image"))
            } else {
                guard data.count >= 12, data[4..<8].elementsEqual("ftyp".utf8) else { throw HostError(String(localized: "支持 PNG、JPEG、WebP、GIF 和 MP4")) }
                let video = folder.appending(path: "clip.mp4")
                try data.write(to: video)
                let asset = AVURLAsset(url: video)
                guard try await asset.load(.isPlayable), try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw HostError(String(localized: "无法读取这个文件")) }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400)
                poster = try await generator.image(at: .zero).image
            }
            guard let jpg = RasterFrames.encode(poster, as: .jpeg, quality: 0.88) else { throw HostError(String(localized: "无法读取这个文件")) }
            try jpg.write(to: folder.appending(path: "poster.jpg"))
            guard let asset = Self(folder: folder) else { throw HostError(String(localized: "无法读取这个文件")) }
            return asset
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static var directory: URL {
        let support = URL.applicationSupportDirectory
        #if os(macOS)
        return support.appending(path: Bundle.main.bundleIdentifier ?? "pallas.mac").appending(path: "LaunchArtwork")
        #else
        return support.appending(path: "LaunchArtwork")
        #endif
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self? {
        guard defaults.bool(forKey: "launchArtworkEnabled") else { return nil }
        return saved(defaults.string(forKey: "launchArtworkID") ?? "")
    }

    static func saved(_ id: String) -> Self? {
        guard UUID(uuidString: id) != nil else { return nil }
        return Self(folder: directory.appending(path: id))
    }

    private static func edgeColor(of poster: CGImage) -> Color {
        guard let strip = poster.cropping(to: CGRect(x: 0, y: 0, width: poster.width, height: 1)) else { return .black }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.interpolationQuality = .high
            context?.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Color(red: Double(pixel[0])/255, green: Double(pixel[1])/255, blue: Double(pixel[2])/255)
    }
}

private struct LaunchTransfer: Transferable {
    let asset: LaunchAsset
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            LaunchTransfer(asset: try await LaunchAsset.importFile(file.file, into: LaunchAsset.directory))
        }
        FileRepresentation(importedContentType: .movie) { file in
            LaunchTransfer(asset: try await LaunchAsset.importFile(file.file, into: LaunchAsset.directory))
        }
    }
}

/// 设置 › 外观 › 启动画面: choose, replace and preview the media in the same layout as launch.
struct LaunchArtworkSettings: View {
    var notify: (String) -> Void = { _ in }

    @AppStorage("launchArtworkID") private var id = ""
    @AppStorage("launchArtworkEnabled") private var enabled = false
    @AppStorage("launchArtworkFill") private var fill = true
    @AppStorage("launchArtworkBackdrop") private var backdrop = "自动"
    @State private var saved: LaunchAsset?
    @State private var chooseSource = false
    @State private var photos = false
    @State private var files = false
    @State private var photo: PhotosPickerItem?
    @State private var preview = false
    @State private var busy = false

    var body: some View {
        let on = enabled && saved != nil
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                ThemePhone(label: String(localized: "默认"), width: ThemePhoneMetrics.width, aspect: ThemePhoneMetrics.aspect, selected: !on) {
                    enabled = false
                } screen: {
                    defaultScreen
                }.accessibilityIdentifier("launchArtworkDefault")
                ThemePhone(label: String(localized: "自定义"), width: ThemePhoneMetrics.width, aspect: ThemePhoneMetrics.aspect, selected: on) {
                    if saved == nil { chooseSource = true } else { enabled = true }
                } screen: {
                    customScreen
                }.accessibilityIdentifier("launchArtworkCustom")
            }.frame(maxWidth: .infinity).padding(.horizontal, 11).padding(.top, 11).padding(.bottom, 16)
            if on {
                ThemeRow(title: String(localized: "适配方式"), chevron: false, value: {
                    ThemePills(options: [(true, String(localized: "填满")), (false, String(localized: "居中"))], selection: $fill).accessibilityIdentifier("launchFit")
                })
                ThemeRow(title: String(localized: "背景色"), chevron: false, value: { swatches.accessibilityIdentifier("launchBackdrop") })
                ThemeRow(String(localized: "更换图片或视频")) { chooseSource = true }
            }
            ThemeRow(String(localized: "预览")) { preview = true }.accessibilityIdentifier("previewLaunchArtwork")
        }
        .disabled(busy)
        .animation(.easeInOut(duration: 0.25), value: on)
        .onChange(of: id, initial: true) { _, value in saved = LaunchAsset.saved(value) }
        .confirmationDialog("更换图片或视频", isPresented: $chooseSource, titleVisibility: .hidden) {
            Button("从照片选择") { photos = true }
            Button("从文件选择") { files = true }
        }
        .photosPicker(isPresented: $photos, selection: $photo, matching: .any(of: [.images, .videos]), preferredItemEncoding: .compatible)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                await install {
                    guard let transfer = try await item.loadTransferable(type: LaunchTransfer.self) else { throw HostError(String(localized: "无法读取这个文件")) }
                    return transfer.asset
                }
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: LaunchAsset.fileTypes) { result in
            Task { await install { try await LaunchAsset.importFile(result.get(), into: LaunchAsset.directory) } }
        }
        #if os(macOS)
        .sheet(isPresented: $preview) {
            LaunchPlayback(asset: on ? saved : nil) { preview = false }
                .desktopSheet(width: 720, height: 450)
        }
        #else
        .fullScreenCover(isPresented: $preview) { LaunchPlayback(asset: on ? saved : nil) { preview = false } }
        #endif
    }

    /// The default launch screen at rest: the mark on the page, at the thumbnail's scale.
    private var defaultScreen: some View {
        #if os(macOS)
        let side: CGFloat = 28
        #else
        let scale = ThemePhoneMetrics.width / max(1, UIScreen.main.bounds.width)
        let side = max(22, 72 * scale)
        #endif
        return ZStack {
            LaunchPlayback.background("自动", asset: nil)
            Image("AppIconPreview").resizable().frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        }
    }

    /// The picture as the launch shows it (its fit, its background); the add mark before there is one.
    @ViewBuilder private var customScreen: some View {
        ZStack {
            if let saved {
                LaunchPlayback.background(backdrop, asset: saved)
                Image(decorative: saved.poster, scale: 1).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                    .frame(width: ThemePhoneMetrics.width, height: ThemePhoneMetrics.width / ThemePhoneMetrics.aspect).clipped()
            } else {
                ChatColors.muted.opacity(0.14)
                if !busy { Image(systemName: "photo.badge.plus").font(.system(size: 22)).foregroundStyle(ChatColors.muted) }
            }
            if busy {
                ChatColors.chip.opacity(0.6)
                ProgressView()
            }
        }
    }

    /// 自动 (light and dark halves: it follows the system), 取自图片, 白色, 黑色; the chosen one ringed.
    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach(["自动", "取自图片", "白色", "黑色"], id: \.self) { name in
                let selected = backdrop == name
                Button { backdrop = name } label: {
                    ZStack {
                        Circle().stroke(.tint, lineWidth: 2).frame(width: 28, height: 28).opacity(selected ? 1 : 0)
                        Group {
                            switch name {
                            case "自动":
                                Circle().fill(ThemeRGB(hex: 0x1D222C).color)
                                    .overlay(alignment: .leading) { Rectangle().fill(ThemeRGB(hex: 0xEBF1FE).color).frame(width: 11) }
                                    .clipShape(Circle())
                            case "取自图片": Circle().fill(saved?.edgeColor ?? .gray)
                            case "白色": Circle().fill(Color.white)
                            default: Circle().fill(Color.black)
                            }
                        }.frame(width: 22, height: 22)
                        Circle().strokeBorder(ChatColors.line, lineWidth: 0.5).frame(width: 22, height: 22)
                    }.frame(width: 30, height: 30).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel(name.localized).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func install(_ load: () async throws -> LaunchAsset) async {
        guard !busy else { return }
        busy = true
        defer { photo = nil; busy = false }
        do {
            let asset = try await load()
            let old = saved
            id = asset.folder.lastPathComponent; saved = asset; enabled = true
            if let old { try? FileManager.default.removeItem(at: old.folder) }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: asset.media.path)[.size] as? Int) ?? nil
            notify(bytes.map { String(localized: "启动画面已更换 · ") + Self.size($0) } ?? String(localized: "启动画面已更换"))
        } catch {
            notify((error as? HostError)?.message ?? String(localized: "无法读取这个文件"))
        }
    }

    /// A file's size for people: 860 KB, 12.4 MB.
    static func size(_ bytes: Int) -> String {
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded(.up))) KB" }
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", mb)
    }
}

#if os(macOS)
private struct LaunchVideo: NSViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    final class Surface: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {
        guard let layer = view.layer as? AVPlayerLayer else { return }
        layer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        layer.player = player
    }
}
#else
private struct LaunchVideo: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    final class Surface: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self } }
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        guard let layer = view.layer as? AVPlayerLayer else { return }
        layer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        layer.player = player
    }
}
#endif

struct LaunchPlayback: View {
    let asset: LaunchAsset?
    let finish: () -> Void
    @AppStorage("launchArtworkFill") private var fill = true
    @AppStorage("launchArtworkBackdrop") private var backdrop = "自动"
    @Environment(\.scenePhase) private var phase
    @State private var frame: CGImage?
    @State private var player: AVPlayer?
    @State private var ended = false
    @State private var active = true
    private var background: Color { Self.background(backdrop, asset: asset) }

    static func background(_ backdrop: String, asset: LaunchAsset?) -> Color {
        #if os(macOS)
        let system = Color(nsColor: .windowBackgroundColor)
        #else
        let system = Color(uiColor: .systemBackground)
        #endif
        guard let asset else { return system }
        switch backdrop {
        case "黑色": return .black
        case "白色": return .white
        case "取自图片": return asset.edgeColor
        default: return system
        }
    }
    var body: some View {
        GeometryReader { bounds in
            Button(action: end) {
                ZStack {
                    background
                    if let asset {
                        Image(decorative: frame ?? asset.poster, scale: 1).resizable()
                            .aspectRatio(contentMode: fill ? .fill : .fit)
                            .frame(width: bounds.size.width, height: bounds.size.height).clipped()
                        if let player { LaunchVideo(player: player, fill: fill).allowsHitTesting(false) }
                    } else {
                        Image("AppIconPreview").resizable().frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }.frame(width: bounds.size.width, height: bounds.size.height).clipped().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("跳过启动画面")
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
        }.ignoresSafeArea()
        #if os(iOS)
        .statusBarHidden()
        #endif
        .task {
            do {
                if let asset, asset.movie {
                    let movie = AVPlayer(url: asset.media)
                    movie.isMuted = true
                    player = movie
                    if phase == .active { movie.play() }
                    if let item = movie.currentItem {
                        for await status in item.publisher(for: \.status, options: [.initial, .new]).values {
                            if Task.isCancelled || status == .readyToPlay { break }
                            if status == .failed { end(); break }
                        }
                    }
                } else if let asset, let source = CGImageSourceCreateWithURL(asset.media as CFURL, nil) {
                    let count = CGImageSourceGetCount(source)
                    for index in 0..<count {
                        while !active { try await Task.sleep(for: .milliseconds(100)) }
                        try Task.checkCancellation()
                        guard let next = RasterFrames.frame(source, index) else { break }
                        frame = next
                        try await Task.sleep(for: .seconds(count == 1 ? 1.4 : RasterFrames.frameDelay(source, index: index)))
                    }
                    end()
                } else { try await Task.sleep(for: .seconds(1.0)); end() }
            } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            if let item = note.object as? AVPlayerItem, item === player?.currentItem { end() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            if let item = note.object as? AVPlayerItem, item === player?.currentItem { end() }
        }
        .onChange(of: phase, initial: true) { _, value in
            active = value == .active
            if active { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
    private func end() { guard !ended else { return }; ended = true; player?.pause(); finish() }
}
