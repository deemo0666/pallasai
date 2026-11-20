#if os(iOS)
import SwiftUI
import UIKit

/// One source of personal data the model may use: a system store on this iPhone or a signed-in mail account.
/// Each has two switches: the AI on this phone, and paired computers (through 允许电脑访问).
enum ConnectorID: String, CaseIterable, Identifiable, Codable {
    case calendar, reminders, contacts, gmail, outlook
    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: String(localized: "日历")
        case .reminders: String(localized: "提醒事项")
        case .contacts: String(localized: "通讯录")
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .gmail, .outlook: "envelope"
        }
    }

    var permission: SystemPermission? {
        switch self {
        case .calendar: .calendar
        case .reminders: .reminders
        case .contacts: .contacts
        case .gmail, .outlook: nil
        }
    }

    var mail: MailProvider? {
        switch self {
        case .gmail: .google
        case .outlook: .microsoft
        default: nil
        }
    }

    /// The app this connector stands for, probed with `canOpenURL` (the scheme is in LSApplicationQueriesSchemes).
    /// Calendar, Reminders and Contacts come with iOS.
    var appScheme: String? {
        switch self {
        case .gmail: "googlegmail://"
        case .outlook: "ms-outlook://"
        default: nil
        }
    }

    var installed: Bool {
        guard let scheme = appScheme else { return true }
        return URL(string: scheme).map { UIApplication.shared.canOpenURL($0) } ?? false
    }
}

/// Where a tool call comes from: the engine on this phone, or a paired computer.
enum ConnectorCaller { case phone, computer }

enum Connectors {
    static func key(_ id: ConnectorID, _ caller: ConnectorCaller) -> String {
        "connector." + id.rawValue + (caller == .phone ? ".phone" : ".computer")
    }

    /// The phone's own AI keeps what it had before connectors existed; computers start with nothing.
    static func allowed(_ id: ConnectorID, _ caller: ConnectorCaller) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key(id, caller)) != nil else { return caller == .phone }
        return defaults.bool(forKey: key(id, caller))
    }

    static func set(_ id: ConnectorID, _ caller: ConnectorCaller, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key(id, caller))
    }

    /// Which connector a tool call reads or writes; nil for tools that are not connectors (compose_message).
    static func connector(tool: String, action: String?, account: String?) -> ConnectorID? {
        switch tool {
        case "apple_calendar":
            return ["add_event", "find_events"].contains(action ?? "") ? .calendar : .reminders
        case "apple_contacts": return .contacts
        case "email":
            if let account { return MailProvider(account: account).map { $0 == .google ? .gmail : .outlook } }
            return nil
        default: return nil
        }
    }

    /// Connectors a computer may use now: switched on for computers and usable (permission given, account signed in).
    @MainActor static func offeredToComputers() -> [ConnectorID] {
        ConnectorID.allCases.filter { id in
            guard allowed(id, .computer) else { return false }
            if let provider = id.mail { return MailAccounts.shared.account(provider) != nil }
            return true
        }
    }
}
#endif
