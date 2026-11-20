import CryptoKit
import Foundation

/// What this phone learned about a model of 第三方接入 or the DeepSeek account (name, efforts,
/// context window), keyed by service and model; the engine route is written from it.
struct ModelBudget {
    let window: Int
    let output: Int
    let source: String

    static func key(service: String, model: String) -> String {
        let digest = Data(SHA256.hash(data: Data((service + "\u{0}" + model).utf8))).base64EncodedString()
        return "context." + digest
    }

    static func resolve(_ key: String) -> Self {
        let settings = UserDefaults.standard
        let values = [(String(localized: "设置"), settings.integer(forKey: key + ".custom")),
                      (String(localized: "服务错误"), settings.integer(forKey: key + ".learned")),
                      (String(localized: "模型列表"), settings.integer(forKey: key + ".window"))]
        let (source, reported) = values.first { $0.1 > 0 } ?? (String(localized: "默认"), 262144)
        let window = min(reported, 1_000_000_000)
        let output = settings.integer(forKey: key + ".output")
        return Self(window: window, output: max(1, min(window / 4, output > 0 ? output : 32768)), source: source)
    }

    static func displayName(service: String, model: String) -> String {
        UserDefaults.standard.string(forKey: key(service: service, model: model) + ".displayName") ?? model
    }

    static func efforts(service: String, model: String) -> [String] {
        if let reported = UserDefaults.standard.stringArray(forKey: key(service: service, model: model) + ".efforts") { return reported }
        // 模型列表没报档位时按名字推：gpt-6 系列都支持 low 到 max。
        if model.hasPrefix("gpt-6") { return ["low", "medium", "high", "xhigh", "max"] }
        if model.range(of: #"^(gpt-5|o[0-9])"#, options: .regularExpression) != nil { return ["low", "medium", "high"] }
        return []
    }

    static func effortLabel(_ value: String) -> String {
        switch value {
        case "off", "none": return String(localized: "不思考")
        case "minimal": return String(localized: "极少")
        case "low": return String(localized: "低")
        case "medium": return String(localized: "中")
        case "high": return String(localized: "高")
        case "xhigh": return String(localized: "超高")
        case "max": return String(localized: "最高")
        default: return value
        }
    }

    static func register(_ entry: Object, service: String, account: Bool = false) {
        guard let id = entry["id"] as? String else { return }
        let key = key(service: service, model: id)
        if let name = entry["name"] as? String, !name.isEmpty { UserDefaults.standard.set(name, forKey: key + ".displayName") }
        if !account {
            let modalities = entry["input_modalities"] as? [String] ?? (entry["architecture"] as? Object)?["input_modalities"] as? [String]
            if let modalities { UserDefaults.standard.set(modalities.contains("image"), forKey: key + ".advertisedImage") }
        }
        if account {
            let advertised = (entry["effort"] as? Object)?["supported_levels"] as? [String] ?? []
            let levels = ["low", "high", "max"].filter(advertised.contains)
            UserDefaults.standard.set(levels.isEmpty ? [] : ["off"] + levels, forKey: key + ".efforts")
        } else if let efforts = entry["supported_reasoning_efforts"] as? [String] {
            UserDefaults.standard.set(efforts.filter { !$0.isEmpty }, forKey: key + ".efforts")
        }
        for (suffix, fields) in [("window", ["context_length", "context_window", "max_model_len", "max_context_length"]),
                                 ("output", ["max_completion_tokens", "max_output_tokens"])] {
            let candidates = [entry, entry["top_provider"] as? Object ?? [:]]
            let number = candidates.lazy.flatMap { source in fields.compactMap { source[$0] as? Int } }.first { $0 > 0 }
            if let number { UserDefaults.standard.set(number, forKey: key + "." + suffix) }
        }
    }
}
