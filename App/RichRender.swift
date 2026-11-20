import SwiftUI
import UniformTypeIdentifiers
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Mermaid charts and TeX formulas, drawn by the bundled mermaid and KaTeX (`App/Render`) in one
/// off-screen web view and handed to the chat as pictures. Nothing is fetched: the page's content
/// security policy and the navigation delegate keep it to the app bundle.
@MainActor
final class RichRenderer: NSObject, WKNavigationDelegate {
    static let shared = RichRenderer()

    enum Kind: String { case mermaid, inline, display }

    struct Key: Hashable {
        let kind: Kind
        let source: String
        let dark: Bool
        /// Point size of the text around a formula (charts use their own).
        let size: Int
        let color: String
    }

    struct Picture {
        let image: PlatformImage
        /// From the top of the picture to the baseline of the text it sits in (formulas).
        let baseline: CGFloat
    }

    enum Outcome {
        case picture(Picture)
        /// Did not parse (or is too large): the reply shows the source.
        case failed(String)
    }

    private var cache: [Key: Outcome] = [:]
    private var order: [Key] = []
    private var web: WKWebView?
    private var loaded: CheckedContinuation<Bool, Never>?
    private var loadTimeout: Task<Void, Never>?
    private var ready = false
    private var tail: Task<Void, Never>?
    #if os(macOS)
    private var backingWindow: NSWindow?
    #endif

    private var pageURL: URL? { Bundle.main.url(forResource: "render", withExtension: "html") }

    func cached(_ key: Key) -> Outcome? { cache[key] }

    /// One job at a time: the page has a single stage.
    func render(_ key: Key) async -> Outcome {
        if let known = cache[key] { return known }
        let previous = tail
        let job = Task { @MainActor () -> Outcome in
            await previous?.value
            if let known = self.cache[key] { return known }
            let outcome = await self.draw(key)
            self.remember(key, outcome)
            return outcome
        }
        tail = Task { _ = await job.value }
        return await job.value
    }

    private func remember(_ key: Key, _ outcome: Outcome) {
        cache[key] = outcome
        order.append(key)
        if order.count > 160 { cache.removeValue(forKey: order.removeFirst()) }
    }

    private func page() async -> WKWebView? {
        if let web, ready { return web }
        guard let pageURL else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(macOS)
        config.preferences.inactiveSchedulingPolicy = .none
        #endif
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.navigationDelegate = self
        guard attach(view) else { return nil }
        web = view
        let success = await withCheckedContinuation { continuation in
            loaded = continuation
            loadTimeout = Task { [weak self, weak view] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                if let view { self?.finishLoading(view, success: false) }
            }
            view.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
        return success ? view : nil
    }

    private func attach(_ view: WKWebView) -> Bool {
        #if os(macOS)
        // An attached WebKit view is needed for layout and PDF export. This window never appears.
        let backing = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backing.isReleasedWhenClosed = false
        backing.isExcludedFromWindowsMenu = true
        backing.contentView = view
        backingWindow = backing
        #else
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return false }
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // Match the page's coordinates even at the window's safe area.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.contentInset = .zero
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.insertSubview(view, at: 0)
        #endif
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let bundledPage = action.request.url?.standardizedFileURL == pageURL?.standardizedFileURL
        decisionHandler(bundledPage && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(webView, success: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(webView, success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(webView, success: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(webView, success: false)
    }

    private func finishLoading(_ view: WKWebView, success: Bool) {
        guard web === view else { return }
        loadTimeout?.cancel()
        loadTimeout = nil
        ready = success
        if !success {
            view.stopLoading()
            #if os(macOS)
            backingWindow?.contentView = nil
            backingWindow = nil
            #else
            view.removeFromSuperview()
            #endif
            web = nil
        }
        let continuation = loaded
        loaded = nil
        continuation?.resume(returning: success)
    }

    private func draw(_ key: Key) async -> Outcome {
        guard let web = await page() else { return .failed(String(localized: "暂时画不出图")) }
        let job: [String: Any] = ["kind": key.kind.rawValue, "source": key.source, "dark": key.dark, "size": key.size, "color": key.color]
        let reply: Any?
        do {
            reply = try await web.callAsyncJavaScript("return await draw(job)", arguments: ["job": job], contentWorld: .page)
        } catch { return .failed(error.localizedDescription) }
        guard let result = reply as? [String: Any] else { return .failed(String(localized: "没能画出图")) }
        guard result["ok"] as? Bool == true, let width = (result["width"] as? NSNumber)?.doubleValue,
              let height = (result["height"] as? NSNumber)?.doubleValue, width > 0, height > 0 else {
            return .failed(result["error"] as? String ?? String(localized: "无法解析"))
        }
        guard width <= 6000, height <= 6000 else { return .failed(String(localized: "图太大")) }
        // The view must cover what is photographed.
        let needed = CGSize(width: max(800, ceil(width)), height: max(600, ceil(height)))
        if web.frame.size.width < needed.width || web.frame.size.height < needed.height {
            let size = CGSize(width: max(web.frame.width, needed.width), height: max(web.frame.height, needed.height))
            #if os(macOS)
            backingWindow?.setContentSize(size)
            #else
            web.frame = CGRect(origin: .zero, size: size)
            #endif
            try? await Task.sleep(for: .milliseconds(30))
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        do {
            // A web view nobody sees is drawn from low-resolution tiles, so a snapshot comes out blurred.
            // Its PDF export is drawn afresh in vector form; rasterise that at the screen's scale. Both are
            // opaque: draw on black and on white and recover the transparency from the difference, so the
            // picture sits on any wallpaper in either appearance.
            let pdf = WKPDFConfiguration()
            pdf.rect = rect
            #if os(macOS)
            let displayScale = max(2, NSScreen.main?.backingScaleFactor ?? 1)
            #else
            let displayScale = max(2, UIScreen.main.scale)
            #endif
            // Large drawings retain their point size without allocating several full display-size bitmaps.
            let scale = min(displayScale, sqrt(8_000_000 / (rect.width * rect.height)))
            _ = try? await web.evaluateJavaScript("document.documentElement.style.background = '#000'")
            let onBlack = Self.raster(try await web.pdf(configuration: pdf), points: rect.size, scale: scale,
                                      background: CGColor(gray: 0, alpha: 1))
            _ = try? await web.evaluateJavaScript("document.documentElement.style.background = '#fff'")
            let onWhite = Self.raster(try await web.pdf(configuration: pdf), points: rect.size, scale: scale,
                                      background: CGColor(gray: 1, alpha: 1))
            _ = try? await web.evaluateJavaScript("document.documentElement.style.background = 'transparent'")
            guard let onBlack, let onWhite, let bitmap = Self.matte(onBlack, onWhite) else { return .failed(String(localized: "无法生成图片")) }
            let baseline = CGFloat((result["baseline"] as? NSNumber)?.doubleValue ?? height)
            return .picture(Picture(image: Self.platformImage(bitmap, points: rect.size), baseline: baseline))
        } catch { return .failed(error.localizedDescription) }
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The first page of a PDF, filling the rectangle over the chosen matte.
    private static func raster(_ data: Data, points: CGSize, scale: CGFloat, background: CGColor) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let width = max(1, Int(ceil(points.width * scale))), height = max(1, Int(ceil(points.height * scale)))
        guard box.width > 0, box.height > 0, let context = bitmapContext(width: width, height: height) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Difference matting: on black a pixel reads `colour × alpha`, on white `colour × alpha + (1 − alpha)`.
    /// The result's scale makes its point size the photographed rectangle's.
    static func matte(_ black: PlatformImage, _ white: PlatformImage, points: CGSize) -> PlatformImage? {
        guard points.width > 0, let a = bitmap(black), let b = bitmap(white), let image = matte(a, b) else { return nil }
        return platformImage(image, points: points)
    }

    private static func matte(_ a: CGImage, _ b: CGImage) -> CGImage? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let width = a.width, height = a.height, count = width * height * 4
        func pixels(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: count)
            let ok = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return ok ? data : nil
        }
        guard var dark = pixels(a), let light = pixels(b) else { return nil }
        for i in stride(from: 0, to: count, by: 4) {
            let spread = (Int(light[i]) - Int(dark[i])) + (Int(light[i + 1]) - Int(dark[i + 1])) + (Int(light[i + 2]) - Int(dark[i + 2]))
            let alpha = UInt8(max(0, min(255, 255 - spread / 3)))
            dark[i] = min(dark[i], alpha); dark[i + 1] = min(dark[i + 1], alpha); dark[i + 2] = min(dark[i + 2], alpha)
            dark[i + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(dark) as CFData)
        guard let provider else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func bitmap(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    private static func platformImage(_ bitmap: CGImage, points: CGSize) -> PlatformImage {
        #if os(macOS)
        return NSImage(cgImage: bitmap, size: points)
        #else
        return UIImage(cgImage: bitmap, scale: CGFloat(bitmap.width) / points.width, orientation: .up)
        #endif
    }

    /// A card behind the chart keeps its lines visible in the black attachment viewer.
    static func chartCard(_ image: PlatformImage, dark: Bool) -> (image: PlatformImage, data: Data)? {
        guard let bitmap = bitmap(image), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = CGFloat(bitmap.width) / image.size.width
        let margin = max(1, Int((16 * scale).rounded()))
        let width = bitmap.width + margin * 2, height = bitmap.height + margin * 2
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        context.setFillColor(resolved(ChatColors.chip, dark: dark).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(bitmap, in: CGRect(x: margin, y: margin, width: bitmap.width, height: bitmap.height))
        guard let card = context.makeImage(), let data = RasterFrames.encode(card, as: .png) else { return nil }
        return (platformImage(card, points: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)), data)
    }

    private static func resolved(_ color: Color, dark: Bool) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        return color.resolve(in: environment)
    }

    /// `#RRGGBB` of a dynamic color in the given appearance.
    static func hex(_ color: Color, dark: Bool) -> String {
        let color = resolved(color, dark: dark)
        func byte(_ value: Float) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }
}

// MARK: - Finding formulas

/// Where the formulas are in a paragraph: `$…$`, `\(…\)` inline; `$$…$$` on one line inside a sentence too.
/// Not inside inline code; a `$` that opens with a space or closes before a digit is money, not maths.
enum MathText {
    enum Piece: Equatable { case text(String), math(String, display: Bool) }

    static func pieces(_ text: String) -> [Piece] {
        guard text.contains("$") || text.contains("\\(") else { return [.text(text)] }
        let chars = Array(text)
        var result: [Piece] = [], plain = "", i = 0
        func flush() { if !plain.isEmpty { result.append(.text(plain)); plain = "" } }
        func find(_ closing: [Character], from start: Int) -> Int? {
            var j = start
            while j + closing.count <= chars.count {
                if chars[j] == "\n" && closing != ["$", "$"] { return nil }
                if chars[j] == "\\" && closing != ["\\", ")"] { j += 2; continue }
                if Array(chars[j..<j + closing.count]) == closing { return j }
                j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                // Inline code runs to the same number of backticks.
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                var j = i + run, end: Int?
                while j < chars.count {
                    if chars[j] == "`" {
                        var other = 0
                        while j + other < chars.count, chars[j + other] == "`" { other += 1 }
                        if other == run { end = j + other; break }
                        j += other
                    } else { j += 1 }
                }
                let stop = end ?? chars.count
                plain += String(chars[i..<stop]); i = stop; continue
            }
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(", let end = find(["\\", ")"], from: i + 2) {
                    let body = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty { flush(); result.append(.math(body, display: false)); i = end + 2; continue }
                }
                plain.append(c); plain.append(chars[i + 1]); i += 2; continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$", let end = find(["$", "$"], from: i + 2) {
                    let body = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { flush(); result.append(.math(body, display: true)); i = end + 2; continue }
                }
                let opensWell = i + 1 < chars.count && !chars[i + 1].isWhitespace && chars[i + 1] != "$"
                let afterWord = i > 0 && (chars[i - 1].isLetter && chars[i - 1].isASCII || chars[i - 1].isNumber)
                if opensWell, !afterWord, let end = find(["$"], from: i + 1), end > i + 1, !chars[end - 1].isWhitespace,
                   !(end + 1 < chars.count && chars[end + 1].isNumber) {
                    flush(); result.append(.math(String(chars[(i + 1)..<end]), display: false)); i = end + 1; continue
                }
            }
            plain.append(c); i += 1
        }
        flush()
        return result
    }

    /// The source with the formulas spelled out: what VoiceOver and copying read.
    static func spoken(_ pieces: [Piece]) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .math(let tex, _): " " + tex + " "
            }
        }.joined()
    }
}

// MARK: - Views

/// A paragraph with formulas: the text as usual, each formula as a picture on the text's baseline
/// (its source, quietly, until drawn or when it does not parse).
struct MathInlineText: View {
    let markdown: String
    @Environment(\.colorScheme) private var scheme
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @State private var revision = 0

    var body: some View {
        let pieces = MathText.pieces(markdown)
        let dark = scheme == .dark
        let size = Int(typeSize.points.rounded())
        let color = RichRenderer.hex(ChatColors.ink, dark: dark)
        let _ = revision
        pieces.reduce(Text(verbatim: "")) { text, piece in
            switch piece {
            case .text(let value):
                return Text("\(text)\(AnswerInline.text(value))")
            case .math(let tex, let display):
                let key = RichRenderer.Key(kind: display ? .display : .inline, source: tex, dark: dark, size: size, color: color)
                if case .picture(let picture)? = RichRenderer.shared.cached(key) {
                    let descent = picture.image.size.height - picture.baseline
                    return Text("\(text)\(Text(Image(platformImage: picture.image)).baselineOffset(-descent))")
                }
                return Text("\(text)\(Text(verbatim: (display ? "$$" : "$") + tex + (display ? "$$" : "$")).foregroundColor(ChatColors.muted))")
            }
        }
        .accessibilityLabel(Text(verbatim: MathText.spoken(pieces)))
        .task(id: "\(markdown.hashValue)/\(dark)/\(size)") {
            // Streaming replies change every moment: draw once the text holds still.
            try? await Task.sleep(for: .milliseconds(250))
            var drew = false
            for piece in pieces {
                guard !Task.isCancelled, case .math(let tex, let display) = piece else { continue }
                let key = RichRenderer.Key(kind: display ? .display : .inline, source: tex, dark: dark, size: size, color: color)
                if RichRenderer.shared.cached(key) == nil { _ = await RichRenderer.shared.render(key); drew = true }
            }
            if drew && !Task.isCancelled { revision += 1 }
        }
    }
}

/// A `$$…$$` block: centred, scrolling sideways when wider than the column; the source when it does not parse.
struct MathBlockView: View {
    let tex: String
    let font: Font
    @Environment(\.colorScheme) private var scheme
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @State private var result: (key: RichRenderer.Key, outcome: RichRenderer.Outcome)?

    var body: some View {
        let dark = scheme == .dark
        let key = RichRenderer.Key(kind: .display, source: tex, dark: dark, size: Int(typeSize.points.rounded()),
                                   color: RichRenderer.hex(ChatColors.ink, dark: dark))
        Group {
            switch result?.key == key ? result?.outcome : RichRenderer.shared.cached(key) {
            case .picture(let picture)?:
                // Centred when it fits the column; otherwise it starts at the left edge and scrolls.
                ViewThatFits(in: .horizontal) {
                    Image(platformImage: picture.image).frame(maxWidth: .infinity)
                    ScrollView(.horizontal, showsIndicators: false) { Image(platformImage: picture.image) }
                }
                .frame(height: picture.image.size.height)
                .accessibilityElement().accessibilityLabel(Text(verbatim: String(localized: "公式 ") + tex))
                .accessibilityIdentifier("mathBlock")
            case .failed?:
                CodeBlockView(code: tex, language: "tex", font: font)
            case nil:
                Text(verbatim: "$$" + tex + "$$").font(font.monospaced()).foregroundStyle(ChatColors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: key) {
            guard RichRenderer.shared.cached(key) == nil else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let outcome = await RichRenderer.shared.render(key)
            if !Task.isCancelled { result = (key, outcome) }
        }
    }
}

/// A ```mermaid chart: drawn at its own size, sideways scrolling when wide (the side panels give way to
/// it), a tap opens it full screen; when it does not parse, the source with a note.
struct DiagramBlockView: View {
    let source: String
    let font: Font
    @Environment(\.colorScheme) private var scheme
    @State private var result: (key: RichRenderer.Key, outcome: RichRenderer.Outcome)?
    @State private var open = false

    var body: some View {
        let key = RichRenderer.Key(kind: .mermaid, source: source, dark: scheme == .dark, size: 16, color: RichRenderer.hex(ChatColors.ink, dark: scheme == .dark))
        Group {
            switch result?.key == key ? result?.outcome : RichRenderer.shared.cached(key) {
            case .picture(let picture)?:
                #if os(macOS)
                diagram(picture).sheet(isPresented: $open) { preview(picture).desktopSheet(width: 720, height: 520) }
                #else
                diagram(picture).fullScreenCover(isPresented: $open) { preview(picture) }
                #endif
            case .failed?:
                VStack(alignment: .leading, spacing: 4) {
                    Label("图表无法解析，显示源文", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("mermaidFailed")
                    CodeBlockView(code: source, language: "mermaid", font: font)
                }
            case nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在绘制图表…").font(.caption).foregroundStyle(ChatColors.muted)
                }.frame(maxWidth: .infinity, minHeight: 60)
                    .background(ChatColors.chip.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .task(id: key) {
            guard RichRenderer.shared.cached(key) == nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let outcome = await RichRenderer.shared.render(key)
            if !Task.isCancelled { result = (key, outcome) }
        }
    }

    private func diagram(_ picture: RichRenderer.Picture) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Button { open = true } label: { Image(platformImage: picture.image).padding(10) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: String(localized: "图表：") + (source.split(separator: "\n").first.map(String.init) ?? "")))
                .accessibilityIdentifier("mermaidChart")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: picture.image.size.height + 20)
        .background(ChatColors.chip.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func preview(_ picture: RichRenderer.Picture) -> some View {
        let card = RichRenderer.chartCard(picture.image, dark: scheme == .dark)
        return AttachmentPreview(title: String(localized: "图表"), dimensions: "", thumbnail: card?.image ?? picture.image) {
            guard let card else { throw HostError(String(localized: "无法显示图表。")) }
            return card.data
        }
    }
}
