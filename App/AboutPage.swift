// 设置 › 帮助与关于 › 关于：版本、检查更新、本项目（Pallas Agent，Apache-2.0）。
// 检查更新只读本项目在 GitHub 上的 Release；分发方式是自己安装，这里只跳到 Release 页。

import Observation
import SwiftUI

/// Asks GitHub for the project's latest release and compares it with this build.
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let dailyKey = "updateDailyCheck"
    private static let lastKey = "updateLastChecked"
    private static let newerKey = "updateNewerVersion"
    private static let newerPageKey = "updateNewerPage"

    enum Outcome: Equatable {
        case upToDate(String)
        case newer(String, URL)
        /// The repository has no release yet (GitHub answers 404).
        case noRelease
        case failed(String)
    }

    private(set) var checking = false
    private(set) var outcome: Outcome?
    private(set) var lastChecked: Date?
    /// A newer release seen by the last check, kept across launches for the hub row.
    private(set) var newer: (version: String, page: URL)?

    private init() {
        let defaults = UserDefaults.standard
        lastChecked = defaults.object(forKey: Self.lastKey) as? Date
        if let version = defaults.string(forKey: Self.newerKey), let page = defaults.url(forKey: Self.newerPageKey),
           Self.compare(version, AppVersion.marketing) == .orderedDescending {
            newer = (version, page)
        }
    }

    static var dailyEnabled: Bool { UserDefaults.standard.object(forKey: dailyKey) as? Bool != false }

    static var feed: URL {
        #if DEBUG
        // Tests point this at another source: `-DSHUpdateFeed <url>` (a data: URL works).
        if let raw = UserDefaults.standard.string(forKey: "DSHUpdateFeed"), let url = URL(string: raw) { return url }
        #endif
        return URL(string: ProjectLinks.api + "/releases/latest")!
    }

    private static var interval: TimeInterval {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "DSHUpdateInterval"), let seconds = TimeInterval(raw) { return seconds }
        #endif
        return 24 * 3600
    }

    /// At launch and back in front: once a day while 每日自动检查 is on.
    func checkDailyIfDue() async {
        guard Self.dailyEnabled, !checking else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        Log.connection.notice("daily update check")
        await check()
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let result = await Self.fetch(Self.feed)
        outcome = result
        lastChecked = Date()
        let defaults = UserDefaults.standard
        defaults.set(lastChecked, forKey: Self.lastKey)
        switch result {
        case .newer(let version, let page):
            newer = (version, page)
            defaults.set(version, forKey: Self.newerKey)
            defaults.set(page, forKey: Self.newerPageKey)
        case .upToDate, .noRelease:
            newer = nil
            defaults.removeObject(forKey: Self.newerKey)
            defaults.removeObject(forKey: Self.newerPageKey)
        case .failed(let why):
            Log.connection.error("update check failed: \(why, privacy: .public)")
        }
    }

    static func fetch(_ url: URL) async -> Outcome {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { return .failed(describe(error)) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { return .noRelease }
        if status == 403 || status == 429 { return .failed(String(localized: "GitHub 暂时限制了查询，过一会儿再试")) }
        guard status == 200 else { return .failed(String(localized: "暂时检查不了更新，过一会儿再试")) }
        return outcome(of: data, current: AppVersion.marketing)
    }

    /// `releases/latest` → where this build stands.
    static func outcome(of data: Data, current: String) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = (root["tag_name"] as? String)?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else {
            return .failed(String(localized: "暂时检查不了更新，过一会儿再试"))
        }
        let version = normalized(tag)
        guard compare(version, current) == .orderedDescending else { return .upToDate(version) }
        let page = (root["html_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } ?? ProjectLinks.releases
        return .newer(version, page)
    }

    /// `v0.2.0` → `0.2.0`.
    static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Dotted numbers compared one by one; a missing part counts as 0, `1.2.0-beta` as `1.2.0`.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ text: String) -> [Int] {
            let core = normalized(text).prefix { $0.isNumber || $0 == "." }
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0, r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func describe(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?: return String(localized: "没有网络连接")
        case .timedOut?: return String(localized: "连接 GitHub 超时")
        case .cannotFindHost?, .cannotConnectToHost?, .dnsLookupFailed?: return String(localized: "连不上 GitHub")
        default: return String(localized: "没能检查：") + ShareText.redacted(error.localizedDescription)
        }
    }
}

/// 关于: version and updates, and this project.
struct AboutSettingsPage: View {
    @AppStorage(UpdateChecker.dailyKey) private var daily = true
    private var updates: UpdateChecker { UpdateChecker.shared }

    var body: some View {
        SettingsList {
            Section {
                SettingsRowLabel(title: String(localized: "版本"), value: AppVersion.label, chevron: false)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("aboutVersion")
                if let newer = updates.newer {
                    Link(destination: newer.page) {
                        SettingsRowLabel(title: String(localized: "有新版本 ") + newer.version, valueColor: Color.accentColor, chevron: false)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(Color.accentColor)
                            }
                    }.accessibilityIdentifier("aboutNewRelease")
                }
                updateRow
                Toggle("每日自动检查", isOn: $daily).accessibilityIdentifier("aboutDailyCheck")
                if let last = updates.lastChecked {
                    LabeledContent("上次检查", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }.listRowBackground(ChatColors.chip)

            Section("本项目") {
                Link(destination: ProjectLinks.repository) {
                    LabeledContent("源代码", value: ProjectLinks.slug)
                }.accessibilityIdentifier("aboutRepository")
                Link(destination: ProjectLinks.componentSources) {
                    LabeledContent("开源组件源代码", value: ProjectLinks.componentSlug)
                }.accessibilityIdentifier("aboutComponentSources")
                NavigationLink("第三方许可") { ThirdPartyLicensesPage() }.accessibilityIdentifier("aboutLicenses")
                Text("基于 DeepSeek Harness 构建 · 非 DeepSeek 官方应用")
            }.listRowBackground(ChatColors.chip)
        }
        .settingsPage(String(localized: "关于"))
    }

    private var updateRow: some View {
        Button { Task { await updates.check() } } label: {
            HStack {
                SettingsRowLabel(title: String(localized: "检查更新"), value: updates.checking ? nil : updateValue.text,
                                 valueColor: updateValue.color, chevron: false)
                if updates.checking { ProgressView() }
            }
        }.buttonStyle(.plain).disabled(updates.checking).accessibilityIdentifier("aboutCheckUpdate")
            .accessibilityValue(updates.checking ? String(localized: "正在检查") : updateValue.text ?? "")
    }

    private var updateValue: (text: String?, color: Color?) {
        switch updates.outcome {
        case .upToDate?: (String(localized: "已是最新"), SettingsStyle.ok)
        case .noRelease?: (String(localized: "还没有发布"), nil)
        case .failed(let why)?: (why, SettingsStyle.warning)
        case .newer?, nil: (nil, nil)
        }
    }
}

struct ThirdPartyLicensesPage: View {
    /// Split at blank lines so the lazy stack only lays out what is on screen: the file is thousands of lines.
    private static let paragraphs = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { $0.components(separatedBy: "\n\n") }

    var body: some View {
        ScrollView {
            if let paragraphs = Self.paragraphs {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Link(destination: ProjectLinks.componentSources) {
                        LabeledContent("开源组件源代码", value: ProjectLinks.componentSlug)
                    }.accessibilityIdentifier("licensesComponentSources")
                    ForEach(paragraphs.indices, id: \.self) { index in
                        Text(verbatim: paragraphs[index]).font(.caption).textSelection(.enabled)
                    }
                }.accessibilityIdentifier("thirdPartyLicenseText").padding()
            } else {
                Text("没能读取这个文件").foregroundStyle(.red).padding()
            }
        }.background(ChatColors.canvas.ignoresSafeArea()).foregroundStyle(ChatColors.ink).navigationTitle("第三方许可")
    }
}
