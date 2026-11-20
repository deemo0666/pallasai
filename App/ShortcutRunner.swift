import Foundation
#if os(iOS)
import UIKit
#endif

/// The native side of the model's `run_shortcut` tool.
@MainActor
final class ShortcutRunner {
    static let shared = ShortcutRunner()

    struct Request: Decodable, Sendable {
        let shortcutRequest: UUID
        let args: Args
        let approval: String?
        struct Args: Decodable, Sendable {
            let name: String
            let input: String?
        }
    }

    struct Cancel: Decodable { let shortcutCancel: UUID }

    enum Outcome {
        case output(String)
        case failure(code: String, message: String)
    }

    #if os(iOS)
    private struct Waiting {
        let id: UUID
        let resume: (Outcome) -> Void
    }

    /// Past this the shortcut is taken as stuck; the engine gives up a minute later.
    private static let limit: Duration = .seconds(10 * 60)
    /// How long a return to the app without a callback waits for one before answering.
    private static let grace: Duration = .seconds(3)

    private var waiting: Waiting?
    private var leftApp = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShortcutRunner.shared.leftApp = true }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShortcutRunner.shared.cameBack() }
        }
    }
    #elseif os(macOS)
    private let mac: MacShortcutRunner

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"), timeout: Duration = .seconds(600)) {
        mac = MacShortcutRunner(executable: executable, timeout: timeout)
    }
    #endif

    /// The answer text for one request; failures become `{ok:false, error:{code,message}}` too.
    func perform(_ request: Request) async -> String {
        let name = request.args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var envelope: [String: Any] = ["tool": "run_shortcut", "timestamp": ISO8601DateFormatter().string(from: Date())]
        let outcome: Outcome
        #if os(macOS)
        outcome = await mac.run(request, name: name)
        #elseif os(iOS)
        outcome = await run(id: request.shortcutRequest, name: name, input: request.args.input)
        #endif
        switch outcome {
        case .output(let output):
            envelope["ok"] = true
            envelope["data"] = ["name": name, "output": output]
        case .failure(let code, let message):
            envelope["ok"] = false
            envelope["error"] = ["code": code, "message": message]
        }
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The engine stopped the tool call; nothing reads the answer any more.
    func cancel(_ id: UUID) {
        #if os(macOS)
        mac.cancel(id)
        #elseif os(iOS)
        guard let waiting, waiting.id == id else { return }
        finish(.failure(code: "cancelled", message: "The tool call was cancelled."))
        #endif
    }

    #if os(iOS)
    /// `dshlocal://shortcut-done?id=…&status=success|error|cancel` from the Shortcuts app.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "dshlocal", url.host == "shortcut-done",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard let waiting, value("id").flatMap(UUID.init(uuidString:)) == waiting.id else { return true }
        switch value("status") {
        case "success":
            finish(.output(value("result") ?? ""))
        case "cancel":
            finish(.failure(code: "cancelled", message: "The person stopped the shortcut."))
        default:
            let message = value("errorMessage") ?? value("error") ?? ""
            finish(.failure(code: "shortcut_failed", message: message.isEmpty ? "The shortcut did not run." : message))
        }
        return true
    }

    private func run(id: UUID, name: String, input: String?) async -> Outcome {
        guard !name.isEmpty else { return .failure(code: "invalid_args", message: "Pass name, the shortcut's exact name.") }
        guard let probe = URL(string: "shortcuts://"), UIApplication.shared.canOpenURL(probe) else {
            return .failure(code: "not_available", message: "The Shortcuts app is not installed.")
        }
        guard UIApplication.shared.applicationState == .active else {
            return .failure(code: "not_available", message: "Pallas Agent must be on screen to open the Shortcuts app; ask the person to open it and try again.")
        }
        guard let url = Self.url(id: id, name: name, input: input) else {
            return .failure(code: "invalid_args", message: "The name or input could not be put in a link.")
        }
        if waiting != nil { finish(.failure(code: "cancelled", message: "Another shortcut was started.")) }
        Log.engine.notice("run_shortcut opening Shortcuts")
        return await withCheckedContinuation { continuation in
            leftApp = false
            waiting = Waiting(id: id) { continuation.resume(returning: $0) }
            Task { [weak self] in
                try? await Task.sleep(for: Self.limit)
                guard let self, self.waiting?.id == id else { return }
                self.finish(.failure(code: "timeout", message: "The shortcut did not finish within 10 minutes."))
            }
            UIApplication.shared.open(url) { [weak self] opened in
                MainActor.assumeIsolated {
                    guard !opened, let self, self.waiting?.id == id else { return }
                    self.finish(.failure(code: "not_available", message: "The Shortcuts app did not open."))
                }
            }
        }
    }

    /// Back on screen without the callback: the person switched back before the shortcut finished.
    private func cameBack() {
        guard let id = waiting?.id, leftApp else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard let self, self.waiting?.id == id else { return }
            self.finish(.failure(code: "no_callback", message: "The person came back to Pallas Agent before the shortcut reported back; it may still be running or may have stopped."))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let waiting else { return }
        self.waiting = nil
        Log.engine.notice("run_shortcut finished: \(String(describing: outcome).prefix(12), privacy: .public)")
        waiting.resume(outcome)
    }

    /// `shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=…&x-success=…&x-error=…&x-cancel=…`
    static func url(id: UUID, name: String, input: String?) -> URL? {
        func callback(_ status: String) -> String { "dshlocal://shortcut-done?id=\(id.uuidString)&status=\(status)" }
        var query: [(String, String)] = [("name", name)]
        if let input, !input.isEmpty { query += [("input", "text"), ("text", input)] }
        query += [("x-success", callback("success")), ("x-error", callback("error")), ("x-cancel", callback("cancel"))]
        // Strict: & = + ? / and spaces inside a value would otherwise end it or change it.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var parts: [String] = []
        for (key, value) in query {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            parts.append(key + "=" + encoded)
        }
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + parts.joined(separator: "&"))
    }
    #endif
}
