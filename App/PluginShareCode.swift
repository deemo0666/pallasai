// 插件分享码的格式，以及离线插件包（ZIP、tgz）的解包。
//
// 分享码：`<base64url(deflate-raw(JSON))>.<base64url(sha256(JSON) 前 6 字节)>`，JSON 为
// `{"v":1,"kind":"plugin","plugin":{name, source, spec, version, integrity, title, author, summary}}`。
// 分享码出现在 `dshlocal://share/plugin?p=`、二维码和 `.dshlocal` 文件
// （`{"dshlocal":1,"kind":"plugin","name":…,"code":…}`）里，只在本机解码。

import CryptoKit
import Foundation

/// One plugin as a legacy share code describes it, already validated.
struct SharedPlugin: Hashable, Identifiable {
    enum Source: String { case npm, github, git, official }
    let name: String
    let source: Source
    let spec: String?
    let version: String?
    let integrity: String?
    let title: String?
    let author: String?
    let summary: String?
    var id: String { name + "@" + (version ?? spec ?? "") }

    var displayTitle: String { title ?? name }

    /// 「npm · 发布者」「GitHub · owner/repo」, the git host, or 「DSH 官方」.
    var sourceLabel: String {
        switch source {
        case .npm: return author.map { "npm · " + $0 } ?? "npm"
        case .official: return String(localized: "官方")
        case .github:
            let repo = spec.flatMap(Self.githubRepository)
            return repo.map { "GitHub · " + $0 } ?? "GitHub"
        case .git: return spec.flatMap { URL(string: $0.replacingOccurrences(of: "git+", with: ""))?.host } ?? "Git"
        }
    }

    /// The version, else the git ref after `#`, else 「—」.
    var versionLabel: String {
        if let version { return version }
        guard let spec, let hash = spec.firstIndex(of: "#") else { return "—" }
        let ref = spec[spec.index(after: hash)...].split(separator: "&").first.map(String.init) ?? ""
        return ref.isEmpty ? "—" : String(ref.prefix(12))
    }

    private static func githubRepository(_ spec: String) -> String? {
        if spec.hasPrefix("github:") {
            return spec.dropFirst(7).split(separator: "#").first.map(String.init)
        }
        guard let url = URL(string: spec.replacingOccurrences(of: "git+", with: "")) else { return nil }
        let parts = url.path.split(separator: "/").prefix(2).map { $0.replacingOccurrences(of: ".git", with: "") }
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }
}

/// Decoding a legacy share code; every failure reads as one of four messages.
enum PluginShareCode {
    struct Failure: LocalizedError {
        enum Kind { case newer, unusable, damaged, notPlugin }
        let kind: Kind
        var errorDescription: String? {
            switch kind {
            case .newer: String(localized: "这是新版格式，请更新 App 后再打开。")
            case .unusable: String(localized: "这个分享码不能使用。")
            case .damaged: String(localized: "分享码不完整或已损坏。")
            case .notPlugin: String(localized: "这不是插件分享。")
            }
        }
    }

    static let maxBody = 1024 * 1024
    static let maxFile = 8 * 1024 * 1024
    private static let namePattern = #"\A(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*\z"#
    private static let semver = #"\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z"#
    private static let integrityPattern = #"\Asha(?:256|384|512)-[A-Za-z0-9+/]+=*\z"#
    private static let githubShort = #"\Agithub:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[^\s&#]+(?:&path:/[^\s&#]+)?\z"#
    private static let githubURL = #"\Agit\+https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?#[^\s&#]+(?:&path:/[^\s&#]+)?\z"#
    private static let gitURL = #"\Agit\+https://[A-Za-z0-9.-]+(?::\d+)?/[^\s#?]+#[^\s&#]+(?:&path:/[^\s&#]+)?\z"#

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Collapses whitespace and cuts display text to `limit` characters with 「…」.
    private static func clean(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
    }

    // MARK: Codec

    static func decode(_ code: String) throws -> SharedPlugin {
        let body = try inflate(code.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let root = try? JSONSerialization.jsonObject(with: body) as? Object else { throw Failure(kind: .damaged) }
        return try plugin(from: root)
    }

    /// The inflated JSON bytes of a code, checksum verified.
    static func inflate(_ code: String) throws -> Data {
        let parts = code.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 8,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_" } }),
              let packed = base64URL(String(parts[0])), let check = base64URL(String(parts[1])), check.count == 6 else {
            throw Failure(kind: .damaged)
        }
        guard packed.count <= maxBody, let body = try? (packed as NSData).decompressed(using: .zlib) as Data,
              body.count <= maxBody else { throw Failure(kind: .damaged) }
        guard Data(SHA256.hash(data: body).prefix(6)) == check else { throw Failure(kind: .damaged) }
        return body
    }

    /// The code for `json` (compact JSON bytes); used by tests and for sharing back out.
    static func encode(_ json: Data) throws -> String {
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        return base64URLString(packed) + "." + base64URLString(Data(SHA256.hash(data: json).prefix(6)))
    }

    static func plugin(from root: Object) throws -> SharedPlugin {
        guard let version = root["v"] as? Int else { throw Failure(kind: .unusable) }
        if version > 1 { throw Failure(kind: .newer) }
        guard version == 1 else { throw Failure(kind: .unusable) }
        guard root["kind"] as? String == "plugin" else { throw Failure(kind: .notPlugin) }
        guard let body = root["plugin"] as? Object, let name = body["name"] as? String, name.utf8.count <= 214,
              matches(name, namePattern), let source = (body["source"] as? String).flatMap(SharedPlugin.Source.init) else {
            throw Failure(kind: .unusable)
        }
        let spec = body["spec"] as? String
        let pinned = body["version"] as? String
        let integrity = body["integrity"] as? String
        switch source {
        case .npm:
            guard let pinned, matches(pinned, semver), spec == name + "@" + pinned,
                  let integrity, matches(integrity, integrityPattern) else { throw Failure(kind: .unusable) }
        case .github:
            guard let spec, matches(spec, githubShort) || matches(spec, githubURL) else { throw Failure(kind: .unusable) }
        case .git:
            guard let spec, matches(spec, gitURL) else { throw Failure(kind: .unusable) }
        case .official:
            guard spec == nil else { throw Failure(kind: .unusable) }
        }
        return SharedPlugin(name: name, source: source, spec: spec, version: pinned.flatMap { matches($0, semver) ? $0 : nil },
                            integrity: source == .npm ? integrity : nil,
                            title: clean(body["title"], limit: 80), author: clean(body["author"], limit: 80),
                            summary: clean(body["summary"], limit: 200))
    }

    // MARK: Where codes come from

    /// What a pasted text, scanned code, or opened link holds.
    enum Found: Equatable {
        case code(String)
        /// A market page link: look the package up in the plugin market.
        case market(String)
    }

    /// Finds a plugin share in `text`: a `dshlocal://` link, `.dshlocal` JSON, or a bare code.
    static func find(_ text: String) -> Found? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8), let code = try? fileCode(data) { return .code(code) }
        for token in trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if let url = URL(string: String(token)), let found = link(url) { return found }
        }
        // Shaped like a share code (two base64url parts): `decode` then says whether it is damaged.
        if trimmed.wholeMatch(of: /[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{6,}/) != nil { return .code(trimmed) }
        return nil
    }

    /// `dshlocal://share/plugin?p=<code>` and `dshlocal://market/<name>`.
    static func link(_ url: URL) -> Found? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "dshlocal" else { return nil }
        let host = parts.host?.lowercased() ?? ""
        if host == "share", parts.path == "/plugin",
           let code = parts.queryItems?.first(where: { $0.name == "p" })?.value, !code.isEmpty {
            return .code(code)
        }
        if host == "market" {
            let name = String(parts.path.dropFirst()).removingPercentEncoding ?? ""
            return matches(name, namePattern) ? .market(name) : nil
        }
        return nil
    }

    /// The code inside a `.dshlocal` file body, or the body itself when it is a bare code.
    static func fileCode(_ data: Data) throws -> String {
        guard data.count <= maxFile else { throw Failure(kind: .unusable) }
        if let root = try? JSONSerialization.jsonObject(with: data) as? Object {
            guard root["dshlocal"] is Int, let code = root["code"] as? String else { throw Failure(kind: .unusable) }
            if let kind = root["kind"] as? String, kind != "plugin" { throw Failure(kind: .notPlugin) }
            return code
        }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.hasPrefix("{"), !text.isEmpty else { throw Failure(kind: .damaged) }
        return text
    }

    /// Whether a `.dshlocal` file is a plugin share (conversation shares keep going to the replay viewer).
    static func isPluginFile(_ url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), let root = try? JSONSerialization.jsonObject(with: head) as? Object else { return false }
        return root["kind"] as? String == "plugin"
    }

    static func readFile(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFile else { throw Failure(kind: .unusable) }
        guard let data = try? Data(contentsOf: url) else { throw HostError(String(localized: "没能读取这个文件。")) }
        return try fileCode(data)
    }

    // MARK: base64url

    static func base64URL(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }

    static func base64URLString(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What npm says about the version a share names.
struct NpmVersionFacts: Equatable {
    enum Check: Equatable { case verified, mismatch, unverifiable }
    let check: Check
    let unpackedSize: Int?
    let publisher: String?

    /// `registry.npmjs.org/<name>/<version>`: compares `dist.integrity` with the share's.
    static func look(_ plugin: SharedPlugin) async -> Self {
        guard plugin.source == .npm, let version = plugin.version, let expected = plugin.integrity,
              let escaped = plugin.name.replacingOccurrences(of: "/", with: "%2F").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://registry.npmjs.org/" + escaped + "/" + version) else {
            return Self(check: .unverifiable, unpackedSize: nil, publisher: nil)
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? Object, let dist = root["dist"] as? Object,
              let actual = dist["integrity"] as? String else { return Self(check: .unverifiable, unpackedSize: nil, publisher: nil) }
        return Self(check: actual == expected ? .verified : .mismatch, unpackedSize: dist["unpackedSize"] as? Int,
                    publisher: (root["_npmUser"] as? Object)?["name"] as? String)
    }
}

// MARK: - 离线插件包

/// Unpacks a plugin archive (ZIP, `.tgz` / `.tar.gz`, `.tar`) into a fresh directory and finds the
/// package root (the folder holding `package.json`). Symlinks, devices, absolute or `..` paths,
/// encrypted ZIP entries and archives over the size limits are refused.
enum PluginArchive {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let maxArchive = 64 * 1024 * 1024
    static let maxUnpacked = 160 * 1024 * 1024
    static let maxEntries = 6000

    enum Format { case zip, gzipTar, tar }

    static func format(of data: Data) -> Format? {
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if data.starts(with: [0x1F, 0x8B]) { return .gzipTar }
        if data.count >= 263, data[257..<262].elementsEqual(Array("ustar".utf8)) { return .tar }
        return nil
    }

    /// Unpacks `archive` under `destination` (which must not exist) and returns the package root.
    static func unpack(_ archive: URL, into destination: URL) throws -> URL {
        try extract(archive, into: destination)
        do { return try packageRoot(destination) } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Unpacks `archive` under `destination` (which must not exist), with the same checks as `unpack`.
    static func extract(_ archive: URL, into destination: URL, skipLinks: Bool = false) throws {
        let fm = FileManager.default
        let access = archive.startAccessingSecurityScopedResource()
        defer { if access { archive.stopAccessingSecurityScopedResource() } }
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxArchive else { throw Failure(message: String(localized: "压缩包超过 64 MB。")) }
        let data: Data
        do { data = try Data(contentsOf: archive, options: .mappedIfSafe) } catch { throw Failure(message: String(localized: "没能读取这个文件。")) }
        guard let format = format(of: data) else { throw Failure(message: String(localized: "只支持 ZIP、tgz 和 tar 格式的压缩包。")) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            var writer = Writer(root: destination, skipLinks: skipLinks)
            switch format {
            case .zip: try unzip(data, into: &writer)
            case .gzipTar: try untar(try gunzip(data), into: &writer)
            case .tar: try untar(data, into: &writer)
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// `destination/package.json`, or the one top-level folder holding it (`package/` from npm pack).
    static func packageRoot(_ destination: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.appendingPathComponent("package.json").path) { return destination }
        let tops = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        guard tops.count == 1, let top = tops.first, (try? top.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              fm.fileExists(atPath: top.appendingPathComponent("package.json").path) else {
            throw Failure(message: String(localized: "压缩包里没有找到插件。"))
        }
        return top
    }

    /// Creates files strictly inside `root`, counting entries and bytes.
    struct Writer {
        let root: URL
        /// Leave links out instead of refusing the archive (skills from a whole repository).
        var skipLinks = false
        var entries = 0
        var bytes = 0

        mutating func path(_ raw: String) throws -> URL? {
            let name = raw.replacingOccurrences(of: "\\", with: "/")
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.contains(where: { $0.contains("\0") }) else {
                throw Failure(message: String(localized: "压缩包里有越出目录的路径。"))
            }
            if parts.isEmpty || parts.first == "__MACOSX" || parts.last == ".DS_Store" { return nil }
            entries += 1
            guard entries <= maxEntries else { throw Failure(message: String(localized: "压缩包文件太多。")) }
            return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
        }

        mutating func directory(_ raw: String) throws {
            guard let url = try path(raw) else { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        mutating func file(_ raw: String, _ contents: Data) throws {
            guard let url = try path(raw) else { return }
            bytes += contents.count
            guard bytes <= maxUnpacked else { throw Failure(message: String(localized: "解压后超过 160 MB。")) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure(message: String(localized: "压缩包里有重复的文件。")) }
            try contents.write(to: url)
        }
    }

    // MARK: ZIP

    private static func u16(_ data: Data, _ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
    private static func u32(_ data: Data, _ at: Int) -> Int { u16(data, at) | u16(data, at + 2) << 16 }

    static func unzip(_ data: Data, into writer: inout Writer) throws {
        let broken = Failure(message: String(localized: "ZIP 文件已损坏。"))
        guard data.count >= 22 else { throw broken }
        var end = -1
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 65535)
        while i >= floor {
            if u32(data, i) == 0x06054B50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw broken }
        let count = u16(data, end + 10), dirSize = u32(data, end + 12), dirStart = u32(data, end + 16)
        guard count != 0xFFFF, dirStart != 0xFFFFFFFF else { throw Failure(message: String(localized: "不支持 ZIP64 格式。")) }
        guard dirStart + dirSize <= end else { throw broken }
        var at = dirStart
        for _ in 0..<count {
            guard at + 46 <= end, u32(data, at) == 0x02014B50 else { throw broken }
            let made = u16(data, at + 4) >> 8, flags = u16(data, at + 8), method = u16(data, at + 10)
            let crc = UInt32(u32(data, at + 16)), packed = u32(data, at + 20), size = u32(data, at + 24)
            let nameLength = u16(data, at + 28), extra = u16(data, at + 30), comment = u16(data, at + 32)
            let mode = u32(data, at + 38) >> 16, local = u32(data, at + 42)
            guard at + 46 + nameLength <= end else { throw broken }
            let name = String(decoding: data[(data.startIndex + at + 46)..<(data.startIndex + at + 46 + nameLength)], as: UTF8.self)
            at += 46 + nameLength + extra + comment
            guard flags & 1 == 0 else { throw Failure(message: String(localized: "不支持加密的 ZIP。")) }
            if made == 3, mode & 0o170000 == 0o120000 {
                if writer.skipLinks { continue }
                throw Failure(message: String(localized: "插件包内含符号链接，无法导入。"))
            }
            if name.hasSuffix("/") { try writer.directory(name); continue }
            guard local + 30 <= data.count, u32(data, local) == 0x04034B50 else { throw broken }
            let start = local + 30 + u16(data, local + 26) + u16(data, local + 28)
            guard start + packed <= data.count else { throw broken }
            let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + packed))
            let contents: Data
            switch method {
            case 0: contents = raw
            case 8:
                guard size <= maxUnpacked else { throw Failure(message: String(localized: "解压后超过 160 MB。")) }
                contents = size == 0 ? Data() : (try? (raw as NSData).decompressed(using: .zlib) as Data) ?? Data()
            default: throw Failure(message: String(localized: "ZIP 使用了不支持的压缩方式。"))
            }
            guard contents.count == size, CRC32.checksum(contents) == crc else { throw broken }
            try writer.file(name, contents)
        }
    }

    // MARK: gzip + tar

    static func gunzip(_ data: Data) throws -> Data {
        let broken = Failure(message: String(localized: "tgz 文件已损坏。"))
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw broken }
        let flags = bytes[3]
        var at = 10
        if flags & 4 != 0 {
            guard at + 2 <= bytes.count else { throw broken }
            at += 2 + (Int(bytes[at]) | Int(bytes[at + 1]) << 8)
        }
        if flags & 8 != 0 { while at < bytes.count, bytes[at] != 0 { at += 1 }; at += 1 }
        if flags & 16 != 0 { while at < bytes.count, bytes[at] != 0 { at += 1 }; at += 1 }
        if flags & 2 != 0 { at += 2 }
        guard at < bytes.count - 8 else { throw broken }
        let trailer = bytes.count - 8
        let crc = UInt32(bytes[trailer]) | UInt32(bytes[trailer + 1]) << 8 | UInt32(bytes[trailer + 2]) << 16 | UInt32(bytes[trailer + 3]) << 24
        let size = Int(bytes[trailer + 4]) | Int(bytes[trailer + 5]) << 8 | Int(bytes[trailer + 6]) << 16 | Int(bytes[trailer + 7]) << 24
        guard size <= maxUnpacked + 64 * 1024 * 1024 else { throw Failure(message: String(localized: "解压后超过 160 MB。")) }
        guard let body = try? (data.subdata(in: (data.startIndex + at)..<(data.startIndex + trailer)) as NSData).decompressed(using: .zlib) as Data,
              body.count & 0xFFFFFFFF == size, CRC32.checksum(body) == crc else { throw broken }
        return body
    }

    static func untar(_ data: Data, into writer: inout Writer) throws {
        let broken = Failure(message: String(localized: "tar 文件已损坏。"))
        var at = 0
        var longName: String?
        func text(_ range: Range<Int>) -> String {
            let slice = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
            return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
        }
        func octal(_ range: Range<Int>) throws -> Int {
            let value = text(range).trimmingCharacters(in: .whitespaces)
            guard let number = value.isEmpty ? 0 : Int(value, radix: 8), number >= 0 else { throw broken }
            return number
        }
        while at + 512 <= data.count {
            let header = data[(data.startIndex + at)..<(data.startIndex + at + 512)]
            if header.allSatisfy({ $0 == 0 }) { return }
            let size = try octal(at + 124 ..< at + 136)
            let type = data[data.startIndex + at + 156]
            var name = text(at ..< at + 100)
            if text(at + 257 ..< at + 262) == "ustar" {
                let prefix = text(at + 345 ..< at + 500)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let start = at + 512
            guard start + size <= data.count else { throw broken }
            let body = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + size))
            at = start + (size + 511) / 512 * 512
            if let pending = longName { name = pending; longName = nil }
            switch type {
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"): try writer.file(name, body)
            case UInt8(ascii: "5"): try writer.directory(name)
            case UInt8(ascii: "L"): longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "x"):
                // A pax header: only its `path` record matters here.
                for record in String(decoding: body, as: UTF8.self).split(separator: "\n") {
                    if let space = record.firstIndex(of: " "), record[record.index(after: space)...].hasPrefix("path=") {
                        longName = String(record[record.index(after: space)...].dropFirst(5))
                    }
                }
            case UInt8(ascii: "g"): continue
            case UInt8(ascii: "1"), UInt8(ascii: "2"):
                if writer.skipLinks { continue }
                throw Failure(message: String(localized: "插件包内含链接，无法导入。"))
            default: throw Failure(message: String(localized: "插件包内含特殊文件，无法导入。"))
            }
        }
    }
}

/// IEEE CRC-32 (ZIP and gzip).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }
}
