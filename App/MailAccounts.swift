#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// A mail service the person signs in to with its own page (OAuth with PKCE, no client secret on the phone).
enum MailProvider: String, Codable, CaseIterable, Identifiable {
    case google, microsoft
    var id: String { rawValue }

    /// The `account` a tool call names: gmail or outlook (the service names work too).
    init?(account: String) {
        switch account.lowercased() {
        case "gmail", "google": self = .google
        case "outlook", "microsoft", "hotmail": self = .microsoft
        default: return nil
        }
    }

    var account: String { self == .google ? "gmail" : "outlook" }
    var connector: ConnectorID { self == .google ? .gmail : .outlook }

    /// From Info.plist, filled from the PALLAS_GOOGLE_CLIENT_ID / PALLAS_MICROSOFT_CLIENT_ID build settings.
    var clientID: String? {
        let key = self == .google ? "PallasGoogleClientID" : "PallasMicrosoftClientID"
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    /// Google's iOS clients answer on the reversed client ID; Microsoft's on msauth.<bundle id>.
    var callbackScheme: String? {
        guard let clientID else { return nil }
        switch self {
        case .google: return clientID.split(separator: ".").reversed().joined(separator: ".")
        case .microsoft: return "msauth." + (Bundle.main.bundleIdentifier ?? "")
        }
    }

    var redirect: String? {
        guard let scheme = callbackScheme else { return nil }
        return self == .google ? scheme + ":/oauth2redirect" : scheme + "://auth"
    }

    fileprivate var authorizeURL: String {
        self == .google ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    }

    fileprivate var tokenURL: String {
        self == .google ? "https://oauth2.googleapis.com/token" : "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    }

    /// Read and send. Nothing that deletes, moves or changes settings.
    fileprivate var scopes: String {
        switch self {
        case .google: "openid email https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send"
        case .microsoft: "openid email offline_access User.Read Mail.Read Mail.Send"
        }
    }
}

/// Signed-in mail accounts and the mail calls the `email` tool makes. Tokens stay in the keychain.
@MainActor
final class MailAccounts: NSObject, ObservableObject {
    static let shared = MailAccounts()

    struct Account: Codable, Equatable { let address: String }

    private struct Credential: Codable {
        var access: String
        var refresh: String?
        var expiry: Date
        var address: String
    }

    @Published private(set) var accounts: [MailProvider: Account] = [:]
    @Published private(set) var signingIn: MailProvider?

    private var session: ASWebAuthenticationSession?
    private var refreshing: [MailProvider: Task<Credential, Error>] = [:]

    override private init() {
        super.init()
        for provider in MailProvider.allCases {
            if let saved = Self.load(provider) { accounts[provider] = Account(address: saved.address) }
        }
    }

    func account(_ provider: MailProvider) -> Account? { accounts[provider] }

    private static func vaultKey(_ provider: MailProvider) -> String { "mail." + provider.rawValue }

    private static func load(_ provider: MailProvider) -> Credential? {
        guard let text = try? Vault.read(vaultKey(provider)), !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: Data(text.utf8))
    }

    private func store(_ credential: Credential?, _ provider: MailProvider) throws {
        let text = try credential.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try Vault.save(text, account: Self.vaultKey(provider))
        accounts[provider] = credential.map { Account(address: $0.address) }
    }

    // MARK: Signing in

    /// Opens the service's sign-in page. Returns a short message on failure, nil on success or when the page was closed.
    func signIn(_ provider: MailProvider) async -> String? {
        guard let clientID = provider.clientID, let redirect = provider.redirect, let scheme = provider.callbackScheme else {
            return String(localized: "这个版本没有配置 \(provider.connector.title) 登录。")
        }
        signingIn = provider
        defer { signingIn = nil; session = nil }
        do {
            let verifier = Self.random()
            let state = Self.random()
            var url = URLComponents(string: provider.authorizeURL)!
            var items: [URLQueryItem] = [
                .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"), .init(name: "scope", value: provider.scopes),
                .init(name: "state", value: state), .init(name: "code_challenge_method", value: "S256"),
                .init(name: "code_challenge", value: Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            ]
            if provider == .google { items += [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")] }
            else { items.append(.init(name: "prompt", value: "select_account")) }
            url.queryItems = items
            let back = try await browse(url.url!, scheme: scheme)
            let query = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            guard value("state") == state else { throw HostError(String(localized: "登录页返回的结果对不上，请重试。")) }
            if let error = value("error") {
                return error == "access_denied" ? nil : String(localized: "登录没有完成：") + (value("error_description") ?? error)
            }
            guard let code = value("code") else { throw HostError(String(localized: "登录页没有返回授权。")) }
            let token = try await tokenRequest(provider, [
                "grant_type": "authorization_code", "code": code, "client_id": clientID,
                "redirect_uri": redirect, "code_verifier": verifier, "scope": provider.scopes,
            ])
            var credential = try credential(token, provider, previous: nil)
            if credential.address.isEmpty { credential.address = try await address(provider, access: credential.access) }
            try store(credential, provider)
            return nil
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Forgets the tokens here and, for Google, revokes them there.
    func signOut(_ provider: MailProvider) async {
        let saved = Self.load(provider)
        try? store(nil, provider)
        if provider == .google, let token = saved?.refresh ?? saved?.access {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form(["token": token]).utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func browse(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? CancellationError()) }
            }
            web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = false
            session = web
            if !web.start() { continuation.resume(throwing: HostError(String(localized: "没能打开登录页。"))) }
        }
    }

    private func tokenRequest(_ provider: MailProvider, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: provider.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, object["access_token"] is String else {
            let reason = object["error_description"] as? String ?? object["error"] as? String ?? ""
            throw AppleData.Failure("auth_failed", "Signing in to \(provider.account) failed. \(reason)")
        }
        return object
    }

    private func credential(_ token: [String: Any], _ provider: MailProvider, previous: Credential?) throws -> Credential {
        let access = token["access_token"] as? String ?? ""
        let seconds = (token["expires_in"] as? Double) ?? Double(token["expires_in"] as? String ?? "") ?? 3600
        var address = previous?.address ?? ""
        if address.isEmpty, let id = token["id_token"] as? String { address = Self.claims(id)["email"] as? String ?? "" }
        return Credential(access: access, refresh: token["refresh_token"] as? String ?? previous?.refresh,
                          expiry: Date().addingTimeInterval(seconds), address: address)
    }

    private func address(_ provider: MailProvider, access: String) async throws -> String {
        let url = provider == .google ? "https://gmail.googleapis.com/gmail/v1/users/me/profile" : "https://graph.microsoft.com/v1.0/me"
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return object["emailAddress"] as? String ?? object["mail"] as? String ?? object["userPrincipalName"] as? String ?? ""
    }

    private func accessToken(_ provider: MailProvider, forceRefresh: Bool = false) async throws -> String {
        guard let saved = Self.load(provider) else {
            throw AppleData.Failure("not_connected", "\(provider.account) is not connected. Ask the user to connect it in Pallas Agent → Settings → Connectors.")
        }
        if !forceRefresh, saved.expiry.timeIntervalSinceNow > 60 { return saved.access }
        if let running = refreshing[provider] { return try await running.value.access }
        let task = Task { () throws -> Credential in
            guard let refresh = saved.refresh, let clientID = provider.clientID else {
                throw AppleData.Failure("not_connected", "The \(provider.account) sign-in expired. Ask the user to connect it again in Settings → Connectors.")
            }
            var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]
            if provider == .microsoft { fields["scope"] = provider.scopes }
            let token: [String: Any]
            do { token = try await tokenRequest(provider, fields) } catch {
                throw AppleData.Failure("not_connected", "The \(provider.account) sign-in expired. Ask the user to connect it again in Settings → Connectors.")
            }
            let next = try credential(token, provider, previous: saved)
            try store(next, provider)
            return next
        }
        refreshing[provider] = task
        defer { refreshing[provider] = nil }
        return try await task.value.access
    }

    // MARK: Mail calls

    private func call(_ provider: MailProvider, _ method: String, _ url: URL, json: Any? = nil,
                      headers: [String: String] = [:], retried: Bool = false) async throws -> [String: Any] {
        let token = try await accessToken(provider, forceRefresh: retried)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried { return try await call(provider, method, url, json: json, headers: headers, retried: true) }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AppleData.Failure(status == 404 ? "not_found" : status == 403 ? "forbidden" : "mail_failed", "\(provider.account) answered \(status): \(message)")
        }
        return object
    }

    private static func pathPart(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    private static let bodyLimit = 20_000

    func search(_ provider: MailProvider, query: String?, limit: Int) async throws -> [String: Any] {
        let limit = min(max(limit, 1), 20)
        switch provider {
        case .google:
            var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            url.queryItems = [.init(name: "maxResults", value: String(limit))] + (query.map { [.init(name: "q", value: $0)] } ?? [])
            let list = try await call(provider, "GET", url.url!)
            let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            var rows: [[String: Any]] = []
            for id in ids {
                var one = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + Self.pathPart(id))!
                one.queryItems = [.init(name: "format", value: "metadata")] + ["From", "To", "Subject", "Date"].map { .init(name: "metadataHeaders", value: $0) }
                let message = try await call(provider, "GET", one.url!)
                let headers = Self.gmailHeaders(message["payload"] as? [String: Any])
                rows.append(["id": id, "from": headers["from"] ?? "", "subject": headers["subject"] ?? "", "date": headers["date"] ?? "",
                             "snippet": message["snippet"] as? String ?? "",
                             "unread": (message["labelIds"] as? [String] ?? []).contains("UNREAD")])
            }
            return ["account": provider.account, "messages": rows]
        case .microsoft:
            var url = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
            var items: [URLQueryItem] = [.init(name: "$top", value: String(limit)),
                                         .init(name: "$select", value: "id,subject,from,receivedDateTime,bodyPreview,isRead")]
            if let query, !query.isEmpty { items.append(.init(name: "$search", value: "\"" + query.replacingOccurrences(of: "\"", with: " ") + "\"")) }
            else { items.append(.init(name: "$orderby", value: "receivedDateTime desc")) }
            url.queryItems = items
            let list = try await call(provider, "GET", url.url!)
            let rows: [[String: Any]] = (list["value"] as? [[String: Any]] ?? []).map { message in
                ["id": message["id"] as? String ?? "", "from": Self.graphAddress(message["from"]), "subject": message["subject"] as? String ?? "",
                 "date": message["receivedDateTime"] as? String ?? "", "snippet": message["bodyPreview"] as? String ?? "",
                 "unread": !(message["isRead"] as? Bool ?? true)]
            }
            return ["account": provider.account, "messages": rows]
        }
    }

    func read(_ provider: MailProvider, id: String) async throws -> [String: Any] {
        switch provider {
        case .google:
            var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + Self.pathPart(id))!
            url.queryItems = [.init(name: "format", value: "full")]
            let message = try await call(provider, "GET", url.url!)
            let payload = message["payload"] as? [String: Any]
            let headers = Self.gmailHeaders(payload)
            return ["account": provider.account, "id": id, "thread_id": message["threadId"] as? String ?? "",
                    "from": headers["from"] ?? "", "to": headers["to"] ?? "", "cc": headers["cc"] ?? "",
                    "subject": headers["subject"] ?? "", "date": headers["date"] ?? "",
                    "body": Self.clip(Self.gmailBody(payload) ?? message["snippet"] as? String ?? "")]
        case .microsoft:
            var url = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages/" + Self.pathPart(id))!
            url.queryItems = [.init(name: "$select", value: "subject,from,toRecipients,ccRecipients,receivedDateTime,body")]
            let message = try await call(provider, "GET", url.url!, headers: ["Prefer": "outlook.body-content-type=\"text\""])
            func list(_ key: String) -> String { (message[key] as? [Any] ?? []).map(Self.graphAddress).joined(separator: ", ") }
            return ["account": provider.account, "id": id, "from": Self.graphAddress(message["from"]), "to": list("toRecipients"),
                    "cc": list("ccRecipients"), "subject": message["subject"] as? String ?? "",
                    "date": message["receivedDateTime"] as? String ?? "",
                    "body": Self.clip((message["body"] as? [String: Any])?["content"] as? String ?? "")]
        }
    }

    /// Sends after the caller has asked the person. A reply goes to the original sender when `to` is empty.
    func send(_ provider: MailProvider, to: [String], cc: [String], subject: String?, body: String, replyTo: String?) async throws -> [String: Any] {
        switch provider {
        case .google:
            var to = to, subject = subject ?? "", threadID: String?, extra: [String] = []
            if let replyTo {
                var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + Self.pathPart(replyTo))!
                url.queryItems = [.init(name: "format", value: "metadata")] + ["From", "Subject", "Message-ID", "References"].map { .init(name: "metadataHeaders", value: $0) }
                let original = try await call(provider, "GET", url.url!)
                let headers = Self.gmailHeaders(original["payload"] as? [String: Any])
                threadID = original["threadId"] as? String
                if to.isEmpty, let from = headers["from"] { to = [from] }
                if subject.isEmpty { subject = headers["subject"].map { $0.lowercased().hasPrefix("re:") ? $0 : "Re: " + $0 } ?? "" }
                if let messageID = headers["message-id"] {
                    extra = ["In-Reply-To: " + messageID, "References: " + ((headers["references"].map { $0 + " " } ?? "") + messageID)]
                }
            }
            guard !to.isEmpty else { throw AppleData.Failure("invalid_args", "Pass to: at least one email address.") }
            var lines = ["To: " + to.joined(separator: ", ")]
            if !cc.isEmpty { lines.append("Cc: " + cc.joined(separator: ", ")) }
            lines += ["Subject: =?UTF-8?B?" + Data(subject.utf8).base64EncodedString() + "?=", "MIME-Version: 1.0",
                      "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"] + extra
            let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + Data(body.utf8).base64EncodedString(options: .lineLength76Characters)
            var json: [String: Any] = ["raw": Self.base64url(Data(raw.utf8))]
            if let threadID { json["threadId"] = threadID }
            let sent = try await call(provider, "POST", URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!, json: json)
            return ["result": "sent", "account": provider.account, "id": sent["id"] as? String ?? ""]
        case .microsoft:
            func recipients(_ list: [String]) -> [[String: Any]] { list.map { ["emailAddress": ["address": $0]] } }
            if let replyTo {
                var json: [String: Any] = ["comment": body]
                if !to.isEmpty || !cc.isEmpty { json["message"] = ["toRecipients": recipients(to), "ccRecipients": recipients(cc)] }
                _ = try await call(provider, "POST", URL(string: "https://graph.microsoft.com/v1.0/me/messages/" + Self.pathPart(replyTo) + "/reply")!, json: json)
            } else {
                guard !to.isEmpty else { throw AppleData.Failure("invalid_args", "Pass to: at least one email address.") }
                let message: [String: Any] = ["subject": subject ?? "", "body": ["contentType": "Text", "content": body],
                                              "toRecipients": recipients(to), "ccRecipients": recipients(cc)]
                _ = try await call(provider, "POST", URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!,
                                   json: ["message": message, "saveToSentItems": true])
            }
            return ["result": "sent", "account": provider.account]
        }
    }

    // MARK: Parsing

    private static func gmailHeaders(_ payload: [String: Any]?) -> [String: String] {
        var out: [String: String] = [:]
        for header in payload?["headers"] as? [[String: Any]] ?? [] {
            if let name = header["name"] as? String, let value = header["value"] as? String { out[name.lowercased()] = value }
        }
        return out
    }

    /// The text/plain part, else the text/html part without tags.
    private static func gmailBody(_ payload: [String: Any]?) -> String? {
        var plain: String?, html: String?
        func walk(_ part: [String: Any]) {
            let type = (part["mimeType"] as? String ?? "").lowercased()
            if let data = (part["body"] as? [String: Any])?["data"] as? String, let bytes = decode(data) {
                let text = String(decoding: bytes, as: UTF8.self)
                if type == "text/plain", plain == nil { plain = text } else if type == "text/html", html == nil { html = text }
            }
            for child in part["parts"] as? [[String: Any]] ?? [] { walk(child) }
        }
        if let payload { walk(payload) }
        return plain ?? html.map(stripTags)
    }

    private static func stripTags(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</tr>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func graphAddress(_ value: Any?) -> String {
        guard let address = (value as? [String: Any])?["emailAddress"] as? [String: Any] else { return "" }
        let name = address["name"] as? String ?? "", mail = address["address"] as? String ?? ""
        return name.isEmpty || name == mail ? mail : "\(name) <\(mail)>"
    }

    private static func clip(_ text: String) -> String {
        text.count > bodyLimit ? String(text.prefix(bodyLimit)) + "\n[… cut at \(bodyLimit) characters]" : text
    }

    // MARK: Encoding

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }

    /// The payload of a token that came straight from the token endpoint over TLS; only its email is read.
    private static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1, let data = decode(String(parts[1])) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.sorted().joined(separator: "&")
    }
}

extension MailAccounts: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        }
    }
}
#endif
