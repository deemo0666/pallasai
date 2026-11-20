import SwiftUI

struct MessageBubble: View {
    let text: String
    let outgoing: Bool
    let font: Font
    let share: () -> Void
    let quote: () -> Void
    var fork: (() -> Void)?
    var retry: (() -> Void)?
    var edit: (() -> Void)?
    /// The quiet icon row under a reply (the host stream shows it under a turn's last reply only).
    var showActions = true
    /// The turn footnote at the action row's right end.
    var footnote: AnyView?
    /// The reply was cut off by a stop: 「已中断」 after it.
    var interrupted = false
    /// A fork is being prepared: the branch keys spin.
    var busy = false
    /// 正在流式写出的回复：逐字显现。
    var live = false
    /// 逐字显现推进时（列表跟随到底部）。
    var onReveal: (() -> Void)?
    @Environment(\.showChatBrowser) private var showBrowser
    @State private var selecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if outgoing {
                    ChatQuestion(text: text, font: font)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        StreamingAnswer(text: text, font: font, live: live, onReveal: onReveal)
                        if interrupted {
                            Label("已中断", systemImage: "stop.circle").font(.caption).foregroundStyle(ChatColors.muted)
                        }
                        // A page of this phone's own (a plugin's install page) is what the reply asks
                        // the person to open: a button they can see, not a run of digits mid-sentence.
                        if !live, let showBrowser {
                            let pages = BrowserRoute.localPages(in: text)
                            ForEach(pages.indices, id: \.self) { index in
                                Button { showBrowser(pages[index]) } label: {
                                    Label(pages.count > 1 ? String(localized: "打开页面 \(index + 1)") : String(localized: "打开页面"),
                                          systemImage: "safari")
                                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 40)
                                        .background(ChatColors.chip, in: Capsule())
                                }.buttonStyle(.pressable).foregroundStyle(Color.accentColor)
                                    .accessibilityIdentifier("openLocalPage-\(index)")
                            }
                        }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
                        guard BrowserRoute.accepts(url), let showBrowser else { return .discarded }
                        showBrowser(BrowserRoute.trimmed(url))
                        return .handled
                    })
                }
            }.foregroundStyle(ChatColors.ink)
                .contextMenu { menu }
            if !outgoing && showActions {
                ReplyActionRow(text: text, share: share, quote: quote, fork: fork, retry: retry, busy: busy,
                               selectText: { selecting = true }, trailing: footnote)
                    .transition(.reveal(Motion.standard))
            }
        }
        .animation(Motion.std(Motion.standard), value: showActions)
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .sheet(isPresented: $selecting) {
            NavigationStack {
                SelectableMessage(text: text)
                    .navigationTitle("选择文字").inlineNavigationTitle()
                    .toolbar { Button("完成") { selecting = false } }
            }
        }
    }

    /// Long-press: a reply offers 复制 / 选择文字 / 引用 / 分享 / 在新对话里重新回答 / 从这里另开对话; a user message 复制 / 选择文字 / 编辑后重发.
    @ViewBuilder private var menu: some View {
        Section {
            Button { PlatformPasteboard.copy(text) } label: { Label("复制", systemImage: "doc.on.doc") }
            Button { selecting = true } label: { Label("选择文字", systemImage: "selection.pin.in.out") }
            if !outgoing {
                Button(action: quote) { Label("引用", systemImage: "quote.opening") }
                Button(action: share) { Label("分享", systemImage: "square.and.arrow.up") }
            }
        }
        Section {
            if let retry, !outgoing { Button(action: retry) { Label("在新对话里重新回答", systemImage: "arrow.clockwise") } }
            if let fork, !outgoing { Button(action: fork) { Label("从这里另开对话", systemImage: "arrow.triangle.branch") } }
            if let edit, outgoing { Button(action: edit) { Label("编辑后重发", systemImage: "square.and.pencil") } }
        }
    }

    static func quoting(_ text: String, in draft: String) -> String {
        let block = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        return (draft.isEmpty ? "" : draft + "\n\n") + block + "\n\n"
    }
}

/// Quiet icons under the last reply of a turn: 复制, 分享, 分叉, 重新回答 and ⋯ 更多; the footnote at the right end.
struct ReplyActionRow: View {
    let text: String
    let share: () -> Void
    let quote: () -> Void
    var fork: (() -> Void)?
    var retry: (() -> Void)?
    var busy = false
    let selectText: () -> Void
    var trailing: AnyView?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                PlatformPasteboard.copy(text)
                withAnimation(Motion.std(Motion.quick)) { copied = true }
                Task { try? await Task.sleep(for: .milliseconds(1400)); withAnimation(Motion.std(Motion.quick)) { copied = false } }
            } label: {
                ZStack {
                    if copied {
                        DrawnCheck(size: 15).foregroundStyle(Color.accentColor).transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        Image(systemName: "doc.on.doc").font(.system(size: 15)).transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }.frame(width: 36, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(copied ? "已复制" : "复制").accessibilityIdentifier("复制")
            key(String(localized: "分享"), icon: "square.and.arrow.up", run: share)
            // The identifiers are the old labels; UI tests find the buttons by them.
            if let fork { busyKey(String(localized: "从这里另开对话"), id: "从这里分叉", icon: "arrow.triangle.branch", run: fork) }
            if let retry { busyKey(String(localized: "在新对话里重新回答"), id: "重新回答", icon: "arrow.clockwise", run: retry) }
            Menu {
                Section {
                    Button { PlatformPasteboard.copy(text) } label: { Label("复制", systemImage: "doc.on.doc") }
                    Button(action: selectText) { Label("选择文字", systemImage: "selection.pin.in.out") }
                    Button(action: quote) { Label("引用", systemImage: "quote.opening") }
                    Button(action: share) { Label("分享", systemImage: "square.and.arrow.up") }
                }
                Section {
                    if let retry { Button(action: retry) { Label("在新对话里重新回答", systemImage: "arrow.clockwise") } }
                    if let fork { Button(action: fork) { Label("从这里另开对话", systemImage: "arrow.triangle.branch") } }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 36, height: 36).contentShape(Rectangle())
            }.accessibilityLabel("更多")
            if let trailing {
                Spacer(minLength: 8)
                trailing
            }
        }
        .foregroundStyle(ChatColors.muted)
        .padding(.leading, -8)
        .padding(.top, 2)
    }

    private func key(_ title: String, icon: String, tint: Color? = nil, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint ?? ChatColors.muted)
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func busyKey(_ title: String, id: String, icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Group {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: icon).font(.system(size: 15)) }
            }.frame(width: 36, height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy).accessibilityLabel(title).accessibilityIdentifier(id)
    }
}

#if os(iOS)
private struct SelectableMessage: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

#else
private struct SelectableMessage: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(verbatim: text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .frame(minWidth: 460, minHeight: 320)
    }
}
#endif

struct ChatQuestion: View {
    let text: String
    let font: Font
    var body: some View {
        Text(verbatim: text).font(font).lineSpacing(3)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(ChatColors.user.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.leading, 44)
    }
}

struct ChatAnswer: View {
    let text: String
    let font: Font

    fileprivate enum Callout: String {
        case note = "NOTE", tip = "TIP", important = "IMPORTANT", warning = "WARNING", caution = "CAUTION"
        var title: String {
            switch self { case .note: String(localized: "注意"); case .tip: String(localized: "提示"); case .important: String(localized: "重要"); case .warning: String(localized: "警告"); case .caution: String(localized: "小心") }
        }
        var color: Color {
            switch self { case .note: .blue; case .tip: .green; case .important: .purple; case .warning: .orange; case .caution: .red }
        }
        var symbol: String {
            switch self {
            case .note: "info.circle"; case .tip: "lightbulb"; case .important: "exclamationmark.bubble"
            case .warning: "exclamationmark.triangle"; case .caution: "exclamationmark.octagon"
            }
        }
    }

    fileprivate enum Block {
        case paragraph(String), heading(Int, String), item(String, String, Int), code(String, String?), table([[String]])
        case quote(String, Callout?), rule, math(String)
    }

    fileprivate static func parse(_ text: String) -> [Block] {
        var result: [Block] = [], lines: [String] = []
        var inCode = false, language: String?
        var quote: [String] = []
        func flush() {
            guard !lines.isEmpty else { return }
            let value = lines.joined(separator: "\n")
            result.append(inCode ? .code(value, language) : .paragraph(value))
            lines.removeAll(keepingCapacity: true)
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            var body = quote
            var callout: Callout?
            if let first = body.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[!"), first.hasSuffix("]"),
               let kind = Callout(rawValue: String(first.dropFirst(2).dropLast()).uppercased()) {
                callout = kind; body.removeFirst()
            }
            result.append(.quote(body.joined(separator: "\n"), callout))
            quote.removeAll()
        }
        let source = text.components(separatedBy: "\n")
        var index = 0
        while index < source.count {
            let line = source[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushQuote(); flush()
                if inCode { inCode = false; language = nil } else {
                    inCode = true
                    let tag = trimmed.drop(while: { $0 == "`" || $0 == "~" }).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : String(tag.split(separator: " ").first ?? "")
                }
                continue
            }
            if inCode { lines.append(line); continue }
            if trimmed.hasPrefix(">") {
                flush()
                var body = trimmed.dropFirst()
                if body.first == " " { body = body.dropFirst() }
                quote.append(String(body))
                continue
            }
            flushQuote()
            if trimmed.isEmpty { flush(); continue }
            // `$$ … $$` / `\[ … \]` on lines of their own: a display formula.
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let close = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                var body = String(trimmed.dropFirst(2))
                if body.trimmingCharacters(in: .whitespaces).hasSuffix(close), body.trimmingCharacters(in: .whitespaces).count >= 2 {
                    let inner = body.trimmingCharacters(in: .whitespaces).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty, !inner.contains("$$") { flush(); result.append(.math(inner)); continue }
                } else {
                    var end = index
                    while end < source.count, !source[end].trimmingCharacters(in: .whitespaces).hasSuffix(close) { end += 1 }
                    if end < source.count {
                        flush()
                        let last = source[end].trimmingCharacters(in: .whitespaces)
                        body += "\n" + source[index..<end].joined(separator: "\n") + "\n" + last.dropLast(2)
                        let inner = body.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !inner.isEmpty { result.append(.math(inner)) }
                        index = end + 1
                        continue
                    }
                }
            }
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, let mark = compact.first, "-*_".contains(mark), compact.allSatisfy({ $0 == mark }) {
                flush(); result.append(.rule); continue
            }
            if index < source.count, let header = ChatTable.cells(line), ChatTable.divides(source[index], columns: header.count) {
                flush(); index += 1
                var rows = [header]
                while index < source.count, let cells = ChatTable.cells(source[index]) {
                    rows.append(Array(cells.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - cells.count)))
                    index += 1
                }
                result.append(.table(rows))
                continue
            }
            let depth = min(3, line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2)
            let token = trimmed.prefix(while: { !$0.isWhitespace })
            let body = String(trimmed.dropFirst(token.count).drop(while: { $0.isWhitespace }))
            if !body.isEmpty && ["-", "*", "+"].contains(String(token)) {
                flush()
                if body.hasPrefix("[ ] ") { result.append(.item("☐", String(body.dropFirst(4)), depth)) }
                else if body.lowercased().hasPrefix("[x] ") { result.append(.item("☑", String(body.dropFirst(4)), depth)) }
                else { result.append(.item(depth == 0 ? "•" : "◦", body, depth)) }
            } else if !body.isEmpty, token.last == "." || token.last == ")", Int(token.dropLast()) != nil {
                flush(); result.append(.item(String(token.dropLast()) + ".", body, depth))
            } else if !body.isEmpty && (1...6).contains(token.count) && token.allSatisfy({ $0 == "#" }) {
                flush(); result.append(.heading(token.count, body))
            } else { lines.append(line) }
        }
        flushQuote()
        flush()
        return result
    }

    /// Text with formulas goes through the formula renderer; the rest stays plain Text.
    @ViewBuilder fileprivate static func inline(_ value: String) -> some View {
        if value.contains("$") || value.contains("\\(") { MathInlineText(markdown: value) } else { AnswerInline.text(value) }
    }

    var body: some View {
        let content = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(content.indices, id: \.self) { i in
                switch content[i] {
                case .paragraph(let value): Self.inline(value).modifier(TailFade(enabled: i == content.count - 1))
                case .heading(let level, let value):
                    Self.inline(value).font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : font.weight(.semibold))
                        .padding(.top, i > 0 ? 4 : 0).modifier(TailFade(enabled: i == content.count - 1))
                case .item(let marker, let value, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(ChatColors.muted).monospacedDigit()
                        Self.inline(value).modifier(TailFade(enabled: i == content.count - 1))
                    }.padding(.leading, 4 + CGFloat(depth) * 16)
                case .code(let code, let language) where language?.lowercased() == "mermaid":
                    DiagramBlockView(source: code, font: font)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language, font: font)
                case .math(let tex):
                    MathBlockView(tex: tex, font: font)
                case .table(let rows):
                    AnswerTable(rows: rows)
                case .quote(let value, let callout):
                    QuoteBlock(text: value, callout: callout, font: font)
                case .rule:
                    Divider().overlay(ChatColors.line).padding(.vertical, 4)
                }
            }
        }.font(font).lineSpacing(6)
    }
}

private struct QuoteBlock: View {
    let text: String
    let callout: ChatAnswer.Callout?
    let font: Font
    var body: some View {
        let tint = callout?.color ?? ChatColors.muted
        VStack(alignment: .leading, spacing: 4) {
            if let callout {
                Label(callout.title, systemImage: callout.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            }
            if !text.isEmpty {
                ChatAnswer(text: text, font: font).foregroundStyle(callout == nil ? ChatColors.muted : ChatColors.ink)
            }
        }
        .padding(.leading, 12).padding(.vertical, callout == nil ? 0 : 8).padding(.trailing, callout == nil ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(callout == nil ? Color.clear : tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(tint.opacity(callout == nil ? 0.5 : 0.8)).frame(width: 3) }
    }
}

/// A fenced code block: the language (or `text`) on a header bar with 自动换行 / 不换行 and 复制.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let font: Font
    @State private var wrap = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(verbatim: language?.isEmpty == false ? language! : "text")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(ChatColors.muted).lineLimit(1)
                Spacer(minLength: 8)
                Button { wrap.toggle() } label: {
                    Image(systemName: "text.word.spacing").font(.system(size: 12))
                        .foregroundStyle(wrap ? Color.accentColor : ChatColors.muted).frame(width: 30, height: 28)
                }.buttonStyle(.plain).accessibilityLabel(wrap ? "不换行" : "自动换行")
                Button {
                    PlatformPasteboard.copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .milliseconds(1400)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption).foregroundStyle(copied ? Color.accentColor : ChatColors.muted)
                        .padding(.horizontal, 6).frame(height: 28)
                }.buttonStyle(.plain).accessibilityLabel(copied ? "已复制" : "复制代码")
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .background(ChatColors.muted.opacity(0.08))
            Group {
                if wrap {
                    Text(verbatim: code).font(font.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    ScrollView(.horizontal) {
                        Text(verbatim: code).font(font.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false).padding(12)
                    }.accessibilityIdentifier("horizontalAnswer")
                }
            }.font(font.monospaced())
        }
        .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// How chat tables are tinted, stored by raw value in tableTint.
enum ChatTableTint: String, CaseIterable, Identifiable {
    case follow, fill, none
    var id: Self { self }

    var title: String {
        switch self {
        case .follow: String(localized: "跟随主题")
        case .fill: String(localized: "淡底整表")
        case .none: String(localized: "无底色")
        }
    }

    var surface: Color {
        switch self {
        case .follow: ChatColors.chip
        case .fill: ChatColors.muted.opacity(0.09)
        case .none: .clear
        }
    }

    var header: Color {
        switch self {
        case .follow: Color.accentColor.opacity(0.12)
        case .fill: ChatColors.muted.opacity(0.12)
        case .none: .clear
        }
    }
}

enum ChatTable {
    static func cells(_ input: String) -> [String]? {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard line.contains("|") else { return nil }
        var cells: [String] = [], cell = "", escape = false
        for character in line {
            if escape {
                if character != "|" { cell.append("\\") }
                cell.append(character); escape = false
            } else if character == "\\" { escape = true }
            else if character == "|" { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escape { cell.append("\\") }
        guard !cells.isEmpty else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if line.hasPrefix("|") { cells.removeFirst() }
        if cells.last == "" && line.hasSuffix("|") { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    static func divides(_ line: String, columns: Int) -> Bool {
        guard let cells = cells(line), cells.count == columns else { return false }
        return cells.allSatisfy { value in
            var body = value[...]
            if body.first == ":" { body = body.dropFirst() }
            if body.last == ":" { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }
}

private struct AnswerTable: View {
    let rows: [[String]]
    @AppStorage("tableTint") private var tint = ChatTableTint.follow

    var body: some View {
        ScrollView(.horizontal) {
            AnswerTableLayout(columns: rows.first?.count ?? 1) {
                ForEach(rows.indices, id: \.self) { row in
                    ForEach(rows[row].indices, id: \.self) { column in
                        ChatAnswer.inline(rows[row][column])
                            .fontWeight(row == 0 ? .semibold : .regular)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(row == 0 ? tint.header : .clear)
                            .overlay(alignment: .bottom) {
                                if row < rows.count - 1 { Rectangle().fill(ChatColors.line).frame(height: 0.5) }
                            }
                    }
                }
            }
        }
        .background(tint.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("horizontalAnswer")
    }
}

/// With an unconstrained horizontal scroll view, measure at the final column widths
/// before laying out the rows. A cell's single-line ideal height can be much too small.
private struct AnswerTableLayout: Layout {
    let columns: Int

    struct Cache {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache {
        var widths = Array(repeating: CGFloat.zero, count: columns)
        for (index, cell) in subviews.enumerated() {
            let column = index % columns
            widths[column] = max(widths[column], min(320, cell.sizeThatFits(.unspecified).width))
        }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for (index, cell) in subviews.enumerated() {
            let row = index / columns
            let size = cell.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil))
            heights[row] = max(heights[row], size.height)
        }
        return Cache(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var x = bounds.minX, y = bounds.minY
        for (index, cell) in subviews.enumerated() {
            let column = index % columns, row = index / columns
            let width = cache.widths[column], height = cache.heights[row]
            cell.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
            x += width
            if column == columns - 1 { x = bounds.minX; y += height }
        }
    }
}
