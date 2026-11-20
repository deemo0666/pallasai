import SwiftUI

/// Stored by raw value in `quickEntries` / `quickOrder`: keep the raw values.
/// 远程主机, 插件, 设置 come first; unknown stored values are skipped.
enum QuickEntry: String, CaseIterable, Identifiable {
    case hosts, plugins, settings, settingsSearch, features, browser, share, terminal, workspace
    static let enabledKey = "quickEntries", orderKey = "quickOrder", swipeKey = "quickSwipe"
    static let defaultEnabled = "plugins,settings"
    var id: Self { self }
    var title: String {
        switch self {
        case .plugins: String(localized: "插件")
        case .settings: String(localized: "设置")
        case .settingsSearch: String(localized: "搜索设置")
        case .features: String(localized: "全部功能")
        case .browser: String(localized: "内置浏览器")
        case .hosts: String(localized: "切换设备")
        case .share: String(localized: "分享与恢复")
        case .terminal: String(localized: "终端")
        case .workspace: String(localized: "文件")
        }
    }
    var symbol: String {
        switch self {
        case .plugins: "puzzlepiece.extension"
        case .settings: "gearshape"
        case .settingsSearch: "magnifyingglass"
        case .features: "circle.grid.3x3"
        case .browser: "globe"
        case .hosts: "network"
        case .share: "square.and.arrow.up"
        case .terminal: "terminal"
        case .workspace: "folder"
        }
    }
    var needsHost: Bool { self == .plugins || self == .terminal || self == .workspace }

    static func order(_ stored: String) -> [Self] {
        var seen = Set<Self>()
        return (stored.split(separator: ",").compactMap { Self(rawValue: String($0)) } + allCases).filter { seen.insert($0).inserted }
    }
    static func enabled(_ stored: String) -> Set<Self> {
        Set(stored.split(separator: ",").compactMap { Self(rawValue: String($0)) })
    }
}

/// 显示的入口: which entries the left-swipe panel lists, and their order.
struct QuickPanelSettings: View {
    @AppStorage(QuickEntry.enabledKey) private var enabled = QuickEntry.defaultEnabled
    @AppStorage(QuickEntry.orderKey) private var order = ""
    #if os(macOS)
    @State private var sorting = false
    #else
    @State private var editMode = EditMode.inactive
    #endif

    var body: some View {
        List {
            #if os(macOS)
            let entries = QuickEntry.order(order)
            Section {
                ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                    HStack {
                        row(entry)
                        if sorting {
                            Spacer(minLength: 8)
                            moveButton(entry, by: -1, enabled: index > 0)
                            moveButton(entry, by: 1, enabled: index + 1 < entries.count)
                        }
                    }
                }
            }.listRowBackground(ChatColors.chip)
            #else
            Section {
                ForEach(QuickEntry.order(order), content: row).onMove { indices, target in
                    var entries = QuickEntry.order(order)
                    entries.move(fromOffsets: indices, toOffset: target)
                    saveOrder(entries)
                }
            } footer: {
                if QuickEntry.enabled(enabled).isEmpty { Text("没有选择，左滑不会打开") }
            }.listRowBackground(ChatColors.chip)
            #endif
        }
        #if os(macOS)
        .groupedList()
        .toolbar { Button(sorting ? "完成排序" : "排序") { sorting.toggle() } }
        #else
        .toolbar { Button(editMode.isEditing ? "完成排序" : "排序") { editMode = editMode.isEditing ? .inactive : .active } }
        .environment(\.editMode, $editMode)
        #endif
        .settingsPage(String(localized: "显示的入口"))
    }

    private func row(_ entry: QuickEntry) -> some View {
        Toggle(isOn: Binding(get: { QuickEntry.enabled(enabled).contains(entry) }, set: { on in
            var chosen = QuickEntry.enabled(enabled)
            if on { chosen.insert(entry) } else { chosen.remove(entry) }
            enabled = QuickEntry.allCases.filter(chosen.contains).map(\.rawValue).joined(separator: ",")
        })) { Label(entry.title, systemImage: entry.symbol) }
            .accessibilityIdentifier("quickEntry-" + entry.rawValue)
    }

    private func saveOrder(_ entries: [QuickEntry]) {
        order = entries.map(\.rawValue).joined(separator: ",")
    }

    #if os(macOS)
    private func moveButton(_ entry: QuickEntry, by step: Int, enabled: Bool) -> some View {
        let symbol = step < 0 ? "arrow.up" : "arrow.down"
        let label = step < 0 ? String(localized: "上移") : String(localized: "下移")
        return Button {
            var entries = QuickEntry.order(order)
            guard let current = entries.firstIndex(of: entry), entries.indices.contains(current + step) else { return }
            entries.swapAt(current, current + step)
            saveOrder(entries)
        } label: {
            Image(systemName: symbol)
                .frame(width: 25, height: 23)
                .contentShape(Rectangle())
        }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .accessibilityLabel(label).accessibilityValue(entry.title)
            .accessibilityIdentifier("quickEntry-" + entry.rawValue + "-" + symbol)
    }
    #endif
}

struct QuickPanel: View {
    let title: String?
    let hostName: String
    let workspace: String
    let model: String
    let host: Harness?
    let choose: (QuickEntry) -> Void
    let changeModel: () -> Void
    let close: () -> Void
    let expand: () -> Void
    var configure: (() -> Void)? = nil
    @AppStorage(QuickEntry.enabledKey) private var enabled = QuickEntry.defaultEnabled
    @AppStorage(QuickEntry.orderKey) private var order = ""
    private var entries: [QuickEntry] {
        let list = QuickEntry.order(order).filter(QuickEntry.enabled(enabled).contains)
        #if os(iOS)
        return list
            .filter { $0 != .terminal || host.map(EmbeddedEngine.shared.hasTerminal) ?? true }
        #else
        return list
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title == nil ? "快捷入口" : "对话面板").font(.headline)
                Spacer()
                if title != nil { Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("完整对话信息") }
                Button(action: close) { Image(systemName: "xmark").frame(width: 36, height: 36) }.accessibilityLabel("关闭快捷面板").keyboardShortcut(.cancelAction)
            }
            if let title {
                ScrollView { QuickSessionInfo(title: title, hostName: hostName, workspace: workspace, model: model, chooseModel: changeModel) }
            }
            if entries.isEmpty {
                Button("设置快捷入口") {
                    if let configure { configure() } else { choose(.settings) }
                }
            }
            if title != nil { Spacer(minLength: 0) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        Button { choose(entry) } label: {
                            HStack(spacing: 13) {
                                Image(systemName: entry.symbol).frame(width: 20)
                                Text(entry.title); Spacer()
                                if entry.needsHost && host == nil { Text("需先连接").font(.caption) }
                                else { Image(systemName: "chevron.right").font(.caption) }
                            }.frame(minHeight: 46).padding(.horizontal, 12).contentShape(Rectangle())
                        }.disabled(entry.needsHost && host == nil)
                            .accessibilityIdentifier("quickAction-" + entry.rawValue)
                    }
                }.background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 14))
            }.frame(maxHeight: title == nil ? .infinity : min(190, CGFloat(entries.count) * 46))
        }.buttonStyle(.pressable).padding(16).foregroundStyle(ChatColors.ink)
        .accessibilityAction(.escape, close)
    }
}

struct QuickSessionInfo: View {
    let title: String, hostName: String, workspace: String, model: String
    let chooseModel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Divider()
            LabeledContent("设备", value: hostName)
            if !workspace.isEmpty { LabeledContent("文件夹", value: workspace) }
            Button(action: chooseModel) {
                HStack {
                    Text("模型"); Spacer()
                    Text(model.isEmpty ? String(localized: "选择模型") : model)
                    Image(systemName: "chevron.right").font(.caption)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("切换模型").accessibilityValue(model)

        }.font(.subheadline).chatCard()
    }
}

// MARK: - 界面

#if os(iOS)
/// A two-by-three table in the colours of one tint.
private struct TableTintPreview: View {
    let tint: ChatTableTint
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        VStack(spacing: 0) {
            Rectangle().fill(tint.header)
            Rectangle().fill(Color.clear)
            Rectangle().fill(Color.clear)
        }
        .background(tint.surface)
        .overlay {
            GeometryReader { box in
                Path { path in
                    let w = box.size.width, h = box.size.height
                    path.move(to: CGPoint(x: w / 2, y: 0)); path.addLine(to: CGPoint(x: w / 2, y: h))
                    path.move(to: CGPoint(x: 0, y: h / 3)); path.addLine(to: CGPoint(x: w, y: h / 3))
                    path.move(to: CGPoint(x: 0, y: h * 2 / 3)); path.addLine(to: CGPoint(x: w, y: h * 2 / 3))
                }.stroke(ChatColors.line, lineWidth: 0.7)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? Color.accentColor : ChatColors.line, lineWidth: selected ? 1.4 : 0.8))
        .frame(width: 58, height: 38)
        .accessibilityHidden(true)
    }
}

/// 界面: sending with a hardware keyboard, the left-swipe panel, table tint.
struct InterfaceSettings: View {
    @AppStorage("hardwareEnterSends") private var enterSends = false
    @AppStorage(QuickEntry.swipeKey) private var swipe = true
    @AppStorage(QuickEntry.enabledKey) private var enabled = QuickEntry.defaultEnabled
    @AppStorage(QuickEntry.orderKey) private var order = ""
    @AppStorage("tableTint") private var tableTint = ChatTableTint.follow

    private var chosen: String {
        let entries = QuickEntry.order(order).filter(QuickEntry.enabled(enabled).contains)
        return entries.isEmpty ? String(localized: "没有选择，左滑不会打开") : entries.map(\.title).joined(separator: String(localized: "、"))
    }

    var body: some View {
        List {
            Section("对话") {
                SettingsToggleRow(title: String(localized: "外接键盘按 Enter 发送"), isOn: $enterSends)
                    .accessibilityIdentifier("hardwareEnterSends")
            }.listRowBackground(ChatColors.chip)
            Section("左滑快捷入口") {
                SettingsToggleRow(title: String(localized: "左滑打开"), isOn: $swipe)
                    .accessibilityIdentifier("quickPanelSwipe")
                NavigationLink { QuickPanelSettings() } label: {
                    SettingsRowLabel(title: String(localized: "显示的入口"), subtitle: chosen, chevron: false)
                }.accessibilityIdentifier("quickPanelItems")
            }.listRowBackground(ChatColors.chip)
            Section("表格底色") {
                ForEach(ChatTableTint.allCases) { tint in
                    Button { tableTint = tint } label: {
                        HStack(spacing: 12) {
                            Text(tint.title).foregroundStyle(ChatColors.ink)
                            Spacer(minLength: 8)
                            TableTintPreview(tint: tint, selected: tint == tableTint)
                            Image(systemName: tint == tableTint ? "largecircle.fill.circle" : "circle")
                                .font(.title3).foregroundStyle(tint == tableTint ? Color.accentColor : ChatColors.muted.opacity(0.6))
                        }.frame(minHeight: 54).contentShape(Rectangle())
                    }.accessibilityLabel(tint.title).accessibilityAddTraits(tint == tableTint ? .isSelected : [])
                        .accessibilityIdentifier("tableTint-" + tint.rawValue)
                }
            }.listRowBackground(ChatColors.chip)
        }.settingsPage(String(localized: "界面"))
    }
}
#endif
