import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import Combine
#else
import BackgroundTasks
import UIKit
#endif

/// The Harness's USER.md and MEMORY.md. The model's memory tool and the settings page edit the
/// same entries, separated by 「§」. Both count Unicode code points.
struct MemoryFiles {
    let directory: URL

    init(home: URL) {
        directory = home.appending(path: "memories", directoryHint: .isDirectory)
    }

    #if os(iOS)
    static let phone = MemoryFiles(home: URL.applicationSupportDirectory.appending(path: "DSH", directoryHint: .isDirectory))
    #endif

    enum Target: String, CaseIterable, Identifiable {
        case user, memory
        var id: String { rawValue }
        var file: String { self == .user ? "USER.md" : "MEMORY.md" }
        var limit: Int { self == .user ? 1375 : 2200 }
        var title: String { self == .user ? String(localized: "关于你") : String(localized: "笔记") }
    }

    struct Entry: Identifiable, Equatable {
        /// The line as stored, date included.
        let raw: String
        let index: Int
        var id: String { "\(index):\(raw)" }
        var text: String {
            raw.replacingOccurrences(of: #"^\[\d{4}-\d{2}-\d{2}\]\s*"#, with: "", options: .regularExpression)
        }
    }

    static let separator = "\n§\n"

    private func rawEntries(_ target: Target) throws -> [String] {
        let url = directory.appending(path: target.file)
        do {
            return Self.parse(try String(contentsOf: url, encoding: .utf8))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
    }

    static func parse(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n[ \t]*§[ \t]*\n"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "§" }
    }

    func entries(_ target: Target) -> [Entry] {
        (try? rawEntries(target))?.enumerated().map { Entry(raw: $0.element, index: $0.offset) } ?? []
    }

    static func used(_ raws: [String]) -> Int { raws.joined(separator: separator).unicodeScalars.count }

    static func today() -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }

    /// Only edit the entry shown by the editor. The model can update the file while it is open.
    func save(_ target: Target, replacing entry: Entry?, with text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var raws = try rawEntries(target)
        if !trimmed.isEmpty {
            if trimmed.contains("§") { throw HostError(String(localized: "请去掉「§」这个符号再保存")) }
            if trimmed.unicodeScalars.contains(where: Self.invisible) { throw HostError(String(localized: "内容里有看不见的特殊字符，请删掉后重新输入")) }
        }
        let line = "[\(Self.today())] \(trimmed)"
        if let entry {
            guard raws.indices.contains(entry.index), raws[entry.index] == entry.raw else {
                throw HostError(String(localized: "记忆已改动，请重新打开后再编辑。"))
            }
            if trimmed.isEmpty { raws.remove(at: entry.index) }
            else { raws[entry.index] = line }
        } else {
            guard !trimmed.isEmpty else { return }
            raws.append(line)
        }
        let count = Self.used(raws)
        if !trimmed.isEmpty && count > target.limit { throw HostError(String(localized: "超出上限 \(count - target.limit) 字")) }
        let content = raws.isEmpty ? "" : raws.joined(separator: Self.separator) + "\n"
        try write(Data(content.utf8), name: target.file)
    }

    private func write(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: name)
        #if os(macOS)
        try data.write(to: url, options: .atomic)
        #else
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    private static func invisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF, 0xFFF9...0xFFFB, 0xE0000...0xE007F: true
        default: false
        }
    }

    // MARK: settings.json — read by the engine on every step

    struct Settings: Codable, Equatable {
        var enabled = true
        var autoDream = true
    }

    func settings() -> Settings {
        guard let data = try? Data(contentsOf: directory.appending(path: "settings.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Settings() }
        return Settings(enabled: object["enabled"] as? Bool ?? true, autoDream: object["autoDream"] as? Bool ?? true)
    }

    func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try write(encoder.encode(settings), name: "settings.json")
    }
}

/// 记忆: the switch, then what the model keeps about the person and its own notes, each editable.
struct MemoryPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: MemoryFiles.Settings
    @State private var entries: [MemoryFiles.Target: [MemoryFiles.Entry]] = [:]
    @State private var editing: MemoryEdit?
    @State private var dreamState = MemoryDream.State()
    @State private var confirmRestore = false
    @State private var editIssue: String?
    @ObservedObject private var dream: MemoryDream
    private var files: MemoryFiles { dream.files }

    init(dream: MemoryDream) {
        self.dream = dream
        _settings = State(initialValue: dream.files.settings())
    }

    #if os(iOS)
    init() { self.init(dream: .shared) }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCard {
                    SettingsToggleRow(symbol: "brain", title: String(localized: "记忆"),
                                      isOn: Binding(get: { settings.enabled }, set: { changeSetting(\.enabled, to: $0) }))
                        .padding(.horizontal, 16).accessibilityIdentifier("memoryEnabled")
                    if settings.enabled {
                        SettingsDivider()
                        SettingsToggleRow(symbol: "moon.stars", title: String(localized: "每天根据对话自动更新"),
                                          isOn: Binding(get: { settings.autoDream }, set: { changeSetting(\.autoDream, to: $0) }))
                            .padding(.horizontal, 16).accessibilityIdentifier("memoryAutoDream")
                        SettingsDivider()
                        Button { run("now") } label: {
                            HStack {
                                SettingsRowLabel(symbol: "sparkles", title: String(localized: "现在更新一次"),
                                                 value: dream.running ? nil : lastRunText, chevron: false)
                                if dream.running { ProgressView() }
                            }.padding(.horizontal, 16)
                        }.buttonStyle(SettingsRowStyle()).disabled(dream.running).accessibilityIdentifier("memoryDreamNow")
                        if dreamState.hasBackup {
                            SettingsDivider()
                            Button { confirmRestore = true } label: {
                                SettingsRowLabel(symbol: "arrow.uturn.backward", title: String(localized: "恢复上一版"), chevron: false)
                                    .padding(.horizontal, 16)
                            }.buttonStyle(SettingsRowStyle()).disabled(dream.running).accessibilityIdentifier("memoryRestore")
                        }
                    }
                    if let issue = editIssue ?? dream.issue {
                        Text(issue).font(.subheadline).foregroundStyle(.red).padding(.horizontal, 16).padding(.vertical, 10)
                            .accessibilityIdentifier("memoryDreamIssue")
                    }
                }
                ForEach(MemoryFiles.Target.allCases) { target in
                    section(target)
                }
            }.padding(16)
        }
        .settingsPage(String(localized: "记忆"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        .onChange(of: dream.running) { _, running in if !running { reload() } }
        .sheet(item: $editing, onDismiss: reload) { edit in MemoryEntryEditor(files: files, edit: edit) }
        .confirmationDialog(String(localized: "恢复到上次更新之前？"), isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复上一版", role: .destructive) { run("restore") }.accessibilityIdentifier("memoryRestoreConfirm")
        }
    }

    private var lastRunText: String {
        guard let last = dreamState.lastRunAt else { return String(localized: "从未更新") }
        return last.formatted(.relative(presentation: .named))
    }

    private func run(_ mode: String) {
        editIssue = nil
        dream.issue = nil
        Task {
            let reply = await dream.request(mode)
            switch (reply["status"], reply["reason"]) {
            case ("done", _), ("restored", _): dream.issue = nil
            case (_, "busy"?): dream.issue = String(localized: "有对话正在进行，稍后再试")
            case (_, "engine_not_running"?):
                #if os(macOS)
                dream.issue = String(localized: "本机引擎未运行")
                #else
                dream.issue = String(localized: "本机没有在运行。到设置的「高级」里打开「本机运行」。")
                #endif
            case (_, "memory_changed"?): dream.issue = String(localized: "记忆已改动，请重新打开后再编辑。")
            case (_, "already_running"?), (_, "memory_off"?): break
            default: dream.issue = String(localized: "没能更新，记忆没有改动")
            }
            reload()
        }
    }

    private func section(_ target: MemoryFiles.Target) -> some View {
        let rows = entries[target] ?? []
        let used = MemoryFiles.used(rows.map(\.raw))
        return SettingsCard(title: target.title + "  \(used)/\(target.limit)") {
            ForEach(rows) { entry in
                Button { editing = MemoryEdit(target: target, entry: entry) } label: {
                    Text(entry.text).foregroundStyle(ChatColors.ink).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight - 16, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(SettingsRowStyle())
                    .contextMenu {
                        Button(role: .destructive) { remove(target, entry) } label: { Label("删除", systemImage: "trash") }
                    }
                    .accessibilityIdentifier("memoryEntry-\(target.rawValue)-\(entry.index)")
                SettingsDivider(inset: 16)
            }
            Button { editing = MemoryEdit(target: target, entry: nil) } label: {
                SettingsRowLabel(symbol: "plus", title: String(localized: "添加"), chevron: false, tinted: false).padding(.horizontal, 16)
            }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("memoryAdd-\(target.rawValue)")
        }
    }

    private func remove(_ target: MemoryFiles.Target, _ entry: MemoryFiles.Entry) {
        do {
            try files.save(target, replacing: entry, with: "")
            editIssue = nil
        } catch {
            editIssue = (error as? HostError)?.message ?? String(localized: "无法保存")
        }
        reload()
    }

    private func changeSetting(_ key: WritableKeyPath<MemoryFiles.Settings, Bool>, to value: Bool) {
        var changed = files.settings()
        changed[keyPath: key] = value
        do {
            try files.save(changed)
            settings = changed
            editIssue = nil
            dream.issue = nil
            dream.schedule()
        } catch { editIssue = String(localized: "无法保存") }
    }

    private func reload() {
        settings = files.settings()
        dreamState = dream.state()
        for target in MemoryFiles.Target.allCases { entries[target] = files.entries(target) }
    }
}

struct MemoryEdit: Identifiable {
    let target: MemoryFiles.Target
    let entry: MemoryFiles.Entry?
    var id: String { target.rawValue + (entry?.id ?? "+") }
}

private struct MemoryEntryEditor: View {
    let files: MemoryFiles
    let edit: MemoryEdit
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $draft).frame(minHeight: 120).accessibilityIdentifier("memoryDraft")
                if let issue { Text(issue).foregroundStyle(.red) }
                if edit.entry != nil {
                    Button("删除", role: .destructive) { save("") }.accessibilityIdentifier("memoryDelete")
                }
            }
            .navigationTitle(edit.target.title).inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(draft) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("memorySave")
                }
            }
        }
        .desktopSheet(width: 440, height: 285)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear { draft = edit.entry?.text ?? "" }
    }

    private func save(_ text: String) {
        do {
            try files.save(edit.target, replacing: edit.entry, with: text)
            dismiss()
        } catch {
            issue = (error as? HostError)?.message ?? String(localized: "无法保存")
        }
    }
}

/// Drives the local Harness's review and restore commands. The platforms schedule automatic
/// reviews with their own app lifecycles.
@MainActor
final class MemoryDream: ObservableObject {
    #if os(iOS)
    static let shared = MemoryDream(files: .phone) { id, mode in
        EmbeddedEngine.shared.memoryDream(id, mode: mode)
    }
    #endif

    let files: MemoryFiles
    private let send: (String, String) -> Bool
    @Published private(set) var running = false
    @Published var issue: String?

    private struct Pending {
        let id: String
        let mode: String
        let reply: CheckedContinuation<[String: String], Never>
        let timeout: Task<Void, Never>
    }
    private var pending: Pending?
    static let leavingGap: TimeInterval = 3600

    #if os(macOS)
    private var engineRunning = false
    private var automaticCheck: Task<Void, Never>?
    private var inactivityObserver: AnyCancellable?
    #else
    private var observers: [NSObjectProtocol] = []
    private var registered = false
    private var watchingActive = false
    private var taskExpired = false
    private var currentTask: BGTask?
    private var leaving = UIBackgroundTaskIdentifier.invalid
    static var taskIdentifier: String { (Bundle.main.bundleIdentifier ?? "dsh") + ".memory.dream" }
    /// The app-open fallback looks again after this long.
    static let foregroundGap: TimeInterval = 6 * 3600
    #endif

    init(files: MemoryFiles, send: @escaping (String, String) -> Bool) {
        self.files = files
        self.send = send
    }

    struct State {
        var lastRunAt: Date?
        var lastChecked: Date?
        var hasBackup = false
    }

    func state() -> State {
        let object = (try? Data(contentsOf: files.directory.appending(path: "state.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func date(_ key: String) -> Date? { (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        var checks = ["lastRunAt", "lastCheckAt", "lastFailedAt"].compactMap(date)
        #if os(iOS)
        if let initial = date("since") { checks.append(initial) }
        #endif
        let backup = files.directory.appending(path: "backup", directoryHint: .isDirectory)
        let hasBackup = MemoryFiles.Target.allCases.allSatisfy {
            FileManager.default.fileExists(atPath: backup.appending(path: $0.file).path)
        }
        return State(lastRunAt: date("lastRunAt"), lastChecked: checks.max(), hasBackup: hasBackup)
    }

    #if os(macOS)
    func engineReady() {
        guard !engineRunning else { return }
        engineRunning = true
        inactivityObserver = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification).sink { [weak self] _ in
            Task { @MainActor in await self?.considerAutomaticPass() }
        }
        schedule()
    }

    func engineStopped() {
        engineRunning = false
        inactivityObserver = nil
        automaticCheck?.cancel()
        automaticCheck = nil
        if let pending { finish(pending.id, ["status": "failed", "reason": "engine_not_running"]) }
    }

    func schedule() {
        automaticCheck?.cancel()
        automaticCheck = nil
        let settings = files.settings()
        if !settings.enabled { cancelRequest(reason: "memory_off") }
        else if !settings.autoDream && pending?.mode == "auto" { cancelRequest(reason: "auto_off") }
        guard engineRunning, settings.enabled, settings.autoDream else { return }
        // The engine remains available when the chat window closes. Check while idle on the same
        // cadence as iOS background work, in addition to checking when the app loses focus.
        automaticCheck = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
                while !Task.isCancelled, self != nil {
                    await self?.considerAutomaticPass()
                    try await Task.sleep(for: .seconds(Self.leavingGap))
                }
            } catch {}
        }
    }

    private func considerAutomaticPass() async {
        guard engineRunning, !running else { return }
        let settings = files.settings()
        guard settings.enabled, settings.autoDream else { return }
        if let last = state().lastChecked, Date().timeIntervalSince(last) < Self.leavingGap { return }
        _ = await request("auto")
    }
    #else
    private var automatic: Bool {
        let settings = files.settings()
        return settings.enabled && settings.autoDream && EmbeddedEngine.enabled
    }

    /// At launch, before the app finishes launching, as BGTaskScheduler requires.
    func registerBackgroundTask() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated { MemoryDream.shared.runBackgroundTask(task) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MemoryDream.shared.appLeft() }
        })
        schedule()
    }

    /// Submits the next background request, or cancels it when memory or 自动整理 is off.
    func schedule() {
        guard registered else { return }
        guard automatic else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { Log.engine.error("memory task not submitted: \(error.localizedDescription, privacy: .public)") }
    }

    private func runBackgroundTask(_ task: BGTask) {
        taskExpired = false
        currentTask = task
        // iOS calls this on a queue of its own, not the main one.
        task.expirationHandler = { Task { @MainActor in MemoryDream.shared.taskExpired = true; MemoryDream.shared.abort() } }
        Log.engine.notice("memory task started")
        Task {
            var success = false
            if automatic, !running {
                if (try? await EmbeddedEngine.shared.start()) != nil, !taskExpired {
                    let reply = await request("auto")
                    success = reply["status"] == "done" || reply["status"] == "skipped"
                }
            } else { success = true }
            Log.engine.notice("memory task ended, expired \(self.taskExpired, privacy: .public)")
            schedule()
            task.setTaskCompleted(success: success && !taskExpired)
            if currentTask === task { currentTask = nil }
        }
    }

    /// Leaving the app: a pass in the background time UIKit grants, if there is anything new.
    private func appLeft() {
        schedule()
        #if DEBUG
        // Device tests: `-memoryTaskSimulation launch` has iOS start the background task now, through
        // the private call the debugger's `_simulateLaunchForTaskWithIdentifier:` makes. `expire` also
        // runs the task's expiration handler one second later, while the model is still answering.
        // (iOS's own simulated expiry freezes the app at once, before the handler can show anything.)
        if let simulation = UserDefaults.standard.string(forKey: "memoryTaskSimulation"), registered {
            let scheduler = BGTaskScheduler.shared as NSObject
            scheduler.perform(NSSelectorFromString("_simulateLaunchForTaskWithIdentifier:"), with: Self.taskIdentifier)
            Log.engine.notice("memory task simulated: \(simulation, privacy: .public)")
            if simulation == "expire" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    Log.engine.notice("memory task expiring (simulated)")
                    MemoryDream.shared.currentTask?.expirationHandler?()
                }
            }
            return
        }
        #endif
        guard automatic, !running, leaving == .invalid, EmbeddedEngine.shared.endpoint != nil else { return }
        if let last = state().lastRunAt, Date().timeIntervalSince(last) < Self.leavingGap { return }
        leaving = UIApplication.shared.beginBackgroundTask(withName: "Memory") {
            MainActor.assumeIsolated { MemoryDream.shared.abort() }
        }
        Task {
            _ = await request("auto")
            UIApplication.shared.endBackgroundTask(leaving)
            leaving = .invalid
        }
    }

    /// iOS is taking the time back: the engine stops its model call, and this side stops waiting.
    func abort() {
        guard pending != nil else { return }
        cancelRequest(reason: "expired")
        if leaving != .invalid { UIApplication.shared.endBackgroundTask(leaving); leaving = .invalid }
    }

    /// The engine is listening: from now on, coming to the front may start a pass.
    func engineReady() {
        if !watchingActive {
            watchingActive = true
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MemoryDream.shared.considerAutomaticPass() }
            })
        }
        // The engine has one thread, and the chat is connecting on it right now: wait a little first.
        Task {
            try? await Task.sleep(for: .seconds(20))
            considerAutomaticPass()
        }
    }

    func considerAutomaticPass() {
        guard automatic, !running, UIApplication.shared.applicationState == .active else { return }
        if let last = state().lastChecked, Date().timeIntervalSince(last) < Self.foregroundGap { return }
        Task { _ = await request("auto") }
    }
    #endif

    /// Runs one engine command and waits for its answer (status, reason).
    func request(_ mode: String) async -> [String: String] {
        guard !running else { return ["status": "skipped", "reason": "already_running"] }
        running = true
        let id = UUID().uuidString
        defer { running = false }
        let reply = await withCheckedContinuation { continuation in
            guard send(id, mode) else {
                continuation.resume(returning: ["status": "failed", "reason": "engine_not_running"])
                return
            }
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(200)) } catch { return }
                guard let self, self.pending?.id == id else { return }
                self.cancelRequest(reason: "timeout")
            }
            pending = Pending(id: id, mode: mode, reply: continuation, timeout: timeout)
        }
        Log.engine.notice("memory \(mode, privacy: .public): \(reply["status"] ?? "-", privacy: .public) \(reply["reason"] ?? "", privacy: .public)")
        return reply
    }

    func finish(_ id: String, _ reply: [String: String]) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.timeout.cancel()
        pending.reply.resume(returning: reply)
    }

    private func cancelRequest(reason: String) {
        guard let id = pending?.id else { return }
        _ = send(UUID().uuidString, "abort")
        finish(id, ["status": "failed", "reason": reason])
    }
}
