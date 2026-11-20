// 生成中输入框正上方的活动条。优先级：正在停止 > 等你回答 / 确认 > 正在跑的工具 >
// 写回复 / 思考 > 等首字。

import SwiftUI

/// 这一刻在做什么。
struct RunActivity: Equatable {
    enum Kind { case waiting, thinking, writing, tool, approval, question, stopping }

    var kind: Kind
    var title: String
    var detail = ""
    var detailIsCode = false

    /// 在等你：图形和标题换成警示色。
    var waitingOnUser: Bool { kind == .approval || kind == .question }

    /// 主机对话。
    @MainActor static func of(_ chat: Conversation) -> RunActivity? {
        guard chat.phase == .replying else { return nil }
        if chat.stopRequest != nil { return RunActivity(kind: .stopping, title: String(localized: "正在停止")) }
        if let ask = chat.interactions.first(where: { $0["event"] as? String == "user-questions/request" }) {
            let questions = (ask["request"] as? Object)?["questions"] as? [Object] ?? []
            return RunActivity(kind: .question, title: String(localized: "等你回答"), detail: oneLine(questions.first?["question"] as? String ?? ""))
        }
        if let ask = chat.interactions.first(where: { $0["event"] as? String == "approval/request" }) {
            let request = ask["request"] as? Object ?? [:]
            let call = request["callId"] as? String
            let step = chat.messages.last { message in message.tool.map { Conversation.callID(of: $0) } == call }?.tool
            let named = step ?? (request["toolName"] as? String).map { ChatStep(id: "", name: $0, arguments: "", result: "", state: "running") }
            let detail = named.map { [$0.verb, $0.summary(in: chat.workspace)].filter { !$0.isEmpty }.joined(separator: " ") } ?? ""
            return RunActivity(kind: .approval, title: String(localized: "等你确认"), detail: detail)
        }
        if chat.preparingPhoneCommand { return RunActivity(kind: .waiting, title: String(localized: "正在想下一步怎么操作手机")) }
        for message in chat.messages.reversed() {
            if message.outgoing { break }
            if let step = message.tool {
                let status = chat.toolStatus(step, turn: message.turn)
                guard status == .running || status == .awaitingApproval else { break }
                let running = chat.messages.reversed().prefix { !$0.outgoing }
                    .filter { $0.tool.map { chat.toolStatus($0, turn: nil) == .running } ?? false }.count
                let more = running > 1 ? String(localized: "等 \(running) 项") : ""
                return RunActivity(kind: .tool, title: step.name == "memory" ? String(localized: "正在整理记忆") : step.verb,
                                   detail: [step.summary(in: chat.workspace), more].filter { !$0.isEmpty }.joined(separator: "  "),
                                   detailIsCode: step.summaryIsCode)
            }
            if let notice = message.notice {
                // The request failed and the engine is trying again: say so instead of "waiting".
                if notice.kind == "retry" {
                    let count = notice.retry.map { retry in notice.maxRetries.map { "\(retry)/\($0)" } ?? "\(retry)" } ?? ""
                    return RunActivity(kind: .waiting, title: String(localized: "请求失败，正在重试"), detail: count)
                }
                break
            }
            if message.sequence == nil {
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return RunActivity(kind: .writing, title: String(localized: "写回复中"))
                }
                if !message.thinking.isEmpty { return RunActivity(kind: .thinking, title: String(localized: "思考中")) }
            }
            break
        }
        return RunActivity(kind: .waiting, title: String(localized: "正在等回复"))
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 没有具体内容时的一句说明，每 8 秒换一句。
    func flavor(at elapsed: TimeInterval, seed: Int) -> String? {
        let pool: [String]
        switch kind {
        case .waiting: return nil
        case .tool: pool = detail.isEmpty ? [String(localized: "做完这一步会自动继续")] : []
        default: pool = []
        }
        guard !pool.isEmpty else { return nil }
        return pool[(seed + Int(elapsed / 8)) % pool.count]
    }
}

/// 输入框正上方的一颗玻璃胶囊：图形 + 此刻在做什么 + 一句说明 + 本轮用时。
/// 出现时从输入框背后升起，收起时沉回去（240ms）；点一下打开本轮详情。
struct ActivityStrip: View {
    let activity: RunActivity
    /// 本轮开始的时刻（不知道时为出现的时刻）。
    let since: Date
    var onTap: (() -> Void)?
    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 0) {
                StripPulse(kind: activity.kind).padding(.trailing, 6)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(since))
                    line(elapsed: elapsed)
                }
            }
            .padding(.leading, 9).padding(.trailing, 14).padding(.vertical, 6)
            .frame(minHeight: 36)
            .chatCapsule()
        }
        .buttonStyle(.pressable)
        .disabled(onTap == nil)
        .padding(.horizontal, 16).padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.title + " " + activity.detail)
        .accessibilityHint(onTap == nil ? "" : "查看本轮详情")
    }

    /// 标题（正文色 600）› 内容（次级色）› 说明和计时（三级色）。内容一变，整行 160ms 交叉淡化。
    private func line(elapsed: TimeInterval) -> some View {
        let flavor = activity.flavor(at: elapsed, seed: Int(since.timeIntervalSince1970) % 7)
        let tint: Color = activity.waitingOnUser ? .orange : ChatColors.ink
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(activity.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                if !activity.detail.isEmpty || flavor != nil {
                    second(flavor).lineLimit(1).truncationMode(.tail)
                }
            }
            .id(activity.title + "\u{0}" + activity.detail + "\u{0}" + (flavor ?? ""))
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.clock(elapsed)).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(activity.waitingOnUser ? Color.orange : ChatColors.tertiary)
        }
        .animation(Motion.std(Motion.quick), value: activity)
        .animation(Motion.std(Motion.quick), value: flavor)
    }

    private func second(_ flavor: String?) -> Text {
        var text = Text(verbatim: "")
        if !activity.detail.isEmpty {
            text = Text(verbatim: activity.detail)
                .font(activity.detailIsCode ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundColor(ChatColors.secondary)
        }
        if let flavor {
            let piece = Text(verbatim: activity.detail.isEmpty ? flavor : " · " + flavor)
                .font(.system(size: 12)).foregroundColor(ChatColors.tertiary)
            text = Text("\(text)\(piece)")
        }
        return text
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 左端的小图形：三根细条起伏。写字时快，思考和跑工具时慢一档，等你时是警示色、最慢，正在停止时静止。
private struct StripPulse: View {
    let kind: RunActivity.Kind

    private var speed: Double {
        switch kind {
        case .writing: 1.6
        case .thinking, .tool: 0.9
        case .waiting: 0.6
        case .approval, .question: 0.35
        case .stopping: 0
        }
    }

    var body: some View {
        let tint: Color = kind == .approval || kind == .question ? .orange : StreamRow.brand
        TimelineView(.animation(paused: speed == 0 || Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * speed
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = speed == 0 || Motion.reduced ? 0.5 : 0.5 + 0.5 * sin(2 * .pi * (t + Double(i) / 3))
                    Capsule().fill(tint).frame(width: 3, height: 5 + 9 * wave)
                }
            }
        }
        .frame(width: 14, height: 16)
        .accessibilityHidden(true)
    }
}
