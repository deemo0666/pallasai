import CryptoKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SharedLink: Identifiable, Codable {
    let id: UUID
    let origin: URL
    let remoteID: String
    let title: String
    let expiresAt: String?
    var removalDeadline: Date?
    var removalConfirmed: Bool?
    var expiration: Date? {
        guard let expiresAt else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = parser.date(from: expiresAt) { return value }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: expiresAt)
    }
    func expiryLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = expiration else { return expiresAt == nil ? String(localized: "永久有效") : String(localized: "到期时间未知") }
        if date <= now { return String(localized: "已过期") }
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天到期") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return String(localized: "明天到期") }
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let month = String(localized: "\(day.month ?? 1)月\(day.day ?? 1)日")
        return (calendar.component(.year, from: now) == day.year ? month : String(localized: "\(day.year ?? 0)年") + month) + String(localized: "到期")
    }
    func isExpired(now: Date = Date()) -> Bool { expiration.map { $0 <= now } ?? false }
    /// `example.com/c/a1B2c3D4e5`: the link without its scheme and key.
    var display: String { (origin.host ?? "") + (origin.port.map { ":\($0)" } ?? "") + "/c/" + remoteID }
    var recordKey: String { "shared-link/" + id.uuidString }
    func link() throws -> URL {
        let key = try Vault.read(recordKey + "/key")
        guard !key.isEmpty, var parts = URLComponents(url: origin.appending(path: "c/" + remoteID), resolvingAgainstBaseURL: false) else { throw HostError(String(localized: "无法读取链接密钥。")) }
        parts.fragment = "k=" + key
        guard let url = parts.url else { throw HostError(String(localized: "分享链接无效。")) }
        return url
    }
}

enum HostedShares {
    static func origin(_ input: String) throws -> URL {
        guard let url = URL(string: input), (url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1")), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw HostError(String(localized: "请输入分享服务的 HTTPS 地址。")) }
        return url
    }
    static func seal(_ file: Data) throws -> (Data, String) {
        let key = SymmetricKey(size: .bits256)
        let compressed = try ReplayDocument.transcode(file, compress: true, gzip: true)
        guard let combined = try AES.GCM.seal(compressed, using: key).combined else { throw HostError(String(localized: "无法加密对话。")) }
        return (Data("DSG1".utf8) + combined, key.withUnsafeBytes { ReplayDocument.pack(Data($0)) })
    }
    static func unseal(_ bytes: Data, key: String) throws -> Data {
        guard bytes.starts(with: Data("DSG1".utf8)), let raw = ReplayDocument.unpack(key), raw.count == 32 else { throw HostError(String(localized: "链接密钥或文件格式无效。")) }
        let box = try AES.GCM.SealedBox(combined: bytes.dropFirst(4))
        let compressed = try AES.GCM.open(box, using: SymmetricKey(data: raw))
        return try ReplayDocument.transcode(compressed, compress: false, gzip: true)
    }

    private static func send(_ request: URLRequest, limit: Int, status: Int, allowMissing: Bool = false) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if allowMissing, (response as? HTTPURLResponse)?.statusCode == 404 { return Data() }
        if request.httpMethod == "GET", (response as? HTTPURLResponse)?.statusCode == 404 {
            throw HostError(String(localized: "链接已过期或已被删除（HTTP 404）。"), code: "share/not-found")
        }
        guard let reply = response as? HTTPURLResponse, reply.statusCode == status else {
            throw HostError(String(localized: "分享服务返回 HTTP ") + String((response as? HTTPURLResponse)?.statusCode ?? 0) + String(localized: "。"))
        }
        guard response.expectedContentLength <= limit else { throw HostError(String(localized: "分享文件过大。")) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw HostError(String(localized: "分享文件过大。")) }
            data.append(byte)
        }
        return data
    }

    static func publish(file: Data, title: String, service: URL, ttl: String) async throws -> SharedLink {
        let (cipher, key) = try seal(file)
        var request = URLRequest(url: service.appending(path: "api/v1/c").appending(queryItems: [URLQueryItem(name: "ttl", value: ttl)]))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = cipher
        let receipt = try await send(request, limit: 16384, status: 201)
        guard let record = try JSONSerialization.jsonObject(with: receipt) as? Object, let id = record["id"] as? String,
              validID(id), let token = record["deleteToken"] as? String, !token.isEmpty else { throw HostError(String(localized: "分享服务未返回有效的管理凭据。")) }
        let entry = SharedLink(id: UUID(), origin: service, remoteID: id, title: title, expiresAt: record["expiresAt"] as? String)
        do {
            try Vault.save(token, account: entry.recordKey + "/delete")
            try Vault.save(key, account: entry.recordKey + "/key")
        } catch {
            try await revoke(entry, token: token)
            throw error
        }
        return entry
    }

    static func revoke(_ entry: SharedLink, token: String) async throws {
        guard !token.isEmpty else { throw HostError(String(localized: "缺少删除凭据。")) }
        var request = URLRequest(url: entry.origin.appending(path: "api/v1/c/" + entry.remoteID))
        request.httpMethod = "DELETE"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        _ = try await send(request, limit: 1024, status: 204, allowMissing: true)
    }

    struct Download {
        let endpoint: URL
        fileprivate let key: String

        init(_ link: String) throws {
            guard var parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let fragment = parts.fragment, fragment.hasPrefix("k=") else {
                throw HostError(String(localized: "链接缺少密钥。"))
            }
            let path = parts.path.split(separator: "/")
            guard parts.query == nil, path.count == 2, path[0] == "c", HostedShares.validID(String(path[1])) else {
                throw HostError(String(localized: "无效的分享地址。"))
            }
            let key = String(fragment.dropFirst(2))
            guard key.utf8.count == 43, ReplayDocument.unpack(key)?.count == 32 else {
                throw HostError(String(localized: "链接密钥无效。"))
            }
            let scheme = parts.scheme?.lowercased()
            parts.scheme = scheme == "dshlocal" ? "https" : scheme
            parts.path = ""
            parts.fragment = nil
            let service = try HostedShares.origin(parts.string ?? "")
            endpoint = service.appending(path: "api/v1/c/" + path[1])
            self.key = key
        }
    }

    static func open(_ link: String) async throws -> ReplayDocument {
        let download = try Download(link)
        let data = try await send(URLRequest(url: download.endpoint), limit: 20 * 1024 * 1024, status: 200)
        try Task.checkCancellation()
        do { return try ReplayDocument.decode(unseal(data, key: download.key)) }
        catch CryptoKitError.authenticationFailure { throw HostError(String(localized: "链接不完整，或密钥与对话不匹配。"), code: "share/key-invalid") }
    }

    fileprivate static func validID(_ id: String) -> Bool {
        id.utf8.count == 10 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
}

/// App handoffs, website share links with a key, and the original inline share format.
enum ReplayLink {
    case hosted(URL)
    case inline(String)

    init?(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        let path = url.path.split(separator: "/")
        if scheme == "dshlocal" {
            if url.path.hasPrefix("/c/") { self = .hosted(url); return }
            guard url.host == "share", url.user == nil, url.password == nil, url.query == nil,
                  url.fragment == nil, path.count == 1, path[0].contains(".") else { return nil }
            self = .inline(String(path[0]))
        } else {
            guard (scheme == "https" || (scheme == "http" && url.host == "127.0.0.1")),
                  url.fragment?.hasPrefix("k=") == true, path.count == 2, path[0] == "c",
                  HostedShares.validID(String(path[1])) else { return nil }
            self = .hosted(url)
        }
    }

    func open() async throws -> ReplayDocument {
        switch self {
        case .hosted(let url):
            return try await HostedShares.open(url.absoluteString)
        case .inline(let code):
            let data = try JSONSerialization.data(withJSONObject: ["code": code])
            return try ReplayDocument.decode(data)
        }
    }

    static func open(_ text: String) async throws -> ReplayDocument {
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let link = Self(url) {
            return try await link.open()
        }
        return try await HostedShares.open(text)
    }
}

@MainActor
final class HostedLibrary: ObservableObject {
    static let shared = HostedLibrary()
    private let key = "sharedLinks"
    private let defaults: UserDefaults
    @Published private(set) var entries: [SharedLink] = []
    var pending: SharedLink? { entries.first { $0.removalDeadline != nil } }
    @Published private(set) var deleting = false
    @Published var issue: String?
    private var removal: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let bytes = defaults.data(forKey: key) else { return }
        do { entries = try JSONDecoder().decode([SharedLink].self, from: bytes) } catch { issue = String(localized: "无法读取分享链接列表。") }
    }

    func resume() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let expired = entries.filter { $0.removalDeadline == nil && ($0.expiration ?? .distantFuture) < cutoff }
        if !expired.isEmpty {
            do {
                for entry in expired {
                    for suffix in ["/key", "/delete"] { try Vault.save("", account: entry.recordKey + suffix) }
                }
                let ids = Set(expired.map(\.id))
                try persist(entries.filter { !ids.contains($0.id) })
            } catch { issue = error.localizedDescription }
        }
        guard removal == nil, let entry = pending else { return }
        schedule(entry)
    }

    private func savedEntries() throws -> [SharedLink] {
        try defaults.data(forKey: key).map { try JSONDecoder().decode([SharedLink].self, from: $0) } ?? []
    }

    func add(_ entry: SharedLink) throws { try persist([entry] + savedEntries()) }

    func publish(file: Data, title: String, service: URL, ttl: String) async throws -> SharedLink {
        _ = try savedEntries()
        let entry = try await HostedShares.publish(file: file, title: title, service: service, ttl: ttl)
        do { try add(entry) }
        catch {
            try await HostedShares.revoke(entry, token: Vault.read(entry.recordKey + "/delete"))
            for suffix in ["/key", "/delete"] { try Vault.save("", account: entry.recordKey + suffix) }
            throw error
        }
        return entry
    }

    func removeAfterDelay(_ entry: SharedLink) {
        guard pending == nil, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        do {
            var updated = entries
            updated[index].removalDeadline = Date().addingTimeInterval(4)
            try persist(updated)
            issue = nil
            schedule(updated[index])
        } catch { issue = error.localizedDescription }
    }

    private func schedule(_ entry: SharedLink) {
        guard let deadline = entry.removalDeadline else { return }
        removal = Task {
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard !Task.isCancelled, pending?.id == entry.id else { return }
            deleting = true
            defer { deleting = false; removal = nil }
            do {
                if entry.removalConfirmed != true {
                    try await HostedShares.revoke(entry, token: Vault.read(entry.recordKey + "/delete"))
                    var updated = entries
                    guard let index = updated.firstIndex(where: { $0.id == entry.id }) else { return }
                    updated[index].removalConfirmed = true
                    try persist(updated)
                }
                for suffix in ["/key", "/delete"] { try Vault.save("", account: entry.recordKey + suffix) }
                try persist(entries.filter { $0.id != entry.id })
            } catch {
                if pending?.removalConfirmed == true { issue = error.localizedDescription; return }
                let failure = error.localizedDescription
                do { try clearDeadline(entry.id); issue = failure }
                catch { issue = failure + " " + error.localizedDescription }
            }
        }
    }

    func undo() {
        guard !deleting, let entry = pending, entry.removalConfirmed != true, let deadline = entry.removalDeadline, Date() < deadline else { return }
        do {
            try clearDeadline(entry.id)
            removal?.cancel(); removal = nil
        } catch { issue = error.localizedDescription }
    }

    private func clearDeadline(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[index].removalDeadline = nil
        try persist(updated)
    }

    private func persist(_ updated: [SharedLink]) throws {
        defaults.set(try JSONEncoder().encode(updated), forKey: key)
        entries = updated
    }
}


enum ShareQR {
    /// A QR code for [url], black on white with a four-module margin, [scale] pixels a module.
    static func render(_ url: URL, scale: CGFloat = 8) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let area = code.extent.insetBy(dx: -4, dy: -4)
        let padded = code.composited(over: CIImage(color: .white).cropped(to: area))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let bitmap = CIContext().createCGImage(padded, from: padded.extent) else { return nil }
        return HostImage.platformImage(bitmap)
    }
}

/// 「二维码」: the link as a code on a white card, the title under it.
struct ShareQRPage: View {
    let link: URL
    let title: String
    @State private var image: PlatformImage?
    var body: some View {
        VStack(spacing: 16) {
            if let image {
                Image(platformImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 248, height: 248)
                    .padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(ChatColors.line, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.06), radius: 12, y: 2)
                    .accessibilityLabel("分享码二维码")
                Text(verbatim: title).font(.headline).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 16)
            } else { Text("无法生成二维码").foregroundStyle(ChatColors.muted) }
        }.padding(.top, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 16)
            .foregroundStyle(ChatColors.ink).background(ChatColors.canvas.ignoresSafeArea())
            .navigationTitle("二维码").inlineNavigationTitle()
            .onAppear { image = ShareQR.render(link) }
    }
}

/// A link on its way out: 「已停止分享 · 撤销」 while it can still be taken back.
struct PendingShareRemoval: View {
    let entry: SharedLink
    var message = String(localized: "已停止分享")
    var undoLabel = String(localized: "撤销停止分享")
    @ObservedObject private var library = HostedLibrary.shared
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.circle").foregroundStyle(ChatColors.muted).frame(width: 24)
            Text(message).lineLimit(2)
            Spacer(minLength: 8)
            if library.deleting { ProgressView() }
            else if entry.removalConfirmed == true { Button("重试清理") { library.resume() }.buttonStyle(.borderless) }
            else { Button("撤销") { library.undo() }.buttonStyle(.borderless).frame(minHeight: 44).accessibilityLabel(undoLabel) }
        }.foregroundStyle(ChatColors.ink)
    }
}

/// A short dark capsule at the bottom of a page.
private struct ShareToast<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.subheadline).lineLimit(2)
            Spacer(minLength: 0)
            trailing()
        }.padding(.horizontal, 18).frame(minHeight: 48)
            .foregroundStyle(Color.white).tint(Color.white)
            .background(Color.black.opacity(0.82), in: Capsule())
            .padding(.horizontal, 16).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 「我的分享链接」: every link made on this phone, when it stops working, copy and delete.
/// Delete asks first, then can be undone for a few seconds before the link is removed from the service.
struct SharedLinksView: View {
    @ObservedObject private var library = HostedLibrary.shared
    @State private var deleting: SharedLink?
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    var body: some View {
        let links = library.entries.filter { $0.removalDeadline == nil }
        List {
            if links.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "link").font(.system(size: 30, weight: .light))
                    Text("还没有分享链接").font(.body)
                }.foregroundStyle(ChatColors.muted).frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear).accessibilityElement(children: .combine)
            } else {
                Section { ForEach(links) { row($0) } }.listRowBackground(ChatColors.chip)
            }
        }
        .foregroundStyle(ChatColors.ink).scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("我的分享链接").inlineNavigationTitle()
        .safeAreaInset(edge: .bottom, spacing: 0) { toast.animation(.easeOut(duration: 0.2), value: toastKey) }
        .alert("删除这个链接？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { entry in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { library.removeAfterDelay(entry) }
        } message: { entry in Text(verbatim: String(localized: "「") + entry.title + String(localized: "」的链接会立即失效")) }
        .onDisappear { copiedReset?.cancel() }
    }

    private var toastKey: String { (library.pending?.id.uuidString ?? "") + (library.issue ?? "") + (copied ? "c" : "") }

    @ViewBuilder private var toast: some View {
        if let pending = library.pending {
            ShareToast(text: library.deleting ? String(localized: "正在删除") : String(localized: "已删除链接")) {
                if library.deleting { ProgressView().tint(.white) }
                else if pending.removalConfirmed == true { Button("重试清理") { library.resume() }.fontWeight(.semibold) }
                else { Button("撤销") { library.undo() }.fontWeight(.semibold).accessibilityLabel("撤销删除链接") }
            }
        } else if let issue = library.issue {
            ShareToast(text: issue) { Button("好") { library.issue = nil }.fontWeight(.semibold) }
        } else if copied {
            ShareToast(text: String(localized: "已复制链接")) { EmptyView() }
        }
    }

    private func row(_ entry: SharedLink) -> some View {
        let expired = entry.isExpired()
        let path = entry.origin.absoluteString + "/" + entry.remoteID
        return HStack(spacing: 12) {
            Image(systemName: "link").foregroundStyle(expired ? ChatColors.muted.opacity(0.5) : ChatColors.ink).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title).lineLimit(2)
                Text(entry.expiryLabel()).font(.caption).foregroundStyle(ChatColors.muted)
            }
            Spacer(minLength: 4)
            Button { copy(entry) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 17)).foregroundStyle(ChatColors.muted.opacity(expired ? 0.4 : 1)).frame(width: 40, height: 44)
            }
                .disabled(expired).accessibilityLabel("复制链接").accessibilityIdentifier("copyShare-" + path)
            Button { deleting = entry } label: {
                Image(systemName: "trash").font(.system(size: 17)).foregroundStyle(ChatColors.muted.opacity(library.pending != nil ? 0.4 : 1)).frame(width: 40, height: 44)
            }
                .disabled(library.pending != nil).accessibilityLabel("删除").accessibilityIdentifier("deleteShare-" + path)
        }.buttonStyle(.borderless).foregroundStyle(ChatColors.ink)
    }

    private func copy(_ entry: SharedLink) {
        guard let url = try? entry.link() else { library.issue = String(localized: "无法读取链接密钥。"); return }
        PlatformPasteboard.copy(url)
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { try? await Task.sleep(for: .milliseconds(1600)); if !Task.isCancelled { copied = false } }
    }
}
