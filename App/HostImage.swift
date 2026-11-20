import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct HostImage: Codable, Equatable {
    let id: String
    let mediaType: String
    let bytes: Int
    let width: Int
    let height: Int
    let name: String?
    let originalDimensions: [String: Int]?

    init?(_ object: Object) {
        guard let id = object["attachmentId"] as? String, !id.isEmpty,
              let mediaType = object["mediaType"] as? String, ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mediaType),
              let bytes = object["bytes"] as? Int, bytes > 0, let width = object["width"] as? Int, width > 0,
              let height = object["height"] as? Int, height > 0 else { return nil }
        self.id = id; self.mediaType = mediaType; self.bytes = bytes; self.width = width; self.height = height
        name = object["name"] as? String
        if let size = object["originalDimensions"] as? [String: Int], let w = size["width"], w > 0, let h = size["height"], h > 0 {
            originalDimensions = ["width": w, "height": h]
        } else { originalDimensions = nil }
    }

    static func references(_ blocks: [Object]) -> [Self] {
        blocks.compactMap { block in
            guard block["type"] as? String == "image", let reference = block["attachment"] as? Object else { return nil }
            return Self(reference)
        }
    }

    var wire: Object {
        var value: Object = ["attachmentId": id, "mediaType": mediaType, "bytes": bytes, "width": width, "height": height]
        value["name"] = name
        value["originalDimensions"] = originalDimensions
        return value
    }

    func data(from reply: Object) throws -> Data {
        guard let object = reply["attachment"] as? Object, let ref = Self(object),
              ref.id == id, ref.mediaType == mediaType, ref.bytes == bytes, ref.width == width, ref.height == height,
              let encoded = reply["data"] as? String, bytes <= 32 * 1024 * 1024, encoded.utf8.count == 4 * ((bytes + 2) / 3),
              let data = Data(base64Encoded: encoded), data.count == bytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, UTType(type)?.preferredMIMEType == mediaType,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              props[kCGImagePropertyPixelWidth as String] as? Int == width,
              props[kCGImagePropertyPixelHeight as String] as? Int == height else { throw HostError(String(localized: "图片内容与对话中的附件记录不符。")) }
        return data
    }

    nonisolated static func render(_ data: Data, maxPixels: Int) -> PlatformImage? {
        ImageTiming.measure("thumb", "px=\(maxPixels) bytes=\(data.count)") { decode(data, maxPixels: maxPixels) }
    }

    /// The size a picture of `pixels` is shown at in a message: as large as fits 240 × 160.
    nonisolated static func fitted(_ pixels: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 120, height: 90) }
        let scale = min(240 / pixels.width, 160 / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }

    /// Pixel size from the file's header, without decoding it.
    nonisolated static func pixelSize(_ data: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              var width = props[kCGImagePropertyPixelWidth as String] as? CGFloat,
              var height = props[kCGImagePropertyPixelHeight as String] as? CGFloat else { return .zero }
        if let orientation = props[kCGImagePropertyOrientation as String] as? Int, orientation >= 5 { swap(&width, &height) }
        return CGSize(width: width, height: height)
    }

    /// Thumbnails already drawn, so a picture moving from the tray to the sent message and then to
    /// the host's echo shows at once each time instead of blinking empty while it decodes again.
    private static let shown: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private nonisolated static func keep(_ image: PlatformImage, _ key: String) {
        #if os(macOS)
        let cost = Int(image.size.width * image.size.height) * 4
        #else
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        #endif
        shown.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// A picked picture's thumbnail (600 px, enough for the tray and the message), if drawn already.
    nonisolated static func shownThumbnail(_ item: DraftAttachment) -> PlatformImage? { shown.object(forKey: "draft:\(item.id)" as NSString) }

    nonisolated static func thumbnail(_ item: DraftAttachment) async -> PlatformImage? {
        if let ready = shownThumbnail(item) { return ready }
        guard let data = item.imageData, let image = await thumbnail(data, maxPixels: 600) else { return nil }
        keep(image, "draft:\(item.id)")
        return image
    }

    nonisolated static func shownThumbnail(_ ref: HostImage) -> PlatformImage? { shown.object(forKey: "ref:\(ref.id)" as NSString) }

    /// The host echoed a sent message: its images are the picked ones, in tray order.
    nonisolated static func adopt(_ drafts: [DraftAttachment], as refs: [HostImage]) {
        let pictures = drafts.filter(\.isImage)
        guard pictures.count == refs.count else { return }
        for (item, ref) in zip(pictures, refs) { if let image = shownThumbnail(item) { keep(image, "ref:\(ref.id)") } }
    }

    /// `render` off the main thread, for thumbnails drawn while the chat scrolls or a photo is added.
    nonisolated static func thumbnail(_ data: Data, maxPixels: Int) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) { render(data, maxPixels: maxPixels) }.value
    }

    private nonisolated static func decode(_ data: Data, maxPixels: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let bitmap = RasterFrames.frame(source, 0, pixels: maxPixels) else { return nil }
        return platformImage(bitmap)
    }

    nonisolated static func platformImage(_ bitmap: CGImage) -> PlatformImage {
        #if os(macOS)
        PlatformImage(cgImage: bitmap, size: .zero)
        #else
        PlatformImage(cgImage: bitmap)
        #endif
    }
}

/// A file attached to a user message, shown above the bubble.
struct FileAttachmentCard: View {
    let name: String
    var body: some View {
        let ext = (name as NSString).pathExtension.uppercased()
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").font(.system(size: 17)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.subheadline).foregroundStyle(ChatColors.ink).lineLimit(1).truncationMode(.middle)
                Text(ext.isEmpty ? String(localized: "文件") : ext).font(.caption).foregroundStyle(ChatColors.muted)
            }
        }
        .padding(8).padding(.trailing, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.55))
        .accessibilityElement(children: .combine)
    }
}

/// A photo picked on this phone, shown above the bubble until the host echoes it. Same size and
/// place as the echoed one (`HostImageCell`), so nothing moves when it is swapped in.
struct LocalImageThumb: View {
    let item: DraftAttachment
    private let size: CGSize
    @State private var image: PlatformImage?
    init(item: DraftAttachment) {
        self.item = item
        size = HostImage.fitted(HostImage.pixelSize(item.imageData ?? Data()))
        _image = State(initialValue: HostImage.shownThumbnail(item))
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ChatColors.chip)
            if let image { Image(platformImage: image).resizable().scaledToFill() }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("图片")
        .task { if image == nil { image = await HostImage.thumbnail(item) } }
    }
}

struct HostImageGallery: View {
    let host: Harness
    let images: [HostImage]
    /// Side of the square each image is cropped to in a grid of several; nil shows it whole.
    var square: CGFloat? = nil
    var body: some View {
        ForEach(images.indices, id: \.self) { index in
            HostImageCell(host: host, ref: images[index], square: square).id(images[index].id)
        }
    }
}

private struct HostImageCell: View {
    let host: Harness
    let ref: HostImage
    let square: CGFloat?
    @State private var thumbnail: PlatformImage?
    @State private var issue: String?
    @State private var revision = 0
    @State private var open = false
    init(host: Harness, ref: HostImage, square: CGFloat?) {
        self.host = host; self.ref = ref; self.square = square
        _thumbnail = State(initialValue: HostImage.shownThumbnail(ref))
    }
    /// Known from the attachment record before any byte arrives, so loading never changes the layout.
    private var size: CGSize {
        if let square { return CGSize(width: square, height: square) }
        return HostImage.fitted(CGSize(width: ref.width, height: ref.height))
    }
    @ViewBuilder var body: some View {
        #if os(macOS)
        tile.sheet(isPresented: $open) { preview.frame(minWidth: 460, minHeight: 340) }
        #else
        tile.fullScreenCover(isPresented: $open) { preview }
        #endif
    }

    private var preview: some View {
        AttachmentPreview(title: ref.name ?? String(localized: "图片"), dimensions: "\(ref.width) × \(ref.height)", thumbnail: thumbnail) {
            try await host.imageData(ref)
        }
    }

    private var tile: some View {
        Group {
            if let thumbnail {
                Button { open = true } label: {
                    Image(platformImage: thumbnail).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }.buttonStyle(.plain).accessibilityLabel("查看图片").accessibilityValue(ref.name ?? "")
            } else if let issue {
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue).font(.caption)
                    Button("重试图片") { revision += 1 }
                }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ChatColors.chip)
                    .frame(width: size.width, height: size.height)
                    .accessibilityLabel("读取图片")
            }
        }
        .task(id: revision) {
            if revision == 0, thumbnail != nil { return }
            issue = nil
            do {
                let data = try await host.imageData(ref)
                try Task.checkCancellation()
                guard let image = await HostImage.thumbnail(data, maxPixels: 600), !Task.isCancelled else { throw HostError(String(localized: "无法显示这张图片。")) }
                thumbnail = image
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
}

struct AttachmentPreview: View {
    let title: String
    let dimensions: String
    let thumbnail: PlatformImage?
    let load: () async throws -> Data
    @State private var image: PlatformImage?
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let picture = image ?? thumbnail { ZoomImage(image: picture).accessibilityLabel("图片预览") }
            }
            .safeAreaInset(edge: .bottom) {
                if issue != nil || !dimensions.isEmpty {
                    Text(issue ?? dimensions).font(.caption).foregroundStyle(.white).padding(8)
                        .background(.black.opacity(0.7), in: Capsule())
                }
            }
            .navigationTitle(title).inlineNavigationTitle()
            .toolbar { Button("完成") { dismiss() }.accessibilityIdentifier("closeHostImage") }
        }.preferredColorScheme(.dark)
        .task {
            do {
                let data = try await load()
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw HostError(String(localized: "无法显示大图。")) }
                let count = CGImageSourceGetCount(source)
                repeat {
                    for i in 0..<count {
                        try Task.checkCancellation()
                        guard let frame = RasterFrames.frame(source, i, pixels: 4096) else { throw HostError(String(localized: "无法读取图片帧。")) }
                        image = HostImage.platformImage(frame)
                        if count > 1 { try await Task.sleep(for: .seconds(RasterFrames.frameDelay(source, index: i))) }
                    }
                } while count > 1
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
}

#if os(macOS)
private struct ZoomImage: View {
    let image: PlatformImage
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { bounds in
            let fit = min(bounds.size.width / max(1, image.size.width), bounds.size.height / max(1, image.size.height))
            let scale = fit * clamped(zoom * pinch)
            ScrollView([.horizontal, .vertical]) {
                Image(platformImage: image).resizable()
                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                    .frame(minWidth: bounds.size.width, minHeight: bounds.size.height)
            }
            .defaultScrollAnchor(.center)
            .simultaneousGesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { zoom = clamped(zoom * $0.magnification) })
            .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2.5 }
            .accessibilityIdentifier("zoomedHostImage")
            .accessibilityValue("\(Int((zoom * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: zoom = clamped(zoom + 0.5)
                case .decrement: zoom = clamped(zoom - 0.5)
                @unknown default: break
                }
            }
        }
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(5, max(1, value)) }
}
#else
private struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    final class Surface: UIScrollView, UIScrollViewDelegate {
        let picture = UIImageView()
        private var lastSize = CGSize.zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self; maximumZoomScale = 5
            contentInsetAdjustmentBehavior = .never
            isAccessibilityElement = true; accessibilityTraits = [.image, .adjustable]
            accessibilityIdentifier = "zoomedHostImage"; accessibilityLabel = String(localized: "图片预览"); accessibilityValue = "100%"
            showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
            addSubview(picture)
            let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = picture.image, bounds.size != lastSize else { return }
            lastSize = bounds.size
            setZoomScale(1, animated: false)
            let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
            picture.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio))
            contentSize = picture.frame.size
            centerImage()
        }
        func update(_ image: UIImage) {
            guard picture.image !== image else { return }
            let resized = picture.image?.size != image.size
            picture.image = image
            if resized { lastSize = .zero; setNeedsLayout() }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
            accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
        }
        override func accessibilityIncrement() { setZoomScale(min(maximumZoomScale, zoomScale + 0.5), animated: true) }
        override func accessibilityDecrement() { setZoomScale(max(1, zoomScale - 0.5), animated: true) }
        private func centerImage() {
            let x = max(0, (bounds.width - contentSize.width) / 2), y = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }
        @objc private func doubleTap(_ tap: UITapGestureRecognizer) {
            if zoomScale > 1 { setZoomScale(1, animated: true); return }
            let point = tap.location(in: picture), size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.update(image) }
}
#endif
