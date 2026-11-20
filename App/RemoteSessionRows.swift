import CryptoKit
import SwiftUI

/// The drawer's groups: 置顶, then by day (今天 / 昨天 / 本周 / 更早; weeks start on Monday).
enum DrawerSection: String, CaseIterable {
    case pinned = "置顶", today = "今天", yesterday = "昨天", week = "本周", earlier = "更早"

    static let days: [Self] = [.today, .yesterday, .week, .earlier]

    static func period(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Self {
        guard let date else { return .earlier }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let diff = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if diff <= 0 { return .today }
        if diff == 1 { return .yesterday }
        let weekday = calendar.component(.weekday, from: today)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        return day >= monday ? .week : .earlier
    }

    var heading: some View { DrawerEyebrow(rawValue.localized) }
}

/// One registered workspace, with the conversations it holds.
struct DrawerWorkspace: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let sessionIDs: Set<String>

    init?(_ raw: Any?) {
        guard let base = HostWorkspace(raw), let object = raw as? Object else { return nil }
        id = base.id; name = base.name; path = base.path
        sessionIDs = Set(object["sessionIds"] as? [String] ?? [])
    }
}

/// 「工作区」: 全部对话, the host's workspaces (name and path), 添加工作区, 管理工作区.
struct DrawerWorkspaceSheet: View {
    let workspaces: [DrawerWorkspace]
    let selected: String?
    let total: Int
    let counts: [String: Int]
    let pick: (String?) -> Void
    let add: () -> Void
    let manage: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DrawerSheetFrame(title: String(localized: "文件夹")) {
            Section {
                choice("bubble.left.and.bubble.right", String(localized: "全部对话"), nil, total, selected == nil) { pick(nil) }
            }.listRowBackground(ChatColors.chip)
            if !workspaces.isEmpty {
                Section {
                    ForEach(workspaces) { workspace in
                        choice("folder", workspace.name, workspace.path, counts[workspace.id] ?? 0, selected == workspace.id) { pick(workspace.id) }
                    }
                }.listRowBackground(ChatColors.chip)
            }
            Section {
                Button { add(); dismiss() } label: { Label("添加文件夹", systemImage: "folder.badge.plus").foregroundStyle(ChatColors.ink) }
                    .accessibilityIdentifier("drawerAddWorkspace")
                if let manage, !workspaces.isEmpty {
                    Button { manage(); dismiss() } label: {
                        HStack {
                            Label("管理文件夹", systemImage: "slider.horizontal.3").foregroundStyle(ChatColors.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ChatColors.muted)
                        }.contentShape(Rectangle())
                    }
                }
            }.listRowBackground(ChatColors.chip)
        }.presentationDetents([.medium, .large])
    }

    private func choice(_ symbol: String, _ title: String, _ path: String?, _ count: Int, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { action(); dismiss() } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(ChatColors.muted).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).foregroundStyle(ChatColors.ink).lineLimit(1)
                    if let path, !path.isEmpty {
                        Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(ChatColors.muted).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer()
                if count > 0 { Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(ChatColors.muted) }
                Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.tint).opacity(on ? 1 : 0).frame(width: 20)
            }.contentShape(Rectangle())
        }.accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct RemoteSessionRows: View {
    let host: Harness
    let scope: String
    let workspace: String
    let query: String
    let open: (String) -> Void
    let share: (HostSessionRow) -> Void
    let archive: ([HostSessionRow]) -> Void
    /// Told which conversations the host confirmed as permanently deleted.
    let deleted: (Set<String>) -> Void
    let archiveBusy: Bool
    /// Starts a new conversation (and closes the drawer); a folder's 「新对话」 files it there. Hidden without one.
    let newChat: (() -> Void)?
    /// Opens 管理工作区; hidden without one.
    let manageWorkspaces: (() -> Void)?
    let hostName: String
    /// Told when multi-select starts and ends (the drawer may hide its own chrome meanwhile).
    let selectionChanged: (Bool) -> Void
    @Binding var filter: RemoteSessionFilter

    @State private var archived = Set<String>()
    @State private var pinned: [String] = []
    @State private var workspaces: [DrawerWorkspace] = []
    @State private var followReady = false
    @State private var archiveIssue: String?
    @State private var restoreIssue: String?
    @State private var restoring: String?
    @State private var rows: [HostSessionRow] = []
    @State private var creationTimes: [String: Int64] = [:]
    @State private var history: HostReadHistory?
    @State private var waiting: [String: String] = [:]
    @State private var more = false
    @State private var error: String?
    @State private var loading = true
    @State private var revision = 0
    @State private var renaming: HostSessionRow?
    @State private var renameText = ""
    @State private var selection: Set<String>?
    @State private var notice: DrawerNotice?
    @State private var sheet: DrawerSheet?
    @State private var afterSheet: (() -> Void)?
    @State private var archivedPage = false
    /// Only hosts whose engine has workspace/deleteSession offer 永久删除.
    @State private var deletable = false
    @State private var confirming: [HostSessionRow]?
    @State private var deleting = false
    @State private var pendingOpen: String?
    @State private var chosenWorkspace: String?
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var layout: HostFolderLibrary

    private enum DrawerSheet: Identifiable {
        case list, move(Set<String>), newFolder(Set<String>), editFolder(ConversationFolder), manageFolders, workspaces, addWorkspace
        var id: String {
            switch self {
            case .list: "list"
            case .move: "move"
            case .newFolder: "new"
            case .editFolder(let folder): "edit-" + folder.id.uuidString
            case .manageFolders: "manage"
            case .workspaces: "workspaces"
            case .addWorkspace: "add"
            }
        }
    }

    init(host: Harness, scope: String, workspace: String, query: String, open: @escaping (String) -> Void, share: @escaping (HostSessionRow) -> Void,
         archive: @escaping ([HostSessionRow]) -> Void, deleted: @escaping (Set<String>) -> Void, archiveBusy: Bool,
         filter: Binding<RemoteSessionFilter>, newChat: (() -> Void)? = nil, manageWorkspaces: (() -> Void)? = nil,
         hostName: String = String(localized: "我的电脑"), selectionChanged: @escaping (Bool) -> Void = { _ in }) {
        self.host = host; self.scope = scope; self.workspace = workspace; self.query = query; self.open = open; self.share = share
        self.archive = archive; self.deleted = deleted; self.archiveBusy = archiveBusy
        self.newChat = newChat; self.manageWorkspaces = manageWorkspaces; self.hostName = hostName; self.selectionChanged = selectionChanged
        _filter = filter
        _layout = StateObject(wrappedValue: HostFolderLibrary(scope: scope))
        _chosenWorkspace = State(initialValue: Self.selectedWorkspace(scope: scope))
    }

    // MARK: Workspace scope

    private static func workspaceKey(_ scope: String) -> String {
        "host-drawer-workspace-" + Data(SHA256.hash(data: Data(scope.utf8))).base64EncodedString()
    }

    /// The workspace the drawer shows on this host (`workspaceId`), or nil for 全部对话.
    /// New conversations from the drawer belong there.
    static func selectedWorkspace(scope: String) -> String? {
        UserDefaults.standard.string(forKey: workspaceKey(scope))
    }

    private func chooseWorkspace(_ id: String?) {
        chosenWorkspace = id
        if let id { UserDefaults.standard.set(id, forKey: Self.workspaceKey(scope)) }
        else { UserDefaults.standard.removeObject(forKey: Self.workspaceKey(scope)) }
    }

    /// The chosen workspace while the host still has it.
    private var scopedWorkspace: DrawerWorkspace? {
        guard followReady, let id = chosenWorkspace else { return nil }
        return workspaces.first { $0.id == id }
    }

    // MARK: What the list shows

    private func timestamp(_ row: HostSessionRow) -> Int64? { layout.byCreation ? row.created : row.updated }
    private func date(_ row: HostSessionRow) -> Date? { timestamp(row).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    private var pinnedSet: Set<String> { Set(pinned) }
    private func folderOf(_ id: String) -> UUID? {
        guard let folder = layout.folder(for: id), layout.folders.contains(where: { $0.id == folder }) else { return nil }
        return folder
    }

    private func sorted(_ items: [HostSessionRow]) -> [HostSessionRow] {
        items.sorted { left, right in
            let lhs = timestamp(left) ?? .min, rhs = timestamp(right) ?? .min
            return lhs == rhs ? left.id < right.id : lhs > rhs
        }
    }

    /// This host's conversations in the chosen workspace (archived ones only while searching).
    private var listed: [HostSessionRow] {
        let scoped = scopedWorkspace
        return sorted(rows.filter { row in
            if query.isEmpty && archived.contains(row.id) { return false }
            return scoped?.sessionIDs.contains(row.id) ?? true
        })
    }

    private func matches(_ row: HostSessionRow) -> Bool {
        switch filter {
        case .all: true
        case .running: row.running
        case .waiting: waiting[row.id] != nil
        case .unread: history?.unread(row, current: host.sessionID) == true
        }
    }

    private func marker(_ row: HostSessionRow) -> DrawerMarker? {
        if let kind = waiting[row.id] { return .pending(kind) }
        if row.running { return .running }
        return history?.unread(row, current: host.sessionID) == true ? .unread : nil
    }

    private struct FolderBlock: Identifiable {
        let folder: ConversationFolder
        let items: [HostSessionRow]
        var id: UUID { folder.id }
    }

    private struct Blocks {
        var pinned: [HostSessionRow] = []
        var folders: [FolderBlock] = []
        var days: [DrawerSection: [HostSessionRow]] = [:]
    }

    /// 置顶 (the host's pin order), the folders (pinned members first), then by day.
    private func blocks(_ items: [HostSessionRow]) -> Blocks {
        var result = Blocks()
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pins = pinnedSet
        result.pinned = pinned.compactMap { id in folderOf(id) == nil ? byID[id] : nil }
        let filed = Dictionary(grouping: items.filter { folderOf($0.id) != nil }) { folderOf($0.id)! }
        for folder in layout.folders {
            let members = filed[folder.id] ?? []
            if members.isEmpty && scopedWorkspace != nil { continue }
            result.folders.append(FolderBlock(folder: folder, items: members.filter { pins.contains($0.id) } + members.filter { !pins.contains($0.id) }))
        }
        result.days = Dictionary(grouping: items.filter { folderOf($0.id) == nil && !pins.contains($0.id) }) { DrawerSection.period(date($0)) }
        return result
    }

    /// 全选 picks what is on screen (members of a closed folder are not).
    private func selectable(_ items: [HostSessionRow]) -> [String] {
        guard filter == .all, query.isEmpty else { return items.filter(matches).map(\.id) }
        let closed = Set(layout.folders.filter { $0.collapsed == true }.map(\.id))
        return items.filter { folderOf($0.id).map { !closed.contains($0) } ?? true }.map(\.id)
    }

    // MARK: Body

    var body: some View {
        let items = listed
        VStack(spacing: 0) {
            header(items)
            if !items.isEmpty || filter != .all {
                DrawerFilterBar(selection: $filter,
                                pending: items.filter { waiting[$0.id] != nil }.count,
                                unread: items.filter { history?.unread($0, current: host.sessionID) == true }.count)
            }
            List { content(items) }
                .listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 1)
            if let selection { selectionBar(selection, items) }
        }
        .overlay(alignment: .bottom) { DrawerNoticeBar(notice: $notice).animation(.easeOut(duration: 0.2), value: notice?.id) }
        .task(id: "\(scenePhase)/\(revision)") {
            guard scenePhase == .active else { return }
            await follow()
        }
        .task(id: ObjectIdentifier(host)) { deletable = (try? await host.checkDeletionSupport()) != nil }
        .confirmationDialog(confirming.map { $0.count == 1 ? String(localized: "永久删除「\($0[0].title)」？") : String(localized: "永久删除 \($0.count) 个对话？") } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { chosen in
            Button("永久删除", role: .destructive) { permanentlyDelete(chosen) }
        } message: { _ in Text("删除后无法恢复。") }
        .task(id: "\(revision)/\(scenePhase)/\(filter.rawValue)/\(query)/\(layout.byCreation)") {
            guard scenePhase == .active else { return }
            loading = true; error = nil; more = false
            if !query.isEmpty { rows = [] }
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                repeat {
                    try await refresh()
                    try await Task.sleep(for: .seconds(5))
                } while !Task.isCancelled
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; loading = false }
            }
        }
        .sheet(item: $sheet, onDismiss: { let next = afterSheet; afterSheet = nil; next?() }) { page in sheetContent(page, items) }
        #if os(macOS)
        .sheet(isPresented: $archivedPage, onDismiss: openRestoredSession) { archivedSearch }
        #else
        .fullScreenCover(isPresented: $archivedPage, onDismiss: openRestoredSession) { archivedSearch }
        #endif
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { row in
            TextField("对话标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { rename(row, to: renameText) }
        }
        .onChange(of: query) { _, _ in if selection != nil { selection = [] } }
        .onChange(of: filter) { _, _ in if selection != nil { selection = [] } }
    }

    private var archivedSearch: some View {
        HostSessionSearchPage(host: host, hostName: hostName, archivedOnly: true) { pendingOpen = $0 }
            .desktopSheet(width: 500, height: 420)
    }

    private func openRestoredSession() {
        if let id = pendingOpen { open(id) }
        pendingOpen = nil
    }

    @ViewBuilder private func header(_ items: [HostSessionRow]) -> some View {
        if let selection {
            let ids = selectable(items)
            let all = !ids.isEmpty && ids.allSatisfy(selection.contains)
            DrawerSelectionHeader(count: selection.count, allSelected: all, canSelectAll: !ids.isEmpty,
                                  toggleAll: { self.selection = all ? [] : Set(ids) }, done: { endSelection() })
        } else {
            HStack(spacing: 0) {
                if followReady {
                    Button { sheet = .workspaces } label: {
                        HStack(spacing: 8) {
                            Image(systemName: scopedWorkspace == nil ? "bubble.left.and.bubble.right" : "folder")
                                .font(.system(size: 15)).foregroundStyle(ChatColors.muted)
                            Text(verbatim: scopedWorkspace?.name ?? String(localized: "全部对话")).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(ChatColors.muted)
                        }.padding(.horizontal, 10).frame(minHeight: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(ChatColors.ink).padding(.leading, 10)
                        .accessibilityLabel(String(localized: "文件夹：") + (scopedWorkspace?.name ?? String(localized: "全部对话")) + String(localized: "。切换文件夹"))
                        .accessibilityIdentifier("drawerWorkspace")
                }
                Spacer(minLength: 0)
                if !items.isEmpty || filter != .all || !archived.isEmpty || !layout.folders.isEmpty {
                    Button { sheet = .list } label: {
                        Image(systemName: "ellipsis").font(.system(size: 17)).foregroundStyle(ChatColors.muted)
                            .frame(width: 44, height: 40).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("对话列表").padding(.trailing, 6)
                }
            }.frame(minHeight: 40)
        }
    }

    @ViewBuilder private func content(_ items: [HostSessionRow]) -> some View {
        if let archiveIssue {
            VStack(alignment: .leading, spacing: 4) {
                Text(archiveIssue).font(.caption).foregroundStyle(ChatColors.muted)
                Button("重新同步归档状态") { revision += 1 }.font(.caption.weight(.medium))
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        if let restoreIssue { issueLine(restoreIssue) }
        if let issue = layout.issue { issueLine(issue) }
        if let error, !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.caption).foregroundStyle(ChatColors.muted)
                Button("重试") { revision += 1 }.font(.caption.weight(.medium))
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        if rows.isEmpty && loading && error == nil {
            DrawerSkeleton()
        } else if rows.isEmpty, let error {
            DrawerEmptyView(symbol: "wifi.exclamationmark", title: String(localized: "对话列表加载失败"), message: error, action: (String(localized: "重试"), { revision += 1 }))
        } else if !query.isEmpty || filter != .all {
            let flat = items.filter(matches)
            if flat.isEmpty {
                let empty: (symbol: String, title: String) = query.isEmpty ? filter.empty : ("magnifyingglass", String(localized: "没有相关对话"))
                DrawerEmptyView(symbol: empty.symbol, title: empty.title)
            }
            ForEach(flat) { sessionRow($0) }
            if more { Text("设备还有更多匹配，请缩小搜索范围。").font(.caption).foregroundStyle(ChatColors.muted).listRowSeparator(.hidden).listRowBackground(Color.clear) }
        } else if items.isEmpty && (layout.folders.isEmpty || scopedWorkspace != nil) {
            if scopedWorkspace != nil {
                DrawerEmptyView(symbol: "folder", title: String(localized: "这里还没有对话"),
                                action: (String(localized: "全部对话"), { chooseWorkspace(nil) }))
            } else {
                DrawerEmptyView(symbol: "bubble.left.and.bubble.right", title: String(localized: "还没有对话"))
            }
        } else {
            grouped(blocks(items))
        }
    }

    private func issueLine(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(DrawerPalette.danger).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    @ViewBuilder private func grouped(_ blocks: Blocks) -> some View {
        if !blocks.pinned.isEmpty {
            DrawerEyebrow(String(localized: "置顶"))
            ForEach(blocks.pinned) { sessionRow($0) }
        }
        if !blocks.folders.isEmpty {
            DrawerEyebrow(String(localized: "文件夹"))
            ForEach(blocks.folders) { block in
                folderHeader(block.folder, count: block.items.count)
                if block.folder.collapsed != true {
                    if block.items.isEmpty {
                        Text("还没有对话").font(.caption).foregroundStyle(ChatColors.muted).frame(height: 36)
                            .listRowInsets(EdgeInsets(top: 0, leading: 50, bottom: 0, trailing: 20))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    ForEach(block.items) { sessionRow($0, inFolder: true) }
                }
            }
        }
        ForEach(DrawerSection.days, id: \.self) { day in
            if let items = blocks.days[day] {
                day.heading
                ForEach(items) { sessionRow($0) }
            }
        }
    }

    private func folderHeader(_ folder: ConversationFolder, count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { layout.setCollapsed(folder.id, folder.collapsed != true) }
        } label: { DrawerFolderLabel(folder: folder, count: count) }
            .foregroundStyle(ChatColors.ink)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            .accessibilityLabel(DrawerFolderLabel.spoken(folder, count: count))
            .accessibilityValue(folder.collapsed == true ? "已收起" : "已展开")
            .contextMenu {
                if selection == nil {
                    if newChat != nil {
                        Button { newChat(in: folder) } label: { Label("新对话", systemImage: "square.and.pencil") }
                    }
                    Button { sheet = .editFolder(folder) } label: { Label("编辑", systemImage: "pencil") }
                    Button(role: .destructive) { deleteFolder(folder) } label: { Label("删除文件夹", systemImage: "trash") }
                }
            }
    }

    private func sessionRow(_ row: HostSessionRow, inFolder: Bool = false) -> some View {
        let current = row.id == host.sessionID
        let chosen = selection?.contains(row.id)
        let pinnedMark = inFolder && pinnedSet.contains(row.id)
        let mark = marker(row)
        let isArchived = archived.contains(row.id)
        return Button {
            if selection != nil {
                if chosen == true { selection?.remove(row.id) } else { selection?.insert(row.id) }
            } else if isArchived { restore(row) }
            else { open(row.id) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                DrawerSessionLabel(title: row.title, current: current, selection: chosen, pinned: pinnedMark,
                                   marker: isArchived ? nil : mark, indent: inFolder ? 30 : 0,
                                   time: ConversationSearchView.dateLabel(row.updatedDate))
                if let snippet = row.snippet, snippet != row.title {
                    Text(snippet).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(2).padding(.bottom, 6)
                }
            }
        }
        .foregroundStyle(ChatColors.ink)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(DrawerRowFill(on: selection != nil ? chosen == true : current))
        .accessibilityLabel(DrawerSessionLabel.spoken(row.title, marker: isArchived ? nil : mark, pinned: pinnedMark) + (isArchived ? String(localized: "，已归档") : ""))
        .accessibilityIdentifier("hostSession-" + row.id)
        .accessibilityValue(current ? "当前对话" : "")
        .accessibilityAddTraits(chosen == true ? .isSelected : [])
        .contextMenu { if selection == nil { menu(row, isArchived: isArchived) } }
    }

    @ViewBuilder private func menu(_ row: HostSessionRow, isArchived: Bool) -> some View {
        if followReady && !isArchived {
            let on = pinnedSet.contains(row.id)
            Button { pin([row.id], !on) } label: { Label(on ? "取消置顶" : "置顶", systemImage: on ? "pin.slash" : "pin") }
        }
        Button { renameText = row.title; renaming = row } label: { Label("重命名", systemImage: "pencil") }
        Button { sheet = .move([row.id]) } label: {
            Label(folderOf(row.id) != nil ? "移到其他文件夹" : "移到文件夹", systemImage: "folder")
        }
        Button { share(row) } label: { Label("分享", systemImage: "square.and.arrow.up") }
        Button { startSelection([row.id]) } label: { Label("多选", systemImage: "checkmark.circle") }
        if isArchived {
            Button { restore(row) } label: { Label("恢复并打开", systemImage: "tray.and.arrow.up") }.disabled(!followReady || restoring != nil)
        } else {
            Button { archive([row]) } label: {
                Label { Text("归档"); Text("进行中的一轮会停止") } icon: { Image(systemName: "archivebox") }
            }.disabled(!followReady || archiveBusy)
        }
        if deletable {
            Button(role: .destructive) { confirming = [row] } label: { Label("永久删除", systemImage: "trash") }.disabled(archiveBusy || deleting)
        }
    }

    private func selectionBar(_ selection: Set<String>, _ items: [HostSessionRow]) -> some View {
        let chosen = items.filter { selection.contains($0.id) }
        let allPinned = !selection.isEmpty && selection.allSatisfy(pinnedSet.contains)
        return DrawerSelectionBar(any: !selection.isEmpty, allPinned: allPinned, canPin: followReady && !archiveBusy,
                                  canArchive: followReady && !archiveBusy && chosen.contains { !archived.contains($0.id) },
                                  canDelete: !archiveBusy && !deleting,
                                  move: { sheet = .move(selection) },
                                  pin: { pin(chosen.map(\.id), !allPinned, batch: true) },
                                  archive: { archive(chosen.filter { !archived.contains($0.id) }); endSelection() },
                                  delete: deletable ? { confirming = chosen; endSelection() } : nil)
    }

    @ViewBuilder private func sheetContent(_ page: DrawerSheet, _ items: [HostSessionRow]) -> some View {
        switch page {
        case .list:
            DrawerListSheet(byCreation: layout.byCreation, sort: { layout.sortByCreation($0) }, hasFolders: !layout.folders.isEmpty) { action in
                switch action {
                case .newFolder: afterSheet = { sheet = .newFolder([]) }
                case .manageFolders: afterSheet = { sheet = .manageFolders }
                case .archived: afterSheet = { archivedPage = true }
                case .select: afterSheet = { startSelection([]) }
                }
            }
        case .move(let ids):
            let homes = Set(ids.map(folderOf))
            DrawerFolderPicker(folders: layout.folders,
                               counts: Dictionary(grouping: items.compactMap { folderOf($0.id) }, by: { $0 }).mapValues(\.count),
                               current: homes.count == 1 ? homes.first ?? nil : nil, anyFiled: homes.contains { $0 != nil }) { pick in
                switch pick {
                case .folder(let id): move(ids, to: id)
                case .none: move(ids, to: nil)
                case .new: afterSheet = { sheet = .newFolder(ids) }
                }
            }
        case .newFolder(let ids):
            FolderEditor(chat: layout, folder: ConversationFolder(name: "")) { id in if !ids.isEmpty { move(ids, to: id) } }
        case .editFolder(let folder): FolderEditor(chat: layout, folder: folder)
        case .manageFolders: FolderManager(chat: layout, createImmediately: false)
        case .workspaces:
            DrawerWorkspaceSheet(workspaces: workspaces, selected: scopedWorkspace?.id,
                                 total: rows.filter { !archived.contains($0.id) }.count,
                                 counts: workspaces.reduce(into: [:]) { counts, workspace in
                                     counts[workspace.id] = rows.filter { workspace.sessionIDs.contains($0.id) && !archived.contains($0.id) }.count
                                 },
                                 pick: { chooseWorkspace($0) },
                                 add: { afterSheet = { sheet = .addWorkspace } },
                                 manage: manageWorkspaces.map { manage in { afterSheet = manage } })
        case .addWorkspace:
            HostDirectoryPicker(host: host) { added in
                sheet = nil
                guard let added else { return }
                chooseWorkspace(added.id)
                notice = DrawerNotice(text: String(localized: "已添加「") + added.name + String(localized: "」"))
            }
        }
    }

    // MARK: Actions

    private func startSelection(_ ids: Set<String>) { selection = ids; selectionChanged(true) }
    private func permanentlyDelete(_ chosen: [HostSessionRow]) {
        deleting = true
        Task {
            let (gone, failures) = await HostDeletion.remove(chosen, from: host, scope: scope)
            rows.removeAll { gone.contains($0.id) }
            deleting = false
            if !gone.isEmpty { deleted(gone) }
            if let failure = failures.first { notice = DrawerNotice(text: failure) }
            else { notice = DrawerNotice(text: gone.count == 1 ? String(localized: "已永久删除「\(chosen[0].title)」") : String(localized: "已永久删除 \(gone.count) 个对话")) }
        }
    }

    private func endSelection() { selection = nil; selectionChanged(false) }

    private func pin(_ ids: [String], _ on: Bool, batch: Bool = false) {
        Task {
            let order = on ? Array(ids.reversed().filter { !pinnedSet.contains($0) }) : ids
            var done = 0
            for id in order {
                do {
                    let reply = try await host.call(on ? "workspace/pinSession" : "workspace/unpinSession", ["sessionId": id])
                    guard let list = reply["pinnedSessionIds"] as? [String] else { throw HostError(String(localized: "没收到设备的确认，置顶可能没生效。刷新后看看。")) }
                    pinned = list
                    done += 1
                } catch { continue }
            }
            if batch { endSelection() }
            if done == 0 && !order.isEmpty { notice = DrawerNotice(text: on ? String(localized: "没能置顶，稍后再试") : String(localized: "没能取消置顶，稍后再试")) }
            else if batch { notice = DrawerNotice(text: on ? String(localized: "已置顶 \(done) 个对话") : String(localized: "已取消置顶 \(done) 个对话")) }
        }
    }

    private func rename(_ row: HostSessionRow, to text: String) {
        let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty, title != row.title else { return }
        Task {
            do {
                let result = try await host.call("session/rename", ["sessionId": row.id, "title": title])
                guard let confirmed = result["title"] as? String, !confirmed.isEmpty, result["seq"] as? Int != nil else {
                    throw HostError(String(localized: "没收到设备的确认，重命名可能没生效。刷新后看看。"))
                }
                revision += 1
            } catch { notice = DrawerNotice(text: String(localized: "没能重命名，稍后再试")) }
        }
    }

    private func move(_ ids: Set<String>, to folder: UUID?) {
        let before = Dictionary(ids.map { ($0, layout.folder(for: $0)) }, uniquingKeysWith: { first, _ in first })
        layout.move(ids, to: folder)
        if selection != nil { endSelection() }
        let name = folder.flatMap { id in layout.folders.first { $0.id == id }?.name }
        notice = DrawerNotice(text: name.map { String(localized: "已移到「") + $0 + String(localized: "」") } ?? String(localized: "已移出文件夹")) { [layout] in layout.restoreAssignments(before) }
    }

    private func deleteFolder(_ folder: ConversationFolder) {
        guard let removed = layout.removeFolderForUndo(folder.id) else { return }
        notice = DrawerNotice(text: String(localized: "已删除「") + folder.name + String(localized: "」")) { [layout] in layout.restoreFolder(removed) }
    }

    private func newChat(in folder: ConversationFolder) {
        layout.fileNextSession(in: folder.id, known: Set(rows.map(\.id)), current: host.sessionID)
        newChat?()
    }

    private func restore(_ row: HostSessionRow) {
        guard followReady, restoring == nil else { return }
        restoring = row.id; restoreIssue = nil
        Task {
            defer { restoring = nil }
            do {
                try await host.setArchived(false, session: row.id)
                open(row.id)
            } catch { restoreIssue = String(localized: "没能恢复「") + row.title + String(localized: "」，稍后再试。") }
        }
    }

    /// The host's archived set, pins and workspaces: the baseline, then its changes.
    private func follow() async {
        followReady = false
        do {
            let stream = try await host.stream("workspace/follow", args: [:])
            defer { stream.cancel() }
            while !Task.isCancelled {
                let frame = try await stream.next()
                try Task.checkCancellation()
                switch frame["type"] as? String {
                case "baseline", "replace":
                    let value = frame["value"] as? Object ?? [:]
                    guard let ids = value["archivedSessionIds"] as? [String] else { throw HostError(String(localized: "设备未提供归档状态。")) }
                    archived = Set(ids)
                    pinned = value["pinnedSessionIds"] as? [String] ?? []
                    workspaces = (value["items"] as? [Any] ?? []).compactMap(DrawerWorkspace.init)
                    followReady = true; archiveIssue = nil
                    moveLegacyPins()
                case "archived":
                    guard let ids = frame["archivedSessionIds"] as? [String] else { throw HostError(String(localized: "设备未提供归档状态。")) }
                    archived = Set(ids)
                case "pinned":
                    if let ids = frame["pinnedSessionIds"] as? [String] { pinned = ids }
                case "upsert":
                    guard let workspace = DrawerWorkspace(frame["workspace"]) else { continue }
                    if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) { workspaces[index] = workspace }
                    else { workspaces.append(workspace) }
                case "remove":
                    workspaces.removeAll { $0.id == frame["workspaceId"] as? String }
                case "order":
                    if let ids = frame["workspaceIds"] as? [String] {
                        workspaces.sort { (ids.firstIndex(of: $0.id) ?? .max) < (ids.firstIndex(of: $1.id) ?? .max) }
                    }
                default: continue
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            followReady = false; archiveIssue = String(localized: "无法同步设备归档状态。") + error.localizedDescription
        }
    }

    /// Pins used to live on this phone only; they now belong to the host (shared with DSH Web).
    private func moveLegacyPins() {
        let legacy = layout.legacyPins
        guard !legacy.isEmpty else { return }
        layout.setPinned(legacy, false)
        let order = legacy.subtracting(pinnedSet).subtracting(archived).sorted()
        guard !order.isEmpty else { return }
        Task {
            for id in order {
                if let reply = try? await host.call("workspace/pinSession", ["sessionId": id]),
                   let list = reply["pinnedSessionIds"] as? [String] { pinned = list }
            }
        }
    }

    private func refresh() async throws {
        let all = try await HostSessionRow.list(host)
        var pending: [String: String] = [:]
        var statusError: String?
        let candidates = all.filter { $0.available && (filter == .waiting || $0.running) }
        if !candidates.isEmpty {
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for row in candidates {
                try Task.checkCancellation()
                let input: [String]
                do {
                    let state = try await host.call("session/state", ["sessionId": row.id])
                    guard let kinds = state["pendingInput"] as? [String] else { throw HostError(String(localized: "设备未提供待确认状态。")) }
                    input = kinds
                } catch {
                    try Task.checkCancellation()
                    statusError = String(localized: "未能读取全部待确认状态。") + error.localizedDescription
                    break
                }
                if input.contains("approval") || input.contains("question") {
                    var owner = row, path = Set<String>()
                    while owner.subagent, let parent = owner.parent.flatMap({ byID[$0] }), path.insert(owner.id).inserted { owner = parent }
                    if pending[owner.id] != String(localized: "待确认") { pending[owner.id] = input.contains("approval") ? String(localized: "待确认") : String(localized: "待回答") }
                }
            }
        }
        var results = all.filter { !$0.subagent && !($0.blank && $0.id != host.sessionID) }
        var truncated = false
        if !query.isEmpty {
            var snippets: [String: String] = [:]
            do {
                let search = try await host.call("session/search", ["query": query])
                guard let hits = search["items"] as? [Object] else { throw HostError(String(localized: "设备未返回搜索结果。")) }
                for hit in hits {
                    if let id = hit["sessionId"] as? String, let text = hit["snippet"] as? String { snippets[id] = ConversationSearchView.plainSnippet(text) }
                }
                truncated = search["hasMore"] as? Bool == true
            } catch {
                try Task.checkCancellation()
                statusError = String(localized: "内容搜索失败，仅显示标题匹配")
            }
            results = results.compactMap { row in
                var row = row
                row.snippet = snippets[row.id]
                return row.snippet != nil || row.title.localizedCaseInsensitiveContains(query) ? row : nil
            }
        }
        try Task.checkCancellation()
        if layout.byCreation {
            for index in results.indices where results[index].created == nil {
                try Task.checkCancellation()
                let id = results[index].id
                if creationTimes[id] == nil {
                    do { creationTimes[id] = try await results[index].creationTime(on: host) }
                    catch {
                        try Task.checkCancellation()
                        statusError = String(localized: "部分对话的创建时间不可用。") + (statusError ?? "")
                    }
                }
                results[index].created = creationTimes[id]
            }
        }
        try Task.checkCancellation()
        history = HostReadHistory.update(all, current: host.sessionID, scope: scope)
        layout.fileNewSession(host.sessionID)
        rows = results; waiting = pending; more = truncated; error = statusError; loading = false
    }
}

// MARK: - 搜索对话

/// One conversation the search page can find.
struct ConversationSearchEntry: Identifiable {
    let id: String
    let title: String
    let updated: Date
    let running: Bool
    let archived: Bool
    let folder: String?
}

/// Where the search page looks: a host (titles here, content via `session/search`) or this phone.
enum ConversationSearchSource {
    case host(Harness)
}

/// 「搜索对话」 over the active host's conversations: titles match as you type,
/// the host's message-content search adds hits with an excerpt, archived ones
/// come last and are restored before opening. Hands the picked session id to
/// [open] and closes itself.
struct HostSessionSearchPage: View {
    let host: Harness
    var hostName = String(localized: "我的电脑")
    var archivedOnly = false
    let open: (String) -> Void

    var body: some View {
        ConversationSearchView(source: .host(host), hostName: hostName, archivedOnly: archivedOnly, open: open)
    }
}

struct ConversationSearchView: View {
    let source: ConversationSearchSource
    let hostName: String
    let archivedOnly: Bool
    let open: (String) -> Void

    private enum Content: Equatable { case idle, pending, ready(more: Bool), unsupported, failed }
    private struct Hit: Identifiable {
        let entry: ConversationSearchEntry
        let snippet: String?
        var id: String { entry.id }
    }

    @Environment(\.dismiss) private var dismiss
    /// 外壳以淡入页打开时由它收起（淡出），否则照常 dismiss。
    @Environment(\.closeSearch) private var closeSearch
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var entries: [ConversationSearchEntry]?
    @State private var loadIssue: String?
    @State private var attempt = 0
    @State private var hits: [(id: String, snippet: String)] = []
    @State private var hitsQuery = ""
    @State private var content = Content.idle
    @State private var restoreTarget: ConversationSearchEntry?
    @State private var restoreIssue: String?
    @State private var restoring = false

    private var trimmed: String { String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
    private var terms: [String] {
        var out: [String] = []
        for term in trimmed.split(whereSeparator: \.isWhitespace).map(String.init) where !out.contains(where: { $0.compare(term, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }) {
            out.append(term)
        }
        return out
    }
    private var current: String? {
        switch source {
        case .host(let host): host.sessionID
        }
    }

    private func close() {
        if let closeSearch { closeSearch() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ChatIcon(label: String(localized: "返回"), symbol: "arrow.left") { close() }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ChatColors.muted)
                    TextField(archivedOnly ? "已归档" : "搜索对话", text: $query).font(.system(size: 15))
                        .textFieldStyle(.plain).focused($focused).submitLabel(.search).onSubmit { focused = false }
                        .autocorrectionDisabled().accessibilityIdentifier("conversationSearchField")
                    if !query.isEmpty {
                        Button { query = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(ChatColors.muted)
                        }.buttonStyle(.plain).accessibilityLabel("清除")
                    }
                }.padding(.horizontal, 13).frame(height: 44).chatCapsule()
            }.foregroundStyle(ChatColors.ink).padding(.horizontal, 12).padding(.vertical, 6)
            results
        }
        .background(ChatColors.canvas.ignoresSafeArea())
        .task(id: attempt) { await load() }
        .task(id: "\(trimmed)/\(attempt)") { await searchContent(trimmed) }
        .onAppear { if !archivedOnly { focused = true } }
        .sheet(item: $restoreTarget) { entry in restoreSheet(entry) }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if entries == nil, let loadIssue {
            notice("wifi.exclamationmark", String(localized: "对话列表加载失败"), loadIssue, action: (String(localized: "重试"), { self.loadIssue = nil; attempt += 1 }))
        } else if trimmed.isEmpty && !archivedOnly {
            notice("magnifyingglass", String(localized: "搜索「") + hostName + String(localized: "」上的对话"),
                   content == .unsupported ? String(localized: "按标题查找，含已归档的对话") : String(localized: "按标题和内容查找，含已归档的对话"))
        } else if let entries {
            let (active, archived) = derive(entries)
            if archivedOnly && trimmed.isEmpty && archived.isEmpty {
                notice("archivebox", String(localized: "已归档"), String(localized: "还没有对话"))
            } else if active.isEmpty && archived.isEmpty {
                if content == .pending { footer.padding(.top, 12); Spacer() }
                else {
                    ScrollView {
                        notice("magnifyingglass", String(localized: "没有相关对话"), nil)
                        footer.frame(maxWidth: .infinity)
                    }.scrollDismissesKeyboard(.interactively)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(active) { row($0) }
                        if !archived.isEmpty {
                            Text("已归档").font(.caption.weight(.medium)).foregroundStyle(ChatColors.muted)
                                .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
                            ForEach(archived) { row($0) }
                        }
                        footer
                    }.padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 24)
                }.scrollDismissesKeyboard(.interactively)
            }
        } else {
            notice("hourglass", String(localized: "正在加载对话…"), nil)
        }
    }

    @ViewBuilder private var footer: some View {
        switch content {
        case .pending:
            HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("正在搜索消息内容…") }
                .font(.caption).foregroundStyle(ChatColors.muted).padding(.horizontal, 12).padding(.top, 14)
        case .unsupported:
            Text("这台设备仅支持按标题搜索").font(.caption).foregroundStyle(ChatColors.muted).padding(.horizontal, 12).padding(.top, 14)
        case .failed:
            HStack(spacing: 8) {
                Text("内容搜索失败，仅显示标题匹配")
                Button("重试") { attempt += 1 }.font(.caption.weight(.medium))
            }.font(.caption).foregroundStyle(ChatColors.muted).padding(.horizontal, 12).padding(.top, 14)
        default: EmptyView()
        }
    }

    private func notice(_ symbol: String, _ title: String, _ body: String?, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(ChatColors.muted).padding(.bottom, 4)
            Text(verbatim: title).font(.headline).foregroundStyle(ChatColors.ink).multilineTextAlignment(.center)
            if let body { Text(body).font(.subheadline).foregroundStyle(ChatColors.muted).multilineTextAlignment(.center) }
            if let action { Button(action.0, action: action.1).padding(.top, 4) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 32).padding(.top, 56).frame(maxWidth: .infinity)
    }

    private func row(_ hit: Hit) -> some View {
        let entry = hit.entry
        let on = entry.id == current
        let date = Self.dateLabel(entry.updated)
        let excerpt = hit.snippet.flatMap { $0.isEmpty ? nil : Self.excerpt($0, terms: terms) }
        let spoken: [String?] = [entry.title, entry.running ? String(localized: "正在运行") : nil, entry.archived ? String(localized: "已归档") : nil, date, excerpt]
        return Button {
            if entry.archived { restoreIssue = nil; restoreTarget = entry } else { pick(entry.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(Self.highlight(entry.title, terms: terms)).font(.system(size: 15, weight: on ? .semibold : .medium))
                        .foregroundStyle(entry.archived ? ChatColors.muted : ChatColors.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.running { DrawerBusyDot() }
                    Text(date).font(.caption2.monospacedDigit()).foregroundStyle(ChatColors.muted)
                }
                if let folder = entry.folder {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(Self.highlight(folder, terms: terms)).lineLimit(1)
                    }.font(.caption).foregroundStyle(ChatColors.muted)
                }
                if let excerpt {
                    Text(Self.highlight(excerpt, terms: terms)).font(.system(size: 13)).foregroundStyle(ChatColors.muted).lineLimit(2)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 11).frame(maxWidth: .infinity, alignment: .leading)
            .background(DrawerRowFill(on: on).padding(.horizontal, -10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.compactMap { $0 }.joined(separator: String(localized: "，")))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("searchResult-" + entry.id)
    }

    private func restoreSheet(_ entry: ConversationSearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: entry.title).font(.headline).foregroundStyle(ChatColors.ink).lineLimit(2)
            Text("已归档的对话需先恢复，才能打开").font(.subheadline).foregroundStyle(ChatColors.muted)
            Button { restore(entry) } label: {
                HStack {
                    if restoring { ProgressView() } else { Image(systemName: "tray.and.arrow.up") }
                    Text("恢复并打开")
                    Spacer()
                }.padding(.horizontal, 16).frame(minHeight: 48).foregroundStyle(ChatColors.ink)
                    .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }.buttonStyle(.plain).disabled(restoring).padding(.top, 6)
            if let restoreIssue { Text(restoreIssue).font(.footnote).foregroundStyle(DrawerPalette.danger) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.panel.ignoresSafeArea())
        .presentationDetents([.height(230)])
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .desktopSheet(width: 380, height: 210)
        #endif
    }

    // MARK: Data

    private func load() async {
        switch source {
        case .host(let host):
            do {
                let rows = try await HostSessionRow.list(host).filter { !$0.subagent && !$0.blank }
                let stream = try await host.stream("workspace/follow", args: [:])
                defer { stream.cancel() }
                let frame = try await stream.next()
                guard frame["type"] as? String == "baseline",
                      let ids = (frame["value"] as? Object)?["archivedSessionIds"] as? [String] else { throw HostError(String(localized: "设备未提供归档状态。")) }
                let archived = Set(ids)
                let folders = Set(rows.map { Self.folderLabel($0.cwd) })
                entries = rows.map { row in
                    ConversationSearchEntry(id: row.id, title: row.title, updated: row.updatedDate, running: row.running,
                                            archived: archived.contains(row.id), folder: folders.count > 1 ? Self.folderLabel(row.cwd) : nil)
                }
                loadIssue = nil
            } catch {
                if !Task.isCancelled { loadIssue = HostError.explain(error) }
            }
        }
    }

    private func searchContent(_ text: String) async {
        guard case .host(let host) = source else { return }
        guard !text.isEmpty else { if content != .unsupported { content = .idle }; hits = []; return }
        guard content != .unsupported else { return }
        content = .pending
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        do {
            let reply = try await host.call("session/search", ["query": text])
            guard let items = reply["items"] as? [Object] else { throw HostError(String(localized: "设备未返回搜索结果。")) }
            try Task.checkCancellation()
            hits = items.compactMap { item in
                guard let id = item["sessionId"] as? String else { return nil }
                return (id, item["snippet"] as? String ?? "")
            }
            hitsQuery = text
            content = .ready(more: reply["hasMore"] as? Bool == true)
        } catch {
            guard !Task.isCancelled else { return }
            let reason = (error as? HostError).map { [$0.message, $0.detail ?? "", $0.code ?? ""].joined(separator: " ") } ?? error.localizedDescription
            content = reason.localizedCaseInsensitiveContains("disabled") ? .unsupported : .failed
        }
    }

    private func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .widthInsensitive]) != nil
    }

    /// Title matches (newest first), then the host's content-only hits in its order; archived apart.
    private func derive(_ all: [ConversationSearchEntry]) -> (active: [Hit], archived: [Hit]) {
        let words = terms
        if archivedOnly && words.isEmpty {
            return ([], all.filter(\.archived).sorted { $0.updated > $1.updated }.map { Hit(entry: $0, snippet: nil) })
        }
        guard !words.isEmpty else { return ([], []) }
        var snippets: [String: String] = [:]
        if Self.sameQuery(hitsQuery, trimmed) {
            for hit in hits where snippets[hit.id] == nil { snippets[hit.id] = Self.plainSnippet(hit.snippet) }
        }
        func section(_ members: [ConversationSearchEntry]) -> [Hit] {
            let byTitle = members.filter { entry in
                let haystack = entry.title + "\n" + (entry.folder ?? "")
                return words.allSatisfy { contains(haystack, $0) }
            }.sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
            let included = Set(byTitle.map(\.id))
            let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // The host ranks by its own tokens, so "1+1" can put a hit on "1" first; whole-phrase hits go ahead, host order otherwise.
            let phrase = words.joined(separator: " ")
            let order = hits.enumerated().sorted { a, b in
                let x = snippets[a.element.id].map { contains($0, phrase) } ?? false
                let y = snippets[b.element.id].map { contains($0, phrase) } ?? false
                return x != y ? x : a.offset < b.offset
            }.map(\.element.id)
            var seen = included
            let byContent = order.compactMap { id -> ConversationSearchEntry? in
                guard snippets[id] != nil, let entry = byID[id], seen.insert(id).inserted else { return nil }
                return entry
            }
            return (byTitle + byContent).map { Hit(entry: $0, snippet: snippets[$0.id]) }
        }
        let archived = section(all.filter(\.archived))
        return (archivedOnly ? [] : section(all.filter { !$0.archived }), archived)
    }

    private func pick(_ id: String) {
        open(id)
        close()
    }

    private func restore(_ entry: ConversationSearchEntry) {
        guard !restoring else { return }
        guard case .host(let host) = source else {
            restoreTarget = nil; pick(entry.id); return
        }
        restoring = true; restoreIssue = nil
        Task {
            defer { restoring = false }
            do {
                try await host.setArchived(false, session: entry.id)
                restoreTarget = nil
                pick(entry.id)
            } catch { restoreIssue = String(localized: "没能恢复，稍后再试") }
        }
    }

    // MARK: Formatting

    static func sameQuery(_ a: String, _ b: String) -> Bool {
        func key(_ text: String) -> String { text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return key(a) == key(b)
    }

    /// Last path segment of a session's working directory.
    static func folderLabel(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let trimmed = cwd.replacingOccurrences(of: #"[/\\]+$"#, with: "", options: .regularExpression)
        if trimmed.isEmpty { return "/" }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? trimmed
    }

    /// The time today, 昨天, M月d日 this year, else yyyy/M/d.
    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let diff = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if diff <= 0 { return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) }
        if diff == 1 { return String(localized: "昨天") }
        if parts.year == calendar.component(.year, from: now) { return String(localized: "\(parts.month ?? 0)月\(parts.day ?? 0)日") }
        return "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    /// The host centres its match about 80 characters in; start a little before the first one.
    /// The host's excerpt is index text: Markdown marks kept and a space put around every CJK punctuation mark.
    static func plainSnippet(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            (#"```[A-Za-z0-9_+-]*"#, " "),                     // code fences, with their language tag
            (#"\[([^\]]*)\]\(<?[^)>]*>?\)"#, "$1"),          // [label](<path>) → label
            (#"\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?"#, " "), // table rules |---|---:|
            (#"(\*\*|__|`)"#, ""),                            // bold and inline code marks
            (#"(^|\s)#{1,6}\s+"#, "$1"),                       // headings
            (#"\s+([，。、；：？！）」』】》,.;:?!)])"#, "$1"),    // no space before closing punctuation
            (#"([（「『【《(])\s+"#, "$1"),                      // nor after opening
            (#"(\p{Han})\s+(?=\p{Han})"#, "$1"),               // nor between two Han characters
            (#"([，。、；：？！])\s+"#, "$1"),                    // nor after CJK punctuation
            (#"\s*\|\s*"#, " · "),                              // table cells
            (#"(·\s*){2,}"#, "· "),
            (#"\s{2,}"#, " "),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "·")))
            .replacingOccurrences(of: #"^·\s*"#, with: "", options: .regularExpression)
    }

    static func excerpt(_ text: String, terms: [String]) -> String {
        let first = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .widthInsensitive])?.lowerBound }.min()
        guard let first, text.distance(from: text.startIndex, to: first) > 15 else { return text }
        var cut = text.index(first, offsetBy: -14)
        if let space = text[cut..<first].firstIndex(of: " "), text.distance(from: cut, to: space) <= 8 { cut = text.index(after: space) }
        return "…" + text[cut...]
    }

    static func highlight(_ text: String, terms: [String]) -> AttributedString {
        var output = AttributedString(text)
        for term in terms where !term.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let found = text.range(of: term, options: [.caseInsensitive, .widthInsensitive], range: start..<text.endIndex) {
                if let range = Range(found, in: output) {
                    output[range].foregroundColor = .accentColor
                    output[range].inlinePresentationIntent = .stronglyEmphasized
                }
                start = found.upperBound
            }
        }
        return output
    }
}

// MARK: - 永久删除

enum HostDeletion {
    /// Deletes one by one; a refusal of one conversation leaves the rest going, anything else stops the batch.
    @MainActor static func remove(_ rows: [HostSessionRow], from host: Harness, scope: String) async -> (deleted: Set<String>, failures: [String]) {
        var deleted = Set<String>()
        var failures: [String] = []
        for (index, row) in rows.enumerated() {
            do {
                try await host.deleteSession(row.id)
                deleted.insert(row.id)
            } catch {
                failures.append("「" + row.title + "」" + error.localizedDescription)
                if !["session-active", "session-related", "writer-held", "not-found"].contains((error as? HostError)?.code ?? "") {
                    let remaining = rows.count - index - 1
                    if remaining > 0 { failures.append(String(localized: "剩余 \(remaining) 个对话未删除。")) }
                    break
                }
            }
        }
        if !deleted.isEmpty {
            try? HostReadHistory.forgetDeleted(deleted, scope: scope)
            ConversationIndex.shared.remove(deleted, scope: scope)
        }
        return (deleted, failures)
    }
}
