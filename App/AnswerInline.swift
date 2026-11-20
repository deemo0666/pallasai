import SwiftUI

struct InlineCodeSpan: TextAttribute {}

/// 回复正文的绘制：行内代码先画圆角底块和发丝边，再画字；流式时末尾 `fade` 个字
/// 按离末尾的距离从透明到不透明（iOS 18 起）。
@available(iOS 18.0, *)
struct AnswerTextRenderer: TextRenderer {
    var fade: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[InlineCodeSpan.self] != nil {
                let box = run.typographicBounds.rect.insetBy(dx: 0, dy: -1)
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous).path(in: box)
                context.fill(shape, with: .color(ChatColors.codeWell))
                context.stroke(shape, with: .color(ChatColors.codeWellBorder), lineWidth: 0.5)
            }
        }
        guard fade > 0 else {
            for line in layout { context.draw(line) }
            return
        }
        var slices: [Text.Layout.RunSlice] = []
        for line in layout { for run in line { for slice in run { slices.append(slice) } } }
        let total = slices.count
        for (index, slice) in slices.enumerated() {
            var copy = context
            copy.opacity = min(1, Double(total - index) / max(1, fade))
            copy.draw(slice)
        }
    }
}

/// 回复里的一段文字：行内 Markdown，行内代码是等宽 0.875 倍、带底块（iOS 17 是平的底色）。
enum AnswerInline {
    /// 正文字号的 0.875 倍，跟着「对话字号」和系统字号。
    static var codeFont: Font {
        #if os(macOS)
        return .system(size: 13, design: .monospaced)
        #else
        let size = ChatTypeSize(rawValue: UserDefaults.standard.string(forKey: "chatTypeSize") ?? "")?.factor ?? 1
        return Font(UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 14 * size, weight: .regular)))
        #endif
    }

    /// The inline Markdown of a reply. A link written as code is still a link: models often put
    /// the page to open in backticks.
    static func parse(_ markdown: String) -> AttributedString? {
        guard var parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return nil
        }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true && run.link == nil {
            let words = String(parsed[run.range].characters).trimmingCharacters(in: .whitespaces)
            if !words.contains(" "), let url = URL(string: words), BrowserRoute.accepts(url) { parsed[run.range].link = url }
        }
        // Underlined, so a link reads as something to tap and not only as coloured words.
        for run in parsed.runs where run.link != nil { parsed[run.range].underlineStyle = .single }
        return parsed
    }

    static func text(_ markdown: String) -> Text {
        guard let parsed = parse(markdown) else { return Text(verbatim: markdown) }
        guard parsed.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { return Text(parsed) }
        var result = Text(verbatim: "")
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                // Narrow no-break spaces either side give the block its margins and keep them on
                // the code's line (a thin space would wrap away and leave an empty block behind).
                piece = AttributedString("\u{202F}") + piece + AttributedString("\u{202F}")
                piece.inlinePresentationIntent = nil
                let code = Text(piece).font(codeFont).foregroundColor(ChatColors.ink)
                if #available(iOS 18.0, *) {
                    result = Text("\(result)\(code.customAttribute(InlineCodeSpan()))")
                } else {
                    piece.backgroundColor = ChatColors.codeWell
                    result = Text("\(result)\(Text(piece).font(codeFont))")
                }
            } else {
                result = Text("\(result)\(Text(piece))")
            }
        }
        return result
    }
}

private struct AnswerTailFadeKey: EnvironmentKey { static let defaultValue: Double = 0 }

extension EnvironmentValues {
    /// 回复末尾还在淡入的字数（0：不淡入）。
    var answerTailFade: Double {
        get { self[AnswerTailFadeKey.self] }
        set { self[AnswerTailFadeKey.self] = newValue }
    }
}

/// 行内代码那一段（iOS 18 起由 [AnswerTextRenderer] 画底块）。
@available(iOS 18.0, *)
struct TailFade: ViewModifier {
    /// 只给回复的最后一块淡入。
    var enabled = true
    @Environment(\.answerTailFade) private var count

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.textRenderer(AnswerTextRenderer(fade: enabled ? count : 0))
        } else {
            content
        }
    }
}
