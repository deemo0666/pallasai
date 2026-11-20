// 社区：问题反馈（本项目的 GitHub Issues）和精选插件（dshfind 目录里标为推荐的，点开是插件市场的详情）。

import SwiftUI

@MainActor
final class CommunityStore: ObservableObject {
    enum Load<Value> { case loading, loaded(Value), failed(String) }

    @Published var picks: Load<[HostMarketPlugin]> = .loading

    /// `-DSHCommunityOffline 1` (debug builds): every request fails as without a network.
    private static var offline: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "DSHCommunityOffline")
        #else
        false
        #endif
    }

    func loadPicks() async {
        picks = .loading
        do {
            if Self.offline { throw HostError(String(localized: "连不上插件目录")) }
            let catalog = try await HostMarketCatalog.fetch()
            guard !Task.isCancelled else { return }
            picks = .loaded(Array(catalog.plugins.filter { $0.featured && !$0.webOnly }.prefix(6)))
        } catch {
            if !Task.isCancelled { picks = .failed(error.localizedDescription) }
        }
    }
}

struct CommunityPage: View {
    @ObservedObject var remote: Conversation
    @StateObject private var store = CommunityStore()
    @State private var pluginStore: HostPluginStore?

    private var host: Harness? {
        remote.phase == .ready || remote.phase == .replying ? remote.connection : nil
    }

    var body: some View {
        List {
            Section {
                Link(destination: ProjectLinks.repository) {
                    HStack(spacing: 14) {
                        SettingsIconDisc(symbol: "chevron.left.forwardslash.chevron.right", size: 48)
                        Text("Pallas Agent").font(.headline).foregroundStyle(ChatColors.ink)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(ChatColors.muted)
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("communityProject")
            }.listRowBackground(ChatColors.chip)

            Section {
                linkRow(String(localized: "问题反馈"), symbol: "exclamationmark.bubble", url: ProjectLinks.issues, id: "communityIssues")
            } header: { Text("反馈") }.listRowBackground(ChatColors.chip)

            picksSection
        }
        .groupedList()
        .settingsPage(String(localized: "社区"))
        #if os(macOS)
        .toolbar {
            Button("刷新", systemImage: "arrow.clockwise") { Task { await store.loadPicks() } }
                .accessibilityIdentifier("communityRefresh")
        }
        #else
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await store.loadPicks() }
        .refreshable { await store.loadPicks() }
        .onChange(of: host.map(ObjectIdentifier.init), initial: true) { _, _ in syncPluginStore() }
    }

    /// The market's detail needs the host it installs to.
    private func syncPluginStore() {
        guard let host else { pluginStore = nil; return }
        if pluginStore?.host !== host {
            let store = HostPluginStore(host: host)
            pluginStore = store
            Task { await store.refresh() }
        }
    }

    private func linkRow(_ title: String, symbol: String, url: URL, id: String) -> some View {
        Link(destination: url) {
            SettingsRowLabel(symbol: symbol, title: title, chevron: false, tinted: false)
                .overlay(alignment: .trailing) { Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(ChatColors.muted) }
        }.accessibilityIdentifier(id)
    }

    @ViewBuilder private var picksSection: some View {
        Section {
            switch store.picks {
            case .loading: ProgressView("正在加载插件目录…").frame(maxWidth: .infinity)
            case .failed(let why):
                #if os(macOS)
                Text(why).foregroundStyle(.red)
                Button("重试") { Task { await store.loadPicks() } }.accessibilityIdentifier("communityPicksRetry")
                #else
                Button { Task { await store.loadPicks() } } label: {
                    SettingsRowLabel(symbol: "arrow.clockwise", title: String(localized: "没能打开插件目录"), subtitle: why + String(localized: " · 点一下重试"), chevron: false, tinted: false)
                }.buttonStyle(.plain).accessibilityIdentifier("communityPicksRetry")
                #endif
            case .loaded(let plugins) where plugins.isEmpty:
                Text("目录里暂时没有推荐的插件").foregroundStyle(ChatColors.muted)
            case .loaded(let plugins):
                #if os(macOS)
                if host == nil { Label("未连接", systemImage: "wifi.slash").foregroundStyle(ChatColors.muted) }
                #endif
                ForEach(plugins) { plugin in pickRow(plugin) }
            }
        } header: { Text("精选插件") } footer: {
            #if os(iOS)
            if host == nil { Text("连接设备后才能查看详情和安装。") }
            #endif
        }.listRowBackground(ChatColors.chip)
    }

    @ViewBuilder private func pickRow(_ plugin: HostMarketPlugin) -> some View {
        let label = HStack(spacing: 12) {
            Text(String(plugin.title.prefix(1)).uppercased()).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: plugin.title).foregroundStyle(ChatColors.ink).lineLimit(1)
                #if os(iOS)
                if let summary = plugin.summary {
                    Text(verbatim: summary).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(2)
                }
                #endif
            }
        }.frame(minHeight: 48)
        if let pluginStore, pluginStore.host === host {
            NavigationLink { HostMarketPluginDetail(store: pluginStore, plugin: plugin) } label: { label }
                .accessibilityIdentifier("communityPick-" + plugin.name)
        } else {
            label.opacity(0.6).accessibilityIdentifier("communityPick-" + plugin.name)
        }
    }
}
