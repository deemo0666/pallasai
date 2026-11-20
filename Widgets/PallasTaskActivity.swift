import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island views of a phone-control turn.
struct PallasTaskActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PallasTaskAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill")
                    Text(verbatim: context.attributes.header).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(verbatim: context.attributes.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                TaskStepView(state: context.state)
            }
            .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "hand.tap.fill").font(.title3).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(verbatim: context.attributes.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: context.attributes.header).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TaskStepView(state: context.state).padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "hand.tap.fill")
            } compactTrailing: {
                if context.state.asking != nil {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView(value: context.state.progress).progressViewStyle(.circular).frame(width: 18, height: 18)
                }
            } minimal: {
                Image(systemName: context.state.asking == nil ? "hand.tap.fill" : "questionmark.circle.fill")
            }
        }
    }
}

/// The step and progress, or the question with 允许 / 不允许.
private struct TaskStepView: View {
    let state: PallasTaskAttributes.ContentState

    var body: some View {
        if let asking = state.asking {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: asking).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 10) {
                    Button(intent: DenyStepIntent()) {
                        Text("不允许").frame(maxWidth: .infinity)
                    }
                    .tint(.gray)
                    Button(intent: AllowStepIntent()) {
                        Text("允许").frame(maxWidth: .infinity)
                    }
                    .tint(.blue)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: state.step).font(.body).lineLimit(1)
                ProgressView(value: state.progress).tint(.blue)
            }
        }
    }
}
