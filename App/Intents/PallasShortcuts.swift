import AppIntents

/// What Siri and Spotlight offer without any setup. Phrases are translated in `App/AppShortcuts.xcstrings`.
struct PallasShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskPallasIntent(), phrases: [
            "让\(.applicationName)办件事",
            "用\(.applicationName)办件事",
            "问\(.applicationName)",
            "让\(.applicationName)帮我",
            "让\(.applicationName)帮我做点事",
            "用\(.applicationName)帮我做点事",
            "\(.applicationName)帮我做件事",
        ], shortTitle: "让 Pallas 办", systemImageName: "sparkles")
        AppShortcut(intent: NewConversationIntent(), phrases: [
            "\(.applicationName)新对话",
            "在\(.applicationName)里开个新对话",
        ], shortTitle: "新对话", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenConversationIntent(), phrases: [
            "打开\(.applicationName)里的\(\.$target)",
            "在\(.applicationName)里打开\(\.$target)",
        ], shortTitle: "打开对话", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: GetLatestResultIntent(), phrases: [
            "\(.applicationName)办得怎么样了",
            "\(.applicationName)的结果",
        ], shortTitle: "最新结果", systemImageName: "checkmark.circle")
        #if os(macOS)
        AppShortcut(intent: StopMacControlIntent(), phrases: [
            "\(.applicationName)停止操控电脑",
            "让\(.applicationName)停下",
        ], shortTitle: "停止操控 Mac", systemImageName: "stop.circle")
        #endif
    }

    static let shortcutTileColor = ShortcutTileColor.grayBlue
}
