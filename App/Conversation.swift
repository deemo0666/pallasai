import Combine
import SwiftUI

/// One end-of-turn or retry notice shown in the stream.
struct TurnNotice: Equatable {
    /// `aborted`, `error`, `max-tokens`, `blocked`, `interrupted`, `retry`, `late`.
    let kind: String
    var code: String?
    var message: String?
    var retry: Int?
    var maxRetries: Int?

    static func turnEnd(_ data: Object) -> TurnNotice? {
        guard let reason = data["reason"] as? Object, let kind = reason["kind"] as? String else { return nil }
        switch kind {
        case "aborted", "max-tokens", "blocked", "interrupted": return TurnNotice(kind: kind)
        case "error":
            let error = reason["error"] as? Object
            return TurnNotice(kind: kind, code: error?["code"] as? String, message: (error?["message"] as? String).map { ShareText.redacted($0.hostLocalized) })
        default: return nil
        }
    }

    /// An 自动化任务 delivered a minute or more after its time (the app was not running then):
    /// 「原定 今天 20:51，晚了 7 分钟」. The engine's message carries the run time as `occurrence_at`.
    static func late(_ data: Object, deliveredAt: Date?) -> TurnNotice? {
        guard (data["source"] as? Object)?["kind"] as? String == "schedule", let deliveredAt,
              let text = (data["content"] as? [Object])?.compactMap({ $0["text"] as? String }).joined(separator: "\n"),
              let pattern = try? NSRegularExpression(pattern: #"occurrence_at\\?"?:\s*\\?"?([0-9T:.+\-Z]+)"#) else { return nil }
        let times = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { ScheduleText.parseDate(String(text[$0])) }
        }
        guard let planned = times.min() else { return nil }
        let minutes = Int(deliveredAt.timeIntervalSince(planned) / 60)
        guard minutes >= 1 else { return nil }
        let span = minutes < 60 ? String(localized: "\(minutes) 分钟") : String(localized: "\(minutes / 60) 小时 \(minutes % 60) 分钟")
        return TurnNotice(kind: "late", message: String(localized: "原定 \(ScheduleText.when(planned, now: deliveredAt))，晚了 \(span)"))
    }
}

/// One item of the session's current todo list.
struct TodoItem: Identifiable, Equatable {
    let id: String
    let text: String
    /// `pending`, `in_progress` or `completed`.
    let status: String

    static func list(_ value: Any?) -> [TodoItem]? {
        guard let items = value as? [Object] else { return nil }
        return items.enumerated().compactMap { index, item in
            guard let text = item["content"] as? String else { return nil }
            let status = item["status"] as? String ?? "pending"
            return TodoItem(id: "\(index):" + text, text: text, status: ["pending", "in_progress", "completed"].contains(status) ? status : "pending")
        }
    }
}

/// Context-window use of the open session (`contextPressure` projection).
struct ContextMeter: Equatable {
    let used: Int
    let window: Int

    init(used: Int, window: Int) { self.used = used; self.window = window }

    init?(_ value: Any?) {
        guard let value = value as? Object, let window = value["contextWindow"] as? Int, window > 0 else { return nil }
        self.init(used: value["pressureTokens"] as? Int ?? 0, window: window)
    }

    var fraction: Double { min(1, max(0, Double(used) / Double(window))) }
}

struct Message: Identifiable {
    /// A call ended by a stop (`ABORTED`) or by the engine going away mid-call (outcome unknown) was not a failure of the tool.
    static func stoppedTool(_ data: Object) -> Bool {
        let code = (data["error"] as? Object)?["code"] as? String
        return code == "ABORTED" || code == "TOOL_OUTCOME_UNKNOWN"
    }

    var id = UUID()
    let outgoing: Bool
    var text: String
    var sequence: Int?
    var turn: Int?
    var requestID: UUID?
    var prompt: String?
    var hasAttachment = false
    var thinking = ""
    var images: [HostImage] = []
    var tool: ChatStep?
    var time: Date?
    var step: Int?
    /// Explicit final answer (pi-ai v2 `final_answer` text signature).
    var finalAnswer = false
    /// The reply was cut off by a stop.
    var interrupted = false
    var notice: TurnNotice?
    /// Names of files attached to a user message.
    var files: [String] = []
    /// What was picked on this phone, shown until the host echoes the message (and given back by 编辑后重发).
    var drafts: [DraftAttachment] = []
    /// Sent with `mode: steer` and not yet echoed by the host.
    var steering = false
    /// A steer the host did not accept: kept on screen (「未送达 · 已保留」) until edited and resent.
    var failed = false
    /// The host's `message.id` of a saved reply (plugin message actions name it).
    var hostID: String?

    static func eventTime(_ event: Object) -> Date? {
        if let ms = event["time"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = event["time"] as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return nil
    }

    static func toolRecord(_ event: Object) -> Message? {
        guard let data = event["data"] as? Object, let seq = event["seq"] as? Int,
              let turn = data["turn"] as? Int, let step = data["step"] as? Int else { return nil }
        let record: ChatStep
        switch event["type"] as? String {
        case "tool/call":
            guard let id = data["callId"] as? String, let name = data["name"] as? String else { return nil }
            record = ChatStep(id: "\(turn)/\(step)/" + id, name: name,
                              arguments: ShareText.redacted(Bounded.arguments(data["arguments"] as? String ?? "")), result: "", state: "running")
        case "tool/result":
            let message = data["message"] as? Object ?? data
            guard let id = message["toolCallId"] as? String ?? data["callId"] as? String else { return nil }
            var lines = (message["content"] as? [Object] ?? []).compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                return block["type"] as? String == "image" ? String(localized: "图片结果") : nil
            }
            let images = HostImage.references(message["content"] as? [Object] ?? [])
            let failed = message["isError"] as? Bool == true
            if failed, let error = data["error"] as? Object, let reason = error["reason"] as? String ?? error["code"] as? String,
               !lines.contains(reason) { lines.append(reason) }
            let meta = data["meta"] as? Object
            let files = (meta?["diffs"] as? [Object])?.compactMap(ToolFileChange.init)
            record = ChatStep(id: "\(turn)/\(step)/" + id, name: data["name"] as? String ?? id, arguments: "",
                              result: ShareText.redacted(Bounded.text(lines.joined(separator: "\n"))), state: failed ? (Self.stoppedTool(data) ? "cancelled" : "error") : "ok", files: files, images: images.isEmpty ? nil : images)
        default: return nil
        }
        return Message(outgoing: false, text: "", sequence: seq, turn: turn, tool: record, time: eventTime(event), step: step)
    }

    mutating func mergeTool(_ other: Message) {
        guard var record = tool, let incoming = other.tool, record.id == incoming.id else { return }
        if incoming.state == "running" {
            record.name = incoming.name; record.arguments = incoming.arguments
        } else {
            record.state = incoming.state; record.result = incoming.result; record.files = incoming.files; record.images = incoming.images
        }
        tool = record
        if let seq = other.sequence {
            if sequence.map({ seq < $0 }) ?? true { time = other.time ?? time }
            sequence = min(sequence ?? seq, seq)
        }
    }

    static func notice(_ event: Object) -> Message? {
        guard let data = event["data"] as? Object, let seq = event["seq"] as? Int else { return nil }
        let notice: TurnNotice
        switch event["type"] as? String {
        case "turn/end":
            guard let value = TurnNotice.turnEnd(data) else { return nil }
            notice = value
        case "user/message":
            guard let value = TurnNotice.late(data, deliveredAt: eventTime(event)) else { return nil }
            notice = value
        case "llm/retry":
            let failure = data["failure"] as? Object
            notice = TurnNotice(kind: "retry", code: failure?["code"] as? String, message: (failure?["message"] as? String).map(ShareText.redacted),
                                retry: data["retry"] as? Int, maxRetries: data["maxRetries"] as? Int)
        default: return nil
        }
        return Message(outgoing: false, text: "", sequence: seq, turn: data["turn"] as? Int, time: eventTime(event), notice: notice)
    }

    /// pi-ai v2 replay blocks mark a text block as the turn's final answer.
    private static func isFinalAnswer(_ message: Object, blocks: [Object]) -> Bool {
        guard let source = message["source"] as? Object, source["kind"] as? String == "model",
              let replay = source["replayState"] as? Object, let response = replay["response"] as? Object,
              response["kind"] as? String == "pi-ai", response["version"] as? Int == 2,
              let marks = replay["blocks"] as? [Object], marks.count == blocks.count else { return false }
        for (block, mark) in zip(blocks, marks) {
            guard block["type"] as? String == "text", let text = block["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, mark["type"] as? String == "text",
                  let signature = mark["textSignature"] as? String,
                  let meta = try? JSONSerialization.jsonObject(with: Data(signature.utf8)) as? Object else { continue }
            if meta["v"] as? Int == 1, meta["phase"] as? String == "final_answer", (meta["id"] as? String)?.isEmpty == false { return true }
        }
        return false
    }

    static func assistant(_ event: Object) -> Message? {
        guard event["type"] as? String == "assistant/message",
              let data = event["data"] as? Object, let message = data["message"] as? Object,
              let blocks = message["content"] as? [Object] else { return nil }
        func content(_ type: String) -> String {
            blocks.filter { $0["type"] as? String == type }.compactMap { $0["text"] as? String }.joined()
        }
        let text = content("text"), thinking = content("reasoning")
        let images = HostImage.references(blocks)
        guard !text.isEmpty || !thinking.isEmpty || !images.isEmpty else { return nil }
        var reply = Message(outgoing: false, text: text, sequence: event["seq"] as? Int, turn: data["turn"] as? Int, thinking: thinking, images: images,
                       time: eventTime(event), step: data["step"] as? Int, finalAnswer: isFinalAnswer(message, blocks: blocks),
                       interrupted: data["interrupted"] as? Bool == true)
        reply.hostID = message["id"] as? String
        return reply
    }

    static func user(_ event: Object) -> Message? {
        guard event["type"] as? String == "user/message", let data = event["data"] as? Object,
              let source = data["source"] as? Object, let kind = source["kind"] as? String,
              ["user", "user-rpc"].contains(kind), let blocks = data["content"] as? [Object] else { return nil }
        let texts = blocks.compactMap { $0["text"] as? String }
        let paths = texts.reversed().prefix { $0.hasPrefix("工作区文件：./") }.count
        let path = paths > 0
        let prompt = (path && texts.count > paths ? Array(texts.dropLast(paths)) : texts).joined()
        let attachment = path || blocks.contains { $0["type"] as? String != "text" }
        guard attachment || !prompt.isEmpty else { return nil }
        var files = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "file" else { return nil }
            return (block["attachment"] as? Object)?["name"] as? String ?? block["name"] as? String ?? String(localized: "文件")
        }
        for line in texts.suffix(paths) { files.append((String(line.dropFirst("工作区文件：".count)) as NSString).lastPathComponent) }
        return Message(outgoing: true, text: texts.isEmpty ? String(localized: "附件") : texts.joined(), sequence: event["seq"] as? Int,
                       requestID: (source["rpcId"] as? String).flatMap(UUID.init(uuidString:)), prompt: path ? prompt : texts.joined(),
                       hasAttachment: attachment, images: HostImage.references(blocks), time: eventTime(event), files: files)
    }

    /// What the user bubble shows: the prompt without the attached file's path line.
    var bubbleText: String { outgoing ? (prompt ?? text) : text }
}

// MARK: - Turn traces

/// Token use summed over model requests.
struct TraceUsage: Equatable {
    var uncached = 0, cacheRead = 0, cacheWrite = 0, output = 0, reasoning = 0, requests = 0
    var input: Int { uncached + cacheRead + cacheWrite }
    var total: Int { input + output }
    var isEmpty: Bool { requests == 0 }
    var cacheHitRate: Double? { input == 0 ? nil : Double(cacheRead) / Double(input) }

    init() {}
    init?(_ value: Any?) {
        guard let usage = value as? Object else { return nil }
        uncached = usage["inputTokens"] as? Int ?? 0
        output = usage["outputTokens"] as? Int ?? 0
        cacheRead = usage["cacheReadTokens"] as? Int ?? 0
        cacheWrite = usage["cacheWriteTokens"] as? Int ?? 0
        reasoning = usage["reasoningTokens"] as? Int ?? 0
        requests = 1
    }

    static func + (a: TraceUsage, b: TraceUsage) -> TraceUsage {
        var sum = a
        sum.uncached += b.uncached; sum.cacheRead += b.cacheRead; sum.cacheWrite += b.cacheWrite
        sum.output += b.output; sum.reasoning += b.reasoning; sum.requests += b.requests
        return sum
    }
}

/// One timed span of a turn (model request, tool call, approval wait, question).
struct TraceSpan: Identifiable {
    enum Kind { case model, tool, approval, question }
    let kind: Kind
    let step: Int
    /// `assistant/message` / `tool/call` / `approval/asked` seq; -1 for a model request in flight.
    let seq: Int
    let start: Date
    var end: Date?
    var cutShort = false
    var usage: TraceUsage?
    var model: String?
    var hasText = false
    var hasReasoning = false
    var toolCalls = 0
    var interrupted = false
    var callID: String?
    var toolName: String?
    var arguments: String?
    var failed = false
    var outcome: String?
    /// First streamed token of a model request (the host's chunk times).
    var firstToken: Date?
    var provider: String?

    var id: String { "\(kind)-\(seq)-\(callID ?? "")-\(start.timeIntervalSince1970)" }
    var open: Bool { end == nil }
    var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
    var waiting: Bool { kind == .approval || kind == .question }
}

/// One turn (`turn/start` … `turn/end`) folded into timed spans.
struct TurnTrace: Identifiable {
    let turn: Int
    let startSeq: Int
    let start: Date
    var endSeq: Int?
    var end: Date?
    /// `completed`, `aborted`, `error`, `max-tokens`, `blocked`, `interrupted`, `forked`.
    var reason: String?
    var spans: [TraceSpan]

    var id: Int { startSeq }
    var running: Bool { end == nil }
    var completed: Bool { reason == "completed" }
    var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
    var steps: Int { spans.filter { $0.kind == .model && $0.seq >= 0 }.count }
    var usage: TraceUsage { spans.compactMap(\.usage).reduce(TraceUsage(), +) }
    func time(_ test: (TraceSpan) -> Bool) -> TimeInterval {
        spans.filter { test($0) && !$0.open }.compactMap(\.duration).reduce(0, +)
    }
    var modelTime: TimeInterval { time { $0.kind == .model } }
    var toolTime: TimeInterval { time { $0.kind == .tool } }
    var waitTime: TimeInterval { time { $0.waiting } }

    func contains(_ seq: Int) -> Bool { seq >= startSeq && (endSeq.map { seq <= $0 } ?? true) }
}

/// The parts of a durable event a turn trace needs (full messages are not kept).
private struct TraceEvent {
    let seq: Int
    let time: Date
    let type: String
    var turn: Int?
    var step: Int?
    var callID: String?
    var name: String?
    var arguments: String?
    var usage: TraceUsage?
    var model: String?
    var hasText = false, hasReasoning = false, toolCalls = 0, interrupted = false, failed = false
    var reason: String?
    var approvalID: String?
    var outcome: String?
    var firstToken: Date?
    var provider: String?

    static let kinds: Set<String> = ["turn/start", "turn/end", "step/start", "step/end", "assistant/message", "assistant/attempt", "tool/call",
                                     "tool/result", "approval/asked", "approval/decided", "user/message"]

    init?(_ event: Object) {
        guard let type = event["type"] as? String, Self.kinds.contains(type), let seq = event["seq"] as? Int,
              let time = Message.eventTime(event) else { return nil }
        let data = event["data"] as? Object ?? [:]
        self.seq = seq; self.time = time; self.type = type
        turn = data["turn"] as? Int; step = data["step"] as? Int
        func filled(_ block: Object, _ kind: String) -> Bool {
            block["type"] as? String == kind && !((block["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch type {
        case "turn/end": reason = (data["reason"] as? Object)?["kind"] as? String ?? "unknown"
        case "assistant/message":
            let message = data["message"] as? Object
            let blocks = message?["content"] as? [Object] ?? []
            usage = TraceUsage(data["usage"])
            model = (message?["source"] as? Object)?["model"] as? String
            provider = (message?["source"] as? Object)?["provider"] as? String
            firstToken = StreamTiming.bounds(data["stream"]).first
            hasText = blocks.contains { filled($0, "text") }
            hasReasoning = blocks.contains { filled($0, "reasoning") }
            toolCalls = blocks.filter { $0["type"] as? String == "tool-call" }.count
            interrupted = data["interrupted"] as? Bool == true
        case "assistant/attempt": firstToken = StreamTiming.bounds(data["stream"]).first
        case "tool/call":
            callID = data["callId"] as? String; name = data["name"] as? String
            arguments = ShareText.redacted(data["arguments"] as? String ?? "")
        case "tool/result":
            let message = data["message"] as? Object ?? data
            callID = message["toolCallId"] as? String ?? data["callId"] as? String
            failed = message["isError"] as? Bool == true
        case "approval/asked":
            approvalID = data["id"] as? String; callID = data["callId"] as? String; name = data["toolName"] as? String
        case "approval/decided":
            approvalID = data["id"] as? String; outcome = data["outcome"] as? String
        default: break
        }
    }

    static func traces(_ log: [TraceEvent]) -> [TurnTrace] {
        var out: [TurnTrace] = []
        var tracer: Tracer?
        for event in log {
            if event.type == "turn/start" {
                if let open = tracer { out.append(open.finish(nil, time: open.lastSeen)) }
                tracer = Tracer(turn: event.turn ?? 0, startSeq: event.seq, start: event.time)
                continue
            }
            guard var current = tracer else { continue }
            if event.type == "turn/end" {
                out.append(current.finish(event, time: event.time))
                tracer = nil
                continue
            }
            current.apply(event)
            tracer = current
        }
        if let tracer { out.append(tracer.running()) }
        return out
    }

    private struct Tracer {
        struct OpenTool { let call: TraceEvent; var start: Date; var outcome: String?; var waiting = false }
        let turn: Int, startSeq: Int, start: Date
        var boundary: Date, lastSeen: Date
        var lastStep = 0
        var spans: [TraceSpan] = []
        var stepStarts: [Int: Date] = [:]
        /// Failed attempts of a step streamed too: its first token is the earliest of them all.
        var attemptFirst: [Int: Date] = [:]
        var tools: [String: OpenTool] = [:]
        var approvals: [String: TraceEvent] = [:]

        init(turn: Int, startSeq: Int, start: Date) {
            self.turn = turn; self.startSeq = startSeq; self.start = start; boundary = start; lastSeen = start
        }

        mutating func apply(_ event: TraceEvent) {
            if event.time > lastSeen { lastSeen = event.time }
            switch event.type {
            case "step/start":
                if let step = event.step { stepStarts[step] = event.time; lastStep = max(lastStep, step) }
            case "assistant/attempt":
                if let step = event.step, let first = event.firstToken, attemptFirst[step].map({ first < $0 }) ?? true { attemptFirst[step] = first }
            case "assistant/message":
                let step = event.step ?? lastStep
                lastStep = max(lastStep, step)
                let first = [event.firstToken, attemptFirst.removeValue(forKey: step)].compactMap { $0 }.min()
                spans.append(TraceSpan(kind: .model, step: step, seq: event.seq, start: stepStarts.removeValue(forKey: step) ?? boundary, end: event.time,
                                       usage: event.usage, model: event.model, hasText: event.hasText, hasReasoning: event.hasReasoning,
                                       toolCalls: event.toolCalls, interrupted: event.interrupted, firstToken: first, provider: event.provider))
                boundary = event.time
            case "tool/call":
                if let id = event.callID { tools[id] = OpenTool(call: event, start: event.time) }
            case "approval/asked":
                if let id = event.approvalID { approvals[id] = event }
                if let call = event.callID { tools[call]?.waiting = true }
            case "approval/decided":
                guard let id = event.approvalID, let asked = approvals.removeValue(forKey: id) else { break }
                spans.append(approvalSpan(asked, end: event.time, outcome: event.outcome))
                if let call = asked.callID, tools[call] != nil {
                    tools[call]?.start = event.time; tools[call]?.outcome = event.outcome; tools[call]?.waiting = false
                }
            case "tool/result":
                guard let id = event.callID, let tool = tools.removeValue(forKey: id) else { break }
                for (key, asked) in approvals where asked.callID == id {
                    spans.append(approvalSpan(asked, end: event.time, cutShort: true)); approvals.removeValue(forKey: key)
                }
                spans.append(toolSpan(tool, end: event.time, failed: event.failed))
                boundary = event.time
            case "step/end", "user/message":
                if event.time > boundary { boundary = event.time }
            default: break
            }
        }

        func approvalSpan(_ asked: TraceEvent, end: Date?, outcome: String? = nil, cutShort: Bool = false) -> TraceSpan {
            let tool = asked.callID.flatMap { tools[$0] }
            return TraceSpan(kind: .approval, step: tool?.call.step ?? lastStep, seq: asked.seq, start: asked.time, end: end, cutShort: cutShort,
                             callID: asked.callID, toolName: asked.name, arguments: tool?.call.arguments, outcome: outcome)
        }

        func toolSpan(_ tool: OpenTool, end: Date?, failed: Bool = false, cutShort: Bool = false) -> TraceSpan {
            TraceSpan(kind: tool.call.name == "ask_user_question" ? .question : .tool, step: tool.call.step ?? lastStep, seq: tool.call.seq,
                      start: tool.start, end: end, cutShort: cutShort, callID: tool.call.callID, toolName: tool.call.name,
                      arguments: tool.call.arguments, failed: failed, outcome: tool.outcome)
        }

        static func ordered(_ spans: [TraceSpan]) -> [TraceSpan] {
            spans.sorted { $0.start != $1.start ? $0.start < $1.start : $0.seq < $1.seq }
        }

        func finish(_ event: TraceEvent?, time: Date) -> TurnTrace {
            var all = spans
            all += approvals.values.map { approvalSpan($0, end: time, cutShort: true) }
            all += tools.values.filter { !$0.waiting }.map { toolSpan($0, end: time, cutShort: true) }
            all += stepStarts.map { TraceSpan(kind: .model, step: $0.key, seq: -1, start: $0.value, end: time, cutShort: true) }
            return TurnTrace(turn: turn, startSeq: startSeq, start: start, endSeq: event?.seq, end: time,
                             reason: event?.reason ?? "interrupted", spans: Self.ordered(all))
        }

        func running() -> TurnTrace {
            var open = approvals.values.map { approvalSpan($0, end: nil) }
            open += tools.values.filter { !$0.waiting }.map { toolSpan($0, end: nil) }
            if !stepStarts.isEmpty {
                open += stepStarts.map { TraceSpan(kind: .model, step: $0.key, seq: -1, start: $0.value) }
            } else if open.isEmpty {
                open.append(TraceSpan(kind: .model, step: lastStep + 1, seq: -1, start: boundary))
            }
            return TurnTrace(turn: turn, startSeq: startSeq, start: start, spans: Self.ordered(spans + open))
        }
    }
}

/// Status of one tool call as the stream shows it.
enum ToolStatus: Equatable {
    case running, awaitingApproval, succeeded, failed, denied, cancelled
    var active: Bool { self == .running || self == .awaitingApproval }
}

@MainActor
final class Conversation: ObservableObject {
    struct CompletedTurn {
        let session: String
        let title: String
        let requests: Set<UUID>
        let reply: String
        let notice: TurnNotice?
        var sequence: Int? = nil
    }

    let completedTurns = PassthroughSubject<CompletedTurn, Never>()
    private var turnRequests: Set<UUID> = []
    private(set) var turnStartSequence: Int?
    enum Phase { case offline, connecting, ready, replying }

    @Published private(set) var phase = Phase.offline
    @Published private(set) var messages: [Message] = []
    @Published private(set) var deliverables: [HostDeliverable] = []
    /// The open session's latest todo list (`todo/write`, `todos` projection); cleared by `turn/start`.
    @Published private(set) var todos: [TodoItem] = []
    /// Context-window use of the open session, once the host knows the window.
    @Published private(set) var contextMeter: ContextMeter? = nil
    @Published private(set) var sessionModes = SessionModes()
    /// Every loaded turn, oldest first.
    @Published private(set) var traces: [TurnTrace] = []
    /// `approval/decided` outcome by tool call id.
    @Published private(set) var approvalOutcomes: [String: String] = [:]
    /// 「本对话都允许」: approvals of this conversation are answered `allowed-once` on arrival.
    @Published private(set) var autoApprove = false
    /// Brief confirmation after a fork (「已在新对话中继续」…); the stream offers 「返回原对话」 beside it.
    @Published private(set) var forkToast: String?

    private var fileEvents: [HostDeliverable.ID: HostDeliverable] = [:]
    private var finishedTurns = Set<Int>()
    private var traceLog: [Int: TraceEvent] = [:]
    private var approvalCalls: [String: String] = [:]
    private var todoSeedSeq = -1
    private var todoEvents = false
    private var projectionWatch: HarnessChannel?
    private var projectionTask: Task<Void, Never>?
    private var modesRead = UUID()

    private func collectFiles(_ events: [Object], historyChanged: Bool = false) {
        var changed = historyChanged
        for event in events {
            if event["type"] as? String == "turn/end", let turn = (event["data"] as? Object)?["turn"] as? Int {
                if finishedTurns.insert(turn).inserted, fileEvents.values.contains(where: { $0.turn == turn }) { changed = true }
            }
            for item in HostDeliverable.files(in: event) where fileEvents[item.id] != item {
                fileEvents[item.id] = item; changed = true
            }
        }
        guard changed, !fileEvents.isEmpty else { return }
        deliverables = HostDeliverable.visible(Array(fileEvents.values), finishedTurns: finishedTurns, workspace: workspace, steps: messages.compactMap(\.tool))
    }

    /// Folds trace-relevant events (and approval outcomes); returns whether the traces need rebuilding.
    @discardableResult
    private func recordTrace(_ event: Object) -> Bool {
        guard let entry = TraceEvent(event) else { return false }
        switch entry.type {
        case "approval/asked":
            if let id = entry.approvalID, let call = entry.callID { approvalCalls[id] = call }
        case "approval/decided":
            if let id = entry.approvalID, let call = approvalCalls[id], let outcome = entry.outcome { approvalOutcomes[call] = outcome }
        default: break
        }
        guard traceLog[entry.seq] == nil else { return false }
        traceLog[entry.seq] = entry
        return true
    }

    /// Durable events folded into turn traces, as the conversation does (tests).
    static func traces(_ events: [Object]) -> [TurnTrace] { TraceEvent.traces(events.compactMap(TraceEvent.init).sorted { $0.seq < $1.seq }) }

    private func rebuildTraces() {
        traces = TraceEvent.traces(traceLog.values.sorted { $0.seq < $1.seq })
    }

    /// The tool call id inside a `ChatStep.id` (`turn/step/callId`).
    static func callID(of step: ChatStep) -> String {
        let parts = step.id.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 ? String(parts[2]) : step.id
    }

    /// A pending `approval/request` interaction for this tool call.
    func pendingApproval(for step: ChatStep) -> Object? {
        let call = Self.callID(of: step)
        return interactions.first { item in
            item["event"] as? String == "approval/request" && (item["request"] as? Object)?["callId"] as? String == call
        }
    }

    /// Whether the turn has a `turn/end` in the loaded history.
    func turnEnded(_ turn: Int?) -> Bool { turn.map(finishedTurns.contains) ?? false }

    func toolStatus(_ step: ChatStep, turn: Int?) -> ToolStatus {
        switch step.state {
        case "ok", "error":
            if let outcome = approvalOutcomes[Self.callID(of: step)], outcome != "allowed-once" { return .denied }
            return step.state == "ok" ? .succeeded : .failed
        case "denied": return .denied
        case "cancelled": return .cancelled
        default:
            if pendingApproval(for: step) != nil { return .awaitingApproval }
            if turnEnded(turn) || phase == .offline { return .cancelled }
            return .running
        }
    }

    @Published var notice: String?
    /// A file the composer attaches next (the transcript a replay continues from).
    @Published var pendingAttachment: URL?
    /// The composer's attachments, in order (the tray above the text).
    @Published var attachments: [DraftAttachment] = []
    private(set) var connection: Harness?
    private var login: (address: String, token: String)?
    @Published private(set) var title = "Pallas Agent"
    @Published private(set) var needsModelSetup: Bool?
    @Published private(set) var modelCatalog: HostModelCatalog?
    private var channelSync: (task: Task<Void, Error>, refreshesModels: Bool)?
    private var catalogRead = 0
    private var appliedCatalogRead = 0
    private var followsDefaultModel = true
    @Published private(set) var modelName = ""
    @Published private(set) var modelProvider = ""
    @Published private(set) var modelEffort: String?
    /// The catalog's names (`provider/model` → `DeepSeek-V4.1-Flash`) on this connection.
    @Published private(set) var modelNames: [String: String] = [:]
    /// What the composer pill shows: the catalog's name when known, as DSH's does.
    var modelLabel: String { needsModelSetup == true ? "" : (modelNames[modelProvider + "/" + modelName] ?? modelName) }

    private func applyModel(_ selection: Object?, isDefault: Bool = false) {
        followsDefaultModel = isDefault || selection == nil
        modelName = selection?["model"] as? String ?? ""
        modelProvider = selection?["provider"] as? String ?? ""
        modelEffort = selection?["reasoningEffort"] as? String
    }

    private func readModelCatalog(on host: Harness) async throws {
        guard connection === host else { throw CancellationError() }
        catalogRead += 1
        let read = catalogRead
        let data = try await host.rpc("session/modelCatalog", args: [:])
        try Task.checkCancellation()
        guard connection === host else { throw CancellationError() }
        guard read > appliedCatalogRead else { return }
        appliedCatalogRead = read
        let catalog = HostModelCatalog(data)
        modelCatalog = catalog
        needsModelSetup = catalog.channels.allSatisfy { $0.models.isEmpty }
        modelNames = Dictionary(catalog.channels.flatMap(\.models).map { ($0.channel + "/" + $0.model, $0.name) },
                                uniquingKeysWith: { first, _ in first })
        guard followsDefaultModel, messages.isEmpty, let fallback = catalog.fallback,
              catalog.channels.flatMap(\.models).contains(where: { $0.channel == fallback.channel && $0.model == fallback.model }) else { return }
        applyModel(data["default"] as? Object, isDefault: true)
    }

    func refreshModelCatalog(on host: Harness) async {
        try? await readModelCatalog(on: host)
    }

    /// The local routes write the same settings revision. Finish an earlier sync before
    /// applying the current credentials and model lists, including changes saved mid-refresh.
    func syncModelChannels(on host: Harness, refreshModels: Bool = false) async throws {
        guard host.usesEmbeddedEngine, connection === host else { return }
        if refreshModels, let current = channelSync, current.refreshesModels {
            try await current.task.value
            return
        }
        let previous = channelSync?.task
        let task = Task {
            _ = await previous?.result
            guard connection === host, !Task.isCancelled else { throw CancellationError() }
            var accountError: Error?
            do { try await ChatGPTChannel.sync(to: host, refreshModels: refreshModels) }
            catch { accountError = error }
            guard connection === host, !Task.isCancelled else { throw CancellationError() }
            try await ThirdPartyChannel.sync(ThirdPartyProviders.load(), to: host, refreshModels: refreshModels)
            if let accountError { throw accountError }
        }
        channelSync = (task, refreshModels)
        defer { if channelSync?.task == task { channelSync = nil } }
        try await task.value
    }

    /// Reload what can actually be selected. A connected computer owns its own catalog.
    func reloadAvailableModels(on host: Harness) async throws {
        if host.usesEmbeddedEngine {
            if modelCatalog == nil { await refreshModelCatalog(on: host) }
            do { try await syncModelChannels(on: host, refreshModels: true) }
            catch {
                // Another provider may have updated successfully.
                await refreshModelCatalog(on: host)
                throw error
            }
        }
        try await readModelCatalog(on: host)
    }

    /// Only an explicit save or an unusable default may change the host default.
    /// The persisted request survives offline saves and partial failures.
    func applyPendingModelActivation(on host: Harness) async throws {
        guard let request = ThirdPartyProviders.pendingActivation else {
            // Repair the old first-provider setup only when there is one unambiguous candidate
            // and the host's existing default is absent from its usable catalog.
            let providers = ThirdPartyProviders.configured()
            if providers.count == 1, let provider = providers.first {
                try await activateConfiguredModel(on: host, provider: provider.id, model: provider.model, explicit: false)
            }
            return
        }
        guard ThirdPartyProviders.configured().contains(request.provider) else {
            ThirdPartyProviders.finishActivation(request); return
        }
        try await activateConfiguredModel(on: host, provider: request.provider.id,
                                          model: request.provider.model, explicit: request.explicit)
        guard connection === host, !Task.isCancelled else { return }
        ThirdPartyProviders.finishActivation(request)
    }

    func applyPendingAccountActivations(on host: Harness) async throws {
        guard connection === host, host.usesEmbeddedEngine else { return }
        let chatGPT = ChatGPTAccount.shared
        if chatGPT.signedIn, chatGPT.pendingActivation, let model = chatGPT.preferredModel {
            try await activateConfiguredModel(on: host, provider: ChatGPTChannel.route, model: model, explicit: true)
            chatGPT.pendingActivation = false
        }
    }

    static func shouldActivateModel(explicit: Bool, current: HostModelDefault, catalog: HostModelCatalog) -> Bool {
        explicit || !catalog.channels.flatMap(\.models).contains { $0.channel == current.provider && $0.model == current.model }
    }

    func activateConfiguredModel(on host: Harness, provider: String, model: String, explicit: Bool) async throws {
        let session = host.sessionID
        let generation = host.sessionGeneration
        let catalog = HostModelCatalog(try await host.rpc("session/modelCatalog", args: [:]))
        let settings = try await HostModelDefaultSettings.read(host)
        guard connection === host, !Task.isCancelled else { throw CancellationError() }
        guard Self.shouldActivateModel(explicit: explicit, current: settings.value, catalog: catalog) else { return }
        guard let option = catalog.channels.flatMap(\.models).first(where: { $0.channel == provider && $0.model == model }) else {
            throw HostError(String(localized: "接入已保存，但模型尚不可用。请检查配置后重新保存。"))
        }
        let desired = HostModelDefault(provider: provider, model: model,
                                       effort: option.effort(keeping: nil), remember: settings.value.remember)
        if settings.value != desired { _ = try await settings.save(desired, on: host) }
        guard connection === host, !Task.isCancelled else { throw CancellationError() }
        if host.sessionID == session && host.sessionGeneration == generation, !switchingSession, messages.isEmpty, phase == .ready {
            try await selectModel(on: host, provider: desired.provider, model: desired.model, effort: desired.effort)
        }
        await refreshModelCatalog(on: host)
    }

    func selectModel(on host: Harness, provider: String, model: String, effort: String?) async throws {
        guard connection === host else { throw HostError(String(localized: "对话已经换了，重新打开再试。")) }
        let session = host.sessionID
        let generation = host.sessionGeneration
        var request: Object = ["sessionId": host.sessionID, "provider": provider, "model": model]
        if let effort { request["reasoningEffort"] = effort }
        let reply = try await host.call("session/selectModel", request)
        guard connection === host && host.sessionID == session && host.sessionGeneration == generation, let selected = reply["selected"] as? Object,
              selected["provider"] as? String == provider, selected["model"] as? String == model,
              effort == nil || selected["reasoningEffort"] as? String == effort else {
            throw HostError(String(localized: "没收到确认，模型可能没切换。重新打开看看。"))
        }
        applyModel(selected)
        Task { await refreshModelCatalog(on: host) }
        if let receipt = reply["defaultSave"] as? Object {
            switch (receipt["status"] as? String, receipt["code"] as? String) {
            case ("saved", _), ("skipped", "settings/fixed-default"): break
            case ("skipped", "settings/default-changed"):
                throw HostError(String(localized: "当前对话的模型已切换。新对话的默认模型在别处改过，请重新打开设置查看。"))
            default: throw HostError(String(localized: "当前对话的模型已切换，但新对话的默认模型没有保存成功。"))
            }
        }
    }
    @Published private(set) var workspace = ""
    @Published private(set) var preparingPhoneCommand = false
    private var pendingTools = Set<String>()
    func isToolRunning(_ step: ChatStep) -> Bool { phase == .replying && pendingTools.contains(step.id) }
    var actions: [ChatStep] { messages.compactMap(\.tool) }

    @Published private(set) var forkParent: String?
    @Published private(set) var forking = false

    @Published private(set) var stopRequest: UUID?
    /// What the composer holds. Keys typed into the field do not republish the conversation (that redrew
    /// every message on each key); only text set from code, and the field turning empty or not, do.
    var draft: String {
        get { activeDraft.text }
        set { activeDraft.text = newValue; draftEdits &+= 1; noteDraftEmptiness() }
    }
    private final class ComposerDraft { var text = "" }
    private var activeDraft = ComposerDraft()
    // Each editor owns its draft across the handover, including uncommitted IME input.
    // A refused create leaves the original draft in place and keeps the new draft for retry.
    private var newDraft = ComposerDraft()
    private var editorDraft: ComposerDraft { creatingSession ? newDraft : activeDraft }
    var draftID: ObjectIdentifier { ObjectIdentifier(editorDraft) }
    /// Bumped when code sets the draft, so the field picks the new text up.
    @Published private(set) var draftEdits = 0
    /// Nothing but blanks in the field.
    @Published private(set) var draftIsEmpty = true
    /// The field's own binding: typing goes here.
    var typedDraft: Binding<String> {
        let edited = editorDraft
        return Binding(get: { edited.text }, set: { [weak self] value in
            edited.text = value
            if self?.activeDraft === edited { self?.noteDraftEmptiness() }
        })
    }
    private func noteDraftEmptiness() {
        let empty = activeDraft.text.allSatisfy(\.isWhitespace)
        if empty != draftIsEmpty { draftIsEmpty = empty }
    }
    private var turnInputs: Int?

    enum BranchAction { case fork, edit, retry }

    private var retryPrompt: Message? {
        messages.dropLast().last { $0.outgoing || !$0.text.isEmpty }
    }

    func canBranch(_ action: BranchAction, at row: Message) -> Bool {
        guard !forking, !switchingSession, phase == .ready, !botSession, let sequence = row.sequence else { return false }
        switch action {
        case .fork: return !row.outgoing && !row.text.isEmpty
        case .edit: return row.outgoing && sequence > 0 && row.prompt != nil
        case .retry:
            guard messages.last?.id == row.id, !row.outgoing, turnInputs == 1,
                  !row.text.isEmpty, let question = retryPrompt else { return false }
            // Image bytes come back from the host (session/attachment); file contents do not.
            return question.outgoing && question.files.isEmpty && (question.prompt?.isEmpty == false || !question.images.isEmpty) && (question.sequence ?? 0) > 0
        }
    }

    func branch(_ action: BranchAction, at row: Message) async {
        guard canBranch(action, at: row), let host = connection, let login,
              messages.contains(where: { $0.id == row.id }) else { return }
        let session = host.sessionID
        let generation = host.sessionGeneration
        let target = action == .retry ? retryPrompt : row
        guard let target, let sequence = target.sequence else { return }
        forking = true
        do {
            // 重新回答 sends the same images again; 编辑后重发 puts them back in the tray.
            var images: [DraftAttachment] = []
            if action != .fork {
                for (index, ref) in target.images.enumerated() {
                    do { images.append(.echoed(ref, data: try await host.imageData(ref), index: index)) }
                    catch { throw HostError(String(localized: "没能读回原消息的图片。")) }
                }
                guard connection === host && host.sessionID == session && host.sessionGeneration == generation else { return }
            }
            if action != .fork {
                let state = try await host.call("session/state", ["sessionId": host.sessionID])
                guard connection === host && host.sessionID == session && host.sessionGeneration == generation else { return }
                guard state["running"] as? Bool == false,
                      state["queue"] is NSNull || (state["queue"] as? [Object])?.isEmpty == true,
                      action != .retry || (messages.last?.id == row.id && turnInputs == 1) else {
                    throw HostError(String(localized: "这个对话还在进行或有排队的消息，稍后再试。"))
                }
            }
            let boundary = action == .fork ? sequence : sequence - 1
            let result = try await host.call("session/fork", ["sessionId": host.sessionID, "atSeq": boundary])
            guard connection === host && host.sessionID == session && host.sessionGeneration == generation else { return }
            guard let child = result["sessionId"] as? String, !child.isEmpty, child != host.sessionID else {
                throw HostError(String(localized: "没能另开对话，稍后再试。"))
            }
            let parent = host.sessionID
            disconnect()
            forkParent = parent
            await connect(address: login.address, token: login.token, existing: child) {
                switch action {
                case .fork: self.forkToast = String(localized: "已另开对话，原对话还在")
                case .retry: self.forkToast = String(localized: "已在新对话里重新回答，原对话还在")
                case .edit: self.forkToast = String(localized: "已在新对话里打开，原对话还在")
                }
                if let prompt = target.prompt {
                    if action == .edit {
                        self.draft = prompt; self.attachments = images
                        if !target.files.isEmpty { self.forkToast = String(localized: "已在新对话里打开，文件需重新添加") }
                    }
                    if action == .retry { await self.send(prompt, attachments: images) }
                }
            }
        } catch {
            if connection === host && host.sessionID == session && host.sessionGeneration == generation { forking = false; notice = Self.describe(error) }
        }
    }

    func dismissForkToast() { forkToast = nil }

    private(set) var botSession = false

    private enum SessionSwitch { case creating, opening }
    @Published private var sessionSwitch: SessionSwitch?
    var switchingSession: Bool { sessionSwitch != nil }
    var creatingSession: Bool { sessionSwitch == .creating }

    @discardableResult
    func openSession(_ id: String?, bot: Bool = false, initialDraft: String? = nil, workspace: String? = nil) async -> Bool {
        guard let host = connection, phase == .ready || phase == .replying, !switchingSession, !forking else { return false }
        if id == nil, let initialDraft { newDraft.text = initialDraft }
        sessionSwitch = id == nil ? .creating : .opening
        notice = nil
        let started = Date()
        defer { if connection === host { sessionSwitch = nil } }
        do {
            let snapshot = try await host.switchSession(existing: id, workspace: workspace)
            guard connection === host else { return false }
            // The host-wide interaction subscription stays alive. Relinquish approvals owned
            // by the old screen so they can be delivered again when that session is reopened.
            let oldInteractions = interactions.compactMap { $0["eventId"] as? String }
            let client = eventClient
            resetSessionState(draft: id == nil ? newDraft : ComposerDraft())
            if id == nil { newDraft = ComposerDraft() }
            if !client.isEmpty, !oldInteractions.isEmpty {
                Task {
                    for event in oldInteractions {
                        _ = try? await host.rpcValue("$events/result", args: ["clientId": client, "eventId": event,
                                                                          "outcome": ["kind": "next"]])
                    }
                }
            }
            botSession = bot
            applySnapshot(snapshot, on: host)
            if id != nil, let initialDraft { draft = initialDraft }
            Log.connection.notice("session switch ready ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
            return true
        } catch {
            guard connection === host else { return false }
            notice = Self.describe(error)
            return false
        }
    }
    @Published private(set) var interactions: [Object] = []
    private var eventClient = ""

    func answer(_ id: String, outcome: Object) async {
        guard let host = connection else { return }
        do {
            _ = try await host.rpcValue("$events/result", args: ["clientId": eventClient, "eventId": id, "outcome": outcome])
            if connection === host { interactions.removeAll { $0["eventId"] as? String == id } }
        } catch { if connection === host { notice = Self.describe(error) } }
    }

    /// 「本对话都允许」: answers what is pending now and every later approval of this conversation.
    func setAutoApprove(_ enabled: Bool) {
        autoApprove = enabled
        guard enabled else { return }
        allowPendingApprovals()
    }

    /// 全自动 for this conversation (FullAuto): approvals, key steps, calls and questions all go ahead.
    var fullAuto: Bool { connection.map { FullAuto.shared.isOn($0.sessionID) } ?? false }

    func setFullAuto(_ on: Bool) {
        guard let host = connection, !host.sessionID.isEmpty else { return }
        FullAuto.shared.set(on, session: host.sessionID)
        if on { allowPendingApprovals() }
    }

    private func allowPendingApprovals() {
        for item in interactions where item["event"] as? String == "approval/request" {
            if let id = item["eventId"] as? String { Task { await answer(id, outcome: ["kind": "result", "value": "allowed-once"]) } }
        }
    }

    private func interaction(_ item: Object, host: Harness) async {
        if item["type"] as? String == "ready" { eventClient = item["clientId"] as? String ?? ""; return }
        guard let id = item["eventId"] as? String else { return }
        switch item["type"] as? String {
        case "cancel": interactions.removeAll { $0["eventId"] as? String == id }
        case "waterfall":
            if item["agentId"] as? String == host.sessionID,
               ["approval/request", "user-questions/request"].contains(item["event"] as? String ?? "") {
                interactions.removeAll { $0["eventId"] as? String == id }
                interactions.append(item)
                if autoApprove || FullAuto.shared.isOn(host.sessionID), item["event"] as? String == "approval/request" {
                    await answer(id, outcome: ["kind": "result", "value": "allowed-once"])
                } else {
                }
            } else { await answer(id, outcome: ["kind": "next"]) }
        default: break
        }
    }

    @Published private(set) var hasOlder = false
    @Published private(set) var loadingOlder = false
    private var firstSequence = 0
    private var cut = 0
    private func pagePosition(_ data: Object) {
        let events = (data["records"] as? [Object] ?? []).compactMap { $0["event"] as? Object }
        let first = events.compactMap { $0["seq"] as? Int }.min()
        hasOlder = data["hasMore"] as? Bool == true && first != nil
        if let first { firstSequence = first }
    }

    func loadShareHistory() async throws {
        guard let host = connection else { return }
        let session = host.sessionID
        let generation = host.sessionGeneration
        while hasOlder {
            try Task.checkCancellation()
            let previous = firstSequence
            if loadingOlder { try await Task.sleep(for: .milliseconds(100)); continue }
            await loadOlder()
            guard connection === host && host.sessionID == session && host.sessionGeneration == generation else { throw HostError(String(localized: "对话连接已改变。")) }
            if hasOlder && previous == firstSequence { throw HostError(notice ?? String(localized: "无法读取完整历史。")) }
        }
    }

    static func shareHistory(on host: Harness, session: String) async throws -> [Message] {
        var page = try await host.snapshot(session: session, maxMessages: 100)
        guard let cursor = page["cursor"] as? Int else { throw HostError(String(localized: "没能读取更早的消息，稍后再试。")) }
        var pages: [[Object]] = []
        var before = Int.max
        while true {
            try Task.checkCancellation()
            let (events, more) = try olderEvents(in: page, before: before)
            pages.append(events)
            guard more, let first = events.first?["seq"] as? Int else { break }
            before = first
            page = try await host.call("session/page", ["address": ["kind": "session", "sessionId": session],
                "beforeSeq": first, "throughSeq": cursor, "maxMessages": 100])
        }
        return prepending(pages.reversed().flatMap { $0 }, to: [])
    }

    static func olderEvents(in page: Object, before: Int) throws -> (events: [Object], more: Bool) {
        guard let records = page["records"] as? [Object], let more = page["hasMore"] as? Bool,
              !more || !records.isEmpty else { throw HostError(String(localized: "没能读取更早的消息，稍后再试。")) }
        var last = -1
        let events = try records.map { record -> Object in
            guard let event = record["event"] as? Object, let seq = event["seq"] as? Int,
                  seq > last, seq < before else { throw HostError(String(localized: "没能读取更早的消息，稍后再试。")) }
            last = seq
            return event
        }
        return (events, more)
    }

    func loadOlder() async {
        guard let host = connection, hasOlder, !loadingOlder else { return }
        let session = host.sessionID
        let generation = host.sessionGeneration
        loadingOlder = true
        defer { if connection === host && host.sessionID == session && host.sessionGeneration == generation { loadingOlder = false } }
        do {
            let before = firstSequence
            let page = try await host.call("session/page", ["address": ["kind": "session", "sessionId": host.sessionID],
                "beforeSeq": before, "throughSeq": cut, "maxMessages": 100])
            guard connection === host && host.sessionID == session && host.sessionGeneration == generation else { return }
            let (events, more) = try Self.olderEvents(in: page, before: before)
            let merged = Self.prepending(events, to: messages)
            if let first = events.first?["seq"] as? Int { firstSequence = first }
            hasOlder = more
            var traced = false
            for event in events { traced = recordTrace(event) || traced }
            if traced { rebuildTraces() }
            messages = merged
            collectFiles(events, historyChanged: true)
        } catch { if connection === host && host.sessionID == session && host.sessionGeneration == generation { notice = Self.describe(error) } }
    }

    static func prepending(_ events: [Object], to current: [Message]) -> [Message] {
        var older: [Message] = []
        var positions: [String: Int] = [:]
        for event in events {
            if let row = Message.toolRecord(event), let id = row.tool?.id {
                if let index = positions[id] { older[index].mergeTool(row) }
                else { positions[id] = older.count; older.append(row) }
            } else if let row = Message.user(event) ?? Message.assistant(event) ?? Message.notice(event) { older.append(row) }
        }
        var tail: [Message] = []
        for row in current {
            if let id = row.tool?.id, let index = positions[id] {
                older[index].mergeTool(row)
                older[index].id = row.id
            } else { tail.append(row) }
        }
        return older + tail
    }

    private var partialID: UUID?

    private func applySnapshot(_ snapshot: Object, on host: Harness) {
        cut = snapshot["cursor"] as? Int ?? 0
        pagePosition(snapshot)
        messages = []; deliverables = []; fileEvents = [:]; finishedTurns = []
        turnRequests.removeAll()
        turnStartSequence = nil
        traceLog = [:]; traces = []; approvalCalls = [:]; approvalOutcomes = [:]
        workspace = (snapshot["header"] as? Object)?["cwd"] as? String ?? ""
        let projections = snapshot["projections"] as? Object
        let values = projections?["values"] as? Object
        // A choice made before the first message is `pending` until a request uses it.
        let selection = values?["modelSelection"] as? Object
        let next = selection?["pending"] as? Object ?? selection?["next"] as? Object ?? selection?["lastUsed"] as? Object
        applyModel(next)
        title = values?["title"] as? String ?? String(localized: "新对话")
        contextMeter = ContextMeter(values?["contextPressure"])
        sessionModes = SessionModes(values)
        modesRead = UUID()
        if let seeded = TodoItem.list(values?["todos"]) {
            todos = seeded; todoSeedSeq = projections?["asOfSeq"] as? Int ?? -1
        } else { todos = []; todoSeedSeq = -1 }
        todoEvents = false
        phase = .ready
        for record in snapshot["records"] as? [Object] ?? [] { update(record, replaying: true) }
        rebuildTraces()
        UITrace.note("snapshot session=\(Log.session(host.sessionID)) generation=\(host.sessionGeneration.uuidString.prefix(8)) records=\((snapshot["records"] as? [Object])?.count ?? 0) messages=\(messages.count) older=\(hasOlder) phase=\(phase)")
        watchProjections(on: host)
        if modelName.isEmpty, let catalog = modelCatalog, let fallback = catalog.fallback,
           catalog.channels.flatMap(\.models).contains(where: { $0.channel == fallback.channel && $0.model == fallback.model }) {
            applyModel(["provider": fallback.channel, "model": fallback.model,
                        "reasoningEffort": fallback.effort as Any], isDefault: true)
        }
    }

    func connect(address: String, token: String, existing: String? = nil, workspaceID: String? = nil,
                 managedEngineHome: URL? = nil, bot: Bool = false, afterSnapshot: (() async -> Void)? = nil) async {
        guard phase == .offline else { return }
        notice = nil
        let target = URL(string: address).map { $0.host == "127.0.0.1" ? "loopback:" + String($0.port ?? 0) : "host" } ?? "host"
        Log.connection.notice("connect \(target, privacy: .public) session=\(Log.session(existing), privacy: .public)")
        do {
            let host = try Harness(address: address, managedEngineHome: managedEngineHome)
            connection = host
            phase = .connecting
            do {
                let snapshot = try await host.connect(token: token, existing: existing, workspace: workspaceID)
                guard connection === host else {
                    Log.connection.notice("connect superseded before snapshot \(target, privacy: .public)")
                    return
                }
                login = (address, token)
                botSession = bot
                applySnapshot(snapshot, on: host)
                Task { await refreshModelCatalog(on: host) }
                Log.connection.notice("ready \(target, privacy: .public) session=\(Log.session(host.sessionID), privacy: .public)")
                await afterSnapshot?()
                while connection === host {
                    let item = try await host.next()
                    guard connection === host else { return }
                    if let generation = item["_clientSessionGeneration"] as? String, generation != host.sessionGeneration.uuidString { continue }
                    if let incoming = item["interaction"] as? Object { await interaction(incoming, host: host) }
                    else { update(item) }
                }
            } catch {
                guard connection === host else { return }
                Log.connection.error("stream ended \(target, privacy: .public) session=\(Log.session(host.sessionID), privacy: .public) phase=\(String(describing: self.phase), privacy: .public) reason=\(Log.reason(error), privacy: .public)")
                // The link dropped, not the user: what they were typing stays for the reconnect.
                let unsent = draft, tray = attachments
                disconnect()
                draft = unsent; attachments = tray
                notice = Self.describe(error)
            }
        } catch {
            Log.connection.error("connect failed \(target, privacy: .public) reason=\(Log.reason(error), privacy: .public)")
            notice = Self.describe(error)
        }
    }

    /// `session/observeProjections`: live context pressure and todo list. Quietly absent on hosts without it.
    private func watchProjections(on host: Harness) {
        projectionTask?.cancel()
        projectionWatch?.cancel(); projectionWatch = nil
        let session = host.sessionID
        let generation = host.sessionGeneration
        projectionTask = Task { [weak self] in
            guard let channel = try? await host.stream("session/observeProjections", args: ["request": ["sessionId": session]]) else { return }
            guard let self, self.connection === host, host.sessionID == session && host.sessionGeneration == generation, !Task.isCancelled else { channel.cancel(); return }
            self.projectionWatch = channel
            while !Task.isCancelled {
                guard let frame = try? await channel.next(), !Task.isCancelled, self.connection === host, host.sessionID == session && host.sessionGeneration == generation else { break }
                guard frame["type"] as? String == "projection", let changes = frame["changes"] as? [Object] else { continue }
                let seq = frame["seq"] as? Int ?? Int.max
                var modes = self.sessionModes
                for change in changes {
                    switch change["key"] as? String {
                    case "contextPressure": self.contextMeter = ContextMeter(change["val"]) ?? self.contextMeter
                    case "todos":
                        if seq >= self.todoSeedSeq { self.todos = TodoItem.list(change["val"]) ?? []; self.todoSeedSeq = seq }
                    case "permissions": modes.preset = (change["val"] as? Object)?["currentValue"] as? String
                    case "plan": modes.plan = (change["val"] as? Object)?["active"] as? Bool == true
                    default: break
                    }
                }
                if modes != self.sessionModes {
                    self.modesRead = UUID()
                    self.sessionModes = modes
                }
            }
            channel.cancel()
        }
    }

    /// Older hosts may expose the current modes over RPC without streaming the changes.
    func refreshSessionModes() async {
        guard let host = connection, phase == .ready || phase == .replying,
              !switchingSession, !host.sessionID.isEmpty, !Task.isCancelled else { return }
        let generation = host.sessionGeneration
        let read = UUID()
        modesRead = read
        guard let projection = try? await host.call("session/projections", ["sessionId": host.sessionID]),
              connection === host, host.sessionGeneration == generation, modesRead == read, !Task.isCancelled else { return }
        let modes = SessionModes(projection["values"] as? Object)
        if modes != sessionModes { sessionModes = modes }
    }

    func setComposerPlan(_ on: Bool) async {
        if await runComposerCommand(on ? "/plan" : "/plan off", failure: String(localized: "没能切换「先列计划」。")) {
            await refreshSessionModes()
        }
    }

    func compactFromComposer() async {
        guard phase == .ready else { return }
        _ = await runComposerCommand("/compact", failure: String(localized: "没能压缩对话，请稍后再试。"))
    }

    private func runComposerCommand(_ line: String, failure: String) async -> Bool {
        guard let host = connection, !host.sessionID.isEmpty, !switchingSession else { return false }
        let generation = host.sessionGeneration
        let reply = try? await host.rpc("commands/execute", args: ["agentId": host.sessionID, "line": line,
                                                                  "submittedAttachments": [] as [Any]])
        guard connection === host, host.sessionGeneration == generation, !Task.isCancelled else { return false }
        guard (reply?["result"] as? Object)?["kind"] as? String == "success" else {
            notice = failure
            return false
        }
        return true
    }

    func send(_ text: String, attachments: [DraftAttachment] = [], steer: Bool = false, requestID: UUID = UUID()) async {
        guard !switchingSession, !Task.isCancelled else { return }
        let fileNames = attachments.filter { !$0.isImage }.map(\.name)
        if steer {
            guard phase == .replying, !forking, !botSession, let host = connection else { return }
            let session = host.sessionID
            let generation = host.sessionGeneration
            let request = requestID
            messages.append(Message(outgoing: true, text: text, requestID: request, prompt: text,
                                    hasAttachment: !attachments.isEmpty, files: fileNames,
                                    drafts: attachments, steering: true))
            do {
                if try await host.prompt(text, attachments: attachments, requestID: request, mode: "steer") { if connection === host, host.sessionID == session && host.sessionGeneration == generation { notice = Self.imagesAsFiles } }
            } catch {
                guard connection === host && host.sessionID == session && host.sessionGeneration == generation else { return }
                if let index = messages.firstIndex(where: { $0.requestID == request && $0.sequence == nil }) {
                    messages[index].steering = false
                    messages[index].failed = true
                }
                notice = Self.describe(error)
            }
            return
        }
        guard phase == .ready, !forking, let host = connection else { return }
        let session = host.sessionID
        let generation = host.sessionGeneration
        if modelProvider == ChatGPTChannel.route, host.usesEmbeddedEngine {
            await ChatGPTChannel.prepareTurn(on: host)
            guard connection === host, host.sessionGeneration == generation, phase == .ready, !switchingSession, !Task.isCancelled else { return }
        }
        phase = .replying
        notice = nil
        let request = requestID
        messages.append(Message(outgoing: true, text: text, requestID: request, prompt: text,
                                hasAttachment: !attachments.isEmpty, files: fileNames, drafts: attachments))
        do {
            if botSession {
                _ = try await host.bot("send", ["sessionId": host.sessionID, "text": text])
            } else if try await host.prompt(text, attachments: attachments, requestID: request) { if connection === host, host.sessionID == session && host.sessionGeneration == generation { notice = Self.imagesAsFiles } }
        }
        catch {
            guard connection === host && host.sessionID == session && host.sessionGeneration == generation else { return }
            // The host answered and refused (a model without image input, a bad attachment …): the link
            // is fine, so the message stays here, 「未送达 · 已保留」, to edit and resend.
            if let refusal = error as? HostError, botSession || refusal.code?.contains("/") == true,
               let index = messages.firstIndex(where: { $0.requestID == request && $0.sequence == nil }) {
                messages[index].failed = true
                if phase == .replying, !traces.contains(where: \.running) { phase = .ready }
                notice = HostError.explain(error)
                return
            }
            Log.connection.error("send failed session=\(Log.session(host.sessionID), privacy: .public) reason=\(Log.reason(error), privacy: .public)")
            let unsent = draft, tray = self.attachments
            disconnect()
            draft = unsent; self.attachments = tray
            notice = Self.describe(error) + String(localized: " 消息可能没发出去，已放回输入框。")
        }
    }

    static let imagesAsFiles = String(localized: "当前模型不读图片，图片已作为文件发给对话，工具可以打开它们。")

    /// 「编辑后重发」 on a message the host did not accept: back into the draft.
    func editFailed(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.failed }) else { return }
        let text = messages[index].prompt ?? messages[index].text
        attach(messages[index].drafts)
        messages.remove(at: index)
        draft = draft.isEmpty ? text : draft + "\n" + text
    }

    func stopTurn() async {
        guard phase == .replying, stopRequest == nil, let host = connection else { return }
        let request = UUID()
        stopRequest = request
        do {
            let reply = try await host.call("session/cancel", ["sessionId": host.sessionID])
            guard reply["accepted"] as? Bool == true else { throw HostError(String(localized: "没收到确认，可能还没停下。稍后再看。")) }
            await returnPendingSteers(host)
        } catch {
            if connection === host && stopRequest == request {
                stopRequest = nil
                notice = Self.describe(error)
            }
        }
    }

    /// A submitted prompt can still be in the host's queue when stop races with its first turn.
    func withdrawQueuedPrompt(_ request: UUID, on host: Harness) async throws -> Bool {
        let session = host.sessionID
        let generation = host.sessionGeneration
        guard connection === host else { return false }
        let state = try await host.call("session/state", ["sessionId": session])
        guard connection === host, host.sessionGeneration == generation,
              let queued = (state["queue"] as? [Object])?.first(where: {
                  ($0["rpcId"] as? String).flatMap(UUID.init(uuidString:)) == request
              }), let id = queued["id"] as? String else { return false }
        let result = try await host.call("session/updateQueue", ["sessionId": session, "itemId": id, "action": ["kind": "remove"]])
        guard result["accepted"] as? Bool == true, connection === host, host.sessionGeneration == generation else { return false }
        if let index = messages.firstIndex(where: { $0.requestID == request && $0.sequence == nil }) {
            let prompt = messages.remove(at: index)
            if draft.isEmpty { draft = prompt.prompt ?? prompt.text }
            attach(prompt.drafts)
        }
        if phase == .replying, !traces.contains(where: \.running) { phase = .ready }
        return true
    }

    /// A stop keeps the host's inbox, so a steer the agent had not read yet would sit there and ride along
    /// with the next message. Stopping means not continuing: take such steers back and return them to the composer.
    private func returnPendingSteers(_ host: Harness) async {
        let session = host.sessionID
        let pending = messages.filter { $0.steering && $0.sequence == nil && $0.requestID != nil }
        guard !pending.isEmpty,
              let state = try? await host.call("session/state", ["sessionId": session]),
              connection === host, host.sessionID == session else { return }
        let queue = state["queue"] as? [Object] ?? []
        var returned: [Message] = []
        for row in pending {
            guard let request = row.requestID?.uuidString,
                  let item = queue.first(where: { ($0["rpcId"] as? String)?.caseInsensitiveCompare(request) == .orderedSame }),
                  let id = item["id"] as? String else { continue }
            do {
                _ = try await host.call("session/updateQueue", ["sessionId": session, "itemId": id, "action": ["kind": "remove"]])
                returned.append(row)
            } catch { continue }
        }
        guard connection === host, host.sessionID == session, !returned.isEmpty else { return }
        let ids = Set(returned.map(\.id))
        messages.removeAll { ids.contains($0.id) }
        let text = returned.map { $0.prompt ?? $0.text }.joined(separator: "\n\n")
        draft = draft.isEmpty ? text : text + "\n\n" + draft
        attach(returned.flatMap(\.drafts))
        notice = String(localized: "插话的消息还没被读到，已放回输入框。")
    }

    func disconnect() {
        if let connection {
            Log.connection.notice("disconnect session=\(Log.session(connection.sessionID), privacy: .public) phase=\(String(describing: self.phase), privacy: .public)")
        }
        connection?.close()
        connection = nil
        channelSync?.task.cancel(); channelSync = nil
        projectionTask?.cancel(); projectionTask = nil
        projectionWatch?.cancel(); projectionWatch = nil
        needsModelSetup = nil; modelCatalog = nil
        modelNames = [:]
        resetSessionState()
        sessionSwitch = nil; newDraft = ComposerDraft()
        login = nil
        eventClient = ""
        phase = .offline
    }

    private func resetSessionState(draft nextDraft: ComposerDraft = ComposerDraft()) {
        applyModel(nil); deliverables = []; fileEvents = [:]; finishedTurns = []
        traceLog = [:]; traces = []; approvalCalls = [:]; approvalOutcomes = [:]
        todos = []; contextMeter = nil; todoSeedSeq = -1; todoEvents = false
        sessionModes = SessionModes()
        modesRead = UUID()
        autoApprove = false
        forkToast = nil
        botSession = false
        forkParent = nil
        activeDraft = nextDraft; draftEdits &+= 1; noteDraftEmptiness()
        attachments = []
        pendingTools.removeAll()
        preparingPhoneCommand = false
        turnInputs = nil
        turnRequests.removeAll()
        turnStartSequence = nil
        stopRequest = nil
        forking = false
        hasOlder = false
        loadingOlder = false
        interactions = []
        partialID = nil
        heldText = ""; heldThinking = ""
    }

    private static func isWordDelta(_ item: Object) -> Bool {
        guard item["event"] == nil, let frame = item["frame"] as? Object, frame["type"] as? String == "chunk",
              let type = (frame["chunk"] as? Object)?["type"] as? String else { return false }
        return type == "text-delta" || type == "reasoning-delta"
    }

    private static func describe(_ error: Error) -> String {
        (error as? HostError)?.message ?? String(localized: "连接断了。检查网络后再试，一直不行就重新打开 Pallas Agent。")
    }

    private func update(_ item: Object, replaying: Bool = false) {
        if !Self.isWordDelta(item) { landHeld() }
        if let frame = item["frame"] as? Object {
            switch frame["type"] as? String {
            case "start":
                if preparingPhoneCommand { preparingPhoneCommand = false }
                discardPartial()
            case "chunk":
                if let chunk = frame["chunk"] as? Object, let type = chunk["type"] as? String {
                    if type == "tool-call-delta", chunk["name"] as? String == "iphone_screen", !preparingPhoneCommand {
                        preparingPhoneCommand = true
                    } else if ["text-delta", "reasoning-delta"].contains(type), let delta = chunk["text"] as? String {
                        append(delta, reasoning: type == "reasoning-delta")
                    }
                }
            case "end":
                if preparingPhoneCommand { preparingPhoneCommand = false }
                if (frame["outcome"] as? Object)?["kind"] as? String == "abandoned" { discardPartial() }
            default: break
            }
        }
        guard let event = item["event"] as? Object, let data = event["data"] as? Object else { return }
        collectFiles([event])
        if recordTrace(event) && !replaying { rebuildTraces() }
        let seq = event["seq"] as? Int ?? Int.max
        switch event["type"] as? String {
        case "user/message":
            if let late = Message.notice(event) {
                if !messages.contains(where: { $0.sequence == late.sequence }) { messages.append(late) }
                return
            }
            guard !botSession || replaying, let row = Message.user(event) else { return }
            if let sequence = row.sequence, messages.contains(where: { $0.sequence == sequence }) { return }
            if let request = row.requestID { turnRequests.insert(request) }
            if let count = turnInputs { turnInputs = count + 1 }
            if let request = row.requestID, let i = messages.firstIndex(where: { $0.requestID == request }) {
                let steered = messages[i].steering
                messages[i].sequence = row.sequence
                HostImage.adopt(messages[i].drafts, as: row.images)
                messages[i].images = row.images
                messages[i].files = row.files
                messages[i].time = row.time
                messages[i].steering = false
                messages[i].drafts = []
                // A steer lands when the agent takes it: after everything that arrived before its echo.
                if steered, i < messages.count - 1 { messages.append(messages.remove(at: i)) }
            } else { messages.append(row) }
        case "model/selection":
            if !replaying, data["model"] is String { applyModel(data) }
        case "session/title":
            if let value = data["title"] as? String { title = value }
        case "todo/write":
            if seq > todoSeedSeq { todos = TodoItem.list(data["todos"]) ?? []; todoEvents = true }
        case "tool/call", "tool/result":
            guard let row = Message.toolRecord(event), let id = row.tool?.id else { return }
            if event["type"] as? String == "tool/call" { pendingTools.insert(id) } else { pendingTools.remove(id) }
            if let index = messages.lastIndex(where: { $0.tool?.id == id }) { messages[index].mergeTool(row) }
            else { messages.append(row) }
            // Hosts without `todo/write` events: the successful todo_write call's own list.
            if event["type"] as? String == "tool/result", !todoEvents, seq > todoSeedSeq, row.tool?.state == "ok",
               let call = messages.last(where: { $0.tool?.id == id })?.tool, call.name == "todo_write",
               let args = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? Object,
               let list = TodoItem.list(args["todos"]) { todos = list }
        case "assistant/message":
            let final = Message.assistant(event)
            if let id = partialID, let index = messages.firstIndex(where: { $0.id == id }) {
                if let final {
                    messages[index].text = final.text
                    messages[index].thinking = final.thinking
                    messages[index].images = final.images
                    messages[index].sequence = final.sequence
                    messages[index].turn = final.turn
                    messages[index].time = final.time
                    messages[index].step = final.step
                    messages[index].finalAnswer = final.finalAnswer
                    messages[index].interrupted = final.interrupted
                    messages[index].hostID = final.hostID
                } else { messages.remove(at: index) }
            } else if let final { messages.append(final) }
            partialID = nil
        case "llm/retry":
            if let row = Message.notice(event), !messages.contains(where: { $0.sequence == row.sequence }) { messages.append(row) }
        case "turn/start":
            pendingTools.removeAll()
            turnStartSequence = event["seq"] as? Int
            turnInputs = 0
            phase = .replying
            if seq > todoSeedSeq { todos = [] }
        case "turn/end":
            if preparingPhoneCommand { preparingPhoneCommand = false }
            pendingTools.removeAll()
            stopRequest = nil
            phase = .ready
            if !(replaying && (data["reason"] as? Object)?["kind"] as? String == "forked"), let row = Message.notice(event),
               !messages.contains(where: { $0.sequence == row.sequence }) { messages.append(row) }
            if !replaying, !botSession, let host = connection {
                publishTurnEnd(data, session: host.sessionID, sequence: event["seq"] as? Int)
            }
            turnRequests.removeAll()
            turnStartSequence = nil
        default: break
        }
    }

    private func publishTurnEnd(_ data: Object, session: String, sequence: Int?) {
        let turn = data["turn"] as? Int
        let rows = messages.filter { row in
            guard !row.outgoing, row.tool == nil, row.notice == nil, !row.interrupted, !row.text.isEmpty,
                  let sequence = row.sequence else { return false }
            if let turn { return row.turn == turn }
            return turnStartSequence.map { sequence > $0 } ?? false
        }
        let answers = rows.filter(\.finalAnswer)
        let reply = (answers.isEmpty ? rows : answers).map(\.text).joined(separator: "\n\n")
        completedTurns.send(CompletedTurn(session: session, title: title, requests: turnRequests,
                                         reply: reply, notice: TurnNotice.turnEnd(data), sequence: sequence))
    }

    /// Words of the reply that came in since the screen last changed. Every token used to change
    /// `messages`, and with it redraw the whole chat, dozens of times a second; now they land together
    /// at most every 50 ms (the reply's own reveal smooths the rest).
    private var heldText = "", heldThinking = ""
    private var landingHeld = false

    private func append(_ delta: String, reasoning: Bool) {
        guard !delta.isEmpty else { return }
        if let id = partialID, messages.last?.id == id || messages.contains(where: { $0.id == id }) {
            if reasoning { heldThinking += delta } else { heldText += delta }
            guard !landingHeld else { return }
            landingHeld = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.landHeld() }
        } else {
            // The first words show at once.
            let row = Message(outgoing: false, text: reasoning ? "" : delta, thinking: reasoning ? delta : "")
            partialID = row.id
            messages.append(row)
        }
    }

    /// Puts the held words into the reply in one change. Runs before any other event, so order holds.
    private func landHeld() {
        landingHeld = false
        guard !heldText.isEmpty || !heldThinking.isEmpty else { return }
        defer { heldText = ""; heldThinking = "" }
        guard let id = partialID, let index = messages.lastIndex(where: { $0.id == id }) else { return }
        var row = messages[index]
        row.text += heldText
        row.thinking += heldThinking
        messages[index] = row
    }

    private func discardPartial() {
        heldText = ""; heldThinking = ""
        if let partialID { messages.removeAll { $0.id == partialID } }
        partialID = nil
    }
}
