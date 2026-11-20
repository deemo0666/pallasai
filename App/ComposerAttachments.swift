import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Something picked in the composer and not sent yet. Images the host takes inline (PNG, JPEG,
/// WebP, GIF) ride in the prompt itself; anything else is uploaded first and referenced by its
/// receipt. Which one is decided from the bytes.
struct DraftAttachment: Identifiable, Equatable {
    enum Body {
        case image(Data, mediaType: String)
        /// A file from the system picker (security scoped), read when the message is sent.
        case file(URL)
    }

    let id: UUID
    let name: String
    let body: Body
    let size: Int
    private var temporaryFile: TemporaryFile?

    init(name: String, body: Body, size: Int) {
        id = UUID(); self.name = name; self.body = body; self.size = size
    }

    var isImage: Bool { if case .image = body { true } else { false } }
    var imageData: Data? { if case .image(let data, _) = body { data } else { nil } }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    private final class TemporaryFile {
        let directory: URL
        init(directory: URL) { self.directory = directory }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// The draft and any queued prompt keep this file alive until they release the attachment.
    static func temporaryFile(_ data: Data, name: String) throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let temporary = TemporaryFile(directory: directory)
        let url = directory.appending(path: name)
        try data.write(to: url, options: .atomic)
        var attachment = try file(url)
        attachment.temporaryFile = temporary
        return attachment
    }

    /// At most this many attachments per message.
    static let limit = 9
    /// The host's inline image limit.
    static let maxImageBytes = 20 * 1024 * 1024
    /// Uploads stream from the file, but one message still has a ceiling.
    static let maxFileBytes = 200 * 1024 * 1024

    /// Media type when `bytes` start like an image the host accepts inline.
    static func inlineImageType(_ bytes: Data) -> String? {
        let head = [UInt8](bytes.prefix(12))
        func at(_ offset: Int, _ sig: [UInt8]) -> Bool {
            head.count >= offset + sig.count && Array(head[offset..<offset + sig.count]) == sig
        }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if at(0, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if at(0, [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return nil
    }

    /// The long side a photo is sent at.
    static let photoPixels = 2560

    /// A photo from the library: read straight down to at most 2560 px on the long side (ImageIO
    /// never decodes the full picture) and re-encoded as JPEG, which also turns HEIC into something
    /// the host takes. Slow work: call it off the main thread.
    nonisolated static func photo(_ data: Data, name: String? = nil) -> DraftAttachment? {
        ImageTiming.measure("photo", "bytes=\(data.count)") {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: photoPixels,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            return jpeg(picture, name: name)
        }
    }

    #if os(iOS)
    /// A photo from the camera, the same way. Also slow: call it off the main thread.
    nonisolated static func photo(_ image: UIImage, name: String? = nil) -> DraftAttachment? {
        ImageTiming.measure("photo", "camera") {
            let longest = max(image.size.width * image.scale, image.size.height * image.scale)
            guard longest > 0 else { return nil }
            let ratio = min(1, CGFloat(photoPixels) / longest)
            let size = CGSize(width: (image.size.width * image.scale * ratio).rounded(), height: (image.size.height * image.scale * ratio).rounded())
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            // Drawing also applies the camera's orientation.
            let picture = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let bitmap = picture.cgImage else { return nil }
            return jpeg(bitmap, name: name)
        }
    }
    #endif

    /// JPEG at quality 0.85 with no metadata (no location or camera details leave the phone).
    private nonisolated static func jpeg(_ picture: CGImage, name: String?) -> DraftAttachment? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length > 0 else { return nil }
        let data = out as Data
        return DraftAttachment(name: name ?? "photo-\(Self.stamp())-\(UUID().uuidString.prefix(4).lowercased()).jpg", body: .image(data, mediaType: "image/jpeg"), size: data.count)
    }

    /// A file from the system picker: an inline image when its bytes say so, else a file to upload.
    static func file(_ url: URL) throws -> DraftAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw HostError(String(localized: "无法读取「\(name)」。")) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        guard !head.isEmpty else { throw HostError(String(localized: "「\(name)」是空文件。")) }
        if let type = inlineImageType(head), size <= maxImageBytes {
            try handle.seek(toOffset: 0)
            guard let data = try handle.readToEnd(), !data.isEmpty else { throw HostError(String(localized: "无法读取「\(name)」。")) }
            return DraftAttachment(name: name, body: .image(data, mediaType: type), size: data.count)
        }
        guard size <= maxFileBytes else { throw HostError(String(localized: "「\(name)」超过 200 MB，无法发送。")) }
        return DraftAttachment(name: name, body: .file(url), size: size)
    }

    /// An image read back from the conversation (重新回答、编辑后重发).
    static func echoed(_ ref: HostImage, data: Data, index: Int) -> DraftAttachment {
        let ext = ["image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"][ref.mediaType] ?? "png"
        let given = ref.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DraftAttachment(name: given.isEmpty ? "image-\(index + 1).\(ext)" : given,
                               body: .image(data, mediaType: inlineImageType(data) ?? ref.mediaType), size: data.count)
    }

    private nonisolated static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: Date())
    }

    /// "1.2 MB", "860 KB", "12 B".
    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return "\(Int((Double(count) / 1024).rounded())) KB" }
        let mb = Double(count) / 1024 / 1024
        return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
    }
}

extension Conversation {
    /// Room left in the tray.
    var attachmentRoom: Int { max(0, DraftAttachment.limit - attachments.count) }

    /// Adds to the end of the tray, up to the limit; says what did not fit.
    func attach(_ items: [DraftAttachment]) {
        let room = attachmentRoom
        attachments += items.prefix(room)
        if items.count > room { notice = String(localized: "每条消息最多 \(DraftAttachment.limit) 个附件。") }
    }

    func attach(files urls: [URL]) {
        var picked: [DraftAttachment] = []
        var problem: String?
        for url in urls {
            do { picked.append(try DraftAttachment.file(url)) } catch { problem = problem ?? (error as? HostError)?.message }
        }
        attach(picked)
        if let problem { notice = problem }
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }
}

extension Harness {
    /// `session/prompt` with the attachments in tray order after the text: images inline, files by
    /// their upload receipt.
    ///
    /// A model that reads text only refuses images at admission, recording nothing; the same request
    /// then goes again with the images uploaded as files, so the message still lands and tools can
    /// open them. Returns whether that happened.
    @discardableResult
    func prompt(_ text: String, attachments: [DraftAttachment], requestID: UUID, mode: String = "queue") async throws -> Bool {
        let targetSession = sessionID
        let generation = sessionGeneration
        var staged: [UUID: Object] = [:]
        for attachment in attachments {
            guard case .file(let url) = attachment.body else { continue }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard sessionID == targetSession, sessionGeneration == generation else { throw HostError(String(localized: "设备对话已切换。")) }
            staged[attachment.id] = Self.block(try await upload(file: url))
        }
        func content() -> [Object] {
            var blocks: [Object] = text.isEmpty ? [] : [["type": "text", "text": text]]
            for attachment in attachments {
                if let block = staged[attachment.id] { blocks.append(block); continue }
                if case .image(let data, let type) = attachment.body {
                    let encoded = ImageTiming.measure("base64", "bytes=\(data.count)") { data.base64EncodedString() }
                    blocks.append(["type": "image", "mediaType": type, "data": encoded, "name": attachment.name])
                }
            }
            return blocks
        }
        func submit() async throws {
            guard sessionID == targetSession, sessionGeneration == generation else { throw HostError(String(localized: "设备对话已切换。")) }
            let receipt = try await ImageTiming.measure("prompt-call") { try await call("session/prompt", ["sessionId": sessionID, "requestId": requestID.uuidString,
                "mode": mode, "content": content(), "clientTimeZone": TimeZone.current.identifier]) }
            guard receipt["accepted"] as? Bool == true else { throw HostError(String(localized: "没收到设备的确认，消息可能没发出去。")) }
        }
        do {
            try await submit()
            return false
        } catch let refusal as HostError where refusal.code == "session/attachment-invalid"
                    && (refusal.detail ?? "").contains("image input") && attachments.contains(where: \.isImage) {
            for attachment in attachments {
                guard case .image(let data, _) = attachment.body else { continue }
                let folder = FileManager.default.temporaryDirectory.appending(path: "prompt-" + attachment.id.uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let file = folder.appending(path: attachment.name)
                try data.write(to: file)
                guard sessionID == targetSession, sessionGeneration == generation else { throw HostError(String(localized: "设备对话已切换。")) }
                staged[attachment.id] = Self.block(try await upload(file: file))
            }
            try await submit()
            return true
        }
    }

    private static func block(_ reference: HostFileReference) -> Object {
        switch reference {
        case .receipt(let id): ["type": "file", "receiptId": id]
        }
    }
}

// MARK: - Tray

/// Picked-but-unsent attachments, in a strip above the composer's text; each tile removes itself.
struct ComposerTray: View {
    let items: [DraftAttachment]
    let remove: (DraftAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    DraftTile(item: item)
                        .padding(.top, 8).padding(.trailing, 8)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(item) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ChatColors.chip)
                                    .frame(width: 20, height: 20)
                                    .background(ChatColors.ink.opacity(0.72), in: Circle())
                                    .overlay(Circle().strokeBorder(ChatColors.chip, lineWidth: 1.5))
                                    .padding(4).contentShape(Rectangle())
                            }.buttonStyle(.plain).offset(x: 4, y: -4)
                                .accessibilityLabel("移除附件 \(item.name)").accessibilityIdentifier("removeAttachment")
                        }
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }.padding(.horizontal, 6).padding(.top, 2)
        }
        .frame(height: 70)
        .animation(Motion.std(Motion.quick), value: items.map(\.id))
        .accessibilityElement(children: .contain).accessibilityLabel("附件 \(items.count) 个").accessibilityIdentifier("composerTray")
    }
}

private struct DraftTile: View {
    let item: DraftAttachment
    @State private var thumbnail: PlatformImage?
    init(item: DraftAttachment) {
        self.item = item
        _thumbnail = State(initialValue: HostImage.shownThumbnail(item))
    }

    var body: some View {
        Group {
            if item.isImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ChatColors.chip)
                    if let thumbnail { Image(platformImage: thumbnail).resizable().scaledToFill() }
                }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .task(id: item.id) { if thumbnail == nil { thumbnail = await HostImage.thumbnail(item) } }
                .accessibilityElement().accessibilityLabel("图片 \(item.name)")
            } else {
                let ext = (item.name as NSString).pathExtension.uppercased()
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill").font(.system(size: 16)).foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.name).font(.caption.weight(.medium)).foregroundStyle(ChatColors.ink).lineLimit(1).truncationMode(.middle)
                        Text((ext.isEmpty ? String(localized: "文件") : ext) + " · " + DraftAttachment.bytes(item.size)).font(.caption2).foregroundStyle(ChatColors.muted)
                    }
                }
                .padding(.horizontal, 8).frame(width: 168, height: 56, alignment: .leading)
                .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.55))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Images of a user message still on its way: one at its own aspect, several as a grid of squares.
struct DraftImageStack: View {
    /// Square side in a grid of several, the same once the host echoes them.
    static let side: CGFloat = 96
    let images: [DraftAttachment]
    var body: some View {
        if images.count == 1, let item = images.first {
            LocalImageThumb(item: item)
        } else if !images.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.side), spacing: 6), count: min(3, images.count)), alignment: .trailing, spacing: 6) {
                ForEach(images) { SquareThumb(item: $0) }
            }.fixedSize()
        }
    }
}

private struct SquareThumb: View {
    let item: DraftAttachment
    @State private var image: PlatformImage?
    init(item: DraftAttachment) {
        self.item = item
        _image = State(initialValue: HostImage.shownThumbnail(item))
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ChatColors.chip)
            if let image { Image(platformImage: image).resizable().scaledToFill() }
        }
        .frame(width: DraftImageStack.side, height: DraftImageStack.side).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("图片")
        .task { if image == nil { image = await HostImage.thumbnail(item) } }
    }
}
