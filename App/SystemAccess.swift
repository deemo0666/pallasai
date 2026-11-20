// 设置 › 通用 › 系统权限：按功能列出 iOS 上的授权，每次进入页面、从系统设置回来都重新读取。
// 还没问过的经那项功能本身的申请弹出系统询问；拒绝了的去系统设置里打开。
// 「AI › 权限」管的是模型在主机上能做什么，和这里无关。

import AVFoundation
import Contacts
import Darwin
import EventKit
import Network
import Photos
import Speech
import SwiftUI
import UserNotifications

/// An authorization declared in the app's Info.plist.
enum SystemPermission: String, CaseIterable, Identifiable {
    case camera, microphone, speech, photosAdd, localNetwork, notifications, calendar, reminders, contacts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: String(localized: "相机")
        case .microphone: String(localized: "麦克风")
        case .speech: String(localized: "语音识别")
        case .photosAdd: String(localized: "添加到照片")
        case .localNetwork: String(localized: "本地网络")
        case .notifications: String(localized: "通知")
        case .calendar: String(localized: "日历")
        case .reminders: String(localized: "提醒事项")
        case .contacts: String(localized: "通讯录")
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera"
        case .microphone: "mic"
        case .speech: "waveform"
        case .photosAdd: "photo.badge.plus"
        case .localNetwork: "wifi"
        case .notifications: "bell"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        }
    }

    /// The Info.plist key that lets the app ask; notifications need none.
    var usageKey: String? {
        switch self {
        case .camera: "NSCameraUsageDescription"
        case .microphone: "NSMicrophoneUsageDescription"
        case .speech: "NSSpeechRecognitionUsageDescription"
        case .photosAdd: "NSPhotoLibraryAddUsageDescription"
        case .localNetwork: "NSLocalNetworkUsageDescription"
        case .notifications: nil
        // Adding events needs only the write-only key; reading the calendar needs the full one.
        case .calendar: "NSCalendarsWriteOnlyAccessUsageDescription"
        case .reminders: "NSRemindersFullAccessUsageDescription"
        case .contacts: "NSContactsUsageDescription"
        }
    }

    var declared: Bool { usageKey.map { Bundle.main.object(forInfoDictionaryKey: $0) != nil } ?? true }
}

/// The features that need them, in the page's order.
enum SystemFeature: String, CaseIterable, Identifiable {
    case scan, voice, savePhoto, lanHost, notify, schedule, people
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: String(localized: "扫码连接电脑")
        case .voice: String(localized: "语音输入")
        case .savePhoto: String(localized: "保存对话图片")
        case .lanHost: String(localized: "找到并连接附近的电脑")
        case .notify: String(localized: "回复通知")
        case .schedule: String(localized: "日程和提醒")
        case .people: String(localized: "找联系人、写信息")
        }
    }

    var permissions: [SystemPermission] {
        switch self {
        case .scan: [.camera]
        case .voice: [.microphone, .speech]
        case .savePhoto: [.photosAdd]
        case .lanHost: [.localNetwork]
        case .notify: [.notifications]
        case .schedule: [.calendar, .reminders]
        case .people: [.contacts]
        }
    }
}

enum PermissionState: Equatable {
    case granted, denied, restricted, notDetermined
    /// 日历 that may only add events, 通讯录 shared for some people only.
    case partial
    /// Not readable without trying (本地网络 before it was ever checked).
    case unknown
    /// Nothing to check against (本地网络 without Wi-Fi).
    case unavailable(String)

    var label: String {
        switch self {
        case .granted: String(localized: "已允许")
        case .denied: String(localized: "已拒绝")
        case .restricted: String(localized: "受限制")
        case .notDetermined: String(localized: "还没问过你")
        case .partial: String(localized: "部分允许")
        case .unknown: String(localized: "点一下检查")
        case .unavailable: String(localized: "现在查不了")
        }
    }
}

/// Reads and asks for each permission the way the feature that uses it does.
@MainActor
enum SystemAccess {
    static func read(_ permission: SystemPermission) async -> PermissionState {
        switch permission {
        case .camera: return state(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            #if os(macOS)
            return state(AVCaptureDevice.authorizationStatus(for: .audio))
            #else
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .notDetermined
            }
            #endif
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .photosAdd: return state(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .ephemeral: return .granted
            case .denied: return .denied
            // Delivered quietly: banners are still to be asked for.
            case .provisional: return .notDetermined
            default: return .notDetermined
            }
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .writeOnly: return .partial
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: return .granted
            case .denied, .writeOnly: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .contacts:
            let status = CNContactStore.authorizationStatus(for: .contacts)
            #if os(iOS)
            if #available(iOS 18.0, *), status == .limited { return .partial }
            #endif
            switch status {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .localNetwork:
            // Checking connects to the LAN, which asks the first time: only once it was checked.
            guard UserDefaults.standard.bool(forKey: LocalNetworkProbe.checkedKey) else { return .unknown }
            return await LocalNetworkProbe.check()
        }
    }

    /// Asks the system, as the feature would on first use; returns where it stands after.
    static func request(_ permission: SystemPermission) async -> PermissionState {
        switch permission {
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            #if os(macOS)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            #else
            _ = await AVAudioApplication.requestRecordPermission()
            #endif
        case .speech: _ = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        case .photosAdd: _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .calendar:
            // First use only adds events; from 部分允许 a tap asks to read the calendar too.
            let store = AppleData.shared.events
            if EKEventStore.authorizationStatus(for: .event) == .writeOnly { _ = try? await store.requestFullAccessToEvents() }
            else { _ = try? await store.requestWriteOnlyAccessToEvents() }
        case .reminders: _ = try? await AppleData.shared.events.requestFullAccessToReminders()
        case .contacts:
            #if os(iOS)
            if #available(iOS 18.0, *), CNContactStore.authorizationStatus(for: .contacts) == .limited { await ContactSharing.pick() }
            else { _ = try? await AppleData.shared.contacts.requestAccess(for: .contacts) }
            #else
            _ = try? await AppleData.shared.contacts.requestAccess(for: .contacts)
            #endif
        case .localNetwork:
            UserDefaults.standard.set(true, forKey: LocalNetworkProbe.checkedKey)
            return await LocalNetworkProbe.check(waitForAnswer: true)
        }
        return await read(permission)
    }

    private static func state(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    private static func state(_ status: PHAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .limited: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    static func settingsURL(for permission: SystemPermission) -> URL? {
        #if os(macOS)
        let pane: String
        switch permission {
        case .calendar: pane = "Privacy_Calendars"
        case .reminders: pane = "Privacy_Reminders"
        case .contacts: pane = "Privacy_Contacts"
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        default: pane = ""
        }
        let privacy = "x-apple.systempreferences:com.apple.preference.security"
        return URL(string: pane.isEmpty ? privacy : privacy + "?" + pane)
        #else
        URL(string: permission == .notifications ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString)
        #endif
    }
}

/// iOS has no call that reads 本地网络: a TCP attempt to the Wi-Fi router tells. Denied shows as a
/// path the system holds back for that reason; anything that reaches the router (even refused) is allowed.
enum LocalNetworkProbe {
    static let checkedKey = "localNetworkChecked"

    /// The phone's Wi-Fi IPv4 address and netmask.
    private static func wifiAddress() -> (ip: UInt32, mask: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard mask != 0, mask != .max else { continue }
            return (ip, mask)
        }
        return nil
    }

    /// The default IPv4 gateways in the routing table (`route.h` is not in the iOS SDK: the
    /// `rt_msghdr` layout is read by hand — 92 bytes, then the sockaddrs `rtm_addrs` lists).
    private static func defaultGateways() -> [UInt32] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, 2 /* NET_RT_FLAGS */, 0x2 /* RTF_GATEWAY */]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return [] }
        func u32(_ at: Int) -> UInt32 { buffer[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        var gateways: [UInt32] = []
        var offset = 0
        while offset + 92 <= size {
            let length = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8
            guard length > 0, offset + length <= size else { break }
            let addrs = u32(offset + 12)
            var cursor = offset + 92
            var destination: UInt32?, gateway: UInt32?
            for bit in 0..<8 where addrs & (1 << bit) != 0 {
                guard cursor + 2 <= offset + length else { break }
                let saLength = Int(buffer[cursor]), family = buffer[cursor + 1]
                if family == UInt8(AF_INET), saLength >= 8, cursor + 8 <= size {
                    let value = buffer[cursor + 4..<cursor + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    if bit == 0 { destination = value } else if bit == 1 { gateway = value }
                }
                cursor += saLength == 0 ? 4 : (saLength + 3) & ~3
            }
            if destination == 0, let gateway { gateways.append(gateway) }
            offset += length
        }
        return gateways
    }

    /// The Wi-Fi network's router: the default gateway on the phone's subnet, else `.1` of it.
    static func router() -> String? {
        guard let wifi = wifiAddress() else { return nil }
        let subnet = wifi.ip & wifi.mask
        let router = defaultGateways().first { $0 & wifi.mask == subnet && $0 != wifi.ip } ?? (subnet | 1)
        guard router != wifi.ip else { return nil }
        return [24, 16, 8, 0].map { String((router >> UInt32($0)) & 0xff) }.joined(separator: ".")
    }

    /// `waitForAnswer` gives the system prompt time to be answered.
    static func check(waitForAnswer: Bool = false) async -> PermissionState {
        guard let target = router() else { return .unavailable(String(localized: "没有连接 Wi-Fi")) }
        let connection = NWConnection(host: NWEndpoint.Host(target), port: 80, using: .tcp)
        let limit: Duration = waitForAnswer ? .seconds(60) : .seconds(3)
        let result: PermissionState = await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "local-network-probe")
            var answered = false
            func finish(_ state: PermissionState) {
                guard !answered else { return }
                answered = true
                connection.cancel()
                continuation.resume(returning: state)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.granted)
                case .failed(let error):
                    finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .denied : Self.reached(error) ? .granted : .unknown)
                case .waiting(let error):
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { finish(.denied) }
                    else if Self.reached(error) { finish(.granted) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(Int(limit.components.seconds))) {
                // Still going nowhere: the router does not answer on port 80, but nothing blocked it.
                finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .denied
                       : connection.currentPath?.status == .satisfied ? .granted : .unknown)
            }
        }
        if result != .unknown { UserDefaults.standard.set(true, forKey: checkedKey) }
        return result
    }

    /// Errors only a reachable router gives.
    private static func reached(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .ECONNREFUSED || code == .ECONNRESET || code == .ETIMEDOUT }
        return false
    }
}

/// 设置 › 权限 的最后一个分区：App 向 iOS 要的授权，按用到它的功能排序。
struct SystemAccessSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var states: [SystemPermission: PermissionState] = [:]
    @State private var asking: SystemPermission?

    private var permissions: [SystemPermission] {
        #if os(macOS)
        let audio: [SystemPermission] = VoiceRecorder.supported ? [.microphone] : []
        return ([.camera] + audio + [.calendar, .reminders, .contacts]).filter(\.declared)
        #else
        var seen = Set<SystemPermission>()
        return SystemFeature.allCases.filter { $0 != .voice || VoiceRecorder.supported }.flatMap(\.permissions).filter { $0.declared && seen.insert($0).inserted }
        #endif
    }

    var body: some View {
        Section {
            ForEach(permissions) { permission in row(permission) }
        } header: { Text("系统权限") }
        .listRowBackground(ChatColors.chip)
        // Entering the page, and coming back from 设置: read everything again.
        .task(id: scenePhase) { if scenePhase == .active { await refresh() } }
    }

    private func refresh() async {
        var next: [SystemPermission: PermissionState] = [:]
        for permission in permissions {
            next[permission] = await SystemAccess.read(permission)
        }
        states = next
    }

    private func color(_ state: PermissionState?) -> Color {
        switch state {
        case .granted: SettingsStyle.ok
        case .denied, .restricted: SettingsStyle.warning
        default: ChatColors.muted
        }
    }

    /// VoiceOver only: what a tap does.
    private func accessibilityHint(_ state: PermissionState?) -> String {
        switch state {
        case .denied: String(localized: "前往系统设置")
        case .notDetermined, .unknown, .unavailable, .partial: String(localized: "请求授权")
        default: ""
        }
    }

    private func row(_ permission: SystemPermission) -> some View {
        let state = states[permission]
        let busy = asking == permission
        return Button { Task { await act(permission, state) } } label: {
            HStack(spacing: 12) {
                Image(systemName: permission.symbol).font(.system(size: 17)).foregroundStyle(ChatColors.muted)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title).foregroundStyle(ChatColors.ink)
                    if case .unavailable(let why)? = state {
                        Text(why).font(.caption).foregroundStyle(ChatColors.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if busy { ProgressView() }
                else if let state {
                    Text(state.label).font(.subheadline).foregroundStyle(color(state)).lineLimit(1)
                }
                if state == .denied { Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(ChatColors.muted) }
            }.frame(minHeight: 54).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || state == nil)
        .accessibilityLabel(permission.title)
        .accessibilityValue(state?.label ?? String(localized: "正在读取…"))
        .accessibilityHint(accessibilityHint(state))
        .accessibilityIdentifier("systemAccess-" + permission.rawValue)
    }

    private func act(_ permission: SystemPermission, _ state: PermissionState?) async {
        switch state {
        case .denied:
            if let url = SystemAccess.settingsURL(for: permission) { openURL(url) }
        case .notDetermined, .unknown, .unavailable, .partial:
            asking = permission
            let after = await SystemAccess.request(permission)
            asking = nil
            states[permission] = after
        default: break
        }
    }
}
