import QuickLook
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct HostDeliverable: Identifiable, Equatable {
    struct ID: Hashable { let sequence: Int; let index: Int }
    let id: ID
    let turn: Int
    let path: String
    let detail: String?
    let generated: Bool
    var fromReply = false

    private static let generatedTypes: Set<String> = ["html", "htm", "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "csv", "odt", "ods", "odp", "zip", "tar", "gz", "7z", "png", "jpg", "jpeg", "gif", "webp", "svg", "mp3", "wav", "m4a", "mp4", "mov", "webm"]

    var symbol: String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(ext) { return "photo" }
        if ["mp4", "mov", "webm"].contains(ext) { return "film" }
        if ["xls", "xlsx", "csv", "ods"].contains(ext) { return "tablecells" }
        if ["html", "htm"].contains(ext) { return "globe" }
        if ["zip", "7z", "gz", "tar"].contains(ext) { return "archivebox" }
        return "doc.text"
    }

    static func visible(_ candidates: [Self], finishedTurns: Set<Int>, workspace: String, steps: [ChatStep]) -> [Self] {
        let tools = Dictionary(grouping: steps.filter { $0.state == "ok" }) { step in
            Int(step.id.prefix(while: { $0 != "/" }))
        }
        let visible = candidates.filter { file in
            guard finishedTurns.contains(file.turn) else { return false }
            if !file.fromReply { return true }
            let prefix = workspace.hasSuffix("/") ? workspace : workspace + "/"
            let relative = file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
            guard !relative.isEmpty else { return false }
            let absolute = file.path.hasPrefix("/") ? file.path : prefix + relative
            let paths = [absolute, relative].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            let pattern = "(?<![\\w./-])(?:" + paths + ")(?![\\w./-])"
            return tools[file.turn]?.contains { step in
                [step.arguments, step.result].contains { $0.range(of: pattern, options: .regularExpression) != nil }
            } == true
        }
        let grouped = Dictionary(grouping: visible, by: \.turn)
        return grouped.keys.sorted(by: >).flatMap { turn -> [HostDeliverable] in
            let files = grouped[turn] ?? []
            let delivered = files.filter { !$0.generated }
            let candidates = (delivered.isEmpty ? files : delivered).sorted {
                if $0.id.sequence == $1.id.sequence { return $0.id.index < $1.id.index }
                return $0.id.sequence < $1.id.sequence
            }
            var positions: [String: Int] = [:]
            var normalized: [HostDeliverable] = []
            for file in candidates {
                let key = (file.path.hasPrefix("/") ? file.path : (workspace as NSString).appendingPathComponent(file.path)) as NSString
                if let index = positions[key.standardizingPath] {
                    if !file.fromReply { normalized[index] = file }
                } else { positions[key.standardizingPath] = normalized.count; normalized.append(file) }
            }
            return normalized
        }
    }

    static func files(in event: Object) -> [Self] {
        guard let seq = event["seq"] as? Int, let data = event["data"] as? Object,
              let turn = data["turn"] as? Int else { return [] }
        let generated: Bool
        let items: [Object]
        switch event["type"] as? String {
        case "assistant/message":
            guard let text = Message.assistant(event)?.text, text.contains("]("),
                  let rich = try? AttributedString(markdown: text) else { return [] }
            return rich.runs.enumerated().compactMap { index, run in
                guard let url = run.link, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      parts.scheme == nil || parts.scheme == "file", parts.host?.isEmpty != false, parts.query == nil,
                      !parts.path.isEmpty, !parts.path.hasPrefix("//"),
                      generatedTypes.contains((parts.path as NSString).pathExtension.lowercased()) else { return nil }
                return Self(id: ID(sequence: seq, index: index), turn: turn, path: parts.path, detail: nil, generated: true, fromReply: true)
            }
        case "deliverables/presented":
            generated = false
            items = data["files"] as? [Object] ?? []
        case "tool/result":
            guard let meta = data["meta"] as? Object, (data["message"] as? Object)?["isError"] as? Bool != true else { return [] }
            generated = true
            if meta["operation"] as? String == "create", let path = meta["path"] as? String,
                      generatedTypes.contains((path as NSString).pathExtension.lowercased()) {
                items = [["path": path]]
            } else { return [] }
        default: return []
        }
        return items.enumerated().compactMap { index, item in
            guard let path = item["path"] as? String, !path.isEmpty else { return nil }
            return Self(id: ID(sequence: seq, index: index), turn: turn, path: path,
                        detail: item["description"] as? String ?? item["mime"] as? String, generated: generated)
        }
    }
}

struct HostTurnFiles: View {
    let host: Harness
    let files: [HostDeliverable]
    @State private var opened: HostDeliverable?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(files.contains(where: { !$0.generated }) ? "交付了 \(files.count) 个文件" : "生成了 \(files.count) 个文件").font(.caption.weight(.medium)).foregroundStyle(ChatColors.muted)
            ForEach(files) { file in
                Button { opened = file } label: {
                    HStack {
                        Image(systemName: file.symbol).foregroundStyle(.tint)
                        Text((file.path as NSString).lastPathComponent).lineLimit(2)
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.chatCard().sheet(item: $opened) { file in
            NavigationStack {
                HostDeliverablePreview(host: host, file: file).toolbar { Button("完成") { opened = nil } }
            }
        }
    }
}

struct HostDeliverablesView: View {
    @ObservedObject var chat: Conversation
    let host: Harness
    @State private var error: String?
    @State private var attempt = 0
    @State private var loading = true

    var body: some View {
        List {
            Section {
                Text(chat.deliverables.isEmpty ? "还没有文件" : "\(chat.deliverables.count) 个文件")
                    .font(.subheadline).foregroundStyle(ChatColors.muted)
            }.listRowBackground(Color.clear)
            if loading { ProgressView("正在读取对话文件记录…") }
            if let error { Text(error); Button("重试") { attempt += 1 } }
            if !loading, error == nil, chat.deliverables.isEmpty {
                HostEmptyState(symbol: "doc.on.doc", title: String(localized: "还没有产出文件")).listRowBackground(Color.clear)
            }
            let groups = Dictionary(grouping: chat.deliverables, by: \.turn)
            ForEach(groups.keys.sorted(by: >), id: \.self) { turn in
                if let files = groups[turn], let first = files.first {
                    Section(String(localized: "第 \(turn) 轮 · ") + (first.generated ? String(localized: "生成") : String(localized: "交付"))) {
                        ForEach(files) { file in
                            NavigationLink {
                                HostDeliverablePreview(host: host, file: file)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: file.symbol).foregroundStyle(.tint)
                                        .frame(width: 34, height: 36).background(ChatColors.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((file.path as NSString).lastPathComponent)
                                        Text(file.detail ?? (file.path as NSString).pathExtension.uppercased()).font(.caption).foregroundStyle(ChatColors.muted)
                                    }
                                }
                            }
                        }
                    }.listRowBackground(ChatColors.chip)
                }
            }
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea()).task(id: attempt) {
            loading = true; error = nil
            defer { loading = false }
            do { try await chat.loadShareHistory() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private final class DownloadedDeliverable {
    let url: URL
    init(_ url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct HostDeliverablePreview: View {
    let host: Harness
    let file: HostDeliverable
    @State private var download: DownloadedDeliverable?
    @State private var error: String?
    @State private var attempt = 0
    @State private var preview: URL?
    #if os(iOS)
    @State private var exporting = false
    #endif
    @State private var savedName: String?

    var body: some View {
        List {
            Text(file.path).font(.callout.monospaced()).textSelection(.enabled)
            if let local = download?.url {
                #if os(iOS)
                if QLPreviewController.canPreview(local as NSURL) { Button("预览文件") { preview = local } }
                #else
                Button("预览文件") { preview = local }
                #endif
                Button { save(local) } label: { Label("存储到文件", systemImage: "square.and.arrow.down") }
                ShareLink(item: local) { Label("分享文件", systemImage: "square.and.arrow.up") }
                if let savedName { Text(String(localized: "已存储「") + savedName + String(localized: "」")).accessibilityIdentifier("deliverableSaved") }
                if let error { Text(error).foregroundStyle(.red) }
            } else if let error { Text(error); Button("重试") { attempt += 1 } }
            else { ProgressView("正在读取文件…") }
        }.navigationTitle((file.path as NSString).lastPathComponent).inlineNavigationTitle()
            .quickLookPreview($preview)
            #if os(iOS)
            .sheet(isPresented: $exporting) {
                if let url = download?.url {
                    DeliverableExporter(url: url) { destination in
                        savedName = destination?.lastPathComponent
                        exporting = false
                    }
                }
            }
            #endif
            .task(id: attempt) {
                guard download == nil else { return }
                error = nil
                do {
                    let received = try await DownloadedDeliverable(host.downloadWorkspaceFile(file.path))
                    try Task.checkCancellation()
                    download = received
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }

    }

    private func save(_ file: URL) {
        savedName = nil
        error = nil
        #if os(macOS)
        Task {
            do { savedName = try await MacFileExport.save(file)?.lastPathComponent }
            catch { self.error = error.localizedDescription }
        }
        #else
        exporting = true
        #endif
    }
}

#if os(iOS)
private struct DeliverableExporter: UIViewControllerRepresentable {
    let url: URL
    let finished: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: (URL?) -> Void
        init(finished: @escaping (URL?) -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished(urls.first) }
    }
}
#endif
