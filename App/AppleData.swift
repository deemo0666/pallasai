import Contacts
import EventKit
import Foundation
#if os(iOS)
import ContactsUI
import MessageUI
import SwiftUI
import UIKit
#endif

/// The model's `apple_calendar`, `apple_contacts` and `compose_message` tools (Embedded/engine/apple-data.cjs):
/// Uses native Calendar, Reminders and Contacts, and opens a draft the person sends themselves.
@MainActor
final class AppleData {
    static let shared = AppleData()

    let events: EKEventStore
    let contacts: CNContactStore
    /// Open requests, so the engine can cancel one (its question to the person, or its form).
    private var running: [UUID: Task<String, Never>] = [:]
    #if os(iOS)
    private var composer: Composer?
    /// 「这一轮都允许」: "<turn>|<action>" for the rest of that turn, with when it was given.
    private var allowedForTurn: [String: Date] = [:]
    /// A question already out for that turn and action; the next write of the kind waits for its answer.
    private var asking: [String: Task<Void, Never>] = [:]
    #endif

    init(events: EKEventStore = EKEventStore(), contacts: CNContactStore = CNContactStore()) {
        self.events = events
        self.contacts = contacts
    }

    struct Request: Decodable, Sendable {
        let appleDataRequest: UUID
        let tool: String
        let args: Args
        let approval: String?
        /// 全自动: the calling conversation asks nothing (FullAuto).
        var auto: Bool? = nil
        /// The conversation turn that called, "<session>#<turn>"; absent for a computer's call.
        var turn: String? = nil
        /// Set for a paired computer's call; never read from the engine.
        var fromComputer = false

        private enum CodingKeys: String, CodingKey { case appleDataRequest, tool, args, approval, auto, turn }

        init(appleDataRequest: UUID, tool: String, args: Args, approval: String? = nil, fromComputer: Bool = false) {
            self.appleDataRequest = appleDataRequest; self.tool = tool; self.args = args
            self.approval = approval; self.fromComputer = fromComputer
        }
    }

    struct Cancel: Decodable { let appleDataCancel: UUID }

    struct Args: Decodable, Sendable {
        var action, title, start, end, location, notes, from, query, due, priority, list, id, kind, subject, body: String?
        /// email: gmail or outlook, and the message a reply answers.
        var account, replyTo: String?
        var allDay, includeCompleted: Bool?
        var alarmMinutes, limit: Int?
        /// A time for find_events, recipients for compose_message.
        var to: [String]?
        var cc: [String]?

        private enum Keys: String, CodingKey {
            case action, title, start, end, location, notes, from, query, due, priority, list, id, kind, subject, body, to, cc, limit, account
            case replyTo = "reply_to", allDay = "all_day", includeCompleted = "include_completed", alarmMinutes = "alarm_minutes"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func text(_ key: Keys) -> String? {
                if let value = try? c.decode(String.self, forKey: key) { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let value = try? c.decode(Double.self, forKey: key) { return String(value) }
                return nil
            }
            func texts(_ key: Keys) -> [String]? {
                if let list = try? c.decode([String].self, forKey: key) { return list }
                return text(key).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            }
            action = text(.action); title = text(.title); start = text(.start); end = text(.end); location = text(.location)
            notes = text(.notes); from = text(.from); query = text(.query); due = text(.due); priority = text(.priority)
            list = text(.list); id = text(.id); kind = text(.kind); subject = text(.subject); body = try? c.decode(String.self, forKey: .body)
            allDay = try? c.decode(Bool.self, forKey: .allDay); includeCompleted = try? c.decode(Bool.self, forKey: .includeCompleted)
            alarmMinutes = try? c.decode(Int.self, forKey: .alarmMinutes); limit = try? c.decode(Int.self, forKey: .limit)
            to = texts(.to); cc = texts(.cc); account = text(.account); replyTo = text(.replyTo)
        }
    }

    struct Failure: Error {
        let code: String, message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }

    func perform(_ request: Request) async -> String {
        let task = Task { await answer(request) }
        running[request.appleDataRequest] = task
        defer { running[request.appleDataRequest] = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancel(_ id: UUID) {
        running[id]?.cancel()
        #if os(iOS)
        PhoneConfirmation.shared.cancel(id)
        if composer?.owner == id { composer?.dismiss(.cancelled) }
        #elseif os(macOS)
        MacTaskConfirmation.shared.cancel(id)
        #endif
    }

    private func answer(_ request: Request) async -> String {
        let args = request.args
        var envelope: [String: Any] = ["tool": request.tool, "now": Self.local(Date()), "time_zone": TimeZone.current.identifier]
        if let action = args.action ?? args.kind { envelope["action"] = action }
        do {
            try Task.checkCancellation()
            #if os(iOS)
            try checkConnector(request)
            #endif
            switch request.tool {
            case "apple_calendar": envelope["data"] = try await calendar(request)
            case "apple_contacts": envelope["data"] = try await findContacts(args)
            case "compose_message": envelope["data"] = try await compose(args, owner: request.appleDataRequest)
            #if os(iOS)
            case "email": envelope["data"] = try await email(request)
            #endif
            default: throw Failure("invalid_args", "Unknown tool.")
            }
            envelope["ok"] = true
        } catch let failure as Failure {
            envelope["ok"] = false
            envelope["error"] = ["code": failure.code, "message": failure.message]
        } catch is CancellationError {
            envelope["ok"] = false
            envelope["error"] = ["code": "cancelled", "message": "The request was cancelled; nothing was changed."]
        } catch {
            envelope["ok"] = false
            envelope["error"] = ["code": "internal_error", "message": error.localizedDescription]
        }
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Asking the person

    /// Writes ask in every mode but 自动, the same rule phone steps use: adding to the calendar can be undone,
    /// but it is still their calendar. 付款和发送要刷脸 is stricter than 先问我, so it asks too.
    #if os(iOS)
    static var asksBeforeWriting: Bool { PhoneConfirmation.asks }
    #endif

    /// `always`: sending mail asks in every mode, 全程自动 included, and every message by itself.
    private func confirm(_ step: String, for request: Request, always: Bool = false) async throws {
        #if os(iOS)
        guard request.auto != true, always || Self.asksBeforeWriting else { return }
        // Calendar and reminder writes: one 「这一轮都允许」 covers the turn's later ones of the same action.
        let key = always ? nil : request.turn.map { "\($0)|\(request.args.action ?? request.tool)" }
        if let key {
            while let earlier = asking[key] { await earlier.value }
            try Task.checkCancellation()
            if allowedForTurn[key] != nil { return }
        }
        let question = Task { await PhoneConfirmation.shared.ask(step, owner: request.appleDataRequest, serious: always, offerAll: key != nil) }
        if let key { asking[key] = Task { _ = await question.value } }
        let (outcome, all) = await question.value  // cancel(_:) answers it 不允许
        if let key {
            asking[key] = nil
            if outcome == .allowed, all {
                // A turn lasts minutes, rarely hours; older entries belong to turns long over.
                allowedForTurn = allowedForTurn.filter { $0.value.timeIntervalSinceNow > -6 * 3600 }
                allowedForTurn[key] = Date()
            }
        }
        #elseif os(macOS)
        guard request.approval != "never" else { return }
        let outcome = await MacTaskConfirmation.shared.ask(step, owner: request.appleDataRequest)
        #endif
        try Task.checkCancellation()
        switch outcome {
        case .allowed: return
        case .denied: throw Failure("denied", "The user did not allow this; nothing was changed. Do not try again another way.")
        case .timedOut: throw Failure("confirm_timeout", "The user did not answer within two minutes; nothing was changed. Tell them, and that saying 继续 asks again.")
        #if os(iOS)
        case .unavailable: throw Failure("confirm_unavailable", "Pallas Agent is not in front and notifications are off, so the user could not be asked; nothing was changed.")
        #endif
        }
    }

    // MARK: Connectors

    #if os(iOS)
    private func caller(_ request: Request) -> ConnectorCaller { request.fromComputer ? .computer : .phone }

    /// Each connector has its own switch for this phone's AI and for computers (设置 › 连接器).
    private func checkConnector(_ request: Request) throws {
        if request.tool == "email" { return }  // email() picks the account and checks it.
        guard let id = Connectors.connector(tool: request.tool, action: request.args.action, account: nil) else {
            if request.fromComputer { throw Failure("not_allowed", "This tool is not offered to computers.") }
            return
        }
        guard Connectors.allowed(id, caller(request)) else { throw connectorOff(id, request) }
    }

    private func connectorOff(_ id: ConnectorID, _ request: Request) -> Failure {
        Failure("connector_off", request.fromComputer
            ? "The iPhone owner has not shared \(id.rawValue) with computers. They can turn it on in Pallas Agent → Settings → Connectors."
            : "The user turned off \(id.rawValue) for the AI in Settings → Connectors. Tell them; do not use another way.")
    }

    private func email(_ request: Request) async throws -> [String: Any] {
        let args = request.args
        let accounts = MailAccounts.shared
        let connected = MailProvider.allCases.filter { accounts.account($0) != nil }
        let usable = connected.filter { Connectors.allowed($0.connector, caller(request)) }
        if args.action == "accounts" {
            return ["accounts": usable.map { ["account": $0.account, "address": accounts.account($0)?.address ?? ""] }]
        }
        let provider: MailProvider
        if let name = args.account {
            guard let named = MailProvider(account: name) else { throw Failure("invalid_args", "account must be gmail or outlook.") }
            guard connected.contains(named) else {
                throw Failure("not_connected", "\(named.account) is not connected. Ask the user to connect it in Pallas Agent → Settings → Connectors.")
            }
            guard usable.contains(named) else { throw connectorOff(named.connector, request) }
            provider = named
        } else if usable.count == 1 {
            provider = usable[0]
        } else if usable.isEmpty {
            if let first = connected.first { throw connectorOff(first.connector, request) }
            throw Failure("not_connected", "No mail account is connected. Ask the user to connect Gmail or Outlook in Pallas Agent → Settings → Connectors.")
        } else {
            throw Failure("invalid_args", "Several accounts are connected; pass account (gmail or outlook).")
        }
        switch args.action {
        case "search":
            return try await accounts.search(provider, query: args.query, limit: args.limit ?? 10)
        case "read":
            guard let id = args.id, !id.isEmpty else { throw Failure("invalid_args", "Pass id from a search result.") }
            return try await accounts.read(provider, id: id)
        case "send":
            guard let body = args.body, !body.isEmpty else { throw Failure("invalid_args", "Pass body.") }
            let to = args.to ?? [], cc = args.cc ?? []
            guard !to.isEmpty || args.replyTo != nil else { throw Failure("invalid_args", "Pass to, or reply_to with a message id.") }
            let address = accounts.account(provider)?.address ?? provider.account
            let subject = args.subject ?? ""
            let step = to.isEmpty
                ? String(localized: "用 \(address) 回复邮件：\(subject)")
                : String(localized: "用 \(address) 发邮件给 \(to.joined(separator: String(localized: "、")))：\(subject)")
            try await confirm(step, for: request, always: true)
            return try await accounts.send(provider, to: to, cc: cc, subject: args.subject, body: body, replyTo: args.replyTo)
        default:
            throw Failure("invalid_args", "action must be accounts, search, read or send.")
        }
    }
    #endif

    // MARK: Times

    nonisolated static func local(_ date: Date, allDay: Bool = false) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = allDay ? "yyyy-MM-dd EEE" : "yyyy-MM-dd'T'HH:mm EEE"
        return format.string(from: date)
    }

    /// Local time as the prompt asks for it; an offset or `Z` is honoured when a model adds one anyway.
    nonisolated static func parse(_ text: String?) -> (date: Date, dayOnly: Bool)? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return (date, false) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return (date, false) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            format.dateFormat = pattern
            if let date = format.date(from: text) { return (date, false) }
        }
        format.dateFormat = "yyyy-MM-dd"
        if let date = format.date(from: String(text.prefix(10))), text.count == 10 { return (date, true) }
        return nil
    }

    private func time(_ text: String?, _ name: String) throws -> (date: Date, dayOnly: Bool)? {
        guard let text, !text.isEmpty else { return nil }
        guard let parsed = Self.parse(text) else { throw Failure("invalid_args", "\(name) must be local time YYYY-MM-DDTHH:MM or a day YYYY-MM-DD.") }
        return parsed
    }

    /// How the question to the person shows a time, in the interface language.
    private static func shown(_ date: Date, dayOnly: Bool) -> String {
        dayOnly ? date.formatted(.dateTime.month().day().weekday())
            : date.formatted(.dateTime.month().day().weekday().hour().minute())
    }

    // MARK: apple_calendar

    private func calendar(_ request: Request) async throws -> [String: Any] {
        switch request.args.action {
        case "add_event": return try await addEvent(request)
        case "find_events": return try await findEvents(request.args)
        case "add_reminder": return try await addReminder(request)
        case "list_reminders": return try await listReminders(request.args)
        case "complete_reminder": return try await completeReminder(request)
        default: throw Failure("invalid_args", "Unknown action. Use one of: add_event, find_events, add_reminder, list_reminders, complete_reminder.")
        }
    }

    private func authorizationDenied(_ service: String) -> Failure {
        #if os(macOS)
        let path = "System Settings › Privacy & Security › \(service)"
        #else
        let path = "Settings › Apps › Pallas Agent › \(service)"
        #endif
        return Failure("authorization_denied", "\(service) access is off. The user can allow Pallas Agent in \(path).")
    }

    /// Adding is fine with write access, reading needs full access. The first question asks for full access,
    /// since the same tool both adds and reads, so the person is not asked a second time later.
    private func eventAccess(full: Bool) async throws {
        let status = type(of: events).authorizationStatus(for: .event)
        if status == .fullAccess || (!full && status == .writeOnly) { return }
        if status == .denied || status == .restricted {
            throw authorizationDenied("Calendars")
        }
        let granted = try await events.requestFullAccessToEvents()
        guard granted else {
            throw Failure("authorization_denied", full ? "The user did not allow reading the calendar." : "The user did not allow adding to the calendar.")
        }
    }

    private func reminderAccess() async throws {
        switch type(of: events).authorizationStatus(for: .reminder) {
        case .fullAccess: return
        case .denied, .restricted, .writeOnly:
            throw authorizationDenied("Reminders")
        default:
            guard try await events.requestFullAccessToReminders() else {
                throw Failure("authorization_denied", "The user did not allow Reminders access.")
            }
        }
    }

    private func addEvent(_ request: Request) async throws -> [String: Any] {
        let args = request.args
        guard let title = args.title, !title.isEmpty else { throw Failure("invalid_args", "Pass title.") }
        guard let start = try time(args.start, "start") else { throw Failure("invalid_args", "Pass start, local time YYYY-MM-DDTHH:MM.") }
        let allDay = args.allDay ?? start.dayOnly
        var end = try time(args.end, "end")?.date ?? start.date.addingTimeInterval(allDay ? 0 : 3600)
        if end < start.date { throw Failure("invalid_args", "end is before start.") }
        if allDay, end == start.date { end = start.date }
        let when = Self.shown(start.date, dayOnly: allDay)
        let step = if let location = args.location, !location.isEmpty { String(localized: "加到日历：\(title)，\(when)，\(location)") }
            else { String(localized: "加到日历：\(title)，\(when)") }
        // iOS's own question first: a refusal there must not use up the person's 允许.
        try await eventAccess(full: false)
        try Task.checkCancellation()
        try await confirm(step, for: request)
        try Task.checkCancellation()
        let event = EKEvent(eventStore: events)
        event.title = title
        event.startDate = start.date
        event.endDate = end
        event.isAllDay = allDay
        event.location = args.location
        event.notes = args.notes
        if let minutes = args.alarmMinutes, minutes > 0 { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-60 * minutes))) }
        guard let calendar = events.defaultCalendarForNewEvents else {
            throw Failure("not_available", "There is no default calendar to add events to on this device.")
        }
        event.calendar = calendar
        do { try events.save(event, span: .thisEvent, commit: true) }
        catch { throw Failure("save_failed", error.localizedDescription) }
        Log.engine.notice("apple_calendar added an event")
        return ["added": eventRow(event)]
    }

    private func eventRow(_ event: EKEvent) -> [String: Any] {
        var row: [String: Any] = ["title": event.title ?? "", "all_day": event.isAllDay,
                                  "start": Self.local(event.startDate, allDay: event.isAllDay),
                                  "end": Self.local(event.endDate, allDay: event.isAllDay)]
        if let id = event.eventIdentifier { row["id"] = id }
        if let location = event.location, !location.isEmpty { row["location"] = location }
        if let notes = event.notes, !notes.isEmpty { row["notes"] = String(notes.prefix(500)) }
        if let calendar = event.calendar?.title { row["calendar"] = calendar }
        return row
    }

    private func findEvents(_ args: Args) async throws -> [String: Any] {
        let today = Calendar.current.startOfDay(for: Date())
        let from = try time(args.from, "from")?.date ?? today
        var to = try args.to?.first.flatMap { try time($0, "to") }
        if let day = to, day.dayOnly { to = (Calendar.current.date(byAdding: .day, value: 1, to: day.date)!, true) }
        let until = to?.date ?? Calendar.current.date(byAdding: .day, value: 7, to: today)!
        guard until > from else { throw Failure("invalid_args", "to must be after from.") }
        guard until.timeIntervalSince(from) <= 62 * 86400 else { throw Failure("invalid_args", "The range can be at most 62 days.") }
        try await eventAccess(full: true)
        try Task.checkCancellation()
        var found = events.events(matching: events.predicateForEvents(withStart: from, end: until, calendars: nil))
        if let query = args.query?.lowercased(), !query.isEmpty {
            found = found.filter { ($0.title ?? "").lowercased().contains(query) || ($0.location ?? "").lowercased().contains(query) }
        }
        found.sort { $0.startDate < $1.startDate }
        return ["from": Self.local(from), "to": Self.local(until), "count": found.count, "events": found.prefix(100).map(eventRow)]
    }

    private func reminderList(named name: String?) throws -> EKCalendar? {
        guard let name, !name.isEmpty else { return nil }
        let lists = events.calendars(for: .reminder)
        guard let list = lists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame })
                ?? lists.first(where: { $0.title.localizedCaseInsensitiveContains(name) }) else {
            throw Failure("not_found", "No Reminders list is called \(name). Lists: " + lists.map(\.title).joined(separator: ", "))
        }
        return list
    }

    private func addReminder(_ request: Request) async throws -> [String: Any] {
        let args = request.args
        guard let title = args.title, !title.isEmpty else { throw Failure("invalid_args", "Pass title.") }
        let due = try time(args.due, "due")
        let step = if let due { String(localized: "加到提醒事项：\(title)，\(Self.shown(due.date, dayOnly: due.dayOnly))") }
            else { String(localized: "加到提醒事项：\(title)") }
        try await reminderAccess()
        try Task.checkCancellation()
        try await confirm(step, for: request)
        try Task.checkCancellation()
        let reminder = EKReminder(eventStore: events)
        reminder.title = title
        reminder.notes = args.notes
        guard let list = try reminderList(named: args.list) ?? events.defaultCalendarForNewReminders() else {
            throw Failure("not_available", "There is no default Reminders list on this device.")
        }
        reminder.calendar = list
        if let due {
            let units: Set<Calendar.Component> = due.dayOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due.date)
            // A reminder with a time alerts then; a day-only one shows on that day without an alert.
            if !due.dayOnly { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        switch args.priority {
        case "high": reminder.priority = 1
        case "medium": reminder.priority = 5
        case "low": reminder.priority = 9
        default: break
        }
        do { try events.save(reminder, commit: true) }
        catch { throw Failure("save_failed", error.localizedDescription) }
        Log.engine.notice("apple_calendar added a reminder")
        return ["added": reminderRow(reminder)]
    }

    nonisolated private static func reminderRow(_ reminder: EKReminder) -> [String: Any] {
        var row: [String: Any] = ["id": reminder.calendarItemIdentifier, "title": reminder.title ?? "",
                                  "completed": reminder.isCompleted, "list": reminder.calendar?.title ?? ""]
        if let parts = reminder.dueDateComponents, let date = Calendar.current.date(from: parts) {
            row["due"] = local(date, allDay: parts.hour == nil)
        }
        if let notes = reminder.notes, !notes.isEmpty { row["notes"] = String(notes.prefix(500)) }
        if reminder.priority > 0 { row["priority"] = reminder.priority <= 4 ? "high" : reminder.priority == 5 ? "medium" : "low" }
        return row
    }

    private func reminderRow(_ reminder: EKReminder) -> [String: Any] { Self.reminderRow(reminder) }

    private func listReminders(_ args: Args) async throws -> [String: Any] {
        try await reminderAccess()
        try Task.checkCancellation()
        let lists = try reminderList(named: args.list).map { [$0] }
        let predicate = args.includeCompleted == true ? events.predicateForReminders(in: lists)
            : events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let query = args.query?.lowercased() ?? ""
        let rows: [[String: Any]] = await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { found in
                let matching = (found ?? []).filter { query.isEmpty || ($0.title ?? "").lowercased().contains(query) }
                continuation.resume(returning: matching.prefix(100).map(Self.reminderRow))
            }
        }
        return ["count": rows.count, "reminders": rows]
    }

    private func completeReminder(_ request: Request) async throws -> [String: Any] {
        let args = request.args
        guard let id = args.id, !id.isEmpty else { throw Failure("invalid_args", "Pass id from list_reminders.") }
        try await reminderAccess()
        try Task.checkCancellation()
        guard let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else {
            throw Failure("not_found", "No reminder has this id; call list_reminders again.")
        }
        try await confirm(String(localized: "把提醒「\(reminder.title ?? "")」标为完成"), for: request)
        try Task.checkCancellation()
        reminder.isCompleted = true
        do { try events.save(reminder, commit: true) }
        catch { throw Failure("save_failed", error.localizedDescription) }
        return ["completed": reminderRow(reminder)]
    }

    // MARK: apple_contacts

    private static var contactKeys: [CNKeyDescriptor] {
        [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
         CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
    }

    /// iOS 18 lets the person share only some contacts; iOS 17 asks for all of them.
    private func contactAccess() async throws -> Bool {
        let status = type(of: contacts).authorizationStatus(for: .contacts)
        #if os(iOS)
        if #available(iOS 18.0, *), status == .limited { return true }
        #endif
        switch status {
        case .authorized: return false
        case .denied, .restricted:
            throw authorizationDenied("Contacts")
        default:
            guard (try? await contacts.requestAccess(for: .contacts)) == true else {
                throw Failure("authorization_denied", "The user did not allow Contacts access.")
            }
            #if os(iOS)
            if #available(iOS 18.0, *) { return type(of: contacts).authorizationStatus(for: .contacts) == .limited }
            #endif
            return false
        }
    }

    private func search(_ query: String) throws -> [CNContact] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = query.filter(\.isNumber)
        if query.contains("@") {
            return try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: query), keysToFetch: Self.contactKeys)
        }
        if digits.count >= 3, digits.count * 2 >= query.filter({ !$0.isWhitespace }).count {
            // Contacts matches a whole number only, and a saved number may or may not carry the +1 country code.
            for number in Self.phoneVariants(query) {
                let found = try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number)),
                                                         keysToFetch: Self.contactKeys)
                if !found.isEmpty { return found }
            }
            return []
        }
        return try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: Self.contactKeys)
    }

    /// The number as given, then with the North American +1 added or dropped. A bare 11-digit number that
    /// starts with 1 is left alone: that is how Chinese mobile numbers look.
    static func phoneVariants(_ query: String) -> [String] {
        let digits = String(query.filter(\.isNumber))
        let spelled = query.filter { !$0.isWhitespace }
        let countryCode = spelled.hasPrefix("+1") || (spelled.hasPrefix("1") && spelled.dropFirst().first.map { !$0.isNumber } == true)
        var out = [query]
        if digits.count == 11, countryCode { out.append(String(digits.dropFirst())) }
        else if digits.count == 10, !spelled.hasPrefix("+") { out += ["+1" + digits, "1" + digits] }
        return out
    }

    private func findContacts(_ args: Args) async throws -> [String: Any] {
        guard let query = args.query, !query.isEmpty else { throw Failure("invalid_args", "Pass query: a name, phone number or email.") }
        let limit = min(max(args.limit ?? 5, 1), 20)
        let limited = try await contactAccess()
        try Task.checkCancellation()
        #if os(iOS)
        var found = try search(query)
        // Shared only some people and this one is not among them: let the person add them, once.
        if limited, found.isEmpty, #available(iOS 18.0, *) {
            await ContactSharing.pick(query: query)
            try Task.checkCancellation()
            found = try search(query)
        }
        #else
        let found = try search(query)
        #endif
        let label = { (raw: String?) in raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
        let rows: [[String: Any]] = found.prefix(limit).map { contact in
            var row: [String: Any] = ["name": CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName]
            if !contact.organizationName.isEmpty { row["organization"] = contact.organizationName }
            row["phones"] = contact.phoneNumbers.map { ["label": label($0.label), "number": $0.value.stringValue] }
            row["emails"] = contact.emailAddresses.map { ["label": label($0.label), "address": $0.value as String] }
            return row
        }
        var data: [String: Any] = ["count": found.count, "contacts": rows]
        if limited { data["limited"] = true }
        return data
    }

    // MARK: compose_message

    private func compose(_ args: Args, owner: UUID) async throws -> [String: Any] {
        let to = (args.to ?? []).filter { !$0.isEmpty }
        guard !to.isEmpty else { throw Failure("invalid_args", "Pass to: at least one recipient.") }
        #if os(macOS)
        try Task.checkCancellation()
        return try await MacMessageDraft.open(args, recipients: to)
        #elseif os(iOS)
        let controller: UIViewController
        let composer = Composer(owner: owner)
        switch args.kind {
        case "sms":
            guard MFMessageComposeViewController.canSendText() else { throw Failure("not_available", "This iPhone cannot send text messages.") }
            let form = MFMessageComposeViewController()
            form.recipients = to
            form.body = args.body
            form.messageComposeDelegate = composer
            controller = form
        case "email":
            guard MFMailComposeViewController.canSendMail() else {
                throw Failure("not_available", "No email account is set up in the Mail app on this iPhone.")
            }
            let form = MFMailComposeViewController()
            form.setToRecipients(to)
            if let cc = args.cc, !cc.isEmpty { form.setCcRecipients(cc) }
            form.setSubject(args.subject ?? "")
            form.setMessageBody(args.body ?? "", isHTML: false)
            form.mailComposeDelegate = composer
            controller = form
        default: throw Failure("invalid_args", "kind must be sms or email.")
        }
        // A form still open from an earlier request closes first; presenting over one that is closing fails.
        if let earlier = self.composer { self.composer = nil; await earlier.close(.cancelled) }
        guard let presenter = await Self.settledPresenter() else {
            throw Failure("not_available", "Pallas Agent is not in front, so the form cannot open. Ask the user to open Pallas Agent and try again.")
        }
        self.composer = composer
        controller.presentationController?.delegate = composer
        let result = await composer.run(controller, over: presenter)
        if self.composer === composer { self.composer = nil }
        switch result {
        case .sent: return ["result": "sent"]
        case .saved: return ["result": "saved", "note": "The user saved the email as a draft; it was not sent."]
        case .cancelled: return ["result": "cancelled", "note": "The user closed the form without sending."]
        case .failed(let why): throw Failure("send_failed", why)
        }
        #endif
    }

    #if os(iOS)
    /// The front-most controller of the active window, to present over.
    static func presenter() -> UIViewController? {
        guard UIApplication.shared.applicationState == .active else { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.keyWindow?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// `presenter()` once nothing over it is still closing (up to two seconds), since presenting over a closing sheet fails.
    static func settledPresenter() async -> UIViewController? {
        for _ in 0..<20 {
            guard let top = presenter() else { return nil }
            if top.presentedViewController == nil { return top }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
    #endif
}

#if os(iOS)
/// Watches one message or mail form until the person sends or closes it. The form is a remote view run by
/// another process and can vanish without calling its delegate, so a watchdog ends the wait when it is no
/// longer on screen. The answer comes only once the form has finished closing, so a next form can open.
@MainActor
private final class Composer: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate,
    UIAdaptivePresentationControllerDelegate {
    enum Result { case sent, saved, cancelled, failed(String) }

    let owner: UUID
    private weak var form: UIViewController?
    private var finish: ((Result) -> Void)?
    private var watchdog: Task<Void, Never>?

    init(owner: UUID) { self.owner = owner }

    func run(_ controller: UIViewController, over presenter: UIViewController) async -> Result {
        form = controller
        return await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
            presenter.present(controller, animated: true) { [weak self] in
                guard let self else { return }
                guard controller.presentingViewController != nil else {
                    self.end(.failed("The form could not open over Pallas Agent."))
                    return
                }
                self.watch(controller)
            }
        }
    }

    /// Closes the form and returns once it is gone.
    func close(_ result: Result) async {
        guard finish != nil else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finish = self.finish
            self.finish = { finish?($0); done.resume() }
            dismiss(result)
        }
    }

    func dismiss(_ result: Result) {
        guard finish != nil else { return }
        // The answer is known now; the watchdog must not turn the closing form into a cancel.
        watchdog?.cancel()
        guard let form, form.presentingViewController != nil, !form.isBeingDismissed else { end(result); return }
        form.dismiss(animated: true) { [weak self] in self?.end(result) }
    }

    private func end(_ result: Result) {
        watchdog?.cancel()
        watchdog = nil
        guard let finish else { return }
        self.finish = nil
        finish(result)
    }

    private func watch(_ controller: UIViewController) {
        watchdog = Task { [weak self, weak controller] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard let controller, controller.presentingViewController != nil else {
                    self.end(.cancelled)
                    return
                }
            }
        }
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { end(.cancelled) }
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        MainActor.assumeIsolated {
            switch result {
            case .sent: dismiss(.sent)
            case .failed: dismiss(.failed("Messages could not send it."))
            default: dismiss(.cancelled)
            }
        }
    }

    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        MainActor.assumeIsolated {
            switch result {
            case .sent: dismiss(.sent)
            case .saved: dismiss(.saved)
            case .failed: dismiss(.failed(error?.localizedDescription ?? "Mail could not send it."))
            default: dismiss(.cancelled)
            }
        }
    }
}

/// iOS 18's picker for adding people to the contacts the person shares with Pallas Agent.
@available(iOS 18.0, *)
@MainActor
enum ContactSharing {
    /// Shows the picker over the app and returns once it closes.
    static func pick(query: String? = nil) async {
        // An iOS app on a Mac has no contactAccessPicker; ContactsUI is weak-linked so launch survives.
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        guard let presenter = AppleData.presenter() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let host = UIHostingController(rootView: PickerHost(done: { continuation.resume() }))
            host.view.backgroundColor = .clear
            host.modalPresentationStyle = .overFullScreen
            presenter.present(host, animated: false)
        }
    }

    private struct PickerHost: View {
        let done: () -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var shown = false
        @State private var finished = false

        var body: some View {
            Color.clear
                .contactAccessPicker(isPresented: $shown) { _ in close() }
                .onAppear { shown = true }
                .onChange(of: shown) { _, now in if !now { close() } }
        }

        private func close() {
            guard !finished else { return }
            finished = true
            dismiss()
            done()
        }
    }
}
#endif
