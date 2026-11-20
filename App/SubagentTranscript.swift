import SwiftUI

/// One subagent's conversation, read-only, opened from 对话详情 › 子代理. The engine serves a child
/// only through its parent's address (`kind: subagent`); opening it as a session of its own fails
/// with session/agent-busy. Refreshes every few seconds while the child is running.
struct SubagentTranscript: View {
    let host: Harness
    let node: HostSubagentNode
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @State private var items: [Message] = []
    @State private var issue: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let issue, items.isEmpty {
                    OfflineMessage(symbol: "exclamationmark.triangle", title: String(localized: "没能读取子任务的对话"), detail: issue) { Task { await load() } }
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if items.isEmpty {
                    HostEmptyState(symbol: "point.3.connected.trianglepath.dotted", title: String(localized: "子任务还没有内容"))
                }
                ForEach(items) { item in
                    if let step = item.tool {
                        ToolRowView(step: step, status: Self.status(step), host: host)
                    } else {
                        MessageBubble(text: item.text, outgoing: item.outgoing, font: typeSize.font, share: {}, quote: {}, showActions: false)
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle(node.label).inlineNavigationTitle()
        .accessibilityIdentifier("subagentTranscript")
        .task {
            while !Task.isCancelled {
                await load()
                guard node.state == .running else { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
    }

    private static func status(_ step: ChatStep) -> ToolStatus {
        switch step.state {
        case "running": .running
        case "ok": .succeeded
        case "denied": .denied
        case "cancelled": .cancelled
        default: .failed
        }
    }

    private func load() async {
        do {
            let snapshot = try await host.snapshot(session: node.id, maxMessages: 200, parent: node.parent, mode: node.mode)
            let events = ((snapshot["records"] as? [Object]) ?? []).compactMap { $0["event"] as? Object }
            items = Self.messages(events)
            issue = nil
        } catch { issue = HostError.explain(error) }
        loaded = true
    }

    /// The task and messages it received, its replies, and its tool calls with their results.
    static func messages(_ events: [Object]) -> [Message] {
        var result: [Message] = []
        var tools: [String: Int] = [:]
        for event in events {
            switch event["type"] as? String {
            case "user/message":
                guard let data = event["data"] as? Object else { continue }
                var text = ((data["content"] as? [Object]) ?? []).compactMap { $0["text"] as? String }.joined()
                // The engine appends how to report back ("Your parent agent id is …"); the task is what precedes it.
                if let guidance = text.range(of: "Your parent agent id is") { text = String(text[..<guidance.lowerBound]) }
                // "Agent session-… sent a message: …" is the parent writing.
                if let range = text.range(of: #"^Agent \S+ sent a message:\s*"#, options: .regularExpression) {
                    text = String(localized: "主代理：") + text[range.upperBound...]
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Runtime context and reminders the engine adds are not the task.
                guard !text.isEmpty, (data["source"] as? Object)?["kind"] as? String != "system",
                      !text.hasPrefix("<system-reminder>"), !text.hasPrefix("Current runtime context"), !text.hasPrefix("Time sampled")
                else { continue }
                result.append(Message(outgoing: true, text: text, sequence: event["seq"] as? Int))
            case "assistant/message":
                if let message = Message.assistant(event), !message.text.isEmpty { result.append(message) }
            case "tool/call", "tool/result":
                guard let record = Message.toolRecord(event), let step = record.tool else { continue }
                if let index = tools[step.id] { result[index].mergeTool(record) }
                else { tools[step.id] = result.count; result.append(record) }
            default: break
            }
        }
        return result
    }
}
