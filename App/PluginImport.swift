// 插件导入：旧版分享（文件、链接、二维码、粘贴）与离线插件包。
//
// 导入入口在插件页工具栏的「导入」菜单里（HostPluginsScreen）。
// 分享和离线包最终都交给主机的 `pluginManager/installBundle`，与插件市场共用 HostPluginStore 的
// 安装、取消和断线后 `waitForInstall` 找回结果的流程。本机引擎只接受暂存在
// tmp/DSHPluginImport/<uuid> 的已构建目录，所以 ZIP／tgz 由 App 解包后暂存；远程主机通过
// HTTP 连接时 DSH 没有把文件写进主机临时目录的接口，离线包只能在主机上用 CLI 安装。

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

// MARK: - 分享输入

/// Paste, pick a `.dshlocal` file or scan a QR code; then the import page.
struct PluginShareInputSheet: View {
    let host: Harness
    let store: HostPluginStore
    let opened: (String) -> Void
    var initial: PluginShareCode.Found? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var picking = false
    #if os(iOS)
    @State private var scanning = false
    #endif
    @State private var issue: String?
    @State private var plugin: SharedPlugin?
    @State private var resolving = false

    private static let shareTypes: [UTType] = [UTType("io.github.maao514.dshlocal.conversation"), .json, .plainText, .data].compactMap { $0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴分享链接或分享码", text: $text, axis: .vertical).lineLimit(2...5)
                        .noAutomaticCapitalization().autocorrectionDisabled().accessibilityIdentifier("pluginShareText")
                    Button("读取") { handle(text) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolving)
                    if PlatformPasteboard.text != nil {
                        Button("从剪贴板读取") { if let value = PlatformPasteboard.text { text = value; handle(value) } }
                    }
                }
                Section {
                    Button { picking = true } label: { Label("选择分享文件", systemImage: "doc") }
                    #if os(iOS)
                    if DataScannerViewController.isSupported {
                        Button { scanning = true } label: { Label("扫描分享二维码", systemImage: "qrcode.viewfinder") }
                    }
                    #endif
                }
                if resolving { Section { ProgressView("正在查找插件…") } }
                if let issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("pluginShareIssue") } }
            }
            .navigationTitle("分享链接或分享码").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .navigationDestination(item: $plugin) { plugin in
                PluginShareImportView(plugin: plugin, host: host, store: store, opened: opened)
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.shareTypes) { result in
                switch result {
                case .success(let url):
                    do { handle(.code(try PluginShareCode.readFile(url))) } catch { issue = error.localizedDescription }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { issue = String(localized: "没能读取这个文件。") }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanning) {
                PluginShareScanner { value in scanning = false; text = value; handle(value) } cancel: { scanning = false }
            }
            #endif
            .task { if let initial { handle(initial) } }
        }.desktopSheet(width: 550, height: 430)
    }

    private func handle(_ raw: String) {
        guard let found = PluginShareCode.find(raw) else { issue = String(localized: "没有找到插件分享链接或分享码。"); return }
        handle(found)
    }

    private func handle(_ found: PluginShareCode.Found) {
        issue = nil
        switch found {
        case .code(let code):
            do { plugin = try PluginShareCode.decode(code) } catch { issue = error.localizedDescription }
        case .market(let name):
            resolving = true
            Task {
                defer { resolving = false }
                do {
                    let market = try await HostMarketCatalog.fetch()
                    guard let entry = market.plugins.first(where: { $0.name == name }) else { issue = String(localized: "插件市场里没有「\(name)」。"); return }
                    plugin = SharedPlugin(market: entry)
                } catch { issue = String(localized: "没能打开插件市场。") + error.localizedDescription }
            }
        }
    }
}

extension SharedPlugin {
    /// A market entry read as a share, so it goes through the same import page.
    init(market entry: HostMarketPlugin) {
        let git = entry.spec.hasPrefix("git+")
        self.init(name: entry.name, source: git ? (entry.spec.contains("github.com/") ? .github : .git) : .npm, spec: entry.spec,
                  version: entry.version, integrity: nil, title: entry.title, author: entry.author, summary: entry.summary)
    }
}

#if os(iOS)
private struct PluginShareScanner: View {
    let found: (String) -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            QRScanner(found: found).ignoresSafeArea()
                .navigationTitle("扫描分享二维码").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) } }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    final class Delegate: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(_ found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let item) in addedItems {
                if let value = item.payloadStringValue, PluginShareCode.find(value) != nil { scanner.stopScanning(); found(value); break }
            }
        }
    }
    func makeCoordinator() -> Delegate { Delegate(found) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])])
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) { try? scanner.startScanning() }
}
#endif

// MARK: - 导入确认

/// What installing a share would do on the target host.
enum PluginSharePlan: Equatable {
    case install(spec: String)
    case upgrade(from: String, spec: String)
    case enable
    case unchanged
    case blocked(String)

    static func make(_ plugin: SharedPlugin, bundles: [HostPluginBundle], embedded: Bool) -> Self {
        let existing = bundles.first { $0.name == plugin.name }
        if plugin.source == .official {
            guard let existing else { return .blocked(String(localized: "这台设备没有这个官方插件。更新后再试。")) }
            if existing.enabled && (existing.installed || existing.optional) { return .unchanged }
            if existing.isOnDemand, let spec = existing.installSpec { return .install(spec: spec) }
            return existing.switchable ? .enable : .blocked(String(localized: "这台设备的插件由管理员统一管理，这里改不了。"))
        }
        guard let spec = plugin.spec else { return .blocked(String(localized: "这个分享不完整，装不了。请让对方重新分享。")) }
        if let existing, existing.installed || existing.availability == "profile" {
            if let have = existing.version, let want = plugin.version, have == want { return .unchanged }
            if plugin.version == nil, existing.installSpec == spec || existing.source == spec { return .unchanged }
            return .upgrade(from: existing.version ?? "—", spec: spec)
        }
        if embedded, plugin.source != .npm { return .blocked(onlineRefusal) }
        return .install(spec: spec)
    }

    static let onlineRefusal = String(localized: "这个插件不能直接装到手机上。请在电脑上打包，再用「导入」里的「离线插件包」装到手机。")
}

struct PluginShareImportView: View {
    let plugin: SharedPlugin
    let host: Harness
    @ObservedObject var store: HostPluginStore
    let opened: (String) -> Void
    @State private var plan: PluginSharePlan?
    @State private var facts: NpmVersionFacts?
    @State private var issue: String?
    @State private var done = false
    /// A failure the store kept from an earlier attempt elsewhere is not this page's to show.
    @State private var attempted = false
    @State private var confirmingReplace: PluginSharePlan?

    private var targetLabel: String {
        if host.usesEmbeddedEngine { return String(localized: "本机") }
        return host.origin.host.map { $0 + (host.origin.port.map { ":\($0)" } ?? "") } ?? String(localized: "当前设备")
    }

    var body: some View {
        let busy = store.working.contains(plugin.name)
        Form {
            Section {
                HStack(spacing: 14) {
                    Text(String(plugin.displayTitle.prefix(1)).uppercased()).font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .frame(width: 56, height: 56).background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: plugin.displayTitle).font(.title3.weight(.semibold)).lineLimit(2)
                        if let line = plugin.summary ?? plugin.author { Text(verbatim: line).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(3) }
                    }
                }
            }
            Section {
                LabeledContent("版本", value: plugin.versionLabel)
                if let size = facts?.unpackedSize { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                LabeledContent("安装到", value: targetLabel)
                DisclosureGroup("更多信息") {
                    LabeledContent("包名") { Text(verbatim: plugin.name).font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("来源", value: facts?.publisher.map { plugin.source == .npm ? "npm · " + $0 : plugin.sourceLabel } ?? plugin.sourceLabel)
                    if plugin.source == .npm, plugin.integrity != nil { LabeledContent("校验", value: checkLabel) }
                }
            }
            Section {
                switch plan {
                case nil: ProgressView("正在读取已装的插件…")
                case .unchanged?:
                    Label(done ? "已装好" : "已装同一版本", systemImage: "checkmark.circle").foregroundStyle(SettingsStyle.ok)
                    Button("打开插件") { opened(plugin.name) }.accessibilityIdentifier("pluginShareOpen")
                case .blocked(let reason)?:
                    Text(reason).foregroundStyle(ChatColors.muted)
                case let plan?:
                    if busy {
                        HStack { ProgressView(); Text("安装中…"); Spacer(); Button("取消") { Task { await store.cancel(plugin.name) } } }
                    } else {
                        Button(actionLabel(plan)) { run(plan) }.disabled(facts?.check == .mismatch)
                            .accessibilityIdentifier("pluginShareInstall")
                    }
                }
                if attempted, let failure = store.failures[plugin.name] { PluginFailureText(message: failure, detail: store.details[plugin.name]) }
                if let issue { Text(issue).foregroundStyle(.red) }
                if let notice = store.notice, done { Text(notice).font(.callout) }
            } footer: {
                if facts?.check == .mismatch { Text("这个版本的内容和分享时不一样，已停止安装。") }
            }
        }
        .navigationTitle("导入插件").inlineNavigationTitle()
        .confirmationDialog("更新「\(plugin.displayTitle)」？", isPresented: Binding(get: { confirmingReplace != nil }, set: { if !$0 { confirmingReplace = nil } }),
                            titleVisibility: .visible, presenting: confirmingReplace) { plan in
            Button("卸载旧版本并安装") { run(plan, replacing: true) }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("会先卸载旧版本，再安装新版本。插件保存的数据和设置会保留。") }
        .task { await replan() }
        .task { if plugin.source == .npm, plugin.integrity != nil { facts = await NpmVersionFacts.look(plugin) } }
    }

    private var checkLabel: String {
        switch facts?.check {
        case nil: String(localized: "正在校验")
        case .verified?: String(localized: "内容一致")
        case .mismatch?: String(localized: "内容不一致")
        case .unverifiable?: String(localized: "无法校验")
        }
    }

    private func actionLabel(_ plan: PluginSharePlan) -> String {
        switch plan {
        case .install: String(localized: "安装")
        case .upgrade(let from, _): String(localized: "从 \(from) 更新到 \(plugin.versionLabel)")
        case .enable: String(localized: "启用")
        default: ""
        }
    }

    private func replan() async {
        await store.refresh()
        if let bundles = store.bundles { plan = .make(plugin, bundles: bundles, embedded: store.stagesOnlinePackages) }
        else { plan = .blocked(String(localized: "没能读取已装的插件。请稍后重试。")) }
    }

    private func run(_ plan: PluginSharePlan, replacing: Bool = false) {
        if !replacing, case .upgrade(_, let spec) = plan, store.needsReplacing(plugin.name, spec: spec) { confirmingReplace = plan; return }
        issue = nil; attempted = true
        Task {
            switch plan {
            case .install(let spec), .upgrade(_, let spec):
                await store.install(name: plugin.name, title: plugin.displayTitle, spec: spec, registry: nil, replacing: replacing)
            case .enable:
                if let bundle = store.bundle(named: plugin.name) { await store.setEnabled(bundle, true) }
            default: return
            }
            done = store.failures[plugin.name] == nil
            await replan()
            if done, self.plan != .unchanged { issue = String(localized: "还没确认装好，请稍后刷新插件列表。") }
        }
    }
}

// MARK: - 离线插件包

/// Unpack, show what the package is, then hand the staged folder to the host's plugin manager.
struct PluginArchiveImportSheet: View {
    let host: Harness
    @ObservedObject var store: HostPluginStore
    let opened: (String) -> Void
    /// A package opened from the Files app: unpacked as soon as the sheet appears.
    var initial: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var staged: StagedPackage?
    @State private var working = false
    @State private var issue: String?
    @State private var result: String?
    @State private var installed: String?
    #if os(macOS)
    @State private var confirmingUpdate = false
    #endif

    struct StagedPackage: Equatable {
        let folder: URL
        let name: String
        let version: String?
        let title: String?
        let file: String
    }

    private static let archiveTypes: [UTType] = [.zip, .gzip, UTType(filenameExtension: "tgz"), UTType(filenameExtension: "tar"), .data].compactMap { $0 }
    private var embedded: Bool { host.usesEmbeddedEngine }

    var body: some View {
        NavigationStack {
            Form {
                if !embedded {
                    Section { Text("离线插件包只能装到本机。先切换到本机，再来导入。") }
                } else if let staged {
                    Section {
                        LabeledContent("插件", value: staged.title ?? staged.name)
                        LabeledContent("版本", value: staged.version ?? "—")
                        LabeledContent("文件", value: staged.file)
                        LabeledContent("安装到", value: String(localized: "本机"))
                    }
                    Section {
                        if working { ProgressView("正在导入…") }
                        else if let installed { Button("打开插件") { opened(installed) }.accessibilityIdentifier("pluginArchiveOpen") }
                        else {
                            #if os(macOS)
                            if store.needsReplacing(staged.name) {
                                Button("更新") { confirmingUpdate = true }.accessibilityIdentifier("pluginArchiveInstall")
                            } else {
                                Button("导入并启用") { install(staged) }.accessibilityIdentifier("pluginArchiveInstall")
                            }
                            #else
                            Button("导入并启用") { install(staged) }.accessibilityIdentifier("pluginArchiveInstall")
                            #endif
                        }
                    }
                } else {
                    Section {
                        Button { picking = true } label: { Label("选择插件包文件", systemImage: "doc.zipper") }.disabled(working)
                        if working { ProgressView("正在解包…") }
                    }
                }
                if let result { Section { Text(result).accessibilityIdentifier("pluginArchiveResult") } }
                if let issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("pluginArchiveIssue") } }
            }
            .navigationTitle("离线插件包").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(working) } }
            #if os(macOS)
            .confirmationDialog("更新「\(staged?.title ?? staged?.name ?? "")」？", isPresented: $confirmingUpdate,
                                titleVisibility: .visible, presenting: staged) { package in
                Button("卸载旧版本并安装") { install(package, replacing: true) }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("会先卸载旧版本，再安装新版本。插件保存的数据和设置会保留。") }
            .task { if embedded, store.bundles == nil { await store.refresh() } }
            #endif
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.archiveTypes) { picked in
                switch picked {
                case .success(let url): unpack(url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { issue = String(localized: "没能读取这个文件。") }
                }
            }
            .onDisappear { if let staged { try? FileManager.default.removeItem(at: staged.folder) } }
            .task { if let initial, embedded, staged == nil, !working { unpack(initial) } }
        }.desktopSheet(width: 540, height: 395).interactiveDismissDisabled(working)
    }

    private func unpack(_ url: URL) {
        working = true; issue = nil; result = nil
        Task {
            defer { working = false }
            do { staged = try await Task.detached(priority: .userInitiated) { try Self.stage(url) }.value }
            catch { issue = error.localizedDescription }
        }
    }

    /// Unpacks into a scratch folder, then moves the package root to `tmp/DSHPluginImport/<uuid>`,
    /// the only place the on-device plugin manager installs from.
    nonisolated static func stage(_ archive: URL) throws -> StagedPackage {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("DSHPluginUnpack", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let root = try PluginArchive.unpack(archive, into: work)
        let package = try describe(root, file: archive.lastPathComponent)
        let inbox = fm.temporaryDirectory.appendingPathComponent("DSHPluginImport", isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.moveItem(at: root, to: folder)
        return StagedPackage(folder: folder, name: package.name, version: package.version, title: package.title, file: package.file)
    }

    nonisolated static func describe(_ folder: URL, file: String) throws -> StagedPackage {
        let manifest = try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("package.json"))) as? Object
        guard let manifest, let name = manifest["name"] as? String, !name.isEmpty else { throw HostError(String(localized: "这个文件不是插件包。")) }
        guard (manifest["dsh"] as? Object)?["bundle"] is Object else { throw HostError(String(localized: "「\(name)」不是 Pallas Agent 能用的插件。")) }
        return StagedPackage(folder: folder, name: name, version: manifest["version"] as? String,
                             title: HostPanelFormat.localized((manifest["dsh"] as? Object)?["title"]), file: file)
    }

    private func install(_ package: StagedPackage, replacing: Bool = false) {
        working = true; issue = nil
        Task {
            defer { working = false }
            await store.install(name: package.name, title: package.title ?? package.name, spec: package.folder.path,
                                registry: nil, replacing: replacing)
            try? FileManager.default.removeItem(at: package.folder)
            if let failure = store.failures[package.name] { issue = failure; staged = nil; return }
            result = store.notice
            if store.bundle(named: package.name)?.installed == true { installed = package.name }
            else { issue = String(localized: "还没确认装好，请稍后刷新插件列表。") }
        }
    }
}

// MARK: - 从链接或文件打开

/// A plugin share the app was opened with (`dshlocal://share/plugin?p=`, a market link or a plugin `.dshlocal` file).
struct PluginShareRequest: Identifiable {
    let id = UUID()
    let found: PluginShareCode.Found

    /// The request `url` makes, or nil when it is not a plugin share (conversation shares keep their own route).
    static func make(_ url: URL) -> Self? {
        if url.isFileURL {
            guard PluginShareCode.isPluginFile(url), let code = try? PluginShareCode.readFile(url) else { return nil }
            return Self(found: .code(code))
        }
        return PluginShareCode.link(url).map { Self(found: $0) }
    }
}

/// A ZIP, tgz or tar opened from the Files app with Pallas Agent: an offline plugin package.
struct PluginArchiveRequest: Identifiable {
    let id = UUID()
    let file: URL

    static func make(_ url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        let name = url.lastPathComponent.lowercased()
        return [".zip", ".tgz", ".tar.gz", ".tar"].contains(where: name.hasSuffix) ? Self(file: url) : nil
    }
}

/// The offline package sheet for a file opened from outside. Packages install only on this phone.
struct PluginArchiveEntrySheet: View {
    let host: Harness?
    let request: PluginArchiveRequest
    let opened: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let host {
            PluginArchiveEntryHost(host: host, request: request, opened: opened)
        } else {
            NavigationStack {
                OfflineMessage(symbol: "puzzlepiece.extension", title: String(localized: "未连接"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            }
        }
    }
}

private struct PluginArchiveEntryHost: View {
    let host: Harness
    let request: PluginArchiveRequest
    let opened: (String) -> Void
    @StateObject private var store: HostPluginStore

    init(host: Harness, request: PluginArchiveRequest, opened: @escaping (String) -> Void) {
        self.host = host; self.request = request; self.opened = opened
        _store = StateObject(wrappedValue: HostPluginStore(host: host))
    }

    var body: some View { PluginArchiveImportSheet(host: host, store: store, opened: opened, initial: request.file) }
}

/// The import sheet for a link or file opened from outside, aimed at the host the chat is using.
struct PluginShareEntrySheet: View {
    let host: Harness?
    let request: PluginShareRequest
    let opened: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let host {
            PluginShareEntryHost(host: host, request: request, opened: opened)
        } else {
            NavigationStack {
                OfflineMessage(symbol: "puzzlepiece.extension", title: String(localized: "未连接"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            }
        }
    }
}

private struct PluginShareEntryHost: View {
    let host: Harness
    let request: PluginShareRequest
    let opened: (String) -> Void
    @StateObject private var store: HostPluginStore

    init(host: Harness, request: PluginShareRequest, opened: @escaping (String) -> Void) {
        self.host = host; self.request = request; self.opened = opened
        _store = StateObject(wrappedValue: HostPluginStore(host: host))
    }

    var body: some View { PluginShareInputSheet(host: host, store: store, opened: opened, initial: request.found) }
}
