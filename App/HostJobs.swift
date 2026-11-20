import SwiftUI

/// One `job/list` entry. Jobs live in the host process's memory: a restart forgets them.
struct HostJob: Identifiable, Equatable {
    let id: String
    let kind: String
    /// Usually the command line.
    let label: String
    /// `running`, `stopping`, `completed`, `killed` or `failed`.
    let status: String
    let progress: String?
    let startedAt: Date?
    let finishedAt: Date?
    let outputBytes: Int

    var live: Bool { status == "running" || status == "stopping" }

    init?(_ raw: Any?) {
        guard let object = raw as? Object, let id = object["id"] as? String, !id.isEmpty else { return nil }
        func date(_ key: String) -> Date? { (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        self.id = id
        kind = object["kind"] as? String ?? "bash"
        label = object["label"] as? String ?? id
        status = object["status"] as? String ?? "running"
        progress = (object["progress"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        startedAt = date("startedAt")
        finishedAt = date("finishedAt")
        outputBytes = (object["output"] as? Object)?["total"] as? Int ?? 0
    }

    var statusLabel: String {
        switch status {
        case "running": String(localized: "运行中")
        case "stopping": String(localized: "正在停止")
        case "completed": String(localized: "已完成")
        case "killed": String(localized: "已停止")
        case "failed": String(localized: "失败")
        default: status
        }
    }

    var tone: Color {
        switch status {
        case "running", "stopping": .orange
        case "completed": .green
        case "failed": .red
        default: ChatColors.muted
        }
    }

    /// Status, time and progress, as under each job in DSH.
    func summary(now: Date = .now) -> String {
        var parts = [statusLabel]
        if let startedAt {
            let span = Self.span((finishedAt ?? now).timeIntervalSince(startedAt))
            parts.append(live ? String(localized: "已运行 ") + span : String(localized: "用时 ") + span)
        }
        if let progress { parts.append(progress.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return parts.joined(separator: " · ")
    }

    static func span(_ interval: TimeInterval) -> String {
        let ms = interval * 1000
        if ms < 0 { return String(localized: "0 秒") }
        if ms < 100 { return String(localized: "<0.1 秒") }
        if ms < 10_000 {
            let text = String(format: "%.1f", ms / 1000)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + String(localized: " 秒")
        }
        let seconds = Int((ms / 1000).rounded())
        if seconds < 60 { return String(localized: "\(seconds) 秒") }
        if seconds < 3600 { return String(localized: "\(seconds / 60) 分 ") + String(format: "%02d", seconds % 60) + String(localized: " 秒") }
        let minutes = seconds / 60
        return String(localized: "\(minutes / 60) 小时 ") + String(format: "%02d", minutes % 60) + String(localized: " 分")
    }
}

/// The last 1000 lines of a job's output with colour codes stripped. The line
/// still being written stays raw across chunks, so a line or an escape split
/// between two chunks comes out whole.
struct JobOutputBuffer {
    static let maxLines = 1000
    private static let maxLine = 4000
    private static let osc = try! NSRegularExpression(pattern: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)")
    private static let csi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    private(set) var complete: [String] = []
    private var partial = ""
    /// Earlier output was dropped, here or by the host.
    var trimmed = false

    var lines: [String] { partial.isEmpty ? complete : complete + [Self.clean(partial)] }
    var text: String { lines.joined(separator: "\n") }

    mutating func add(_ chunk: String) {
        var parts = (partial + chunk).components(separatedBy: "\n")
        partial = parts.removeLast()
        // A bare CR redraws the line (progress bars); a trailing one may be the first half of a CRLF.
        if partial.count > 1, let cr = partial.dropLast().lastIndex(of: "\r") {
            partial = String(partial[partial.index(after: cr)...])
        }
        if partial.count > Self.maxLine { partial = String(partial.prefix(Self.maxLine)) }
        complete.append(contentsOf: parts.map(Self.clean))
        let limit = partial.isEmpty ? Self.maxLines : Self.maxLines - 1
        if complete.count > limit { complete.removeFirst(complete.count - limit); trimmed = true }
    }

    static func strip(_ raw: String) -> String {
        var text = raw
        for pattern in [osc, csi] {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text
    }

    private static func clean(_ raw: String) -> String {
        var line = strip(raw)
        if line.hasSuffix("\r") { line.removeLast() }
        if let cr = line.lastIndex(of: "\r") { line = String(line[line.index(after: cr)...]) }
        return line.count > maxLine ? String(line.prefix(maxLine)) : line
    }
}

/// 后台任务: the open conversation's background jobs (`job/list`), grouped into
/// 进行中 and 已结束, each opening its streamed output.
struct HostJobsView: View {
    let host: Harness
    @Environment(\.scenePhase) private var scenePhase
    @State private var jobs: [HostJob]?
    @State private var issue: String?
    @State private var attempt = 0

    var body: some View {
        List {
            if let issue, jobs == nil {
                Section {
                    Text("没能读取后台命令").font(.headline)
                    Text(issue).font(.caption).foregroundStyle(ChatColors.muted)
                    Button("重试") { attempt += 1 }
                }.listRowBackground(ChatColors.chip)
            } else if let jobs {
                if jobs.isEmpty {
                    ContentUnavailableView("没有后台命令", systemImage: "terminal")
                        .listRowBackground(Color.clear).accessibilityIdentifier("jobsEmpty")
                }
                let live = jobs.filter(\.live), ended = jobs.filter { !$0.live }
                if !live.isEmpty { Section("进行中") { ForEach(live) { row($0) } }.listRowBackground(ChatColors.chip) }
                if !ended.isEmpty { Section("已结束 · \(ended.count)") { ForEach(ended) { row($0) } }.listRowBackground(ChatColors.chip) }
                if let issue { Text(String(localized: "列表已停止更新：") + issue).font(.caption).foregroundStyle(.red).listRowBackground(Color.clear) }
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .foregroundStyle(ChatColors.ink).scrollContentBackground(.hidden)
        .background(ChatColors.canvas.ignoresSafeArea())
        .task(id: "\(attempt)/\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await follow()
        }
    }

    private func row(_ job: HostJob) -> some View {
        NavigationLink { HostJobOutputView(host: host, job: job) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(job.tone).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: job.label).font(.system(.footnote, design: .monospaced)).lineLimit(3)
                    // Like DSH, the list shows the time as of its last update; the output page ticks.
                    Text(job.summary()).font(.caption)
                        .foregroundStyle(job.status == "failed" ? .red : ChatColors.muted)
                }
            }.padding(.vertical, 2)
        }.accessibilityIdentifier("hostJob-" + job.id)
    }

    /// `job/list` sends the whole set on every change.
    private func follow() async {
        do {
            let stream = try await host.stream("job/list", args: ["request": ["sessionId": host.sessionID]])
            defer { stream.cancel() }
            while !Task.isCancelled {
                let frame = try await stream.next()
                try Task.checkCancellation()
                guard let list = frame["jobs"] as? [Any] else { continue }
                jobs = list.compactMap(HostJob.init).sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
                issue = nil
            }
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }
}

/// One job's output (`job/follow`) with a confirmed stop (`job/kill`).
struct HostJobOutputView: View {
    let host: Harness
    @State var job: HostJob
    @State private var output = JobOutputBuffer()
    @State private var failed: String?
    @State private var confirmStop = false
    @State private var stopping = false
    @State private var notice: String?
    @State private var opened = false
    @State private var received = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(job.summary(now: context.date)).font(.caption).foregroundStyle(job.status == "failed" ? .red : ChatColors.muted)
                    }.accessibilityIdentifier("jobSummary").accessibilityLabel(job.statusLabel)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "$ " + job.label).font(.system(.footnote, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color(white: 0.92))
                        if output.trimmed { Text("最近 \(JobOutputBuffer.maxLines) 行").font(.caption2).foregroundStyle(Color(white: 0.6)) }
                        let lines = output.lines
                        if lines.isEmpty {
                            Text(failed != nil ? "没能读取输出" : job.live ? "等待输出…" : "没有输出")
                                .font(.system(.footnote, design: .monospaced)).foregroundStyle(Color(white: 0.6))
                                .accessibilityIdentifier("jobOutputEmpty")
                        } else {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(lines.indices, id: \.self) { index in
                                    Text(verbatim: lines[index].isEmpty ? " " : lines[index])
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(Color(white: 0.88))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.textSelection(.enabled).accessibilityIdentifier("jobOutput")
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.07, green: 0.08, blue: 0.10), in: RoundedRectangle(cornerRadius: 14))
                    if let failed { Text(failed).font(.caption).foregroundStyle(.red) }
                    if let notice { Text(notice).font(.caption).foregroundStyle(ChatColors.muted).accessibilityIdentifier("jobNotice") }
                    Color.clear.frame(height: 1).id("end")
                }.padding(16)
            }
            .onChange(of: received) { _, _ in if job.live { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .background(ChatColors.canvas.ignoresSafeArea())
        .navigationTitle("命令输出").inlineNavigationTitle()
        .toolbar {
            ToolbarItemGroup(placement: .screenTrailing) {
                if !output.lines.isEmpty { ShareLink(item: output.text, subject: Text("命令输出")) }
                if job.live {
                    Button(role: .destructive) { confirmStop = true } label: { Label("停止", systemImage: "stop.circle") }
                        .disabled(stopping).accessibilityIdentifier("stopJob")
                }
            }
        }
        .confirmationDialog("停止这个命令？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止", role: .destructive) { stop() }
            Button("取消", role: .cancel) {}
        } message: { Text(verbatim: job.label) }
        .task { await follow() }
    }

    /// `opened`, then output chunks from the earliest kept, then one `status` frame when the job ends.
    private func follow() async {
        do {
            let stream = try await host.stream("job/follow", args: ["request": ["sessionId": host.sessionID, "jobId": job.id]])
            defer { stream.cancel() }
            while !Task.isCancelled {
                let frame = try await stream.next()
                try Task.checkCancellation()
                switch frame["type"] as? String {
                case "opened":
                    if let first = HostJob(frame["job"]) { job = first }
                    opened = true
                case "output":
                    if frame["lossy"] as? Bool == true { output.trimmed = true }
                    for case let chunk as Object in frame["chunks"] as? [Any] ?? [] {
                        if chunk["gapBefore"] as? Bool == true { output.trimmed = true }
                        output.add(chunk["text"] as? String ?? "")
                    }
                    received += 1
                case "status":
                    if let ended = HostJob(frame["job"]) { job = ended }
                    if !job.live { stopping = false; notice = nil; return }
                default: continue
                }
            }
        } catch {
            // A finished job's stream may simply close after its output.
            if !Task.isCancelled, job.live || !opened { failed = error.localizedDescription }
        }
    }

    private func stop() {
        stopping = true; notice = nil
        Task {
            do {
                let reply = try await host.call("job/kill", ["sessionId": host.sessionID, "jobId": job.id])
                if reply["outcome"] as? String == "requested" { if job.live { notice = String(localized: "正在停止…") } }
                else { notice = String(localized: "命令已经结束了"); stopping = false }
            } catch {
                notice = String(localized: "没能停止：") + error.localizedDescription
                stopping = false
            }
        }
    }
}
