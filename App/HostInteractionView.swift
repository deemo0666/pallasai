import SwiftUI

/// The card shell of approvals and questions: icon + title row, toned hairline.
struct ChatCardShell<Content: View>: View {
    let icon: String
    let title: String
    let tone: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tone)
                Text(title).font(.headline).foregroundStyle(ChatColors.ink)
                Spacer(minLength: 0)
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tone.opacity(0.55), lineWidth: 1))
    }
}

/// A pending `approval/request` or `user-questions/request`, as a card in the stream
/// (under its tool row when the host named the call).
struct HostInteractionView: View {
    let event: Object
    @ObservedObject var chat: Conversation
    var step: ChatStep? = nil
    var workspace = ""
    @State private var choices: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var customOpen: [String: Bool] = [:]
    @State private var busy: String?
    @State private var confirmAll = false
    /// The command or path behind the plain-words line, opened on request.
    @State private var showCode = false
    private var request: Object { event["request"] as? Object ?? [:] }
    private var questions: [Object] { request["questions"] as? [Object] ?? [] }

    var body: some View {
        Group {
            if event["event"] as? String == "approval/request" { approval } else { questionCard }
        }.disabled(busy != nil)
    }

    // MARK: Approval

    private var tool: ChatStep? {
        if let step { return step }
        guard let call = request["callId"] as? String else { return nil }
        return chat.messages.last { $0.tool.map(Conversation.callID) == call }?.tool
    }

    private var approvalTitle: String {
        let name = tool?.name ?? request["toolName"] as? String ?? ""
        switch name {
        case "bash", "pwsh": return String(localized: "允许运行这条命令？")
        case "write": return String(localized: "允许写入这个文件？")
        case "edit", "str_replace_editor": return String(localized: "允许修改这个文件？")
        case "web_fetch": return String(localized: "允许打开这个网页？")
        case "web_search": return String(localized: "允许联网搜索？")
        default:
            let step = tool ?? ChatStep(id: "", name: name, arguments: "", result: "", state: "running")
            if step.isKnownTool { return String(localized: "允许「") + step.verb + String(localized: "」？") }
            let readable = step.readableName
            return readable.isEmpty ? String(localized: "允许这一步？") : String(localized: "允许使用「") + readable + String(localized: "」？")
        }
    }

    private var reason: String? {
        let display = (request["displayReason"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }.filter { !$0.value.isEmpty }
        let localized = AppLanguage.pick(display)
        let text = localized ?? request["reason"] as? String
        return text.map(ShareText.redacted).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var approval: some View {
        let step = tool
        let root = workspace.isEmpty ? chat.workspace : workspace
        let isCommand = step?.command != nil
        let code = (step?.command ?? step?.path.map { ChatStep.displayPath($0, workspace: root) })?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // What this step is for, in the model's or the engine's words; then what the tool row would say.
        let said = step?.arg("description")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = step.map { $0.summaryIsCode ? "" : $0.summary(in: root) } ?? ""
        let purpose = [said, reason ?? "", summary].first { !$0.isEmpty } ?? ""
        let note = !said.isEmpty ? reason : nil
        return ChatCardShell(icon: "checkmark.shield", title: approvalTitle, tone: .orange) {
            if !purpose.isEmpty {
                Text(verbatim: purpose).font(.subheadline).foregroundStyle(ChatColors.ink)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
            if let note, note != purpose {
                Text(verbatim: note).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(3)
            }
            if !code.isEmpty {
                if !purpose.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showCode.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isCommand ? "查看命令" : "查看文件位置")
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showCode ? 180 : 0))
                        }.font(.footnote).foregroundStyle(ChatColors.muted).frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("approvalShowCode")
                }
                if purpose.isEmpty || showCode {
                    ScrollView {
                        (isCommand ? Text(verbatim: "$ ").foregroundStyle(ChatColors.muted) + Text(verbatim: code) : Text(verbatim: code))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(ChatColors.ink)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }.frame(maxHeight: 148).fixedSize(horizontal: false, vertical: true)
                        .background(ChatColors.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5))
                }
            }
            HStack(spacing: 12) {
                Button { submit("rejected", value: "rejected") } label: {
                    busyLabel(String(localized: "不允许"), busy: busy == "rejected").frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(.bordered).tint(ChatColors.muted)
                Button { submit("allowed-once", value: "allowed-once") } label: {
                    busyLabel(String(localized: "允许这一次"), busy: busy == "allowed-once").frame(maxWidth: .infinity, minHeight: 32)
                }.prominentButton()
            }.padding(.top, 6)
            Button("这个对话都允许") { confirmAll = true }
                .font(.footnote).foregroundStyle(ChatColors.muted)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .alert("这个对话都允许？", isPresented: $confirmAll) {
            Button("取消", role: .cancel) {}
            Button("这个对话都允许") { chat.setAutoApprove(true) }
        } message: { Text("这个对话之后的命令和改动都不再问你，可在输入框上方随时关闭。") }
    }

    @ViewBuilder private func busyLabel(_ title: String, busy: Bool) -> some View {
        if busy { ProgressView().controlSize(.small) } else { Text(title) }
    }

    // MARK: Questions

    private func complete(_ q: Object) -> Bool {
        let id = q["id"] as? String ?? ""
        return !choices[id, default: []].isEmpty || !(custom[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var questionCard: some View {
        ChatCardShell(icon: "questionmark.bubble", title: questions.count > 1 ? String(localized: "有 \(questions.count) 个问题想问你") : String(localized: "有个问题想问你"), tone: .accentColor) {
            ForEach(questions.indices, id: \.self) { i in
                questionBlock(questions[i], index: questions.count > 1 ? i + 1 : nil)
                    .padding(.top, i > 0 ? 14 : 0)
            }
            HStack(spacing: 12) {
                Button { decline() } label: {
                    busyLabel(String(localized: "不回答"), busy: busy == "declined").frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(.bordered).tint(ChatColors.muted)
                Button { answer() } label: {
                    busyLabel(String(localized: "发送回答"), busy: busy == "answer").frame(maxWidth: .infinity, minHeight: 32)
                }.prominentButton()
                    .disabled(questions.isEmpty || !questions.allSatisfy(complete))
            }.padding(.top, 8)
        }
    }

    @ViewBuilder private func questionBlock(_ q: Object, index: Int?) -> some View {
        let id = q["id"] as? String ?? ""
        let multi = q["multiSelect"] as? Bool == true
        let options = (q["options"] as? [Object] ?? []).compactMap { option -> (label: String, detail: String?)? in
            guard let label = option["label"] as? String else { return nil }
            return (label, option["description"] as? String)
        }
        let header = (q["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let eyebrow = [index.map(String.init), header?.isEmpty == false ? header : nil, multi ? String(localized: "可多选") : nil].compactMap { $0 }
        let allowsCustom = (q["intent"] as? Object)?["kind"] as? String != "approval"
        let showField = allowsCustom && (options.isEmpty || customOpen[id] == true)
        VStack(alignment: .leading, spacing: 4) {
            if !eyebrow.isEmpty {
                Text(eyebrow.joined(separator: " · ")).font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(ChatColors.muted)
            }
            Text(verbatim: q["question"] as? String ?? id).font(.body).foregroundStyle(ChatColors.ink)
            if let detail = (q["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                ChatAnswer(text: detail, font: .subheadline).foregroundStyle(ChatColors.muted)
            }
            ForEach(options.indices, id: \.self) { o in
                let option = options[o]
                let selected = choices[id, default: []].contains(option.label)
                Button {
                    if multi {
                        if selected { choices[id]?.remove(option.label) } else { choices[id, default: []].insert(option.label) }
                    } else {
                        choices[id] = [option.label]
                        if !options.isEmpty { custom[id] = ""; customOpen[id] = false }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(selected ? Color.accentColor : ChatColors.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: option.label).foregroundStyle(ChatColors.ink)
                            if let detail = option.detail, !detail.isEmpty {
                                Text(verbatim: detail).font(.caption).foregroundStyle(ChatColors.muted)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if allowsCustom && !options.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { customOpen[id] = !(customOpen[id] ?? false) }
                } label: {
                    Label("其他回答", systemImage: "plus").font(.subheadline)
                }.buttonStyle(.borderless).padding(.top, 2)
            }
            if showField {
                TextField("输入你的回答", text: Binding(get: { custom[id] ?? "" }, set: {
                    custom[id] = $0
                    if !multi, !$0.isEmpty, !options.isEmpty { choices[id] = [] }
                }), axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(ChatColors.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.6))
                .padding(.top, 6)
            }
        }
    }

    private func answer() {
        let answers: [Object] = questions.compactMap { q in
            guard let id = q["id"] as? String else { return nil }
            let picked = choices[id, default: []]
            let labels = (q["options"] as? [Object] ?? []).compactMap { $0["label"] as? String }
            var answer: Object = ["id": id, "selected": labels.filter(picked.contains)]
            if let text = custom[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { answer["custom"] = text }
            return answer
        }
        submit("answer", outcome: ["kind": "result", "value": ["answers": answers]])
    }

    private func decline() {
        submit("declined", outcome: ["kind": "rejected", "error": ["name": "UserQuestionError", "message": "declined"]])
    }

    private func submit(_ tag: String, value: Any) {
        submit(tag, outcome: ["kind": "result", "value": value])
    }

    private func submit(_ tag: String, outcome: Object) {
        guard let id = event["eventId"] as? String else { return }
        busy = tag
        Task {
            await chat.answer(id, outcome: outcome)
            busy = nil
        }
    }
}
