import WebKit

@MainActor
final class BrowserTools: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = BrowserTools()
    let web = WKWebView()
    @Published private(set) var loadError: String?
    private var navigation: WKNavigation?
    private var waiter: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?

    override init() {
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
    }

    static var declarations: [Object] {
        [
            ("browser_open", "Open an HTTP or HTTPS address", ["url"]),
            ("browser_read", "Read visible text from the current page", []),
            ("browser_click", "Click the first element matching a CSS selector", ["selector"]),
            ("browser_type", "Set the text of a field matching a CSS selector", ["selector", "text"]),
            ("browser_back", "Return to the previous page", []),
            ("browser_run_js", "Evaluate JavaScript in the current browser page", ["script"])
        ].map { name, description, fields in
            let properties = Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": "string"]) })
            return ["type": "function", "name": name, "description": description,
                    "parameters": ["type": "object", "properties": properties, "required": fields, "additionalProperties": false] as Object]
        }
    }

    func perform(name: String, arguments: String) async throws -> String {
        let args = try JSONDecoder().decode([String: String].self, from: Data(arguments.utf8))
        switch name {
        case "browser_open":
            guard let url = URL(string: args["url"] ?? ""), BrowserRoute.accepts(url)
            else { throw HostError(String(localized: "网址无效。")) }
            try await navigate { web.load(URLRequest(url: url)) }
        case "browser_back":
            try await navigate { web.goBack() }
        case "browser_read":
            break
        case "browser_click":
            _ = try await web.callAsyncJavaScript("const e=document.querySelector(selector); if(!e) throw Error('Element missing'); e.click();",
                                                  arguments: ["selector": args["selector"] ?? ""], in: nil, contentWorld: .page)
        case "browser_type":
            _ = try await web.callAsyncJavaScript("const e=document.querySelector(selector); if(!e) throw Error('Field missing'); e.value=text; e.dispatchEvent(new Event('input',{bubbles:true}));",
                                                  arguments: ["selector": args["selector"] ?? "", "text": args["text"] ?? ""], in: nil, contentWorld: .page)
        case "browser_run_js":
            let result = try await web.evaluateJavaScript(args["script"] ?? "")
            return String(String(describing: result ?? "").prefix(16000))
        default: throw HostError(String(localized: "未知浏览器工具。"))
        }
        return try await web.evaluateJavaScript("document.body?.innerText.slice(0,16000) ?? ''") as? String ?? ""
    }

    private func navigate(_ start: () -> WKNavigation?) async throws {
        finish(throwing: CancellationError())
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            navigation = start()
            guard navigation != nil else { finish(throwing: HostError(String(localized: "没有可打开的页面。"))); return }
            timer = Task {
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled { finish(throwing: HostError(String(localized: "网页加载超时。"))) }
            }
        }
    }
    private func finish(throwing error: Error? = nil) {
        timer?.cancel()
        timer = nil
        navigation = nil
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
        waiter = nil
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, action.navigationType == .linkActivated,
           let url = action.request.url, BrowserRoute.accepts(url) { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }
    private func report(_ error: Error, navigation: WKNavigation?) {
        let issue = error as NSError
        if !(issue.domain == NSURLErrorDomain && issue.code == NSURLErrorCancelled) {
            loadError = error.localizedDescription
        }
        if self.navigation === navigation { finish(throwing: error) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if self.navigation === navigation { finish() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error, navigation: navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error, navigation: navigation)
    }
}
