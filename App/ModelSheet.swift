// 输入框里的模型胶囊和它打开的「选择模型」弹层：渠道筛选、两列模型卡、思考深度胶囊；点模型卡
// 立即生效，选思考深度后弹层自己收起。列表来自主机的 `session/modelCatalog`（本机引擎的
// DeepSeek 账号与第三方接入都在里面）。

import SwiftUI

enum ModelName {
    /// 模型名的短写：去掉 "DeepSeek-" 前缀，连字符换空格，首字母大写。
    /// `deepseek-v4-pro` → `V4 Pro`。别家的名字（`gpt-5`、`claude-sonnet-4-5`）本来就好读，原样显示。
    static func short(_ raw: String) -> String {
        guard let prefix = raw.range(of: #"^deepseek[-_ ]?"#, options: [.regularExpression, .caseInsensitive]) else { return raw }
        let words = raw[prefix.upperBound...].split(whereSeparator: { "-_ ".contains($0) }).map { word in
            word.count == 1 ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.isEmpty ? raw : words.joined(separator: " ")
    }
}

struct ModelEffortOption: Hashable {
    let id: String
    let name: String
    /// 协议词（off/low/high/max）不直接给人看；不认识的档位用目录给的名字。
    var label: String {
        let known = ModelBudget.effortLabel(id)
        return known == id ? name : known
    }
}

struct ModelOption: Identifiable, Hashable {
    let channel: String
    let model: String
    let name: String
    var detail: String?
    var efforts: [ModelEffortOption] = []
    var defaultEffort: String?
    var id: String { channel + "\u{0}" + model }

    /// 换到这个模型时的思考深度：原来的档位它也有就沿用，否则取模型默认。
    func effort(keeping previous: String?) -> String? {
        let ids = efforts.map(\.id)
        if let previous, ids.contains(previous) { return previous }
        if ids.isEmpty { return nil }
        if let preset = defaultEffort, ids.contains(preset) { return preset }
        if ids.contains("medium") { return "medium" }
        return ids.first { $0 != "off" && $0 != "none" } ?? ids.first
    }

    /// 深度胶囊上亮哪一格：会话记下的档位，没记就是模型默认；都没有时一格不亮，
    /// 不把引擎没在用的档位当成当前值，每一格也都能点。
    func shownEffort(_ picked: String?) -> String? {
        picked ?? defaultEffort
    }
}

struct ModelChannel: Identifiable, Hashable {
    let id: String
    let name: String
    var models: [ModelOption]

    /// 收起时最多显示的模型卡（三行）。
    static let foldedCount = 6

    /// 收起时的模型卡：前 6 个；选中的不在里面，就顶替第 6 个。
    func folded(keeping selected: ModelOption?) -> [ModelOption] {
        guard models.count > Self.foldedCount else { return models }
        var head = Array(models.prefix(Self.foldedCount))
        if let selected, selected.channel == id, !head.contains(selected) { head[Self.foldedCount - 1] = selected }
        return head
    }
}

struct ModelPick: Equatable {
    var channel: String
    var model: String
    var effort: String?
}

/// `session/modelCatalog`：按渠道分组的模型、未选择时的默认值、读不到的渠道。
struct HostModelCatalog {
    var channels: [ModelChannel]
    var fallback: ModelPick?
    var failure: String?

    init(_ data: Object) {
        channels = (data["groups"] as? [Object] ?? []).compactMap { group in
            guard let provider = group["id"] as? String, !provider.isEmpty else { return nil }
            let models = (group["models"] as? [Object] ?? []).compactMap { model -> ModelOption? in
                guard let id = model["id"] as? String, !id.isEmpty else { return nil }
                let reasoning = model["reasoning"] as? Object
                let efforts = (reasoning?["efforts"] as? [Object] ?? []).compactMap { effort -> ModelEffortOption? in
                    guard let id = effort["id"] as? String, !id.isEmpty else { return nil }
                    return ModelEffortOption(id: id, name: effort["name"] as? String ?? id)
                }
                let description = (model["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ModelOption(channel: provider, model: id, name: model["name"] as? String ?? id,
                                   detail: description?.isEmpty == false ? description : nil,
                                   efforts: efforts, defaultEffort: reasoning?["defaultEffort"] as? String)
            }
            return ModelChannel(id: provider, name: group["name"] as? String ?? provider, models: models)
        }
        let preset = data["default"] as? Object
        if let provider = preset?["provider"] as? String, let model = preset?["model"] as? String {
            fallback = ModelPick(channel: provider, model: model, effort: preset?["reasoningEffort"] as? String)
        }
        failure = (data["failures"] as? [Object])?.lazy.compactMap { $0["message"] as? String }.first { !$0.isEmpty }
    }
}

// MARK: - 胶囊

/// 手机输入框展开后第二行里的模型胶囊，挨着 ＋、和它一样高：这条消息用什么发，点一下就能换。
struct ModelPill: View {
    let model: String
    let effort: String?
    let action: () -> Void

    var body: some View {
        let name = model.isEmpty ? String(localized: "选择模型") : ModelName.short(model)
        let depth = effort.map(ModelBudget.effortLabel)
        Button(action: action) {
            Text(depth.map { name + " " + $0 } ?? name)
                .font(.system(size: 12.5)).lineLimit(1)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .background(ChatColors.muted.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel(String(localized: "模型 ") + name + (depth.map { String(localized: "，思考深度 ") + $0 } ?? ""))
    }
}

// MARK: - 弹层

/// ```
///                    ───
///   选择模型                               (×)
///   ((  DeepSeek  )   OpenAI                )    渠道多于一个时
///   ╭─────────────────╮  ╭─────────────────╮
///   │ V4 Pro       (✓)│  │ V4 Flash     ( )│
///   │ 更强的推理与编码  │  │ 更快、更省        │
///   ╰─────────────────╯  ╰─────────────────╯
///   ╭──────────────────────────────────────╮
///   │          全部 24 个模型 ⌄            │    超过 6 个时，收起只留三行
///   ╰──────────────────────────────────────╯
///                 管理模型 ›
///   ────────────────────────────────────────    以下固定在底部
///   思考深度
///   (( 不思考 )  低      ( 高 )     最高   )
/// ```
///
/// 渠道条只是筛选，不改当前选择；打开时停在当前模型所在的渠道。点模型卡、选深度都
/// 立即交给 `apply`；它报错时退回原来的选择，把原因写在标题下面。
struct ModelSheet<Manage: View>: View {
    /// nil：第一次读取还没回来。
    let channels: [ModelChannel]?
    let refreshing: Bool
    /// 整个列表没读到。
    let issue: String?
    let current: ModelPick?
    var empty: (title: String, message: String?) = (String(localized: "还没有可用的模型"), nil)
    /// Ways out of the empty list (sign in, bring a key), the first one prominent. They replace 「管理模型」 there.
    var emptyActions: [(String, () -> Void)] = []
    let manageLabel: String
    let apply: (ModelPick) async throws -> Void
    let retry: () -> Void
    @ViewBuilder var manage: () -> Manage

    @Environment(\.dismiss) private var dismiss
    @State private var picked: ModelPick?
    @State private var browsing: String?
    @State private var busy = false
    @State private var failure: String?
    @State private var managing = false
    @State private var showsAll = false
    @State private var fitted: CGFloat = 360
    @State private var docked: CGFloat = 0

    init(channels: [ModelChannel]?, refreshing: Bool, issue: String?, current: ModelPick?,
         empty: (title: String, message: String?) = (String(localized: "还没有可用的模型"), nil),
         emptyActions: [(String, () -> Void)] = [], manageLabel: String,
         apply: @escaping (ModelPick) async throws -> Void, retry: @escaping () -> Void, @ViewBuilder manage: @escaping () -> Manage) {
        self.channels = channels; self.refreshing = refreshing; self.issue = issue; self.current = current
        self.empty = empty; self.emptyActions = emptyActions; self.manageLabel = manageLabel
        self.apply = apply; self.retry = retry; self.manage = manage
        _picked = State(initialValue: current)
    }

    private var shown: [ModelChannel] { (channels ?? []).filter { !$0.models.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleBar
                if let message = failure ?? (shown.isEmpty ? nil : issue) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .padding(.horizontal, 24).padding(.bottom, 10).transition(.opacity)
                }
                content
            }
            .padding(.bottom, 20)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitted = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { effortDock }
        .foregroundStyle(ChatColors.ink)
        .background(ChatColors.panel.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.height(fitted + docked)])
        .presentationCornerRadius(28)
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 440, idealHeight: min(600, max(360, fitted + docked)))
        #endif
        .animation(Motion.std(Motion.standard), value: fitted)
        .animation(Motion.std(Motion.quick), value: failure)
        .onChange(of: current) { _, value in if !busy { picked = value } }
        .sheet(isPresented: $managing, onDismiss: retry) { manage() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("选择模型").font(.headline).accessibilityAddTraits(.isHeader)
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(action: retry) {
                Group {
                    if refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 36, height: 36)
            }.buttonStyle(.plain).disabled(busy || refreshing).accessibilityLabel("刷新")
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.medium))
                    .frame(width: 32, height: 32).background(ChatColors.muted.opacity(0.12), in: Circle())
            }.buttonStyle(.pressable).accessibilityLabel("关闭")
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
    }

    @ViewBuilder private var content: some View {
        if channels == nil, issue == nil {
            ProgressView("正在读取模型…").font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if shown.isEmpty, let issue {
            HostEmptyState(symbol: "wifi.exclamationmark", title: String(localized: "模型列表读取失败"), message: issue, action: (String(localized: "重试"), retry))
        } else if shown.isEmpty {
            HostEmptyState(symbol: "cpu", title: empty.title, message: empty.message)
            if emptyActions.isEmpty { manageLink } else { emptyButtons }
        } else {
            picker(shown)
            manageLink
        }
    }

    /// 正在看的渠道：点过渠道条就是它，否则是当前模型所在的渠道。
    private var browsed: ModelChannel? { shown.first { $0.id == (browsing ?? picked?.channel) } ?? shown.first }
    private var selected: ModelOption? { shown.lazy.flatMap(\.models).first { $0.channel == picked?.channel && $0.model == picked?.model } }

    private func picker(_ channels: [ModelChannel]) -> some View {
        let channel = browsed ?? channels[0]
        return VStack(alignment: .leading, spacing: 0) {
            if channels.count > 1 {
                SegmentedPill(segments: channels.map { ($0.id, $0.name) }, selected: channel.id, identifier: "modelChannel-") { id in
                    browsing = id; showsAll = false
                }.padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 16)
            } else {
                sectionLabel(channel.name)
            }
            ModelGrid(models: showsAll ? channel.models : channel.folded(keeping: selected), selected: selected?.id, enabled: !busy, pick: pick)
                .padding(.horizontal, 24)
            .id(channel.id).transition(.opacity)
            if channel.models.count > ModelChannel.foldedCount { allToggle(channel) }
        }
        .animation(Motion.std(Motion.quick), value: channel.id)
    }

    /// 「全部 24 个模型 ⌄」/「收起 ⌃」：和模型卡同宽同色。
    private func allToggle(_ channel: ModelChannel) -> some View {
        Button { withAnimation(Motion.std(Motion.standard)) { showsAll.toggle() } } label: {
            HStack(spacing: 4) {
                if showsAll { Text("收起") } else { Text("全部 \(channel.models.count) 个模型") }
                Image(systemName: showsAll ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
            .background(ChatColors.chip.opacity(0.87), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(ChatColors.line, lineWidth: 0.55).allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.pressable).foregroundStyle(ChatColors.muted)
        .padding(.horizontal, 24).padding(.top, 12)
        .accessibilityIdentifier("modelSheetAll")
    }

    /// 固定在底部的思考深度：模型再多也不用滑到底。正在看的渠道里没有选中的模型，
    /// 或模型不到两档时不出现。
    private var effortDock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let model = selected, model.channel == browsed?.id, model.efforts.count >= 2 {
                sectionLabel(String(localized: "思考深度")).padding(.top, 14)
                SegmentedPill(segments: model.efforts.map { ($0.id, $0.label) }, selected: model.shownEffort(picked?.effort) ?? "",
                              identifier: "modelEffort-", enabled: !busy) { id in
                    pickEffort(id, of: model)
                }.padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.panel.ignoresSafeArea(edges: .bottom))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { docked = $0 }
        .animation(Motion.std(Motion.quick), value: browsed?.id)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted)
            .padding(.horizontal, 24).padding(.bottom, 10).accessibilityAddTraits(.isHeader)
    }

    /// 列表是空的时候的出路：第一个是主按钮，其余是文字按钮。
    private var emptyButtons: some View {
        VStack(spacing: 4) {
            ForEach(emptyActions.indices, id: \.self) { index in
                let entry = emptyActions[index]
                if index == 0 {
                    Button(entry.0, action: entry.1).prominentButton().buttonBorderShape(.capsule)
                        .accessibilityIdentifier("modelSheetSignIn")
                } else {
                    Button(entry.0, action: entry.1).buttonStyle(.pressable)
                        .font(.subheadline).foregroundStyle(ChatColors.muted).frame(minHeight: 44)
                }
            }
        }.frame(maxWidth: .infinity).padding(.bottom, 8)
    }

    /// 「管理模型 ›」：在弹层上面打开，关掉回到这里并重新读列表。
    private var manageLink: some View {
        Button { managing = true } label: {
            HStack(spacing: 2) { Text(manageLabel); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.pressable).foregroundStyle(ChatColors.muted).padding(.top, 12)
    }

    private func pick(_ model: ModelOption) {
        browsing = model.channel
        commit(ModelPick(channel: model.channel, model: model.model, effort: model.effort(keeping: picked?.effort)), closing: false)
    }

    private func pickEffort(_ effort: String, of model: ModelOption) {
        guard picked?.channel == model.channel, picked?.model == model.model else { return }
        commit(ModelPick(channel: model.channel, model: model.model, effort: effort), closing: true)
    }

    /// 先把卡片和滑块挪过去，等 `apply` 的回答：失败就退回原来的选择。
    private func commit(_ next: ModelPick, closing: Bool) {
        guard !busy else { return }
        let previous = picked
        guard next != previous else {
            if closing { close() }
            return
        }
        picked = next; busy = true; failure = nil
        Task {
            do {
                try await apply(next)
                busy = false
                if closing { close() }
            } catch {
                picked = previous; busy = false
                failure = error.localizedDescription
            }
        }
    }

    /// 等深度滑块落位再收起。
    private func close() {
        Task {
            if !Motion.reduced { try? await Task.sleep(for: .seconds(Motion.standard + 0.12)) }
            dismiss()
        }
    }
}

/// 两列等宽的模型卡，同一行等高、间距 12；单数时最后一张占满整行。
private struct ModelGrid: View {
    let models: [ModelOption]
    let selected: String?
    let enabled: Bool
    let pick: (ModelOption) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: models.count, by: 2)), id: \.self) { i in
                HStack(spacing: 12) {
                    card(models[i])
                    if i + 1 < models.count { card(models[i + 1]) }
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(_ model: ModelOption) -> some View {
        let on = model.id == selected
        let name = ModelName.short(model.name)
        let detail = model.detail ?? (name == model.model ? nil : model.model)
        return Button { pick(model) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(name).font(.body.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.body)
                        .foregroundStyle(on ? Color.accentColor : ChatColors.muted.opacity(0.5))
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1) }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(on ? Color.accentColor.opacity(0.08) : ChatColors.chip.opacity(0.87), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(on ? Color.accentColor : ChatColors.line, lineWidth: on ? 1.2 : 0.55)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.pressable).disabled(!enabled)
        .animation(Motion.std(Motion.quick), value: on)
        .accessibilityLabel(detail.map { name + String(localized: "，") + $0 } ?? name)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("listedModel-" + model.model)
    }
}

/// 一条整宽的分段胶囊：底槽上滑动的白色滑块（深色时亮灰）。
struct SegmentedPill: View {
    private struct Segment: Identifiable { let id: String; let label: String }
    private let segments: [Segment]
    let selected: String
    var identifier = ""
    var enabled = true
    let change: (String) -> Void
    @Namespace private var thumb
    @Environment(\.colorScheme) private var scheme

    init(segments: [(String, String)], selected: String, identifier: String = "", enabled: Bool = true,
         change: @escaping (String) -> Void) {
        self.segments = segments.map { Segment(id: $0.0, label: $0.1) }
        self.selected = selected; self.identifier = identifier; self.enabled = enabled; self.change = change
    }

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                let on = segment.id == selected
                Button { if !on { change(segment.id) } } label: {
                    Text(segment.label).font(.subheadline.weight(on ? .semibold : .medium))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(on ? ChatColors.ink : ChatColors.muted)
                        .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if on {
                                Capsule().fill(dark ? Color.white.opacity(0.2) : Color.white)
                                    .shadow(color: .black.opacity(dark ? 0 : 0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!enabled)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier(identifier + (segment.id.isEmpty ? "default" : segment.id))
            }
        }
        .padding(3)
        .background(dark ? Color.white.opacity(0.07) : ChatColors.ink.opacity(0.06), in: Capsule())
        .animation(Motion.reduced ? nil : Motion.std(Motion.standard), value: selected)
    }
}

/// 叠在弹层上面的设置页：自带导航栈和「完成」。
struct SheetPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 主机对话

/// 主机对话的「选择模型」：读 `session/modelCatalog`，换模型走 `session/selectModel`，
/// 以主机确认的选择为准。
struct HostModelSheet<Manage: View>: View {
    @ObservedObject var chat: Conversation
    let host: Harness
    /// With no model to pick: the page for an API key of one's own (OpenAI by default), and the DeepSeek sign-in page.
    var signIn: (() -> Void)? = nil
    var ownKey: (() -> Void)? = nil
    var chatGPT: (() -> Void)? = nil
    @ViewBuilder var manage: () -> Manage
    @State private var issue: String?
    @State private var revision = 0
    @State private var refreshing = false
    private var catalog: HostModelCatalog? { chat.modelCatalog }

    private var current: ModelPick? {
        chat.modelName.isEmpty ? catalog?.fallback
            : ModelPick(channel: chat.modelProvider, model: chat.modelName, effort: chat.modelEffort)
    }

    private var emptyActions: [(String, () -> Void)] {
        var rows: [(String, () -> Void)] = []
        if let chatGPT { rows.append((String(localized: "用 ChatGPT 登录"), chatGPT)) }
        if let ownKey { rows.append((String(localized: "接入 OpenAI"), ownKey)) }
        if let signIn { rows.append((String(localized: "登录 DeepSeek 账号"), signIn)) }
        return rows
    }

    var body: some View {
        ModelSheet(channels: catalog?.channels, refreshing: refreshing, issue: issue, current: current,
                   empty: (String(localized: "还没有可用的模型"), catalog?.failure),
                   emptyActions: emptyActions, manageLabel: String(localized: "管理模型"),
                   apply: { pick in try await chat.selectModel(on: host, provider: pick.channel, model: pick.model, effort: pick.effort) },
                   retry: { revision += 1 }, manage: manage)
        .task(id: revision) {
            issue = nil; refreshing = true
            defer { if !Task.isCancelled { refreshing = false } }
            do {
                try await chat.reloadAvailableModels(on: host)
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}
