// 设置 › 第三方接入在本机引擎里的样子：每个接入是 `llm-pi-ai` 下一条自定义渠道。地址和模型
// 都用设置里配的那一份，不依赖引擎内置的目录；key 只经 `credentials/set` 存进引擎的凭据（本机
// 引擎是钥匙串），渠道里只记引用名。

import Foundation

/// One entry of 第三方接入: an endpoint (its key sits in the keychain under `base`) and its default model.
struct ThirdPartyProvider: Codable, Hashable, Identifiable {
    /// The route's name in the engine. The first entry keeps `third-party`, the name used before
    /// there could be more than one; later ones are `third-party-<hex>`.
    var id: String
    var base: String
    var model: String

    var keyRef: String { ThirdPartyChannel.keyRef(for: id) }
}

/// The saved list. The first entry is mirrored into `providerURL` / `providerModel`, which the
/// image check, diagnostics and UI tests read.
enum ThirdPartyProviders {
    static let storageKey = "thirdPartyProviders"
    struct Activation: Codable, Equatable {
        var id = UUID()
        let provider: ThirdPartyProvider
        let explicit: Bool
    }
    private static let activationKey = "thirdPartyPendingActivation"
    static var pendingActivation: Activation? {
        guard let data = UserDefaults.standard.data(forKey: activationKey) else { return nil }
        return try? JSONDecoder().decode(Activation.self, from: data)
    }
    static func requestActivation(_ provider: ThirdPartyProvider, explicit: Bool) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Activation(provider: provider, explicit: explicit)), forKey: activationKey)
    }
    static func finishActivation(_ request: Activation) {
        guard pendingActivation?.id == request.id else { return }
        UserDefaults.standard.removeObject(forKey: activationKey)
    }

    static func load() -> [ThirdPartyProvider] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([ThirdPartyProvider].self, from: data) { return list }
        // Before the list existed: the single endpoint and model.
        let model = defaults.string(forKey: "providerModel") ?? ""
        guard !model.isEmpty else { return [] }
        let base = defaults.string(forKey: "providerURL") ?? DirectAccessPage.defaultBase
        return [ThirdPartyProvider(id: ThirdPartyChannel.route, base: base, model: model)]
    }

    static func store(_ list: [ThirdPartyProvider]) {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(list), forKey: storageKey)
        defaults.set(list.first?.base ?? DirectAccessPage.defaultBase, forKey: "providerURL")
        defaults.set(list.first?.model ?? "", forKey: "providerModel")
        defaults.set(defaults.integer(forKey: "thirdPartySaved") + 1, forKey: "thirdPartySaved")
    }

    /// A route name no entry of `list` uses.
    static func newID(in list: [ThirdPartyProvider]) -> String {
        let taken = Set(list.map(\.id))
        if !taken.contains(ThirdPartyChannel.route) { return ThirdPartyChannel.route }
        while true {
            let id = ThirdPartyChannel.route + "-" + String(format: "%06x", UInt32.random(in: 0..<0xFFFFFF))
            if !taken.contains(id) { return id }
        }
    }

    /// Entries whose key is in the keychain.
    static func configured() -> [ThirdPartyProvider] {
        load().filter { ((try? Vault.read($0.base)) ?? "").isEmpty == false }
    }

    /// `api.openai.com` (or nothing) is OpenAI; another endpoint shows its host.
    static func displayName(_ base: String) -> String {
        let host = URL(string: base)?.host ?? ""
        return host == "api.openai.com" || host.isEmpty ? "OpenAI" : host
    }
}

@MainActor
enum ThirdPartyChannel {
    nonisolated static let route = "third-party"
    nonisolated private static let baseKeyRef = "THIRD_PARTY_API_KEY"
    private static let namespace = "llm-pi-ai"
    /// `THINKING_LEVELS` of `dsh-llm-pi-ai`: a level outside it fails the adapter's validation.
    private static let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Where the endpoint's last `GET /models` answer is kept, so the route can offer all of them.
    private static func listKey(_ base: String) -> String { "thirdPartyModels." + base }

    static func remember(_ models: [String], base: String) {
        UserDefaults.standard.set(models, forKey: listKey(base))
    }

    /// The endpoint's last `GET /models` answer, unfiltered.
    static func listed(base: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: listKey(base)) ?? []
    }

    /// Whether a route of the engine is one of 第三方接入's.
    nonisolated static func owns(_ id: String) -> Bool { id == route || id.hasPrefix(route + "-") }

    /// `third-party` → `THIRD_PARTY_API_KEY`, `third-party-1a2b3c` → `THIRD_PARTY_API_KEY_1A2B3C`.
    nonisolated static func keyRef(for id: String) -> String {
        id == route ? baseKeyRef : baseKeyRef + "_" + id.dropFirst(route.count + 1).uppercased()
    }

    /// The route for `base`: `model` (the default) first, then the endpoint's other listed models,
    /// each with what this phone learned about it.
    static func profile(base: String, model: String, listed: [String] = [], keyRef: String = keyRef(for: route)) -> Object {
        let ids = [model] + listed.filter { $0 != model && chats($0) }
        return ["displayName": ThirdPartyProviders.displayName(base), "api": "openai-responses", "baseURL": base,
                "apiKeyEnv": keyRef, "models": ids.map { entry(base: base, model: $0) }]
    }

    /// `GET /models` also lists speech, transcription, image, embedding and moderation models;
    /// none of them answer a chat turn, so the chat's model sheet leaves them out.
    static func chats(_ id: String) -> Bool {
        let name = id.lowercased()
        return !["transcribe", "tts", "whisper", "embedding", "moderation", "dall-e", "image", "realtime", "audio", "sora", "speech"]
            .contains { name.contains($0) }
    }

    private static func entry(base: String, model: String) -> Object {
        var entry: Object = ["id": model]
        let capabilities = ModelBudget.key(service: base, model: model)
        if UserDefaults.standard.bool(forKey: capabilities + ".verifiedImage") ||
            UserDefaults.standard.bool(forKey: capabilities + ".advertisedImage") { entry["input"] = ["text", "image"] }
        let name = ModelBudget.displayName(service: base, model: model)
        if name != model { entry["name"] = name }
        let efforts = ModelBudget.efforts(service: base, model: model).filter(levels.contains)
        if efforts.contains(where: { $0 != "off" }) { entry["reasoningEfforts"] = Dictionary(uniqueKeysWithValues: efforts.map { ($0, $0) }) }
        let budget = ModelBudget.resolve(ModelBudget.key(service: base, model: model))
        if budget.source != String(localized: "默认") { entry["contextWindow"] = budget.window }
        return entry
    }

    /// Makes the host's routes match 第三方接入: stores each entry's key and writes its route when
    /// it differs; routes of entries that are gone or have no key or model are removed.
    static func sync(_ providers: [ThirdPartyProvider], to host: Harness, refreshModels: Bool = false) async throws {
        let described = try await host.rpc("settings/describe", args: [:])
        guard described["writable"] as? Bool == true,
              let section = (described["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == namespace }),
              let revision = section["revision"] as? Int else { throw HostError(String(localized: "本机不支持自定义模型服务。")) }
        let routes = ((section["value"] as? Object)?["providers"] as? Object) ?? [:]
        var ops: [Object] = []
        var discoveryError: Error?
        var kept = Set<String>()
        for provider in providers {
            let key = (try? Vault.read(provider.base)) ?? ""
            guard !key.isEmpty, !provider.model.isEmpty, (try? ModelService.endpoint(provider.base)) != nil,
                  !kept.contains(provider.id) else { continue }
            kept.insert(provider.id)
            // These answer with no value: read them with `rpcValue`, which accepts that.
            _ = try await host.rpcValue("credentials/set", args: ["ref": provider.keyRef, "value": key])
            var listed = UserDefaults.standard.stringArray(forKey: listKey(provider.base)) ?? []
            if refreshModels || listed.isEmpty {
                do {
                    listed = try await ModelService.models(base: provider.base, key: key)
                    remember(listed, base: provider.base)
                } catch {
                    try Task.checkCancellation()
                    if refreshModels { discoveryError = error }
                }
            }
            let desired = profile(base: provider.base, model: provider.model, listed: listed, keyRef: provider.keyRef)
            // The host fills defaults into what it reads back: compare only the fields written here.
            if let current = routes[provider.id] as? Object,
               desired.allSatisfy({ field, value in (current[field] as? NSObject)?.isEqual(value) == true }) { continue }
            ops.append(["op": "set", "path": ["providers", provider.id], "value": desired])
        }
        let stale = routes.keys.filter { owns($0) && !kept.contains($0) }.sorted()
        ops += stale.map { ["op": "unset", "path": ["providers", $0]] }
        if !ops.isEmpty {
            _ = try await host.rpcValue("settings/mutate", args: ["ns": namespace, "expectedRevision": revision, "ops": ops])
            for id in stale { _ = try? await host.rpcValue("credentials/unset", args: ["ref": keyRef(for: id)]) }
        }
        if let discoveryError { throw discoveryError }
    }
}
