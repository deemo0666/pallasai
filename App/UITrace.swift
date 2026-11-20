// 界面埋点：前后台、回前台重连、对话重载、聊天区滚动位置、进场动画卡住。
// 同时写系统日志（分类 ui）和 App 容器里的 Library/Logs/ui.log（只留最近一段），
// App 重启后也能从 Mac 拉：
//   xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
//     --domain-identifier <bundle id> --source Library/Logs/ui.log --destination ui.log
// 只记数量、状态、时间和对话 ID 前 8 位，不记对话内容。

import Foundation
import os
#if os(iOS)
import ImageIO
import UIKit
#endif

enum UITrace {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dsh-local", category: "ui")
    private static let queue = DispatchQueue(label: "dsh.ui-trace")
    private static let limit = 256 * 1024
    static let file: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        let folder = library.appendingPathComponent("Logs/Pallas Agent", isDirectory: true)
        #else
        let folder = library.appendingPathComponent("Logs", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ui.log")
    }()
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    static func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        let now = Date()
        queue.async {
            let text = stamp.string(from: now) + " " + line + "\n"
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size + UInt64(data.count) > UInt64(limit) {
                    // Keep the newer half.
                    try? handle.close()
                    if let old = try? Data(contentsOf: file) {
                        var kept = old.suffix(limit / 2)
                        if let cut = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[(cut + 1)...] }
                        try? (Data(kept) + data).write(to: file, options: .atomic)
                    }
                    return
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

/// The chat list's latest scroll geometry, kept outside SwiftUI state so scrolling does not redraw the list.
final class ScrollProbe {
    var content: CGFloat = 0
    var top: CGFloat = 0
    var visible: CGFloat = 0
    var insets: CGFloat = 0
    /// Everything is on screen (known from iOS 18 on): there is nowhere to scroll to.
    var fits: Bool { content > 0 && content + insets <= visible + 1 }
    var summary: String { "content \(Int(content)) offset \(Int(top)) visible \(Int(visible))" }
}

/// 发图片各步的耗时和主线程卡顿，写进 ui.log（行首 `img`）。启动参数 `-imageTiming YES` 打开。
enum ImageTiming {
    static let enabled = UserDefaults.standard.bool(forKey: "imageTiming")

    @discardableResult
    static func measure<T>(_ label: String, _ detail: @autoclosure () -> String = "", _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try work()
        log(label, start: start, detail())
        return value
    }

    static func measure<T>(_ label: String, _ detail: @autoclosure () -> String = "", _ work: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await work()
        log(label, start: start, detail())
        return value
    }

    static func log(_ label: String, start: UInt64, _ detail: String = "") {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        UITrace.note(String(format: "img %@ %.1f ms main=%d ", label, ms, Thread.isMainThread ? 1 : 0) + detail)
    }

    /// A background thread pings the main thread; each wait over 50 ms is logged as `img stall`.
    static func startStallWatch() {
        guard enabled else { return }
        let thread = Thread {
            while true {
                let done = DispatchSemaphore(value: 0)
                let start = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                if ms > 50 { UITrace.note(String(format: "img stall %.0f ms", ms)) }
                usleep(10_000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

#if DEBUG && os(iOS)
/// UI 测试用：收到 Darwin 通知 `io.dsh.bench.photos` 时，造 `-benchPhotoCount` 张 24MP HEIC
/// （默认 3），走和相册选图同一条路加进输入框。只在 `-imageTiming YES` 时监听。
enum PhotoBench {
    static var handler: (([Data]) -> Void)?
    static let name = "io.dsh.bench.photos" as CFString

    static func listen(_ attach: @escaping ([Data]) -> Void) {
        guard ImageTiming.enabled else { return }
        let first = handler == nil
        handler = attach
        guard first else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task.detached {
                let count = max(1, UserDefaults.standard.integer(forKey: "benchPhotoCount"))
                let photos = (0..<count).compactMap { _ in PhotoBench.make() }
                await MainActor.run { PhotoBench.handler?(photos) }
            }
        }, name, nil, .deliverImmediately)
    }

    /// 5712 × 4284 (24 MP, the iPhone default), random shapes so the encoders get real work.
    nonisolated static func make() -> Data? {
        let size = UserDefaults.standard.bool(forKey: "benchPortrait") ? CGSize(width: 4284, height: 5712) : CGSize(width: 5712, height: 4284)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: .random(in: 0...1), saturation: 0.3, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<600 {
                UIColor(hue: .random(in: 0...1), saturation: .random(in: 0.2...0.9), brightness: .random(in: 0.3...1), alpha: .random(in: 0.2...0.8)).setFill()
                let d = CGFloat.random(in: 40...900)
                UIBezierPath(ovalIn: CGRect(x: .random(in: -200...size.width), y: .random(in: -200...size.height), width: d, height: d * .random(in: 0.5...1.5))).fill()
            }
            // Fine grain like a real photo's, so the files come out a few MB as camera HEICs do.
            let side = 509
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            for i in bytes.indices { bytes[i] = i % 4 == 3 ? 255 : .random(in: 0...255) }
            if let provider = CGDataProvider(data: Data(bytes) as CFData),
               let grain = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                context.cgContext.setAlpha(0.18)
                context.cgContext.draw(grain, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
            }
        }
        guard let cg = image.cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
#endif
