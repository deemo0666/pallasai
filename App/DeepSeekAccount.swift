import CryptoKit
import Network
#if os(macOS)
import AppKit
#else
import SafariServices
#endif
import SwiftUI

@MainActor
final class DeepSeekAccount: ObservableObject {
    static let shared = DeepSeekAccount()
    nonisolated static let key = "deepseek-platform-account"
    nonisolated static let origin = URL(string: "https://platform.deepseek.com")!
    static let models = URL(string: "https://api.deepseek.com/models")!
    static let messages = URL(string: "https://api.deepseek.com/anthropic/v1/messages")!
    @Published var page: URL?
    @Published var status = ""
    @Published private(set) var busy = false
    @Published private(set) var signedIn = false
    @Published private(set) var verified = false
    private var exchanging = false
    private let platform: URL
    private let credentialKey: String
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var attempt = UUID()
    private var verifier = ""
    private var state = ""
    private var redirect = ""
    private var authorizeID = ""
    private let http: URLSession
    init(platform: URL = DeepSeekAccount.origin, credentialKey: String = DeepSeekAccount.key) {
        self.platform = platform; self.credentialKey = credentialKey
        http = URLSession(configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil)
        signedIn = ((try? Vault.read(credentialKey)) ?? "").isEmpty == false
    }

    private var locale: String { AppLanguage.isChinese ? "zh_CN" : "en_US" }
    static var agent: String {
        "dsh-local/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") + " (+" + ProjectLinks.repository.absoluteString + ")"
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: platform.appending(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        req.setValue("web", forHTTPHeaderField: "x-client-platform")
        req.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        req.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0", forHTTPHeaderField: "x-client-version")
        req.setValue(locale, forHTTPHeaderField: "x-client-locale")
        req.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "x-client-timezone-offset")
        return req
    }

    func reject(_ token: String) throws {
        guard !token.isEmpty, try Vault.read(credentialKey) == token else { return }
        try Vault.save("", account: credentialKey)
        signedIn = false; verified = false; balance = .loading; refreshedAt = nil; cache(nil)
        status = String(localized: "登录已失效，请重新登录。")
    }

    /// 账号资料（`auth-api/v0/users/current`）：昵称、手机号或邮箱、头像。
    struct Profile: Equatable, Codable {
        var name: String?
        var contact: String?
        var avatar: URL?
        init(_ data: Object) {
            let identity = data["id_profile"] as? Object
            name = (identity?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            contact = [data["mobile"], data["mobile_number"], data["email"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            avatar = (identity?["picture"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        }
    }

    /// 一个币种的钱包余额。
    struct Wallet: Equatable, Identifiable {
        let currency: String
        let amount: Decimal
        var id: String { currency }
        var text: String { amount.formatted(.currency(code: currency).precision(.fractionLength(2))) }
    }

    /// 余额（`api/v0/users/get_user_summary`）：充值余额和赠送余额，按币种分。
    struct Balance: Equatable {
        let paid: [Wallet]
        let bonus: [Wallet]
        /// 每个币种的合计，人民币在前。
        var totals: [Wallet] {
            var sums: [String: Decimal] = [:]
            for wallet in paid + bonus { sums[wallet.currency, default: 0] += wallet.amount }
            let all = sums.map { Wallet(currency: $0.key, amount: $0.value) }
            let nonzero = all.filter { $0.amount != 0 }
            return (nonzero.isEmpty ? all.filter { $0.currency == "CNY" } : nonzero)
                .sorted { ($0.currency == "CNY" ? 0 : 1, $0.currency) < ($1.currency == "CNY" ? 0 : 1, $1.currency) }
        }
        init?(_ data: Object) {
            func wallets(_ key: String) -> [Wallet]? {
                guard let rows = data[key] as? [Object] else { return nil }
                return rows.compactMap { row in
                    guard let currency = row["currency"] as? String, let text = row["balance"] as? String,
                          let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
                    return Wallet(currency: currency, amount: amount)
                }
            }
            guard let paid = wallets("normal_wallets"), let bonus = wallets("bonus_wallets") else { return nil }
            self.paid = paid; self.bonus = bonus
        }
        init(paid: [Wallet], bonus: [Wallet]) { self.paid = paid; self.bonus = bonus }
    }

    enum Detail<Value: Equatable>: Equatable { case loading, ready(Value), failed }
    @Published private(set) var profile: Profile?
    @Published private(set) var balance: Detail<Balance> = .loading

    /// 平台网页：充值、用量明细。
    var topUpPage: URL { platform.appending(path: "top_up") }
    var usagePage: URL { platform.appending(path: "usage") }

    /// The platform's gateway now and then answers 403/429/5xx to a burst of requests; those,
    /// and a dropped connection, are worth a quiet retry.
    private struct Transient: Error {}

    /// GET a platform account path with the saved token; a rejected token signs out. Transient
    /// refusals are retried twice with a pause before giving up.
    private func account(_ path: String, token: String, stage: String) async throws -> Object {
        var req = request(path, method: "GET")
        req.setValue(token, forHTTPHeaderField: "x-dsh-auth-token")
        for delay in [0.8, 2.0, nil] as [Double?] {
            do {
                let (bytes, response) = try await http.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: bytes)) as? Object
                if code == 401 || json?["code"] as? Int == 40003 {
                    if !busy, try Vault.read(credentialKey) == token { try reject(token) }
                    throw CancellationError()
                }
                if code == 403 || code == 429 || code >= 500 { throw Transient() }
                return try Self.payload(bytes, response, stage: stage)
            } catch let error where error is Transient || error is URLError {
                guard let delay, !Task.isCancelled else { throw Transient() }
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw Transient()
    }

    private var refreshing: Task<Void, Never>?
    private var refreshedAt: Date?

    /// Re-read the account and its balance, one request after the other. Calls while one is
    /// running join it; an automatic call within 30 s of the last good read does nothing.
    func verifySavedLogin(force: Bool = false) async {
        guard !busy else { return }
        if let refreshing { await refreshing.value; return }
        if !force, let refreshedAt, signedIn, Date().timeIntervalSince(refreshedAt) < 30 { return }
        let task = Task { await refresh() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private var profileKey: String { credentialKey + "/profile" }

    /// The account the last good read (or the sign-in itself) named, kept with the credential so
    /// the page has a name even when `users/current` is refused.
    private func cache(_ value: Profile?) {
        profile = value
        let text = value.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        try? Vault.save(text, account: profileKey)
    }

    private func cachedProfile() -> Profile? {
        guard let text = try? Vault.read(profileKey), !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: Data(text.utf8))
    }

    private func refresh() async {
        guard let token = try? Vault.read(credentialKey), !token.isEmpty else {
            signedIn = false; verified = false; profile = nil; balance = .loading; return
        }
        if profile == nil { profile = cachedProfile() }
        var profileError: Error?
        do {
            let data = try await account("auth-api/v0/users/current", token: token, stage: String(localized: "验证登录"))
            guard !busy, (try? Vault.read(credentialKey)) == token else { return }
            signedIn = true; verified = true; status = ""
            cache(Profile(data))
        } catch is CancellationError { return
        } catch { profileError = error }
        await refreshBalance(token: token)
        guard !busy, (try? Vault.read(credentialKey)) == token else { return }
        // Either read going through proves the credential; only both failing is worth a line.
        if case .ready = balance { signedIn = true; verified = true; status = "" }
        if let profileError, !verified {
            status = profileError is Transient ? String(localized: "暂时连不上 DeepSeek，下拉重试。")
                : (profileError as? HostError)?.message ?? String(localized: "暂时无法连接 DeepSeek 验证登录。")
        }
        if case .ready = balance { refreshedAt = Date() }
    }

    /// 重新读余额（重试、关掉充值页后）。
    func refreshBalance() async {
        guard let token = try? Vault.read(credentialKey), !token.isEmpty else { return }
        await refreshBalance(token: token)
    }

    /// 读不到就显示读取失败，不当成 0；已经读到过的余额保留。
    private func refreshBalance(token: String) async {
        if case .ready = balance {} else { balance = .loading }
        do {
            let data = try await account("api/v0/users/get_user_summary", token: token, stage: String(localized: "查询余额"))
            guard (try? Vault.read(credentialKey)) == token else { return }
            if let value = Balance(data) { balance = .ready(value) } else if case .ready = balance {} else { balance = .failed }
        } catch is CancellationError {
        } catch {
            guard (try? Vault.read(credentialKey)) == token else { return }
            if case .ready = balance {} else { balance = .failed }
        }
    }

    private static func payload(_ bytes: Data, _ response: URLResponse, stage: String) throws -> Object {
        // The person reads what did not work and that trying later may; the codes go to the log.
        func refused(_ why: String) -> HostError {
            Log.connection.error("deepseek account refused: \(why, privacy: .public)")
            return HostError(String(localized: "没能") + stage + String(localized: "，请稍后再试。"))
        }
        let http = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard http == 200 else { throw refused("http \(http)") }
        guard let json = (try? JSONSerialization.jsonObject(with: bytes)) as? Object, let code = json["code"] as? Int else {
            throw refused("unreadable response")
        }
        guard code == 0 else { throw refused("platform code \(code)") }
        guard let data = json["data"] as? Object, let business = data["biz_code"] as? Int else { throw refused("no business code") }
        guard business == 0 else { throw refused("business code \(business)") }
        return data["biz_data"] as? Object ?? [:]
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func begin() {
        guard !busy else { return }
        busy = true
        status = ""
        let id = UUID()
        attempt = id
        state = Self.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        verifier = Self.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: params)
            listener = server
            server.stateUpdateHandler = { [weak self] change in
                Task { @MainActor in
                    guard let self, self.attempt == id else { return }
                    switch change {
                    case .ready:
                        if let port = server.port { await self.initialize(port: port.rawValue, id: id) }
                    case .failed: self.fail(String(localized: "没能开始登录，请再试一次。"))
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in self?.read(connection, buffer: Data(), id: id) }
            }
            server.start(queue: .main)
            timeout = Task {
                try? await Task.sleep(for: .seconds(180))
                if !Task.isCancelled, attempt == id { fail(String(localized: "等了太久，登录没有完成。请再试一次。")) }
            }
        } catch { fail(String(localized: "没能开始登录，请再试一次。")) }
    }

    private func initialize(port: UInt16, id: UUID) async {
        redirect = "http://127.0.0.1:" + String(port) + "/oauth/callback"
        let challenge = Self.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        do {
            let result = try await post("auth_init", ["code_challenge": challenge, "code_challenge_method": "S256",
                "state": state, "redirect_uri": redirect, "locale": locale, "login_source": "web"])
            guard attempt == id else { return }
            guard let address = result["authorize_url"] as? String, let url = URL(string: address),
                  url.scheme == platform.scheme, url.host == platform.host, url.path == "/dsh/authorize",
                  url.user == nil, url.password == nil, url.port == platform.port, let auth = result["authorize_id"] as? String
            else { throw HostError(String(localized: "没能开始登录，请稍后再试。")) }
            authorizeID = auth
            if let seconds = (result["expires_in"] as? NSNumber)?.doubleValue, seconds > 0 {
                timeout?.cancel()
                timeout = Task {
                    do { try await Task.sleep(for: .seconds(min(180, seconds))) } catch { return }
                    if attempt == id { fail(String(localized: "等了太久，登录没有完成。请再试一次。")) }
                }
            }
            status = String(localized: "请在打开的页面里登录，完成后会回到这里。")
            page = url
        } catch { if attempt == id { fail(error.localizedDescription) } }
    }

    private func read(_ connection: NWConnection, buffer: Data, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, done, error in
            Task { @MainActor in
                guard self.attempt == id, error == nil, let chunk else { connection.cancel(); return }
                let bytes = buffer + chunk
                guard bytes.count < 16384 else { connection.cancel(); return }
                let raw = String(decoding: bytes, as: UTF8.self)
                guard raw.contains("\r\n\r\n") else {
                    if done { connection.cancel() } else { self.read(connection, buffer: bytes, id: id) }
                    return
                }
                let fields = raw.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard fields.count == 3, fields[0] == "GET", let parts = URLComponents(string: String(fields[1])),
                      parts.path == "/oauth/callback", self.page != nil, !self.exchanging,
                      parts.queryItems?.filter({ $0.name == "state" }).map(\.value) == [self.state] else {
                    self.respond(connection, ok: false); return
                }
                if parts.queryItems?.contains(where: { $0.name == "error" }) == true {
                    self.respond(connection, ok: false); self.fail(String(localized: "登录没有完成，请再试一次。")); return
                }
                guard let codes = parts.queryItems?.filter({ $0.name == "code" }), codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
                    self.respond(connection, ok: false); self.fail(String(localized: "登录没有完成，请再试一次。")); return
                }
                self.exchanging = true
                self.status = String(localized: "正在完成登录…")
                await self.exchange(code, id: id, connection: connection)
            }
        }
    }

    private func respond(_ connection: NWConnection, ok: Bool) {
        let body = Data((ok ? String(localized: "登录完成，可以回到 Pallas Agent 了。") : String(localized: "登录没有完成，请回到 Pallas Agent 再试一次。")).utf8)
        let head = "HTTP/1.1 " + (ok ? "200 OK" : "400 Bad Request") + "\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func exchange(_ code: String, id: UUID, connection: NWConnection) async {
        do {
            let deviceKey = credentialKey == Self.key ? "deepseek-device-id" : credentialKey + "/device"
            var device = try Vault.read(deviceKey)
            if device.isEmpty { device = UUID().uuidString; try Vault.save(device, account: deviceKey) }
            #if os(macOS)
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let model = "Mac"
            let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            #else
            let model = UIDevice.current.model
            let osVersion = UIDevice.current.systemVersion
            #endif
            let data = try await post("auth_exchange", ["code": code, "code_verifier": verifier, "redirect_uri": redirect,
                "device_id": device, "device_model": model, "os_version": osVersion])
            guard attempt == id else { respond(connection, ok: false); return }
            guard let token = data["token"] as? String, !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw HostError(String(localized: "登录没有完成，请再试一次。")) }
            try Vault.save(token, account: credentialKey)
            signedIn = true; verified = true; status = String(localized: "已登录。")
            cache((data["user"] as? Object).map(Profile.init))
            respond(connection, ok: true); reset()
            await verifySavedLogin(force: true)
        } catch { respond(connection, ok: false); if attempt == id { fail(error.localizedDescription) } }
    }

    private func post(_ method: String, _ body: Object) async throws -> Object {
        var req = request("auth-api/v0/dsh/" + method, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await http.data(for: req)
        let stage = ["auth_init": String(localized: "开始登录"), "auth_exchange": String(localized: "完成登录"), "auth_cancel": String(localized: "取消登录")][method] ?? String(localized: "连接 DeepSeek")
        return try Self.payload(bytes, response, stage: stage)
    }
    func cancel() {
        let auth = authorizeID
        let proof = verifier
        reset()
        if !auth.isEmpty { Task { _ = try? await post("auth_cancel", ["authorize_id": auth, "code_verifier": proof]) } }
    }
    func logout() async {
        do {
            let token = try Vault.read(credentialKey)
            try Vault.save("", account: credentialKey)
            signedIn = false; verified = false; status = ""; balance = .loading; refreshedAt = nil; cache(nil)
            var request = self.request("auth-api/v0/users/logout", method: "POST")
            request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token")
            let (_, response) = try await http.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HostError(String(localized: "本机已退出，平台注销未确认。")) }
        } catch { status = String(localized: "退出时遇到问题，请核对账号状态。") }
    }
    private func reset() {
        attempt = UUID()
        listener?.cancel(); listener = nil
        timeout?.cancel(); timeout = nil
        page = nil; exchanging = false; verifier = ""; state = ""; authorizeID = ""; busy = false
    }
    private func fail(_ message: String) { cancel(); status = message }
}

#if os(iOS)
struct AccountBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

/// DeepSeek 账号 on the iPhone: sign in through the browser so 本机引擎 chats on the
/// account's balance; signed in, the account, its balance, and the platform's 充值 and
/// 用量明细 pages.
struct DeepSeekAccountPage: View {
    @ObservedObject private var account = DeepSeekAccount.shared
    @State private var confirmingLogout = false
    @State private var platformPage: PlatformPage?

    private struct PlatformPage: Identifiable { let url: URL; var id: String { url.absoluteString } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if account.signedIn { signedInContent } else { signedOutContent }
            }.padding(16).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .refreshable { await account.verifySavedLogin(force: true) }
        .settingsPage(String(localized: "DeepSeek 账号"))
        .alert("退出 DeepSeek 账号？", isPresented: $confirmingLogout) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) { Task { await account.logout() } }
        } message: { Text("退出后，正在使用账号模型的任务会中断。") }
        #if os(macOS)
        .onChange(of: account.page) { _, url in
            guard let url, !NSWorkspace.shared.open(url) else { return }
            account.cancel()
            account.status = String(localized: "没能开始登录，请稍后再试。")
        }
        .sheet(item: $platformPage, onDismiss: { Task { await account.refreshBalance() } }) { page in
            BrowserView(initialURL: page.url).desktopSheet(width: 740, height: 540)
        }
        #else
        .sheet(isPresented: Binding(get: { account.page != nil }, set: { if !$0, account.page != nil { account.cancel() } })) {
            if let url = account.page { AccountBrowser(url: url).ignoresSafeArea() }
        }
        .sheet(item: $platformPage, onDismiss: { Task { await account.refreshBalance() } }) { page in
            AccountBrowser(url: page.url).ignoresSafeArea()
        }
        #endif
        .task { await account.verifySavedLogin() }
    }

    // MARK: 已登录

    @ViewBuilder private var signedInContent: some View {
        SettingsCard { profileRow }
        SettingsCard(title: String(localized: "余额")) { balanceContent }
        SettingsCard {
            Button { platformPage = PlatformPage(url: account.topUpPage) } label: {
                SettingsRowLabel(symbol: "creditcard", title: String(localized: "充值"))
            }.buttonStyle(.plain).padding(.horizontal, 16).accessibilityIdentifier("accountTopUp")
            SettingsDivider()
            Button { platformPage = PlatformPage(url: account.usagePage) } label: {
                SettingsRowLabel(symbol: "chart.bar", title: String(localized: "用量明细"))
            }.buttonStyle(.plain).padding(.horizontal, 16).accessibilityIdentifier("accountUsage")
        }
        if !account.status.isEmpty { notice }
        SettingsCard {
            Button { confirmingLogout = true } label: {
                SettingsRowLabel(symbol: "rectangle.portrait.and.arrow.right", title: String(localized: "退出登录"), danger: true, chevron: false)
            }.buttonStyle(.plain).padding(.horizontal, 16).disabled(account.busy)
        }
    }

    private var profileRow: some View {
        let profile = account.profile
        let title = profile?.name ?? profile?.contact ?? String(localized: "DeepSeek 账号")
        let subtitle = profile?.name == nil ? nil : profile?.contact
        return HStack(spacing: 14) {
            avatar(profile, title: title)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.headline).foregroundStyle(ChatColors.ink).lineLimit(1)
                if let subtitle { Text(verbatim: subtitle).font(.subheadline).foregroundStyle(ChatColors.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if account.verified || !account.status.isEmpty {
                    Circle().fill(account.verified ? SettingsStyle.ok : SettingsStyle.warning).frame(width: 8, height: 8)
                    Text(account.verified ? "已登录" : "未验证").font(.subheadline).foregroundStyle(ChatColors.muted)
                } else { ProgressView().controlSize(.small) }
            }
        }.padding(16).accessibilityElement(children: .combine).accessibilityIdentifier("accountStatus")
    }

    private func avatar(_ profile: DeepSeekAccount.Profile?, title: String) -> some View {
        let letter = Text(title.first.map { String($0).uppercased() } ?? "D")
            .font(.title3.weight(.semibold)).foregroundStyle(ChatColors.ink)
        return ZStack {
            Circle().fill(ChatColors.tile)
            if let url = profile?.avatar {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { letter }
            } else { letter }
        }.frame(width: 48, height: 48).clipShape(Circle()).accessibilityHidden(true)
    }

    @ViewBuilder private var balanceContent: some View {
        switch account.balance {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }.frame(minHeight: 96)
        case .failed:
            HStack(spacing: 12) {
                Text("暂时读不到余额").foregroundStyle(SettingsStyle.warning)
                Spacer()
                Button("重试") { Task { await account.refreshBalance() } }.font(.subheadline.weight(.semibold))
                Button("去网页查看") { platformPage = PlatformPage(url: account.usagePage) }.font(.subheadline.weight(.semibold))
            }.padding(16).frame(minHeight: SettingsStyle.rowHeight).accessibilityIdentifier("accountBalanceFailed")
        case .ready(let balance):
            VStack(alignment: .leading, spacing: 4) {
                Text("可用余额").font(.subheadline).foregroundStyle(ChatColors.muted)
                let totals = balance.totals
                if totals.isEmpty {
                    Text(verbatim: DeepSeekAccount.Wallet(currency: "CNY", amount: 0).text).font(.system(size: 34, weight: .semibold).monospacedDigit())
                } else {
                    ForEach(totals) { wallet in
                        Text(verbatim: wallet.text).font(.system(size: 34, weight: .semibold).monospacedDigit())
                            .minimumScaleFactor(0.6).lineLimit(1)
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
                .accessibilityElement(children: .combine).accessibilityIdentifier("accountBalance")
            SettingsDivider(inset: 16)
            walletRow(String(localized: "充值余额"), balance.paid)
            SettingsDivider(inset: 16)
            walletRow(String(localized: "赠送余额"), balance.bonus)
        }
    }

    private func walletRow(_ title: String, _ wallets: [DeepSeekAccount.Wallet]) -> some View {
        HStack {
            Text(title).foregroundStyle(ChatColors.ink)
            Spacer()
            let shown = wallets.filter { $0.amount != 0 }
            Text(verbatim: shown.isEmpty ? DeepSeekAccount.Wallet(currency: "CNY", amount: 0).text : shown.map(\.text).joined(separator: " · "))
                .font(.body.monospacedDigit()).foregroundStyle(ChatColors.muted)
        }.padding(.horizontal, 16).frame(minHeight: SettingsStyle.rowHeight).accessibilityElement(children: .combine)
    }

    // MARK: 未登录

    @ViewBuilder private var signedOutContent: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    SettingsIconDisc(symbol: "person.crop.circle", size: 48)
                    Text("用 DeepSeek 账号余额聊天，按用量扣费。登录后可以在这里看余额和充值。")
                        .font(.headline).foregroundStyle(ChatColors.ink).fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("accountStatus")
                if account.busy { ProgressView().progressViewStyle(.linear) }
                Button { account.begin() } label: {
                    Text("登录 DeepSeek 账号").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }.prominentButton().buttonBorderShape(.capsule).disabled(account.busy)
                if account.busy {
                    Button { account.cancel() } label: { Text("取消登录").frame(maxWidth: .infinity, minHeight: 44) }
                }
            }.padding(16)
        }
        if !account.status.isEmpty { notice }
    }

    private var notice: some View {
        Text(account.status).font(.subheadline).foregroundStyle(ChatColors.muted)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.bottom, 20)
            .accessibilityIdentifier("accountNotice")
    }
}
