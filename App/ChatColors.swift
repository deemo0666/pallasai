import SwiftUI
#if os(macOS)
import AppKit
#endif

enum ChatColors {
    static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func components(_ isDark: Bool) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let rgb = isDark ? dark : light
            return (CGFloat((rgb >> 16) & 255) / 255, CGFloat((rgb >> 8) & 255) / 255,
                    CGFloat(rgb & 255) / 255, isDark ? darkAlpha : lightAlpha)
        }
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b, a) = components(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        })
        #else
        return Color(uiColor: UIColor { style in
            let (r, g, b, a) = components(style.userInterfaceStyle == .dark)
            return UIColor(red: r, green: g, blue: b, alpha: a)
        })
        #endif
    }
    static let ink = adaptive(0x202633, 0xe1e5ec)
    static let muted = adaptive(0x586273, 0xa4acba)
    /// 过程行的标签（思考、工具动词）：比正文安静一档。
    static let secondary = adaptive(0x4f5562, 0xb6bbc5)
    /// 过程行的细节（命令、路径、思考预览和实时窗口）：再安静一档。
    static let tertiary = adaptive(0x646974, 0x9a9ea9)
    /// 行内代码和代码块的底与边。
    static let codeWell = adaptive(0xedf0f6, 0x14171e)
    static let codeWellBorder = adaptive(0xdbdee5, 0x2f333a)
    static let panel = adaptive(0xf6f7fa, 0x202630)
    static let chip = adaptive(0xffffff, 0x272e39)
    static let user = adaptive(0xe6edf8, 0x283244)
    static let line = adaptive(0xcbd2de, 0x49515e).opacity(0.65)
    /// Text on a filled accent: the accents are dark in light mode and light in dark mode.
    static let onAccent = adaptive(0xffffff, 0x1c2029)
    /// 主操作（新对话、发送、选中的筛选、完成）：始终是墨色，不随主题配色变。
    static let primary = adaptive(0x202633, 0xe1e5ec)
    static let onPrimary = adaptive(0xffffff, 0x1c2029)
    /// 设置、侧栏、全部功能的纯色页面底（聊天页仍用 `canvas`）。
    static let page = adaptive(0xf2f3f7, 0x1b1f27)
    /// 行内图标的底。
    static let tile = adaptive(0xeceef3, 0x353c49)
    /// 选中行的底：正文色 8%（深色 10%）。
    static let selected = adaptive(0x202633, 0xe1e5ec, lightAlpha: 0.08, darkAlpha: 0.1)
    /// 分段控件的灰底和选中段。
    static let segmentWell = adaptive(0x586273, 0xa4acba, lightAlpha: 0.10, darkAlpha: 0.14)
    static let segmentOn = adaptive(0xffffff, 0x465064)
    static var canvas: LinearGradient {
        // One flat, neutral colour: the old blue-to-violet wash made every white surface on it look grey.
        LinearGradient(colors: [adaptive(0xf5f5f7, 0x1b1c1f), adaptive(0xf5f5f7, 0x1b1c1f)], startPoint: .top, endPoint: .bottom)
    }
}
