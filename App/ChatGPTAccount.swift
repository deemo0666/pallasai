// 用 ChatGPT 登录（OpenAI 的 Sign in with ChatGPT，开源客户端的「ChatGPT plan usage」路线）。
//
// 首次登录用 `client_id=dynamic_agent_client` 动态注册，回调带回签发的 `oaiapp_…` client_id，之后
// 都用它；本机的 `ext_agent_host_id` 一次生成、长期不变。回调只能是 `http://127.0.0.1:<端口>/auth/callback`，
// 所以登录时在本机开一个回环监听，网页由 `ASWebAuthenticationSession` 打开；监听收到回调后把网页
// 302 到 `dshlocal://chatgpt-signin`，登录窗随之关闭。token 只存钥匙串（本机解锁时可读），App 自己
// 在到期前刷新，再用 `credentials/set` 交给本机引擎。引擎里是 `llm-pi-ai` 的 `openai` 渠道，地址固定
// `https://api.openai.com/v1`（pi-ai 据此去掉这条路线不接受的请求字段）。

import AuthenticationServices
#if os(macOS)
import AppKit
#endif
import CryptoKit
import Network
import SwiftUI

@MainActor
final class ChatGPTAccount: NSObject, ObservableObject {
    static let shared = ChatGPTAccount()

    private static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let discovery = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    private static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let usagePage = URL(string: "https://chatgpt.com/settings/usage")!
    private static let planScope = "chatgpt.tokens.use.direct"
    private static let scope = "openid profile email offline_access resource.invoke " + planScope
    private static let agentName = "Pallas Agent"
    #if os(macOS)
    private static let callbackScheme = "dshlocal-mac"
    #else
    private static let callbackScheme = "dshlocal"
    #endif
    /// Refresh this long before the access token runs out, so no request starts on one about to expire.
    private static let margin: TimeInterval = 5 * 60

    // Keychain items. The host ID and the registration outlive a sign-out; the tokens do not.
    private static let hostKey = "chatgpt-host-id"
    private static let registrationKey = "chatgpt-registration"
    private static let credentialKey = "chatgpt-credential"
    private static let modelsKey = "chatGPTModels"
    private static let welcomedKey = "chatGPTWelcomed"
    private static let activationKey = "chatGPTPendingActivation"

    /// The issued client and the account it belongs to.
    private struct Registration: Codable {
        var clientID: String
        var subject: String?
        var email: String?
    }

    private struct Credential: Codable {
        var access: String
        var refresh: String
        var idToken: String
        var expires: Date
        var scopes: [String]
    }

    struct Model: Codable, Hashable { let id: String; let name: String }

    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published private(set) var email: String?
    @Published private(set) var models: [Model] = []
    @Published var status = ""
    /// Shown once, after the first sign-in.
    @Published var welcome = false
    /// Bumped whenever what the engine should hold changes (sign-in, refresh, sign-out).
    @Published private(set) var revision = 0

    private let http = URLSession(configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil)
    private var listener: NWListener?
    private var session: ASWebAuthenticationSession?
    private var callback: CheckedContinuation<[URLQueryItem], Error>?
    private var expectedState = ""
    private var refreshing: Task<Credential, Error>?
    private var timer: Task<Void, Never>?
    private var modelRequest = 0

    override init() {
        super.init()
        let credential = Self.load(Credential.self, Self.credentialKey)
        signedIn = credential != nil
        email = Self.load(Registration.self, Self.registrationKey)?.email
        if signedIn {
            models = (UserDefaults.standard.data(forKey: Self.modelsKey)).flatMap { try? JSONDecoder().decode([Model].self, from: $0) } ?? []
            scheduleRefresh()
        }
    }

    var pendingActivation: Bool {
        get { UserDefaults.standard.bool(forKey: Self.activationKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.activationKey) }
    }

    /// The model a fresh sign-in makes the default.
    var preferredModel: String? { models.first?.id }

    // MARK: Keychain

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let text = try? Vault.read(key), !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private static func store<T: Encodable>(_ value: T?, _ key: String) throws {
        let text = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try Vault.save(text, account: key)
    }

    /// `urn:uuid:…`, made once for this phone and kept across sign-outs.
    private static func hostID() throws -> String {
        let saved = try Vault.read(hostKey)
        if !saved.isEmpty { return saved }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        try Vault.save(id, account: hostKey)
        return id
    }

    private static func random() -> String {
        base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Sign-in

    /// Runs the whole sign-in; returns what went wrong, or nil once signed in (or cancelled).
    @discardableResult
    func signIn() async -> String? {
        guard !busy else { return nil }
        busy = true; status = ""
        defer { busy = false; stopListening() }
        do {
            try await authorizeAndExchange()
            return nil
        } catch is CancellationError {
            return nil
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        } catch {
            let message = (error as? HostError)?.message ?? String(localized: "没能用 ChatGPT 登录，请再试一次。")
            Log.connection.error("chatgpt sign-in failed: \(String(describing: type(of: error)), privacy: .public)")
            status = message
            return message
        }
    }

    private func authorizeAndExchange() async throws {
        let host = try Self.hostID()
        let registration = Self.load(Registration.self, Self.registrationKey)
        let state = Self.random(), nonce = Self.random(), verifier = Self.random()
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let port = try await listen()
        let redirect = "http://127.0.0.1:\(port)/auth/callback"
        expectedState = state

        var query: [URLQueryItem] = [
            .init(name: "client_id", value: registration?.clientID ?? "dynamic_agent_client"),
            .init(name: "ext_agent_host_id", value: host),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: Self.scope),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        if registration == nil { query.append(.init(name: "agent_name_hint", value: Self.agentName)) }
        else if let email = registration?.email { query.append(.init(name: "login_hint", value: email)) }
        var parts = URLComponents(url: Self.authorize, resolvingAgainstBaseURL: false)!
        parts.queryItems = query
        // `URLComponents` leaves `+` alone; OAuth servers read it as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        let items = try await browse(parts.url!)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw HostError(error == "access_denied" ? String(localized: "没有同意使用 ChatGPT 套餐。") : String(localized: "ChatGPT 没有完成登录，请再试一次。"))
        }
        guard let code = value("code"), !code.isEmpty else { throw HostError(String(localized: "ChatGPT 没有完成登录，请再试一次。")) }
        let issued = value("client_id")?.trimmingCharacters(in: .whitespaces)
        let clientID: String
        if let saved = registration?.clientID {
            if let issued, !issued.isEmpty, issued != saved { throw HostError(String(localized: "ChatGPT 返回的应用登记和本机保存的不一致，请再试一次。")) }
            clientID = saved
        } else {
            guard let issued, !issued.isEmpty, issued != "dynamic_agent_client" else { throw HostError(String(localized: "ChatGPT 没有完成应用登记，请再试一次。")) }
            clientID = issued
        }
        // Keep the issued client even if a later step fails: the next attempt must reuse it.
        if registration == nil { try Self.store(Registration(clientID: clientID), Self.registrationKey) }

        let token = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource,
        ])
        guard let idToken = token["id_token"] as? String, !idToken.isEmpty else { throw HostError(String(localized: "ChatGPT 没有返回账号信息，请再试一次。")) }
        let claims = try await verify(idToken, clientID: clientID, nonce: nonce)
        guard let subject = claims["sub"] as? String, !subject.isEmpty else { throw HostError(String(localized: "ChatGPT 没有返回账号信息，请再试一次。")) }
        if let known = registration?.subject, known != subject {
            throw HostError(String(localized: "登录的不是原来那个 ChatGPT 账号。请选原来的账号再试。"))
        }
        let credential = try Self.credential(from: token, idToken: idToken)
        guard credential.scopes.contains(Self.planScope) else {
            try Self.store(Registration(clientID: clientID, subject: subject, email: claims["email"] as? String), Self.registrationKey)
            throw HostError(String(localized: "没有同意使用 ChatGPT 套餐。"))
        }
        let mail = claims["email"] as? String
        try Self.store(Registration(clientID: clientID, subject: subject, email: mail), Self.registrationKey)
        try Self.store(credential, Self.credentialKey)
        email = mail
        signedIn = true; status = ""
        try? await loadModels(credential.access)
        pendingActivation = true
        if !UserDefaults.standard.bool(forKey: Self.welcomedKey) {
            UserDefaults.standard.set(true, forKey: Self.welcomedKey)
            welcome = true
        }
        revision += 1
        scheduleRefresh()
    }

    /// Opens the loopback listener the browser returns to; answers with its port.
    private func listen() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: params)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { @MainActor in self?.read(connection, buffer: Data()) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            server.stateUpdateHandler = { change in
                guard !resumed else { return }
                switch change {
                case .ready:
                    resumed = true
                    if let port = server.port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: HostError(String(localized: "没能开始登录，请再试一次。"))) }
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(throwing: HostError(String(localized: "没能开始登录，请再试一次。")))
                default: break
                }
            }
            server.start(queue: .main)
        }
    }

    private func stopListening() {
        listener?.cancel(); listener = nil
        session?.cancel(); session = nil
        expectedState = ""
        callback?.resume(throwing: CancellationError()); callback = nil
    }

    /// Shows the sign-in page; returns the query of the callback the listener received.
    private func browse(_ url: URL) async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { [weak self] _, error in
                Task { @MainActor in
                    guard let self, let pending = self.callback else { return }
                    // The listener answers first; reaching here still pending means the page was closed.
                    self.callback = nil
                    pending.resume(throwing: error ?? CancellationError())
                }
            }
            web.presentationContextProvider = self
            session = web
            if !web.start() {
                callback = nil
                continuation.resume(throwing: HostError(String(localized: "没能打开 ChatGPT 登录页。")))
            }
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, done, error in
            Task { @MainActor in
                guard error == nil, let chunk else { connection.cancel(); return }
                let bytes = buffer + chunk
                guard bytes.count < 32768 else { connection.cancel(); return }
                let raw = String(decoding: bytes, as: UTF8.self)
                guard raw.contains("\r\n\r\n") else {
                    if done { connection.cancel() } else { self.read(connection, buffer: bytes) }
                    return
                }
                let fields = raw.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard fields.count == 3, fields[0] == "GET", let parts = URLComponents(string: String(fields[1])),
                      parts.path == "/auth/callback", !self.expectedState.isEmpty,
                      parts.queryItems?.filter({ $0.name == "state" }).map(\.value) == [self.expectedState],
                      let pending = self.callback else {
                    self.respond(connection, redirect: false); return
                }
                self.callback = nil
                self.respond(connection, redirect: true)
                pending.resume(returning: parts.queryItems ?? [])
            }
        }
    }

    /// The good callback goes back to the app's scheme, which closes the sign-in page.
    private func respond(_ connection: NWConnection, redirect: Bool) {
        let head = redirect
            ? "HTTP/1.1 302 Found\r\nLocation: \(Self.callbackScheme)://chatgpt-signin\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
            : "HTTP/1.1 400 Bad Request\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Tokens

    private func tokenRequest(_ form: [String: String]) async throws -> Object {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formBody(form).utf8)
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? Object
        guard status == 200, let json else {
            let code = json?["error"] as? String ?? (json?["error"] as? Object)?["code"] as? String ?? ""
            Log.connection.error("chatgpt token endpoint http \(status, privacy: .public) \(code, privacy: .public)")
            throw TokenFailure(status: status, code: code)
        }
        return json
    }

    private struct TokenFailure: Error, LocalizedError {
        let status: Int, code: String
        /// The refresh token itself is no good: only signing in again helps.
        var terminal: Bool {
            ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
             "refresh_token_invalidated", "refresh_token_reused", "invalid_client"].contains(code)
        }
        var errorDescription: String? { String(localized: "ChatGPT 没有完成登录，请再试一次。") }
    }

    private static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
    }

    private static func credential(from token: Object, idToken: String) throws -> Credential {
        guard let access = token["access_token"] as? String, !access.isEmpty,
              let refresh = token["refresh_token"] as? String, !refresh.isEmpty,
              let seconds = (token["expires_in"] as? NSNumber)?.doubleValue, seconds > 0 else {
            throw HostError(String(localized: "ChatGPT 没有完成登录，请再试一次。"))
        }
        let scopes = (token["scope"] as? String ?? "").split(separator: " ").map(String.init)
        return Credential(access: access, refresh: refresh, idToken: idToken, expires: Date().addingTimeInterval(seconds), scopes: scopes)
    }

    /// A usable access token, refreshed first when it is about to run out. Refreshes are serialized.
    func accessToken() async throws -> String {
        guard var credential = Self.load(Credential.self, Self.credentialKey) else {
            throw HostError(String(localized: "请先用 ChatGPT 登录。"))
        }
        if credential.expires.timeIntervalSinceNow < Self.margin { credential = try await refresh() }
        return credential.access
    }

    private func refresh() async throws -> Credential {
        if let refreshing { return try await refreshing.value }
        let task = Task<Credential, Error> { try await self.runRefresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func runRefresh() async throws -> Credential {
        guard let current = Self.load(Credential.self, Self.credentialKey),
              let registration = Self.load(Registration.self, Self.registrationKey) else {
            throw HostError(String(localized: "请先用 ChatGPT 登录。"))
        }
        do {
            let token = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": registration.clientID,
                "refresh_token": current.refresh, "resource": Self.resource,
            ])
            var next = try Self.credential(from: token, idToken: (token["id_token"] as? String) ?? current.idToken)
            if next.scopes.isEmpty { next.scopes = current.scopes }
            // Another refresh or a sign-out may have replaced the record meanwhile.
            guard Self.load(Credential.self, Self.credentialKey)?.refresh == current.refresh else {
                return Self.load(Credential.self, Self.credentialKey) ?? next
            }
            try Self.store(next, Self.credentialKey)
            revision += 1
            return next
        } catch let failure as TokenFailure where failure.terminal {
            try? Self.store(Optional<Credential>.none, Self.credentialKey)
            signedIn = false
            clearModels()
            status = String(localized: "ChatGPT 登录已失效，请重新登录。")
            revision += 1
            throw HostError(status)
        }
    }

    /// Refreshes shortly before each expiry while signed in; a failed try comes back a minute later.
    private func scheduleRefresh() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.signedIn, let credential = Self.load(Credential.self, Self.credentialKey) else { return }
                let wait = max(0, credential.expires.timeIntervalSinceNow - Self.margin)
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                do { _ = try await self.accessToken() }
                catch {
                    guard self.signedIn else { return }
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
        }
    }

    // MARK: Models

    /// `GET /v1/models` with the account's token: the models this account may use, in the server's order.
    func loadModels(_ access: String? = nil) async throws {
        modelRequest += 1
        let read = modelRequest
        let token: String
        if let access { token = access } else { token = try await accessToken() }
        var request = URLRequest(url: URL(string: Self.resource + "/models")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: request)
        try ModelService.check(response, request: request, stage: String(localized: "获取模型"))
        let list = try Self.visibleModels(in: data)
        try Task.checkCancellation()
        guard signedIn, modelRequest == read else { throw CancellationError() }
        if list != models {
            models = list
            UserDefaults.standard.set(try JSONEncoder().encode(list), forKey: Self.modelsKey)
            if pendingActivation && !list.isEmpty { revision += 1 }
        }
    }

    static func visibleModels(in data: Data) throws -> [Model] {
        let json = try JSONSerialization.jsonObject(with: data) as? Object
        let planModels = json?["models"] as? [Object]
        guard let rows = planModels ?? (json?["data"] as? [Object]) else {
            throw HostError(String(localized: "服务端没有返回模型列表。"))
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            if planModels != nil || row["visibility"] != nil {
                guard row["visibility"] as? String == "list" else { return nil }
            }
            guard let id = (row["slug"] as? String) ?? (row["id"] as? String), !id.isEmpty,
                  planModels != nil || ThirdPartyChannel.chats(id), seen.insert(id).inserted else { return nil }
            return Model(id: id, name: (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
    }

    private func clearModels() {
        modelRequest += 1
        models = []
        UserDefaults.standard.removeObject(forKey: Self.modelsKey)
    }

    // MARK: ID token

    /// Checks the ID token's signature against OpenAI's published keys, then issuer, audience, expiry and nonce.
    private func verify(_ token: String, clientID: String, nonce: String) async throws -> Object {
        let bad = HostError(String(localized: "没能核对 ChatGPT 账号，请再试一次。"))
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Self.decode(parts[0]), let bodyData = Self.decode(parts[1]), let signature = Self.decode(parts[2]),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? Object,
              let claims = (try? JSONSerialization.jsonObject(with: bodyData)) as? Object,
              header["alg"] as? String == "RS256" else { throw bad }
        let config = try await json(Self.discovery)
        guard let jwksAddress = config["jwks_uri"] as? String, let jwksURL = URL(string: jwksAddress), jwksURL.scheme == "https" else { throw bad }
        let keys = (try await json(jwksURL))["keys"] as? [Object] ?? []
        let kid = header["kid"] as? String
        guard let jwk = keys.first(where: { kid == nil || $0["kid"] as? String == kid }),
              let n = (jwk["n"] as? String).flatMap(Self.decode), let e = (jwk["e"] as? String).flatMap(Self.decode),
              let key = Self.rsaKey(modulus: n, exponent: e) else { throw bad }
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil) else { throw bad }
        let audience = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
        guard claims["iss"] as? String == Self.issuer, audience.contains(clientID),
              let exp = (claims["exp"] as? NSNumber)?.doubleValue, exp > Date().timeIntervalSince1970 - 60,
              claims["nonce"] as? String == nonce else { throw bad }
        return claims
    }

    private func json(_ url: URL) async throws -> Object {
        let (data, response) = try await http.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? Object else {
            throw HostError(String(localized: "暂时连不上 ChatGPT，请稍后再试。"))
        }
        return json
    }

    private static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }

    /// A PKCS#1 `RSAPublicKey` (SEQUENCE of two INTEGERs) made into a `SecKey`.
    private static func rsaKey(modulus: Data, exponent: Data) -> SecKey? {
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes: [UInt8] = []
            var value = count
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ raw: Data) -> Data {
            var bytes = Data(raw.drop(while: { $0 == 0 }))
            if bytes.isEmpty || bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                         kSecAttrKeySizeInBits as String: modulus.drop(while: { $0 == 0 }).count * 8]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    // MARK: Sign-out

    /// Revokes the renewable session, then clears the tokens. The client and host ID stay for the next sign-in.
    func signOut() async {
        timer?.cancel(); timer = nil
        let credential = Self.load(Credential.self, Self.credentialKey)
        let registration = Self.load(Registration.self, Self.registrationKey)
        var revoked = credential == nil
        if let credential, let registration {
            for delay in [0.0, 1.0, 3.0] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let config = try? await json(Self.discovery), let address = config["revocation_endpoint"] as? String,
                      let url = URL(string: address), url.scheme == "https" else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(Self.formBody(["token": credential.refresh, "token_type_hint": "refresh_token",
                                                       "client_id": registration.clientID]).utf8)
                guard let (_, response) = try? await http.data(for: request) else { continue }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { revoked = true; break }
                if code < 500 { break }
            }
        }
        try? Self.store(Optional<Credential>.none, Self.credentialKey)
        signedIn = false; pendingActivation = false
        clearModels()
        status = revoked ? "" : String(localized: "本机已退出，ChatGPT 那边的注销没有确认。可以在 ChatGPT 设置里断开 Pallas Agent。")
        revision += 1
    }
}

extension ChatGPTAccount: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

// MARK: - 本机引擎里的渠道

/// The `openai` route of `llm-pi-ai` on this phone's engine, fed by 用 ChatGPT 登录.
@MainActor
enum ChatGPTChannel {
    nonisolated static let route = "openai"
    nonisolated static let keyRef = "CHATGPT_ACCESS_TOKEN"
    private static let namespace = "llm-pi-ai"
    /// The token last handed to each engine, by connection, so a send only writes a changed one.
    private static var pushed: [ObjectIdentifier: String] = [:]

    /// Whether a route the host lists is this one (and not a channel someone set up by hand).
    nonisolated static func owns(route id: String, profile: Object?) -> Bool {
        id == route && profile?["apiKeyEnv"] as? String == keyRef
    }

    static func profile(_ models: [ChatGPTAccount.Model]) -> Object {
        ["displayName": "ChatGPT", "api": "openai-responses", "baseURL": ChatGPTAccount.resource,
         // The account's models all read images; declare it so ones newer than pi-ai's catalog
         // (gpt-6.2 when this was written) don't fall back to its text-only default.
         "apiKeyEnv": keyRef, "models": models.map { ["id": $0.id, "name": $0.name, "input": ["text", "image"]] as Object }]
    }

    /// Makes the engine match the account: signed in, its token and route; signed out, neither.
    static func sync(to host: Harness, refreshModels: Bool = false) async throws {
        let account = ChatGPTAccount.shared
        if account.signedIn && (refreshModels || account.models.isEmpty) { try await account.loadModels() }
        let described = try await host.rpc("settings/describe", args: [:])
        guard described["writable"] as? Bool == true,
              let section = (described["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == namespace }),
              let revision = section["revision"] as? Int else { return }
        let current = ((section["value"] as? Object)?["providers"] as? Object)?[route] as? Object
        let id = ObjectIdentifier(host)
        if account.signedIn && !account.models.isEmpty {
            let token = try await account.accessToken()
            if pushed[id] != token {
                _ = try await host.rpcValue("credentials/set", args: ["ref": keyRef, "value": token])
                pushed[id] = token
            }
            let desired = profile(account.models)
            if let current, desired.allSatisfy({ field, value in (current[field] as? NSObject)?.isEqual(value) == true }) { return }
            _ = try await host.rpcValue("settings/mutate", args: ["ns": namespace, "expectedRevision": revision,
                                                                  "ops": [["op": "set", "path": ["providers", route], "value": desired]]])
        } else {
            pushed[id] = nil
            guard owns(route: route, profile: current) else { return }
            _ = try await host.rpcValue("settings/mutate", args: ["ns": namespace, "expectedRevision": revision,
                                                                  "ops": [["op": "unset", "path": ["providers", route]]]])
            _ = try? await host.rpcValue("credentials/unset", args: ["ref": keyRef])
        }
    }

    /// Before a turn on this route: a token close to expiry is refreshed and handed over first.
    static func prepareTurn(on host: Harness) async {
        guard ChatGPTAccount.shared.signedIn, let token = try? await ChatGPTAccount.shared.accessToken(),
              pushed[ObjectIdentifier(host)] != token else { return }
        if (try? await host.rpcValue("credentials/set", args: ["ref": keyRef, "value": token])) != nil { pushed[ObjectIdentifier(host)] = token }
    }
}

// MARK: - 页面

/// 用 ChatGPT 登录: signed out, the button; signed in, the account, 管理用量 and 退出登录.
struct ChatGPTAccountPage: View {
    @ObservedObject private var account = ChatGPTAccount.shared
    @State private var confirmingLogout = false
    @State private var signingOut = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if account.signedIn { signedInContent } else { signedOutContent }
                if !account.status.isEmpty {
                    Text(account.status).font(.subheadline).foregroundStyle(ChatColors.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.bottom, 20)
                        .accessibilityIdentifier("chatGPTNotice")
                }
            }.padding(16).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .settingsPage("ChatGPT")
        .alert("退出 ChatGPT？", isPresented: $confirmingLogout) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                signingOut = true
                Task { await account.signOut(); signingOut = false }
            }
        } message: { Text("退出后，正在用 ChatGPT 的任务会中断。") }
    }

    @ViewBuilder private var signedInContent: some View {
        SettingsCard {
            HStack(spacing: 14) {
                SettingsIconDisc(symbol: "person.crop.circle", size: 48)
                Text(verbatim: account.email ?? "ChatGPT").font(.headline).foregroundStyle(ChatColors.ink).lineLimit(1)
                Spacer(minLength: 8)
                Circle().fill(SettingsStyle.ok).frame(width: 8, height: 8)
                Text("已登录").font(.subheadline).foregroundStyle(ChatColors.muted)
            }.padding(16).accessibilityElement(children: .combine).accessibilityIdentifier("chatGPTStatus")
        }
        SettingsCard {
            Button { openURL(ChatGPTAccount.usagePage) } label: {
                SettingsRowLabel(symbol: "chart.bar", title: String(localized: "管理用量"))
            }.buttonStyle(.plain).padding(.horizontal, 16).accessibilityIdentifier("chatGPTUsage")
        }
        SettingsCard {
            Button { confirmingLogout = true } label: {
                SettingsRowLabel(symbol: "rectangle.portrait.and.arrow.right", title: String(localized: "退出登录"), danger: true, chevron: false)
            }.buttonStyle(.plain).padding(.horizontal, 16).disabled(signingOut).accessibilityIdentifier("chatGPTSignOut")
        }
    }

    @ViewBuilder private var signedOutContent: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    SettingsIconDisc(symbol: "person.crop.circle", size: 48)
                    Text("用你的 ChatGPT 套餐聊天").font(.headline).foregroundStyle(ChatColors.ink).fixedSize(horizontal: false, vertical: true)
                }
                ChatGPTSignInButton()
            }.padding(16)
        }
    }
}

/// 用 ChatGPT 登录, as a full-width button.
struct ChatGPTSignInButton: View {
    @ObservedObject private var account = ChatGPTAccount.shared
    var body: some View {
        Button { Task { await account.signIn() } } label: {
            HStack(spacing: 8) {
                if account.busy { ProgressView().controlSize(.small) }
                Text("用 ChatGPT 登录").font(.headline)
            }.frame(maxWidth: .infinity, minHeight: 50)
        }.prominentButton().buttonBorderShape(.capsule).disabled(account.busy).accessibilityIdentifier("chatGPTSignIn")
    }
}

/// The one-time confirmation after the first sign-in.
struct ChatGPTWelcome: ViewModifier {
    @ObservedObject private var account = ChatGPTAccount.shared
    @Environment(\.openURL) private var openURL
    func body(content: Content) -> some View {
        content.alert("正在使用你的 ChatGPT 套餐", isPresented: $account.welcome) {
            Button("知道了", role: .cancel) {}
            Button("管理用量") { openURL(ChatGPTAccount.usagePage) }
        } message: { Text("Pallas Agent 的请求会计入你的 ChatGPT 套餐，可以在 ChatGPT 设置里管理用量。") }
    }
}
