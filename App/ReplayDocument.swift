import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

extension UTType {
    static let dshConversation = UTType(importedAs: "io.github.maao514.dshlocal.conversation", conformingTo: .json)
}

struct ReplayEvent: Identifiable {
    let id: Int
    let kind: String
    let time: Int
    let duration: Int?
    let text: String
    let detail: String
    let imageIDs: [String]
    var tool: ChatStep?
    var tasks: [(text: String, status: String)] = []
    var phase: String?
    var turnSummary: String?

    var label: String {
        ["turn": String(localized: "开始一轮"), "user": String(localized: "我"), "reply": String(localized: "助手"), "tool": String(localized: "工具"), "notice": String(localized: "提示"),
         "todos": String(localized: "待办"), "goal": String(localized: "目标"), "command": String(localized: "命令")][kind] ?? kind
    }
}

struct ReplayPicture {
    let data: Data
    let mediaType: String
    let width: Int
    let height: Int

    init(reference: HostImage, bytes: Data) throws {
        if max(reference.width, reference.height) <= 1600, reference.mediaType != "image/gif" {
            data = bytes; mediaType = reference.mediaType; width = reference.width; height = reference.height
            return
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let raster = RasterFrames.frame(source, 0, pixels: 1600) else { throw HostError(String(localized: "无法生成分享图片。")) }
        width = raster.width; height = raster.height
        let transparent = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(raster.alphaInfo)
        guard let encoded = RasterFrames.encode(raster, as: transparent ? .png : .jpeg, quality: transparent ? nil : 0.82)
        else { throw HostError(String(localized: "无法编码分享图片。")) }
        data = encoded; mediaType = transparent ? "image/png" : "image/jpeg"
    }
}

struct ReplayDocument: Identifiable {
    let id = UUID()
    let title: String
    let events: [ReplayEvent]
    let images: [String: Data]
    /// Time of `t: 0`.
    var start: Date?
    /// What wrote the file (this app times its entries one second apart).
    var app: String?
    /// The rounds a part of a conversation covers: 「第 2–3 轮」 of `of`.
    var range: (from: Int, to: Int, of: Int)?

    /// When the conversation ended, in milliseconds after [start].
    var span: Int { events.map { $0.time + ($0.duration ?? 0) }.max() ?? 0 }
    /// The entries carry recorded times (not spaced out by this app's export).
    var timed: Bool { app != Self.appName }
    static let appName = "Pallas Agent"

    static let fileLimit = 4 * 1024 * 1024
    private static let bodyLimit = 16 * 1024 * 1024

    static func read(_ url: URL) throws -> ReplayDocument {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: fileLimit + 1) ?? Data()
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> ReplayDocument {
        guard data.count <= fileLimit else { throw HostError(String(localized: "文件超过 4 MB。")) }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? Object,
              let code = envelope["code"] as? String else { throw HostError(String(localized: "无法识别对话文件。")) }
        let parts = code.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 8,
              let compressed = unpack(String(parts[0])) else { throw HostError(String(localized: "分享码不完整。")) }
        let body = try transcode(compressed, compress: false)
        guard pack(Data(SHA256.hash(data: body).prefix(6))) == parts[1] else { throw HostError(String(localized: "对话校验失败。")) }
        guard let object = try JSONSerialization.jsonObject(with: body) as? Object,
              object["kind"] as? String == "conversation", let version = object["v"] as? Int,
              (1...2).contains(version), object["schema"] as? Int == 1,
              let rows = object["entries"] as? [Object], rows.count <= 20000 else { throw HostError(String(localized: "不支持此对话版本或类型。")) }
        let events = rows.enumerated().compactMap { index, row -> ReplayEvent? in
            guard let kind = row["type"] as? String else { return nil }
            var text = row["text"] as? String ?? ""
            var detail = ""
            var tool: ChatStep?
            var tasks: [(text: String, status: String)] = []
            switch kind {
            case "turn": break
            case "user":
                detail = (row["files"] as? [Object] ?? []).compactMap { $0["name"] as? String }.joined(separator: String(localized: "、"))
            case "reply": detail = row["think"] as? String ?? ""
            case "tool":
                text = row["summary"] as? String ?? row["name"] as? String ?? String(localized: "工具")
                let arguments: String
                if let object = row["args"] as? Object, let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    arguments = String(decoding: json, as: UTF8.self)
                } else { arguments = row["args"] as? String ?? "" }
                let status = row["status"] as? String ?? "ok"
                var results = [row["result"], row["error"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                if let more = row["more"] as? Int, more > 0 { results.append(String(localized: "已略去 \(more) 个字符")) }
                let result = results.joined(separator: "\n")
                detail = [status, arguments, result].filter { !$0.isEmpty }.joined(separator: "\n")
                tool = ChatStep(id: String(index), name: row["name"] as? String ?? text, arguments: arguments, result: result, state: status)
            case "todos":
                tasks = (row["items"] as? [Object] ?? []).compactMap { item in
                    guard let title = item["text"] as? String else { return nil }
                    return (title, item["status"] as? String ?? "pending")
                }
                text = tasks.map(\.text).joined(separator: "\n")
            case "command": detail = text; text = row["line"] as? String ?? "/"
            case "goal", "notice": break
            default: return nil
            }
            var summary: String?
            if kind == "turn", let end = row["end"] as? String {
                var fields = [["completed": String(localized: "已完成"), "cancelled": String(localized: "已取消"), "failed": String(localized: "失败")][end] ?? end]
                if let steps = row["steps"] as? Int { fields.append(String(localized: "\(steps) 步")) }
                if let tokens = row["tokens"] as? Int { fields.append("\(tokens) tokens") }
                summary = fields.joined(separator: " · ")
            }
            return ReplayEvent(id: index, kind: kind, time: max(0, row["t"] as? Int ?? 0),
                               duration: (row["d"] as? Int).map { max(0, $0) }, text: text, detail: detail,
                               imageIDs: (row["images"] as? [Object] ?? []).compactMap { $0["id"] as? String },
                               tool: tool, tasks: tasks, phase: row["phase"] as? String, turnSummary: summary)
        }
        var images: [String: Data] = [:]
        let assets = envelope["assets"] as? [String: Object] ?? [:]
        for id in Set(events.flatMap(\.imageIDs)) {
            if let encoded = assets[id]?["data"] as? String, let bytes = Data(base64Encoded: encoded),
               pack(Data(SHA256.hash(data: bytes).prefix(9))) == id { images[id] = bytes }
        }
        func int(_ value: Any?) -> Int? { (value as? NSNumber).map(\.intValue) }
        var range: (from: Int, to: Int, of: Int)?
        if let span = object["range"] as? Object, let from = int(span["from"]), let to = int(span["to"]), let of = int(span["of"]),
           from >= 1, from <= to, to <= of { range = (from, to, of) }
        let started = (object["start"] as? String).flatMap { text -> Date? in
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = parser.date(from: text) { return value }
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: text)
        }
        return ReplayDocument(title: object["title"] as? String ?? String(localized: "对话"), events: events, images: images,
                              start: started, app: object["app"] as? String, range: range)
    }

    static func encode(title: String, turns: [LocalTurn], pictures: [String: ReplayPicture] = [:],
                       range: (from: Int, to: Int, of: Int)? = nil) throws -> Data {
        let now = ISO8601DateFormatter().string(from: Date())
        var entries: [Object] = []
        var assets: [String: Object] = [:]
        func attachments(_ refs: [HostImage]?) throws -> [Object] {
            try (refs ?? []).map { ref in
                guard let picture = pictures[ref.id] else { throw HostError(String(localized: "分享所需的图片尚未加载。")) }
                let id = pack(Data(SHA256.hash(data: picture.data).prefix(9)))
                if assets[id] == nil { assets[id] = ["type": picture.mediaType, "w": picture.width, "h": picture.height, "data": picture.data.base64EncodedString()] }
                var item: Object = ["id": id, "w": picture.width, "h": picture.height]
                if let name = ref.name { item["name"] = ShareText.redacted((name as NSString).lastPathComponent) }
                return item
            }
        }
        for row in turns {
            for step in row.steps ?? [] {
                var entry: Object = ["type": "tool", "t": entries.count * 1000, "name": step.name, "args": step.arguments,
                                "summary": step.displayName, "result": step.sharedResult, "status": step.state == "running" ? "cancelled" : step.state]
                if let args = try? JSONSerialization.jsonObject(with: Data(step.arguments.utf8)) as? Object { entry["args"] = args }
                if step.state == "error" { entry["status"] = "failed" }
                if let refs = step.images { entry["images"] = try attachments(refs) }
                entries.append(entry)
            }
            if !row.outgoing, row.text.isEmpty, row.thinking?.isEmpty != false, row.images?.isEmpty != false, row.steps?.isEmpty == false { continue }
            var entry: Object = ["type": row.outgoing ? "user" : "reply", "t": entries.count * 1000, "text": row.text]
            if let refs = row.images { entry["images"] = try attachments(refs) }
            entry["think"] = row.thinking
            entries.append(entry)
        }
        guard entries.count <= 20000 else { throw HostError(String(localized: "消息过多，请缩小范围。")) }
        var object: Object = ["v": 2, "kind": "conversation", "schema": 1, "start": now, "created": now,
                              "app": appName, "title": title, "entries": entries]
        if let range { object["range"] = ["from": range.from, "to": range.to, "of": range.of] }
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= bodyLimit else { throw HostError(String(localized: "对话过长，请缩小范围。")) }
        let code = pack(try transcode(body, compress: true)) + "." + pack(Data(SHA256.hash(data: body).prefix(6)))
        let envelope = try JSONSerialization.data(withJSONObject: ["dshlocal": 2, "kind": "conversation", "name": title, "code": code, "assets": assets])
        guard envelope.count <= fileLimit else { throw HostError(String(localized: "文件超过 4 MB。少选几条消息，或关掉图片。")) }
        return envelope
    }

    static func pack(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    static func unpack(_ code: String) -> Data? {
        let normalized = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - code.count % 4) % 4)),
              pack(data) == code else { return nil }
        return data
    }

    static func transcode(_ bytes: Data, compress: Bool, gzip: Bool = false) throws -> Data {
        var stream = z_stream()
        let size = Int32(MemoryLayout<z_stream>.size)
        let status = compress
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, gzip ? 31 : -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, size)
            : inflateInit2_(&stream, gzip ? 31 : -15, ZLIB_VERSION, size)
        guard status == Z_OK else { throw HostError(String(localized: "压缩服务不可用。")) }
        defer { if compress { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        return try bytes.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(bytes.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 32768)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress; stream.avail_out = UInt32(target.count)
                    return compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard result.count + count <= (compress ? fileLimit : bodyLimit) else { throw HostError(String(localized: "对话超过大小限制。")) }
                result.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END, stream.avail_in == 0 { return result }
                guard status == Z_OK, count > 0 else { throw HostError(String(localized: "压缩数据损坏。")) }
            }
        }
    }

    var markdown: String {
        events.compactMap { event in
            switch event.kind {
            case "user", "reply": return "## " + event.label + "\n\n" + event.text
            case "tool": return String(localized: "工具 · ") + event.text.components(separatedBy: .newlines).joined(separator: " ")
            default: return nil
            }
        }.joined(separator: "\n\n")
    }
}
