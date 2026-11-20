import SwiftUI

enum ChatTypeSize: String, CaseIterable {
    case small = "小", standard = "标准", large = "大", extraLarge = "特大"

    /// 对话正文 16 号的倍数；在系统字号之上再缩放。
    var factor: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }

    var font: Font {
        #if os(macOS)
        .system(size: points)
        #else
        Font(UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16 * factor)))
        #endif
    }

    var points: CGFloat {
        #if os(macOS)
        16 * factor
        #else
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 16 * factor)
        #endif
    }
}
