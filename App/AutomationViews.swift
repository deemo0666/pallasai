import SwiftUI

// MARK: - Schedule model

/// One `schedule/catalog` entry: legacy session-owned records and 0.2.2 target-based tasks.
struct ScheduleItem: Identifiable {
    let raw: Object
    let id: String
    let kind: String
    let title: String
    let prompt: String
    let active: Bool
    let sessionId: String?
    let scheduledAt: Date?
    let lastDeliveredAt: Date?
    var usesTarget: Bool { raw["target"] is Object }
    var time: String? { raw["time"] as? String }
    var timeZone: String? { raw["timeZone"] as? String }
    var weekdays: [Int] { (raw["weekdays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
    var expression: String? { raw["expression"] as? String }
    var everySeconds: Int? { (raw["everySeconds"] as? NSNumber)?.intValue }
    var updatedAt: Any { raw["updatedAt"] ?? NSNull() }
    var recurring: Bool { ["every", "daily", "weekly", "cron", "rrule"].contains(kind) }
    var lastScheduledDelivery: Date? {
        ((raw["lastDelivery"] as? Object)?["scheduledAt"] as? String).flatMap(ScheduleText.parseDate)
    }

    init?(_ value: Any) {
        guard let map = value as? Object, let id = map["id"] as? String, !id.isEmpty else { return nil }
        let target = map["target"] as? Object
        let targetKind = target?["kind"] as? String
        if target != nil, !["session", "new_once", "new"].contains(targetKind ?? "") { return nil }
        let session = target == nil ? map["sessionId"] as? String : targetKind == "session" || targetKind == "new_once" ? target?["sessionId"] as? String : nil
        if target == nil, session == nil { return nil }
        raw = map
        self.id = id
        kind = map["kind"] as? String ?? "at"
        prompt = map["prompt"] as? String ?? ""
        let stored = (map["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = stored.isEmpty ? (prompt.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") : stored
        active = target == nil ? map["status"] as? String != "inactive" : map["status"] as? String == "active"
        sessionId = session
        scheduledAt = (map["scheduledAt"] as? String).flatMap(ScheduleText.parseDate)
        lastDeliveredAt = ((map["lastDelivery"] as? Object)?["deliveredAt"] as? String).flatMap(ScheduleText.parseDate)
    }

    /// The schedule store is available while the local engine is stopped.
    static func stored(in home: URL) throws -> [ScheduleItem] {
        let data: Data
        do { data = try Data(contentsOf: home.appending(path: "storages/schedule.json")) }
        catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { return [] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? Object,
              let tables = root["tables"] as? Object else { throw CocoaError(.coderReadCorrupt) }
        guard let stored = tables["tasks"] else { return [] }
        guard let tasks = stored as? Object else { throw CocoaError(.coderReadCorrupt) }
        return tasks.values.compactMap { value in
            guard let row = value as? Object, var flat = row["record"] as? Object else { return nil }
            for key in ["status", "target", "updatedAt", "lastDelivery", "deliveryHistory"] {
                if let value = row[key] { flat[key] = value }
            }
            if flat["target"] as? Object == nil {
                let session = (row["sessionId"] as? String) ?? (flat["sessionId"] as? String)
                flat["target"] = session.map { ["kind": "session", "sessionId": $0] } ?? ["kind": "new_once"]
            }
            if flat["status"] == nil { flat["status"] = "active" }
            return ScheduleItem(flat)
        }
    }

    /// Include the saved occurrence and two more for the repeat rules the client can calculate.
    func reminderDates(now: Date) -> [Date] {
        guard active, let next = scheduledAt else { return [] }
        guard recurring, kind != "rrule" else { return [next] }
        let draft = ScheduleDraft.from(self, deviceZone: TimeZone.current.identifier, now: now)
        let anchor = kind == "every" ? next.addingTimeInterval(Double(everySeconds ?? 0)) : nil
        return [next] + draft.nextRuns(now: next, count: 2, anchor: anchor)
    }
}

/// The run-time builder's state: a friendly repeat choice that maps onto the Host's rule kinds.
struct ScheduleDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case daily = "每天", weekdays = "工作日", weekly = "每周", monthly = "每月", interval = "间隔", once = "仅一次", cron = "高级"
        var id: Self { self }
    }
    enum Unit: Int, CaseIterable, Identifiable {
        case second = 1, minute = 60, hour = 3600
        var id: Self { self }
        var label: String { switch self { case .second: String(localized: "秒"); case .minute: String(localized: "分钟"); case .hour: String(localized: "小时") } }
    }

    var kind = Kind.daily
    var hour = 9
    var minute = 0
    var second = 0
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    var monthDays: Set<Int> = [1]
    var interval = 1
    var unit = Unit.hour
    var year = 2000, month = 1, day = 1
    var expression = "0 9 * * 1-5"
    var timeZone: String

    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }

    /// A new task: every day at 09:00; the one-shot date starts tomorrow, the weekly day on today's.
    static func initial(zone: String, now: Date) -> Self {
        var draft = Self(timeZone: zone)
        let parts = draft.calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        draft.weekdays = [ScheduleText.iso(parts.weekday ?? 2)]
        draft.monthDays = [parts.day ?? 1]
        let tomorrow = draft.calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let next = draft.calendar.dateComponents([.year, .month, .day], from: tomorrow)
        draft.year = next.year ?? 2000; draft.month = next.month ?? 1; draft.day = next.day ?? 1
        return draft
    }

    /// The stored rule of a task, read into the builder.
    static func from(_ task: ScheduleItem, deviceZone: String, now: Date) -> Self {
        var draft = initial(zone: task.timeZone ?? deviceZone, now: now)
        let clock = (task.time ?? "09:00").split(separator: ".").first?.split(separator: ":").map { Int($0) ?? 0 } ?? []
        let (h, m, s) = (min(max(clock.first ?? 9, 0), 23), min(max(clock.count > 1 ? clock[1] : 0, 0), 59), min(max(clock.count > 2 ? clock[2] : 0, 0), 59))
        func days(_ set: Set<Int>) -> Kind { set == [1, 2, 3, 4, 5] ? .weekdays : set.count == 7 ? .daily : .weekly }
        switch task.kind {
        case "daily": draft.kind = .daily; draft.hour = h; draft.minute = m; draft.second = s
        case "weekly":
            let set = Set(task.weekdays.filter { (1...7).contains($0) })
            draft.kind = days(set); draft.hour = h; draft.minute = m; draft.second = s
            if draft.kind == .weekly { draft.weekdays = set }
        case "cron":
            draft.kind = .cron; draft.expression = task.expression ?? ""
            if let parsed = try? Cron.parse(draft.expression).get(), let shape = parsed.shape {
                switch shape {
                case .daily(let hh, let mm): draft.kind = .daily; draft.hour = hh; draft.minute = mm
                case .weekly(let list, let hh, let mm):
                    draft.kind = days(Set(list)); draft.weekdays = Set(list); draft.hour = hh; draft.minute = mm
                case .monthly(let list, let hh, let mm): draft.kind = .monthly; draft.monthDays = Set(list); draft.hour = hh; draft.minute = mm
                default: break
                }
            }
        case "every":
            let seconds = task.everySeconds ?? 3600
            draft.unit = seconds % 3600 == 0 ? .hour : seconds % 60 == 0 ? .minute : .second
            draft.kind = .interval; draft.interval = seconds / draft.unit.rawValue
        default:
            draft.kind = .once
            if let at = task.scheduledAt {
                let parts = draft.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
                draft.year = parts.year ?? draft.year; draft.month = parts.month ?? draft.month; draft.day = parts.day ?? draft.day
                draft.hour = parts.hour ?? 9; draft.minute = parts.minute ?? 0; draft.second = parts.second ?? 0
            }
        }
        return draft
    }

    /// Switches the repeat choice; entering 高级 writes the current rule as an expression.
    func with(_ next: Kind) -> Self {
        guard next != kind else { return self }
        var copy = self
        if next == .cron {
            let shape: Cron.Shape = switch kind {
            case .weekdays: .weekly([1, 2, 3, 4, 5], hour, minute)
            case .weekly where !weekdays.isEmpty: .weekly(weekdays.sorted(), hour, minute)
            case .monthly where !monthDays.isEmpty: .monthly(monthDays.sorted(), hour, minute)
            case .interval where unit == .minute && interval >= 1 && interval < 60 && 60 % interval == 0: .minutely(interval)
            case .interval where unit == .hour && interval >= 1 && interval < 24 && 24 % interval == 0: .hourly(interval, 0)
            default: .daily(hour, minute)
            }
            copy.expression = shape.expression
        } else if kind == .cron, let parsed = try? Cron.parse(expression.trimmingCharacters(in: .whitespaces)).get(), let shape = parsed.shape {
            switch shape {
            case .daily(let h, let m): copy.hour = h; copy.minute = m; copy.second = 0
            case .weekly(let days, let h, let m): copy.hour = h; copy.minute = m; copy.second = 0; copy.weekdays = Set(days)
            case .monthly(let days, let h, let m): copy.hour = h; copy.minute = m; copy.second = 0; copy.monthDays = Set(days)
            default: break
            }
        }
        copy.kind = next
        return copy
    }

    var clock: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
    var clockLabel: String { second == 0 ? String(format: "%02d:%02d", hour, minute) : clock }
    var intervalSeconds: Int { interval * unit.rawValue }
    private var normalized: String { expression.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    func instant(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date? {
        let parts = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        guard let date = calendar.date(from: parts) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return back.hour == h && back.minute == mi && back.day == d ? date : nil
    }

    /// Why this can't be saved, or nil.
    func validate(now: Date) -> String? {
        if kind != .interval, TimeZone(identifier: timeZone) == nil { return String(localized: "时区不可用") }
        switch kind {
        case .weekly where weekdays.isEmpty, .monthly where monthDays.isEmpty: return String(localized: "至少选一天")
        case .interval:
            if interval < 1 { return String(localized: "间隔至少为 1") }
            return intervalSeconds < 60 ? String(localized: "至少 1 分钟") : nil
        case .once:
            guard let at = instant(year, month, day, hour, minute, second) else { return String(localized: "这个时间在该时区不存在") }
            return at > now ? nil : String(localized: "选一个以后的时间")
        case .cron:
            switch Cron.parse(expression.trimmingCharacters(in: .whitespaces)) {
            case .failure(let error): return error.message
            case .success: return nextRuns(now: now, count: 1).isEmpty ? String(localized: "按这个表达式，任务永远不会运行") : nil
            }
        default: return nil
        }
    }

    /// The rule to save (`ScheduleTiming`).
    var timing: Object? {
        switch kind {
        case .daily: return ["kind": "daily", "daily": ["time": clock, "time_zone": timeZone]]
        case .weekdays: return ["kind": "weekly", "weekly": ["time": clock, "time_zone": timeZone, "weekdays": [1, 2, 3, 4, 5]] as Object]
        case .weekly:
            return weekdays.isEmpty ? nil : ["kind": "weekly", "weekly": ["time": clock, "time_zone": timeZone, "weekdays": weekdays.sorted()] as Object]
        case .monthly:
            return monthDays.isEmpty ? nil : ["kind": "cron", "cron": ["expression": Cron.Shape.monthly(monthDays.sorted(), hour, minute).expression, "time_zone": timeZone]]
        case .interval: return intervalSeconds < 60 ? nil : ["kind": "every", "every_seconds": intervalSeconds]
        case .once:
            return ["kind": "at", "at": ["date": String(format: "%04d-%02d-%02d", year, month, day), "time": clock, "time_zone": timeZone]]
        case .cron:
            return (try? Cron.parse(normalized).get()) == nil ? nil : ["kind": "cron", "cron": ["expression": normalized, "time_zone": timeZone]]
        }
    }

    /// `每天 09:00`, `每个工作日 09:00`, `每周一、三 18:30`, `每月 1、15 日 09:00`, `每 30 分钟`, `仅一次`.
    var ruleText: String {
        let time = clockLabel
        switch kind {
        case .daily: return String(localized: "每天 ") + time
        case .weekdays: return String(localized: "每个工作日 ") + time
        case .weekly:
            let days = weekdays.sorted()
            if days.isEmpty { return String(localized: "每周") }
            if days.count == 7 { return String(localized: "每天 ") + time }
            if Set(days) == [1, 2, 3, 4, 5] { return String(localized: "每个工作日 ") + time }
            if Set(days) == [6, 7] { return String(localized: "每个周末 ") + time }
            return String(localized: "每周") + days.map { ScheduleText.weekdayNames[$0 - 1] }.joined(separator: String(localized: "、")) + " " + time
        case .monthly:
            let days = monthDays.sorted()
            return days.isEmpty ? String(localized: "每月") : String(localized: "每月 ") + days.map(String.init).joined(separator: String(localized: "、")) + String(localized: " 日 ") + time
        case .interval:
            switch (unit, interval) {
            case (.hour, 1): return String(localized: "每小时")
            case (.minute, 1): return String(localized: "每分钟")
            case (.second, let n): return String(localized: "每 \(n) 秒")
            case (.minute, let n): return String(localized: "每 \(n) 分钟")
            case (.hour, let n): return String(localized: "每 \(n) 小时")
            }
        case .once: return String(localized: "仅一次")
        case .cron:
            guard let parsed = try? Cron.parse(expression.trimmingCharacters(in: .whitespaces)).get() else { return String(localized: "高级") }
            return parsed.preview
        }
    }

    /// [ruleText], plus the date of a one-shot: `仅一次 · 10月25日 09:00`.
    func describe(now: Date) -> String {
        guard kind == .once else { return ruleText }
        let thisYear = calendar.component(.year, from: now)
        let date = year == thisYear ? String(localized: "\(month)月\(day)日") : String(localized: "\(year)年\(month)月\(day)日")
        return ruleText + " · " + date + " " + clockLabel
    }

    /// The next runs after [now]; [anchor] is the committed target of an unchanged fixed-rate rule.
    func nextRuns(now: Date, count: Int = 3, anchor: Date? = nil) -> [Date] {
        switch kind {
        case .interval:
            let step = TimeInterval(intervalSeconds)
            guard step >= 60 else { return [] }
            var next = anchor ?? now.addingTimeInterval(step)
            while next <= now { next = next.addingTimeInterval(step) }
            return (0..<count).map { next.addingTimeInterval(step * Double($0)) }
        case .once:
            guard let at = instant(year, month, day, hour, minute, second), at > now else { return [] }
            return [at]
        default: break
        }
        let cron = kind == .cron ? try? Cron.parse(expression.trimmingCharacters(in: .whitespaces)).get() : nil
        if kind == .cron, cron == nil { return [] }
        let times: [(Int, Int, Int)] = cron.map { c in c.hours.values.flatMap { h in c.minutes.values.map { (h, $0, 0) } } } ?? [(hour, minute, second)]
        let horizon = kind == .cron ? 366 * 8 : kind == .monthly ? 366 * 2 : 15
        var runs: [Date] = []
        var day = calendar.startOfDay(for: now)
        for _ in 0..<horizon where runs.count < count {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            let (y, mo, d, wd) = (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, ScheduleText.iso(parts.weekday ?? 1))
            let matches: Bool = switch kind {
            case .daily: true
            case .weekdays: wd <= 5
            case .weekly: weekdays.contains(wd)
            case .monthly: monthDays.contains(d)
            default: cron?.matches(month: mo, day: d, weekday: wd) ?? false
            }
            if matches {
                for (h, mi, s) in times {
                    guard let at = instant(y, mo, d, h, mi, s), at > now else { continue }
                    runs.append(at)
                    if runs.count == count { break }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return runs
    }
}

/// The five-field cron dialect the Host accepts: `*`, `n`, `a-b`, `*/n`, `a-b/n` and lists.
enum Cron {
    struct Failure: Error { let message: String }
    struct Field { let values: [Int]; let starred: Bool; let full: Bool; var unrestricted: Bool { starred && full } }
    enum Shape {
        case minutely(Int), hourly(Int, Int), daily(Int, Int), weekly([Int], Int, Int), monthly([Int], Int, Int)
        var expression: String {
            switch self {
            case .minutely(let step): step == 1 ? "* * * * *" : "*/\(step) * * * *"
            case .hourly(let step, let minute): step == 1 ? "\(minute) * * * *" : "\(minute) */\(step) * * *"
            case .daily(let hour, let minute): "\(minute) \(hour) * * *"
            case .weekly(let days, let hour, let minute): "\(minute) \(hour) * * " + Cron.runField(Set(days.map { $0 % 7 }).sorted())
            case .monthly(let days, let hour, let minute): "\(minute) \(hour) " + Cron.runField(Set(days).sorted()) + " * *"
            }
        }
    }
    struct Parsed {
        let minutes: Field, hours: Field, days: Field, months: Field, weekdays: Field

        /// Vixie day-of-month / day-of-week semantics; [weekday] is ISO (Monday 1 … Sunday 7).
        func matches(month: Int, day: Int, weekday: Int) -> Bool {
            guard months.values.contains(month) else { return false }
            let dom = days.values.contains(day), dow = weekdays.values.contains(weekday % 7)
            return !days.starred && !weekdays.starred ? dom || dow : dom && dow
        }

        var shape: Shape? {
            guard months.full else { return nil }
            let minuteStep = minutes.unrestricted ? 1 : Cron.fullStep(minutes.values, 0, 59)
            let hourStep = hours.unrestricted ? 1 : Cron.fullStep(hours.values, 0, 23)
            let minute = minutes.values.count == 1 ? minutes.values[0] : nil
            let hour = hours.values.count == 1 ? hours.values[0] : nil
            if weekdays.unrestricted {
                if days.unrestricted {
                    if let minuteStep, hours.full { return .minutely(minuteStep) }
                    if let minute, let hourStep { return .hourly(hourStep, minute) }
                    if let minute, let hour { return .daily(hour, minute) }
                    return nil
                }
                guard let minute, let hour else { return nil }
                return .monthly(days.values, hour, minute)
            }
            guard days.unrestricted, let minute, let hour else { return nil }
            return .weekly(weekdays.values.map { $0 == 0 ? 7 : $0 }.sorted(), hour, minute)
        }

        /// One sentence, as the official page words it: `周一至周五 09:00`, `每 15 分钟`.
        var preview: String {
            let day = dayText, time = timeText
            return day.everyDay && time.interval ? time.text : day.text + " " + time.text
        }

        private var dayText: (everyDay: Bool, text: String) {
            let monthNames = [String(localized: "一月"), String(localized: "二月"), String(localized: "三月"), String(localized: "四月"), String(localized: "五月"), String(localized: "六月"), String(localized: "七月"), String(localized: "八月"), String(localized: "九月"), String(localized: "十月"), String(localized: "十一月"), String(localized: "十二月")]
            let suffix = months.values.count == 12 ? "" : String(localized: "（") + months.values.map { monthNames[$0 - 1] }.joined(separator: String(localized: "、")) + String(localized: "）")
            let iso = weekdays.values.map { $0 == 0 ? 7 : $0 }.sorted()
            let names = Cron.runs(iso).map { run in
                run.count >= 3 ? String(localized: "周") + ScheduleText.weekdayNames[run[0] - 1] + String(localized: "至周") + ScheduleText.weekdayNames[run[run.count - 1] - 1]
                    : run.map { String(localized: "周") + ScheduleText.weekdayNames[$0 - 1] }.joined(separator: String(localized: "、"))
            }.joined(separator: String(localized: "、"))
            let dates = days.values.map(String.init).joined(separator: String(localized: "、"))
            if days.starred || weekdays.starred {
                if days.full && weekdays.full { return (suffix.isEmpty, String(localized: "每天") + suffix) }
                if days.full { return (false, names + suffix) }
                if weekdays.full { return (false, String(localized: "每月 ") + dates + String(localized: " 日") + suffix) }
                return (false, String(localized: "每月 ") + dates + String(localized: " 日且") + names + suffix)
            }
            if days.full || weekdays.full { return (suffix.isEmpty, String(localized: "每天") + suffix) }
            return (false, String(localized: "每月 ") + dates + String(localized: " 日或") + names + suffix)
        }

        private var timeText: (interval: Bool, text: String) {
            let two = { (v: Int) in String(format: "%02d", v) }
            let step = minutes.unrestricted ? nil : Cron.fullStep(minutes.values, 0, 59)
            let list = minutes.values.map(String.init).joined(separator: String(localized: "、"))
            if hours.unrestricted {
                if minutes.unrestricted { return (true, String(localized: "每分钟")) }
                if let step, step >= 2 { return (true, String(localized: "每 \(step) 分钟")) }
                if minutes.values == [0] { return (true, String(localized: "每小时")) }
                return (false, String(localized: "每小时的第 \(list) 分钟"))
            }
            let h = hours.values
            let hourText = h.count >= 2 && h[h.count - 1] - h[0] == h.count - 1 ? two(h[0]) + String(localized: " 至 ") + two(h[h.count - 1]) : h.map(two).joined(separator: String(localized: "、"))
            if minutes.unrestricted { return (false, hourText + String(localized: " 点的每分钟")) }
            if let step, step >= 2 { return (false, hourText + String(localized: " 点内每 \(step) 分钟")) }
            if minutes.values == [0], let hourStep = Cron.fullStep(h, 0, 23), hourStep >= 2 { return (true, String(localized: "每 \(hourStep) 小时")) }
            let times = h.flatMap { hh in minutes.values.map { two(hh) + ":" + two($0) } }
            return (false, times.count <= 6 ? times.joined(separator: String(localized: "、")) : hourText + String(localized: " 点的第 \(list) 分钟"))
        }
    }

    private static let specs: [(name: String, min: Int, max: Int, count: Int, fold: Int?)] = [
        (String(localized: "分钟"), 0, 59, 60, nil), (String(localized: "小时"), 0, 23, 24, nil), (String(localized: "日期"), 1, 31, 31, nil), (String(localized: "月份"), 1, 12, 12, nil), (String(localized: "星期"), 0, 7, 7, 7),
    ]

    static func parse(_ expression: String) -> Result<Parsed, Failure> {
        if expression.trimmingCharacters(in: .whitespaces).isEmpty { return .failure(Failure(message: String(localized: "填写 5 段 Cron 表达式"))) }
        if expression.trimmingCharacters(in: .whitespaces) != expression { return .failure(Failure(message: String(localized: "首尾不能有空格"))) }
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else { return .failure(Failure(message: String(localized: "需要 5 段，现在是 \(parts.count) 段"))) }
        var fields: [Field] = []
        for (i, raw) in parts.enumerated() {
            let spec = specs[i]
            var matched = Set<Int>()
            for element in raw.split(separator: ",", omittingEmptySubsequences: false) {
                guard let values = elementValues(String(element), min: spec.min, max: spec.max) else {
                    return .failure(Failure(message: String(localized: "第 \(i + 1) 段（\(spec.name)）写法不对")))
                }
                for v in values { matched.insert(v == spec.fold ? spec.min : v) }
            }
            let values = matched.sorted()
            fields.append(Field(values: values, starred: raw.hasPrefix("*"), full: values.count == spec.count))
        }
        return .success(Parsed(minutes: fields[0], hours: fields[1], days: fields[2], months: fields[3], weekdays: fields[4]))
    }

    private static func elementValues(_ element: String, min: Int, max: Int) -> [Int]? {
        guard !element.isEmpty else { return nil }
        if element == "*" { return Array(min...max) }
        if element.hasPrefix("*") {
            guard element.hasPrefix("*/"), let step = Int(element.dropFirst(2)), step >= 1 else { return nil }
            return Array(stride(from: min, through: max, by: step))
        }
        let slash = element.split(separator: "/", omittingEmptySubsequences: false)
        guard slash.count <= 2, let range = slash.first else { return nil }
        let bounds = range.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count <= 2, bounds.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let start = Int(bounds[0]), start >= min, start <= max else { return nil }
        if bounds.count == 1 { return slash.count == 1 ? [start] : nil }
        guard let end = Int(bounds[1]), end >= min, end <= max, start <= end else { return nil }
        let step = slash.count == 2 ? Int(slash[1]) : 1
        guard let step, step >= 1 else { return nil }
        return Array(stride(from: start, through: end, by: step))
    }

    static func runs(_ values: [Int]) -> [[Int]] {
        var out: [[Int]] = []
        for v in values {
            if let last = out.last?.last, last + 1 == v { out[out.count - 1].append(v) } else { out.append([v]) }
        }
        return out
    }

    static func runField(_ values: [Int]) -> String {
        runs(values).map { $0.count >= 3 ? "\($0[0])-\($0[$0.count - 1])" : $0.map(String.init).joined(separator: ",") }.joined(separator: ",")
    }

    static func fullStep(_ values: [Int], _ min: Int, _ max: Int) -> Int? {
        guard values.count >= 2, values[0] == min else { return nil }
        let step = values[1] - values[0]
        for i in 1..<values.count where values[i] - values[i - 1] != step { return nil }
        return values[values.count - 1] + step > max ? step : nil
    }
}

/// Dates, zones and rule wording of 自动化任务.
enum ScheduleText {
    static let weekdayNames = [String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五"), String(localized: "六"), String(localized: "日")]

    /// Calendar weekday (Sunday 1) → ISO (Monday 1 … Sunday 7).
    static func iso(_ weekday: Int) -> Int { weekday == 1 ? 7 : weekday - 1 }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The rule of a stored task; 0.2.2's `rrule` reads 「自定义」.
    static func rule(_ task: ScheduleItem) -> String {
        task.kind == "rrule" ? String(localized: "自定义") : ScheduleDraft.from(task, deviceZone: task.timeZone ?? "UTC", now: .now).ruleText
    }

    /// `今天 09:00`, `明天 09:00`, `昨天 21:15`, `10月25日 09:00`, `2025年1月3日 09:00` in the phone's zone.
    static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hm = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return String(localized: "今天 ") + hm
        case 1: return String(localized: "明天 ") + hm
        case -1: return String(localized: "昨天 ") + hm
        default:
            let day = String(localized: "\(parts.month ?? 0)月\(parts.day ?? 0)日")
            return (parts.year == calendar.component(.year, from: now) ? day : String(localized: "\(parts.year ?? 0)年") + day) + " " + hm
        }
    }

    /// A run in [zone]'s wall clock: `今天 09:00`, `明天 09:00`, `10月27日 周一 09:00`.
    static func run(_ date: Date, zone: String, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) + ((parts.second ?? 0) == 0 ? "" : String(format: ":%02d", parts.second ?? 0))
        let diff = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if diff == 0 { return String(localized: "今天 ") + clock }
        if diff == 1 { return String(localized: "明天 ") + clock }
        let week = String(localized: "周") + weekdayNames[iso(parts.weekday ?? 1) - 1]
        let day = String(localized: "\(parts.month ?? 0)月\(parts.day ?? 0)日")
        return (parts.year == calendar.component(.year, from: now) ? day : String(localized: "\(parts.year ?? 0)年") + day) + " " + week + " " + clock
    }

    /// One list line under a task's title.
    static func summary(_ task: ScheduleItem, now: Date = .now) -> String {
        let rule = rule(task)
        if task.active { return task.scheduledAt.map { rule + String(localized: " · 下次 ") + when($0, now: now) } ?? rule }
        return task.lastDeliveredAt.map { String(localized: "已结束 · ") + when($0, now: now) + String(localized: " 运行过") } ?? String(localized: "已结束")
    }

    static let zoneNames: [String: String] = [
        "UTC": String(localized: "协调世界时"), "Asia/Shanghai": String(localized: "上海"), "Asia/Urumqi": String(localized: "乌鲁木齐"), "Asia/Hong_Kong": String(localized: "香港"), "Asia/Macau": String(localized: "澳门"),
        "Asia/Taipei": String(localized: "台北"), "Asia/Tokyo": String(localized: "东京"), "Asia/Seoul": String(localized: "首尔"), "Asia/Singapore": String(localized: "新加坡"), "Asia/Kuala_Lumpur": String(localized: "吉隆坡"),
        "Asia/Bangkok": String(localized: "曼谷"), "Asia/Ho_Chi_Minh": String(localized: "胡志明市"), "Asia/Jakarta": String(localized: "雅加达"), "Asia/Manila": String(localized: "马尼拉"), "Asia/Kolkata": String(localized: "加尔各答"),
        "Asia/Dubai": String(localized: "迪拜"), "Asia/Jerusalem": String(localized: "耶路撒冷"), "Europe/London": String(localized: "伦敦"), "Europe/Dublin": String(localized: "都柏林"), "Europe/Lisbon": String(localized: "里斯本"),
        "Europe/Paris": String(localized: "巴黎"), "Europe/Berlin": String(localized: "柏林"), "Europe/Madrid": String(localized: "马德里"), "Europe/Rome": String(localized: "罗马"), "Europe/Amsterdam": String(localized: "阿姆斯特丹"),
        "Europe/Zurich": String(localized: "苏黎世"), "Europe/Stockholm": String(localized: "斯德哥尔摩"), "Europe/Warsaw": String(localized: "华沙"), "Europe/Athens": String(localized: "雅典"), "Europe/Istanbul": String(localized: "伊斯坦布尔"),
        "Europe/Moscow": String(localized: "莫斯科"), "Africa/Cairo": String(localized: "开罗"), "Africa/Johannesburg": String(localized: "约翰内斯堡"), "Africa/Lagos": String(localized: "拉各斯"), "America/New_York": String(localized: "纽约"),
        "America/Toronto": String(localized: "多伦多"), "America/Chicago": String(localized: "芝加哥"), "America/Denver": String(localized: "丹佛"), "America/Phoenix": String(localized: "凤凰城"), "America/Los_Angeles": String(localized: "洛杉矶"),
        "America/Vancouver": String(localized: "温哥华"), "America/Anchorage": String(localized: "安克雷奇"), "America/Mexico_City": String(localized: "墨西哥城"), "America/Bogota": String(localized: "波哥大"), "America/Lima": String(localized: "利马"),
        "America/Santiago": String(localized: "圣地亚哥"), "America/Sao_Paulo": String(localized: "圣保罗"), "America/Argentina/Buenos_Aires": String(localized: "布宜诺斯艾利斯"), "Pacific/Honolulu": String(localized: "檀香山"),
        "Pacific/Auckland": String(localized: "奥克兰"), "Australia/Sydney": String(localized: "悉尼"), "Australia/Melbourne": String(localized: "墨尔本"), "Australia/Brisbane": String(localized: "布里斯班"), "Australia/Perth": String(localized: "珀斯"),
    ]

    static func city(_ zone: String) -> String { zoneNames[zone] ?? (zone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone) }

    /// `UTC+08:00`, `UTC−03:30`, `UTC` for zero.
    static func offset(_ zone: String, at date: Date = .now) -> String {
        guard let tz = TimeZone(identifier: zone) else { return zone }
        let seconds = tz.secondsFromGMT(for: date)
        if seconds == 0 { return "UTC" }
        let minutes = abs(seconds) / 60
        return "UTC" + (seconds < 0 ? "−" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// `上海 · UTC+08:00`.
    static func zoneLabel(_ zone: String, at date: Date = .now) -> String {
        TimeZone(identifier: zone) == nil ? zone : city(zone) + " · " + offset(zone, at: date)
    }

    /// Every `Area/Location` zone plus `UTC`, by current offset then name.
    static let allZones: [String] = {
        let names = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc/") } + ["UTC"]
        return names.sorted {
            let a = TimeZone(identifier: $0)?.secondsFromGMT() ?? 0, b = TimeZone(identifier: $1)?.secondsFromGMT() ?? 0
            return a == b ? $0 < $1 : a < b
        }
    }()

    static func editError(_ code: String?) -> String {
        switch code {
        case "schedule_not_found": String(localized: "这个任务已经不在了")
        case "schedule_ended": String(localized: "任务已结束，不能再改")
        case "schedule_conflict": String(localized: "任务刚被改过，返回后再试")
        case "invalid_prompt": String(localized: "名称和指令不能为空，名称最多 120 字")
        case "invalid_rule", "invalid_selector": String(localized: "运行时间无效，检查日期和时间")
        case "invalid_time_zone": String(localized: "时区不可用")
        case "not_future": String(localized: "选一个以后的时间")
        case "frequency_too_high": String(localized: "间隔至少 1 分钟")
        case "time_out_of_range": String(localized: "时间超出范围")
        case "subagent_session": String(localized: "这个对话收不到自动化任务")
        default: String(localized: "没能保存")
        }
    }
}

// MARK: - 自动化任务

/// 自动化任务: the Host's task catalog with 全部 / 已开启 / 已结束, search and 新建.
struct HostTasks: View {
    let host: Harness
    let open: (String) -> Void
    private enum Filter: Hashable { case all, active, ended }
    @State private var tasks: [ScheduleItem]?
    @State private var issue: String?
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var creating = false
    @State private var titles: [String: String]?
    @State private var notice: String?
    @State private var revision = 0
    private var notesStore: TaskNotes? { host.localEngineHome.map(TaskNotes.init(home:)) }

    private func matches(_ task: ScheduleItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return task.title.lowercased().contains(q) || task.prompt.lowercased().contains(q) || ScheduleText.rule(task).lowercased().contains(q)
    }

    var body: some View {
        List {
            if let notice { Section { Text(notice).font(.callout) }.listRowBackground(ChatColors.chip) }
            if let tasks {
                if tasks.isEmpty {
                    Section {
                        HostEmptyState(symbol: "calendar.badge.clock", title: String(localized: "还没有自动化任务"), message: String(localized: "到点自动发进对话，替你跑一遍"),
                                       action: (String(localized: "新建任务"), { creating = true }))
                    }.listRowBackground(Color.clear)
                } else {
                    let shown = tasks.filter { matches($0) && (filter == .all || (filter == .active) == $0.active) }
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(ChatColors.muted)
                            TextField("搜索任务", text: $query).autocorrectionDisabled()
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ChatColors.muted) }
                                    .buttonStyle(.plain).accessibilityLabel("清除")
                            }
                        }
                        Picker("筛选", selection: $filter) {
                            Text("全部 \(tasks.count)").tag(Filter.all)
                            Text("已开启 \(tasks.filter(\.active).count)").tag(Filter.active)
                            Text("已结束 \(tasks.filter { !$0.active }.count)").tag(Filter.ended)
                        }.pickerStyle(.segmented)
                    }.listRowBackground(ChatColors.chip)
                    if shown.isEmpty {
                        Section {
                            HostEmptyState(symbol: "magnifyingglass", title: !query.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "没有匹配的任务")
                                           : filter == .active ? String(localized: "没有开启中的任务") : String(localized: "没有已结束的任务"))
                        }.listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(shown) { task in
                                NavigationLink {
                                    ScheduleDetailPage(host: host, task: task, titles: titles, notesStore: notesStore, open: open) { revision += 1 }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: task.recurring ? "arrow.triangle.2.circlepath" : "alarm")
                                            .foregroundStyle(task.active ? Color.accentColor : ChatColors.muted).frame(width: 26)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: task.title.isEmpty ? String(localized: "未命名任务") : task.title).foregroundStyle(ChatColors.ink).lineLimit(2)
                                            Text(ScheduleText.summary(task)).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(2)
                                        }
                                    }
                                }.accessibilityIdentifier("schedule-" + task.id)
                            }
                        }.listRowBackground(ChatColors.chip)
                    }
                }
            } else if let issue {
                Section {
                    HostEmptyState(symbol: "exclamationmark.triangle", title: String(localized: "没能读取自动化任务"), message: issue, action: (String(localized: "重试"), { revision += 1 }))
                }.listRowBackground(Color.clear)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
        }
        .groupedList().scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .screenLeading) {
                Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建")
            }
        }
        .task(id: revision) { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $creating) {
            ScheduleEditor(host: host, task: nil) { saved in
                creating = false
                if saved != nil { notice = String(localized: "已创建"); revision += 1 }
            }
        }
    }

    private func refresh() async {
        do {
            let value = try await host.rpcValue("schedule/catalog", args: [:])
            let rows = value as? [Any]
            tasks = (rows ?? []).compactMap(ScheduleItem.init)
            if let notesStore, let rows {
                let ids = rows.compactMap { ($0 as? Object)?["id"] as? String }
                if ids.count == rows.count { notesStore.keep(Set(ids)) }
            }
            issue = nil
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        if let data = try? await host.sessionList() {
            titles = Dictionary((data["items"] as? [Object] ?? []).compactMap { item -> (String, String)? in
                guard let id = item["sessionId"] as? String else { return nil }
                return (id, ((item["projections"] as? Object)?["values"] as? Object)?["title"] as? String ?? "")
            }, uniquingKeysWith: { first, _ in first })
        }
    }
}

// MARK: - Task notes

/// The app-owned Harness reads this file anew for each run. Keep the legacy basename for both platforms.
@MainActor struct TaskNotes {
    static let limit = 8, length = 300
    private let file: URL

    init(home: URL) {
        file = home.appending(path: "ios-task-notes.json")
    }

    private func all() throws -> [String: [String]] {
        do { return try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [:] }
    }

    private func write(_ all: [String: [String]]) throws {
        let data = try JSONEncoder().encode(all)
        #if os(macOS)
        try data.write(to: file, options: .atomic)
        #else
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    func notes(_ id: String) throws -> [String] { try all()[id] ?? [] }

    /// The notes as the engine keeps them: one line each, trimmed, none empty, at most `limit` of `length` characters.
    static func normalized(_ notes: [String]) -> [String] {
        let clean = notes.map { note in
            let line = note.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return String(String.UnicodeScalarView(line.unicodeScalars.prefix(length)))
        }.filter { !$0.isEmpty }
        return Array(clean.prefix(limit))
    }

    func save(_ id: String, notes: [String], expecting previous: [String]) throws {
        var stored = try all()
        let current = stored[id] ?? []
        guard current != notes else { return }
        guard current == previous else { throw HostError(String(localized: "做法备注已改动，请重新打开任务。")) }
        stored[id] = notes.isEmpty ? nil : notes
        try write(stored)
    }

    func remove(_ id: String) {
        guard var stored = try? all(), stored.removeValue(forKey: id) != nil else { return }
        try? write(stored)
    }

    /// Drops the notes of tasks that are gone, given every task the engine has.
    func keep(_ ids: Set<String>) {
        guard let stored = try? all() else { return }
        let kept = stored.filter { ids.contains($0.key) }
        if kept.count != stored.count { try? write(kept) }
    }
}

/// One task: rule, instruction, 做法备注, 编辑任务, 立即运行, 运行记录 and 删除任务.
private struct ScheduleDetailPage: View {
    let host: Harness
    @State var task: ScheduleItem
    let titles: [String: String]?
    let notesStore: TaskNotes?
    let open: (String) -> Void
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var deleting = false
    @State private var busy = false
    @State private var notice: String?
    @State private var sentTo: String?
    @State private var history: [Object]?
    @State private var historyMissing: String?
    @State private var historyError: String?
    @State private var retention: (days: Int, records: Int?)?
    @State private var attempt = 0
    private struct Note: Identifiable { let id = UUID(); var text: String }
    @State private var notes: [Note] = []
    @State private var savedNotes: [String] = []
    @State private var notesIssue: String?
    @State private var clearingNotes = false
    @FocusState private var noteFocus: UUID?

    var body: some View {
        let rule = ScheduleText.rule(task)
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: task.recurring ? "arrow.triangle.2.circlepath" : "alarm").font(.system(size: 24))
                        .foregroundStyle(task.active ? Color.white : ChatColors.muted)
                        .frame(width: 56, height: 56).background(task.active ? Color.accentColor : ChatColors.muted.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: task.title.isEmpty ? String(localized: "未命名任务") : task.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Text(task.active ? "已开启" : "已结束").font(.subheadline).foregroundStyle(ChatColors.muted)
                    }
                }
                HStack(spacing: 12) {
                    stat(rule, String(localized: "运行"))
                    if task.active, let next = task.scheduledAt { stat(ScheduleText.when(next), String(localized: "下次")) }
                    else if let last = task.lastDeliveredAt { stat(ScheduleText.when(last), String(localized: "上次")) }
                }
            }.listRowBackground(Color.clear)
            if let notice {
                Section {
                    HStack {
                        Text(notice)
                        Spacer()
                        if let sentTo { Button("查看") { open(sentTo) } }
                    }
                }.listRowBackground(ChatColors.chip)
            }
            Section("规则") {
                LabeledContent("规则", value: rule)
                if task.active, let next = task.scheduledAt { LabeledContent("下次", value: ScheduleText.when(next)) }
                if let last = task.lastDeliveredAt { LabeledContent("上次", value: ScheduleText.when(last)) }
                if let zone = task.timeZone { LabeledContent("时区", value: ScheduleText.zoneLabel(zone)) }
                linkedChat
            }.listRowBackground(ChatColors.chip)
            Section("指令") { Text(verbatim: task.prompt).textSelection(.enabled).lineSpacing(3) }.listRowBackground(ChatColors.chip)
            if notesStore != nil { notesSection }
            Section {
                if task.active { Button { editing = true } label: { Label("编辑任务", systemImage: "pencil") }.disabled(busy) }
                Button { runNow() } label: { Label("立即运行", systemImage: "play.fill") }.disabled(busy)
            }.listRowBackground(ChatColors.chip)
            Section {
                if let history {
                    if history.isEmpty {
                        Label(historyMissing == nil ? "还没有运行过" : "记录不可用", systemImage: "clock.arrow.circlepath").foregroundStyle(ChatColors.muted)
                    }
                    ForEach(Array(history.enumerated()), id: \.offset) { _, run in
                        VStack(alignment: .leading, spacing: 2) {
                            let ran = (run["deliveredAt"] as? String).flatMap(ScheduleText.parseDate)
                            let planned = (run["scheduledAt"] as? String).flatMap(ScheduleText.parseDate)
                            let late = ran.flatMap { ran in planned.map { Int(ran.timeIntervalSince($0) / 60) } } ?? 0
                            Text((ran.map { ScheduleText.when($0) } ?? "—") + (late >= 1 ? String(localized: " · 晚了 \(late) 分钟") : ""))
                            if let line = (run["prompt"] as? String)?.split(separator: "\n").first {
                                Text(verbatim: String(line)).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1)
                            }
                        }
                    }
                } else if let historyError {
                    Button { attempt += 1 } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("没能读取运行记录")
                            Text(historyError + String(localized: " · 重试")).font(.caption).foregroundStyle(ChatColors.muted)
                        }
                    }
                } else { ProgressView().frame(maxWidth: .infinity) }
            } header: { Text("运行记录") } footer: {
                if let retention { Text(retention.records.map { "只保留最近 \(retention.days) 天、最多 \($0) 条" } ?? "只保留最近 \(retention.days) 天、最多 — 条") }
            }.listRowBackground(ChatColors.chip)
            Section {
                Button(role: .destructive) { deleting = true } label: { Label("删除任务", systemImage: "trash") }.disabled(busy)
            }.listRowBackground(ChatColors.chip)
        }
        .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle(task.title.isEmpty ? String(localized: "未命名任务") : task.title).inlineNavigationTitle()
        .task(id: attempt) { await loadHistory() }
        .onAppear { loadNotes() }
        .onDisappear { saveNotes() }
        .onChange(of: noteFocus) { old, _ in if old != nil { saveNotes() } }
        .alert("清空做法备注？", isPresented: $clearingNotes) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { noteFocus = nil; notes = []; saveNotes() }
        }
        .sheet(isPresented: $editing) {
            ScheduleEditor(host: host, task: task) { saved in
                editing = false
                if let saved { task = saved; notice = String(localized: "已保存"); sentTo = nil; changed() }
            }
        }
        .alert("删除这个任务？", isPresented: $deleting) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { remove() }
        } message: { Text("会停止之后的运行，并删掉它的运行记录。") }
    }

    private var notesSection: some View {
        Section("做法备注") {
            if let notesIssue { Text(notesIssue).foregroundStyle(.red) }
            ForEach($notes) { $note in
                HStack {
                    TextField("备注", text: $note.text, axis: .vertical).lineSpacing(3).focused($noteFocus, equals: note.id)
                    #if os(macOS)
                    Button(role: .destructive) {
                        let id = note.id
                        noteFocus = nil
                        notes.removeAll { $0.id == id }
                        saveNotes()
                    } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).accessibilityLabel("删除")
                    #endif
                }
            }
            .onDelete { notes.remove(atOffsets: $0); saveNotes() }
            if notes.count < TaskNotes.limit {
                Button {
                    let note = Note(text: "")
                    notes.append(note); noteFocus = note.id
                } label: { Label("添加备注", systemImage: "plus") }
            }
            if !notes.isEmpty {
                Button(role: .destructive) { clearingNotes = true } label: { Label("清空备注", systemImage: "trash") }
            }
        }.listRowBackground(ChatColors.chip)
    }

    private func loadNotes() {
        guard let notesStore else { return }
        do {
            savedNotes = try notesStore.notes(task.id)
            notes = savedNotes.map { Note(text: $0) }
            notesIssue = nil
        } catch { notesIssue = String(localized: "未能读取") }
    }

    /// The note being typed stays as it is on screen; the file gets every note as the engine reads them.
    @discardableResult
    private func saveNotes() -> Bool {
        guard let notesStore else { return true }
        let clean = TaskNotes.normalized(notes.map(\.text))
        do {
            if clean != savedNotes {
                try notesStore.save(task.id, notes: clean, expecting: savedNotes)
                savedNotes = clean
                notesIssue = nil
            }
            if noteFocus == nil { loadNotes() }
            return true
        } catch {
            notesIssue = (error as? HostError)?.message ?? String(localized: "无法保存")
            return false
        }
    }

    @ViewBuilder private var linkedChat: some View {
        let title = task.sessionId.flatMap { titles?[$0] }
        Button { if let id = task.sessionId, title != nil { open(id) } } label: {
            HStack {
                Text("关联对话").foregroundStyle(ChatColors.ink)
                Spacer()
                if let titles {
                    Text(task.sessionId == nil ? String(localized: "新对话") : (title.map { $0.isEmpty ? String(localized: "未命名对话") : $0 } ?? (titles.isEmpty ? "" : String(localized: "对话已删除"))))
                        .foregroundStyle(ChatColors.muted).lineLimit(1)
                }
                if title != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted) }
            }
        }.disabled(title == nil)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(ChatColors.ink).lineLimit(2)
            Text(label).font(.caption).foregroundStyle(ChatColors.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(ChatColors.chip.opacity(0.87), in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadHistory() async {
        historyError = nil
        var request: Object = ["id": task.id, "limit": 20]
        if !task.usesTarget, let session = task.sessionId { request["sessionId"] = session }
        do {
            let value = try await host.call("schedule/history", request)
            if let code = value["code"] as? String { historyMissing = code; history = []; return }
            history = value["records"] as? [Object] ?? []
            let bounds = value["retention"] as? Object
            if value["earlierRecordsPruned"] as? Bool == true, let days = (bounds?["days"] as? NSNumber)?.intValue {
                retention = (days, (bounds?["records"] as? NSNumber)?.intValue)
            }
        } catch { if !Task.isCancelled { history = nil; historyError = error.localizedDescription } }
    }

    private func runNow() {
        guard saveNotes() else { return }
        busy = true; notice = nil; sentTo = nil
        Task {
            defer { busy = false }
            do {
                let value = try await host.call("schedule/run", ["id": task.id])
                if value["code"] != nil { throw HostError(String(localized: "没能发进对话，检查连接后再试")) }
                let target = (value["target"] as? Object)?["sessionId"] as? String
                notice = String(localized: "已发进对话"); sentTo = target ?? task.sessionId
                if let updated = ScheduleItem(value) { task = updated }
                changed(); attempt += 1
            } catch { notice = String(localized: "没能发进对话，检查连接后再试") }
        }
    }

    private func remove() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let value: Object
                if task.usesTarget {
                    value = try await host.call("schedule/edit", ["id": task.id, "action": "delete", "expectedUpdatedAt": task.updatedAt])
                    if let code = value["code"] as? String, code != "schedule_not_found" { throw HostError(ScheduleText.editError(code)) }
                } else {
                    value = try await host.call("schedule/delete", ["sessionId": task.sessionId ?? "", "id": task.id])
                }
                notesStore?.remove(task.id)
                savedNotes = []; notes = []
                changed()
                dismiss()
            } catch { notice = String(localized: "没能删除：") + error.localizedDescription }
        }
    }
}

/// 新建 / 编辑自动化任务: name, instruction, run time (重复, 时间, 日期, 时区), 接下来, 在哪里运行.
private struct ScheduleEditor: View {
    let host: Harness
    let task: ScheduleItem?
    let finished: (ScheduleItem?) -> Void
    @State private var title: String
    @State private var prompt: String
    @State private var draft: ScheduleDraft
    private let initial: ScheduleDraft
    private let deviceZone = TimeZone.current.identifier
    @State private var intervalText: String
    @State private var sessions: [(id: String, title: String)] = []
    @State private var workspaces: [HostWorkspace] = []
    @State private var sessionID = ""
    @State private var workspaceID = ""
    @State private var errors: [String: String] = [:]
    @State private var formError: String?
    @State private var saving = false

    init(host: Harness, task: ScheduleItem?, finished: @escaping (ScheduleItem?) -> Void) {
        self.host = host; self.task = task; self.finished = finished
        let draft = task.map { ScheduleDraft.from($0, deviceZone: TimeZone.current.identifier, now: .now) } ?? ScheduleDraft.initial(zone: TimeZone.current.identifier, now: .now)
        initial = draft
        _draft = State(initialValue: draft)
        _title = State(initialValue: task?.title ?? "")
        _prompt = State(initialValue: task?.prompt ?? "")
        _intervalText = State(initialValue: String(draft.interval))
    }

    private var custom: Bool { task?.kind == "rrule" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("名称").font(.caption).foregroundStyle(ChatColors.muted)
                        TextField("名称", text: $title, prompt: Text("比如：每天早上提醒我带伞"))
                            .accessibilityIdentifier("任务名称").onChange(of: title) { _, value in
                                if value.count > 120 { title = String(value.prefix(120)) }
                                errors["title"] = nil; formError = nil
                            }
                        if let error = errors["title"] { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("指令").font(.caption).foregroundStyle(ChatColors.muted)
                        TextField("指令", text: $prompt, prompt: Text("比如：查一下今天的天气，要下雨就提醒我带伞"), axis: .vertical).lineLimit(4...12)
                            .accessibilityIdentifier("scheduleInstruction").onChange(of: prompt) { _, _ in errors["prompt"] = nil; formError = nil }
                        if let error = errors["prompt"] { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }.listRowBackground(ChatColors.chip)
                Section("运行时间") { timingRows }.listRowBackground(ChatColors.chip).disabled(saving)
                if !custom { Section { preview }.listRowBackground(ChatColors.chip) }
                if task == nil { placeSection }
                if let formError { Section { Text(formError).foregroundStyle(.red) } }
            }
            .scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
            .navigationTitle(task == nil ? "新建自动化任务" : "编辑自动化任务").inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { finished(nil) }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button(task == nil ? "创建" : "保存") { save() } }
                }
            }
            .interactiveDismissDisabled(saving || title != (task?.title ?? "") || prompt != (task?.prompt ?? "") || draft != initial)
            .task { if task == nil { await loadPlaces() } }
        }
    }

    @ViewBuilder private var timingRows: some View {
        if custom {
            LabeledContent("重复", value: String(localized: "自定义"))
        } else {
            Picker("重复", selection: Binding(get: { draft.kind }, set: { kind in
                draft = draft.with(kind); intervalText = String(draft.interval); formError = nil
            })) {
                ForEach(ScheduleDraft.Kind.allCases) { Text($0.rawValue.localized).tag($0) }
            }
            switch draft.kind {
            case .daily, .weekdays: clockRow
            case .weekly: weekdayRow; clockRow
            case .monthly:
                NavigationLink {
                    MonthDayPicker(days: Binding(get: { draft.monthDays }, set: { draft.monthDays = $0 }))
                } label: {
                    LabeledContent("日期", value: draft.monthDays.isEmpty ? String(localized: "未选") : draft.monthDays.sorted().map(String.init).joined(separator: String(localized: "、")) + String(localized: " 日"))
                }
                clockRow
            case .interval:
                HStack {
                    Text("每")
                    TextField("1", text: $intervalText).numericKeyboard().multilineTextAlignment(.center).frame(width: 64)
                        .padding(.vertical, 4).background(ChatColors.muted.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .onChange(of: intervalText) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { intervalText = digits }
                            draft.interval = Int(digits) ?? 0
                        }
                    Spacer()
                    Picker("单位", selection: $draft.unit) { ForEach(ScheduleDraft.Unit.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 180)
                }
            case .once:
                DatePicker("日期", selection: dateBinding, in: draft.calendar.startOfDay(for: .now)..., displayedComponents: .date)
                    .environment(\.timeZone, draft.zone).environment(\.calendar, draft.calendar)
                clockRow
            case .cron:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cron 表达式").font(.caption).foregroundStyle(ChatColors.muted)
                    TextField("0 9 * * 1-5", text: $draft.expression).font(.body.monospaced())
                        .noAutomaticCapitalization().autocorrectionDisabled()
                    Text("分  时  日  月  周").font(.caption.monospaced()).foregroundStyle(ChatColors.muted)
                }
            }
            if draft.kind != .interval {
                NavigationLink {
                    ZonePicker(selected: draft.timeZone, device: deviceZone) { draft.timeZone = $0 }
                } label: { LabeledContent("时区", value: ScheduleText.zoneLabel(draft.timeZone)) }
            }
        }
    }

    private var clockRow: some View {
        DatePicker("时间", selection: Binding(get: {
            draft.instant(2001, 1, 1, draft.hour, draft.minute, 0) ?? .now
        }, set: { date in
            let parts = draft.calendar.dateComponents([.hour, .minute], from: date)
            if parts.hour != draft.hour || parts.minute != draft.minute {
                draft.hour = parts.hour ?? draft.hour; draft.minute = parts.minute ?? draft.minute; draft.second = 0
            }
        }), displayedComponents: .hourAndMinute)
        .environment(\.timeZone, draft.zone)
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { draft.instant(draft.year, draft.month, draft.day, 12, 0, 0) ?? .now }, set: { date in
            let parts = draft.calendar.dateComponents([.year, .month, .day], from: date)
            draft.year = parts.year ?? draft.year; draft.month = parts.month ?? draft.month; draft.day = parts.day ?? draft.day
        })
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(1...7, id: \.self) { day in
                let on = draft.weekdays.contains(day)
                Button {
                    if on { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                } label: {
                    Text(ScheduleText.weekdayNames[day - 1]).font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : ChatColors.ink)
                        .frame(width: 36, height: 36).background(on ? Color.accentColor : ChatColors.muted.opacity(0.1), in: Circle())
                }.buttonStyle(.plain).frame(maxWidth: .infinity)
                    .accessibilityLabel(String(localized: "周") + ScheduleText.weekdayNames[day - 1]).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var preview: some View {
        let now = Date.now
        let error = draft.validate(now: now)
        let anchor = task != nil && draft == initial && task?.kind == "every" ? task?.scheduledAt : nil
        let runs = error == nil ? draft.nextRuns(now: now, anchor: anchor) : []
        let foreign = draft.kind != .interval && draft.timeZone != deviceZone
        let title = (error == nil || draft.kind != .cron ? draft.describe(now: now) : "")
            + (foreign && (error == nil || draft.kind != .cron) ? String(localized: "（") + ScheduleText.city(draft.timeZone) + String(localized: "时间）") : "")
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { Text(title).font(.headline) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            else {
                Text(foreign ? "接下来（本机时间）" : "接下来").font(.caption).foregroundStyle(ChatColors.muted).padding(.top, 4)
                ForEach(runs, id: \.self) { run in
                    Text(ScheduleText.run(run, zone: deviceZone, now: now)).font(.callout.monospacedDigit()).foregroundStyle(ChatColors.muted)
                }
            }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private var placeSection: some View {
        Section("结果发到") {
            Picker("对话", selection: $sessionID) {
                Text("新对话").tag("")
                ForEach(sessions.prefix(40), id: \.id) { Text($0.title).tag($0.id) }
            }
            if sessionID.isEmpty, !workspaces.isEmpty {
                Picker("文件夹", selection: $workspaceID) {
                    Text("默认").tag("")
                    ForEach(workspaces) { Text($0.name).tag($0.id) }
                }
            }
        }.listRowBackground(ChatColors.chip).disabled(saving)
    }

    private func loadPlaces() async {
        if let data = try? await host.sessionList() {
            sessions = (data["items"] as? [Object] ?? []).compactMap { item in
                guard let id = item["sessionId"] as? String, item["origin"] as? String != "subagent" else { return nil }
                let title = (((item["projections"] as? Object)?["values"] as? Object)?["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                return (id, title.isEmpty ? String(localized: "未命名对话") : title)
            }
        }
        if let stream = try? await host.stream("workspace/follow", args: [:]) {
            defer { stream.cancel() }
            if let frame = try? await stream.next(), frame["type"] as? String == "baseline" {
                workspaces = ((frame["value"] as? Object)?["items"] as? [Any] ?? []).compactMap(HostWorkspace.init)
            }
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines), text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [String: String] = [:]
        if name.isEmpty { found["title"] = String(localized: "填写名称") }
        if text.isEmpty { found["prompt"] = String(localized: "填写指令") }
        let timingError = custom ? nil : draft.validate(now: .now)
        errors = found; formError = timingError
        guard found.isEmpty, timingError == nil else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if let task { try await saveEdit(task, name: name, text: text) } else { try await create(name: name, text: text) }
            } catch let error as HostError where error.code == "edit" {
                formError = error.message
            } catch {
                formError = (task == nil ? String(localized: "没能创建：") : String(localized: "没能保存：")) + ((error as? HostError)?.code != nil ? String(localized: "请稍后重试") : error.localizedDescription)
            }
        }
    }

    private func saveEdit(_ task: ScheduleItem, name: String, text: String) async throws {
        let timing = custom || draft == initial ? nil : draft.timing
        guard name != task.title || text != task.prompt || timing != nil else { finished(task); return }
        var patch: Object = [:]
        if name != task.title { patch["title"] = name }
        if text != task.prompt { patch["prompt"] = text }
        let value: Object
        if task.usesTarget {
            if let timing { patch["timing"] = timing }
            value = try await host.call("schedule/edit", ["id": task.id, "action": "update", "patch": patch, "expectedUpdatedAt": task.updatedAt])
        } else {
            var request = patch
            request["sessionId"] = task.sessionId ?? ""; request["id"] = task.id
            var expected = task.raw; expected["sessionId"] = nil; expected["status"] = nil; expected["lastDelivery"] = nil
            request["expected"] = expected
            value = try await host.call("schedule/update", request)
        }
        if let code = value["code"] as? String { throw HostError(ScheduleText.editError(code), code: "edit") }
        var record = (value["record"] as? Object) ?? value
        if !task.usesTarget { record["sessionId"] = task.sessionId; record["status"] = task.active ? "active" : "inactive" }
        finished(ScheduleItem(record) ?? task)
    }

    private func create(name: String, text: String) async throws {
        guard let timing = draft.timing else { throw HostError(String(localized: "运行时间无效，检查日期和时间"), code: "edit") }
        var request: Object = ["title": name, "prompt": text, "timing": timing]
        if sessionID.isEmpty {
            var create: Object = [:]
            if let workspace = workspaces.first(where: { $0.id == workspaceID }) { create["cwd"] = workspace.path }
            request["target"] = ["kind": "new_once", "create": create] as Object
        } else {
            request["target"] = ["kind": "session", "sessionId": sessionID]
        }
        let value = try await host.call("schedule/create", request)
        if let code = value["code"] as? String { throw HostError(ScheduleText.editError(code), code: "edit") }
        finished(ScheduleItem(value) ?? ScheduleItem(["id": value["id"] ?? UUID().uuidString, "target": ["kind": "new"]]))
    }
}

/// Days of the month for 每月.
private struct MonthDayPicker: View {
    @Binding var days: Set<Int>
    var body: some View {
        List {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                ForEach(1...31, id: \.self) { day in
                    let on = days.contains(day)
                    Button { if on { days.remove(day) } else { days.insert(day) } } label: {
                        Text("\(day)").font(.subheadline.monospacedDigit().weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : ChatColors.ink)
                            .frame(width: 38, height: 38).background(on ? Color.accentColor : ChatColors.muted.opacity(0.1), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("\(day) 日").accessibilityAddTraits(on ? .isSelected : [])
                }
            }.padding(.vertical, 6).listRowBackground(ChatColors.chip)
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
            .navigationTitle("日期").inlineNavigationTitle()
    }
}

/// The searchable zone list: this phone's zone first, then 常用, then 全部.
private struct ZonePicker: View {
    let selected: String
    let device: String
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private func matches(_ zone: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "−", with: "-")
        guard !q.isEmpty else { return true }
        return zone.lowercased().contains(q) || ScheduleText.city(zone).lowercased().contains(q)
            || ScheduleText.offset(zone).lowercased().replacingOccurrences(of: "−", with: "-").contains(q)
    }

    var body: some View {
        let all = ScheduleText.allZones
        let pinned = [device] + (selected == device ? [] : [selected])
        List {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let shown = all.filter(matches)
                if shown.isEmpty { Text("没有匹配的时区").foregroundStyle(ChatColors.muted) }
                ForEach(shown, id: \.self) { row($0) }
            } else {
                Section { ForEach(pinned.filter { TimeZone(identifier: $0) != nil }, id: \.self) { row($0) } }
                Section("常用") { ForEach(all.filter { ScheduleText.zoneNames[$0] != nil && !pinned.contains($0) }, id: \.self) { row($0) } }
                Section("全部") { ForEach(all.filter { ScheduleText.zoneNames[$0] == nil && !pinned.contains($0) }, id: \.self) { row($0) } }
            }
        }.searchable(text: $query, prompt: Text("搜索城市、时区或 UTC 偏移"))
        .navigationTitle("时区").inlineNavigationTitle()
    }

    private func row(_ zone: String) -> some View {
        Button { pick(zone); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScheduleText.city(zone)).foregroundStyle(ChatColors.ink)
                    Text(zone == device ? ScheduleText.city(zone) + String(localized: " · 本机") : zone).font(.caption).foregroundStyle(ChatColors.muted)
                }
                Spacer()
                Text(ScheduleText.offset(zone)).font(.caption.monospacedDigit()).foregroundStyle(ChatColors.muted)
                if zone == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(zone == selected ? .isSelected : [])
    }
}

// MARK: - 目标

/// The goal's actions under 对话详情 › 进度: 设定目标, or 编辑目标 / 暂停 / 恢复 / 清除目标.
struct GoalView: View {
    let host: Harness
    let goal: Object?
    let changed: () -> Void
    @State private var editing = false
    @State private var clearing = false
    @State private var objective = ""
    @State private var roundLimit = ""
    @State private var note: String?
    @State private var busy = false

    private var phase: String { goal?["phase"] as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if goal == nil {
                    Button { begin() } label: { Label("设定目标", systemImage: "scope") }
                } else {
                    Button("编辑目标") { begin() }
                    if phase == "active" {
                        Button("暂停") { run("pause") }.accessibilityHint("先不自动推进")
                    } else if ["paused", "blocked"].contains(phase) {
                        Button("恢复") { run("resume") }.accessibilityHint("继续自动推进")
                    }
                    Button("清除目标", role: .destructive) { clearing = true }
                }
            }.buttonStyle(.bordered).controlSize(.small)
            if let note { Text(note).font(.caption).foregroundStyle(.red) }
        }.disabled(busy)
        .confirmationDialog("清除目标？", isPresented: $clearing, titleVisibility: .visible) {
            Button("清除目标", role: .destructive) { run("clear") }
        } message: { Text("自动推进会停止。") }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    TextField("目标", text: $objective, prompt: Text("要完成什么"), axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("goalObjective")
                    TextField("最大轮数（可选）", text: $roundLimit).numericKeyboard()
                }.navigationTitle(goal == nil ? "设定目标" : "编辑目标").inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { editing = false; run(goal == nil ? "create" : "edit") }.disabled(!valid)
                    }
                }
            }.presentationDetents([.medium, .large])
        }
    }

    private var valid: Bool {
        !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (roundLimit.isEmpty || (Int(roundLimit) ?? 0) > 0)
    }

    private func begin() {
        objective = goal?["objective"] as? String ?? ""
        roundLimit = (goal?["maxGoalRounds"] as? Int).map(String.init) ?? ""
        editing = true
    }

    private func run(_ method: String) {
        busy = true; note = nil
        Task {
            defer { busy = false }
            do {
                var fields: Object = ["agentId": host.sessionID]
                if method == "create" || method == "edit" {
                    var request: Object = ["objective": objective.trimmingCharacters(in: .whitespacesAndNewlines)]
                    if let cap = Int(roundLimit) { request["maxGoalRounds"] = cap }
                    fields["request"] = request
                }
                if method != "create" {
                    let current = try await host.rpcValue("goals/get", args: ["agentId": host.sessionID]) as? Object
                    guard let id = current?["id"] as? String, let revision = current?["revision"] as? Int else { throw HostError(String(localized: "还没有目标")) }
                    fields["ref"] = ["id": id, "revision": revision] as Object
                }
                _ = try await host.rpcValue("goals/" + method, args: fields)
                changed()
            } catch { note = String(localized: "当前无法执行，请查看目标") + ((error as? HostError)?.code.map { String(localized: "（\($0)）") } ?? "") }
        }
    }
}
