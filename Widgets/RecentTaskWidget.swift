import AppIntents
import SwiftUI
import WidgetKit

struct RecentTaskEntry: TimelineEntry {
    let date: Date
    let task: PallasRecentTask?
}

struct RecentTaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentTaskEntry {
        RecentTaskEntry(date: .now, task: PallasRecentTask(title: String(localized: "设置"), status: .done, step: "", updated: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (RecentTaskEntry) -> Void) {
        #if os(macOS)
        let task = recent ?? (context.isPreview ? placeholder(in: context).task : nil)
        #else
        let task = recent ?? placeholder(in: context).task
        #endif
        completion(RecentTaskEntry(date: .now, task: task))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentTaskEntry>) -> Void) {
        let entry = RecentTaskEntry(date: .now, task: recent)
        #if os(macOS)
        // Recheck a live entry if the app exits without sending a reload.
        let policy: TimelineReloadPolicy = entry.task?.status.live == true ? .after(entry.date.addingTimeInterval(60)) : .never
        #else
        let policy: TimelineReloadPolicy = .never
        #endif
        completion(Timeline(entries: [entry], policy: policy))
    }

    private var recent: PallasRecentTask? {
        #if os(macOS)
        PallasShared.displayRecent()
        #else
        PallasShared.readRecent()
        #endif
    }
}

/// Home Screen (small, medium) and Lock Screen (rectangular): the latest task and its state.
struct RecentTaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PallasShared.recentKind, provider: RecentTaskProvider()) { entry in
            RecentTaskView(task: entry.task).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("最近一件事")
        .supportedFamilies(families)
    }

    private var families: [WidgetFamily] {
        #if os(macOS)
        [.systemSmall, .systemMedium]
        #else
        [.systemSmall, .systemMedium, .accessoryRectangular]
        #endif
    }
}

private extension PallasRecentTask.Status {
    var label: LocalizedStringKey {
        switch self {
        case .running: "进行中"
        case .asking: "等你确认"
        case .done: "已完成"
        case .stopped: "已停止"
        }
    }
    var symbol: String {
        switch self {
        case .running: "hand.tap.fill"
        case .asking: "questionmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .running: .blue
        case .asking: .orange
        case .done: .green
        case .stopped: .secondary
        }
    }
}

struct RecentTaskView: View {
    let task: PallasRecentTask?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(verbatim: task?.title ?? "Pallas Agent").font(.headline) } icon: { Image(systemName: task?.status.symbol ?? "sparkles") }
                if let task { Text(task.status.label).font(.subheadline) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(PallasShared.openURL)
        #endif
        case .systemMedium:
            HStack(alignment: .center, spacing: 12) {
                summary
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    primaryAction
                    Link(destination: PallasShared.openURL) { Label("打开", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity) }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .frame(width: 128)
            }
        default:
            summary.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(task == nil ? PallasShared.askURL : PallasShared.openURL)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        #if os(macOS)
        if let ticket = task?.mac?.stopTicket, task?.status.live == true {
            stopButton(MacWidgetStopIntent(ticket: ticket))
        } else {
            askLink
        }
        #else
        if task?.status.live == true {
            stopButton(StopPhoneActivityIntent())
        } else {
            askLink
        }
        #endif
    }

    private func stopButton(_ intent: some AppIntent) -> some View {
        Button(intent: intent) { Label("停下", systemImage: "stop.fill").frame(maxWidth: .infinity) }
            .tint(.red)
    }

    private var askLink: some View {
        Link(destination: PallasShared.askURL) { Label("问 Pallas", systemImage: "bubble.left.fill").frame(maxWidth: .infinity) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: task?.status.symbol ?? "sparkles").font(.title2).foregroundStyle(task?.status.tint ?? .blue)
            Spacer(minLength: 0)
            Text(verbatim: task?.title ?? "Pallas Agent").font(.headline).lineLimit(2)
            if let task {
                Text(task.status.label).font(.subheadline).foregroundStyle(task.status.tint)
                if task.status.live, !task.step.isEmpty {
                    Text(verbatim: task.step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("问 Pallas").font(.subheadline).foregroundStyle(.blue)
            }
        }
    }
}

/// One tap starts dictation in Pallas Agent.
struct AskPallasWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PallasAskVoice", provider: AskProvider()) { _ in
            #if os(macOS)
            Button(intent: MacWidgetAskIntent(dictation: true)) {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.title2)
                    Text("问 Pallas").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .containerBackground(.fill.tertiary, for: .widget)
            #else
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title2)
            }
            .widgetURL(PallasShared.voiceURL)
            .containerBackground(.fill.tertiary, for: .widget)
            #endif
        }
        .configurationDisplayName("问 Pallas")
        .supportedFamilies(families)
    }

    private var families: [WidgetFamily] {
        #if os(macOS)
        [.systemSmall]
        #else
        [.accessoryCircular]
        #endif
    }
}

struct AskProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
