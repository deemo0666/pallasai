import SwiftUI

// MARK: - 使用自己的 API Key

/// 使用自己的 API Key: every saved endpoint, each a route of its own in 本机引擎, and a way to add one.
struct ThirdPartyListPage: View {
    @AppStorage("thirdPartySaved") private var thirdPartySaved = 0
    @State private var providers: [ThirdPartyProvider] = []
    @State private var keyed: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !providers.isEmpty {
                    SettingsCard {
                        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 { SettingsDivider() }
                            NavigationLink { DirectAccessPage(providerID: provider.id) } label: {
                                SettingsRowLabel(symbol: "server.rack", title: ThirdPartyProviders.displayName(provider.base),
                                                 subtitle: provider.model,
                                                 value: keyed.contains(provider.id) ? nil : String(localized: "缺少 API Key"),
                                                 valueColor: SettingsStyle.warning, tinted: false)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                            }.buttonStyle(.plain).accessibilityIdentifier("thirdParty-" + provider.id)
                        }
                    }
                }
                SettingsCard {
                    NavigationLink { DirectAccessPage(providerID: nil) } label: {
                        SettingsRowLabel(symbol: "plus", title: String(localized: "添加 API Key"), chevron: false, tinted: false)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }.buttonStyle(.plain).accessibilityIdentifier("thirdPartyAdd")
                }
            }.padding(16)
        }
        .settingsPage(String(localized: "使用自己的 API Key")).settingsNavigationTitle()
        .onAppear(perform: reload)
        .onChange(of: thirdPartySaved) { _, _ in reload() }
    }

    private func reload() {
        providers = ThirdPartyProviders.load()
        keyed = Set(ThirdPartyProviders.configured().map(\.id))
    }
}

struct ModelImageCheckSection: View {
    var disabled = false
    @AppStorage("thirdPartySaved") private var providerRevision = 0
    @State private var providers: [ThirdPartyProvider] = []
    @State private var selectedID: String?
    @State private var checking: ThirdPartyProvider?
    @State private var status: String?

    private var provider: ThirdPartyProvider? {
        providers.first { $0.id == selectedID } ?? providers.first
    }

    var body: some View {
        Section("模型读图") {
            if let provider {
                if providers.count > 1 {
                    Picker("模型", selection: Binding(get: { provider.id }, set: { selectedID = $0 })) {
                        ForEach(providers) { option in
                            let name = ThirdPartyProviders.displayName(option.base)
                            Text(verbatim: option.model + String(localized: "（") + name + String(localized: "）")).tag(option.id)
                        }
                    }
                    .disabled(checking != nil)
                    .accessibilityIdentifier("modelImageCheckModel")
                } else {
                    LabeledContent("模型", value: provider.model)
                }
                Button(checking == nil ? "验证第三方模型读图" : "正在验证读图…") {
                    status = nil
                    checking = provider
                }
                .disabled(checking != nil || disabled)
                .accessibilityIdentifier("modelImageCheck")
                if let status { Text(status).accessibilityIdentifier("modelImageCheckResult") }
            } else {
                NavigationLink("使用自己的 API Key") { ThirdPartyListPage() }
            }
        }
        .onChange(of: providerRevision, initial: true) { _, _ in providers = ThirdPartyProviders.load() }
        .onChange(of: provider) { _, _ in
            checking = nil
            status = nil
        }
        .task(id: checking) {
            guard let checking else { return }
            await verify(checking)
        }
        .onDisappear { checking = nil }
    }

    private func verify(_ route: ThirdPartyProvider) async {
        do {
            try await ModelService.verifyImageInput(base: route.base, model: route.model)
            guard !Task.isCancelled, checking == route else { return }
            status = String(localized: "图片输入已验证")
            providerRevision += 1
        } catch {
            guard !Task.isCancelled, checking == route else { return }
            status = error.localizedDescription
        }
        checking = nil
    }
}

/// Key, endpoint and model of one 自己的 API Key (`providerID` nil adds a new one); the shell writes
/// each into 本机引擎 as a route of its own (`ThirdPartyChannel`). The saved key is never shown
/// or put back in the field.
struct DirectAccessPage: View {
    let providerID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var address = ""
    @State private var selection = ""
    @State private var windowText = ""
    @State private var contextError: String?
    @State private var loaded = false
    @State private var hasKey = false
    @State private var fetching = false
    @State private var choices: ModelChoices?
    @State private var saveAfterPick = false
    @State private var makeDefault = false
    @State private var issue: String?
    /// 「其他」 was chosen: the address field shows even while it holds a listed service's address.
    @State private var customAddress = false

    static let defaultBase = "https://api.openai.com/v1"
    /// Common services and their OpenAI-compatible addresses; picking one fills the address.
    static let services: [(name: String, base: String)] = [
        ("OpenAI", "https://api.openai.com/v1"),
        ("DeepSeek", "https://api.deepseek.com/v1"),
        ("OpenRouter", "https://openrouter.ai/api/v1"),
        (String(localized: "硅基流动"), "https://api.siliconflow.cn/v1"),
        (String(localized: "阿里云百炼"), "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        (String(localized: "火山方舟"), "https://ark.cn-beijing.volces.com/api/v3"),
        (String(localized: "智谱"), "https://open.bigmodel.cn/api/paas/v4"),
        ("Moonshot", "https://api.moonshot.cn/v1"),
    ]
    static let contextPresets = [32768, 65536, 131072, 200000, 262144, 1_000_000]
    private static let badURL = String(localized: "API 地址需要以 https:// 开头；本机或局域网地址可以用 http://")
    private static let keyRequired = String(localized: "请先输入 API Key")
    private static let modelRequired = String(localized: "先给这个服务商选一个默认模型")
    private static let tokenInvalid = String(localized: "填写数字，如 128K")
    private static let duplicate = String(localized: "这个服务商已经添加过了，请在列表里编辑它")

    private struct ModelChoices: Identifiable {
        let id = UUID()
        let models: [String]
        let problem: String?
    }

    /// `262144` → `256K`, `1000000` → `1M`.
    static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return String(value / 1_000_000) + "M" }
        if value >= 1_048_576, value % 1_048_576 == 0 { return String(value / 1_048_576) + "M" }
        if value >= 1024, value % 1024 == 0 { return String(value / 1024) + "K" }
        if value >= 1000, value % 1000 == 0 { return String(value / 1000) + "K" }
        return String(value)
    }

    /// `128K`, `1m`, `200,000`; a preset's own label means that preset.
    static func parseTokens(_ raw: String) -> Int? {
        let text = raw.replacingOccurrences(of: #"[\s,_]"#, with: "", options: .regularExpression)
        if let preset = contextPresets.first(where: { formatTokens($0).caseInsensitiveCompare(text) == .orderedSame }) { return preset }
        guard let match = text.wholeMatch(of: #/(\d+(?:\.\d+)?)([kKmM])?/#), let number = Double(match.1) else { return nil }
        let suffix = match.2.map { $0.lowercased() } ?? ""
        let scale: Double = suffix == "k" ? 1000 : suffix == "m" ? 1_000_000 : 1
        let scaled = number * scale
        guard (128.0...1_000_000_000.0).contains(scaled) else { return nil }
        let rounded = Int(scaled.rounded())
        guard abs(scaled - Double(rounded)) < 1e-6, (128...1_000_000_000).contains(rounded) else { return nil }
        return rounded
    }

    private var addressOrDefault: String {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? Self.defaultBase : raw
    }
    private var service: String { (try? ModelService.endpoint(addressOrDefault))?.absoluteString ?? addressOrDefault }

    /// The listed service the address belongs to; nil for an address typed by hand.
    private var listedService: String? {
        func plain(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
        return Self.services.first { plain($0.base) == plain(addressOrDefault) }?.name
    }

    /// What an empty 对话长度 means for the model in the form.
    private var automaticContext: String {
        let key = ModelBudget.key(service: service, model: selection.trimmingCharacters(in: .whitespacesAndNewlines))
        let learned = UserDefaults.standard.integer(forKey: key + ".learned")
        let reported = UserDefaults.standard.integer(forKey: key + ".window")
        let (size, source) = learned > 0 ? (learned, String(localized: "按服务商报错校正")) : reported > 0 ? (reported, String(localized: "服务商提供")) : (262144, String(localized: "默认值"))
        return String(localized: "自动：") + Self.formatTokens(size) + String(localized: "（") + source + String(localized: "）")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCard {
                    field("API Key") {
                        SecureField(hasKey ? "输入新的 API Key 以替换" : "sk-…", text: $key)
                            .noAutomaticCapitalization().autocorrectionDisabled().chatInput()
                            .accessibilityLabel("API Key").accessibilityIdentifier("directApiKey")
                    }
                    field(String(localized: "服务商")) {
                        Menu {
                            ForEach(Self.services, id: \.base) { item in
                                Button(item.name) { customAddress = false; address = item.base }
                            }
                            Button("其他") { customAddress = true }
                        } label: {
                            HStack {
                                Text(customAddress ? String(localized: "其他") : listedService ?? String(localized: "其他")).lineLimit(1)
                                    .foregroundStyle(ChatColors.ink)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(ChatColors.muted)
                            }.padding(.horizontal, 13).frame(minHeight: 48)
                                .background(ChatColors.muted.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatColors.line, lineWidth: 0.8))
                                .contentShape(Rectangle())
                        }.accessibilityLabel("服务商").accessibilityIdentifier("directService")
                    }
                    if customAddress || listedService == nil {
                        field(String(localized: "API 地址")) {
                            TextField(Self.defaultBase, text: $address).urlKeyboard()
                                .noAutomaticCapitalization().autocorrectionDisabled().chatInput()
                                .accessibilityLabel("API 地址").accessibilityIdentifier("directBaseURL")
                        }
                    }
                    Toggle("设为默认模型", isOn: $makeDefault).padding(16)
                    field(String(localized: "模型")) {
                        Button { Task { await pickModel() } } label: {
                            HStack {
                                Text(selection.isEmpty ? String(localized: "选择模型") : selection).lineLimit(1)
                                    .foregroundStyle(selection.isEmpty ? ChatColors.muted : ChatColors.ink)
                                Spacer()
                                if fetching { ProgressView() }
                                else { Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(ChatColors.muted) }
                            }.padding(.horizontal, 13).frame(minHeight: 48)
                                .background(ChatColors.muted.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatColors.line, lineWidth: 0.8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(fetching)
                            .accessibilityLabel("模型").accessibilityValue(selection).accessibilityIdentifier("directModel")
                    }
                }
                SettingsCard {
                    field(String(localized: "对话长度"), error: contextError) {
                        TextField(automaticContext, text: $windowText).settingsNumberKeyboard()
                            .noAutomaticCapitalization().autocorrectionDisabled().chatInput()
                            .accessibilityLabel("对话长度").accessibilityIdentifier("directContextWindow")
                            .onChange(of: windowText) { _, raw in
                                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                contextError = text.isEmpty || Self.parseTokens(text) != nil ? nil : Self.tokenInvalid
                            }
                        let current = Self.parseTokens(windowText.trimmingCharacters(in: .whitespacesAndNewlines))
                        HStack(spacing: 6) {
                            ForEach(Self.contextPresets, id: \.self) { preset in
                                let chosen = current == preset
                                Button {
                                    windowText = chosen ? "" : Self.formatTokens(preset)
                                } label: {
                                    Text(Self.formatTokens(preset)).font(.caption.weight(chosen ? .semibold : .regular))
                                        .foregroundStyle(chosen ? Color.accentColor : ChatColors.ink)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .background(chosen ? Color.accentColor.opacity(0.16) : ChatColors.muted.opacity(0.1), in: Capsule())
                                        .overlay { if chosen { Capsule().strokeBorder(Color.accentColor.opacity(0.6)) } }
                                        .contentShape(Capsule())
                                }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
                            }
                        }.padding(.top, 4)
                    }
                }
                if providerID != nil {
                    SettingsCard {
                        Button(action: remove) {
                            SettingsRowLabel(symbol: "trash", title: String(localized: "删除这个 API Key"), danger: true, chevron: false).padding(.horizontal, 16)
                        }.buttonStyle(.plain).accessibilityIdentifier("directRemove")
                    }
                }
                if let issue {
                    Text(issue).font(.subheadline).foregroundStyle(.red).padding(.horizontal, 4).padding(.vertical, 4)
                        .accessibilityIdentifier("directIssue")
                }
                Button(action: save) {
                    Text("保存").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }.prominentButton().buttonBorderShape(.capsule)
                    .disabled(fetching).padding(.top, 12).padding(.bottom, 24).accessibilityIdentifier("directSave")
            }.padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(ChatColors.ink)
        .background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle(providerID == nil ? "添加 API Key" : "编辑 API Key").settingsNavigationTitle()
        .onAppear(perform: load)
        .onChange(of: address) { _, _ in refreshKeyState() }
        .sheet(item: $choices, onDismiss: {
            guard saveAfterPick else { return }
            saveAfterPick = false
            if selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issue = Self.modelRequired } else { save() }
        }) { list in
            DirectModelPickSheet(models: list.models, current: selection, problem: list.problem) { picked in
                selection = picked
                showWindow(of: picked)
            }
        }
    }

    private func field<Input: View>(_ label: String, error: String? = nil, @ViewBuilder input: () -> Input) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote.weight(.medium)).foregroundStyle(ChatColors.muted)
            input()
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func load() {
        guard !loaded else { refreshKeyState(); return }
        loaded = true
        let saved = ThirdPartyProviders.load().first { $0.id == providerID }
        address = saved?.base ?? Self.defaultBase
        makeDefault = false
        selection = saved?.model ?? ""
        showWindow(of: selection)
        refreshKeyState()
    }

    /// Whether the endpoint in the form already has a key in the keychain. Only the answer is kept.
    private func refreshKeyState() {
        guard let url = try? ModelService.endpoint(addressOrDefault) else { hasKey = false; return }
        hasKey = ((try? Vault.read(url.absoluteString)) ?? "").isEmpty == false
    }

    private func showWindow(of model: String) {
        let saved = UserDefaults.standard.integer(forKey: ModelBudget.key(service: service, model: model) + ".custom")
        let label = Self.formatTokens(saved)
        windowText = saved > 0 ? (Self.parseTokens(label) == saved ? label : String(saved)) : ""
        contextError = nil
    }

    private func endpoint() -> URL? {
        guard let url = try? ModelService.endpoint(addressOrDefault) else { issue = Self.badURL; return nil }
        return url
    }

    /// Lists the endpoint's models with the typed (or saved) key; a failed or
    /// empty list still lets a name be typed in the sheet.
    private func pickModel(thenSave: Bool = false) async {
        guard let url = endpoint() else { return }
        issue = nil
        fetching = true
        var models: [String] = []
        var problem: String?
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = typed.isEmpty ? ((try? Vault.read(url.absoluteString)) ?? "") : typed
        if token.isEmpty { problem = Self.keyRequired }
        else {
            do {
                models = try await ModelService.models(base: url.absoluteString, key: token)
                ThirdPartyChannel.remember(models, base: url.absoluteString)
                if models.isEmpty { problem = String(localized: "服务没有列出可用的模型，可以在上面直接输入模型名") }
            } catch { problem = error.localizedDescription }
        }
        fetching = false
        saveAfterPick = thenSave
        choices = ModelChoices(models: models, problem: problem)
    }

    /// Drops this entry and its key; the shell then removes its route from 本机引擎.
    private func remove() {
        var list = ThirdPartyProviders.load()
        guard let gone = list.first(where: { $0.id == providerID }) else { dismiss(); return }
        do { try Vault.save("", account: gone.base) } catch { issue = error.localizedDescription; return }
        list.removeAll { $0.id == providerID }
        ThirdPartyProviders.store(list)
        dismiss()
    }

    private func save() {
        issue = nil
        guard let url = endpoint() else { return }
        let service = url.absoluteString
        var list = ThirdPartyProviders.load()
        let old = list.first { $0.id == providerID }
        guard !list.contains(where: { $0.base == service && $0.id != providerID }) else { issue = Self.duplicate; return }
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || ((try? Vault.read(service)) ?? "").isEmpty == false else { issue = Self.keyRequired; return }
        let rawWindow = windowText.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = rawWindow.isEmpty ? nil : Self.parseTokens(rawWindow)
        if !rawWindow.isEmpty, window == nil { contextError = Self.tokenInvalid; return }
        let chosen = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty else { Task { await pickModel(thenSave: true) }; return }
        do { if !typed.isEmpty { try Vault.save(typed, account: service) } }
        catch { issue = error.localizedDescription; return }
        // A moved endpoint takes its key along when no new one was typed.
        if let old, old.base != service {
            if typed.isEmpty, ((try? Vault.read(service)) ?? "").isEmpty, let carried = try? Vault.read(old.base), !carried.isEmpty {
                try? Vault.save(carried, account: service)
            }
            try? Vault.save("", account: old.base)
        }
        UserDefaults.standard.set(window, forKey: ModelBudget.key(service: service, model: chosen) + ".custom")
        let entry = ThirdPartyProvider(id: old?.id ?? ThirdPartyProviders.newID(in: list), base: service, model: chosen)
        if let index = list.firstIndex(where: { $0.id == entry.id }) { list[index] = entry } else { list.append(entry) }
        if makeDefault { ThirdPartyProviders.requestActivation(entry, explicit: true) }
        else { ThirdPartyProviders.requestActivation(entry, explicit: false) }
        ThirdPartyProviders.store(list)
        key = ""
        dismiss()
    }
}

/// Picks one model id: a listed one, or what was typed when the list lacks it.
private struct DirectModelPickSheet: View {
    let models: [String]
    let current: String
    let problem: String?
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private func choose(_ id: String) { pick(id); dismiss() }

    private func row(_ label: String, id: String, icon: String? = nil) -> some View {
        Button { choose(id) } label: {
            HStack(spacing: 14) {
                if let icon { Image(systemName: icon).frame(width: 22).foregroundStyle(ChatColors.muted) }
                else {
                    Image(systemName: id == current ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(id == current ? Color.accentColor : ChatColors.muted.opacity(0.55)).frame(width: 22)
                }
                Text(label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("listedModel-" + id)
            .accessibilityAddTraits(icon == nil && id == current ? .isSelected : [])
    }

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = models.filter { trimmed.isEmpty || $0.localizedCaseInsensitiveContains(trimmed) }
        let custom = !trimmed.isEmpty && !models.contains(trimmed)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择模型").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.medium))
                        .frame(width: 32, height: 32).background(ChatColors.muted.opacity(0.12), in: Circle())
                }.accessibilityLabel("取消")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(ChatColors.muted)
                TextField("搜索，或输入模型名", text: $query)
                    .noAutomaticCapitalization().autocorrectionDisabled().submitLabel(.done)
                    .focused($focused).accessibilityIdentifier("modelSearch")
                    .onSubmit { if custom { choose(trimmed) } }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清除搜索") }
            }.padding(.horizontal, 14).frame(minHeight: 50)
                .background(ChatColors.muted.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ChatColors.muted.opacity(0.45)))
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if custom { row(String(localized: "使用「") + trimmed + String(localized: "」"), id: trimmed, icon: "pencil") }
                    ForEach(visible, id: \.self) { id in row(id, id: id) }
                }
            }.scrollDismissesKeyboard(.immediately)
        }.padding(.horizontal, 20).padding(.vertical, 14)
            .foregroundStyle(ChatColors.ink).background(ChatColors.panel.ignoresSafeArea())
            .directModelSheetSize()
            .onAppear { if models.isEmpty { focused = true } }
    }
}

private extension View {
    @ViewBuilder func settingsNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    @ViewBuilder func settingsNumberKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }

    @ViewBuilder func directModelSheetSize() -> some View {
        #if os(iOS)
        presentationDetents([.fraction(0.7), .large]).presentationCornerRadius(28)
        #else
        desktopSheet(width: 440, height: 440)
        #endif
    }
}
