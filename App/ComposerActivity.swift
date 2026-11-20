import SwiftUI

enum SendHow { case normal, steer, interrupt, queue }

/// The modes the host reports for the current session.
struct SessionModes: Equatable {
    var preset: String?
    var plan: Bool

    init(_ values: Object? = nil) {
        preset = (values?["permissions"] as? Object)?["currentValue"] as? String
        plan = (values?["plan"] as? Object)?["active"] as? Bool == true
    }

    var risky: Bool { preset == "danger-full-access" || preset == "auto" }
    var title: String {
        if plan { return String(localized: "先列计划") }
        return preset.map { PermissionOption(value: $0).title } ?? String(localized: "权限")
    }
}

struct ComposerModeMenu: View {
    @ObservedObject var chat: Conversation
    let permissions: () -> Void
    @State private var changingPlan = false

    var body: some View {
        if !chat.botSession {
            let modes = chat.sessionModes
            Menu {
                Button(action: permissions) {
                    Label("权限", systemImage: "lock.shield")
                }.accessibilityIdentifier("plusPermission")
                Toggle(isOn: Binding(get: { chat.sessionModes.plan }, set: changePlan)) {
                    Label("先列计划再动手", systemImage: "list.bullet.clipboard")
                }.accessibilityIdentifier("plusPlanMode").disabled(changingPlan)
            } label: {
                HStack(spacing: 4) {
                    if modes.risky { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(verbatim: modes.title)
                }.font(.system(size: 12.5)).lineLimit(1)
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .background(ChatColors.muted.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel(modes.title).accessibilityIdentifier("composerModes")
        }
    }

    private func changePlan(_ on: Bool) {
        guard !changingPlan else { return }
        changingPlan = true
        Task {
            defer { changingPlan = false }
            await chat.setComposerPlan(on)
        }
    }
}

struct ComposerApprovalStatus: View {
    let stop: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield").foregroundStyle(.orange)
                Text("这个对话都允许")
                Button(action: stop) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain).accessibilityLabel("停止都允许")
            }.font(.caption.weight(.medium)).padding(.horizontal, 12).frame(height: 30).chatCapsule()
                .foregroundStyle(ChatColors.ink).accessibilityIdentifier("autoApprovePill")
            Spacer()
        }
    }
}

struct ComposerQueuedMessage: View {
    let text: String
    var starting = false
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text(starting ? "排队中 · 准备好就发送" : "排队中 · 本轮结束后发送")
                .font(.caption.weight(.medium))
            Text(verbatim: text).font(.caption).foregroundStyle(ChatColors.muted).lineLimit(1)
            Spacer(minLength: 0)
            if let cancel {
                Button(action: cancel) { Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("取消排队").accessibilityIdentifier("cancelQueuedMessage")
            }
        }.padding(.horizontal, 14).frame(height: 34).chatCapsule()
            .accessibilityElement(children: .contain).accessibilityIdentifier("queuedMessage")
    }
}

struct ComposerTodoList: View {
    let todos: [TodoItem]
    let running: Bool
    @Binding var expanded: Bool

    private func label(done: Int) -> String {
        if done == todos.count { return String(localized: "全部完成") }
        let working = todos.first { $0.status == "in_progress" }
        let current = working ?? todos.first { $0.status != "completed" }
        let prefix = running && working != nil ? String(localized: "正在：") : String(localized: "下一步：")
        return prefix + (current?.text ?? "")
    }

    var body: some View {
        let done = todos.filter { $0.status == "completed" }.count
        let fraction = todos.isEmpty ? 0 : Double(done) / Double(todos.count)
        let label = label(done: done)
        VStack(spacing: 0) {
            Button { withAnimation(Motion.collapseCurve) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").foregroundStyle(ChatColors.muted)
                    Text("\(done)/\(todos.count)").font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("· " + label).font(.subheadline).foregroundStyle(ChatColors.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Capsule().fill(ChatColors.muted.opacity(0.2)).frame(width: 44, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(done == todos.count ? Color.green.opacity(0.8) : Color.accentColor).frame(width: 44 * fraction, height: 4)
                        }
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(ChatColors.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(ChatColors.ink)
                .accessibilityLabel(String(localized: "待办 \(done)/\(todos.count)，") + label).accessibilityIdentifier("todoBar")
                .accessibilityAddTraits(expanded ? .isSelected : [])
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(todos) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.dashed" : "circle")
                                    .foregroundStyle(item.status == "completed" ? Color.green.opacity(0.8) : item.status == "in_progress" ? Color.accentColor : ChatColors.muted)
                                Text(verbatim: item.text).font(.subheadline.weight(item.status == "in_progress" ? .semibold : .regular))
                                    .foregroundStyle(item.status == "completed" ? ChatColors.muted : ChatColors.ink)
                                    .strikethrough(item.status == "completed", color: ChatColors.muted)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
                }.frame(maxHeight: 196)
                .transition(.reveal())
            }
        }
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct ComposerUsage: View {
    @ObservedObject var chat: Conversation
    let canCompact: Bool
    let compact: () -> Void

    var body: some View {
        List {
            Section("对话长度") {
                if let meter = chat.contextMeter, meter.window > 0 {
                    ProgressView(value: meter.fraction).tint(meter.fraction >= 0.6 ? .orange : .accentColor)
                    LabeledContent(meter.fraction >= 0.8 ? String(localized: "快满了") : String(localized: "已用"),
                                   value: "\(Int((meter.fraction * 100).rounded()))%")
                    Button("压缩对话", action: compact).disabled(!canCompact || chat.messages.isEmpty)
                        .accessibilityIdentifier("usageCompact")
                } else { Text("还没有用量").foregroundStyle(ChatColors.muted) }
            }.listRowBackground(ChatColors.chip)
            Section("本对话") {
                if !chat.modelName.isEmpty { LabeledContent(String(localized: "模型"), value: chat.modelName) }
                LabeledContent(String(localized: "消息"), value: String(localized: "\(chat.messages.count) 条"))
            }.listRowBackground(ChatColors.chip)
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
    }
}
