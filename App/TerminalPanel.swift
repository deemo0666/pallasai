import SwiftUI
import SwiftTerm
#if os(macOS)
import AppKit
#endif

@MainActor
final class ShellAttachment: ObservableObject {
    @Published var terminals: [Object] = []
    @Published var active: String?
    @Published var notice: String?
    let screen = TerminalView(frame: .zero)
    private var socket: HarnessChannel?
    private var pending: [Object] = []
    private var index = 0
    private var ack = 0
    @Published private(set) var writable = false
    @Published private(set) var shells: [Object] = []
    @Published private(set) var cwd = ""
    @Published private(set) var state = ""
    @Published private(set) var creating = false
    /// The terminal whose link dropped, offered for 重新连接.
    @Published var lost: String?
    @Published private(set) var exitCode: Int?
    /// Sticky Ctrl / Alt of the key row: a tap arms one for the next key, a long press locks it.
    enum Modifier { case off, armed, locked }
    @Published var ctrl = Modifier.off
    @Published var alt = Modifier.off
    private var retained: [String: HarnessChannel] = [:]
    private var selectionGeneration = 0
    private var maxInput = 65536
    private var maxQueued = 262144
    private var preferredSize: (cols: Int, rows: Int)?
    private var frameLimit = Int.max
    private var queuedBytes = 0
    private var closed = false

    func prepare(_ host: Harness) async {
        closed = false
        await refresh(host)
        do {
            let env = try await host.rpc("terminal/environment", args: ["agentId": host.sessionID])
            cwd = env["cwd"] as? String ?? ""
            maxInput = max(1, env["maxInputBytes"] as? Int ?? maxInput)
            maxQueued = max(1, env["maxBufferedBytes"] as? Int ?? maxQueued)
            shells = try await host.rpcValue("terminal/shells", args: ["agentId": host.sessionID]) as? [Object] ?? []
        } catch { notice = error.localizedDescription }
    }

    func rename(_ host: Harness, id: String, title: String) async {
        do {
            _ = try await host.rpcValue("terminal/rename", args: ["agentId": host.sessionID, "id": id, "title": title])
            await refresh(host)
        } catch { notice = error.localizedDescription }
    }

    func finish() {
        closed = true
        detach()
        for link in retained.values { link.cancel() }
        retained.removeAll()
    }
    private var sender: Task<Void, Never>?

    func refresh(_ host: Harness) async {
        do { terminals = try await host.rpcValue("terminal/list", args: ["sessionId": host.sessionID]) as? [Object] ?? [] }
        catch { notice = error.localizedDescription }
    }
    func create(_ host: Harness, shellPath: String? = nil) async {
        guard !creating, !closed else { return }
        creating = true
        let generation = selectionGeneration
        do {
            let id = UUID().uuidString
            var request: Object = ["id": id, "cols": 80, "rows": 24]
            if let shellPath { request["shellPath"] = shellPath }
            _ = try await host.rpc("terminal/create", args: ["agentId": host.sessionID, "request": request])
            guard generation == selectionGeneration, !closed else { creating = false; return }
            await refresh(host)
            creating = false
            await attach(host, id: id)
        } catch { creating = false; notice = error.localizedDescription }
    }
    func destroy(_ host: Harness, id: String) async {
        do {
            _ = try await host.rpcValue("terminal/close", args: ["agentId": host.sessionID, "id": id])
            retained.removeValue(forKey: id)?.cancel()
            if active == id { detach() }
            await refresh(host)
        } catch { notice = error.localizedDescription }
    }
    func detach() {
        selectionGeneration += 1
        state = ""; exitCode = nil; queuedBytes = 0; frameLimit = Int.max
        socket?.cancel()
        socket = nil
        sender?.cancel(); sender = nil
        active = nil; writable = false; index = 0; ack = 0; pending = []
    }
    func attach(_ host: Harness, id: String) async {
        guard !closed else { return }
        detach()
        let generation = selectionGeneration
        active = id
        lost = nil
        notice = nil
        do {
            if retained[id] == nil {
                let hold = try await host.stream("terminal/retain", args: ["sessionId": host.sessionID, "id": id])
                guard generation == selectionGeneration else { hold.cancel(); return }
                retained[id] = hold
                do {
                    let first = try await hold.next()
                    guard first["type"] as? String == "retained" else { throw HostError(String(localized: "终端没有打开成功，请重试。")) }
                    Task { [weak self] in
                        _ = try? await hold.next()
                        if self?.retained[id] === hold { self?.retained.removeValue(forKey: id) }
                    }
                } catch {
                    if retained[id] === hold { retained.removeValue(forKey: id) }
                    hold.cancel()
                    throw error
                }
            }
            guard generation == selectionGeneration else { return }
            let link = try await host.stream("terminal/attach", args: ["agentId": host.sessionID, "id": id])
            guard generation == selectionGeneration else { link.cancel(); return }
            socket = link
            while socket === link {
                let frame = try await link.next()
                guard socket === link else { return }
                switch frame["type"] as? String {
                case "snapshot":
                    updateState(frame)
                    if let window = frame["inputWindow"] as? Object, let limit = window["maxBytes"] as? Int {
                        frameLimit = max(1, limit - (window["frameOverheadBytes"] as? Int ?? 0))
                    }
                    if let info = frame["info"] as? Object, let cols = info["cols"] as? Int, let rows = info["rows"] as? Int {
                        let target = preferredSize ?? (cols, rows)
                        screen.getTerminal().resize(cols: max(2, min(target.0, 1000)), rows: max(1, min(target.1, 500)))
                        if preferredSize != nil, target != (cols, rows) {
                            enqueue(["type": "resize", "cols": target.0, "rows": target.1])
                        }
                    }
                    screen.feed(text: "\u{001B}c" + (frame["screen"] as? String ?? ""))
                    screen.getTerminal().setCursorStyle(.steadyBlock)
                case "output": screen.feed(text: frame["data"] as? String ?? "")
                case "state": updateState(frame)
                case "ack":
                    ack = frame["sequence"] as? Int ?? ack
                    if frame["refusal"] != nil { notice = String(localized: "终端没有接受这次输入。") }
                    drain()
                default: break
                }
            }
        } catch {
            if generation == selectionGeneration {
                detach()
                if !closed, terminals.contains(where: { $0["id"] as? String == id }) { lost = id } else { notice = error.localizedDescription }
            }
        }
    }

    private func updateState(_ frame: Object) {
        writable = frame["writable"] as? Bool == true
        if let info = frame["info"] as? Object {
            state = info["state"] as? String ?? ""
            exitCode = (info["exitCode"] as? NSNumber)?.intValue
        }
        if !writable { pending.removeAll(); queuedBytes = 0 }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 1, rows > 0 else { return }
        preferredSize = (cols, rows)
        enqueue(["type": "resize", "cols": cols, "rows": rows])
    }

    /// Typed text with the armed Ctrl / Alt applied the way xterm encodes them; armed ones are used up.
    func typed(_ text: String) {
        var out = text
        if text.unicodeScalars.count == 1, ctrl != .off || alt != .off {
            if ctrl != .off, let scalar = text.unicodeScalars.first {
                let c = scalar.value
                let code: UInt32? = switch c {
                case 0x61...0x7a: c - 0x60
                case 0x41...0x5a: c - 0x40
                default: ["@": 0, " ": 0, "2": 0, "[": 0x1b, "3": 0x1b, "\\": 0x1c, "4": 0x1c, "]": 0x1d, "5": 0x1d,
                          "^": 0x1e, "~": 0x1e, "6": 0x1e, "_": 0x1f, "-": 0x1f, "/": 0x1f, "7": 0x1f, "?": 0x7f, "8": 0x7f][text]
                }
                if let code, let control = Unicode.Scalar(code) { out = String(Character(control)) }
            }
            if alt != .off { out = "\u{1B}" + out }
            if ctrl == .armed { ctrl = .off }
            if alt == .armed { alt = .off }
        }
        enqueue(["type": "write", "data": out])
    }

    /// The bytes of a cursor key, in the mode the program asked for.
    func cursor(_ key: Character) {
        let application = screen.getTerminal().applicationCursor
        typed((application ? "\u{1B}O" : "\u{1B}[") + String(key))
    }

    func enqueue(_ value: Object) {
        guard writable else { return }
        let cost = (value["data"] as? String)?.utf8.count ?? 32
        var sized = value
        sized["sequence"] = index + pending.count + 1
        guard cost <= maxInput, let encoded = try? JSONSerialization.data(withJSONObject: sized),
              encoded.count <= frameLimit else { notice = String(localized: "这次输入太长，请分段发送。"); return }
        guard pending.count < 1024, queuedBytes + cost <= maxQueued else { notice = String(localized: "终端输入队列已满。"); return }
        queuedBytes += cost
        pending.append(value)
        drain()
    }
    private func drain() {
        guard sender == nil, let link = socket, writable, index == ack, !pending.isEmpty else { return }
        var value = pending.removeFirst()
        queuedBytes -= (value["data"] as? String)?.utf8.count ?? 32
        index += 1
        value["sequence"] = index
        sender = Task {
            do { try await link.send(value) }
            catch { if socket === link { detach(); notice = String(localized: "无法发送终端输入。") }; return }
            guard socket === link else { return }
            sender = nil
            drain()
        }
    }

}

@MainActor
private struct ShellSurface {
    let shell: ShellAttachment
    let fontSize: Double
    func makeCoordinator() -> Delegate { Delegate(shell) }
    private func makeTerminal(_ delegate: Delegate) -> TerminalView {
        shell.screen.terminalDelegate = delegate
        return shell.screen
    }
    private func updateTerminal(_ view: TerminalView) {
        if view.font.pointSize != CGFloat(fontSize) { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
    @MainActor final class Delegate: NSObject, @preconcurrency TerminalViewDelegate {
        let shell: ShellAttachment
        init(_ shell: ShellAttachment) { self.shell = shell }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { shell.typed(String(decoding: data, as: UTF8.self)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { shell.resize(cols: newCols, rows: newRows) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme) else { return }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            // A remote shell cannot change the system pasteboard via an escape sequence.
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

#if os(macOS)
extension ShellSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView { makeTerminal(context.coordinator) }
    func updateNSView(_ view: TerminalView, context: Context) { updateTerminal(view) }
}
#else
extension ShellSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalView { makeTerminal(context.coordinator) }
    func updateUIView(_ view: TerminalView, context: Context) { updateTerminal(view) }
}
#endif

struct TerminalPanel: View {
    let host: Harness
    @StateObject private var shell = ShellAttachment()
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @State private var closing: String?
    @State private var renaming: String?
    @State private var title = ""
    @State private var shellPath = ""
    @State private var command = ""
    @State private var composing = false
    @State private var copied = false
    @FocusState private var enteringCommand: Bool

    private func savedTitle(_ id: String) -> String {
        shell.terminals.first { $0["id"] as? String == id }?["title"] as? String ?? ""
    }

    private func name(_ id: String) -> String {
        let title = savedTitle(id)
        return title.isEmpty ? String(localized: "终端") : title
    }

    var body: some View {
        VStack(spacing: 0) {
            if let note = shell.notice { Text(note).font(.callout).foregroundStyle(.red).padding(.horizontal).padding(.vertical, 4) }
            if let id = shell.active {
                HStack {
                    Button(String(localized: "终端列表")) { shell.detach(); Task { await shell.refresh(host) } }
                    Menu {
                        Button(String(localized: "新建终端")) { Task { await shell.create(host, shellPath: shellPath.isEmpty ? nil : shellPath) } }
                        ForEach(shell.terminals.indices, id: \.self) { i in
                            if let other = shell.terminals[i]["id"] as? String {
                                Button(shell.terminals[i]["title"] as? String ?? other) { Task { await shell.attach(host, id: other) } }
                            }
                        }
                    } label: { Label(String(localized: "切换终端"), systemImage: "rectangle.stack").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    Spacer()
                    Button { composing.toggle(); enteringCommand = composing } label: { Label(String(localized: "输入命令"), systemImage: "keyboard").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.disabled(!shell.writable)
                    Menu {
                        Button { if let text = shell.screen.getSelection() { PlatformPasteboard.copy(text); copied = true } } label: { Label(String(localized: "复制"), systemImage: "doc.on.doc") }
                        Button { if let text = PlatformPasteboard.text { shell.enqueue(["type": "write", "data": text]) } } label: { Label(String(localized: "粘贴"), systemImage: "doc.on.clipboard") }
                            .disabled(!shell.writable)
                        Button("Ctrl-C") { shell.enqueue(["type": "write", "data": "\u{3}"]) }.disabled(!shell.writable)
                        Button { renaming = id; title = savedTitle(id) } label: { Label(String(localized: "重命名"), systemImage: "pencil") }
                        Button(role: .destructive) { closing = id } label: { Label(String(localized: "关闭终端"), systemImage: "xmark.circle") }
                    } label: { Label(String(localized: "更多"), systemImage: "ellipsis.circle").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                }.padding(.horizontal)
                if composing {
                    HStack {
                        TextField(String(localized: "命令"), text: $command).noAutomaticCapitalization().autocorrectionDisabled()
                            .focused($enteringCommand).textFieldStyle(.roundedBorder).onSubmit(sendCommand)
                        Button(String(localized: "执行"), action: sendCommand).disabled(command.isEmpty || !shell.writable)
                    }.padding(.horizontal).padding(.bottom, 6)
                }
                ShellSurface(shell: shell, fontSize: fontSize).accessibilityIdentifier("terminalScreen")
                bottomBar(id)
            } else {
                List {
                    if let id = shell.lost {
                        Section {
                            HStack {
                                Text(String(localized: "连接已断开")).foregroundStyle(ChatColors.muted)
                                Spacer()
                                Button(String(localized: "重新连接")) { Task { await shell.attach(host, id: id) } }
                            }
                        }
                    }
                    Section {
                        if !shell.cwd.isEmpty { LabeledContent(String(localized: "工作目录"), value: shell.cwd) }
                        if !shell.shells.isEmpty {
                            Picker(String(localized: "选择 Shell"), selection: $shellPath) {
                                Text(String(localized: "默认 Shell")).tag("")
                                ForEach(shell.shells.indices, id: \.self) { i in
                                    if let path = shell.shells[i]["path"] as? String {
                                        Text(shell.shells[i]["name"] as? String ?? path).tag(path)
                                    }
                                }
                            }
                        }
                        Stepper(String(localized: "终端字号 \(Int(fontSize))"), value: $fontSize, in: 9...26)
                        Button { Task { await shell.create(host, shellPath: shellPath.isEmpty ? nil : shellPath) } } label: {
                            Label(shell.creating ? String(localized: "正在打开终端…") : String(localized: "新建终端"), systemImage: "plus")
                        }.disabled(shell.creating).accessibilityIdentifier("newTerminal")
                    }
                    Section {
                        if shell.terminals.isEmpty { Text(String(localized: "没有打开的终端")).foregroundStyle(ChatColors.muted) }
                        ForEach(shell.terminals.indices, id: \.self) { i in
                            let row = shell.terminals[i]
                            if let id = row["id"] as? String {
                                if renaming == id {
                                    renameRow(id)
                                } else {
                                    Button { Task { await shell.attach(host, id: id) } } label: {
                                        HStack {
                                            Image(systemName: "terminal").foregroundStyle(ChatColors.muted)
                                            Text(row["title"] as? String ?? id).foregroundStyle(ChatColors.ink)
                                            Spacer()
                                            if row["state"] as? String == "exited" { Text(String(localized: "已结束")).font(.caption).foregroundStyle(ChatColors.muted) }
                                        }
                                    }.accessibilityIdentifier("terminalRow." + id)
                                    .contextMenu {
                                        Button(String(localized: "重命名")) { renaming = id; title = row["title"] as? String ?? "" }
                                        Button(String(localized: "关闭终端"), role: .destructive) { closing = id }
                                    }
                                    .swipeActions { Button(String(localized: "关闭终端"), role: .destructive) { closing = id } }
                                }
                            }
                        }
                    }
                }
            }
        }.task {
            await shell.prepare(host)
            guard !Task.isCancelled, shell.notice == nil else { return }
            if let row = shell.terminals.first(where: { $0["state"] as? String == "running" }) ?? shell.terminals.first, let id = row["id"] as? String {
                await shell.attach(host, id: id)
            } else { await shell.create(host) }
        }.onDisappear { shell.finish() }
        .confirmationDialog(closing.map { String(localized: "关闭「") + name($0) + String(localized: "」？") } ?? "", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { id in
            Button(String(localized: "关闭"), role: .destructive) { Task { await shell.destroy(host, id: id) } }
        } message: { _ in Text(String(localized: "里面的进程会结束")) }
        .alert(String(localized: "重命名终端"), isPresented: Binding(get: { renaming != nil && shell.active != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "终端名称"), text: $title)
            Button("保存") {
                if let id = renaming { let value = title; Task { await shell.rename(host, id: id, title: value) } }
                renaming = nil
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private func renameRow(_ id: String) -> some View {
        HStack {
            TextField(String(localized: "终端名称"), text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("terminalTitle")
            Button(String(localized: "保存")) {
                let value = title
                renaming = nil
                Task { await shell.rename(host, id: id, title: value) }
            }.buttonStyle(.borderless).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "取消")) { renaming = nil }.buttonStyle(.borderless)
        }
    }

    /// Under the screen: the key row while this phone types, else why it can't.
    @ViewBuilder private func bottomBar(_ id: String) -> some View {
        if shell.state == "exited" {
            statusBar(shell.exitCode.map { $0 == 0 ? String(localized: "已结束") : String(localized: "已结束 · 退出码 \($0)") } ?? String(localized: "已结束"), action: (String(localized: "新建终端"), {
                Task { await shell.create(host, shellPath: shellPath.isEmpty ? nil : shellPath) }
            }))
        } else if shell.writable {
            #if os(iOS)
            keyRow
            #else
            EmptyView()
            #endif
        } else if shell.state.isEmpty {
            statusBar(String(localized: "正在连接…"), action: nil)
        } else {
            statusBar(String(localized: "其他设备正在输入"), action: (String(localized: "接管"), { Task { await shell.attach(host, id: id) } }))
        }
        if copied { Text(String(localized: "已复制")).font(.caption).foregroundStyle(ChatColors.muted).task { try? await Task.sleep(for: .seconds(1.5)); copied = false } }
    }

    private func statusBar(_ label: String, action: (String, () -> Void)?) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(ChatColors.muted)
            Spacer()
            if let action { Button(action.0, action: action.1).buttonStyle(.bordered) }
        }.padding(.horizontal).padding(.vertical, 8).background(ChatColors.panel)
    }

    /// Esc, Tab, sticky Ctrl / Alt, arrows, | ~ / -.
    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("Esc") { shell.typed("\u{1B}") }
                key("Tab") { shell.typed("\t") }
                modifier("Ctrl", state: shell.ctrl) { shell.ctrl = $0 }
                modifier("Alt", state: shell.alt) { shell.alt = $0 }
                key("←") { shell.cursor("D") }
                key("↑") { shell.cursor("A") }
                key("↓") { shell.cursor("B") }
                key("→") { shell.cursor("C") }
                ForEach(["|", "~", "/", "-"], id: \.self) { text in key(text) { shell.typed(text) } }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.background(ChatColors.panel)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(.callout, design: .monospaced)).foregroundStyle(ChatColors.ink)
                .frame(minWidth: 40, minHeight: 34).background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ChatColors.line, lineWidth: 0.6))
        }.buttonStyle(.plain)
    }

    private func modifier(_ label: String, state: ShellAttachment.Modifier, set: @escaping (ShellAttachment.Modifier) -> Void) -> some View {
        let on = state != .off
        let fill: SwiftUI.Color = !on ? ChatColors.chip : state == .locked ? SwiftUI.Color.accentColor : SwiftUI.Color.accentColor.opacity(0.7)
        let next: ShellAttachment.Modifier = on ? .off : .armed
        let traits: AccessibilityTraits = on ? [.isButton, .isSelected] : .isButton
        return Text(label).font(.system(.callout, design: .monospaced).weight(on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : ChatColors.ink)
            .frame(minWidth: 44, minHeight: 34)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ChatColors.line, lineWidth: 0.6))
            .onTapGesture { set(next) }
            .onLongPressGesture { set(.locked) }
            .accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(traits)
            .accessibilityAction { set(next) }
    }

    private func sendCommand() {
        guard !command.isEmpty, shell.writable else { return }
        shell.enqueue(["type": "write", "data": command + "\r"])
        command = ""
        composing = false
        enteringCommand = false
    }
}
