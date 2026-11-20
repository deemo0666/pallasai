import SwiftUI
import WidgetKit

@main
struct PallasWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecentTaskWidget()
        #if os(macOS)
        if #available(macOS 26, *) {
            AskPallasWidget()
            AskPallasControl()
            StopMacControl()
        }
        #else
        // Its tap starts dictation, which needs iOS 26's on-device recognizer.
        if #available(iOS 26, *) {
            AskPallasWidget()
        }
        PallasTaskActivity()
        AskPallasControl()
        RecordScreenControl()
        StopPhoneControl()
        #endif
    }
}

