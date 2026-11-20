import Foundation

extension String {
    /// 以中文原文为键取当前语言的译文，用于运行时才知道的文案（中文 rawValue、存储的中文标识）。
    var localized: String { String(localized: LocalizationValue(self)) }

    /// 引擎或主机传来的文字：目录里有这个中文键就换成译文，没有就原样返回。不做格式替换。
    var hostLocalized: String { Bundle.main.localizedString(forKey: self, value: self, table: nil) }
}

/// 界面实际显示的语言（跟随系统或 iOS 设置里为本 App 选的语言）。
enum AppLanguage {
    /// 界面语言的完整标识，小写，如 "zh-hans"、"zh-hant"、"pt-br"、"ja"。
    static var identifier: String { (Bundle.main.preferredLocalizations.first ?? "zh-Hans").lowercased() }

    /// "zh" 或 "en"：传给只认中英文的引擎和服务。其他语言按英文。
    static var code: String { isChinese ? "zh" : "en" }
    static var isChinese: Bool { identifier.hasPrefix("zh") }

    /// 从 `{zh: …, en: …}` 这类多语言文本里取界面语言那一份：先找完整标识（zh-Hant），再找语言（ja），
    /// 再退到英文、中文、任意一份。
    static func pick(_ texts: [String: String]) -> String? {
        func first(_ prefix: String) -> String? { texts.first { $0.key.lowercased().hasPrefix(prefix) }?.value }
        let language = String(identifier.prefix { $0 != "-" })
        return texts.first { $0.key.lowercased().replacingOccurrences(of: "_", with: "-") == identifier }?.value
            ?? first(language) ?? texts[""] ?? first("en") ?? first("zh") ?? texts.sorted { $0.key < $1.key }.first?.value
    }
}

/// 本 App 的界面语言选择。写的是本 App 自己的 `AppleLanguages`，与 iOS 设置里本 App 的「语言」是同一个值，
/// 重新打开 App 后生效。
enum AppLanguageChoice: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", english = "en", japanese = "ja", korean = "ko"
    case spanish = "es", french = "fr", german = "de", portuguese = "pt-BR", italian = "it", russian = "ru"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        // 语言名用它自己的文字写，换到哪种语言都认得出。
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .portuguese: "Português (Brasil)"
        case .italian: "Italiano"
        case .russian: "Русский"
        }
    }

    /// 当前存着的选择（含在 iOS 设置里选的）。
    static var current: AppLanguageChoice {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return match(first) ?? .system
    }

    /// 把 "zh-Hant-TW"、"pt-PT"、"es-419" 这类系统语言标识对到本 App 的语言；没有对应的返回 nil。
    static func match(_ identifier: String) -> AppLanguageChoice? {
        let id = identifier.lowercased()
        if id.hasPrefix("zh") {
            return id.hasPrefix("zh-hant") || id.hasPrefix("zh-tw") || id.hasPrefix("zh-hk") || id.hasPrefix("zh-mo")
                ? .traditionalChinese : .simplifiedChinese
        }
        let language = String(id.prefix { $0 != "-" && $0 != "_" })
        return allCases.first { $0 != .system && $0.rawValue.lowercased().hasPrefix(language) }
    }

    /// 存下选择；返回它是否和界面正在用的语言不同（需要重新打开）。
    @discardableResult func apply() -> Bool {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
        let next = self == .system ? Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: Locale.preferredLanguages).first
                                   : rawValue
        return AppLanguageChoice.match(next ?? "en") != AppLanguageChoice.match(AppLanguage.identifier)
    }
}
