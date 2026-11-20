// 本机引擎的在线安装。手机上起不了 pnpm，所以由 App 自己从 npm 下载插件包、核对 integrity、
// 解包，再交给本机引擎已有的「导入已构建目录」流程（tmp/DSHPluginImport/<uuid>）。
// 不替插件装依赖：每个依赖要么打包在插件包里，要么是本机引擎自带的包；缺了就不装，说明缺哪些。

import CryptoKit
import Foundation

enum PluginDownload {
    struct Failure: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads `spec` (`name` or `name@version`) and stages it for the on-device plugin manager.
    static func stage(spec: String, registry: String? = nil) async throws -> PluginArchiveImportSheet.StagedPackage {
        guard let (name, version) = PluginPolicy.npmName(spec) else {
            throw Failure(code: "unsupported-source", message: PluginSharePlan.onlineRefusal)
        }
        let base = (registry ?? "https://registry.npmjs.org").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/" + name.replacingOccurrences(of: "/", with: "%2F") + "/" + (version ?? "latest")),
              url.scheme == "https" else { throw Failure(code: "bad-registry", message: String(localized: "插件源地址无效。")) }
        let manifest = try await json(url)
        guard let dist = manifest["dist"] as? Object, let tarball = (dist["tarball"] as? String).flatMap(URL.init(string:)),
              tarball.scheme == "https", let integrity = dist["integrity"] as? String else {
            throw Failure(code: "no-tarball", message: String(localized: "没能拿到「\(name)」的下载地址。请稍后重试。"))
        }
        if let refusal = PluginPolicy.refusal(manifest) { throw Failure(code: "ui-plugin", message: refusal) }

        let data = try await download(tarball)
        guard matches(data, integrity: integrity) else {
            throw Failure(code: "integrity-mismatch", message: String(localized: "下载的「\(name)」和发布的内容对不上，已停止安装。请稍后重试。"))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tgz")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let staged = try await Task.detached(priority: .userInitiated) { try PluginArchiveImportSheet.stage(file) }.value
        do {
            guard staged.name == name else {
                throw Failure(code: "name-mismatch", message: String(localized: "下载到的是「\(staged.name)」，不是「\(name)」，已停止安装。"))
            }
            let missing = try unbundledDependencies(in: staged.folder)
            if !missing.isEmpty {
                throw Failure(code: "dependencies-not-bundled",
                              message: String(localized: "「\(name)」依赖 \(missing.joined(separator: String(localized: "、")))，手机上缺这些组件，装不了。可以装到电脑上用。"))
            }
        } catch {
            try? FileManager.default.removeItem(at: staged.folder)
            throw error
        }
        return staged
    }

    /// `dependencies` of the unpacked package that are neither inside it nor shipped with the engine.
    static func unbundledDependencies(in folder: URL, engine: URL? = Bundle.main.url(forResource: "DSHEngine", withExtension: nil)) throws -> [String] {
        let data = try Data(contentsOf: folder.appendingPathComponent("package.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as? Object ?? [:]
        let wanted = (manifest["dependencies"] as? Object)?.keys.sorted() ?? []
        let fm = FileManager.default
        func has(_ root: URL?, _ dep: String) -> Bool {
            guard let root else { return false }
            return fm.fileExists(atPath: root.appendingPathComponent("node_modules").appendingPathComponent(dep).appendingPathComponent("package.json").path)
        }
        return wanted.filter { !has(folder, $0) && !has(engine, $0) }
    }

    /// npm's Subresource Integrity string (`sha512-<base64>`, possibly several, space-separated).
    static func matches(_ data: Data, integrity: String) -> Bool {
        let sha512 = Data(SHA512.hash(data: data)).base64EncodedString()
        let sha256 = Data(SHA256.hash(data: data)).base64EncodedString()
        return integrity.split(separator: " ").contains { entry in
            entry == "sha512-" + sha512 || entry == "sha256-" + sha256
        }
    }

    private static func json(_ url: URL) async throws -> Object {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw Failure(code: "not-found", message: String(localized: "找不到这个插件或版本，可能已下架。")) }
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? Object else {
            throw Failure(code: "registry-error", message: String(localized: "插件下载服务暂时不可用，请稍后重试。"))
        }
        return object
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 60))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(code: "download-failed", message: String(localized: "插件下载失败，请检查网络后重试。"))
        }
        guard data.count <= PluginArchive.maxArchive else { throw Failure(code: "too-large", message: String(localized: "插件包超过 64 MB。")) }
        return data
    }
}
