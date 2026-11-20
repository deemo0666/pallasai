import SwiftUI

// MARK: - 文件

private struct WorkspaceEntry: Identifiable, Equatable {
    let name: String
    let directory: Bool
    let size: Int?
    var id: String { name }
}

private struct WorkspaceHit: Identifiable {
    let path: String
    let directory: Bool
    var id: String { path }
}

/// 文件 on its own page.
struct WorkspaceBrowserPage: View {
    @ObservedObject var chat: Conversation
    let host: Harness
    var body: some View {
        List { WorkspaceBrowserRows(chat: chat, host: host) }
            .groupedList().scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
    }
}

/// The workspace one folder at a time: a name search, path capsules, rows with
/// size and time, folder and file counts; a file opens its preview.
struct WorkspaceBrowserRows: View {
    @ObservedObject var chat: Conversation
    let host: Harness
    @State private var path = ""
    @State private var entries: [WorkspaceEntry]?
    @State private var truncated = false
    @State private var times: [String: Date] = [:]
    @State private var failure: String?
    @State private var missing = false
    @State private var query = ""
    @State private var results: [WorkspaceHit]?
    @State private var searchFailure: String?
    @State private var attempt = 0
    @State private var copied: String?

    private var root: String { chat.workspace }
    private var searchingFiles: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private func child(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }
    private func absolute(_ relative: String) -> String {
        if relative.hasPrefix("/") || root.isEmpty { return relative }
        return relative.isEmpty ? root : (root.hasSuffix("/") ? root : root + "/") + relative
    }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ChatColors.muted)
                TextField("搜索文件", text: $query).noAutomaticCapitalization().autocorrectionDisabled().submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ChatColors.muted) }
                        .buttonStyle(.plain).accessibilityLabel("清除")
                }
            }
            if !searchingFiles {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        crumb(String(localized: "文件夹"), target: "")
                        let parts = path.split(separator: "/").map(String.init)
                        ForEach(parts.indices, id: \.self) { i in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(ChatColors.muted)
                            crumb(parts[i], target: parts[...i].joined(separator: "/"))
                        }
                    }
                }
            }
        }.listRowBackground(ChatColors.chip)
        .task(id: "\(path)|\(attempt)") { await list() }
        .task(id: query) { await searchFiles() }
        if searchingFiles { searchSection } else { folderSection }
        if let copied { Section { Text(String(localized: "已复制 ") + copied).font(.caption).foregroundStyle(ChatColors.muted) }.listRowBackground(Color.clear) }
    }

    private func crumb(_ title: String, target: String) -> some View {
        let current = target == path
        return Button { path = target } label: {
            Text(verbatim: title).font(.subheadline).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background((current ? Color.accentColor : ChatColors.muted).opacity(current ? 0.16 : 0.1), in: Capsule())
                .foregroundStyle(current ? Color.accentColor : ChatColors.ink)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var folderSection: some View {
        if let failure {
            Section {
                HostEmptyState(symbol: "folder.badge.questionmark", title: String(localized: "打不开这个文件夹"), message: failure,
                               action: missing ? (String(localized: "回到上一级"), { path = path.split(separator: "/").dropLast().joined(separator: "/") }) : (String(localized: "重试"), { attempt += 1 }))
            }.listRowBackground(Color.clear)
        } else if let entries {
            if entries.isEmpty {
                Section { HostEmptyState(symbol: "folder", title: String(localized: "空文件夹")) }.listRowBackground(Color.clear)
            } else {
                let folders = entries.filter(\.directory).count, files = entries.count - folders
                Section {
                    ForEach(entries) { entry in entryRow(entry) }
                } footer: {
                    Text([folders > 0 ? String(localized: "\(folders) 个文件夹") : nil, files > 0 ? String(localized: "\(files) 个文件") : nil,
                          truncated ? String(localized: "只列出了前 \(entries.count) 项") : nil].compactMap { $0 }.joined(separator: String(localized: "，")))
                }.listRowBackground(ChatColors.chip)
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
        }
    }

    private func rowLabel(name: String, directory: Bool, line: String, mono: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: directory ? "folder.fill" : WorkspaceFilePreview.symbol(for: name))
                .foregroundStyle(directory ? Color.accentColor : ChatColors.muted).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).foregroundStyle(ChatColors.ink).lineLimit(2)
                if !line.isEmpty {
                    Text(verbatim: line).font(mono ? .caption.monospaced() : .caption.monospacedDigit()).foregroundStyle(ChatColors.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if directory { Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted) }
        }.contentShape(Rectangle())
    }

    @ViewBuilder private func entryRow(_ entry: WorkspaceEntry) -> some View {
        let relative = child(entry.name)
        let line = [entry.size.map(HostPanelFormat.bytes), times[entry.name].map { HostPanelFormat.fileTime($0) }].compactMap { $0 }.joined(separator: " · ")
        Group {
            if entry.directory {
                Button { path = relative } label: { rowLabel(name: entry.name, directory: true, line: line) }.buttonStyle(.plain)
            } else {
                NavigationLink { WorkspaceFilePreview(host: host, path: relative, absolute: absolute(relative)) } label: {
                    rowLabel(name: entry.name, directory: false, line: line)
                }
            }
        }.accessibilityIdentifier(entry.name)
        .contextMenu {
            if entry.directory { Button("打开") { path = relative } }
            Button("复制路径") { copy(absolute(relative)) }
        }
    }

    @ViewBuilder private var searchSection: some View {
        if let searchFailure {
            Section { HostEmptyState(symbol: "magnifyingglass", title: String(localized: "没能搜索"), message: searchFailure) }.listRowBackground(Color.clear)
        } else if let results {
            if results.isEmpty {
                Section { HostEmptyState(symbol: "magnifyingglass", title: String(localized: "没有找到")) }.listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results) { hit in
                        let trimmed = hit.path.hasSuffix("/") ? String(hit.path.dropLast()) : hit.path
                        let name = (trimmed as NSString).lastPathComponent, parent = (trimmed as NSString).deletingLastPathComponent
                        Group {
                            if hit.directory {
                                Button { query = ""; path = trimmed } label: { rowLabel(name: name, directory: true, line: parent, mono: true) }.buttonStyle(.plain)
                            } else {
                                NavigationLink { WorkspaceFilePreview(host: host, path: trimmed, absolute: absolute(trimmed)) } label: {
                                    rowLabel(name: name, directory: false, line: parent, mono: true)
                                }
                            }
                        }.contextMenu { Button("复制路径") { copy(absolute(trimmed)) } }
                    }
                }.listRowBackground(ChatColors.chip)
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
        }
    }

    private func copy(_ text: String) {
        PlatformPasteboard.copy(text)
        copied = (text as NSString).lastPathComponent
    }

    private func list() async {
        failure = nil; missing = false; entries = nil; times = [:]
        do {
            let data = try await host.rpc("workspaceFiles/list", args: ["workspaceFileScopeId": host.sessionID, "path": path.isEmpty ? "." : path])
            try Task.checkCancellation()
            let found = (data["entries"] as? [Object] ?? []).compactMap { item -> WorkspaceEntry? in
                guard let name = item["name"] as? String, !name.isEmpty else { return nil }
                return WorkspaceEntry(name: name, directory: item["type"] as? String == "directory", size: (item["size"] as? NSNumber)?.intValue)
            }
            let sorted = found.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            entries = sorted
            truncated = data["truncated"] as? Bool == true
            // Modified times arrive a few at a time.
            let files = Array(sorted.filter { !$0.directory }.prefix(120))
            var start = 0
            while start < files.count {
                try Task.checkCancellation()
                let chunk = files[start..<min(start + 6, files.count)]
                start += 6
                for entry in chunk {
                    let stat = try? await host.rpc("workspaceFiles/stat", args: ["workspaceFileScopeId": host.sessionID, "path": child(entry.name)])
                    try Task.checkCancellation()
                    if let date = (stat?["version"] as? String).flatMap(HostPanelFormat.modified(fromVersion:)) { times[entry.name] = date }
                }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            let code = (error as? HostError)?.code
            missing = code == "workspace-file/not-found" && !path.isEmpty
            failure = code == "workspace-file/not-found" ? String(localized: "这个文件夹已经不在了") : code == "workspace-file/outside-workspace" ? String(localized: "不在这个文件夹里") : error.localizedDescription
        }
    }

    private func searchFiles() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        results = nil; searchFailure = nil
        guard !text.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let value = try await host.rpcValue("fileReferences/list", args: ["agentId": host.sessionID, "query": text])
            try Task.checkCancellation()
            results = (value as? [Object] ?? []).compactMap { item in
                guard let path = item["path"] as? String, !path.isEmpty else { return nil }
                return WorkspaceHit(path: path, directory: item["kind"] as? String == "directory")
            }
        } catch is CancellationError {
        } catch { if !Task.isCancelled { searchFailure = error.localizedDescription } }
    }
}

/// One workspace file: an image, Markdown, a table or text; 打开 hands it to Quick Look, 复制路径 copies it.
struct WorkspaceFilePreview: View {
    let host: Harness
    let path: String
    let absolute: String
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @State private var text: String?
    @State private var version: String?
    @State private var nextLine: Int?
    @State private var image: PlatformImage?
    @State private var failure: String?
    @State private var loading = false
    @State private var copied = false
    @State private var opening = false

    private var ext: String { (path as NSString).pathExtension.lowercased() }
    private var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(ext) }

    static func symbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp"].contains(ext) { return "photo" }
        if ["mp4", "mov", "webm"].contains(ext) { return "film" }
        if ["csv", "tsv", "xls", "xlsx"].contains(ext) { return "tablecells" }
        if ["md", "markdown"].contains(ext) { return "text.alignleft" }
        if ["zip", "gz", "tar", "7z"].contains(ext) { return "archivebox" }
        if ["swift", "js", "ts", "py", "dart", "json", "sh", "go", "rs", "c", "h", "java", "kt", "yaml", "yml", "toml", "html", "css"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc.text"
    }

    var body: some View {
        List {
            if let image {
                Image(platformImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).listRowInsets(EdgeInsets())
            } else if let text {
                textBody(text)
                if let nextLine { Button("读取更多行") { Task { await read(offset: nextLine) } }.disabled(loading) }
            } else if let failure {
                Text(failure).foregroundStyle(ChatColors.muted)
                NavigationLink("打开") { HostDeliverablePreview(host: host, file: Self.deliverable(path)) }
            } else { ProgressView().frame(maxWidth: .infinity) }
            if copied { Text("已复制").font(.caption).foregroundStyle(ChatColors.muted) }
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle((path as NSString).lastPathComponent).inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .screenTrailing) {
                Menu {
                    Button { opening = true } label: { Label("打开", systemImage: "arrow.up.forward.app") }
                    Button { PlatformPasteboard.copy(absolute); copied = true } label: { Label("复制路径", systemImage: "doc.on.doc") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("更多操作")
            }
        }
        .navigationDestination(isPresented: $opening) { HostDeliverablePreview(host: host, file: Self.deliverable(path)) }
        .task { if isImage { await loadImage() } else { await read(offset: 1) } }
    }

    @ViewBuilder private func textBody(_ text: String) -> some View {
        if ["md", "markdown"].contains(ext), let rich = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(rich).font(typeSize.font).textSelection(.enabled)
        } else if ["csv", "tsv"].contains(ext), let table = Self.table(text, separator: ext == "tsv" ? "\t" : ","), table.count > 1 {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(table.indices, id: \.self) { r in
                        GridRow {
                            ForEach(table[r].indices, id: \.self) { c in
                                Text(verbatim: table[r][c]).font(r == 0 ? .caption.weight(.semibold) : .caption).lineLimit(3)
                                    .frame(maxWidth: 220, alignment: .leading)
                            }
                        }
                        if r == 0 { Divider() }
                    }
                }.padding(.vertical, 4)
            }
            Text("\(table.count - 1) 行 · \(table.first?.count ?? 0) 列").font(.caption).foregroundStyle(ChatColors.muted)
        } else {
            Text(verbatim: text).font(typeSize.font.monospaced()).textSelection(.enabled)
        }
    }

    static func deliverable(_ path: String) -> HostDeliverable {
        HostDeliverable(id: .init(sequence: 0, index: 0), turn: 0, path: path, detail: nil, generated: false)
    }

    /// A small CSV/TSV as rows of cells; nil when it is not a plain table.
    static func table(_ text: String, separator: Character) -> [[String]]? {
        let lines = text.split(whereSeparator: \.isNewline).prefix(200)
        guard !lines.isEmpty, !text.contains("\"") else { return nil }
        let rows = lines.map { $0.split(separator: separator, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) } }
        let width = rows.first?.count ?? 0
        guard width > 1, width <= 30 else { return nil }
        return rows.map { row in Array(row.prefix(width)) + Array(repeating: "", count: max(0, width - row.count)) }
    }

    private func loadImage() async {
        do {
            let file = try await host.downloadWorkspaceFile(path)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            guard let picture = PlatformImage(data: try Data(contentsOf: file, options: .mappedIfSafe)) else { throw HostError(String(localized: "图片没能显示")) }
            image = picture
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func read(offset: Int) async {
        loading = true
        defer { loading = false }
        do {
            let page = try await host.rpc("workspaceFiles/read", args: ["workspaceFileScopeId": host.sessionID, "path": path, "range": ["offset": offset]])
            guard let chunk = page["text"] as? String, let lines = page["lines"] as? Int, let stamp = page["version"] as? String else {
                throw HostError(String(localized: "这个文件不能按文本预览"))
            }
            guard offset == 1 || stamp == version else { nextLine = nil; throw HostError(String(localized: "文件已更改，请重新打开。")) }
            version = stamp
            text = offset == 1 ? chunk : (text ?? "") + (lines > 0 ? "\n" + chunk : "")
            nextLine = page["eof"] as? Bool == false && lines > 0 ? offset + lines : nil
        } catch {
            guard !Task.isCancelled else { return }
            let code = (error as? HostError)?.code
            failure = code == "workspace-file/not-text" ? String(localized: "这个文件不能按文本预览") : code == "workspace-file/too-large" ? String(localized: "文件太大，没法在这里预览") : error.localizedDescription
        }
    }
}
