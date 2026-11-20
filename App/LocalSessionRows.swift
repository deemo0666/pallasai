import SwiftUI

// MARK: - Drawer chrome shared by the host and local lists

/// What a row shows at its end: one marker at most.
enum DrawerMarker: Equatable {
    case pending(String), running, unread

    var spoken: String {
        switch self {
        case .pending(let text): text
        case .running: String(localized: "正在运行")
        case .unread: String(localized: "未读")
        }
    }
}

enum DrawerPalette {
    static let warning = ChatColors.adaptive(0x936123, 0xe6bd7c)
    static let danger = ChatColors.adaptive(0xb3261e, 0xf2b8b5)
    static let pill = ChatColors.adaptive(0x446caa, 0xa1baf3)
    static let onPill = ChatColors.adaptive(0xffffff, 0x172335)
}

/// A small, faint section label on the rows' text line (置顶, 文件夹, 今天 …).
struct DrawerEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(ChatColors.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}

/// The breathing dot of a conversation that is working.
struct DrawerBusyDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    var body: some View {
        Circle().fill(.tint).frame(width: 7, height: 7).opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// The soft fill behind the open (or chosen) conversation.
struct DrawerRowFill: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(on ? ChatColors.selected : Color.clear)
            .padding(.horizontal, 10)
    }
}

/// One conversation row: the title (bold when it is the open one), a pin inside
/// folders, then 待确认 / a breathing dot / an unread dot. A check slides in
/// before the title while choosing.
struct DrawerSessionLabel: View {
    let title: String
    var current = false
    var selection: Bool?
    var pinned = false
    var marker: DrawerMarker?
    var indent: CGFloat = 0
    /// Shown on the right when there is no status to show.
    var time: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            if let selected = selection { DrawerCheck(on: selected).padding(.trailing, 10) }
            Text(verbatim: title).font(.system(size: 15, weight: current && selection == nil ? .semibold : .regular))
                .foregroundStyle(ChatColors.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(ChatColors.muted)
                    .padding(.leading, 8).accessibilityHidden(true)
            }
            switch marker {
            case .pending(let text):
                Text(text).font(.footnote.weight(.medium)).foregroundStyle(SettingsStyle.warning).padding(.leading, 10)
            case .running: DrawerBusyDot().padding(.leading, 10)
            case .unread: Circle().fill(ChatColors.muted).frame(width: 7, height: 7).padding(.leading, 10)
            case nil:
                if let time, selection == nil {
                    Text(verbatim: time).font(.footnote).foregroundStyle(ChatColors.muted).padding(.leading, 10)
                }
            }
        }
        .padding(.leading, indent).frame(minHeight: 44).contentShape(Rectangle())
    }

    static func spoken(_ title: String, marker: DrawerMarker?, pinned: Bool) -> String {
        ([title, marker?.spoken, pinned ? String(localized: "已置顶") : nil] as [String?]).compactMap { $0 }.joined(separator: String(localized: "，"))
    }
}

/// The 20pt ring before a title while choosing; filled with ink once chosen.
struct DrawerCheck: View {
    let on: Bool
    var body: some View {
        ZStack {
            if on {
                Circle().fill(ChatColors.ink)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ChatColors.panel)
            } else {
                Circle().strokeBorder(ChatColors.muted.opacity(0.55), lineWidth: 1.5)
            }
        }.frame(width: 20, height: 20).accessibilityHidden(true)
    }
}

/// A folder's row: its mark, the name, the member count and a chevron that
/// turns as the folder opens.
struct DrawerFolderLabel: View {
    let folder: ConversationFolder
    let count: Int
    var body: some View {
        HStack(spacing: 0) {
            folder.mark.frame(width: 20)
            Text(verbatim: folder.name).font(.system(size: 15, weight: .medium)).foregroundStyle(ChatColors.ink).lineLimit(1)
                .padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
            if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted).padding(.trailing, 6) }
            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(ChatColors.muted)
                .rotationEffect(.degrees(folder.collapsed == true ? -90 : 0))
        }.frame(minHeight: 44).contentShape(Rectangle())
    }

    static func spoken(_ folder: ConversationFolder, count: Int) -> String {
        count == 0 ? String(localized: "文件夹「") + folder.name + String(localized: "」") : String(localized: "文件夹「") + folder.name + String(localized: "」，\(count) 个对话")
    }
}

/// 全部 / 运行中 / 待确认 N / 未读 N as quiet capsules.
struct DrawerFilterBar: View {
    @Binding var selection: RemoteSessionFilter
    var options = RemoteSessionFilter.allCases
    var pending = 0
    var unread = 0

    private func label(_ value: RemoteSessionFilter) -> String {
        switch value {
        case .waiting where pending > 0: value.rawValue.localized + " \(pending)"
        case .unread where unread > 0: value.rawValue.localized + " \(unread)"
        default: value.rawValue.localized
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { value in
                    Button { selection = value } label: {
                        Text(label(value)).font(.subheadline.weight(.medium)).monospacedDigit()
                            .padding(.horizontal, 13).frame(minHeight: 32)
                            .foregroundStyle(value == selection ? ChatColors.panel : ChatColors.muted)
                            .background(value == selection ? ChatColors.ink : ChatColors.muted.opacity(0.12), in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(value.rawValue.localized)
                        .accessibilityValue(label(value) == value.rawValue.localized ? "" : label(value))
                        .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }.padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
        }
    }
}

/// While choosing: 全选 · 已选 N 个 · 完成.
struct DrawerSelectionHeader: View {
    let count: Int
    let allSelected: Bool
    let canSelectAll: Bool
    let toggleAll: () -> Void
    let done: () -> Void

    var body: some View {
        ZStack {
            Text(count == 0 ? "选择对话" : "已选 \(count) 个").font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(ChatColors.ink).accessibilityAddTraits(.updatesFrequently)
            HStack {
                Button(allSelected ? "取消全选" : "全选", action: toggleAll).font(.subheadline.weight(.medium))
                    .foregroundStyle(canSelectAll ? ChatColors.ink : ChatColors.muted).disabled(!canSelectAll)
                    .padding(.horizontal, 10).frame(minHeight: 36)
                Spacer()
                Button(action: done) {
                    Text("完成").font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 36)
                        .foregroundStyle(DrawerPalette.onPill).background(DrawerPalette.pill, in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 10).padding(.vertical, 4)
    }
}

/// While choosing: 移到文件夹 · 置顶 · 归档, icon over label.
struct DrawerSelectionBar: View {
    let any: Bool
    let allPinned: Bool
    var canPin = true
    var canArchive = true
    var canDelete = true
    let move: () -> Void
    let pin: () -> Void
    let archive: () -> Void
    var delete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            key("folder", String(localized: "移到文件夹"), any, move)
            key(allPinned ? "pin.slash" : "pin", allPinned ? String(localized: "取消置顶") : String(localized: "置顶"), any && canPin, pin)
            key("archivebox", String(localized: "归档"), any && canArchive, archive)
            if let delete { key("trash", String(localized: "删除"), any && canDelete, delete, destructive: true) }
        }.padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
    }

    private func key(_ symbol: String, _ label: String, _ enabled: Bool, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(label).font(.system(size: 11)).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                .foregroundStyle(destructive ? DrawerPalette.danger : ChatColors.ink)
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.38).accessibilityLabel(label)
    }
}

/// A brief notice over the drawer's bottom edge, with 撤销 when it can be undone.
struct DrawerNotice: Identifiable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)?
}

struct DrawerNoticeBar: View {
    @Binding var notice: DrawerNotice?
    var body: some View {
        if let current = notice {
            HStack(spacing: 12) {
                Text(current.text).font(.subheadline).foregroundStyle(ChatColors.panel).lineLimit(2)
                Spacer(minLength: 0)
                if let undo = current.undo {
                    Button("撤销") { undo(); notice = nil }.font(.subheadline.weight(.semibold)).foregroundStyle(ChatColors.panel)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(ChatColors.ink.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: current.id) {
                try? await Task.sleep(for: .seconds(4))
                if notice?.id == current.id { withAnimation { notice = nil } }
            }
        }
    }
}

/// An empty or failed list, a little above the middle.
struct DrawerEmptyView: View {
    let symbol: String
    let title: String
    var message: String?
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(ChatColors.muted).padding(.bottom, 4)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(ChatColors.ink).multilineTextAlignment(.center)
            if let message { Text(message).font(.footnote).foregroundStyle(ChatColors.muted).multilineTextAlignment(.center) }
            if let action { Button(action.label, action: action.run).font(.subheadline.weight(.medium)).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 48)
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

/// Loading: a few quiet placeholder rows on the same grid as the real ones.
struct DrawerSkeleton: View {
    @State private var dim = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(ChatColors.muted.opacity(0.14)).frame(width: 28, height: 8).padding(.top, 19).padding(.bottom, 9)
            ForEach([0.72, 0.5, 0.64, 0.42, 0.58], id: \.self) { width in
                GeometryReader { box in
                    Capsule().fill(ChatColors.muted.opacity(0.14)).frame(width: box.size.width * width, height: 10)
                        .frame(maxHeight: .infinity, alignment: .center)
                }.frame(height: 44)
            }
        }
        .opacity(dim ? 0.55 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true } }
        .accessibilityElement(children: .ignore).accessibilityLabel("正在加载对话…")
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

/// 「对话列表」: 排序 (applies at once), 新建文件夹, 管理文件夹, 已归档, 多选.
struct DrawerListSheet: View {
    enum Action { case newFolder, manageFolders, archived, select }
    let byCreation: Bool
    let sort: (Bool) -> Void
    let hasFolders: Bool
    let pick: (Action) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DrawerSheetFrame(title: String(localized: "对话列表")) {
            Section {
                Picker("排序", selection: Binding(get: { byCreation }, set: sort)) {
                    Text("最近活动").tag(false)
                    Text("创建时间").tag(true)
                }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            } header: { Text("排序").textCase(nil) }
            Section {
                row("folder.badge.plus", String(localized: "新建文件夹"), .newFolder)
                if hasFolders { row("folder.badge.gearshape", String(localized: "管理文件夹"), .manageFolders, chevron: true) }
                row("archivebox", String(localized: "已归档"), .archived, chevron: true)
                row("checkmark.circle", String(localized: "多选"), .select)
            }.listRowBackground(ChatColors.chip)
        }.presentationDetents([.height(hasFolders ? 380 : 330), .large])
    }

    private func row(_ symbol: String, _ title: String, _ action: Action, chevron: Bool = false) -> some View {
        Button { pick(action); dismiss() } label: {
            HStack {
                Label(title, systemImage: symbol).foregroundStyle(ChatColors.ink)
                Spacer()
                if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ChatColors.muted) }
            }.contentShape(Rectangle())
        }
    }
}

/// 移到文件夹: the folders (✓ where all chosen already are), then 新建文件夹 and,
/// when any is filed, 移出文件夹.
struct DrawerFolderPicker: View {
    enum Pick { case folder(UUID), new, none }
    let folders: [ConversationFolder]
    let counts: [UUID: Int]
    let current: UUID?
    let anyFiled: Bool
    let pick: (Pick) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DrawerSheetFrame(title: String(localized: "移到文件夹")) {
            if !folders.isEmpty {
                Section {
                    ForEach(folders) { folder in
                        Button { pick(.folder(folder.id)); dismiss() } label: {
                            HStack(spacing: 12) {
                                folder.mark.frame(width: 22)
                                Text(verbatim: folder.name).foregroundStyle(ChatColors.ink)
                                Spacer()
                                if let count = counts[folder.id], count > 0 { Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(ChatColors.muted) }
                                Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                                    .opacity(folder.id == current ? 1 : 0).frame(width: 20)
                            }.contentShape(Rectangle())
                        }.accessibilityLabel(folder.name).accessibilityAddTraits(folder.id == current ? .isSelected : [])
                    }
                }.listRowBackground(ChatColors.chip)
            }
            Section {
                Button { pick(.new); dismiss() } label: { Label("新建文件夹", systemImage: "folder.badge.plus").foregroundStyle(ChatColors.ink) }
                if anyFiled {
                    Button { pick(.none); dismiss() } label: { Label("移出文件夹", systemImage: "folder.badge.minus").foregroundStyle(ChatColors.ink) }
                }
            }.listRowBackground(ChatColors.chip)
        }.presentationDetents([.medium, .large])
    }
}

/// A sheet's title bar over a grouped list on the panel colour.
struct DrawerSheetFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).foregroundStyle(ChatColors.ink).padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            List { content() }.scrollContentBackground(.hidden).foregroundStyle(ChatColors.ink)
        }.background(ChatColors.panel.ignoresSafeArea()).presentationDragIndicator(.visible).presentationCornerRadius(28)
    }
}

extension RemoteSessionFilter {
    /// The flat list's empty state under this filter.
    var empty: (symbol: String, title: String) {
        switch self {
        case .all: ("bubble.left.and.bubble.right", String(localized: "还没有对话"))
        case .running: ("play.circle", String(localized: "没有运行中的对话"))
        case .waiting: ("questionmark.circle", String(localized: "没有待确认的对话"))
        case .unread: ("checkmark.circle", String(localized: "没有未读对话"))
        }
    }
}

struct FolderManager<Library: FolderLibrary>: View {
    @ObservedObject var chat: Library
    let createImmediately: Bool
    @State private var opened = false
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ConversationFolder?
    @State private var removing: ConversationFolder?

    var body: some View {
        NavigationStack {
            List {
                Button("新建文件夹") { editing = ConversationFolder(name: "") }
                ForEach(chat.folders) { folder in
                    HStack {
                        folder.label
                        Spacer()
                        Menu {
                            Button("编辑文件夹") { editing = folder }
                            Button("删除文件夹", role: .destructive) { removing = folder }
                        } label: { Label(String(localized: "管理") + folder.name, systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                    }
                }.onMove { chat.reorderFolders(from: $0, to: $1) }
            }
            .task {
                if !opened && createImmediately { editing = ConversationFolder(name: "") }
                opened = true
            }
            .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea()).navigationTitle("管理文件夹").inlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .screenLeading) {
                    Button(editMode.isEditing ? "结束排序" : "拖动排序") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }.disabled(chat.folders.count < 2)
                }
                #endif
                ToolbarItem(placement: .screenTrailing) { Button("完成") { dismiss() } }
            }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            .sheet(item: $editing) { folder in
                FolderEditor(chat: chat, folder: folder)
            }
            .confirmationDialog("删除文件夹？里面的对话会保留。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { folder in
                Button("删除文件夹", role: .destructive) { chat.removeFolder(folder.id) }
            }
        }.desktopSheet(width: 410, height: 340)
    }
}

/// 新建文件夹 / 编辑文件夹: a name, a mark and a colour. [created] hears the new folder's id.
struct FolderEditor<Library: FolderLibrary>: View {
    let chat: Library
    let id: UUID
    let isNew: Bool
    let created: ((UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var color: String
    @State private var emoji: String
    @State private var message: String?

    init(chat: Library, folder: ConversationFolder, created: ((UUID) -> Void)? = nil) {
        self.chat = chat
        self.created = created
        id = folder.id
        isNew = folder.name.isEmpty
        _name = State(initialValue: folder.name)
        let mark = folder.symbol ?? "folder"
        _symbol = State(initialValue: ConversationFolder.isEmoji(mark) ? "emoji" : mark)
        _emoji = State(initialValue: ConversationFolder.isEmoji(mark) ? mark : "")
        _color = State(initialValue: folder.color ?? "默认")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                Menu {
                    ForEach(ConversationFolder.symbols, id: \.self) { mark in
                        Button { symbol = mark } label: {
                            Label(ConversationFolder.symbolNames[mark] ?? mark, systemImage: mark)
                        }
                    }
                    Button("自定义表情") { symbol = "emoji" }
                } label: {
                    LabeledContent("标记") {
                        if symbol == "emoji" { Text(emoji.isEmpty ? String(localized: "自定义表情") : emoji) }
                        else { Label(ConversationFolder.symbolNames[symbol] ?? symbol, systemImage: symbol) }
                    }
                }.accessibilityIdentifier("folderSymbol").accessibilityValue(ConversationFolder.symbolNames[symbol] ?? symbol)
                if symbol == "emoji" { TextField("自定义表情", text: $emoji).textFieldStyle(.plain) }
                Menu {
                    ForEach(ConversationFolder.colors, id: \.self) { choice in
                        Button(choice.localized) { color = choice }
                    }
                } label: {
                    LabeledContent("颜色", value: color.localized)
                }.accessibilityIdentifier("folderColor").accessibilityValue(color)
                if let message { Text(message).foregroundStyle(.red) }
            }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea()).navigationTitle(isNew ? "新建文件夹" : "编辑文件夹")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isNew ? "创建" : "保存") {
                            do {
                                let mark = symbol == "emoji" ? emoji.trimmingCharacters(in: .whitespacesAndNewlines) : symbol
                                if symbol == "emoji", !ConversationFolder.isEmoji(mark) { throw HostError(String(localized: "请输入一个表情。")) }
                                try chat.saveFolder(id: isNew ? nil : id, name: name, symbol: mark, color: color)
                                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                if isNew, let made = chat.folders.first(where: { $0.name == title }) { created?(made.id) }
                                dismiss()
                            } catch { message = error.localizedDescription }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}

extension ConversationFolder {
    static let symbols = ["folder", "star", "book", "briefcase", "heart", "tray"]
    static let symbolNames = ["folder": String(localized: "文件夹"), "star": String(localized: "星星"), "book": String(localized: "书籍"), "briefcase": String(localized: "公文包"), "heart": String(localized: "爱心"), "tray": String(localized: "收件箱")]
    static let colors = ["默认", "蓝色", "绿色", "橙色", "紫色", "红色"]
    static func isEmoji(_ mark: String) -> Bool {
        mark.count == 1 && (mark.unicodeScalars.contains { $0.properties.isEmojiPresentation } ||
                           (mark.unicodeScalars.count > 1 && mark.unicodeScalars.contains { $0.properties.isEmoji }))
    }

    private var tint: Color {
        switch color {
        case "蓝色": .blue
        case "绿色": .green
        case "橙色": .orange
        case "紫色": .purple
        case "红色": .red
        default: .accentColor
        }
    }

    /// The folder's mark alone (its emoji, or its symbol in its colour).
    @ViewBuilder var mark: some View {
        if let symbol, Self.isEmoji(symbol) { Text(symbol).font(.system(size: 16)) }
        else { Image(systemName: symbol ?? "folder").font(.system(size: 16)).foregroundStyle(tint) }
    }

    var label: some View {
        Label { Text(name) } icon: { mark }
    }
}

/// 「重命名对话」 as a sheet, for callers outside the drawer.
struct SessionNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle: String
    @State private var saving = false
    @State private var error: String?
    let save: (String) async throws -> Void

    init(title: String, save: @escaping (String) async throws -> Void) {
        self.save = save
        _newTitle = State(initialValue: title)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    TextField("对话标题", text: $newTitle)
                    if !newTitle.isEmpty {
                        Button { newTitle = "" } label: {
                            Label("清除", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }
                .navigationTitle("重命名对话")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await save(String(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.disabled(saving).interactiveDismissDisabled(saving).presentationDetents([.medium])
    }
}
