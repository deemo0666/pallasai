// 设置页列模型用的请求：第三方接入的 `GET {base}/models` 和 DeepSeek 账号的模型列表。
// 聊天都由主机（本机引擎或远程主机）发出，App 自己不再请求模型。

import Foundation
import Network
#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
#else
import UIKit
#endif

@MainActor
enum ModelService {
    private static let network = URLSession(configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil)

    private static func localHost(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".local") { return true }
        if let ip = IPv4Address(name) {
            let bytes = Array(ip.rawValue)
            return bytes[0] == 127 || bytes[0] == 10 ||
                (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) || ip.isLinkLocal
        }
        let literal = name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let ip = IPv6Address(literal) {
            return ip.isLoopback || ip.isLinkLocal || (ip.rawValue.first.map { $0 & 0xfe == 0xfc } ?? false)
        }
        return false
    }

    static func endpoint(_ base: String) throws -> URL {
        guard let url = URL(string: base), let host = url.host, !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && localHost(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw HostError(String(localized: "请输入 HTTPS 服务地址，或使用本机及局域网 HTTP 地址。"))
        }
        return url
    }

    static func models(base: String, key: String, account: Bool = false, accountKey: String = DeepSeekAccount.key) async throws -> [String] {
        var request = URLRequest(url: account ? DeepSeekAccount.models : try Self.endpoint(base).appending(path: "models"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if account {
            let token = try Vault.read(accountKey)
            guard !token.isEmpty else { throw HostError(String(localized: "请先登录 DeepSeek 账号。")) }
            request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token")
            request.setValue(DeepSeekAccount.agent, forHTTPHeaderField: "User-Agent")
        }
        else { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await network.data(for: request)
        try Self.check(response, request: request, stage: String(localized: "获取模型"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? Object, let list = json["data"] as? [Object]
        else { throw HostError(String(localized: "服务端没有返回模型列表。")) }
        let service = account ? DeepSeekAccount.messages.absoluteString : try Self.endpoint(base).absoluteString
        for entry in list { ModelBudget.register(entry, service: service, account: account) }
        var seen = Set<String>()
        let openAI = !account && request.url?.host?.lowercased() == "api.openai.com"
        // OpenAI's API-key catalog includes creation times and non-chat models. Put recent
        // chat releases within the first rows of the picker, even with many older snapshots.
        let ordered = openAI ? list.sorted { ($0["created"] as? Int ?? 0) > ($1["created"] as? Int ?? 0) } : list
        let ids = ordered.compactMap { $0["id"] as? String }.filter {
            !$0.isEmpty && (!openAI || ThirdPartyChannel.chats($0)) && seen.insert($0).inserted
        }
        if account && ids.isEmpty { throw HostError(String(localized: "DeepSeek 没有返回可选的账号模型。")) }
        return account || openAI ? ids : ids.sorted()
    }

    /// Probe the selected compatible endpoint with synthetic pixels before advertising
    /// image input to the Harness. The expected answer exists only inside the image.
    static func verifyImageInput(base: String, model: String) async throws {
        guard !model.isEmpty else { throw HostError(String(localized: "请先选择第三方模型。")) }
        let endpoint = try Self.endpoint(base)
        let key = try Vault.read(base)
        guard !key.isEmpty else { throw HostError(String(localized: "请先配置第三方接入。")) }
        let expected = String(Int.random(in: 10000...99999))
        #if os(macOS)
        let sample = Text(expected).font(.system(size: 60, weight: .medium, design: .monospaced))
            .foregroundStyle(.black).frame(width: 260, height: 90).background(.white)
        let png = ImageRenderer(content: sample).cgImage.flatMap { RasterFrames.encode($0, as: .png) }
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 260, height: 90), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 260, height: 90))
            (expected as NSString).draw(at: CGPoint(x: 24, y: 7), withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 60, weight: .medium), .foregroundColor: UIColor.black
            ])
        }
        let png = image.pngData()
        #endif
        guard let png else { throw HostError(String(localized: "无法生成读图测试。")) }
        var request = URLRequest(url: endpoint.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 50
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let content: [Object] = [["type":"input_text","text":"Read the five digits. Reply only with the digits."],
                                 ["type":"input_image","image_url":"data:image/png;base64," + png.base64EncodedString()]]
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true, "instructions": "Read the supplied test image.",
            "input": [["role":"user","content": content]]
        ] as Object)
        let (data, response) = try await network.data(for: request)
        try check(response, request: request, stage: String(localized: "验证图片输入"))
        var answer = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
            let json = Data(line.dropFirst(5).utf8)
            guard let event = (try? JSONSerialization.jsonObject(with: json)) as? Object else { continue }
            if event["type"] as? String == "response.output_text.delta" { answer += event["delta"] as? String ?? "" }
            if event["type"] as? String == "response.output_text.done", let final = event["text"] as? String { answer = final }
        }
        guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == expected else { throw HostError(String(localized: "模型没有正确读出测试图。")) }
        try Task.checkCancellation()
        UserDefaults.standard.set(true, forKey: ModelBudget.key(service: base, model: model) + ".verifiedImage")
    }

    static func check(_ response: URLResponse, request: URLRequest, stage: String, account: DeepSeekAccount? = nil) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status), let token = request.value(forHTTPHeaderField: "x-dsh-auth-token") {
            let message: String
            switch status {
            case 401:
                try (account ?? DeepSeekAccount.shared).reject(token)
                message = String(localized: "登录凭据已被拒绝，请到接入设置重新登录。")
            case 403: message = String(localized: "账号未获准使用此服务或模型，请核对账号权限或切换模型。")
            case 402: message = String(localized: "账号可用额度不足，请核对余额。")
            case 429: message = String(localized: "请求过于频繁，请稍后重试。")
            default: message = String(localized: "请稍后重试。")
            }
            throw HostError("DeepSeek " + stage + String(localized: "返回 HTTP \(status)。") + message)
        }
        guard (200..<300).contains(status) else { throw HostError(String(localized: "模型服务返回 HTTP \(status)。")) }
    }
}
