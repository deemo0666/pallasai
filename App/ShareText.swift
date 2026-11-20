import Foundation

enum ShareText {
    private static let mask = "[已隐藏]"

    static func redacted(_ text: String) -> String {
        var output = text
        for (pattern, replacement) in rules {
            output = pattern.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: replacement)
        }
        return output
    }

    static func localizedRedactions(_ text: String) -> String {
        text.replacingOccurrences(of: mask, with: String(localized: "[已隐藏]"))
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (#"-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----[\s\S]*?(?:-----END \1-----|\z)"#, "[已隐藏]"),
        (#"(?i)\b(https?://[^/\s:@]+:)[^@/\s]+@"#, "$1[已隐藏]@"),
        (#"(?i)\b(?:sk-[a-z0-9_-]{12,}|gh[pousr]_[a-z0-9_]{12,}|github_pat_[a-z0-9_]{12,}|eyJ[\w-]+\.[\w-]+\.[\w-]+)\b"#, "[已隐藏]"),
        (#"(?i)(\bBearer\s+)[a-z0-9._~+/=-]+"#, "$1[已隐藏]"),
        (#"(?i)([\w-]*(?:api[_-]?key|token|password|secret)[\"']?\s*[:=]\s*)(?:\"(?:\\[^\r\n]|[^\"\\\r\n])*\"|'(?:\\[^\r\n]|[^'\\\r\n])*'|(?:\[已隐藏\]|[^\s,;&}\]])+)"#, "$1[已隐藏]"),
        (#"(?:/Users/|/home/)[^/\s]+"#, "~"),
        (#"(?i)\b[A-Z]:\\Users\\[^\\\s]+"#, "~"),
        (#"/data/(?:data/|user/\d+/)[\w.]+"#, "…"),
        (#"!\[([^\]]*)\]\([^\n)]*\)"#, "〔$1〕")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}

/// Tool calls and results as the chat keeps them, before redaction: at most 64 KiB a field, the
/// head and tail kept around a marker. JSON arguments stay JSON: strings up to 1 KiB stay whole
/// (paths, ids), longer ones are cut to a shared length. One huge output then cannot stall the
/// redaction rules and the drawing on the main thread.
enum Bounded {
    static let tool = 64 << 10
    private static let whole = 1 << 10

    static func text(_ text: String, limit: Int = tool) -> String {
        let size = text.utf8.count
        guard size > limit else { return text }
        let head = prefix(text, bytes: limit / 2), tail = suffix(text, bytes: limit / 2)
        let removed = ByteCountFormatter.string(fromByteCount: Int64(size - head.utf8.count - tail.utf8.count), countStyle: .file)
        return head + String(localized: "…（已截断 \(removed)）") + tail
    }

    static func arguments(_ text: String, limit: Int = tool) -> String {
        guard text.utf8.count > limit else { return text }
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)), value is [String: Any] || value is [Any]
        else { return Self.text(text, limit: limit) }
        var long = 0, short = 0
        visit(value) { let size = $0.utf8.count; if size > whole { long += 1 } else { short += size } }
        guard long > 0 else { return Self.text(text, limit: limit) }
        let cap = max(whole, (limit - short) / long)
        let bounded = map(value) { $0.utf8.count > cap ? Self.text($0, limit: cap) : $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: bounded, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return Self.text(text, limit: limit) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func visit(_ value: Any, _ body: (String) -> Void) {
        if let string = value as? String { body(string) }
        else if let object = value as? [String: Any] { object.values.forEach { visit($0, body) } }
        else if let array = value as? [Any] { array.forEach { visit($0, body) } }
    }

    private static func map(_ value: Any, _ body: (String) -> String) -> Any {
        if let string = value as? String { return body(string) }
        if let object = value as? [String: Any] { return object.mapValues { map($0, body) } }
        if let array = value as? [Any] { return array.map { map($0, body) } }
        return value
    }

    /// The longest prefix of at most `bytes` UTF-8 bytes that ends on a character boundary.
    private static func prefix(_ text: String, bytes: Int) -> String {
        var end = text.utf8.index(text.startIndex, offsetBy: bytes)
        while String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }

    private static func suffix(_ text: String, bytes: Int) -> String {
        var start = text.utf8.index(text.endIndex, offsetBy: -bytes)
        while String.Index(start, within: text) == nil { start = text.utf8.index(after: start) }
        return String(text[start...])
    }
}
