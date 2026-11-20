import SwiftUI
#if os(iOS)
import Photos
#endif
import UniformTypeIdentifiers

struct TranscriptFile: Codable {
    let format: Int
    let title: String
    let turns: [LocalTurn]
}

/// How much of a conversation goes out.
private enum ShareScope: Hashable {
    /// The reply the sheet was opened from, and the question above it.
    case reply
    /// Messages picked one by one (or a stretch at once).
    case picked
    /// All of it.
    case whole

    var label: String {
        switch self {
        case .reply: String(localized: "这条回复")
        case .picked: String(localized: "选中消息")
        case .whole: String(localized: "整段对话")
        }
    }
}

/// A share card's look.
private enum ShareTemplate: String, CaseIterable, Hashable {
    case light, dark, paper, glass, card

    var label: String {
        switch self {
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        case .paper: String(localized: "纸张")
        case .glass: String(localized: "玻璃")
        case .card: String(localized: "卡片")
        }
    }

    /// The body sits on a panel over a coloured field.
    var onField: Bool { self == .glass || self == .card }
}

/// The template picked last in this app session.
@MainActor private enum ShareCardMemory {
    static var template: ShareTemplate?
}

/// What 「文件」 writes.
private enum ShareFileFormat: String, CaseIterable, Hashable {
    case file = "dshlocal", page = "html", markdown = "md"

    var label: String {
        switch self {
        case .file: String(localized: "对话文件")
        case .page: String(localized: "网页")
        case .markdown: "Markdown"
        }
    }

    var hint: String {
        switch self {
        case .file: String(localized: "在 Pallas Agent 里回放、接着聊")
        case .page: String(localized: "任何浏览器都能打开，不用联网")
        case .markdown: String(localized: "纯文本，随处可读")
        }
    }

    var type: UTType {
        switch self {
        case .file: .dshConversation
        case .page: .html
        case .markdown: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        }
    }

    /// Carries the `.dshlocal` file (and so its size limit).
    var carriesFile: Bool { self != .markdown }
}

private enum SharePage: Hashable { case pick, link, file, image, openLink, links, qr }

private enum ShareWork { case link, saving, sharing, opening }

/// The file forms of what is shared, for one scope and privacy.
private struct BuiltShare {
    let key: String
    let file: Data
    let page: Data?
    let markdown: Data

    func data(_ format: ShareFileFormat) -> Data? {
        switch format {
        case .file: file
        case .page: page
        case .markdown: markdown
        }
    }
}

/// 「分享」: what to share (the scope, what it includes, the card), then where it goes —
/// 链接, 图片, 文件, 文字 — each a page of its own.
struct TranscriptPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    var host: Harness?
    var imageSession: String?
    let title: String
    let turns: [LocalTurn]
    let focusedTurn: UUID?
    /// 「接着聊」 an imported conversation file, its turns as Markdown.
    let continueChat: (String) -> Void
    let openDocument: (ReplayDocument) -> Void
    @AppStorage("shareService") private var service = ""
    @AppStorage("accentPalette") private var palette = AccentPalette.graphite
    @AppStorage("accentHue") private var hue = 0.58
    @ObservedObject private var library = HostedLibrary.shared
    @State private var path: [SharePage] = []
    @State private var scopeChoice: ShareScope?
    @State private var picked: Set<UUID>?
    @State private var includeThinking = true
    @State private var includeTools = true
    @State private var includeImages = true
    @State private var templateChoice: ShareTemplate?
    @State private var showQuestion = true
    @State private var showMeta = true
    @State private var format = ShareFileFormat.file
    @State private var ttl = "30d"
    @State private var sharedID: UUID?
    @State private var sharedFor = ""
    @State private var stoppedID: UUID?
    @State private var confirmingStop = false
    @State private var copied = false
    @State private var fileSaved = false
    @State private var imageSaved = false
    @State private var flash: Task<Void, Never>?
    @State private var work: ShareWork?
    @State private var error: String?
    @State private var built: BuiltShare?
    @State private var pictures: [String: ReplayPicture] = [:]
    @State private var cardImages: [String: PlatformImage] = [:]
    @State private var replay: ReplayDocument?
    @State private var receivedLink = ""
    @State private var saveFile: TranscriptExport?
    @State private var saving = false
    @State private var items: [Any] = []
    @State private var sharing = false
    @State private var importing = false
    @State private var directory: URL?
    private var safeTitle: String { ShareText.redacted(title) }

    // MARK: Scope and privacy

    private var focused: LocalTurn? { focusedTurn.flatMap { id in turns.first { $0.id == id } } }
    private var scopes: [ShareScope] {
        var list: [ShareScope] = [.picked, .whole]
        if let focused, !focused.outgoing { list.insert(.reply, at: 0) }
        return list
    }
    private var scope: ShareScope {
        if let scopeChoice { return scopeChoice }
        guard let focused else { return .whole }
        return focused.outgoing ? .picked : .reply
    }

    /// What 「选中消息」 starts with: the picks so far, else the message the sheet was opened from
    /// (a reply with its question), else the last exchange.
    private var pickStart: Set<UUID> {
        if let picked { return picked }
        let anchor = focused?.id ?? turns.last { !$0.outgoing && Self.isMessage($0) }?.id
        return Self.initialSelection(turns, anchor: anchor)
    }

    /// The rows in scope, as the conversation holds them.
    private var scopeRows: [LocalTurn] {
        switch scope {
        case .reply: Self.focusedExcerpt(turns, id: focusedTurn)
        case .picked: Self.pickedRows(turns, picked: pickStart)
        case .whole: turns
        }
    }

    /// The rows in scope with what the privacy choices leave, redacted.
    private var selection: [LocalTurn] { scopeRows.compactMap(shared) }

    private func shared(_ row: LocalTurn) -> LocalTurn? {
        var copy = LocalTurn(id: row.id, outgoing: row.outgoing, text: ShareText.redacted(row.text))
        if includeImages { copy.images = row.images }
        if includeThinking { copy.thinking = row.thinking.map(ShareText.redacted) }
        if includeTools {
            copy.steps = row.steps?.map { step in
                ChatStep(id: step.id, name: ShareText.redacted(step.name), arguments: ShareText.redacted(step.arguments),
                         result: ShareText.redacted(step.sharedResult), state: step.state, images: includeImages ? step.images : nil)
            }
        }
        if !copy.outgoing && copy.text.isEmpty && copy.thinking?.isEmpty != false && copy.steps?.isEmpty != false && copy.images?.isEmpty != false { return nil }
        return copy
    }

    /// Scope and privacy as one value: what was made for another one is stale.
    private var contentKey: String {
        var hasher = Hasher()
        let rows = scopeRows
        for row in rows { hasher.combine(row.id) }
        return "\(scope)-\(rows.count)-\(hasher.finalize())-\(includeThinking)\(includeTools)\(includeImages)"
    }
    private var linkKey: String { contentKey + "|" + ttl + "|" + service }

    /// A prompt (text or pictures) or a reply with text: what a card shows and the picker lists.
    nonisolated static func isMessage(_ turn: LocalTurn) -> Bool {
        let text = !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return turn.outgoing ? text || turn.images?.isEmpty == false : text
    }

    static func focusedExcerpt(_ turns: [LocalTurn], id: UUID?) -> [LocalTurn] {
        guard let end = turns.firstIndex(where: { $0.id == id }) else { return [] }
        if turns[end].outgoing { return [turns[end]] }
        var start = end
        while start > 0 {
            let previous = turns[start - 1]
            if !previous.outgoing && !previous.text.isEmpty { break }
            start -= 1
            if previous.outgoing { break }
        }
        return Array(turns[start...end])
    }

    /// The picked messages, with the tool calls that led to a picked reply.
    nonisolated static func pickedRows(_ turns: [LocalTurn], picked: Set<UUID>) -> [LocalTurn] {
        var keep = Array(repeating: false, count: turns.count)
        var work: [Int] = []
        for (index, row) in turns.enumerated() {
            if isMessage(row) {
                keep[index] = picked.contains(row.id)
                if keep[index], !row.outgoing { for step in work { keep[step] = true } }
                work.removeAll()
            } else if !row.outgoing { work.append(index) }
        }
        return turns.indices.filter { keep[$0] }.map { turns[$0] }
    }

    /// A reply and the question above it.
    nonisolated static func initialSelection(_ turns: [LocalTurn], anchor: UUID?) -> Set<UUID> {
        guard let index = turns.firstIndex(where: { $0.id == anchor }) else { return [] }
        var result: Set<UUID> = [turns[index].id]
        if !turns[index].outgoing, let question = turns[..<index].last(where: { $0.outgoing && isMessage($0) }) {
            result.insert(question.id)
        }
        return result
    }

    /// The rounds a part covers, for 「第 2–3 轮」 in its replay.
    private var range: (from: Int, to: Int, of: Int)? {
        guard scope != .whole else { return nil }
        let prompts = turns.indices.filter { turns[$0].outgoing }
        let ids = Set(scopeRows.map(\.id))
        let rows = turns.indices.filter { ids.contains(turns[$0].id) }
        guard !prompts.isEmpty, let first = rows.first, let last = rows.last else { return nil }
        func round(_ index: Int) -> Int { (prompts.lastIndex { $0 <= index } ?? 0) + 1 }
        return (round(first), round(last), prompts.count)
    }

    private var counts: (messages: Int, tools: Int, images: Int) {
        let rows = scopeRows
        let tools = includeTools ? rows.reduce(0) { $0 + ($1.steps?.count ?? 0) } : 0
        let images = includeImages ? rows.filter(\.outgoing).reduce(0) { $0 + ($1.images?.count ?? 0) } : 0
        return (rows.filter(Self.isMessage).count, tools, images)
    }

    // MARK: The card

    private var template: ShareTemplate { templateChoice ?? (colorScheme == .dark ? .dark : .light) }
    private var accent: Color { palette.color(hue: hue) }

    /// The card for what is in scope (nil when there is nothing to show).
    private var card: ShareCardContent? {
        ShareCardContent.make(title: safeTitle, rows: scopeRows, tools: includeTools) { row in
            var copy = LocalTurn(id: row.id, outgoing: row.outgoing, text: ShareText.redacted(row.text))
            copy.images = includeImages ? row.images : nil
            return copy
        }
    }

    private func cardView(_ content: ShareCardContent) -> ShareCardView {
        ShareCardView(content: content, template: template, showQuestion: showQuestion, showMeta: showMeta, accent: accent, images: cardImages)
    }

    // MARK: Pages

    var body: some View {
        NavigationStack(path: $path) {
            home
                .toolbar {
                    ToolbarItem(placement: .screenLeading) { more }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
                .navigationDestination(for: SharePage.self) { page in destination(page) }
        }
        .onAppear { if templateChoice == nil { templateChoice = ShareCardMemory.template } }
        .onChange(of: path) { _, _ in error = nil }
        .onChange(of: contentKey) { _, _ in error = nil; fileSaved = false; imageSaved = false }
        .task(id: contentKey + (host == nil ? "" : "+")) { await loadCardPictures() }
        .alert("停止分享？", isPresented: $confirmingStop) {
            Button("取消", role: .cancel) {}
            Button("停止分享", role: .destructive) {
                guard let entry = linkEntry else { return }
                library.removeAfterDelay(entry)
                stoppedID = entry.id
            }
        } message: { Text(verbatim: String(localized: "「") + (linkEntry?.title ?? safeTitle) + String(localized: "」的链接会立即失效")) }
        .fileExporter(isPresented: $saving, document: saveFile, contentType: saveFile?.type ?? .data,
                      defaultFilename: Self.fileStem(safeTitle) + "." + format.rawValue) { result in
            switch result {
            case .success: flashDone { fileSaved = $0 }
            case .failure(let failure): error = failure.localizedDescription
            }
            saveFile = nil
        }
        #if os(macOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.dshConversation, .json]) { result in
            switch result {
            case .success(let file): importFile(file)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .sheet(item: $replay) { ReplayView(document: $0).desktopSheet(width: 620, height: 500) }
        #else
        .sheet(isPresented: $importing) {
            ConversationPicker { file in
                importing = false
                if let file { importFile(file) }
            }
        }
        .fullScreenCover(item: $replay) { ReplayView(document: $0) }
        #endif
        .sheet(isPresented: $sharing, onDismiss: clean) { SystemShare(items: items) }
    }

    /// Opening a conversation file or a link someone sent: not part of sharing, kept one tap away.
    private var more: some View {
        Menu {
            Button { importing = true } label: { Label("打开对话文件", systemImage: "doc") }
                .accessibilityIdentifier("importTranscript")
            Button { path.append(.openLink) } label: { Label("打开分享链接", systemImage: "link") }
                .accessibilityIdentifier("openSharedLink")
        } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("更多").accessibilityIdentifier("shareMore")
    }

    @ViewBuilder private func destination(_ page: SharePage) -> some View {
        switch page {
        case .pick:
            SharePickPage(rows: turns.filter(Self.isMessage), selected: pickStart) { keys in
                picked = keys
                scopeChoice = .picked
                if !path.isEmpty { path.removeLast() }
            }
        case .link: linkPage
        case .file: filePage
        case .image: imagePage
        case .openLink: openLinkPage
        case .links: SharedLinksView()
        case .qr:
            if let entry = linkEntry, let url = try? entry.link() { ShareQRPage(link: url, title: entry.title) }
            else { Text("无法读取链接密钥").foregroundStyle(ChatColors.muted) }
        }
    }

    private func open(_ page: SharePage) {
        error = nil
        path.append(page)
    }

    private func choose(_ next: ShareScope) {
        if next == .picked { open(.pick) } else { scopeChoice = next }
    }

    // 分享: scope, what it includes, the card, then the ways out.
    private var home: some View {
        let content = card
        return SharePageFrame {
            if !turns.isEmpty {
                SharePill(options: scopes, selected: scope, label: \.label, choose: choose).accessibilityIdentifier("shareScope")
                HStack(spacing: 8) {
                    ShareToggleChip(label: String(localized: "思考过程"), isOn: $includeThinking)
                    ShareToggleChip(label: String(localized: "操作步骤"), isOn: $includeTools)
                    ShareToggleChip(label: String(localized: "图片"), isOn: $includeImages)
                }.padding(.top, 12)
            }
            Group {
                if let content { ShareCardPreview(card: cardView(content)) }
                else {
                    Text("这个对话还没有内容").foregroundStyle(ChatColors.muted)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }.padding(.top, 16)
        } bottom: {
            if content != nil { summary }
            ShareStatusLine(error: error)
            HStack(alignment: .top, spacing: 0) {
                ShareRoundAction(label: String(localized: "链接"), symbol: "link", enabled: content != nil) { open(.link) }
                    .accessibilityIdentifier("shareToLink")
                ShareRoundAction(label: String(localized: "图片"), symbol: "photo", enabled: content != nil) { open(.image) }
                    .accessibilityIdentifier("shareToImage")
                ShareRoundAction(label: String(localized: "文件"), symbol: "doc.text", enabled: content != nil) { open(.file) }
                    .accessibilityIdentifier("shareToFile")
                ShareRoundAction(label: String(localized: "文字"), symbol: "text.alignleft", enabled: content != nil) { shareText() }
                    .accessibilityIdentifier("shareToText")
            }.padding(.top, 12)
        }
        .navigationTitle("分享").inlineNavigationTitle()
    }

    /// 「⛨ 2 条消息 · 3 次工具调用 · 密钥已隐藏  调整」.
    private var summary: some View {
        let counts = counts
        var parts = [String(localized: "\(counts.messages) 条消息")]
        if counts.tools > 0 { parts.append(String(localized: "\(counts.tools) 步操作")) }
        if counts.images > 0 { parts.append(String(localized: "\(counts.images) 张图片")) }
        parts.append(String(localized: "密钥已隐藏"))
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.shield").font(.system(size: 13))
            Text(parts.joined(separator: " · ")).font(.caption.monospacedDigit()).accessibilityIdentifier("shareSummary")
            Spacer(minLength: 4)
            if scope == .picked { Button("调整") { open(.pick) }.font(.subheadline).buttonStyle(.borderless) }
        }.foregroundStyle(ChatColors.muted).frame(minHeight: 40)
    }

    // 链接: how long it lives, then the link and what to do with it.
    private var linkEntry: SharedLink? {
        guard sharedFor == linkKey, let id = sharedID else { return nil }
        return library.entries.first { $0.id == id && $0.removalDeadline == nil }
    }
    private var stoppedEntry: SharedLink? {
        guard let id = stoppedID else { return nil }
        return library.entries.first { $0.id == id && $0.removalDeadline != nil }
    }
    private var ready: BuiltShare? { built?.key == contentKey ? built : nil }

    private var linkPage: some View {
        let entry = linkEntry, stopped = stoppedEntry, file = ready
        let busy = work == .link
        return SharePageFrame {
            SharePill(options: ["7d", "30d", "forever"], selected: ttl, label: Self.ttlLabel, enabled: !busy) { ttl = $0 }
                .accessibilityIdentifier("shareLinkExpiry")
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 12))
                Text("端到端加密，服务器看不到内容").font(.caption)
            }.foregroundStyle(ChatColors.muted).padding(.horizontal, 8).padding(.top, 12)
            Group {
                if let entry {
                    HStack(spacing: 12) {
                        Image(systemName: "link").foregroundStyle(ChatColors.muted).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: entry.display).font(.system(size: 14, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                            Text(entry.expiryLabel()).font(.caption).foregroundStyle(ChatColors.muted)
                        }
                        Spacer(minLength: 0)
                    }.shareRow().accessibilityElement(children: .combine).accessibilityIdentifier("shareLinkRow")
                } else if let stopped {
                    PendingShareRemoval(entry: stopped).shareRow()
                } else {
                    ShareFileRow(name: safeTitle, size: file.map { Self.formatBytes($0.file.count) }, preview: previewAction(file))
                    // Links go to a share service of the person's own choosing; none is built in.
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack").font(.system(size: 12)).foregroundStyle(ChatColors.muted)
                        TextField("分享服务 HTTPS 地址", text: $service).font(.footnote)
                            .urlKeyboard().autocorrectionDisabled().submitLabel(.done)
                    }.padding(.horizontal, 14).frame(minHeight: 40).background(ChatColors.muted.opacity(0.08), in: Capsule())
                        .padding(.top, 12)
                }
            }.padding(.top, 16)
        } bottom: {
            ShareStatusLine(error: error ?? (stoppedID != nil ? library.issue : nil))
            if let entry {
                HStack(alignment: .top, spacing: 0) {
                    ShareRoundAction(label: copied ? String(localized: "已复制") : String(localized: "复制链接"), symbol: "doc.on.doc", done: copied) { copy(entry) }
                        .accessibilityIdentifier("shareLinkCopy")
                    ShareRoundAction(label: String(localized: "二维码"), symbol: "qrcode") { open(.qr) }
                    ShareRoundAction(label: String(localized: "分享"), symbol: "square.and.arrow.up") { shareLink(entry) }
                        .accessibilityIdentifier("shareLinkShare")
                    ShareRoundAction(label: String(localized: "停止分享"), symbol: "xmark.circle", enabled: library.pending == nil) { confirmingStop = true }
                        .accessibilityIdentifier("stopShare-" + entry.origin.absoluteString + "/" + entry.remoteID)
                }
            } else {
                Button { publish() } label: {
                    ZStack {
                        Text("生成链接").fontWeight(.semibold).opacity(busy ? 0 : 1)
                        if busy { ProgressView().tint(.white) }
                    }.frame(maxWidth: .infinity, minHeight: 36)
                }.prominentButton().buttonBorderShape(.capsule).controlSize(.large)
                    .disabled(busy || file == nil || service.isEmpty || stopped != nil)
                    .accessibilityLabel("生成链接")
            }
            Button("我的分享链接") { open(.links) }.font(.subheadline).foregroundStyle(ChatColors.muted)
                .frame(minHeight: 40).padding(.top, 4)
        }
        .navigationTitle("链接").inlineNavigationTitle()
        .task(id: contentKey) { await prepare() }
    }

    private static func ttlLabel(_ ttl: String) -> String { ttl == "7d" ? String(localized: "7 天") : ttl == "30d" ? String(localized: "30 天") : String(localized: "永久") }

    // 文件: the conversation as a .dshlocal file, a web page or Markdown.
    private var filePage: some View {
        let file = ready
        let data = file?.data(format)
        let tooLarge = file != nil && format.carriesFile && (data?.count ?? .max) > ReplayDocument.fileLimit
        return SharePageFrame {
            SharePill(options: ShareFileFormat.allCases, selected: format, label: \.label, enabled: work == nil) { next in
                format = next
                fileSaved = false
                error = nil
            }.accessibilityIdentifier("shareFileFormat")
            ShareFileRow(name: Self.fileStem(safeTitle) + "." + format.rawValue, size: data.map { Self.formatBytes($0.count) },
                         preview: format.carriesFile ? previewAction(file) : nil).padding(.top, 16)
            Text(format.hint).font(.caption).foregroundStyle(ChatColors.muted).padding(.horizontal, 8).padding(.top, 10)
                .accessibilityIdentifier("shareFileHint")
        } bottom: {
            ShareStatusLine(error: error ?? (tooLarge ? String(localized: "超过 4 MB。少选几条消息，或关掉图片") : nil))
            ShareSaveBar(saveLabel: String(localized: "保存"), saved: fileSaved, work: work, enabled: data != nil && !tooLarge,
                         save: { exportFile(save: true) }, share: { exportFile(save: false) })
        }
        .navigationTitle("文件").inlineNavigationTitle()
        .task(id: contentKey) { await prepare() }
    }

    // 图片: the card with its template and two toggles.
    @ViewBuilder private var imagePage: some View {
        if let content = card {
            SharePageFrame {
                SharePill(options: ShareTemplate.allCases, selected: template, label: \.label) { next in
                    templateChoice = next
                    ShareCardMemory.template = next
                }.accessibilityIdentifier("shareTemplate")
                if content.hasQuestion || content.hasMeta {
                    HStack(spacing: 8) {
                        if content.hasQuestion { ShareToggleChip(label: String(localized: "提问"), isOn: $showQuestion) }
                        if content.hasMeta { ShareToggleChip(label: String(localized: "模型与过程"), isOn: $showMeta) }
                    }.padding(.top, 12)
                }
                ShareCardPreview(card: cardView(content)).padding(.top, 16)
            } bottom: {
                ShareStatusLine(error: error)
                ShareSaveBar(saveLabel: String(localized: "保存图片"), saved: imageSaved, work: work, enabled: true,
                             save: { picture(save: true) }, share: { picture(save: false) })
            }
            .navigationTitle("图片").inlineNavigationTitle()
        } else {
            Text("这个对话还没有内容").foregroundStyle(ChatColors.muted).navigationTitle("图片")
        }
    }

    // 打开分享链接: a link someone sent, opened as a replay.
    private var openLinkPage: some View {
        Form {
            Section {
                SecureField("粘贴完整链接", text: $receivedLink).noAutomaticCapitalization().autocorrectionDisabled()
                Button { openReceived() } label: {
                    HStack {
                        Text("打开回放")
                        if work == .opening { Spacer(); ProgressView() }
                    }
                }.disabled(receivedLink.isEmpty || work != nil)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }.listRowBackground(ChatColors.chip)
        }.foregroundStyle(ChatColors.ink).scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
            .navigationTitle("打开分享链接").inlineNavigationTitle()
    }

    // MARK: Work

    private func openReceived() {
        work = .opening
        error = nil
        Task {
            defer { work = nil }
            do {
                let doc = try await ReplayLink.open(receivedLink)
                receivedLink = ""
                openDocument(doc)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 「预览」: the replay the receiver gets (no 「接着聊」).
    private func previewAction(_ made: BuiltShare?) -> (() -> Void)? {
        guard let made else { return nil }
        return { preview(made.file) }
    }

    private func preview(_ file: Data) {
        do { replay = try ReplayDocument.decode(file) } catch { self.error = error.localizedDescription }
    }

    private func prepare() async {
        do { _ = try await builtShare() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    /// The file forms of the current scope and privacy (made once for each).
    private func builtShare() async throws -> BuiltShare {
        let key = contentKey
        if let built, built.key == key { return built }
        let rows = selection
        let previews = try await pictureData(rows)
        try Task.checkCancellation()
        let file = try ReplayDocument.encode(title: safeTitle, turns: rows, pictures: previews, range: range)
        let made = BuiltShare(key: key, file: file, page: try? OfflineReplay.page(title: safeTitle, file: file),
                              markdown: Data(Self.markdown(rows, pictures: previews).utf8))
        if key == contentKey { built = made }
        return made
    }

    private func importFile(_ file: URL) {
        do {
            if file.pathExtension.lowercased() == "dshlocal" {
                openDocument(try ReplayDocument.read(file)); return
            }
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 8_000_001) ?? Data()
            guard data.count <= 8_000_000 else { throw HostError(String(localized: "对话文件过大。")) }
            let archive = try JSONDecoder().decode(TranscriptFile.self, from: data)
            guard archive.format == 1, archive.turns.count <= 20000 else { throw HostError(String(localized: "不支持此对话格式。")) }
            continueChat(Self.markdown(archive.turns.map { LocalTurn(outgoing: $0.outgoing, text: $0.text) }))
        } catch { self.error = error.localizedDescription }
    }

    private func pictureData(_ rows: [LocalTurn]) async throws -> [String: ReplayPicture] {
        try await loadPictures(rows.flatMap { ($0.images ?? []) + ($0.steps ?? []).flatMap { $0.images ?? [] } })
    }

    private func loadPictures(_ refs: [HostImage]) async throws -> [String: ReplayPicture] {
        var result: [String: ReplayPicture] = [:]
        var size = 0
        for ref in refs where result[ref.id] == nil {
            let preview: ReplayPicture
            if let cached = pictures[ref.id] { preview = cached }
            else {
                guard let host else { throw HostError(String(localized: "请重新连接后再读取对话图片。")) }
                let media = try await host.imageData(ref, session: imageSession)
                preview = try ReplayPicture(reference: ref, bytes: media)
                pictures[ref.id] = preview
                if cardImages[ref.id] == nil { cardImages[ref.id] = PlatformImage(data: preview.data) }
            }
            size += preview.data.count
            guard size < ReplayDocument.fileLimit else { throw HostError(String(localized: "图片过多，请缩小范围或关闭图片。")) }
            result[ref.id] = preview
        }
        return result
    }

    /// The card's pictures, fetched after the sheet is up; one that can't be read is left off.
    private func loadCardPictures() async {
        guard includeImages, let host else { return }
        for ref in scopeRows.filter(Self.isMessage).flatMap({ $0.images ?? [] }) where cardImages[ref.id] == nil {
            guard let bytes = try? await host.imageData(ref, session: imageSession), !Task.isCancelled,
                  let preview = try? ReplayPicture(reference: ref, bytes: bytes) else { continue }
            pictures[ref.id] = preview
            cardImages[ref.id] = PlatformImage(data: preview.data)
        }
    }

    private func publish() {
        guard work == nil else { return }
        error = nil
        work = .link
        let key = linkKey
        Task {
            defer { work = nil }
            do {
                let file = try await builtShare().file
                let entry = try await library.publish(file: file, title: safeTitle, service: HostedShares.origin(service), ttl: ttl)
                sharedID = entry.id
                sharedFor = key
                stoppedID = nil
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            } catch { self.error = error.localizedDescription }
        }
    }

    private func copy(_ entry: SharedLink) {
        guard let url = try? entry.link() else { error = String(localized: "无法读取链接密钥。"); return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        PlatformPasteboard.copy(url)
        flashDone(for: 1.6) { copied = $0 }
    }

    private func shareLink(_ entry: SharedLink) {
        guard let url = try? entry.link() else { error = String(localized: "无法读取链接密钥。"); return }
        present([String(localized: "「") + entry.title + String(localized: "」· Pallas Agent 对话\n") + url.absoluteString])
    }

    /// 「文字」: a reply's own words, or the picked / whole conversation as Markdown.
    private func shareText() {
        if scope == .reply, let focused {
            present([ShareText.redacted(focused.text).trimmingCharacters(in: .whitespacesAndNewlines)])
        } else {
            present([Self.markdown(selection)])
        }
    }

    /// Shows a done state (「已保存」「已复制」) for a moment.
    private func flashDone(for seconds: Double = 2.4, _ set: @escaping (Bool) -> Void) {
        set(true)
        flash?.cancel()
        flash = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { set(false) }
        }
    }

    private func clean() {
        items = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func present(_ values: [Any]) { error = nil; items = values; sharing = true }

    private func exportFile(save: Bool) {
        guard work == nil, let built = ready, let data = built.data(format) else { return }
        error = nil
        if save {
            clean()
            saveFile = TranscriptExport(data: data, type: format.type)
            saving = true
            return
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            directory = folder
            let file = folder.appending(path: Self.fileStem(safeTitle) + "." + format.rawValue)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            present([file])
        } catch { clean(); self.error = error.localizedDescription }
    }

    @MainActor private func picture(save: Bool) {
        guard work == nil, let content = card else { return }
        error = nil
        work = save ? .saving : .sharing
        Task {
            defer { work = nil }
            do {
                _ = try await loadPictures(content.blocks.flatMap(\.images))
                let rendered = cardView(content).frame(width: ShareCardView.width)
                let renderer = ImageRenderer(content: rendered)
                renderer.scale = 3
                #if os(macOS)
                guard let image = renderer.cgImage, let png = RasterFrames.encode(image, as: .png) else {
                    error = String(localized: "没能生成图片，请重试")
                    return
                }
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let file = folder.appending(path: Self.fileStem(safeTitle) + ".png")
                do { try png.write(to: file, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: folder); throw error }
                if save {
                    defer { try? FileManager.default.removeItem(at: folder) }
                    if try await MacFileExport.save(file) != nil { flashDone { imageSaved = $0 } }
                } else {
                    directory = folder
                    present([file])
                }
                #else
                guard let image = renderer.uiImage else { error = String(localized: "没能生成图片，请重试"); return }
                if save {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard status == .authorized || status == .limited else { error = String(localized: "没有相册权限。到系统设置里允许后再保存"); return }
                    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    flashDone { imageSaved = $0 }
                } else { present([image]) }
                #endif
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Text forms

    static func markdown(_ rows: [LocalTurn], pictures: [String: ReplayPicture] = [:]) -> String {
        var definitions: [String] = [], labels: [String: String] = [:]
        func images(_ references: [HostImage]?) -> [String] {
            (references ?? []).compactMap { ref in
                guard let picture = pictures[ref.id] else { return nil }
                let label = labels[ref.id] ?? "image-\(labels.count + 1)"
                if labels[ref.id] == nil {
                    labels[ref.id] = label
                    definitions.append("[\(label)]: data:\(picture.mediaType);base64,\(picture.data.base64EncodedString())")
                }
                return String(localized: "![图片][\(label)]")
            }
        }
        let messages = rows.map { row in
            var blocks = [row.outgoing ? String(localized: "## 我") : String(localized: "## 助手")]
            if let thinking = row.thinking { blocks.append(thinking) }
            for step in row.steps ?? [] {
                blocks.append([step.displayName, step.arguments, step.result].filter { !$0.isEmpty }.joined(separator: "\n"))
                blocks += images(step.images)
            }
            blocks += images(row.images)
            blocks.append(row.text)
            return blocks.joined(separator: "\n\n")
        }
        return (messages + definitions).joined(separator: "\n\n")
    }

    /// A file name from a title: no path characters, at most 40 characters.
    nonisolated static func fileStem(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: #"[\\/:*?"<>|\x00-\x1f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return String(localized: "对话") }
        return cleaned.count <= 40 ? cleaned : String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

// MARK: - 选择消息

/// Every prompt and reply with a round check. A tap picks or drops one message; a long press
/// picks the whole stretch from the nearest picked message to the one pressed.
private struct SharePickPage: View {
    let rows: [LocalTurn]
    let done: (Set<UUID>) -> Void
    @State private var picks: Set<UUID>

    init(rows: [LocalTurn], selected: Set<UUID>, done: @escaping (Set<UUID>) -> Void) {
        self.rows = rows
        self.done = done
        _picks = State(initialValue: selected.intersection(rows.map(\.id)))
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        let on = picked(index)
                        SharePickRow(turn: rows[index], picked: on, joinAbove: on && picked(index - 1), joinBelow: on && picked(index + 1))
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(index) }
                            .onLongPressGesture(minimumDuration: 0.4) { stretch(to: index) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { toggle(index) }
                            .accessibilityAction(named: "选到这里") { stretch(to: index) }
                            .id(rows[index].id)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.onAppear {
                if let first = rows.first(where: { picks.contains($0.id) }), first.id != rows.first?.id {
                    reader.scrollTo(first.id, anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { done(picks) } label: {
                Text(picks.isEmpty ? "完成" : "完成（\(picks.count)）").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36)
            }.prominentButton().buttonBorderShape(.capsule).controlSize(.large).disabled(picks.isEmpty)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12).background(.ultraThinMaterial)
                .accessibilityIdentifier("sharePickDone")
        }
        .foregroundStyle(ChatColors.ink).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("选择消息").inlineNavigationTitle()
    }

    private func picked(_ index: Int) -> Bool { rows.indices.contains(index) && picks.contains(rows[index].id) }

    private func toggle(_ index: Int) {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        let id = rows[index].id
        if picks.contains(id) { picks.remove(id) } else { picks.insert(id) }
    }

    private func stretch(to index: Int) {
        let others = rows.indices.filter { $0 != index && picks.contains(rows[$0].id) }
        let anchor = others.min { abs($0 - index) < abs($1 - index) } ?? index
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        for i in min(anchor, index)...max(anchor, index) { picks.insert(rows[i].id) }
    }
}

/// One message: a round check (ink when picked), who said it, two lines of it.
/// Picked neighbours share a rail through their checks.
private struct SharePickRow: View {
    let turn: LocalTurn
    let picked: Bool
    let joinAbove: Bool
    let joinBelow: Bool

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.outgoing ? "你" : "回复").font(.caption.weight(.medium))
                    .foregroundStyle(turn.outgoing ? ChatColors.ink.opacity(0.7) : ChatColors.muted)
                Text(verbatim: Self.preview(turn)).lineLimit(2).foregroundStyle(ChatColors.ink)
            }.padding(.vertical, 10)
            Spacer(minLength: 8)
        }
        .frame(minHeight: 68)
        .background(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle().fill(joinAbove ? ChatColors.ink : Color.clear).frame(width: 2)
                ZStack {
                    Circle().fill(picked ? ChatColors.ink : Color.clear)
                    if picked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ChatColors.chip) }
                    else { Circle().strokeBorder(ChatColors.muted.opacity(0.6), lineWidth: 1.5) }
                }.frame(width: 22, height: 22)
                Rectangle().fill(joinBelow ? ChatColors.ink : Color.clear).frame(width: 2)
            }.frame(width: 22)
        }
        .padding(.leading, 8)
        .animation(.easeOut(duration: 0.15), value: picked)
    }

    /// The message on one or two lines: no Markdown marks, pictures as 〔图片〕.
    static func preview(_ turn: LocalTurn) -> String {
        var text = turn.text.replacingOccurrences(of: #"!\[[^\]\n]*\]\([^)\n]*\)"#, with: String(localized: "〔图片〕"), options: .regularExpression)
        text = ShareText.redacted(text)
            .replacingOccurrences(of: #"(?m)^\s*(`{3,}|~{3,}).*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*|__|`+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if turn.outgoing, let count = turn.images?.count, count > 0 {
            return ([count == 1 ? String(localized: "〔图片〕") : String(localized: "〔\(count) 张图片〕")] + (text.isEmpty ? [] : [text])).joined(separator: " ")
        }
        return text
    }
}

// MARK: - The card

/// What a share card shows: the title, the messages (cut to fit), the steps and what the agent did.
private struct ShareCardContent {
    enum Block {
        case question(String, [HostImage])
        case answer(String, [HostImage])

        var images: [HostImage] {
            switch self {
            case .question(_, let images), .answer(_, let images): images
            }
        }
        var isQuestion: Bool { if case .question = self { true } else { false } }
    }

    let title: String
    let blocks: [Block]
    /// 「8 步」.
    let stats: String?
    /// What the agent did, most frequent first.
    let process: [(label: String, symbol: String, count: Int)]
    /// The body was cut to fit the card.
    let cut: Bool

    var hasQuestion: Bool { blocks.contains(where: \.isQuestion) }
    var hasMeta: Bool { stats != nil || !process.isEmpty }

    /// The card for [rows]; [redact] makes a row ready to show (only rows that fit are redacted).
    static func make(title: String, rows: [LocalTurn], tools: Bool, redact: (LocalTurn) -> LocalTurn) -> ShareCardContent? {
        let messages = rows.filter(TranscriptPanel.isMessage)
        guard !messages.isEmpty else { return nil }
        var budget = messages.filter { !$0.outgoing }.count >= 2 ? 5200 : 2000
        var blocks: [Block] = [], cut = false
        for row in messages {
            if budget <= 0 { cut = true; break }
            let shown = redact(row)
            if shown.outgoing {
                let text = shown.text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let short = text.count > 600 ? String(text.prefix(600)) + "…" : text
                blocks.append(.question(short, shown.images ?? []))
                budget -= min(text.count, 600)
            } else {
                let (text, clipped) = clip(shown.text.trimmingCharacters(in: .whitespacesAndNewlines), to: budget)
                blocks.append(.answer(text, shown.images ?? []))
                budget -= text.count
                if clipped { cut = true; break }
            }
        }
        let steps = rows.flatMap { $0.steps ?? [] }
        var counts: [String: Int] = [:], order: [String] = [], symbols: [String: String] = [:]
        if tools {
            for step in steps {
                guard let (label, symbol) = processKind(step.name) else { continue }
                if counts[label] == nil { order.append(label); symbols[label] = symbol }
                counts[label, default: 0] += 1
            }
        }
        let ranked = order.enumerated().sorted { a, b in
            let left = counts[a.element] ?? 0, right = counts[b.element] ?? 0
            return left != right ? left > right : a.offset < b.offset
        }.prefix(3).map { (label: $0.element, symbol: symbols[$0.element] ?? "puzzlepiece.extension", count: counts[$0.element] ?? 0) }
        return ShareCardContent(title: title, blocks: blocks, stats: steps.isEmpty ? nil : String(localized: "\(steps.count) 步"), process: Array(ranked), cut: cut)
    }

    /// [text] cut at a paragraph (or sentence) boundary within [budget] characters.
    private static func clip(_ text: String, to budget: Int) -> (String, Bool) {
        let room = max(budget, 200)
        guard text.count > room else { return (text, false) }
        let head = String(text.prefix(room))
        if let paragraph = head.range(of: "\n\n", options: .backwards),
           head.distance(from: head.startIndex, to: paragraph.lowerBound) > head.count / 2 {
            return (String(head[..<paragraph.lowerBound]) + "\n\n…", true)
        }
        if let stop = head.lastIndex(where: { "。！？；.!?;".contains($0) }), head.distance(from: head.startIndex, to: stop) > head.count / 2 {
            return (String(head[...stop]) + "…", true)
        }
        return (head.trimmingCharacters(in: .whitespacesAndNewlines) + "…", true)
    }

    /// The noun for what a tool call did and its symbol; nil for bookkeeping that is not work to show.
    static func processKind(_ tool: String) -> (label: String, symbol: String)? {
        switch tool {
        case "web_search": (String(localized: "联网搜索"), "magnifyingglass")
        case "web_fetch", "browser_open": (String(localized: "打开网页"), "globe")
        case "bash", "pwsh": (String(localized: "运行命令"), "terminal")
        case "read", "read_image", "grep", "glob": (String(localized: "读取文件"), "doc.text")
        case "write", "edit", "str_replace_editor": (String(localized: "修改文件"), "pencil")
        case "subagent": (String(localized: "子任务"), "person.2")
        case "skill": (String(localized: "使用技能"), "sparkles")
        case "present": (String(localized: "交付文件"), "shippingbox")
        case "workflow", "ralph": (String(localized: "工作流"), "arrow.triangle.branch")
        case "memory": (String(localized: "整理记忆"), "brain")
        case "iphone_screen", "iphone_calculator": (String(localized: "操作手机"), "iphone")
        case "mac_task": (String(localized: "在电脑上执行"), "desktopcomputer")
        case "claude_desktop": (String(localized: "交给 Mac 上的 Claude"), "sparkles")
        case "claude_sessions": (String(localized: "查看 Mac 上的 Claude 会话"), "sparkles")
        default: tool.hasPrefix("mcp__") ? (String(localized: "使用插件"), "puzzlepiece.extension") : nil
        }
    }
}

private func hex(_ rgb: UInt32) -> Color {
    Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
}

/// A share card, [width] wide and as tall as its content: title, meta, the messages, then the
/// brand line with a code to the project page.
private struct ShareCardView: View {
    let content: ShareCardContent
    let template: ShareTemplate
    let showQuestion: Bool
    let showMeta: Bool
    let accent: Color
    let images: [String: PlatformImage]

    static let width: CGFloat = 390
    private static let projectQR = ShareQR.render(ProjectLinks.repository, scale: 6)

    private struct Look {
        let ink: Color, muted: Color, bubble: Color, rule: Color, code: Color
    }

    private var look: Look {
        switch template {
        case .light: Look(ink: hex(0x202633), muted: hex(0x586273), bubble: hex(0xe6edf8), rule: hex(0xcbd2de), code: Color.white.opacity(0.75))
        case .dark: Look(ink: hex(0xe1e5ec), muted: hex(0xa4acba), bubble: hex(0x283244), rule: hex(0x49515e), code: hex(0x272e39))
        case .paper: Look(ink: hex(0x2b2723), muted: hex(0x6f675d), bubble: hex(0xeee9df), rule: hex(0xd9d3c8), code: hex(0xf3efe6))
        case .glass: Look(ink: hex(0x202633), muted: hex(0x586273), bubble: Color.white.opacity(0.7), rule: hex(0xcbd2de), code: Color.white.opacity(0.6))
        case .card: Look(ink: hex(0x202633), muted: hex(0x586273), bubble: hex(0xeef1f6), rule: hex(0xcbd2de), code: hex(0xf3f5f9))
        }
    }

    var body: some View {
        let look = look
        Group {
            if template.onField {
                VStack(alignment: .leading, spacing: 18) {
                    main(look).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(panel)
                    footer(ink: .white, muted: .white.opacity(0.8)).padding(.horizontal, 4)
                }.padding(18).background(field)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if template == .paper { Rectangle().fill(accent).frame(width: 28, height: 3).padding(.bottom, 14) }
                    main(look)
                    Rectangle().fill(look.rule).frame(height: 0.6).padding(.vertical, 20)
                    footer(ink: look.ink, muted: look.muted)
                }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 24).background(page)
            }
        }
        .frame(maxWidth: Self.width)
        .environment(\.colorScheme, template == .dark ? .dark : .light)
    }

    @ViewBuilder private var page: some View {
        switch template {
        case .dark: LinearGradient(colors: [hex(0x242e40), hex(0x1d222b), hex(0x24222b)], startPoint: .topTrailing, endPoint: .bottomLeading)
        case .paper: LinearGradient(colors: [hex(0xfbf9f4), hex(0xf5f1e8)], startPoint: .top, endPoint: .bottom)
        default:
            LinearGradient(colors: [hex(0xeef2fa), hex(0xf8f9fc), hex(0xf5f3f8)], startPoint: .topTrailing, endPoint: .bottomLeading)
                .overlay(accent.opacity(0.05))
        }
    }

    @ViewBuilder private var field: some View {
        if template == .glass {
            LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(Color.white)
        } else {
            LinearGradient(colors: [accent.opacity(0.85), accent], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder private var panel: some View {
        if template == .glass {
            RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 24).fill(Color.white).shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
    }

    private func main(_ look: Look) -> some View {
        let blocks = showQuestion ? content.blocks : content.blocks.filter { !$0.isQuestion }
        let endsCut: Bool = {
            if case .answer(let text, _)? = blocks.last { return text.hasSuffix("…") }
            return false
        }()
        return VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: content.title).font(.system(size: 21, weight: .semibold)).lineLimit(3)
            if showMeta && content.hasMeta { meta(look) }
            ForEach(blocks.indices, id: \.self) { index in block(blocks[index], look) }
            if content.cut && !endsCut { Text("…").foregroundStyle(look.muted) }
        }.foregroundStyle(look.ink)
    }

    private func meta(_ look: Look) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stats = content.stats {
                HStack(spacing: 6) {
                    ForEach(stats.components(separatedBy: " · "), id: \.self) { part in
                        Text(part).font(.caption.monospacedDigit()).padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(look.ink.opacity(0.07)))
                    }
                }
            }
            if !content.process.isEmpty {
                HStack(spacing: 14) {
                    ForEach(content.process.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            Image(systemName: content.process[i].symbol)
                            Text("\(content.process[i].label) \(content.process[i].count)")
                        }
                    }
                }.font(.caption).foregroundStyle(look.muted)
            }
        }
    }

    @ViewBuilder private func block(_ block: ShareCardContent.Block, _ look: Look) -> some View {
        switch block {
        case .question(let text, let refs):
            let pictures = refs.compactMap { images[$0.id] }
            VStack(alignment: .trailing, spacing: 8) {
                if !pictures.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(pictures.prefix(4).indices, id: \.self) { i in
                            Image(platformImage: pictures[i]).resizable().scaledToFill().frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if !text.isEmpty {
                    Text(verbatim: text).font(.system(size: 15)).lineSpacing(3).lineLimit(12)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(look.bubble, in: RoundedRectangle(cornerRadius: 18))
                }
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 44)
        case .answer(let text, let refs):
            let pictures = refs.compactMap { images[$0.id] }
            VStack(alignment: .leading, spacing: 10) {
                ShareCardMarkdown(text: text, code: look.code)
                ForEach(pictures.prefix(4).indices, id: \.self) { i in
                    Image(platformImage: pictures[i]).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func footer(ink: Color, muted: Color) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image("AppIconPreview").resizable().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(verbatim: "Pallas Agent").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                }
                Text(Self.projectQR == nil ? "手机上的私人秘书" : "手机上的私人秘书 · 扫码获取").font(.caption).foregroundStyle(muted)
                    .lineLimit(1).padding(.leading, 29)
            }
            Spacer(minLength: 0)
            if let code = Self.projectQR {
                Image(platformImage: code).interpolation(.none).resizable().frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(template == .light ? 0.08 : 0), lineWidth: 0.5))
            }
        }
    }
}

/// A reply's Markdown as a card draws it: paragraphs, headings, list items and code, no scrolling parts.
private struct ShareCardMarkdown: View {
    let text: String
    let code: Color

    private enum Part { case text(String), heading(String), item(String, String), code(String) }

    private var parts: [Part] {
        var result: [Part] = [], lines: [String] = [], inCode = false
        func flush() {
            guard !lines.isEmpty else { return }
            result.append(inCode ? .code(lines.joined(separator: "\n")) : .text(lines.joined(separator: "\n")))
            lines.removeAll()
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { flush(); inCode.toggle(); continue }
            if inCode { lines.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            let token = trimmed.prefix { !$0.isWhitespace }
            let body = String(trimmed.dropFirst(token.count).drop { $0.isWhitespace })
            if !body.isEmpty, ["-", "*", "+"].contains(String(token)) { flush(); result.append(.item("•", body)) }
            else if !body.isEmpty, token.last == ".", Int(token.dropLast()) != nil { flush(); result.append(.item(String(token), body)) }
            else if !body.isEmpty, (1...6).contains(token.count), token.allSatisfy({ $0 == "#" }) { flush(); result.append(.heading(body)) }
            else { lines.append(line) }
        }
        flush()
        return result
    }

    var body: some View {
        let parts = parts
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parts.indices, id: \.self) { index in
                switch parts[index] {
                case .text(let value): Text(Self.inline(value))
                case .heading(let value): Text(Self.inline(value)).fontWeight(.semibold)
                case .item(let marker, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text(marker); Text(Self.inline(value)) }.padding(.leading, 4)
                case .code(let value):
                    Text(verbatim: value).font(.system(size: 12.5, design: .monospaced)).lineLimit(24).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading).background(code, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }.font(.system(size: 15)).lineSpacing(3)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The card at the page's width, in a soft frame.
private struct ShareCardPreview: View {
    let card: ShareCardView
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        card.clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ChatColors.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.10), radius: 14, y: 6)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel("分享图片预览").accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("sharePreview")
    }
}

// MARK: - Pieces of the share pages

/// A share page: [top] scrolling, [bottom] pinned under it.
private struct SharePageFrame<Top: View, Bottom: View>: View {
    let top: Top
    let bottom: Bottom
    init(@ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        self.top = top()
        self.bottom = bottom()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { top }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) { bottom }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                .frame(maxWidth: .infinity).background(.ultraThinMaterial)
        }
        .foregroundStyle(ChatColors.ink).background(ChatColors.canvas.ignoresSafeArea())
    }
}

/// Segments in a capsule; the picked one raised.
private struct SharePill<Value: Hashable>: View {
    let options: [Value]
    let selected: Value
    let label: (Value) -> String
    var enabled = true
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selected
                Button { choose(option) } label: {
                    // minWidth 0: equal thirds even when a label (English "Entire Conversation") is wider than its share; it shrinks instead.
                    Text(label(option)).font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, 6).frame(minWidth: 0, maxWidth: .infinity, minHeight: 36)
                        .background { if on { Capsule().fill(ChatColors.chip).shadow(color: .black.opacity(0.1), radius: 3, y: 1) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).foregroundStyle(on ? ChatColors.ink : ChatColors.muted)
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(3).background(Capsule().fill(ChatColors.muted.opacity(0.12))).disabled(!enabled).opacity(enabled ? 1 : 0.6)
    }
}

/// An on / off capsule: a check and the label when on, a quiet label when off.
private struct ShareToggleChip: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                Text(label).font(.subheadline.weight(isOn ? .semibold : .medium)).lineLimit(1)
            }.padding(.horizontal, 12).frame(minHeight: 32).background(Capsule().fill(ChatColors.ink.opacity(isOn ? 0.10 : 0.04)))
                .contentShape(Capsule())
        }.buttonStyle(.plain).foregroundStyle(isOn ? ChatColors.ink : ChatColors.muted)
            .accessibilityLabel(label).accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A round key with its label under it.
private struct ShareRoundAction: View {
    let label: String
    let symbol: String
    var enabled = true
    var busy = false
    var done = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(ChatColors.ink.opacity(scheme == .dark ? 0.10 : 0.06))
                    if busy { ProgressView() }
                    else { Image(systemName: done ? "checkmark" : symbol).font(.system(size: 20)) }
                }.frame(width: 52, height: 52)
                Text(label).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(enabled ? ChatColors.ink : ChatColors.muted.opacity(0.5))
            .disabled(!enabled || busy).accessibilityLabel(label)
    }
}

/// What goes out as a file: its name, its size, and 「预览」 when it replays.
private struct ShareFileRow: View {
    let name: String
    let size: String?
    var preview: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 18)).foregroundStyle(ChatColors.muted).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).lineLimit(2)
                if let size { Text(size).font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted) }
            }
            Spacer(minLength: 8)
            if let preview {
                Button("预览", action: preview).buttonStyle(.borderless).frame(minHeight: 44).accessibilityIdentifier("sharePreviewReplay")
            }
        }.shareRow()
    }
}

private extension View {
    func shareRow() -> some View {
        padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A one-line error over a page's actions.
private struct ShareStatusLine: View {
    let error: String?
    var body: some View {
        if let error {
            Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.bottom, 10).accessibilityIdentifier("shareStatus")
        }
    }
}

/// 「保存」 and 「分享」: two equal halves; the one at work shows a ring.
private struct ShareSaveBar: View {
    let saveLabel: String
    let saved: Bool
    let work: ShareWork?
    let enabled: Bool
    let save: () -> Void
    let share: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: save) {
                HStack(spacing: 6) {
                    if work == .saving { ProgressView() } else { Image(systemName: saved ? "checkmark" : "square.and.arrow.down") }
                    Text(saved ? String(localized: "已保存") : saveLabel).lineLimit(1).minimumScaleFactor(0.8)
                }.frame(maxWidth: .infinity, minHeight: 36)
            }.buttonStyle(.bordered).accessibilityIdentifier("shareSave")
            Button(action: share) {
                HStack(spacing: 6) {
                    if work == .sharing { ProgressView().tint(.white) } else { Image(systemName: "square.and.arrow.up") }
                    Text("分享").lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 36)
            }.prominentButton().accessibilityIdentifier("shareSend")
        }.buttonBorderShape(.capsule).controlSize(.large).disabled(!enabled || work != nil)
    }
}

private struct TranscriptExport: FileDocument {
    static let readableContentTypes: [UTType] = [.dshConversation, .html, .plainText]
    let data: Data
    let type: UTType
    init(data: Data, type: UTType) { self.data = data; self.type = type }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data; type = configuration.contentType
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

#if os(macOS)
private struct SystemShare: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button("完成") { dismiss() }
            if let text = items.first as? String {
                ShareLink(item: text)
            } else if let files = items as? [URL], !files.isEmpty {
                ShareLink(items: files)
            }
        }.padding(24)
    }
}
#else
private struct SystemShare: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ConversationPicker: UIViewControllerRepresentable {
    let picked: (URL?) -> Void
    final class Delegate: NSObject, UIDocumentPickerDelegate {
        let picked: (URL?) -> Void
        init(_ picked: @escaping (URL?) -> Void) { self.picked = picked }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picked(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls.first) }
    }
    func makeCoordinator() -> Delegate { Delegate(picked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.dshConversation, .json], asCopy: true)
        picker.directoryURL = .documentsDirectory
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
#endif
