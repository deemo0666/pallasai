import Foundation

enum ReplyNotificationPreview {
    /// The first sentence of a reply, without Markdown marks, at most 80 characters.
    static func firstSentence(_ reply: String?) -> String? {
        guard let reply else { return nil }
        var fenced = false
        for raw in reply.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); continue }
            if fenced || line.hasPrefix("|") { continue }
            line = String(line.drop { "#>-*+ ".contains($0) })
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard line.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if let end = line.firstIndex(where: { "。！？!?".contains($0) }) { line = String(line[...end]) }
            return line.count > 80 ? String(line.prefix(80)) + "…" : line
        }
        return nil
    }
}
