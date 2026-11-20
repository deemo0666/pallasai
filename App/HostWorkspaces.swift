import SwiftUI

/// One registered workspace from `workspace/follow`.
struct HostWorkspace: Identifiable, Equatable {
    let id: String
    let path: String
    let title: String
    let sessionCount: Int

    init?(_ raw: Any?) {
        guard let object = raw as? Object, let id = object["workspaceId"] as? String, !id.isEmpty else { return nil }
        self.id = id
        path = object["path"] as? String ?? ""
        title = object["title"] as? String ?? ""
        sessionCount = (object["sessionIds"] as? [Any])?.count ?? 0
    }

    var name: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// 工作区: the host's registered folders, each with its conversation count.
/// A row offers a new conversation there, rename and remove; ＋ adds a folder.
struct HostWorkspacesView: View {
    let host: Harness
    @ObservedObject var chat: Conversation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspaces: [HostWorkspace]?
    @State private var issue: String?
    @State private var attempt = 0
    @State private var chosen: HostWorkspace?
    @State private var renaming: HostWorkspace?
    @State private var newTitle = ""
    @State private var removing: HostWorkspace?
    @State private var adding = false
    @State private var note: String?

    var body: some View {
        List {
            if let workspaces, !workspaces.isEmpty {
                Text("\(workspaces.count) 个文件夹").font(.subheadline).foregroundStyle(ChatColors.muted)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            if let note { Text(note).foregroundStyle(.red).listRowBackground(ChatColors.chip) }
            if let issue, workspaces == nil {
                Section {
                    Text("没能读取文件夹").font(.headline)
                    Text(issue).font(.caption).foregroundStyle(ChatColors.muted)
                    Button("重试") { attempt += 1 }
                }.listRowBackground(ChatColors.chip)
            } else if let workspaces {
                if workspaces.isEmpty {
                    ContentUnavailableView {
                        Label("还没有文件夹", systemImage: "folder.badge.plus")
                    } actions: {
                        Button("添加文件夹") { adding = true }.prominentButton()
                    }.listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(workspaces) { workspace in
                            Button { chosen = workspace } label: { row(workspace) }.buttonStyle(.plain)
                                .accessibilityIdentifier("hostWorkspace-" + workspace.name)
                        }
                    }.listRowBackground(ChatColors.chip)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .foregroundStyle(ChatColors.ink).scrollContentBackground(.hidden)
        .background(ChatColors.canvas.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .screenLeading) {
                Button { adding = true } label: { Label("添加文件夹", systemImage: "plus") }.accessibilityIdentifier("addWorkspace")
            }
        }
        .task(id: "\(attempt)/\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await follow()
        }
        .confirmationDialog(chosen?.name ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                            titleVisibility: .visible, presenting: chosen) { workspace in
            Button("在这里新建对话") { start(in: workspace) }
            Button("重命名") { newTitle = workspace.name; renaming = workspace }
            Button("移除文件夹", role: .destructive) { removing = workspace }
        } message: { workspace in Text(verbatim: workspace.path) }
        .alert("文件夹名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { workspace in
            TextField("名称", text: $newTitle)
            Button("保存") { rename(workspace, to: newTitle) }
            Button("取消", role: .cancel) {}
        }
        .alert("移除这个文件夹？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { workspace in
            Button("移除", role: .destructive) { remove(workspace) }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("只是不再显示在这里，文件夹里的文件和对话都保留。") }
        .sheet(isPresented: $adding) {
            HostDirectoryPicker(host: host) { workspace in
                adding = false
                if let workspace { note = nil; chosen = workspace }
            }
        }
    }

    private func row(_ workspace: HostWorkspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: workspace.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(verbatim: workspace.path).font(.caption.monospaced()).foregroundStyle(ChatColors.muted).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text(workspace.sessionCount == 0 ? "没有对话" : "\(workspace.sessionCount) 个对话").font(.caption).foregroundStyle(ChatColors.muted)
            if workspace.path == chat.workspace { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("当前文件夹") }
        }.padding(.vertical, 3).contentShape(Rectangle())
    }

    private func start(in workspace: HostWorkspace) {
        dismiss()
        Task { if chat.connection === host { await chat.openSession(nil, workspace: workspace.id) } }
    }

    private func rename(_ workspace: HostWorkspace, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != workspace.name else { return }
        Task {
            do {
                let reply = try await host.call("workspace/rename", ["workspaceId": workspace.id, "title": name])
                guard let confirmed = HostWorkspace(reply["workspace"]), confirmed.name == name else { throw HostError(String(localized: "重命名可能没生效。刷新后看看。")) }
                replace(confirmed); note = nil
            } catch { note = String(localized: "没能重命名：") + HostError.explain(error) }
        }
    }

    private func remove(_ workspace: HostWorkspace) {
        Task {
            do {
                _ = try await host.rpcValue("workspace/delete", args: ["request": ["workspaceId": workspace.id]])
                workspaces?.removeAll { $0.id == workspace.id }; note = nil
            } catch { note = String(localized: "移除失败：") + HostError.explain(error) }
        }
    }

    private func replace(_ workspace: HostWorkspace) {
        guard var list = workspaces else { return }
        if let index = list.firstIndex(where: { $0.id == workspace.id }) { list[index] = workspace } else { list.append(workspace) }
        workspaces = list
    }

    /// The baseline, then upserts, removals and reorders.
    private func follow() async {
        do {
            let stream = try await host.stream("workspace/follow", args: [:])
            defer { stream.cancel() }
            while !Task.isCancelled {
                let frame = try await stream.next()
                try Task.checkCancellation()
                switch frame["type"] as? String {
                case "baseline":
                    workspaces = ((frame["value"] as? Object)?["items"] as? [Any] ?? []).compactMap(HostWorkspace.init)
                case "upsert": if let workspace = HostWorkspace(frame["workspace"]) { replace(workspace) }
                case "remove": workspaces?.removeAll { $0.id == frame["workspaceId"] as? String }
                case "order":
                    if let ids = frame["workspaceIds"] as? [String], let list = workspaces {
                        workspaces = list.sorted { (ids.firstIndex(of: $0.id) ?? .max) < (ids.firstIndex(of: $1.id) ?? .max) }
                    }
                default: continue
                }
                issue = nil
            }
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }
}

/// Browses the host's folders (`directoryPicker/list`) and registers one (`workspace/create`).
struct HostDirectoryPicker: View {
    let host: Harness
    let finished: (HostWorkspace?) -> Void
    @State private var path: String?
    @State private var listing: (path: String, home: String, entries: [(name: String, path: String)], truncated: Bool)?
    @State private var showHidden = false
    @State private var hidden: Set<String> = []
    @State private var issue: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if let issue { Text(issue).foregroundStyle(.red).listRowBackground(ChatColors.chip) }
                if let listing {
                    Section {
                        Text(verbatim: listing.path).font(.caption.monospaced()).textSelection(.enabled)
                        let parent = (listing.path as NSString).deletingLastPathComponent
                        if !parent.isEmpty, parent != listing.path {
                            Button { path = parent } label: { Label("上一级", systemImage: "arrow.turn.left.up") }
                        }
                        if listing.path != listing.home { Button { path = listing.home } label: { Label("主目录", systemImage: "house") } }
                    }.listRowBackground(ChatColors.chip)
                    Section {
                        let entries = listing.entries.filter { showHidden || !hidden.contains($0.path) }
                        if entries.isEmpty { Text("没有子文件夹").foregroundStyle(ChatColors.muted) }
                        ForEach(entries, id: \.path) { entry in
                            Button { path = entry.path } label: {
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(.tint)
                                    Text(verbatim: entry.name).foregroundStyle(ChatColors.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if listing.truncated { Text("文件夹太多，只显示了一部分").font(.caption).foregroundStyle(ChatColors.muted) }
                    } header: { Toggle("显示隐藏文件夹", isOn: $showHidden).font(.caption).textCase(nil) }
                        .listRowBackground(ChatColors.chip)
                } else if issue == nil { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            }
            .foregroundStyle(ChatColors.ink).scrollContentBackground(.hidden)
            .background(ChatColors.canvas.ignoresSafeArea())
            .disabled(busy)
            .navigationTitle("添加文件夹").inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { finished(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加此目录") { add() }.disabled(listing == nil || busy).accessibilityIdentifier("addThisDirectory")
                }
            }
            .task(id: path ?? "") { await load() }
        }
    }

    private func load() async {
        do {
            let value = try await host.rpc("directoryPicker/list", args: path.map { ["path": $0] } ?? [:])
            guard let current = value["path"] as? String else { throw HostError(String(localized: "没能打开这个文件夹。")) }
            var entries: [(name: String, path: String)] = []
            var secret: Set<String> = []
            for case let entry as Object in value["entries"] as? [Any] ?? [] {
                guard let name = entry["name"] as? String, let full = entry["path"] as? String else { continue }
                entries.append((name, full))
                if entry["hidden"] as? Bool == true { secret.insert(full) }
            }
            listing = (current, value["home"] as? String ?? current, entries, value["truncated"] as? Bool == true)
            hidden = secret; issue = nil
        } catch { if !Task.isCancelled { issue = String(localized: "没能读取目录：") + error.localizedDescription } }
    }

    private func add() {
        guard let target = listing?.path else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let reply = try await host.call("workspace/create", ["path": target])
                guard let workspace = HostWorkspace(reply["workspace"]) else { throw HostError(String(localized: "没能添加这个文件夹。")) }
                finished(workspace)
            } catch { issue = String(localized: "没能添加：") + HostError.explain(error) }
        }
    }
}
