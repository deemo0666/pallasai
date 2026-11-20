// 哪些插件能装进 Pallas Agent：只收跑在引擎里的部分（给模型的工具、服务、主机命令）。
// 改界面的插件一律不收：带网页版界面的（`dsh.client`，或导出 `./client`），以及带原生界面清单的。
// 装之前读插件自己的 package.json 判断；读不到就不装，不猜。

import Foundation

enum PluginPolicy {
    /// The package.json key another client reads its native screens from.
    static let nativeUIKey = "dshGo"

    /// Why `manifest` (a plugin's package.json) cannot be installed; nil when it may.
    static func refusal(_ manifest: Object) -> String? {
        let name = manifest["name"] as? String ?? String(localized: "这个插件")
        if manifest[nativeUIKey] != nil { return String(localized: "「\(name)」会改动界面，Pallas Agent 不能安装这类插件。") }
        if (manifest["dsh"] as? Object)?["client"] != nil || (manifest["exports"] as? Object)?["./client"] != nil {
            return String(localized: "「\(name)」是给网页版用的，Pallas Agent 不能安装这类插件。")
        }
        return nil
    }

    /// The same check for an install spec: a local folder, an npm `name[@version]`, or a GitHub
    /// `git+https://…#commit`. Anything it cannot read is refused.
    static func refusal(spec: String, registry: String? = nil) async -> String? {
        let manifest: Object?
        do { manifest = try await self.manifest(spec: spec, registry: registry) }
        catch { return String(localized: "没能读取这个插件的信息，暂时不能安装。请检查网络后重试。") }
        guard let manifest else { return String(localized: "Pallas Agent 不支持这个插件的来源。请到插件市场里找。") }
        return refusal(manifest)
    }

    private static func manifest(spec: String, registry: String?) async throws -> Object? {
        if spec.hasPrefix("/") {
            let data = try Data(contentsOf: URL(fileURLWithPath: spec).appendingPathComponent("package.json"))
            return try JSONSerialization.jsonObject(with: data) as? Object
        }
        if spec.hasPrefix("git+https://github.com/") { return try await gitHubManifest(spec) }
        guard let (name, version) = npmName(spec) else { return nil }
        let base = (registry ?? "https://registry.npmjs.org").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let escaped = name.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: base + "/" + escaped + "/" + (version ?? "latest")), url.scheme == "https" else { return nil }
        return try await fetch(url)
    }

    /// `name`, `name@1.2.3`, `@scope/name`, `@scope/name@1.2.3`; nil for paths, URLs and aliases.
    static func npmName(_ spec: String) -> (name: String, version: String?)? {
        guard !spec.contains(":"), !spec.hasPrefix("."), !spec.isEmpty else { return nil }
        let start = spec.hasPrefix("@") ? spec.index(after: spec.startIndex) : spec.startIndex
        guard let at = spec[start...].firstIndex(of: "@") else { return (spec, nil) }
        let version = String(spec[spec.index(after: at)...])
        return (String(spec[..<at]), version.isEmpty ? nil : version)
    }

    /// `git+https://github.com/owner/repo(.git)#commit(&path:/sub)` → that commit's package.json.
    private static func gitHubManifest(_ spec: String) async throws -> Object? {
        let rest = spec.dropFirst("git+https://github.com/".count)
        let parts = rest.split(separator: "#", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let repo = parts[0].hasSuffix(".git") ? parts[0].dropLast(4) : parts[0]
        let ref = parts[1].components(separatedBy: "&path:/")
        let folder = ref.count > 1 ? ref[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" : ""
        guard repo.split(separator: "/").count == 2, !folder.contains(".."),
              let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(ref[0])/\(folder)package.json") else { return nil }
        return try await fetch(url)
    }

    private static func fetch(_ url: URL) async throws -> Object? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HostError(String(localized: "没能读取这个插件的信息"), code: "manifest-http-\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONSerialization.jsonObject(with: data) as? Object
    }

    /// Official bundles whose only use is a DSH web screen this app does not have.
    static let hiddenOfficial: Set<String> = [
        "@deepseek-ai/dsh-experimental-voice-input-bundle",
        "@deepseek-ai/dsh-experimental-plugin-market-bundle",
    ]
}
