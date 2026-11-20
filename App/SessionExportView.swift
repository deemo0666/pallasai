import SwiftUI

// MARK: - 导出对话日志

struct SessionExportView: View {
    @ObservedObject var chat: Conversation
    let host: Harness
    private enum Action { case share, save }
    @State private var busy: Action?
    @State private var archive: URL?
    @State private var sharing = false
    #if os(iOS)
    @State private var saving = false
    #endif
    @State private var notice: String?
    @State private var failure: String?

    private var exporter: SessionLogExporting? { (host as AnyObject) as? SessionLogExporting }

    var body: some View {
        List {
            Section {
                row(.share, symbol: "square.and.arrow.up", title: String(localized: "分享"))
                row(.save, symbol: "square.and.arrow.down", title: String(localized: "存储到文件"))
            }
            .listRowBackground(ChatColors.chip)
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            if let notice { Section { Text(notice).accessibilityIdentifier("exportSaved") } }
        }.scrollContentBackground(.hidden).background(ChatColors.canvas.ignoresSafeArea())
        .sheet(isPresented: $sharing) { if let archive { ExportShareSheet(items: [archive]) } }
        #if os(iOS)
        .sheet(isPresented: $saving) {
            if let archive {
                ExportDocumentSaver(url: archive) { destination in
                    if let destination { notice = String(localized: "已存到「") + destination.lastPathComponent + String(localized: "」") }
                    saving = false
                }
            }
        }
        #endif
        .onDisappear { if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) } }
    }

    private func row(_ action: Action, symbol: String, title: String) -> some View {
        Button { run(action) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 26)
                Text(title).foregroundStyle(ChatColors.ink)
                Spacer()
                if busy == action { ProgressView() } else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(ChatColors.muted) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy != nil)
    }

    private func run(_ action: Action) {
        guard busy == nil else { return }
        busy = action; failure = nil; notice = nil
        Task {
            defer { busy = nil }
            do {
                guard let exporter else { throw HostError(String(localized: "没能导出"), code: "session-export/unavailable") }
                let file: URL
                if let archive { file = archive } else { file = try await exporter.exportSessionLog(host.sessionID); archive = file }
                if action == .share { sharing = true }
                else {
                    #if os(macOS)
                    if let destination = try await MacFileExport.save(file) {
                        notice = String(localized: "已存到「") + destination.lastPathComponent + String(localized: "」")
                    }
                    #else
                    saving = true
                    #endif
                }
            } catch {
                let code = (error as? HostError)?.code ?? ""
                failure = code == "session-export/http-404" ? String(localized: "找不到这个对话了") : code == "connection-closed" ? String(localized: "未连接") : String(localized: "没能导出")
            }
        }
    }
}

#if os(macOS)
struct ExportShareSheet: View {
    let items: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button("完成") { dismiss() }
            ShareLink(items: items)
        }.padding(24)
    }
}
#else
struct ExportShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ExportDocumentSaver: UIViewControllerRepresentable {
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
