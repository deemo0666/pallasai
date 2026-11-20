import SwiftUI
import UniformTypeIdentifiers

struct PrivacySettingsPage: View {
    @ObservedObject private var sharedLinks = HostedLibrary.shared
    @AppStorage(ConversationIndex.searchableKey) private var searchable = ConversationIndex.searchableByDefault
    var host: Harness? = nil
    var hostLabel: String? = nil

    var body: some View {
        SettingsList {
            Section("分享") {
                NavigationLink { SharedLinksView() } label: {
                    SettingsRowLabel(title: String(localized: "我的分享链接"),
                                     value: "\(sharedLinks.entries.filter { $0.removalDeadline == nil }.count)", chevron: false)
                }.accessibilityIdentifier("settingsSharedLinks")
            }.listRowBackground(ChatColors.chip)
            Section("搜索") {
                Toggle("在搜索中显示对话", isOn: Binding(get: { searchable }, set: {
                    searchable = $0
                    ConversationIndex.shared.setSearchable($0)
                })).accessibilityIdentifier("settingsSpotlightConversations")
            }.listRowBackground(ChatColors.chip)
            PrivacyHostSections(host: host, hostLabel: hostLabel)
        }.settingsPage(String(localized: "隐私与分享"))
    }
}

// The parts of 隐私与分享 that depend on the host: 分享配置 / 导入配置 / 恢复点,
// 使用统计 (none), and 对话日志 when the host serves `session-log-deepseek`.

struct PrivacyHostSections: View {
    let host: Harness?
    var hostLabel: String?
    @State private var restoreCount = ProfileRestorePoint.all().count

    var body: some View {
        Section {
            NavigationLink { ProfileExportPage(host: host, hostLabel: hostLabel) } label: {
                SettingsRowLabel(title: String(localized: "分享配置"), chevron: false)
            }.accessibilityIdentifier("privacyShareProfile")
            NavigationLink { ProfileImportPage(host: host, hostLabel: hostLabel) } label: {
                SettingsRowLabel(title: String(localized: "导入配置"), chevron: false)
            }.accessibilityIdentifier("privacyImportProfile")
            NavigationLink { ProfileRestorePointsPage(host: host, hostLabel: hostLabel) } label: {
                SettingsRowLabel(title: String(localized: "恢复点"), value: "\(restoreCount)", chevron: false)
            }.accessibilityIdentifier("privacyRestorePoints")
        } header: { Text("配置") }.listRowBackground(ChatColors.chip)
            .onAppear { restoreCount = ProfileRestorePoint.all().count }
            .onReceive(NotificationCenter.default.publisher(for: ProfileRestorePoint.changed)) { _ in
                restoreCount = ProfileRestorePoint.all().count
            }
        SessionLogSection(host: host)
    }
}

/// 使用统计, then 对话日志: the host's `session-log-deepseek.enabled`, shown only when
/// the host has it. The host is read from the 使用统计 section, which is always on
/// screen (a task on an empty view never runs).
private struct SessionLogSection: View {
    let host: Harness?
    static let namespace = "session-log-deepseek"
    @State private var present = false
    @State private var enabled = false
    @State private var revision = 0
    @State private var writable = false
    @State private var saving = false
    @State private var note: String?

    var body: some View {
        Section {
            Text("不收集使用统计，没有埋点或上报。")
        } header: { Text("使用统计") }.listRowBackground(ChatColors.chip)
            .task(id: host.map(ObjectIdentifier.init)) {
                present = false
                note = nil
                await load()
            }
        if present {
            Section {
                Toggle("向 DeepSeek 上传对话日志", isOn: Binding(get: { enabled }, set: { save($0) }))
                    .disabled(!writable || saving).accessibilityIdentifier("privacySessionLog")
                if let note { Text(note).font(.caption).foregroundStyle(ChatColors.muted).accessibilityIdentifier("privacySessionLogNote") }
            } header: { Text("对话日志") }.listRowBackground(ChatColors.chip)
        }
    }

    private func load() async {
        guard let host else { return }
        let result = try? await host.rpc("settings/describe", args: [:])
        guard !Task.isCancelled else { return }
        guard let described = result,
              let section = (described["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == Self.namespace }) else { present = false; return }
        present = true
        writable = described["writable"] as? Bool == true
        enabled = (section["value"] as? Object)?["enabled"] as? Bool ?? true
        revision = section["revision"] as? Int ?? 0
    }

    private func save(_ on: Bool) {
        guard let host, writable, !saving else { return }
        saving = true; note = nil
        Task {
            defer { saving = false }
            do {
                _ = try await host.rpcValue("settings/mutate", args: ["ns": Self.namespace, "expectedRevision": revision,
                                                                      "ops": [["op": "set", "path": ["enabled"], "value": on]]])
                await load()
                note = String(localized: "已保存：") + (enabled ? String(localized: "开启") : String(localized: "关闭"))
            } catch {
                await load()
                note = String(localized: "没能保存：") + HostError.explain(error)
            }
        }
    }
}

// MARK: - 分享配置

struct ProfileExportPage: View {
    let host: Harness?
    var hostLabel: String?
    @State private var export: ProfileExport?
    @State private var selected: Set<String> = []
    @State private var name = ""
    @State private var issue: String?
    @State private var loaded = false

    var body: some View {
        SettingsList {
            if let hostLabel {
                Section { Text(String(localized: "来自：") + hostLabel).font(.subheadline).foregroundStyle(ChatColors.muted) }.listRowBackground(Color.clear)
            }
            if let export {
                if export.items.isEmpty {
                    Text("这台设备上没有改过的设置可以分享。").foregroundStyle(ChatColors.muted).listRowBackground(ChatColors.chip)
                } else {
                    Section {
                        ForEach(export.items) { item in
                            Button { toggle(item.ns) } label: {
                                HStack {
                                    Image(systemName: selected.contains(item.ns) ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: item.ns).font(.callout.monospaced()).foregroundStyle(ChatColors.ink)
                                        Text(String(localized: "\(item.fields) 项") + (item.dropped > 0 ? String(localized: " · 去掉了 \(item.dropped) 项凭据或本机路径") : ""))
                                            .font(.caption).foregroundStyle(ChatColors.muted)
                                    }
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(.caption).foregroundStyle(ChatColors.muted)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("shareItem-" + item.ns)
                        }
                    } header: { Text("设置") }.listRowBackground(ChatColors.chip)
                    Section {
                        TextField("配置名称（可选）", text: $name).onChange(of: name) { _, value in if value.count > 40 { name = String(value.prefix(40)) } }
                        NavigationLink { ProfileSharePreview(payload: export.payload(selected, name: name.isEmpty ? nil : name)) } label: {
                            Text("预览并分享").bold()
                        }.disabled(selected.isEmpty).accessibilityIdentifier("shareProfilePreview")
                    }.listRowBackground(ChatColors.chip)
                }
            } else if loaded {
                Text(host == nil ? "连接设备后才能分享配置。" : "没能读取设置").foregroundStyle(ChatColors.muted).listRowBackground(ChatColors.chip)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let issue { Text(issue).font(.footnote).foregroundStyle(DrawerPalette.danger).listRowBackground(Color.clear) }
        }
        .settingsPage(String(localized: "分享配置"))
        .task {
            guard let host else { loaded = true; return }
            do { export = try await ProfileExport.load(host); selected = Set(export?.items.map(\.ns) ?? []) }
            catch { issue = HostError.explain(error) }
            loaded = true
        }
    }

    private func toggle(_ ns: String) { if selected.contains(ns) { selected.remove(ns) } else { selected.insert(ns) } }
}

/// 预览: exactly the JSON that goes into the code, then 复制分享码 / 分享文件.
struct ProfileSharePreview: View {
    let payload: ProfileSharePayload
    @State private var code: String?
    @State private var file: URL?
    @State private var issue: String?
    @State private var copied = false
    #if os(macOS)
    @State private var saving = false
    @State private var savedName: String?
    #endif

    private var preview: String {
        (try? JSONSerialization.data(withJSONObject: payload.json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var body: some View {
        SettingsList {
            Section {
                Text(payload.summary.isEmpty ? String(localized: "空配置") : payload.summary)
                if let code { LabeledContent("分享码长度") { Text("\(code.count) 字符") } }
            }.listRowBackground(ChatColors.chip)
            Section("将要分享的内容") {
                ScrollView(.horizontal) {
                    Text(verbatim: preview).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                }.accessibilityIdentifier("shareProfileJSON")
            }.listRowBackground(ChatColors.chip)
            Section {
                Button(copied ? "已复制分享码" : "复制分享码") {
                    if let code { PlatformPasteboard.copy(code); copied = true }
                }.disabled(code == nil).accessibilityIdentifier("shareProfileCopy")
                if let file {
                    ShareLink(item: file) { Label("分享 .dshlocal 文件", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("shareProfileFile")
                    #if os(macOS)
                    Button("存储到文件", systemImage: "square.and.arrow.down") { save(file) }
                        .disabled(saving).accessibilityIdentifier("saveProfileFile")
                    if let savedName {
                        Text(String(localized: "已存到「") + savedName + String(localized: "」"))
                            .accessibilityIdentifier("profileFileSaved")
                    }
                    #endif
                }
            }.listRowBackground(ChatColors.chip)
            if let issue { Text(issue).font(.footnote).foregroundStyle(DrawerPalette.danger).listRowBackground(Color.clear) }
        }
        .settingsPage(String(localized: "预览"))
        .task {
            do {
                code = try ShareCodec.encode(payload.json)
                let text = try ShareCodec.file(payload.json, name: payload.name)
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let base = (payload.name?.isEmpty == false ? payload.name! : String(localized: "配置")).replacingOccurrences(of: "/", with: "-")
                let url = folder.appending(path: base + ".dshlocal")
                try Data(text.utf8).write(to: url)
                file = url
            } catch { issue = HostError.explain(error) }
        }
    }

    #if os(macOS)
    private func save(_ file: URL) {
        saving = true
        issue = nil
        savedName = nil
        Task {
            defer { saving = false }
            do { savedName = try await MacFileExport.save(file)?.lastPathComponent }
            catch { issue = HostError.explain(error) }
        }
    }
    #endif
}

// MARK: - 导入配置

struct ProfileImportPage: View {
    private struct Preview {
        let input: String
        let host: ObjectIdentifier
        let payload: ProfileSharePayload
        let plan: ProfileImportPlan
    }

    let host: Harness?
    var hostLabel: String?
    @State private var text = ""
    @State private var preview: Preview?
    @State private var selected: Set<String> = []
    @State private var issue: String?
    @State private var busy = false
    @State private var importing = false
    @State private var done: ProfileRestorePoint?
    @FocusState private var typing: Bool

    var body: some View {
        SettingsList {
            Section {
                #if os(macOS)
                if let hostLabel { LabeledContent("目标设备", value: hostLabel) }
                #endif
                TextField("粘贴分享码、.dshlocal 文件内容或分享链接", text: $text, axis: .vertical).lineLimit(2...5).font(.caption.monospaced())
                    .focused($typing).accessibilityIdentifier("importProfileText")
                HStack {
                    Button("粘贴") { if let pasted = PlatformPasteboard.text { text = pasted } }
                    Spacer()
                    Button("从文件导入") { importing = true }.accessibilityIdentifier("importProfileFile")
                    Spacer()
                    Button("读取") { read() }.bold().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host == nil)
                        .accessibilityIdentifier("importProfileRead")
                }.buttonStyle(.borderless)
                #if os(macOS)
                if host == nil { Text("连接设备后才能导入。").foregroundStyle(ChatColors.muted) }
                #endif
            } footer: {
                #if os(iOS)
                Text(host == nil ? String(localized: "连接设备后才能导入。") : String(localized: "导入到：") + (hostLabel ?? String(localized: "当前设备")))
                #endif
            }.listRowBackground(ChatColors.chip)
            if let preview, preview.input == text, host.map(ObjectIdentifier.init) == preview.host {
                let payload = preview.payload
                let plan = preview.plan
                Section {
                    #if os(iOS)
                    LabeledContent("目标设备") { Text(hostLabel ?? String(localized: "当前设备")) }
                    #endif
                    if let name = payload.name { LabeledContent("配置名称") { Text(name) } }
                    if let created = payload.created { LabeledContent("导出时间") { Text(created.formatted(date: .abbreviated, time: .shortened)) } }
                    LabeledContent("内容") { Text(payload.summary) }
                } header: { Text("分享内容") }.listRowBackground(ChatColors.chip)
                Section {
                    if plan.changes.isEmpty { Text("所有设置都和设备上的一致，没有要改的。").foregroundStyle(ChatColors.muted) }
                    ForEach(plan.changes) { change in changeRow(change) }
                    if !plan.ignored.isEmpty {
                        Text(String(localized: "已忽略疑似凭据或本机路径的字段：") + plan.ignored.joined(separator: String(localized: "、"))).font(.caption)
                            .foregroundStyle(SettingsStyle.warning).accessibilityIdentifier("importProfileIgnored")
                    }
                    if !plan.unchanged.isEmpty {
                        Text(String(localized: "不变：") + plan.unchanged.joined(separator: String(localized: "、"))).font(.caption).foregroundStyle(ChatColors.muted)
                    }
                } header: { Text("改动") }.listRowBackground(ChatColors.chip)
                if !payload.plugins.isEmpty || !payload.presets.isEmpty || !payload.skills.isEmpty || payload.agentsMd != nil {
                    Section {
                        ForEach(Array(payload.plugins.enumerated()), id: \.offset) { _, plugin in
                            LabeledContent((plugin["title"] as? String) ?? (plugin["name"] as? String) ?? String(localized: "插件")) {
                                Text([plugin["source"] as? String, plugin["version"] as? String].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                        if !payload.skills.isEmpty { Text("\(payload.skills.count) 个技能") }
                        if payload.agentsMd != nil { Text("AGENTS.md") }
                    } header: { Text("不导入") }.listRowBackground(ChatColors.chip)
                }
                Section {
                    Button { apply(preview) } label: { HStack { Spacer(); if busy { ProgressView() } else { Text("导入选中的 \(selected.count) 项").bold() }; Spacer() } }
                        .disabled(selected.isEmpty || busy).accessibilityIdentifier("importProfileApply")
                }.listRowBackground(ChatColors.chip)
            }
            if let done {
                Section {
                    Label("已导入", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    NavigationLink { ProfileRestorePointsPage(host: host, hostLabel: hostLabel) } label: {
                        Text(String(localized: "恢复点 · ") + done.created.formatted(date: .omitted, time: .standard))
                    }
                }.listRowBackground(ChatColors.chip).accessibilityIdentifier("importProfileDone")
            }
            if let issue { Text(issue).font(.footnote).foregroundStyle(DrawerPalette.danger).textSelection(.enabled).listRowBackground(Color.clear) }
        }
        .disabled(busy)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { typing = false } } }
        #endif
        .settingsPage(String(localized: "导入配置"))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data, .item]) { result in
            guard let url = try? result.get() else { return }
            preview = nil
            done = nil
            issue = nil
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let limit = ShareCodec.maxCodeCharacters + 4096
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw HostError(String(localized: "没能读取这个文件"))
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                guard let data = try file.read(upToCount: limit + 1), data.count <= limit else {
                    throw HostError(String(localized: "没能读取这个文件"))
                }
                text = String(decoding: data, as: UTF8.self)
                read()
            } catch { issue = String(localized: "没能读取这个文件") }
        }
    }

    private func changeRow(_ change: ProfileImportPlan.Change) -> some View {
        Button { if change.applicable { if selected.contains(change.ns) { selected.remove(change.ns) } else { selected.insert(change.ns) } } } label: {
            HStack(alignment: .top) {
                Image(systemName: !change.applicable ? "minus.circle" : selected.contains(change.ns) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(change.applicable ? Color.accentColor : ChatColors.muted)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: change.ns).font(.callout.monospaced()).foregroundStyle(ChatColors.ink)
                        Text(kind(change)).font(.caption).foregroundStyle(change.applicable ? ChatColors.muted : SettingsStyle.warning)
                        if change.sensitive { Text("敏感").font(.caption2).foregroundStyle(SettingsStyle.warning) }
                    }
                    ForEach(change.diffs) { diff in
                        Text(verbatim: diff.key + String(localized: "：") + render(diff.from) + " → " + render(diff.to)).font(.caption.monospaced())
                            .foregroundStyle(ChatColors.muted).lineLimit(3)
                    }
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("importChange-" + change.ns)
    }

    private func kind(_ change: ProfileImportPlan.Change) -> String {
        switch change.kind {
        case .add: String(localized: "新增")
        case .change: String(localized: "修改")
        case .unavailable: String(localized: "这台设备没有这项设置，跳过")
        case .readOnly: String(localized: "这台设备的设置是只读的")
        }
    }

    private func render(_ value: Any?) -> String {
        guard let value else { return String(localized: "（未设置）") }
        if let text = value as? String { return "\"" + text + "\"" }
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(value)" }
        let json = String(decoding: data, as: UTF8.self)
        let inner = String(json.dropFirst(5).dropLast())
        return inner.count > 120 ? String(inner.prefix(120)) + "…" : inner
    }

    private func read() {
        guard let host else { return }
        let input = text
        typing = false
        issue = nil; preview = nil; done = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let next = try ProfileSharePayload(json: try ShareCodec.decode(try ShareCodec.code(in: input)))
                let made = try await ProfileImportPlan.make(next, on: host)
                preview = Preview(input: input, host: ObjectIdentifier(host), payload: next, plan: made)
                selected = Set(made.changes.filter { $0.applicable && !$0.sensitive }.map(\.ns))
            } catch { issue = HostError.explain(error) }
        }
    }

    private func apply(_ ready: Preview) {
        guard let host, ready.host == ObjectIdentifier(host), ready.input == text else { return }
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do {
                done = try await ready.plan.apply(selected, on: host, hostLabel: hostLabel ?? String(localized: "当前设备"), share: ready.payload.name)
                preview = nil
            } catch { issue = HostError.explain(error) }
        }
    }
}

/// 恢复点: imports made from this app, newest first, each can be undone once.
struct ProfileRestorePointsPage: View {
    let host: Harness?
    var hostLabel: String?
    @State private var points = ProfileRestorePoint.all()
    @State private var issue: String?
    @State private var busy: UUID?
    @State private var confirming: ProfileRestorePoint?

    var body: some View {
        SettingsList {
            if points.isEmpty { Text("还没有导入过配置。").foregroundStyle(ChatColors.muted).listRowBackground(ChatColors.chip) }
            ForEach(points) { point in
                VStack(alignment: .leading, spacing: 4) {
                    Text(point.created.formatted(date: .abbreviated, time: .standard)).font(.headline)
                    Text(String(localized: "设备：") + point.host + (point.share.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(ChatColors.muted)
                    Text(point.namespaces.keys.sorted().joined(separator: String(localized: "、"))).font(.caption.monospaced()).foregroundStyle(ChatColors.muted)
                    if let restored = point.restored {
                        Text(String(localized: "已于 ") + restored.formatted(date: .omitted, time: .standard) + String(localized: " 恢复")).font(.caption).foregroundStyle(.green)
                    } else {
                        Button(busy == point.id ? "正在恢复…" : "恢复到导入前") { confirming = point }
                            .disabled(host == nil || busy != nil).accessibilityIdentifier("restorePoint")
                    }
                }.padding(.vertical, 4)
            }.listRowBackground(ChatColors.chip)
            if let issue { Text(issue).font(.footnote).foregroundStyle(DrawerPalette.danger).listRowBackground(Color.clear) }
        }
        .settingsPage(String(localized: "恢复点"))
        .alert("恢复到导入前？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { point in
            Button("取消", role: .cancel) {}
            Button("恢复") { restore(point) }
        } message: { point in
            Text(String(localized: "把「\(hostLabel ?? String(localized: "当前设备"))」上的 \(point.namespaces.count) 个设置分区改回导入前的值。") + (hostLabel != nil && hostLabel != point.host ? String(localized: "\n\n注意：这个恢复点来自「\(point.host)」。") : ""))
        }
    }

    private func restore(_ point: ProfileRestorePoint) {
        guard let host else { return }
        busy = point.id; issue = nil
        Task {
            defer { busy = nil; points = ProfileRestorePoint.all() }
            do { try await point.restore(on: host) } catch { issue = HostError.explain(error) }
        }
    }
}
