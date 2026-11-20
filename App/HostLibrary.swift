import CoreImage
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import AVFoundation
import PhotosUI
import VisionKit

private struct PairScanner: UIViewControllerRepresentable {
    let receive: (String) -> Void
    final class Delegate: NSObject, DataScannerViewControllerDelegate {
        let receive: (String) -> Void
        init(_ receive: @escaping (String) -> Void) { self.receive = receive }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let item) in addedItems {
                if let value = item.payloadStringValue { scanner.stopScanning(); receive(value); break }
            }
        }
    }
    func makeCoordinator() -> Delegate { Delegate(receive) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])])
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) { try? scanner.startScanning() }
}
#endif

/// What the chat is talking to now, for the card at the top of 我的电脑 (nil while on this phone).
struct ActiveRemoteHost {
    let name: String
    /// SSH: the host's address, for 「已连接 · SSH …」. A paired computer's status leaves it out.
    var address: String?
    /// The computer was paired by its code, not set up as an SSH host.
    var paired = false
    var connected = true
    /// Overrides the status line (连接中…, a failure).
    var status: String?
    /// The saved SSH / paired computer (`HostProfile.id`).
    var profileID: UUID?

    var statusLine: String {
        if let status { return status }
        guard connected else { return String(localized: "未连接") }
        guard !paired, let address, !address.isEmpty else { return String(localized: "已连接") }
        return String(localized: "已连接 · SSH ") + address
    }
}

/// 「信任这台主机？」: trust on first use, with the fingerprint to compare.
@MainActor
final class HostKeyPrompt: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let key: SSHHostKey
    let remember: Bool
    let previous: String
    var action: String { !remember ? String(localized: "仅本次测试") : previous.isEmpty ? String(localized: "信任并记住") : String(localized: "更新并记住指纹") }
    private var completion: ((Bool) -> Void)?

    init(name: String, address: String, key: SSHHostKey, remember: Bool = true, previous: String = "", decide: @escaping (Bool) -> Void) {
        self.name = name
        self.address = address
        self.remember = remember
        self.previous = previous
        self.key = key
        self.completion = decide
    }

    func decide(_ trusted: Bool) {
        let pending = completion
        completion = nil
        pending?(trusted)
    }

    /// Manual actions probe before sending credentials. The authenticated second
    /// connection still checks the exact accepted key, even if the host changes meanwhile.
    static func verify(_ profile: HostProfile, remember: Bool, stored: Binding<Data>,
                       prompt: Binding<HostKeyPrompt?>) async throws -> HostProfile? {
        guard profile.kind == .ssh else { return profile }
        let key = try await SSHTunnel.hostKey(profile)
        try Task.checkCancellation()
        if remember && key.fingerprint == profile.fingerprint { return profile }
        let trusted = await withCheckedContinuation { done in
            prompt.wrappedValue = HostKeyPrompt(name: profile.name.isEmpty ? profile.address : profile.name,
                address: "\(profile.address):\(profile.port)", key: key, remember: remember, previous: profile.fingerprint == key.fingerprint ? "" : profile.fingerprint) {
                done.resume(returning: $0)
            }
        }
        guard trusted else { return nil }
        if remember { stored.wrappedValue = try HostVault.remember(key, for: profile, in: stored.wrappedValue) }
        var target = profile
        target.fingerprint = key.fingerprint
        target.hostKeyType = key.type
        return target
    }

    var message: String {
        let identity = String(localized: "「\(name)」（\(address)）")
        let comparison = previous.isEmpty ? String(localized: "请核对主机指纹") : String(localized: "主机指纹已变化，连接已暂停。请在电脑上核实后再继续。\n\n已信任：\(previous)\n当前")
        let effect = remember ? String(localized: "确认后立即记住此指纹。") : String(localized: "仅用于本次测试；保存主机后才会记住此指纹。")
        return "\(identity)\n\n\(comparison)\n\(key.type)  \(key.fingerprint)\n\n\(effect)"
    }
}

extension View {
    func hostKeyPrompt(_ prompt: Binding<HostKeyPrompt?>) -> some View {
        sheet(item: prompt) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text(request.previous.isEmpty ? "信任这台主机？" : "主机指纹已变化").font(.headline)
                ScrollView { Text(request.message).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("取消", role: .cancel) { request.decide(false); prompt.wrappedValue = nil }
                    Spacer()
                    Button(request.action) { request.decide(true); prompt.wrappedValue = nil }
                        .prominentButton()
                }
            }
            .padding()
            .presentationDetents([.medium, .large])
            #if os(iOS)
            .presentationDragIndicator(.visible)
            #endif
            .desktopSheet(width: 520, height: 285)
            .onDisappear { request.decide(false) }
        }
    }
}

@MainActor
enum HostVault {
    static func remember(_ key: SSHHostKey, for target: HostProfile, in stored: Data) throws -> Data {
        var hosts = try JSONDecoder().decode([HostProfile].self, from: stored)
        guard let index = hosts.firstIndex(where: { $0.id == target.id && $0.kind == .ssh &&
            $0.address == target.address && $0.port == target.port && $0.fingerprint == target.fingerprint }) else {
            throw HostError(String(localized: "主机记录已变化，请重新打开后再确认指纹。"), code: "ssh/trust-record-changed")
        }
        hosts[index].fingerprint = key.fingerprint
        hosts[index].hostKeyType = key.type
        return try JSONEncoder().encode(hosts)
    }

    static func secrets(_ id: UUID) throws -> (secret: String, passphrase: String, token: String) {
        (try Vault.read(id.uuidString), try Vault.read(id.uuidString + "/pass"), try Vault.read(id.uuidString + "/token"))
    }

    static func save(_ profile: HostProfile, secret: String, passphrase: String, token: String, into stored: inout Data) throws {
        var hosts = try profiles(in: stored)
        if let index = hosts.firstIndex(where: { $0.id == profile.id }) { hosts[index] = profile }
        else { hosts.append(profile) }
        let next = try JSONEncoder().encode(hosts)
        try writeSecrets(profile.id, secret: secret, passphrase: passphrase, token: token)
        stored = next
    }

    static func forget(_ profile: HostProfile, from stored: inout Data) throws {
        let next = try JSONEncoder().encode(profiles(in: stored).filter { $0.id != profile.id })
        try writeSecrets(profile.id, secret: "", passphrase: "", token: "")
        stored = next
        HostReadHistory.forget(profile.id.uuidString)
    }

    private static func profiles(in data: Data) throws -> [HostProfile] {
        data.isEmpty ? [] : try JSONDecoder().decode([HostProfile].self, from: data)
    }

    private static func writeSecrets(_ id: UUID, secret: String, passphrase: String, token: String) throws {
        let old = try secrets(id)
        let items = [("", secret, old.secret), ("/pass", passphrase, old.passphrase), ("/token", token, old.token)]
        var written: [(suffix: String, previous: String)] = []
        do {
            for (suffix, value, previous) in items where value != previous {
                try Vault.save(value, account: id.uuidString + suffix)
                written.append((suffix, previous))
            }
        } catch {
            for (suffix, previous) in written.reversed() { try? Vault.save(previous, account: id.uuidString + suffix) }
            throw error
        }
    }
}

/// 我的电脑: what the chat is using now, 已配对的电脑 with 连接电脑 (scan the computer's code), and
/// what to do on the computer while there is none. SSH 主机 and the rest sit under 高级 at the foot.
/// A paired computer is used in two ways: this phone's AI hands it tasks (nothing to do here), or
/// the chat itself moves to the computer (`use`).
struct HostLibrary: View {
    let connected: (HostProfile, SSHTunnel) -> Void
    let active: ActiveRemoteHost?
    let switchToPhone: (() -> Void)?
    /// 由外壳推入：已经在根导航栈里，用系统的返回。
    let pushed: Bool
    /// 高级 › 使用主机地址连接, when the shell offers it here.
    let connectByAddress: (() -> Void)?
    let forgotten: (HostProfile) -> Void

    init(connected: @escaping (HostProfile, SSHTunnel) -> Void,
         active: ActiveRemoteHost? = nil, switchToPhone: (() -> Void)? = nil, pushed: Bool = false,
         connectByAddress: (() -> Void)? = nil, forgotten: @escaping (HostProfile) -> Void = { _ in }) {
        self.connected = connected; self.active = active; self.switchToPhone = switchToPhone
        self.pushed = pushed; self.connectByAddress = connectByAddress; self.forgotten = forgotten
    }

    /// A computer that was just paired, with the connection the pairing left open.
    private struct Fresh: Identifiable {
        let id = UUID()
        let profile: HostProfile
        let tunnel: SSHTunnel
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("hostProfiles") private var stored = Data()
    @AppStorage("restoreHost") private var restoreHost = true
    #if os(iOS)
    @AppStorage(EmbeddedEngine.enabledKey) private var engineEnabled = true
    #else
    @AppStorage(MacLocalEngine.enabledKey) private var engineEnabled = true
    #endif
    @State private var editing: HostProfile?
    @State private var pairing = false
    @State private var removing: HostProfile?
    /// The paired computer whose row was tapped: asks which of the two ways to use it.
    @State private var choosing: HostProfile?
    @State private var fresh: Fresh?
    /// Held until the scanner has closed, so the question that follows is not lost under it.
    @State private var arriving: Fresh?
    /// nil follows the saved hosts: open when there is an SSH host.
    @State private var advancedOpen: Bool?
    @State private var connecting: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionError: HostError?
    @State private var issue: String?
    @State private var prompt: HostKeyPrompt?
    @State private var launchPrompt: SSHLaunchPrompt?
    /// Computers on this network that publish the pairing plugin and are not paired with this phone yet.
    @State private var nearby: [PallasHost] = []
    /// iOS refused the search for nearby computers: 本地网络 is off for this app.
    @State private var networkDenied = false
    private var hosts: [HostProfile] { (try? JSONDecoder().decode([HostProfile].self, from: stored)) ?? [] }
    private var pairedHosts: [HostProfile] { hosts.filter { $0.kind == .paired } }
    private var sshHosts: [HostProfile] { hosts.filter { $0.kind == .ssh } }
    private var unpaired: [PallasHost] {
        let pins = Set(pairedHosts.map(\.fingerprint))
        return nearby.filter { !pins.contains($0.pin) }
    }
    /// The embedded engine can delegate a task without moving the conversation.
    private var localUsable: Bool {
        #if os(iOS)
        EmbeddedEngine.available && engineEnabled
        #else
        MacLocalEngine.bundledRuntime != nil && engineEnabled
        #endif
    }
    private var showsAdvanced: Bool { advancedOpen ?? !sshHosts.isEmpty }
    private var showsSSH: Bool {
        #if os(iOS)
        showsAdvanced
        #else
        !sshHosts.isEmpty
        #endif
    }
    private var showsRestore: Bool {
        #if os(iOS)
        showsAdvanced && !hosts.isEmpty
        #else
        !hosts.isEmpty
        #endif
    }

    /// What to do on the computer before it can show a code. Only what holds today is written here.
    private static var computerSteps: [String] {
        [String(localized: "在电脑上打开「连接 Pallas Agent」页面"),
         String(localized: "点「生成配对码」"),
         String(localized: "在这台设备上点「扫码连接」")]
    }

    var body: some View {
        if pushed { page } else { NavigationStack { page } }
    }

    private var page: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Button("连接电脑", systemImage: "qrcode.viewfinder") { pairing = true }
                    .accessibilityIdentifier("scanPairCode")
                Button("添加 SSH 主机", systemImage: "plus") { editing = HostProfile() }
                    .accessibilityIdentifier("addSSHHost")
                if let connectByAddress {
                    Button("使用主机地址连接", systemImage: "link", action: connectByAddress)
                        .accessibilityIdentifier("connectByAddress")
                }
                Spacer(minLength: 0)
            }.padding(16)
            #endif
            List {
                if let active { activeCard(active) }
                if let issue { Text(issue).font(.footnote).foregroundStyle(DrawerPalette.danger).listRowBackground(ChatColors.chip) }
                if networkDenied {
                    HStack(spacing: 12) {
                        Text("没有本地网络权限，找不到附近的电脑").font(.callout).foregroundStyle(DrawerPalette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("打开设置") {
                            #if os(macOS)
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                                NSWorkspace.shared.open(url)
                            }
                            #else
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            #endif
                        }
                            .buttonStyle(.borderless).font(.subheadline.weight(.semibold))
                    }.listRowBackground(ChatColors.chip).accessibilityIdentifier("localNetworkDenied")
                }
                #if os(iOS)
                Section {
                    Button { pairing = true } label: {
                        settingsRow("qrcode.viewfinder", String(localized: "扫码连接"))
                    }.accessibilityIdentifier("scanPairCode")
                }.listRowBackground(ChatColors.chip)
                #endif
                Section {
                    ForEach(pairedHosts) { profile in
                        HStack(spacing: 12) {
                            Button { tapped(profile) } label: { hostRow(profile, symbol: "desktopcomputer") }.buttonStyle(.plain)
                            Button { removing = profile } label: { Image(systemName: "trash").foregroundStyle(ChatColors.muted) }
                                .buttonStyle(.borderless).accessibilityLabel("删除这台电脑")
                        }
                    }
                    ForEach(unpaired) { host in
                        Button { pairing = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer").foregroundStyle(ChatColors.muted).frame(width: 28)
                                Text(verbatim: host.name).foregroundStyle(ChatColors.ink).lineLimit(1)
                                Spacer(minLength: 4)
                                Label("扫码连接", systemImage: "qrcode.viewfinder").font(.subheadline).foregroundStyle(.tint)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("nearbyHost")
                    }
                } header: {
                    #if os(iOS)
                    if !pairedHosts.isEmpty || !unpaired.isEmpty { Text("电脑") }
                    #else
                    if !pairedHosts.isEmpty { Text("已配对的电脑") }
                    #endif
                }.listRowBackground(ChatColors.chip)
                #if os(iOS)
                // First time only: once any computer, phone or iPad is paired, the steps are not needed here.
                let firstTime = pairedHosts.isEmpty
                if firstTime {
                    Section {
                        ForEach(Array(Self.computerSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: String(index + 1)).font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(ChatColors.muted).frame(width: 28)
                                Text(step).foregroundStyle(ChatColors.ink).fixedSize(horizontal: false, vertical: true)
                            }.accessibilityElement(children: .combine)
                        }
                    } header: { Text("电脑上要做的事") }.listRowBackground(ChatColors.chip)
                }
                Section {
                    Button { withAnimation { advancedOpen = !showsAdvanced } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .medium)).foregroundStyle(ChatColors.muted).frame(width: 28)
                            Text("高级").foregroundStyle(ChatColors.ink)
                            Spacer(minLength: 0)
                            Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down").font(.footnote.weight(.semibold))
                                .foregroundStyle(ChatColors.muted)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("hostAdvanced")
                        .accessibilityValue(showsAdvanced ? String(localized: "已展开") : String(localized: "已收起"))
                }.listRowBackground(ChatColors.chip)
                #endif
                if showsSSH {
                    Section {
                        ForEach(sshHosts) { profile in
                            HStack(spacing: 12) {
                                Button { use(profile) } label: { hostRow(profile, symbol: "terminal") }.buttonStyle(.plain)
                                Button { editing = profile } label: { Image(systemName: "gearshape").foregroundStyle(ChatColors.muted) }
                                    .buttonStyle(.borderless).accessibilityLabel("编辑")
                            }
                        }
                        #if os(iOS)
                        Button { editing = HostProfile() } label: {
                            settingsRow("plus", String(localized: "添加 SSH 主机"))
                        }.accessibilityIdentifier("addSSHHost")
                        if let connectByAddress {
                            Button { connectByAddress() } label: {
                                settingsRow("link", String(localized: "使用主机地址连接"))
                            }.accessibilityIdentifier("connectByAddress")
                        }
                        #endif
                    } header: { Text("SSH 主机") }.listRowBackground(ChatColors.chip)
                }
                if showsRestore {
                    Section {
                        Toggle("启动时连接上次使用的设备", isOn: $restoreHost)
                    }.listRowBackground(ChatColors.chip)
                }
            }
        }
            .foregroundStyle(ChatColors.ink)
            .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
            .disabled(connecting != nil)
            .overlay {
                if connecting != nil {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Button("取消", role: .cancel) { cancelConnection() }
                    }.padding().background(ChatColors.panel, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            #if os(iOS)
            .navigationTitle("我的设备")
            #else
            .navigationTitle("我的电脑")
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                if !pushed {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { cancelConnection(); dismiss() } }
                }
            }
            .navigationDestination(item: $editing) { profile in
                SSHHostForm(profile: profile) { saved, isNew in
                    editing = nil
                    if isNew && active == nil, let saved { use(saved) }
                    if saved == nil { forgotten(profile) }
                }
            }
            #if os(macOS)
            .sheet(isPresented: $pairing, onDismiss: pairDismissed) { pairView }
            #else
            .fullScreenCover(isPresented: $pairing, onDismiss: pairDismissed) { pairView }
            #endif
            .alert(Text("已连上「\(fresh?.profile.name ?? "")」"),
                   isPresented: Binding(get: { fresh != nil }, set: { if !$0 { fresh = nil } }), presenting: fresh) { item in
                #if os(macOS)
                Button("留在本机，让 AI 指挥这台电脑") {
                    discardFresh(item)
                    stayOnLocalDevice()
                }
                #endif
                Button("把对话切到这台电脑") {
                    fresh = nil
                    connected(item.profile, item.tunnel)
                    dismiss()
                }
                Button("好", role: .cancel) { discardFresh(item) }
            } message: { _ in
                #if os(iOS)
                Text("回到对话，直接说要这台电脑做什么。")
                #endif
            }
            .confirmationDialog(choosing.map(Self.title) ?? "", isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                                titleVisibility: .visible, presenting: choosing) { profile in
                Button("留在本机，让 AI 指挥这台电脑") { stayOnLocalDevice() }
                Button("把对话切到这台电脑") { use(profile) }
                Button("取消", role: .cancel) {}
            }
            .alert("删除「\(removing.map(Self.title) ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { profile in
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { forget(profile) }
            } message: { profile in
                #if os(macOS)
                Text("删除本机上的连接记录和凭据。远程对话会保留。")
                #else
                profile.kind == .paired ? Text("手机不再连接这台电脑，电脑上的对话保留。")
                    : Text("删除手机上的主机设置、密码和私钥，主机上的对话保留。")
                #endif
            }
            .hostKeyPrompt($prompt)
            .sshLaunchPrompt($launchPrompt)
            .remoteConnectionAlert($connectionError)
        .onDisappear {
            cancelConnection()
            if let fresh { discardFresh(fresh) }
            if let arriving {
                self.arriving = nil
                Task { await arriving.tunnel.close() }
            }
        }
        .desktopSheet(width: 660, height: 480)
        .task {
            // Looks again every few seconds while the page is open: computers come and go.
            while !Task.isCancelled {
                let found = await PallasHostFinder.look()
                if !Task.isCancelled {
                    if found.hosts != nearby { withAnimation { nearby = found.hosts } }
                    if found.denied != networkDenied { networkDenied = found.denied }
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var pairView: some View {
        LanPairPage { profile, tunnel in
            #if os(iOS)
            EmbeddedEngine.shared.macHostsChanged()
            if !localUsable { connected(profile, tunnel); dismiss(); pairing = false; return }
            #endif
            arriving = Fresh(profile: profile, tunnel: tunnel)
            pairing = false
        }
    }

    private func pairDismissed() {
        guard let arriving else { return }
        self.arriving = nil
        if localUsable { fresh = arriving }
        else { connected(arriving.profile, arriving.tunnel); dismiss() }
    }

    private func discardFresh(_ item: Fresh) {
        fresh = nil
        Task { await item.tunnel.close() }
    }

    private static func title(_ profile: HostProfile) -> String { profile.name.isEmpty ? profile.address : profile.name }

    /// A paired computer can take tasks from the local engine or host the conversation itself.
    private func tapped(_ profile: HostProfile) {
        if localUsable { choosing = profile } else { use(profile) }
    }

    private func stayOnLocalDevice() {
        switchToPhone?()
        dismiss()
    }

    private func activeCard(_ active: ActiveRemoteHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isPaired(active) ? "desktopcomputer" : "terminal")
                .foregroundStyle(ChatColors.adaptive(0x337e72, 0x92cbb8))
                .frame(width: 40, height: 40).background(Color.teal.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("对话正在「\(active.name)」上").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(active.connected ? Color(red: 0.48, green: 0.76, blue: 0.64) : ChatColors.muted).frame(width: 7, height: 7)
                    Text(statusLine(active)).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let switchToPhone {
                Button("切回本机") { switchToPhone(); dismiss() }.buttonStyle(.borderless).font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("switchToPhone")
            }
        }.padding(.vertical, 6).listRowBackground(ChatColors.chip).accessibilityElement(children: .contain)
    }

    /// A paired computer's status says nothing of the SSH underneath.
    private func statusLine(_ active: ActiveRemoteHost) -> String {
        var shown = active
        shown.paired = isPaired(active)
        return shown.statusLine
    }

    private func isPaired(_ active: ActiveRemoteHost) -> Bool {
        active.paired || hosts.contains { $0.id == active.profileID && $0.kind == .paired }
    }

    private func settingsRow(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.tint).frame(width: 28)
            Text(title).foregroundStyle(ChatColors.ink)
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }

    private func hostRow(_ profile: HostProfile, symbol: String) -> some View {
        let current = active?.profileID == profile.id
        return HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(ChatColors.muted).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(profile)).foregroundStyle(ChatColors.ink).lineLimit(1)
                // An SSH host is told apart by its address; a paired computer by its name alone.
                if profile.kind == .ssh {
                    Text(verbatim: profile.address).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if current, let active {
                HStack(spacing: 5) {
                    Circle().fill(active.connected ? Color(red: 0.48, green: 0.76, blue: 0.64) : ChatColors.muted).frame(width: 7, height: 7)
                    Text(active.connected ? "对话在这里" : "未连接").font(.caption)
                }.foregroundStyle(ChatColors.muted)
            }
        }.contentShape(Rectangle()).accessibilityElement(children: .combine).accessibilityAddTraits(current ? .isSelected : [])
    }

    /// Makes [profile] the active host; first reads and confirms its key when it has none yet.
    private func use(_ profile: HostProfile) {
        if active?.profileID == profile.id, active?.connected == true { dismiss(); return }
        guard connecting == nil else { return }
        connecting = profile.id; issue = nil
        connectionTask = Task {
            defer { if !Task.isCancelled { connecting = nil; connectionTask = nil } }
            do {
                guard let target = try await HostKeyPrompt.verify(profile, remember: true, stored: $stored, prompt: $prompt) else { return }
                try Task.checkCancellation()
                let secrets = try HostVault.secrets(target.id)
                let tunnel = try await SSHTunnel.open(target, secret: secrets.secret, passphrase: secrets.passphrase, token: secrets.token,
                                                      ask: SSHLaunchPrompt.asker($launchPrompt))
                guard !Task.isCancelled else { await tunnel.close(); return }
                connected(target, tunnel)
                dismiss()
            } catch { if !Task.isCancelled { connectionError = SSHFailure.explain(error, at: .connect) } }
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connecting = nil
        prompt?.decide(false)
        prompt = nil
        launchPrompt?.decide(false)
        launchPrompt = nil
    }

    private func forget(_ profile: HostProfile) {
        do {
            var copy = stored
            try HostVault.forget(profile, from: &copy)
            stored = copy
            SSHReports.shared.forget(profile.id)
            forgotten(profile)
        }
        catch { issue = error.localizedDescription }
    }
}

// MARK: - 添加 SSH 主机 / 编辑主机

/// One SSH host: 基本信息, 登录方式 (密码 | 私钥), DSH (the running `dsh web`'s
/// port and launch token), 主机指纹 (confirmed on first connect), 删除这台主机,
/// then 测试连接 and 保存.
struct SSHHostForm: View {
    let isNew: Bool
    /// The saved profile (and whether it is new), or nil after 删除这台主机.
    let finished: (HostProfile?, Bool) -> Void

    @AppStorage("hostProfiles") private var stored = Data()
    @State private var config: HostProfile
    @State private var portText: String
    @State private var usesKey = false
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var token = ""
    @State private var harnessPortText: String
    @State private var startsDSH: Bool
    @State private var launchCommand: String
    @State private var workingDirectory: String
    @State private var launchPrompt: SSHLaunchPrompt?
    @State private var reveal = false
    @State private var keyFor: String
    @State private var errors: [Field: String] = [:]
    @State private var formError: String?
    @State private var note: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var testError: HostError?
    @State private var result: (ok: Bool, text: String)?
    @State private var saving = false
    @State private var importing = false
    private var savedProfile: HostProfile? {
        (try? JSONDecoder().decode([HostProfile].self, from: stored))?.first { $0.id == config.id }
    }
    private func matchesSaved(_ target: HostProfile) -> Bool {
        guard let saved = savedProfile else { return false }
        return saved.address == target.address && saved.port == target.port
    }
    @State private var removing = false
    @State private var prompt: HostKeyPrompt?

    private enum Field { case host, user, port, password, key }

    init(profile: HostProfile, finished: @escaping (HostProfile?, Bool) -> Void) {
        self.finished = finished
        isNew = profile.address.isEmpty
        _config = State(initialValue: profile)
        _portText = State(initialValue: String(profile.port))
        _harnessPortText = State(initialValue: String(profile.harnessPort))
        _startsDSH = State(initialValue: profile.launchCommand != nil)
        _launchCommand = State(initialValue: profile.launchCommand ?? SSHLaunch.defaultCommand)
        _workingDirectory = State(initialValue: profile.workingDirectory ?? "")
        _keyFor = State(initialValue: profile.fingerprint.isEmpty ? "" : profile.address + ":" + String(profile.port))
    }

    private var address: String { config.address.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + portText.trimmingCharacters(in: .whitespaces) }
    private var displayedTrust: HostProfile? {
        if let saved = savedProfile, !saved.fingerprint.isEmpty,
           saved.address + ":" + String(saved.port) == address { return saved }
        return !config.fingerprint.isEmpty && keyFor == address ? config : nil
    }

    var body: some View {
        Form {
            Section("基本信息") {
                LabeledContent("名称") { TextField("比如：电脑、家里的 Mac", text: $config.name).multilineTextAlignment(.trailing) }
                field(.host) {
                    LabeledContent("主机") {
                        TextField("192.168.1.20 或 example.com", text: $config.address).urlKeyboard().font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                }
                field(.user) {
                    LabeledContent("用户名") { TextField("me", text: $config.username).font(.body.monospaced()).multilineTextAlignment(.trailing) }
                }
                field(.port) {
                    LabeledContent("端口") { TextField("22", text: $portText).numericKeyboard().font(.body.monospaced()).multilineTextAlignment(.trailing) }
                }
            }
            Section {
                Picker("登录方式", selection: $usesKey) {
                    Text("密码").tag(false)
                    Text("私钥").tag(true)
                }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                if usesKey {
                    field(.key) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("私钥")
                                Spacer()
                                Button("从文件导入") { importing = true }.buttonStyle(.borderless).font(.footnote)
                                Button("粘贴") { if let text = PlatformPasteboard.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { privateKey = text } }
                                    .buttonStyle(.borderless).font(.footnote)
                            }
                            TextField("-----BEGIN OPENSSH PRIVATE KEY-----\n…", text: $privateKey, axis: .vertical)
                                .lineLimit(3...6).font(.caption.monospaced())
                        }
                    }
                    SecureField("私钥密码（可选）", text: $passphrase)
                } else {
                    field(.password) {
                        HStack {
                            Group {
                                if reveal { TextField("密码", text: $password) } else { SecureField("密码", text: $password) }
                            }.textContentType(.password)
                            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless).foregroundStyle(ChatColors.muted).accessibilityLabel(reveal ? "隐藏" : "显示")
                        }
                    }
                }
            } header: { Text("登录方式") }
            Section {
                Picker("启动方式", selection: $startsDSH) {
                    Text("连接已在运行的").tag(false)
                    Text("通过 SSH 启动").tag(true)
                }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets()).accessibilityIdentifier("sshLaunchMode")
                if startsDSH {
                    LabeledContent("启动命令") {
                        TextField(SSHLaunch.defaultCommand, text: $launchCommand).font(.body.monospaced()).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("工作目录") {
                        TextField("可选，比如 ~/code", text: $workingDirectory).font(.body.monospaced()).multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("端口") { TextField("3080", text: $harnessPortText).numericKeyboard().font(.body.monospaced()).multilineTextAlignment(.trailing) }
                    SecureField("启动令牌", text: $token)
                }
            } header: { Text("Pallas 服务") }
            Section("主机指纹") {
                if let displayedTrust {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayedTrust.hostKeyType ?? "SHA256").font(.caption2.monospaced()).foregroundStyle(ChatColors.muted)
                            Text(verbatim: displayedTrust.fingerprint.hasPrefix("SHA256:") ? displayedTrust.fingerprint : "SHA256:" + displayedTrust.fingerprint)
                                .font(.caption.monospaced()).foregroundStyle(ChatColors.ink).textSelection(.enabled)
                        }
                        Spacer(minLength: 4)
                        Text(savedProfile.map { $0.address + ":" + String($0.port) == address && $0.fingerprint == displayedTrust.fingerprint } == true ? "已记住" : "保存主机后记住")
                            .font(.caption).foregroundStyle(ChatColors.muted)
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "touchid").foregroundStyle(ChatColors.muted)
                        Text("还没有确认")
                    }
                }
            }
            if testing || result?.ok == true {
                Section {
                    HStack(spacing: 10) {
                        if testing { ProgressView(); Text("正在测试") }
                        else if let result {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.ok ? Color.green : DrawerPalette.warning)
                            Text(result.text).font(.subheadline)
                        }
                    }
                }
            }
            if let formError { Text(formError).font(.footnote).foregroundStyle(DrawerPalette.danger) }
            if let note { Text(note).font(.footnote).foregroundStyle(ChatColors.muted) }
            if !isNew || SSHReports.shared.reports[config.id] != nil {
                Section { SSHConnectionSummary(profileID: config.id) }
            }
            if !isNew {
                Section {
                    Button(role: .destructive) { removing = true } label: { Label("删除这台主机", systemImage: "trash").frame(maxWidth: .infinity) }
                }
            }
        }
        .disabled(testing)
        .noAutomaticCapitalization().autocorrectionDisabled()
        .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle(isNew ? "添加 SSH 主机" : "编辑主机").inlineNavigationTitle()
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if testing {
                    Button("取消", role: .cancel) { cancelTest() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                } else {
                    Button { test() } label: {
                        Label("测试连接", systemImage: "bolt.horizontal").frame(maxWidth: .infinity, minHeight: 34)
                    }.buttonStyle(.bordered)
                }
                Button { save() } label: { Text("保存").frame(maxWidth: .infinity, minHeight: 34) }.prominentButton().disabled(testing)
            }.disabled(saving).padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
        }
        .task { load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { picked in
            do {
                let url = try picked.get()
                let access = url.startAccessingSecurityScopedResource()
                #if os(iOS)
                guard access else { throw HostError(String(localized: "无法读取私钥文件。")) }
                #endif
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
                guard size <= 256 * 1024 else { throw HostError(String(localized: "无法读取私钥文件。")) }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard SSHUserKey.looksLikePrivateKey(text) else { note = String(localized: "这不是私钥文件，请选不带 .pub 的那个（例如 id_ed25519、id_rsa、id_ecdsa）"); return }
                privateKey = text.trimmingCharacters(in: .whitespacesAndNewlines); errors[.key] = nil
                note = String(localized: "已导入私钥，原文件可以删掉了")
            } catch { note = String(localized: "没能读取：") + error.localizedDescription }
        }
        .alert("删除「\(config.name.isEmpty ? config.address : config.name)」？", isPresented: $removing) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do { var copy = stored; try HostVault.forget(config, from: &copy); stored = copy; SSHReports.shared.forget(config.id); finished(nil, false) }
                catch { formError = error.localizedDescription }
            }
        } message: {
            #if os(macOS)
            Text("删除本机上的连接记录和凭据。远程对话会保留。")
            #else
            Text("删除手机上的主机设置、密码和私钥，主机上的对话保留。")
            #endif
        }
        .hostKeyPrompt($prompt)
        .sshLaunchPrompt($launchPrompt)
        .remoteConnectionAlert($testError)
        .onChange(of: result?.text) { _, _ in
            if let result, !result.ok { testError = HostError(String(localized: "连接测试失败"), detail: result.text) }
        }
        .onDisappear { cancelTest() }
    }

    private func cancelTest() {
        testTask?.cancel(); testTask = nil; testing = false
        prompt?.decide(false); prompt = nil
        launchPrompt?.decide(false); launchPrompt = nil
    }

    private func field<Content: View>(_ name: Field, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let error = errors[name] { Text(error).font(.caption).foregroundStyle(DrawerPalette.danger) }
        }
    }

    private func load() {
        guard !isNew else { return }
        do {
            let secrets = try HostVault.secrets(config.id)
            usesKey = secrets.secret.contains("PRIVATE KEY-----")
            if usesKey { privateKey = secrets.secret } else { password = secrets.secret }
            passphrase = secrets.passphrase; token = secrets.token
        } catch { formError = error.localizedDescription }
    }

    /// The profile as typed; nil (with the fields' problems shown) when incomplete.
    private func draft() -> HostProfile? {
        var next = config
        next.address = config.address.trimmingCharacters(in: .whitespacesAndNewlines)
        next.username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        var problems: [Field: String] = [:]
        if next.address.isEmpty { problems[.host] = String(localized: "填写主机地址（IP 或域名）") }
        if next.username.isEmpty { problems[.user] = String(localized: "填写登录用户名") }
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) { next.port = port } else { problems[.port] = "1–65535" }
        if usesKey {
            if !SSHUserKey.looksLikePrivateKey(privateKey) { problems[.key] = String(localized: "粘贴私钥（以 -----BEGIN 开头的整段文本）") }
            else {
                do { _ = try SSHUserKey.parse(privateKey, passphrase: passphrase) }
                catch { problems[.key] = HostError.explain(error) }
            }
        } else if password.isEmpty { problems[.password] = String(localized: "填写 SSH 密码，或改用私钥") }
        if let port = Int(harnessPortText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) { next.harnessPort = port }
        else if !startsDSH { formError = String(localized: "服务端口需要 1–65535") }
        next.launch = startsDSH ? .start(command: launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? SSHLaunch.defaultCommand : launchCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                                         directory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
                                : .existing
        errors = problems
        guard problems.isEmpty, startsDSH || Int(harnessPortText.trimmingCharacters(in: .whitespaces)).map({ (1...65535).contains($0) }) == true else { return nil }
        formError = nil
        if next.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next.name = next.address }
        if keyFor != next.address + ":" + String(next.port) { next.fingerprint = ""; next.hostKeyType = nil }
        if matchesSaved(next), let saved = savedProfile {
            next.fingerprint = saved.fingerprint
            next.hostKeyType = saved.hostKeyType
        }
        return next
    }

    private var secret: String { usesKey ? privateKey.trimmingCharacters(in: .whitespacesAndNewlines) : password }

    private func test() {
        guard let profile = draft() else { return }
        testing = true; result = nil; note = nil
        testTask = Task {
            defer { if !Task.isCancelled { testing = false; testTask = nil } }
            do {
                let remember = matchesSaved(profile)
                guard let target = try await HostKeyPrompt.verify(profile, remember: remember, stored: $stored, prompt: $prompt) else {
                    return
                }
                try Task.checkCancellation()
                config.fingerprint = target.fingerprint
                config.hostKeyType = target.hostKeyType
                keyFor = target.address + ":" + String(target.port)
                let trust = remember ? String(localized: "主机指纹已记住") : String(localized: "保存主机后将记住此指纹")
                let tunnel: SSHTunnel
                do { tunnel = try await SSHTunnel.open(target, secret: secret, passphrase: passphrase, token: token, ask: SSHLaunchPrompt.asker($launchPrompt)) }
                catch { if !Task.isCancelled { result = (false, HostError.explain(error)) }; return }
                defer { Task { await tunnel.close() } }
                try Task.checkCancellation()
                let endpoint = SSHReports.shared.reports[target.id]?.remoteEndpoint ?? String(localized: "端口 \(target.harnessPort)")
                do {
                    let harness = try Harness(address: tunnel.address)
                    defer { harness.close() }
                    try await harness.authenticate(token: tunnel.token, timeout: 10)
                    try Task.checkCancellation()
                    SSHReportRecorder.recordAuth(target.id, ok: true, detail: String(localized: "令牌有效"))
                    result = (true, String(localized: "SSH 已连接，\(trust)；服务认证成功（\(endpoint)）。"))
                } catch {
                    guard !Task.isCancelled else { return }
                    let detail = (error as? HostError)?.message ?? String(localized: "无法连接电脑上的 Pallas 服务。")
                    SSHReportRecorder.recordAuth(target.id, ok: false, detail: detail)
                    result = (false, String(localized: "SSH 已连接，\(trust)；服务认证失败：\(detail)（\(endpoint)）"))
                }
            } catch { if !Task.isCancelled { result = (false, HostError.explain(error)) } }
        }
    }

    private func save() {
        guard let profile = draft() else { return }
        saving = true
        defer { saving = false }
        do {
            var copy = stored
            try HostVault.save(profile, secret: secret, passphrase: usesKey ? passphrase : "", token: token, into: &copy)
            stored = copy
            finished(profile, isNew)
        } catch { formError = String(localized: "没能保存") }
    }


}

// MARK: - 扫码连接电脑

struct HostPairingCode {
    let address: String
    let port: Int
    let pin: String
    let invite: String
    let name: String
    let alternates: [String]

    static func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "dshlocal" && url.host?.lowercased() == "lan" && url.path == "/pair"
    }

    static func parse(_ text: String) -> Self? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4_096, let url = URL(string: text), accepts(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil,
              let fragment = parts.percentEncodedFragment,
              let fields = URLComponents(string: "https://localhost?" + fragment.replacingOccurrences(of: "+", with: "%20")),
              fields.fragment == nil,
              let items = fields.queryItems, Set(items.map(\.name)).count == items.count else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["v"] == "1", let address = values["host"], PairedReach.valid([address]) == [address],
              let value = values["port"], let port = Int(value), (1...65535).contains(port),
              let invite = values["invite"], invite.range(of: #"^[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil,
              let fingerprint = values["pin"] else { return nil }
        let pin = digest(fingerprint)
        guard pin.utf8.count == 43, Data(base64Encoded: pin + "=")?.count == 32 else { return nil }
        let alternates = PairedReach.valid((values["alt"] ?? "").split(separator: ",").prefix(16).map(String.init))
        let name = values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(address: address, port: port, pin: pin, invite: invite, name: name.isEmpty ? address : String(name.prefix(120)),
                    alternates: alternates.filter { $0 != address })
    }

    private static func digest(_ fingerprint: String) -> String {
        fingerprint.hasPrefix("SHA256:") ? String(fingerprint.dropFirst(7)) : fingerprint
    }

    @MainActor
    func connect(among hosts: [HostProfile]) async throws -> (profile: HostProfile, secret: String, tunnel: SSHTunnel) {
        let saved = hosts.first { $0.kind == .paired && Self.digest($0.fingerprint) == pin }
        var config = saved ?? HostProfile()
        var secret = try saved.map { try Vault.read($0.id.uuidString) } ?? ""
        if secret.isEmpty {
            let identity = SSHTunnel.identity()
            secret = identity.secret
            config.username = identity.username
        }
        config.kind = .paired
        config.fingerprint = pin
        config.address = address
        config.port = port
        config.name = name
        config.alternateAddress = nil
        config.alternateAddresses = alternates.isEmpty ? nil : alternates
        let tunnel = try await SSHTunnel.open(config, secret: secret, passphrase: "", token: "", invite: invite)
        do {
            let harness = try Harness(address: tunnel.address)
            defer { harness.close() }
            try await harness.authenticate(token: tunnel.token, timeout: 10)
            try Task.checkCancellation()
            if let first = tunnel.reportedAddresses.first {
                config.address = first
                let others = Array(tunnel.reportedAddresses.dropFirst())
                config.alternateAddresses = others.isEmpty ? nil : others
            }
            return (config, secret, tunnel)
        } catch {
            await tunnel.close()
            throw error
        }
    }
}

/// Opens the scanner at once; a `dshlocal://lan/pair` code pairs, saves the
/// computer and switches to it.
struct LanPairPage: View {
    /// A code that arrived as a link (the system camera opened it): paired at once, no scanner.
    var code: String? = nil
    let paired: (HostProfile, SSHTunnel) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hostProfiles") private var stored = Data()
    @State private var working = false
    @State private var pairTask: Task<Void, Never>?
    @State private var error: String?
    @State private var link = ""
    #if os(macOS)
    @State private var pickingImage = false
    @State private var showingCamera = false
    #else
    @State private var scanning = true
    @State private var photo: PhotosPickerItem?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// Read again when the person answers the camera question or comes back from 设置.
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    private var scannerReady: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }
    private var cameraRefused: Bool { camera == .denied || camera == .restricted }
    #endif
    private static var notACode: String { String(localized: "这不是配对码。请扫电脑或另一台手机、iPad 上显示的二维码。") }
    #if os(iOS)
    /// A phone or iPad that just paired by its code.
    @State private var pairedDevice: String?
    #endif
    private var hosts: [HostProfile] { (try? JSONDecoder().decode([HostProfile].self, from: stored)) ?? [] }

    var body: some View {
        NavigationStack {
            Group {
            #if os(macOS)
            Form {
                SecureField("配对链接", text: $link).accessibilityIdentifier("pairLink")
                    .onSubmit { handle(link) }.disabled(working)
                Button("读取配对链接") { handle(link) }.disabled(working || link.isEmpty)
                    .accessibilityIdentifier("readPairLink")
                Button("选择二维码图片", systemImage: "photo") { pickingImage = true }.disabled(working)
                Button("扫码连接", systemImage: "qrcode.viewfinder") { showingCamera = true }.disabled(working)
                if working { ProgressView("连接中…") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $pickingImage, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
                    guard size <= 20 * 1024 * 1024, let code = Self.decodeQR(try Data(contentsOf: url, options: .mappedIfSafe)) else {
                        error = Self.notACode
                        return
                    }
                    handle(code)
                } catch { if (error as NSError).code != NSUserCancelledError { self.error = Self.notACode } }
            }
            .sheet(isPresented: $showingCamera) {
                MacPairingCameraSheet { code in showingCamera = false; handle(code) }
            }
            #else
            ZStack {
                if scannerReady && scanning && !working && error == nil {
                    PairScanner { code in handle(code) }.ignoresSafeArea()
                    VStack {
                        Spacer()
                        photoButton.prominentButton().padding(.top, 12).padding(.bottom, 28)
                    }
                } else {
                    VStack(spacing: 14) {
                        Spacer()
                        if working { ProgressView() }
                        else {
                            Text(error ?? (cameraRefused ? String(localized: "没有相机权限，扫不了码") : String(localized: "这台设备扫不了码，可以选一张配对码的图片")))
                                .multilineTextAlignment(.center).padding(.horizontal, 24)
                            if scannerReady { Button("重试") { error = nil; scanning = true } }
                            else if cameraRefused {
                                Button("打开设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                                    .prominentButton().accessibilityIdentifier("cameraOpenSettings")
                            }
                            photoButton
                            if !scannerReady {
                                SecureField("配对链接", text: $link).textFieldStyle(.roundedBorder).padding(.horizontal, 32)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                Button("读取配对链接") { handle(link) }.disabled(link.isEmpty)
                            }
                        }
                        Spacer()
                    }.foregroundStyle(ChatColors.ink).frame(maxWidth: .infinity).background(ChatColors.canvas.ignoresSafeArea())
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let code = Self.decodeQR(data) else {
                        error = Self.notACode; return
                    }
                    handle(code)
                }
            }
            #endif
            }
            .navigationTitle("扫码连接").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { pairTask?.cancel(); dismiss() } } }
        }
        .desktopSheet(width: 510, height: 330)
        .onAppear {
            guard let code, pairTask == nil else { return }
            #if os(macOS)
            link = code
            #else
            handle(code)
            #endif
        }
        .onDisappear { pairTask?.cancel() }
        #if os(iOS)
        .task(id: scenePhase) {
            guard scenePhase == .active, code == nil else { return }
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
            camera = AVCaptureDevice.authorizationStatus(for: .video)
        }
        .remoteConnectionAlert(Binding(get: { error.map { HostError(String(localized: "没有连上"), detail: $0) } },
                                       set: { if $0 == nil { error = nil; scanning = true } }))
        .alert(String(localized: "已和「\(pairedDevice ?? "")」配对"), isPresented: Binding(get: { pairedDevice != nil }, set: { if !$0 { pairedDevice = nil } })) {
            // Closing the page while the alert is still going away is ignored; wait for it.
            Button("好") { Task { try? await Task.sleep(for: .milliseconds(350)); dismiss() } }
        }
        #endif
    }

    #if os(iOS)
    private var photoButton: some View {
        PhotosPicker(selection: $photo, matching: .images) { Label("选择二维码图片", systemImage: "photo") }.disabled(working)
    }
    #endif

    static func decodeQR(_ data: Data) -> String? {
        guard let image = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    private func handle(_ code: String) {
        guard !working else { return }
        #if os(iOS)
        scanning = false
        #endif
        guard let invitation = HostPairingCode.parse(code) else {
            error = Self.notACode; return
        }
        working = true; error = nil
        pairTask = Task {
            defer { if !Task.isCancelled { working = false } }
            let result: (profile: HostProfile, secret: String, tunnel: SSHTunnel)
            do { result = try await invitation.connect(among: hosts) }
            catch { if !Task.isCancelled { self.error = Self.reason(error) }; return }
            guard !Task.isCancelled else { await result.tunnel.close(); return }
            do {
                var copy = stored
                try HostVault.save(result.profile, secret: result.secret, passphrase: "", token: "", into: &copy)
                stored = copy
            } catch {
                await result.tunnel.close()
                self.error = String(localized: "没能保存这台电脑。请在电脑上重新生成配对码，再扫一次。"); return
            }
            link = ""
            paired(result.profile, result.tunnel)
        }
    }

    /// Why pairing failed, in the person's words: `SSHTunnel.open` already tells a paired computer's failures plainly.
    private static func reason(_ error: Error) -> String {
        let used = String(localized: "这个配对码过期了，或者已经用过。请在电脑上重新生成，再扫一次。")
        if let host = error as? HostError { return host.code == "pair/refused" ? used : HostError.explain(host) }
        let text = String(describing: error)
        if text.contains("allAuthenticationOptionsFailed") || text.contains("authentication") { return used }
        return String(localized: "没能连上这台电脑")
    }
}
