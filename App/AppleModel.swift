import Foundation
import SwiftUI
#if os(iOS)
import CoreGraphics
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The on-device Apple model for conversation titles, notification replies, and iPhone step checks.
/// Callers fall back when the system model is unavailable or gives no usable answer.
enum AppleModel {
    /// `appleModelTitles` = NO in the defaults turns every use off.
    static let enabledKey = "appleModelTitles"
    /// `appleModelSummary` = NO turns off only the one-line summary.
    static let summaryKey = "appleModelSummary"

    struct Request: Decodable, Sendable {
        let appleModelRequest: UUID
        /// Absent: a title, with the engine's own instructions. `summary`: one line for a notification.
        let task: String?
        let system: String
        let input: String
    }

    enum Answer: Equatable {
        case text(String)
        /// Not now, but it may come: switched off, still downloading, declined this prompt.
        case none
        /// This device or OS has no such model; asking again is pointless until relaunch.
        case absent
    }

    /// An answer with how long the model took.
    struct Timed: Sendable, Equatable {
        let value: String
        var reason: String?
        let seconds: Double
    }

    #if os(iOS)
    /// `appleModelRisk` = NO turns off only the check of phone steps.
    static let riskKey = "appleModelRisk"

    /// What a phone step is about to touch, as the risk check reads it.
    struct StepContext: Sendable, Equatable {
        var app: String?
        var page: String?
        var role: String
        var label: String
        /// Other labels on the screen, top to bottom.
        var nearby: [String] = []
        var typed: String?

        var prompt: String {
            var lines: [String] = []
            if let app, !app.isEmpty { lines.append("App: \(app)") }
            if let page, !page.isEmpty { lines.append("Page: \(page)") }
            lines.append("Control to tap: \(role) \"\(label)\"")
            if let typed, !typed.isEmpty { lines.append("Text just typed: \"\(typed.prefix(80))\"") }
            let others = nearby.filter { $0 != label }.prefix(24).map { String($0.prefix(40)) }
            if !others.isEmpty { lines.append("Also on screen: " + others.joined(separator: " | ")) }
            return lines.joined(separator: "\n")
        }
    }
    #endif

    static var switchedOff: Bool { off(enabledKey) }

    /// `bool(forKey:)` also reads a launch argument's "NO", which arrives as a string.
    static func off(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) != nil && !defaults.bool(forKey: key)
    }

    static func answer(system: String, input: String, maxTokens: Int = 64) async -> Answer {
        if switchedOff { return .none }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return .absent }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: break
        case .unavailable(.deviceNotEligible): return .absent
        case .unavailable: return .none
        }
        do {
            let session = LanguageModelSession(model: model, instructions: system)
            let reply = try await session.respond(to: input, options: GenerationOptions(maximumResponseTokens: maxTokens)).content
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .text(text)
        } catch {
            Log.engine.notice("apple model gave no answer: \(String(describing: type(of: error)), privacy: .public)")
            return .none
        }
        #else
        return .absent
        #endif
    }

    /// The line the engine's `apple-model.cjs` waits for.
    static func reply(to request: Request) async -> [String: String] {
        var reply = ["appleModelReply": request.appleModelRequest.uuidString.lowercased()]
        let begin = ContinuousClock.now
        let answer: Answer
        switch request.task {
        case "summary": answer = await summarize(request.input).map { .text($0.value) } ?? .none
        default:
            answer = await self.answer(system: request.system, input: request.input)
        }
        switch answer {
        case .text(let text): reply["value"] = text
        case .none: break
        case .absent: reply["absent"] = "true"
        }
        reply["seconds"] = String(seconds(since: begin))
        Log.engine.notice("apple model asked \(request.task ?? "title", privacy: .public): \(answer == .absent ? "absent" : answer == .none ? "none" : "answered", privacy: .public)")
        return reply
    }

    // MARK: One-line summary

    static let summaryInstructions = """
    You write the one line a lock-screen notification shows when an assistant has finished a task. \
    Say what was done or found, keeping the one most important number, date or name. \
    Write in the language of the assistant's reply. At most 30 characters in Chinese, or 8 words in English. \
    No greeting, no quotes, no Markdown, no ending period.
    """

    #if os(iOS)
    // MARK: Phone prompts (the probe measures these same words)

    static let riskInstructions = """
    You check one step an assistant is about to take on a person's iPhone, inside another app, before it happens. \
    Say what tapping this control would commit, if anything, that the person could not simply take back:
    send: sends a message, email, post, comment, review or invitation to other people.
    pay: pays, tips, transfers or buys something now.
    order: places an order, books or reserves, requests a ride, starts a subscription or free trial, submits a return, claim or refill.
    delete: deletes or erases something, cancels an order, booking, ride or subscription, unsends.
    account: signs out, changes a password, security or privacy setting, a plan or personal details, or agrees to terms.
    none: anything else, such as opening a page or tab, searching, viewing details, orders, bills, activity or rewards, tracking a package, \
    choosing an option on a form, adding to a cart, list or wishlist, going on to checkout or the next step, closing a pop-up, going back.
    Judge only what this one tap does at once. A control that only opens the page where such a choice is made is none, \
    even when that page is about orders, payments, returns or a subscription. Labels may be in any language.
    """

    static let routeInstructions = """
    You decide which way an assistant on an iPhone will handle a request.
    phone: it must operate apps on this iPhone: shopping, food delivery, rides, messages, email, calendar, settings, banking apps, or reading what an app shows.
    computer: it must work on the person's paired Mac or PC: files or folders on the computer, code, terminals, programs that run there.
    answer: it can reply from knowledge, a web search, or the conversation alone: questions, writing, translation, advice, chat.
    """

    static let screenInstructions = """
    You look at one iPhone screenshot and say whether it asks the person for something an assistant must never fill in for them.
    login: a sign-in page asking for an email, phone number, user name or password, or a Face ID or passcode prompt.
    payment: a page that asks for card details, or confirms a payment or purchase.
    code: a page that asks for a one-time verification code, or a CAPTCHA.
    other: anything else.
    """

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    enum RiskKind: String, CaseIterable {
        case none, send, pay, delete, order, account
    }

    @available(iOS 26.0, *)
    @Generable
    struct StepRisk {
        @Guide(description: "At most eight words on what this one tap does at once")
        var reason: String
        @Guide(description: "What tapping this control commits")
        var kind: RiskKind
    }

    @available(iOS 26.0, *)
    @Generable
    enum Route: String, CaseIterable {
        case phone, computer, answer
    }

    @available(iOS 26.0, *)
    @Generable
    struct RouteChoice {
        var route: Route
    }

    @available(iOS 26.0, *)
    @Generable
    enum ScreenKind: String, CaseIterable {
        case login, payment, code, other
    }

    @available(iOS 26.0, *)
    @Generable
    struct ScreenChoice {
        var kind: ScreenKind
    }
    #endif
    #endif

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    static var model: SystemLanguageModel? {
        guard !switchedOff else { return nil }
        let model = SystemLanguageModel.default
        return model.availability == .available ? model : nil
    }
    #endif

    /// The model can be asked right now.
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) { return model != nil }
        #endif
        return false
    }

    #if os(iOS)
    // MARK: Risk of a phone step

    /// What tapping this control commits, by the model's reading: a `RiskKind` raw value. Nil when
    /// the model has no answer within `limit` seconds. Callers only ever add a question with it.
    static func classifyStep(_ step: StepContext, limit: Double = 4) async -> Timed? {
        guard !off(riskKey) else { return nil }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), let model else { return nil }
        let begin = ContinuousClock.now
        let prompt = step.prompt
        let risk = try? await limited(limit) {
            let session = LanguageModelSession(model: model, instructions: riskInstructions)
            return try await session.respond(to: prompt, generating: StepRisk.self,
                                             options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 48)).content
        }
        guard let risk else { return nil }
        return Timed(value: risk.kind.rawValue, reason: risk.reason, seconds: seconds(since: begin))
        #else
        return nil
        #endif
    }
    #endif

    /// The reply in one line for a notification or a Live Activity, or nil.
    static func summarize(_ reply: String, limit: Double = 8) async -> Timed? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), !off(summaryKey), let model else { return nil }
        let text = String(reply.prefix(3000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let begin = ContinuousClock.now
        let raw = try? await limited(limit) {
            let session = LanguageModelSession(model: model, instructions: summaryInstructions)
            return try await session.respond(to: "The assistant's reply:\n\n" + text,
                                             options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 48)).content
        }
        guard let raw, let line = oneLine(raw) else { return nil }
        return Timed(value: line, seconds: seconds(since: begin))
        #else
        return nil
        #endif
    }

    /// The first line without quotes or marks; nil when it is far over the length a banner shows.
    static func oneLine(_ raw: String) -> String? {
        var line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”「」*#-•。.")).replacingOccurrences(of: "**", with: "")
        guard !line.isEmpty else { return nil }
        let wide = line.unicodeScalars.contains { $0.value >= 0x2E80 }
        let limit = wide ? 30 : 60
        guard line.count <= limit + limit / 3 else { return nil }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    #if os(iOS)
    // MARK: Route and screen kind (measured by the probe, not wired)

    static func route(_ request: String, limit: Double = 4) async -> Timed? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), let model else { return nil }
        let begin = ContinuousClock.now
        let choice = try? await limited(limit) {
            let session = LanguageModelSession(model: model, instructions: routeInstructions)
            return try await session.respond(to: "Request: " + request, generating: RouteChoice.self,
                                             options: GenerationOptions(sampling: .greedy)).content
        }
        guard let choice else { return nil }
        return Timed(value: choice.route.rawValue, seconds: seconds(since: begin))
        #else
        return nil
        #endif
    }

    /// iOS 27 takes images: whether this screen asks for a sign-in, a payment or a code.
    static func screenKind(_ image: CGImage, limit: Double = 10) async -> Timed? {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *), let model else { return nil }
        let begin = ContinuousClock.now
        let choice = try? await limited(limit) {
            let session = LanguageModelSession(model: model, instructions: screenInstructions)
            return try await session.respond(generating: ScreenChoice.self, options: GenerationOptions(sampling: .greedy)) {
                "Which kind of screen is this?"
                Attachment(image)
            }.content
        }
        guard let choice else { return nil }
        return Timed(value: choice.kind.rawValue, seconds: seconds(since: begin))
        #else
        return nil
        #endif
    }
    #endif

    // MARK: Helpers

    static func seconds(since begin: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - begin
        let value = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (value * 1000).rounded() / 1000
    }

    private struct TimedOut: Error {}

    static func limited<T: Sendable>(_ limit: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(limit)); throw TimedOut() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

#if os(iOS)
/// The one-line summaries the engine had the Apple model write as turns ended, newest last. The
/// "replied" notification shows one, and a Live Activity can later.
@MainActor
final class AppleModelSummaries {
    static let shared = AppleModelSummaries()

    struct Line {
        let text: String
        let session: String
        let at: Date
    }

    private(set) var latest: Line?

    func note(_ text: String, session: String) {
        latest = Line(text: text, session: session, at: Date())
    }

    /// A summary noted after `since`, waiting at most `wait` seconds for one to come.
    func line(after since: Date, wait: Double) async -> String? {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if let latest, latest.at >= since { return latest.text }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif

/// The new conversation's four examples, written for this moment: the on-device model first, the
/// default chat model on this phone's engine when there is none. Only the hour, the weekday, the
/// month and the broad topics of recent conversation titles go in; what comes back is checked
/// for anything personal and dropped whole when it does not pass. Until then, and whenever it
/// fails, the fixed examples show.
@MainActor
final class StarterIdeas: ObservableObject {
    static let shared = StarterIdeas()

    struct Example: Codable, Equatable {
        let symbol: String
        let label: String
        let text: String
    }

    private struct Saved: Codable {
        let slot: String
        let examples: [Example]
    }

    private static let savedKey = "starterIdeas.v3"
    /// `starterIdeasOn` = NO keeps the fixed examples.
    static let enabledKey = "starterIdeasOn"

    @Published private(set) var examples: [Example]?
    private var making: String?
    #if os(iOS)
    private var waiting: [String: CheckedContinuation<String, Never>] = [:]
    #endif

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.slot == Self.slot() {
            examples = saved.examples
        }
    }

    /// One set per part of the day and language: the morning's ideas stay until the afternoon.
    static func slot(at date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part = switch hour { case 5..<11: "morning"; case 11..<13: "noon"; case 13..<18: "afternoon"; case 18..<23: "evening"; default: "night" }
        let day = date.formatted(.iso8601.year().month().day())
        return "\(day)|\(part)|\(language)"
    }

    private static var language: String { Bundle.main.preferredLocalizations.first ?? "zh-Hans" }

    func refresh() async {
        guard !AppleModel.off(Self.enabledKey) else { examples = nil; return }
        let slot = Self.slot()
        if examples != nil, (try? JSONDecoder().decode(Saved.self, from: UserDefaults.standard.data(forKey: Self.savedKey) ?? Data()))?.slot == slot { return }
        guard making != slot else { return }
        making = slot
        defer { making = nil }
        let input = Self.input()
        var list: [Example]?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) { list = await Self.onDevice(input) }
        #endif
        #if os(iOS)
        if list == nil { list = Self.parse(await askEngine(input)) }
        #endif
        guard let list, Self.slot() == slot else { return }
        withAnimation(Motion.reduced ? nil : Motion.std(Motion.standard)) { examples = list }
        if let data = try? JSONEncoder().encode(Saved(slot: slot, examples: list)) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    enum Kind: String, CaseIterable {
        case calendar, reminder, folder, app, web, weather, computer
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Idea {
        var kind: Kind
        @Guide(description: "The whole request in one specific sentence, in the requested language, as the user would type it")
        var request: String
        @Guide(description: "That request shortened to a few words, keeping what is specific about it; never just the kind")
        var chip: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct IdeaSet {
        @Guide(description: "Four ideas of different kinds", .count(4))
        var ideas: [Idea]
    }

    /// Structured output: the small model keeps the shape, the checks in `accept` keep the content.
    @available(iOS 26.0, macOS 26.0, *)
    private static func onDevice(_ input: String) async -> [Example]? {
        guard let model = AppleModel.model else { return nil }
        let instructions = system
        let set = try? await AppleModel.limited(20) {
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: input, generating: IdeaSet.self,
                                             options: GenerationOptions(maximumResponseTokens: 500)).content
        }
        guard let set else { return nil }
        return accept(set.ideas.map { ($0.kind.rawValue, $0.chip, $0.request) })
    }
    #endif

    #if os(iOS)
    private func askEngine(_ input: String) async -> String {
        let id = UUID().uuidString.lowercased()
        return await withCheckedContinuation { reply in
            waiting[id] = reply
            guard EmbeddedEngine.shared.starterIdeas(id, system: Self.system, input: input) else {
                waiting.removeValue(forKey: id)?.resume(returning: "")
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(35))
                self?.waiting.removeValue(forKey: id)?.resume(returning: "")
            }
        }
    }

    func engineAnswered(_ id: String, _ value: String) {
        waiting.removeValue(forKey: id)?.resume(returning: value)
    }
    #endif

    private static let symbols = ["calendar": "calendar", "reminder": "alarm", "folder": "folder", "app": "iphone",
                                  "web": "magnifyingglass", "weather": "cloud.sun", "computer": "desktopcomputer"]

    static var system: String {
        let name = Locale(identifier: "en").localizedString(forIdentifier: language) ?? "Simplified Chinese"
        return """
        You write four short starter requests for a personal assistant app on the user's iPhone. \
        The assistant can add calendar events and reminders, run timed or daily tasks, read and organize \
        files in folders the user authorized, open and operate apps on the phone, search the web, check \
        the weather, and run tasks on the user's paired computer.
        Make each idea fit the moment you are given (time of day, weekday, month). At most two may lean on \
        the recent conversation titles, and only on an everyday interest such as cooking, travel, sports, \
        reading or learning, named in general words. They show on screen where others may see them, so never \
        mention a person, family member or who something is for, a place name, phone number, address, \
        account, work document, money, bills, health, or relationships. Four different kinds.
        Reply with exactly four lines and nothing else, each as: kind|chip|request
        kind is one of: calendar, reminder, folder, app, web, weather, computer
        chip: a short label of 2 to 5 words (at most 10 characters in Chinese, Japanese or Korean)
        request: the whole request in one sentence, as the user would type it (at most 30 characters in Chinese, Japanese or Korean)
        Write chip and request in \(name). The style, in that language (do not repeat these):
        \(ChatWelcome.examples.prefix(3).map { "\($0.label)|\($0.text)" }.joined(separator: "\n"))
        """
    }

    private static func input(at date: Date = .now) -> String {
        let english = Locale(identifier: "en_US_POSIX")
        let moment = date.formatted(Date.FormatStyle(locale: english).weekday(.wide).month(.wide).hour().minute())
        var lines = ["Now: \(moment)"]
        let since = date.addingTimeInterval(-14 * 86400)
        let topics = ConversationIndex.shared.recent.filter { $0.updated > since }.prefix(8)
            .map { String($0.title.prefix(30)) }.filter { !$0.isEmpty }
        if !topics.isEmpty { lines.append("Recent conversation titles (themes only): " + topics.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    /// Four clean lines, or nil. A set with anything that looks personal is dropped whole.
    static func parse(_ raw: String) -> [Example]? {
        accept(raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
        })
    }

    /// Four clean ideas of different kinds, or nil. Anything that looks personal drops the whole set;
    /// a bare word, a label that only names its kind, or the wrong script drops that one idea.
    static func accept(_ rows: [(kind: String, chip: String, request: String)]) -> [Example]? {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*•`\"「」"))
        let cjk = ["zh", "ja", "ko"].contains(where: language.hasPrefix)
        var list: [Example] = []
        for row in rows {
            let kind = row.kind.trimmingCharacters(in: trim).lowercased()
            let label = row.chip.trimmingCharacters(in: trim), text = row.request.trimmingCharacters(in: trim)
            guard let symbol = symbols[kind] else { continue }
            if personal(label) || personal(text) { return nil }
            let words = text.split(whereSeparator: \.isWhitespace).count
            guard !label.isEmpty, label.count <= 24, text.count <= 90, text.count > label.count,
                  cjk ? text.count >= 6 && label.count >= 4 && hasCJK(label) && hasCJK(text) : words >= 3 && label.split(separator: " ").count >= 2,
                  symbols[label.lowercased()] == nil, !["time", "day", "files", "search", "task"].contains(label.lowercased()),
                  !list.contains(where: { $0.symbol == symbol || $0.label == label }) else { continue }
            list.append(Example(symbol: symbol, label: label, text: text))
        }
        return list.count >= 4 ? Array(list.prefix(4)) : nil
    }

    private static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// Long digit runs (numbers, codes), addresses, links.
    private static func personal(_ text: String) -> Bool {
        text.range(of: #"\d{4,}"#, options: .regularExpression) != nil
            || text.contains("@") || text.lowercased().contains("http") || text.contains("www.")
    }
}
