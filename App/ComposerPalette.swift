import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - What the caret is typing

/// The `/` or `@` token that ends at the caret, on the caret's line. Offsets are UTF-16.
struct PaletteQuery: Equatable {
    enum Kind: Equatable { case command, mention }
    let kind: Kind
    /// From the trigger character to the caret: what a pick replaces.
    let range: NSRange
    /// The text after `/`, `@` or `@"`.
    let query: String
    /// `@"…`: a quoted path the person opened.
    var quoted = false
    /// The `/` is the first thing in the message: host commands can run (they take the whole line).
    var lineCommand = false

    /// A `/` after whitespace or at the start (DSH's skill gesture), or an `@` that does not continue a
    /// word in Latin letters (so `name@example.com` stays text, while `看看@main` asks).
    static func at(_ text: String, caret: Int) -> PaletteQuery? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        let lineStart = ns.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: 0, length: caret)).location
        let start = lineStart == NSNotFound ? 0 : lineStart + 1
        let before = ns.substring(with: NSRange(location: start, length: caret - start))
        let line = before as NSString
        func match(_ pattern: String) -> NSTextCheckingResult? {
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: before, range: NSRange(location: 0, length: line.length))
        }
        if let found = match(#"(?:^|[^A-Za-z0-9_.+\-])(@"([^"\n]*))$"#) ?? match(#"(?:^|[^A-Za-z0-9_.+\-])(@([^\s"\[]*))$"#) {
            let token = found.range(at: 1)
            let quoted = line.substring(with: token).hasPrefix("@\"")
            return PaletteQuery(kind: .mention, range: NSRange(location: start + token.location, length: token.length),
                                query: line.substring(with: found.range(at: 2)), quoted: quoted)
        }
        if let found = match(#"(?:^|\s)(/([^\s/]*))$"#) {
            let token = found.range(at: 1)
            let leading = ns.substring(to: start + token.location)
            return PaletteQuery(kind: .command, range: NSRange(location: start + token.location, length: token.length),
                                query: line.substring(with: found.range(at: 2)),
                                lineCommand: leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return nil
    }
}

// MARK: - Candidates

/// One `/` command the conversation offers: the app's own, the host's (`commands/list`), or a skill.
struct SlashCommand: Equatable {
    enum Source: Equatable { case app, host, skill }
    let name: String
    let label: String
    let description: String
    var source = Source.host
    /// The host declares an input (`input.hint`): picking it waits for the rest of the line.
    var hint: String?

    /// DSH's own commands in Chinese, by `definitionId` (a plugin's same-name command keeps its own copy).
    private static let faces: [String: (name: String, label: String, description: String)] = [
        "@deepseek-ai/dsh-command-compact": ("compact", String(localized: "压缩"), String(localized: "总结前面的内容，让对话能继续")),
        "@deepseek-ai/dsh-permission-presets": ("permission", String(localized: "权限"), String(localized: "切换本对话可以执行的操作")),
        "@deepseek-ai/dsh-plan-mode": ("plan", String(localized: "先列计划"), String(localized: "先出方案，确认后再动手")),
        "@deepseek-ai/dsh-command-goal": ("goal", String(localized: "目标"), String(localized: "设定本对话要达成的目标"))
    ]

    /// Always offered: handled by the app itself.
    static let app: [SlashCommand] = [
        SlashCommand(name: "new", label: String(localized: "新对话"), description: String(localized: "开一个新的对话"), source: .app),
        SlashCommand(name: "model", label: String(localized: "模型"), description: String(localized: "选择模型和思考深度"), source: .app)
    ]

    /// The host's `/export` asks for a browser download.
    private static let hidden: Set<String> = ["export"]
    /// The engine's own /feedback only fed its vendor's log upload, which is switched off.
    private static let hiddenDefinitions: Set<String> = ["@deepseek-ai/dsh-command-feedback"]
    private static let order = ["new", "model", "compact", "permission", "plan", "goal"]

    static func host(_ value: Any?) -> [SlashCommand] {
        (value as? [Object] ?? []).compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty, !hidden.contains(name),
                  !hiddenDefinitions.contains(item["definitionId"] as? String ?? "") else { return nil }
            let input = item["input"] as? Object
            let hint = input.map { $0["hint"] as? String ?? "" }
            if let id = item["definitionId"] as? String, let face = faces[id], face.name == name {
                return SlashCommand(name: name, label: face.label, description: face.description, hint: hint)
            }
            return SlashCommand(name: name, label: name, description: item["description"] as? String ?? "", hint: hint)
        }
    }

    /// App commands, then the host's, then skills; a host command never shadows an app one, a skill neither.
    static func merged(host: [SlashCommand], skills: [SlashCommand]) -> [SlashCommand] {
        let appNames = Set(app.map(\.name)), hostNames = Set(host.map(\.name))
        let all = app + host.filter { !appNames.contains($0.name) } + skills.filter { !appNames.contains($0.name) && !hostNames.contains($0.name) }
        func rank(_ command: SlashCommand) -> Int { order.firstIndex(of: command.name) ?? order.count }
        return all.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.map(\.element)
    }

    /// Name prefix, then title prefix, then substring, then the name's letters in order; ties keep order.
    static func filter(_ all: [SlashCommand], _ token: String) -> [SlashCommand] {
        let query = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        func score(_ command: SlashCommand) -> Int? {
            let name = command.name.lowercased(), label = command.label.lowercased()
            if name.hasPrefix(query) { return 0 }
            if label.hasPrefix(query) { return 1 }
            if name.contains(query) || label.contains(query) { return 2 }
            var rest = Substring(query)
            for character in name where rest.first == character { rest = rest.dropFirst() }
            return rest.isEmpty ? 3 : nil
        }
        var scored: [(score: Int, index: Int, command: SlashCommand)] = []
        for (index, command) in all.enumerated() {
            if let value = score(command) { scored.append((value, index, command)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score < b.score : a.index < b.index }
        return scored.map(\.command)
    }

    /// The command a typed line names exactly (`/compact`, `/压缩 …`).
    static func resolve(_ all: [SlashCommand], line: String) -> (command: SlashCommand, rest: String)? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        guard !name.isEmpty, let command = all.first(where: { $0.name.lowercased() == name || $0.label.lowercased() == name }) else { return nil }
        return (command, String(body.dropFirst(name.count)))
    }
}

/// One row of the palette.
struct PaletteItem: Identifiable, Equatable {
    enum Kind: Equatable { case app, command, skill, file, folder, conversation, subagent }
    let id: String
    let kind: Kind
    let title: String
    var detail: String?
    /// The text that replaces the token.
    let insert: String
    /// A host command without input runs the moment it is picked.
    var runs = false

    var symbol: String {
        switch kind {
        case .app: "sparkles"
        case .command: "command"
        case .skill: "book.closed"
        case .file: "doc.text"
        case .folder: "folder"
        case .conversation: "bubble.left.and.bubble.right"
        case .subagent: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// DSH's file reference grammar: `@path`; whitespace switches to `@"path"`; a quoted folder keeps its
/// quote open after the slash, as the official completion writes it. Nil for paths it cannot carry.
enum MentionText {
    /// Start a reference at the end of a draft, or continue its unfinished reference.
    static func triggerSuffix(after draft: String) -> String {
        if PaletteQuery.at(draft, caret: draft.utf16.count)?.kind == .mention { return "" }
        if let last = draft.last, !last.isWhitespace { return " @" }
        return "@"
    }

    static func file(_ path: String, directory: Bool, keepQuote: Bool = false) -> String? {
        let text = directory ? path + "/" : path
        guard text.range(of: #"[\u0000-\u001f\u007f-\u009f"]"#, options: .regularExpression) == nil else { return nil }
        if !keepQuote && text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return "@" + text }
        return directory ? "@\"" + text : "@\"" + text + "\""
    }

    /// 刚刚 / 5 分钟 / 3 小时 / 2 天 / 4 个月 / 1 年.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "刚刚") }
        if seconds < 3600 { return String(localized: "\(Int(seconds / 60)) 分钟") }
        if seconds < 86400 { return String(localized: "\(Int(seconds / 3600)) 小时") }
        if seconds < 86400 * 30 { return String(localized: "\(Int(seconds / 86400)) 天") }
        if seconds < 86400 * 365 { return String(localized: "\(Int(seconds / 86400 / 30)) 个月") }
        return String(localized: "\(Int(seconds / 86400 / 365)) 年")
    }

    /// Higher is better: prefix > word start > substring > letters in order; nil when they are not all there.
    static func score(_ text: String, _ query: String) -> Double? {
        guard !query.isEmpty else { return 0 }
        let t = text.lowercased(), q = query.lowercased()
        if let found = t.range(of: q) {
            let at = t.distance(from: t.startIndex, to: found.lowerBound)
            if at == 0 { return 1000 - Double(t.count) }
            let previous = t[t.index(before: found.lowerBound)]
            let wordStart = previous.isWhitespace || "/_-.".contains(previous)
            return (wordStart ? 800 : 600) - Double(at) - Double(t.count) / 100
        }
        var index = t.startIndex, gaps = 0
        for character in q {
            guard let next = t[index...].firstIndex(of: character) else { return nil }
            gaps += t.distance(from: index, to: next); index = t.index(after: next)
        }
        return 300 - Double(gaps) - Double(t.count) / 100
    }
}

// MARK: - Editor handle

/// Lets the palette edit the draft's text view directly (outside SwiftUI's update), at the caret.
@MainActor
final class DraftEditorHandle {
    #if os(macOS)
    weak var view: NSTextView?
    var text: String? { view?.string }
    var selection: NSRange? { view?.selectedRange() }
    #else
    weak var view: UITextView?
    var changed: ((UITextView) -> Void)?
    var text: String? { view?.text }
    var selection: NSRange? { view?.selectedRange }
    #endif

    /// Replaces `range` (UTF-16) with `text` and puts the caret after it.
    @discardableResult
    func replace(_ range: NSRange, with text: String) -> Bool {
        guard let view, let draft = self.text else { return false }
        let length = draft.utf16.count
        guard range.location >= 0, range.location <= length,
              range.length >= 0, range.length <= length - range.location else { return false }
        let caret = NSRange(location: range.location + text.utf16.count, length: 0)
        #if os(macOS)
        guard !view.hasMarkedText(), let storage = view.textStorage,
              view.shouldChangeText(in: range, replacementString: text) else { return false }
        storage.replaceCharacters(in: range, with: text)
        view.setSelectedRange(caret)
        view.didChangeText()
        #else
        guard view.markedTextRange == nil,
              let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length),
              let span = view.textRange(from: start, to: end) else { return false }
        view.replace(span, withText: text)
        view.selectedRange = caret
        changed?(view)
        #endif
        return true
    }
}

// MARK: - Palette

/// The `/` and `@` candidates for the draft: commands and skills the conversation actually has, and the
/// files and conversations the host offers for references.
@MainActor
final class ComposerPalette: ObservableObject {
    @Published private(set) var query: PaletteQuery?
    @Published private(set) var sections: [(title: String, items: [PaletteItem])] = []
    @Published private(set) var loading = false
    /// A host command's outcome (「已执行 /compact」…), shown briefly above the composer.
    @Published var toast: (text: String, failed: Bool)?
    let editor = DraftEditorHandle()

    private var session: UUID?
    private var hostCommands: [SlashCommand] = []
    private var skills: [SlashCommand] = []
    private var catalogTask: Task<Void, Never>?
    private var lookup: Task<Void, Never>?
    private var generation = 0
    /// The token the person dismissed (by picking or closing); it stays closed until a new one starts.
    private var dismissed: PaletteQuery?
    private var showingEmptyReferences = false

    var isOpen: Bool { query != nil && (!sections.isEmpty || loading || showingEmptyReferences) }
    var commands: [SlashCommand] { SlashCommand.merged(host: hostCommands, skills: skills) }

    func openReferences(in draft: String, on host: Harness) {
        update(text: draft, caret: draft.utf16.count, host: host, openingReferences: true)
    }

    /// The draft or its caret moved.
    func update(text: String, caret: Int, host: Harness?, openingReferences: Bool = false) {
        if session != nil, session != host?.sessionGeneration { reset() }
        let next = PaletteQuery.at(text, caret: caret)
        if openingReferences { dismissed = nil }
        if let dismissed, let next, next.range.location == dismissed.range.location,
           next.kind == dismissed.kind { return }
        dismissed = nil
        showingEmptyReferences = next?.kind == .mention &&
            (openingReferences || (showingEmptyReferences && next?.range.location == query?.range.location))
        guard next != query || openingReferences else { return }
        let fresh = query == nil || query?.range.location != next?.range.location || query?.kind != next?.kind
        query = next
        guard let next, let host, !host.sessionID.isEmpty else { close(keepDismissal: true); return }
        // A new `/`: read the catalog again (skills and plugin commands come and go); keep what is shown meanwhile.
        load(host, force: fresh && next.kind == .command)
        generation += 1
        let ticket = generation
        lookup?.cancel()
        switch next.kind {
        case .command:
            sections = commandSections(next)
            loading = catalogTask != nil && sections.isEmpty
        case .mention:
            sections = []
            loading = true
            lookup = Task { [weak self] in
                // The first listing goes at once; typing is debounced.
                if next.query.count > 0 { try? await Task.sleep(for: .milliseconds(180)) }
                guard !Task.isCancelled, let self else { return }
                let found = await Self.mentions(next, host: host)
                guard ticket == self.generation, self.session == host.sessionGeneration, !Task.isCancelled else { return }
                self.sections = found
                self.loading = false
            }
        }
    }

    func close(keepDismissal: Bool = false) {
        if !keepDismissal, let query { dismissed = query }
        showingEmptyReferences = false
        query = nil; sections = []; loading = false
        lookup?.cancel(); generation += 1
    }

    func reset() {
        close(keepDismissal: true)
        dismissed = nil
        session = nil
        catalogTask?.cancel()
        catalogTask = nil
        hostCommands = []
        skills = []
        if toast != nil { toast = nil }
    }

    /// Commands and skills of this conversation, read once per conversation (and again after a command ran).
    func load(_ host: Harness, force: Bool = false) {
        let scope = host.sessionGeneration
        guard !host.sessionID.isEmpty, force || session != scope else { return }
        if session != scope { hostCommands = []; skills = [] }
        session = scope
        catalogTask?.cancel()
        let id = host.sessionID
        catalogTask = Task { [weak self] in
            async let listed = try? host.rpcValue("commands/list", args: ["agentId": id])
            async let skillList = try? host.call("skills/list", ["sessionId": id])
            let (commands, skillData) = await (listed, skillList)
            guard let self, self.session == scope, host.sessionGeneration == scope, !Task.isCancelled else { return }
            self.hostCommands = SlashCommand.host(commands)
            let rows = skillData?["skills"] as? [Object] ?? skillData?["items"] as? [Object] ?? []
            self.skills = rows.compactMap { item in
                guard let name = item["name"] as? String, !name.isEmpty, item["userInvocable"] as? Bool != false else { return nil }
                return SlashCommand(name: name, label: name, description: item["description"] as? String ?? "", source: .skill, hint: "")
            }
            self.catalogTask = nil
            if let query = self.query, query.kind == .command {
                self.sections = self.commandSections(query); self.loading = false
            }
        }
    }

    private func commandSections(_ query: PaletteQuery) -> [(title: String, items: [PaletteItem])] {
        // Host commands take the whole line; in the middle of a sentence only skills apply.
        let all = query.lineCommand ? commands : commands.filter { $0.source == .skill }
        let found = SlashCommand.filter(all, query.query)
        func item(_ command: SlashCommand) -> PaletteItem {
            let kind: PaletteItem.Kind = command.source == .app ? .app : command.source == .skill ? .skill : .command
            let title = "/" + command.name + (command.label != command.name ? " · " + command.label : "")
            return PaletteItem(id: "\(kind):" + command.name, kind: kind, title: title,
                               detail: command.description.isEmpty ? nil : command.description, insert: "/" + command.name + " ",
                               runs: command.source == .app || (command.source == .host && command.hint == nil))
        }
        let commandRows = found.filter { $0.source != .skill }.map(item)
        let skillRows = found.filter { $0.source == .skill }.map(item)
        return [(String(localized: "指令"), commandRows), (String(localized: "技能"), skillRows)].filter { !$0.1.isEmpty }
    }

    /// `fileReferences/list` and `sessionReferenceResolver/candidates`, like the official reference menu:
    /// files first, then this conversation's subagents, then other conversations (newest first).
    private static func mentions(_ query: PaletteQuery, host: Harness) async -> [(title: String, items: [PaletteItem])] {
        let id = host.sessionID
        let pathOnly = query.quoted || query.query.contains("/")
        async let fileValue = try? host.rpcValue("fileReferences/list", args: ["agentId": id, "query": query.query])
        async let sessionValue = pathOnly ? nil : try? host.rpcValue("sessionReferenceResolver/candidates", args: ["agentId": id, "query": query.query])
        async let rowList = pathOnly ? nil : try? HostSessionRow.list(host)
        let (fileData, sessionData, rows) = await (fileValue, sessionValue, rowList)
        let files: [PaletteItem] = (fileData as? [Object] ?? []).prefix(30).compactMap { item in
            guard let path = item["path"] as? String, !path.isEmpty else { return nil }
            let directory = item["kind"] as? String == "directory"
            guard let mention = MentionText.file(path, directory: directory, keepQuote: query.quoted) else { return nil }
            let name = (path as NSString).lastPathComponent, parent = (path as NSString).deletingLastPathComponent
            return PaletteItem(id: "f:" + path, kind: directory ? .folder : .file, title: directory ? name + "/" : name,
                               detail: query.query.contains("/") || parent.isEmpty ? nil : parent, insert: directory ? mention : mention + " ")
        }
        let byID = Dictionary((rows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [(PaletteItem, Double, Date)] = [], others: [(PaletteItem, Double, Date)] = []
        for candidate in sessionData as? [Object] ?? [] {
            guard let session = candidate["sessionId"] as? String, session != id,
                  let mention = candidate["mention"] as? String, !mention.isEmpty else { continue }
            let row = byID[session]
            let child = row?.subagent == true && row?.parent == id
            // Other conversations' subagents stay out.
            if row?.subagent == true && !child { continue }
            let title = candidate["displayTitle"] as? String ?? candidate["label"] as? String ?? row?.title ?? session
            let when = row?.updatedDate ?? (candidate["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            let cwd = candidate["cwd"] as? String
            let place = candidate["sameWorkspace"] as? Bool == true || cwd == nil || cwd == byID[id]?.cwd ? nil : (cwd! as NSString).lastPathComponent
            let age = MentionText.age(when)
            let item = PaletteItem(id: "s:" + session, kind: child ? .subagent : .conversation, title: title,
                                   detail: place.map { $0 + " · " + age } ?? age, insert: mention + " ")
            let score = MentionText.score(title, query.query) ?? 100
            if child { children.append((item, score, when)) } else { others.append((item, score, when)) }
        }
        func ranked(_ list: [(PaletteItem, Double, Date)]) -> [PaletteItem] {
            list.sorted { query.query.isEmpty ? $0.2 > $1.2 : ($0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2) }.prefix(12).map(\.0)
        }
        return [(String(localized: "文件"), files), (String(localized: "子任务"), ranked(children)), (String(localized: "对话"), ranked(others))].filter { !$0.1.isEmpty }
    }

    /// A row was picked. Returns the command line to run now (host commands without input).
    func pick(_ item: PaletteItem) -> String? {
        guard let query, let draft = editor.text, let selection = editor.selection,
              selection.length == 0, PaletteQuery.at(draft, caret: selection.location) == query,
              sections.contains(where: { $0.items.contains(item) }) else { return nil }
        if item.runs {
            guard editor.replace(query.range, with: "") else { return nil }
            close()
            return item.insert.trimmingCharacters(in: .whitespaces)
        }
        let ns = draft as NSString
        var text = item.insert
        // Text right after the caret: no double space.
        if text.hasSuffix(" ") {
            let after = NSMaxRange(query.range)
            if after < ns.length, ns.substring(with: NSRange(location: after, length: 1)).rangeOfCharacter(from: .whitespaces) != nil {
                text.removeLast()
            }
        }
        if editor.replace(query.range, with: text), item.kind != .folder { close() }
        return nil
    }

    /// `commands/execute` for a typed or picked host command line; the outcome shows as the toast.
    func run(_ line: String, on host: Harness) async {
        let scope = host.sessionGeneration
        let outcome: (text: String, failed: Bool)
        do {
            let reply = try await host.rpc("commands/execute", args: ["agentId": host.sessionID, "line": line,
                                                                      "submittedAttachments": [] as [Any]])
            let result = reply["result"] as? Object
            let text = (result?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if result?["kind"] as? String == "success" {
                outcome = (String(localized: "已执行 ") + line + (text.isEmpty ? "" : String(localized: "：") + text), false)
            } else {
                outcome = (text.isEmpty ? String(localized: "指令没有执行：") + line : text, true)
            }
        } catch { outcome = (String(localized: "指令没有执行：") + HostError.explain(error), true) }
        guard session == scope, host.sessionGeneration == scope else { return }
        toast = outcome
        load(host, force: true)
    }
}

// MARK: - Views

/// The candidates above the composer: sections of rows; a row replaces the token at the caret.
struct ComposerPaletteView: View {
    @ObservedObject var palette: ComposerPalette
    var selection: String? = nil
    let pick: (PaletteItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(palette.query?.kind == .command ? "指令与技能" : "引用文件或对话")
                    .font(.caption.weight(.semibold)).foregroundStyle(ChatColors.muted)
                Spacer()
                if palette.loading { ProgressView().controlSize(.mini) }
                Button { palette.close() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(ChatColors.muted).accessibilityLabel("关闭候选")
            }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            if palette.sections.isEmpty {
                Text(palette.loading ? "正在读取…" : "没有匹配的项").font(.subheadline).foregroundStyle(ChatColors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                            ForEach(palette.sections.indices, id: \.self) { index in
                                let section = palette.sections[index]
                                if palette.sections.count > 1 {
                                    Text(section.title).font(.caption2.weight(.semibold)).foregroundStyle(ChatColors.tertiary)
                                        .padding(.horizontal, 16).padding(.top, index == 0 ? 2 : 8).padding(.bottom, 2)
                                }
                                ForEach(section.items) { item in row(item).id(item.id) }
                            }
                        }.padding(.bottom, 6)
                    }
                    .onChange(of: selection) { _, id in if let id { scroll.scrollTo(id) } }
                }
                .frame(height: min(248, listHeight))
            }
        }
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composerPalette")
    }

    /// Rows are 44 (48 with a detail line); section titles 22.
    private var listHeight: CGFloat {
        #if os(macOS)
        let rows = palette.sections.flatMap(\.items).count * 44
        #else
        let rows = palette.sections.flatMap(\.items).reduce(0) { $0 + ($1.detail == nil ? 44 : 48) }
        #endif
        return CGFloat(rows + (palette.sections.count > 1 ? palette.sections.count * 22 : 0) + 6)
    }

    private func row(_ item: PaletteItem) -> some View {
        Button { pick(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 14)).foregroundStyle(ChatColors.muted).frame(width: 22)
                #if os(macOS)
                Text(verbatim: item.title).font(.subheadline.weight(.medium)).foregroundStyle(ChatColors.ink).lineLimit(1)
                #else
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.title).font(.subheadline.weight(.medium)).foregroundStyle(ChatColors.ink).lineLimit(1)
                    if let detail = item.detail {
                        Text(verbatim: detail).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                #endif
                Spacer(minLength: 0)
                #if os(macOS)
                if let detail = item.detail, item.kind == .file || item.kind == .folder {
                    Text(verbatim: detail).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1).truncationMode(.middle)
                }
                #endif
                if item.runs { Image(systemName: "return").font(.caption).foregroundStyle(ChatColors.tertiary) }
            }.padding(.horizontal, 16).frame(minHeight: 44).contentShape(Rectangle())
                .background(selection == item.id ? Color.accentColor.opacity(0.15) : .clear)
        }.buttonStyle(.plain)
            .accessibilityLabel(item.title + (item.detail.map { String(localized: "，") + $0 } ?? ""))
            .accessibilityHint(item.runs ? "立即执行" : "插入到光标处")
            .accessibilityAddTraits(selection == item.id ? .isSelected : [])
    }
}

/// A command's outcome, a moment above the composer.
struct PaletteToast: View {
    @ObservedObject var palette: ComposerPalette
    var body: some View {
        if let toast = palette.toast {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: toast.failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(toast.failed ? Color.orange : Color.green)
                Text(verbatim: toast.text).font(.callout).foregroundStyle(ChatColors.ink).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).chatCard().padding(.horizontal, 12).padding(.bottom, 6)
            .onTapGesture { palette.toast = nil }
            .task(id: toast.text) {
                try? await Task.sleep(for: .seconds(4))
                if palette.toast?.text == toast.text { palette.toast = nil }
            }
            .accessibilityIdentifier("commandToast")
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }
}
