import Foundation

struct BrowserRoute: Identifiable {
    let id = UUID()
    let url: URL?

    static func accepts(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    /// A bare link in a reply ends only at a space, so "…/abc。" or "…/abc，再登录" takes the
    /// sentence along, and a page that checks its path (a plugin's local status page) refuses it.
    /// Cut at the first full-width punctuation mark, and for this phone's own pages, where paths
    /// are plain ASCII, at the first character that is not.
    static func trimmed(_ url: URL) -> URL {
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let local = ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        guard let cut = text.firstIndex(where: { punctuation.contains($0) || (local && !$0.isASCII) }), cut > text.startIndex,
              let shorter = URL(string: String(text[..<cut])) else { return url }
        return shorter
    }

    private static let punctuation = Set("。，、；：！？）」』】》〉…“”‘’（「『【《〈　～")

    /// Links in a reply to pages this phone serves itself, in order, each once, at most three.
    static func localPages(in markdown: String) -> [URL] {
        guard markdown.contains("127.0.0.1") || markdown.contains("localhost"),
              let parsed = AnswerInline.parse(markdown) else { return [] }
        var pages: [URL] = []
        for run in parsed.runs {
            guard let link = run.link, accepts(link), ["127.0.0.1", "localhost"].contains(link.host?.lowercased() ?? "") else { continue }
            let page = trimmed(link)
            if !pages.contains(page) { pages.append(page) }
        }
        return Array(pages.prefix(3))
    }
}
