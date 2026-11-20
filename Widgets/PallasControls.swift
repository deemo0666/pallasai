import AppIntents
import SwiftUI
import WidgetKit

@available(macOS 26.0, *)
struct AskPallasControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PallasAsk") {
            #if os(macOS)
            ControlWidgetButton(action: MacWidgetAskIntent()) {
                Label("问 Pallas", systemImage: "bubble.left.fill")
            }
            #else
            ControlWidgetButton(action: OpenURLIntent(PallasShared.askURL)) {
                Label("问 Pallas", systemImage: "bubble.left.fill")
            }
            #endif
        }
        .displayName("问 Pallas")
    }
}

#if os(macOS)
@available(macOS 26.0, *)
struct StopMacControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PallasStopMac") {
            ControlWidgetButton(action: MacWidgetEmergencyStopIntent()) {
                Label("停止操控 Mac", systemImage: "stop.circle.fill")
            }
        }
        .displayName("停止操控 Mac")
    }
}
#else
struct RecordScreenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PallasRecordScreen") {
            ControlWidgetButton(action: RecordScreenIntent()) {
                Label("Pallas 录屏", systemImage: "record.circle")
            }
        }
        .displayName("Pallas 录屏")
    }
}

struct StopPhoneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PallasStopPhone") {
            ControlWidgetButton(action: StopPhoneActivityIntent()) {
                Label("停下手机操控", systemImage: "stop.circle.fill")
            }
        }
        .displayName("停下手机操控")
    }
}
#endif
