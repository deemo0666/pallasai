import SwiftUI

struct ToolFileChange: Codable {
    let path: String
    let before: String?
    let after: String

    init?(_ item: Object) {
        guard let path = item["path"] as? String, let after = item["newText"] as? String,
              item["oldText"] is NSNull || item["oldText"] is String else { return nil }
        self.path = ShareText.redacted(path)
        before = (item["oldText"] as? String).map(ShareText.redacted)
        self.after = ShareText.redacted(after)
    }

    init(path: String, before: String?, after: String) {
        self.path = path; self.before = before; self.after = after
    }

    private func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { result.removeLast() }
        return result
    }

    // Harness supplies individual contextual hunks. For larger inputs display both originals directly.
    var patch: [(prefix: String, text: String)]? {
        guard (before?.utf8.count ?? 0) + after.utf8.count <= 96 * 1024 else { return nil }
        let old = lines(before ?? ""), new = lines(after)
        guard old.count + new.count <= 1000 else { return nil }
        var removed = Set<Int>(), added = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): added.insert(index)
            }
        }
        var result: [(String, String)] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { result.append(("−", String(old[i]))); i += 1 }
            else if j < new.count, added.contains(j) { result.append(("+", String(new[j]))); j += 1 }
            else if i < old.count && j < new.count { result.append((" ", String(old[i]))); i += 1; j += 1 }
            else { return nil }
        }
        return result
    }

    /// Lines added and removed; without a computable patch, every old line is removed and every new one added.
    var stats: (added: Int, removed: Int) {
        if let patch { return (patch.filter { $0.prefix == "+" }.count, patch.filter { $0.prefix == "−" }.count) }
        return (lines(after).count, lines(before ?? "").count)
    }

    /// Diff lines for display: the patch, or every old line removed and every new one added.
    var displayLines: [(prefix: String, text: String)] {
        patch ?? (lines(before ?? "").map { ("−", String($0)) } + lines(after).map { ("+", String($0)) })
    }
}

struct ChatStep: Identifiable, Codable {
    let id: String
    var name: String
    var arguments: String
    var result: String
    var state: String
    var files: [ToolFileChange]?
    var images: [HostImage]?
    var sharedResult: String {
        let changes = (files ?? []).map { file in
            let body: String
            if let patch = file.patch { body = patch.map { $0.prefix + " " + $0.text }.joined(separator: "\n") }
            else { body = [file.before.map { String(localized: "更改前\n") + $0 }, String(localized: "更改后\n") + file.after].compactMap { $0 }.joined(separator: "\n") }
            return file.path + "\n" + body
        }
        return ([result] + changes).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var summary: String? {
        guard let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? Object else { return nil }
        if let path = args["file_path"] as? String { return (path as NSString).lastPathComponent }
        return (args["description"] ?? args["command"] ?? args["query"]) as? String
    }

    var openedPage: URL? {
        guard name == "browser_open", state == "ok",
              let fields = try? JSONDecoder().decode([String: String].self, from: Data(arguments.utf8)),
              let raw = fields["url"], !raw.contains("[已隐藏]"), let url = URL(string: raw), BrowserRoute.accepts(url) else { return nil }
        return url
    }
    func statusLabel(live: Bool) -> String {
        switch state {
        case "running": live ? String(localized: "进行中") : String(localized: "未收到结果")
        case "ok": String(localized: "完成")
        case "denied": String(localized: "已拒绝")
        case "cancelled": String(localized: "已取消")
        default: String(localized: "失败")
        }
    }

    var displayName: String {
        ["read_image": String(localized: "读取图片"), "read": String(localized: "读取文件"), "edit": String(localized: "修改文件"), "write": String(localized: "写入文件"), "apply_patch": String(localized: "修改文件"), "ask_user_question": String(localized: "提问"), "bash": String(localized: "运行命令"), "web_search": String(localized: "联网搜索"), "browser_open": String(localized: "打开网页"), "browser_read": String(localized: "读取网页"),
         "browser_click": String(localized: "点击网页元素"), "browser_type": String(localized: "填写网页"), "browser_back": String(localized: "网页后退"),
         "browser_run_js": String(localized: "执行网页脚本")][name] ?? (isKnownTool ? verb : readableName)
    }
}

// MARK: - Tool presentation

enum ToolKind { case command, edit, read, search, web, agent, todo, phone, computer, other }

enum ToolTone {
    case terminal, read, edit, search, web, agent, plan, neutral
    var color: Color {
        switch self {
        case .terminal: ChatColors.adaptive(0x4b5563, 0xb6bfcc)
        case .read: ChatColors.adaptive(0x2f6fd6, 0x7fa9f0)
        case .edit: ChatColors.adaptive(0xc26a12, 0xf0a65c)
        case .search: ChatColors.adaptive(0x7a4fd0, 0xb79af0)
        case .web: ChatColors.adaptive(0x0f8a8a, 0x5cc8c8)
        case .agent: ChatColors.adaptive(0x4b56d2, 0x9aa2f2)
        case .plan: ChatColors.adaptive(0x2f8a4a, 0x76c690)
        case .neutral: ChatColors.adaptive(0x6b7280, 0xa4acba)
        }
    }
}

extension ChatStep {
    static func tone(for name: String) -> ToolTone {
        switch name {
        case "bash", "pwsh", "job_output", "job_list", "job_kill": .terminal
        case "read", "read_image", "present", "browser_read": .read
        case "write", "edit", "str_replace_editor", "apply_patch": .edit
        case "grep", "glob": .search
        case "web_fetch", "web_search", "browser_open", "browser_click", "browser_type", "browser_back", "browser_run_js": .web
        case "subagent", "send_message", "interrupt_agent", "list_subagent_models", "workflow", "ralph", "skill": .agent
        case "todo_write", "create_goal", "get_goal", "update_goal", "ask_user_question": .plan
        case "iphone_screen", "iphone_calculator": .agent
        case "iphone_files", "authorized_files": .read
        case "session_search": .search
        default: .neutral
        }
    }

    static func symbol(for name: String) -> String {
        switch name {
        case "bash", "pwsh": "terminal"
        case "job_output", "job_list", "job_kill": "square.stack.3d.up"
        case "read": "doc.text"
        case "read_image": "photo"
        case "present": "shippingbox"
        case "write", "edit", "str_replace_editor", "apply_patch": "pencil"
        case "grep": "magnifyingglass"
        case "glob": "folder"
        case "web_fetch", "browser_open", "browser_read", "browser_click", "browser_type", "browser_back", "browser_run_js": "globe"
        case "web_search": "network"
        case "subagent", "send_message", "interrupt_agent", "list_subagent_models": "person.2"
        case "workflow", "ralph": "arrow.triangle.branch"
        case "skill": "wand.and.stars"
        case "todo_write": "checklist"
        case "create_goal", "get_goal", "update_goal": "target"
        case "ask_user_question": "questionmark.bubble"
        case "memory": "brain"
        case "iphone_screen": "iphone"
        case "iphone_calculator": "plus.forwardslash.minus"
        case "iphone_files", "authorized_files", "working_directory": "folder"
        case "lan_services": "wifi"
        case "apple_calendar": "calendar"
        case "apple_contacts": "person.crop.circle"
        case "compose_message": "message"
        case "session_search": "magnifyingglass"
        case "plugin_manager": "puzzlepiece.extension"
        case "mac_task": "desktopcomputer"
        case "claude_desktop", "claude_sessions": "sparkles"
        case "schedule_create", "schedule_edit", "schedule_list", "schedule_view": "calendar.badge.clock"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    var args: Object? { try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? Object }

    func arg(_ key: String) -> String? { args?[key] as? String }

    /// Names for the bundle identifiers a model is likely to open; anything else shows as 「打开 App」.
    private static let appNames: [String: String] = [
        "com.apple.mobilenotes": String(localized: "备忘录"), "com.apple.reminders": String(localized: "提醒事项"),
        "com.apple.mobilecal": String(localized: "日历"), "com.apple.mobilemail": String(localized: "邮件"),
        "com.apple.mobilesms": String(localized: "信息"), "com.apple.mobilephone": String(localized: "电话"),
        "com.apple.mobilesafari": String(localized: "Safari 浏览器"), "com.apple.preferences": String(localized: "设置"),
        "com.apple.mobileslideshow": String(localized: "照片"), "com.apple.camera": String(localized: "相机"),
        "com.apple.maps": String(localized: "地图"), "com.apple.weather": String(localized: "天气"),
        "com.apple.mobiletimer": String(localized: "时钟"), "com.apple.calculator": String(localized: "计算器"),
        "com.apple.documentsapp": String(localized: "文件"), "com.apple.appstore": "App Store",
        "com.apple.music": String(localized: "音乐"), "com.apple.podcasts": String(localized: "播客"),
        "com.apple.mobileaddressbook": String(localized: "通讯录"), "com.apple.shortcuts": String(localized: "快捷指令"),
        "com.apple.health": String(localized: "健康"), "com.apple.passbook": String(localized: "钱包"),
        "com.apple.voicememos": String(localized: "语音备忘录"), "com.apple.translate": String(localized: "翻译"),
        "com.apple.facetime": "FaceTime", "com.apple.findmy": String(localized: "查找"),
        "com.apple.stocks": String(localized: "股市"), "com.apple.ibooks": String(localized: "图书"),
        "com.apple.freeform": String(localized: "无边记"), "com.apple.journal": String(localized: "手记"),
        "com.tencent.xin": String(localized: "微信"), "com.tencent.mqq": "QQ",
        "com.alipay.iphoneclient": String(localized: "支付宝"), "com.taobao.taobao4iphone": String(localized: "淘宝"),
        "com.ss.iphone.ugc.aweme": String(localized: "抖音"), "com.xingin.discover": String(localized: "小红书"),
        "com.sina.weibo": String(localized: "微博"), "com.meituan.imeituan": String(localized: "美团"),
        "com.autonavi.amap": String(localized: "高德地图"), "com.jingdong.app.mall": String(localized: "京东"),
        "com.google.chrome.ios": "Chrome", "com.google.maps": String(localized: "Google 地图"),
        "com.google.gmail": "Gmail", "com.google.ios.youtube": "YouTube",
    ]

    /// The app an `iphone_screen` open names, as a person would say it; nil when only an unknown bundle identifier was given.
    var phoneAppName: String? {
        let given = (arg("app") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ((args?["bundleParts"] as? [Any])?.compactMap { $0 as? String } ?? []).joined(separator: ".")
        let looksLikeBundle = given.range(of: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
        if !given.isEmpty, !looksLikeBundle, !given.contains("[已隐藏]") { return given }
        for id in [parts, given] where !id.isEmpty {
            if let known = Self.appNames[id.lowercased()] { return known }
        }
        return nil
    }

    /// The tool's raw name made readable: no `mcp__` prefix, no underscores.
    var readableName: String {
        var text = name
        if text.hasPrefix("mcp__") { text = text.dropFirst(5).components(separatedBy: "__").joined(separator: " ") }
        return text.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Whether [verb] says what this tool does (anything else reads 「使用工具 · 名字」).
    var isKnownTool: Bool { !name.isEmpty && verb != Self.genericVerb }

    private static var genericVerb: String { String(localized: "使用工具") }

    /// The row's verb (「运行」「读取」「打开」「点按」…).
    var verb: String {
        if name == "str_replace_editor" {
            switch arg("command") { case "view": return String(localized: "读取"); case "create": return String(localized: "写入"); default: return String(localized: "编辑") }
        }
        switch name {
        case "": return Self.genericVerb
        case "bash", "pwsh": return String(localized: "运行")
        case "job_output": return String(localized: "查看后台任务")
        case "job_list": return String(localized: "后台任务")
        case "job_kill": return String(localized: "停止后台任务")
        case "read": return String(localized: "读取")
        case "read_image": return String(localized: "查看图片")
        case "present": return String(localized: "交付文件")
        case "write": return String(localized: "写入")
        case "edit": return String(localized: "编辑")
        case "apply_patch": return String(localized: "修改文件")
        case "grep": return String(localized: "搜索")
        case "glob": return String(localized: "查找文件")
        case "web_fetch": return String(localized: "打开网页")
        case "web_search": return String(localized: "联网搜索")
        case "browser_open": return String(localized: "打开网页")
        case "browser_read": return String(localized: "读取网页")
        case "browser_click": return String(localized: "点击网页元素")
        case "browser_type": return String(localized: "填写网页")
        case "browser_back": return String(localized: "网页后退")
        case "browser_run_js": return String(localized: "执行网页脚本")
        case "subagent", "subagent_fork": return String(localized: "子任务")
        case "send_message": return String(localized: "发消息给子任务")
        case "interrupt_agent": return String(localized: "打断子任务")
        case "list_subagent_models": return String(localized: "查看子任务可用的模型")
        case "workflow": return String(localized: "工作流")
        case "ralph": return String(localized: "循环任务")
        case "skill": return String(localized: "使用技能")
        case "todo_write": return String(localized: "更新待办")
        case "create_goal": return String(localized: "设定目标")
        case "get_goal": return String(localized: "查看目标")
        case "update_goal": return String(localized: "更新目标")
        case "ask_user_question": return String(localized: "提问")
        case "memory":
            switch arg("action") {
            case "add": return String(localized: "记住")
            case "remove": return String(localized: "删除记忆")
            case "patch": return String(localized: "更新记忆")
            default: return String(localized: "整理记忆")
            }
        case "mac_task": return String(localized: "在电脑上执行")
        case "claude_desktop": return String(localized: "交给 Mac 上的 Claude")
        case "claude_sessions": return String(localized: "查看 Mac 上的 Claude 会话")
        case "iphone_screen":
            switch arg("action") {
            case "open": return phoneAppName == nil ? String(localized: "打开 App") : String(localized: "打开")
            case "observe": return String(localized: "查看屏幕")
            case "tap": return String(localized: "点按")
            case "swipe": return String(localized: "滑动")
            case "type": return String(localized: "输入")
            case "navigate": return String(localized: "前往")
            default: return String(localized: "操作手机")
            }
        case "iphone_calculator":
            switch arg("action") {
            case "open": return String(localized: "打开计算器")
            case "press": return String(localized: "按计算器")
            default: return String(localized: "查看计算器")
            }
        case "iphone_files", "authorized_files":
            switch arg("action") {
            case "open": return String(localized: "打开文件")
            case "list": return String(localized: "查看文件夹")
            default: return String(localized: "查看授权文件夹")
            }
        case "lan_services":
            switch arg("action") {
            case "connect": return String(localized: "连接附近设备")
            case "advertise": return String(localized: "让附近设备找到本机")
            case "stop": return String(localized: "停止查找附近设备")
            default: return String(localized: "查找附近设备")
            }
        case "apple_calendar":
            switch arg("action") {
            case "add_event": return String(localized: "加到日历")
            case "add_reminder": return String(localized: "加提醒")
            case "list_reminders": return String(localized: "查看提醒事项")
            case "complete_reminder": return String(localized: "完成提醒")
            default: return String(localized: "查看日程")
            }
        case "apple_contacts": return String(localized: "查找联系人")
        case "compose_message": return arg("kind") == "email" ? String(localized: "写邮件") : String(localized: "写短信")
        case "session_search": return String(localized: "搜索历史对话")
        case "plugin_manager":
            switch arg("action") {
            case "install_bundle": return String(localized: "安装插件")
            case "remove_bundle": return String(localized: "移除插件")
            case "set_plugin", "set_bundle": return args?["enabled"] as? Bool == false ? String(localized: "停用插件") : String(localized: "启用插件")
            default: return String(localized: "查看插件")
            }
        case "schedule_create": return String(localized: "新建自动化任务")
        case "schedule_edit": return String(localized: "修改自动化任务")
        case "schedule_list", "schedule_view": return String(localized: "查看自动化任务")
        case "working_directory": return (arg("cd") ?? "").isEmpty ? String(localized: "查看当前文件夹") : String(localized: "切换文件夹")
        case "word_create", "excel_create", "ppt_create": return String(localized: "新建文档")
        case "word_update", "excel_update", "ppt_update": return String(localized: "修改文档")
        case "mcp__ocu__list_apps": return String(localized: "列出应用")
        case "mcp__ocu__get_app_state": return String(localized: "查看界面")
        case "mcp__ocu__click": return String(localized: "点击")
        case "mcp__ocu__type_text": return String(localized: "输入")
        case "mcp__ocu__set_value": return String(localized: "填写")
        case "mcp__ocu__press_key": return String(localized: "按键")
        case "mcp__ocu__scroll": return String(localized: "滚动")
        case "mcp__ocu__drag": return String(localized: "拖动")
        default:
            if name.hasPrefix("schedule_") { return String(localized: "自动化任务") }
            return Self.genericVerb
        }
    }

    var isTerminal: Bool { ["bash", "pwsh", "job_output"].contains(name) }
    var isFileTool: Bool { ["read", "write", "edit", "str_replace_editor", "read_image"].contains(name) }
    var path: String? { arg("file_path") ?? arg("path") }
    var command: String? { isTerminal ? arg("command") : nil }
    /// What the model said this command is for.
    var commandPurpose: String? {
        guard ["bash", "pwsh"].contains(name), let text = arg("description")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    var summaryIsCode: Bool {
        if ["bash", "pwsh"].contains(name) { return commandPurpose == nil }
        return ["read", "write", "edit", "str_replace_editor", "read_image", "grep", "glob", "job_output", "job_kill"].contains(name)
    }

    var kind: ToolKind {
        switch name {
        case "bash", "pwsh": .command
        case "write", "edit", "apply_patch": .edit
        case "str_replace_editor": arg("command") == "view" ? .read : .edit
        case "read", "read_image": .read
        case "grep", "glob": .search
        case "web_fetch", "web_search": .web
        case "subagent", "subagent_fork", "send_message", "interrupt_agent", "workflow", "ralph": .agent
        case "todo_write": .todo
        case "iphone_screen", "iphone_calculator": .phone
        case "mac_task", "claude_desktop", "claude_sessions": .computer
        default: .other
        }
    }

    /// Workspace paths without the workspace prefix.
    static func displayPath(_ path: String, workspace: String) -> String {
        let root = ShareText.redacted(workspace)
        guard !root.isEmpty else { return path }
        if path == root { return "." }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    /// One-line summary after the verb (command, path, pattern, query…).
    func summary(in workspace: String) -> String {
        func line(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        let args = self.args
        switch name {
        case "bash", "pwsh": return line(commandPurpose ?? arg("command") ?? "")
        case "present":
            if let files = args?["files"] as? [Object] {
                return files.compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }.joined(separator: String(localized: "、"))
            }
            return path.map { Self.displayPath($0, workspace: workspace) } ?? ""
        case "read", "write", "edit", "read_image", "str_replace_editor":
            return path.map { Self.displayPath($0, workspace: workspace) } ?? ""
        case "grep":
            let pattern = arg("pattern") ?? ""
            guard let place = arg("path"), !place.isEmpty else { return pattern }
            return pattern + " · " + Self.displayPath(place, workspace: workspace)
        case "glob": return arg("pattern") ?? ""
        case "web_fetch": return (arg("url") ?? "").replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        case "web_search": return arg("query") ?? ""
        case "todo_write": return (args?["todos"] as? [Any]).map { String(localized: "\($0.count) 项") } ?? ""
        case "job_output", "job_kill": return arg("job_id") ?? arg("id") ?? ""
        case "ask_user_question":
            return ((args?["questions"] as? [Object])?.first?["question"] as? String).map(line) ?? ""
        case "subagent", "send_message", "workflow", "ralph": return line(arg("description") ?? arg("prompt") ?? "")
        case "skill": return arg("name") ?? arg("skill") ?? ""
        case "memory": return line(arg("content") ?? arg("old_text") ?? "")
        case "mac_task": return line(arg("task") ?? "")
        case "claude_desktop": return line(arg("message") ?? "")
        case "iphone_screen":
            switch arg("action") {
            case "open": return phoneAppName ?? ""
            case "type": return line(arg("text") ?? "")
            case "navigate": return line(arg("goal") ?? "")
            default: return ""
            }
        case "iphone_calculator": return arg("action") == "press" ? (arg("keys") ?? "") : ""
        case "iphone_files", "authorized_files":
            let place = [arg("folder"), arg("path")].compactMap { $0 }.filter { !$0.isEmpty }
            if arg("action") == "open", let last = place.last { return (last as NSString).lastPathComponent }
            return place.joined(separator: "/")
        case "lan_services": return line(arg("name") ?? arg("host") ?? "")
        case "apple_calendar": return line(arg("title") ?? arg("query") ?? "")
        case "apple_contacts": return line(arg("query") ?? "")
        case "compose_message": return line((args?["to"] as? [String])?.joined(separator: ", ") ?? arg("to") ?? "")
        case "session_search": return line(arg("query") ?? arg("pattern") ?? arg("keyword") ?? "")
        case "plugin_manager": return ["list_plugins", "list_bundles"].contains(arg("action") ?? "") ? "" : line(arg("target") ?? "")
        case "schedule_create", "schedule_edit", "schedule_list", "schedule_view": return line(arg("title") ?? "")
        case "working_directory": return arg("cd").map { Self.displayPath($0, workspace: workspace) } ?? ""
        case "word_create", "excel_create", "ppt_create", "word_update", "excel_update", "ppt_update":
            return path.map { ($0 as NSString).lastPathComponent } ?? ""
        case "browser_open": return (arg("url") ?? "").replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        case "browser_type": return line(arg("text") ?? "")
        case "mcp__ocu__type_text", "mcp__ocu__set_value":
            return [arg("app"), (arg("text") ?? arg("value")).map(line)].compactMap { $0 }.joined(separator: " · ")
        case "mcp__ocu__press_key": return [arg("app"), arg("key")].compactMap { $0 }.joined(separator: " · ")
        case _ where name.hasPrefix("mcp__ocu__"): return arg("app") ?? ""
        default: break
        }
        // A tool with a verb of its own: the argument a person would recognise, if it has one.
        if isKnownTool {
            for key in ["description", "query", "title", "url", "file_path", "path", "pattern", "prompt"] {
                if let value = arg(key), !value.trimmingCharacters(in: .whitespaces).isEmpty { return line(value) }
            }
            return ""
        }
        // 「使用工具 · 名字」: the name, never a raw argument.
        return readableName
    }

    var prettyArguments: String {
        guard let args, let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return arguments }
        return String(decoding: data, as: UTF8.self)
    }

    /// New file content of `write` / `str_replace_editor create`.
    var writtenContent: String? {
        if name == "write" { return arg("content") }
        if name == "str_replace_editor", arg("command") == "create" { return arg("file_text") }
        return nil
    }

    /// The edits this call made: the host's `meta.diffs`, else the old/new text in the arguments.
    var fileChanges: [ToolFileChange] {
        if let files, !files.isEmpty { return files }
        guard let path else { return [] }
        if name == "edit", let old = arg("old_string"), let new = arg("new_string") { return [ToolFileChange(path: path, before: old, after: new)] }
        if name == "str_replace_editor", arg("command") == "str_replace", let old = arg("old_str"), let new = arg("new_str") {
            return [ToolFileChange(path: path, before: old, after: new)]
        }
        if let content = writtenContent { return [ToolFileChange(path: path, before: nil, after: content)] }
        return []
    }

    /// Edits shown as a diff: the host's hunks, else `edit` / `str_replace` old and new text (new files show as content).
    var diffChanges: [ToolFileChange] {
        if let files, !files.isEmpty { return files }
        return writtenContent == nil ? fileChanges : []
    }

    /// `+18 −4` for a successful edit.
    var diffCounts: (added: Int, removed: Int)? {
        guard state == "ok", kind == .edit else { return nil }
        let changes = fileChanges
        guard !changes.isEmpty else { return nil }
        return changes.reduce((0, 0)) { sum, change in (sum.0 + change.stats.added, sum.1 + change.stats.removed) }
    }
}

/// A tool call as the stream shows it.
struct ToolEntry: Identifiable {
    let id: UUID
    let step: ChatStep
    let status: ToolStatus
    var approval: Object?
}

/// 「操作手机 6 步 · 改了 2 个文件 · 读了 4 个文件」 for three or more consecutive calls.
enum ToolSummary {
    /// What the calls did, one phrase per kind of work.
    static func parts(_ entries: [ToolEntry]) -> [String] {
        var commands = 0, searches = 0, web = 0, agents = 0, todos = 0, phone = 0, computer = 0, other = 0
        var edited = Set<String>(), read = Set<String>()
        for entry in entries {
            let happened = ![.failed, .denied, .cancelled].contains(entry.status)
            let key = entry.step.path ?? "#" + entry.step.id
            switch entry.step.kind {
            case .command: commands += 1
            case .edit: if happened { edited.insert(key) }
            case .read: if happened { read.insert(key) }
            case .search: searches += 1
            case .web: web += 1
            case .agent: agents += 1
            case .todo: todos += 1
            case .phone: phone += 1
            case .computer: computer += 1
            case .other: other += 1
            }
        }
        var parts: [String] = []
        if phone > 0 { parts.append(String(localized: "操作手机 \(phone) 步")) }
        if computer > 0 { parts.append(String(localized: "电脑任务 \(computer) 个")) }
        if commands > 0 { parts.append(String(localized: "运行了 \(commands) 条命令")) }
        if !edited.isEmpty { parts.append(String(localized: "改了 \(edited.count) 个文件")) }
        if !read.isEmpty { parts.append(String(localized: "读了 \(read.count) 个文件")) }
        if searches > 0 { parts.append(String(localized: "搜索 \(searches) 次")) }
        if web > 0 { parts.append(String(localized: "联网 \(web) 次")) }
        if agents > 0 { parts.append(String(localized: "子任务 \(agents) 个")) }
        if todos > 0 { parts.append(String(localized: "更新了待办")) }
        if other > 0 { parts.append(String(localized: "其他操作 \(other) 步")) }
        return parts
    }

    static func label(_ entries: [ToolEntry]) -> (label: String, failed: Int) {
        let phrases = Self.parts(entries)
        let failed = entries.filter { $0.status == .failed }.count
        return (phrases.isEmpty ? String(localized: "做了 \(entries.count) 步操作") : phrases.joined(separator: " · "), failed)
    }

    /// The glyph of the summary's first segment.
    static func leadingTool(_ entries: [ToolEntry]) -> String {
        for kind in [ToolKind.phone, .computer, .command, .edit, .read, .search, .web, .agent, .todo, .other] {
            if let entry = entries.first(where: { $0.step.kind == kind }) { return entry.step.name }
        }
        return entries.first?.step.name ?? ""
    }
}

enum ChatFormat {
    /// `0.3 秒`、`4.2 秒`、`47 秒`、`1 分 05 秒`、`1 小时 02 分`.
    static func span(_ seconds: TimeInterval) -> String {
        let ms = Int((seconds * 1000).rounded())
        if ms < 0 { return String(localized: "0 秒") }
        if ms < 100 { return String(localized: "<0.1 秒") }
        if ms < 10000 {
            var text = String(format: "%.1f", Double(ms) / 1000)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + String(localized: " 秒")
        }
        let whole = Int((Double(ms) / 1000).rounded())
        if whole < 60 { return String(localized: "\(whole) 秒") }
        if whole < 3600 { return String(localized: "\(whole / 60) 分 ") + String(format: "%02d", whole % 60) + String(localized: " 秒") }
        let minutes = whole / 60
        return String(localized: "\(minutes / 60) 小时 ") + String(format: "%02d", minutes % 60) + String(localized: " 分")
    }

    /// `999` / `8.4K` / `43K` / `1.05M`.
    static func tokens(_ n: Int) -> String {
        func trim(_ text: String) -> String {
            guard text.contains(".") else { return text }
            var value = text
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
            return value
        }
        let sign = n < 0 ? "-" : "", value = abs(n)
        if value < 1000 { return sign + "\(value)" }
        if value < 1_000_000 {
            let k = Double(value) / 1000
            let text = trim(k >= 100 ? String(format: "%.0f", k) : String(format: "%.1f", k))
            if text != "1000" { return sign + text + "K" }
        }
        return sign + trim(String(format: "%.2f", Double(value) / 1_000_000)) + "M"
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Stream row anatomy (24 glyph column + 8 gap + text column)

enum StreamRow {
    static let lead: CGFloat = 24
    static let gap: CGFloat = 8
    static let indent: CGFloat = 32
    static let minHeight: CGFloat = 32
    static let brand = ChatColors.adaptive(0x4d6bfe, 0x8297fe)
    /// 行标签（动词、「思考」）：次级色 14 号，比回答安静一档。
    static let label = Font.system(size: 14)
    /// 行内细节（命令、路径、预览、实时窗口）：三级色 13 号。
    static let detail = Font.system(size: 13)
    static let code = Font.system(size: 12.5, design: .monospaced)
}

/// 动词和摘要之间的间隔：3 点的小圆点，两边各 6。
struct StreamDot: View {
    var body: some View {
        Circle().fill(ChatColors.tertiary).frame(width: 3, height: 3).padding(.horizontal, 6).accessibilityHidden(true)
    }
}

/// 思考的图形：两道交叉的轨道和一个中心点。
struct OrbitGlyph: View {
    var size: CGFloat = 15

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 16
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            for angle in [45.0, -45.0] {
                var orbit = context
                orbit.translateBy(x: center.x, y: center.y)
                orbit.rotate(by: .degrees(angle))
                let ring = Path(ellipseIn: CGRect(x: -7 * unit, y: -2.9 * unit, width: 14 * unit, height: 5.8 * unit))
                orbit.stroke(ring, with: .foreground, lineWidth: 1.25 * unit)
            }
            let dot = 0.95 * unit
            context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)), with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StreamChevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
            .foregroundStyle(ChatColors.tertiary)
            .rotationEffect(.degrees(open ? 180 : 0))
            .frame(width: 16, height: 16)
    }
}

/// Expanded content: a hairline on the glyph column's centre, content from the text column.
struct StreamThread<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(.leading, StreamRow.indent).frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                Rectangle().fill(ChatColors.line).frame(width: 1).padding(.vertical, 4).padding(.leading, StreamRow.lead / 2 - 0.5)
            }
    }
}

struct ToolGlyph: View {
    let name: String
    var size: CGFloat = 24
    var body: some View {
        let tone = ChatStep.tone(for: name)
        Image(systemName: ChatStep.symbol(for: name)).font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(ChatColors.tertiary)
            .frame(width: size, height: size)
            .frame(width: StreamRow.lead, height: StreamRow.lead)
            .accessibilityHidden(true)
    }
}

/// `+18 −4`; one side left out when zero (`+0` when both are).
struct DiffCountsText: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: 4) {
            if added > 0 || removed == 0 { Text(verbatim: "+\(added)").foregroundStyle(Color.green) }
            if removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(Color.red) }
        }.font(.system(size: 12, weight: .medium, design: .monospaced)).monospacedDigit()
        .accessibilityElement(children: .ignore).accessibilityLabel("新增 \(added) 行，删除 \(removed) 行")
    }
}

private extension ToolStatus {
    var label: String {
        switch self {
        case .running: String(localized: "进行中")
        case .awaitingApproval: String(localized: "等你确认")
        case .succeeded: String(localized: "完成")
        case .failed: String(localized: "失败")
        case .denied: String(localized: "已拒绝")
        case .cancelled: String(localized: "已取消")
        }
    }
}

/// The row's trailing status: 细弧 / 等你确认 / ✕ / 已拒绝 / 已取消 / diff stat. Running → done
/// draws a check that stays 0.9 s, then the row goes quiet; states crossfade (240ms).
struct ToolStatusTrail: View {
    let step: ChatStep
    let status: ToolStatus
    @State private var justDone = false

    private var key: String { justDone ? "done" : "\(status)" }

    var body: some View {
        ZStack(alignment: .trailing) {
            trail.id(key).transition(.opacity)
        }
        .animation(Motion.std(Motion.standard), value: key)
        .onChange(of: status) { old, new in
            guard old == .running, new == .succeeded, step.diffCounts == nil, !Motion.reduced else { return }
            justDone = true
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                justDone = false
            }
        }
    }

    @ViewBuilder private var trail: some View {
        switch status {
        case .running: QuietArc(size: 14).foregroundStyle(ChatColors.tertiary).frame(width: 16, height: 16)
        case .awaitingApproval: Text("等你确认").font(.caption).foregroundStyle(Color.orange)
        case .failed: Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.red)
        case .denied: Text("已拒绝").font(.caption).foregroundStyle(Color.orange)
        case .cancelled: Text("已取消").font(.caption).foregroundStyle(ChatColors.tertiary)
        case .succeeded:
            if justDone { DrawnCheck(size: 14).foregroundStyle(ChatColors.tertiary).frame(width: 16, height: 16) }
            else if let counts = step.diffCounts { DiffCountsText(added: counts.added, removed: counts.removed) }
        }
    }
}

/// One tool call: a 32pt line「▣ 运行 · <命令>」, tap to grow the detail well below.
struct ToolRowView: View {
    let step: ChatStep
    let status: ToolStatus
    var workspace = ""
    var host: Harness?
    var chat: Conversation?
    var approval: Object?
    var title: String?
    @State private var expanded = false

    private func tapped() {
        withAnimation(Motion.collapseCurve) { expanded.toggle() }
    }

    var body: some View {
        let summary = step.summary(in: workspace)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: tapped) {
                HStack(spacing: StreamRow.gap) {
                    ToolGlyph(name: step.name)
                    HStack(spacing: 0) {
                        Text(title ?? step.verb).font(StreamRow.label).foregroundStyle(ChatColors.secondary).lineLimit(1).layoutPriority(1)
                        if !summary.isEmpty && summary != title {
                            StreamDot()
                            Text(verbatim: summary)
                                .font(step.summaryIsCode ? StreamRow.code : StreamRow.detail)
                                .foregroundStyle(status == .failed ? Color.red : ChatColors.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 8)
                    ToolStatusTrail(step: step, status: status)
                }.frame(minHeight: StreamRow.minHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([title ?? step.verb, summary].filter { !$0.isEmpty }.joined(separator: " "))
                .accessibilityValue(status.label)
                .accessibilityAddTraits(.isButton)
            if step.name == "mac_task", status.active || expanded {
                MacTaskLiveView(task: step.arg("task") ?? "", stepID: step.id, sessionID: host?.sessionID, running: status.active)
            }
            if step.name == "claude_desktop", status.active || expanded {
                ClaudeDesktopLiveView(message: step.arg("message") ?? "", stepID: step.id, sessionID: host?.sessionID, running: status.active)
            }
            if expanded {
                ToolDetailWell(step: step, status: status, workspace: workspace, host: host)
                    .padding(.top, 4).padding(.bottom, 8)
                    .transition(.reveal())
            }
            if let approval, let chat {
                HostInteractionView(event: approval, chat: chat, step: step, workspace: workspace)
                    .padding(.vertical, 4)
                    .modifier(StreamEntrance(play: true))
                    .id(approval["eventId"] as? String)
            }
        }
    }
}

/// The detail well under a tool row: 命令 / 文件 / 参数, then 改动 / 内容 / 结果 / 输出 / 错误.
struct ToolDetailWell: View {
    let step: ChatStep
    let status: ToolStatus
    var workspace = ""
    var host: Harness?
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard
    @Environment(\.showChatBrowser) private var showBrowser

    private enum Part {
        case mono(String, prompt: Bool = false, error: Bool = false)
        case note(String)
        case diff([ToolFileChange])
        case images
    }

    private var sections: [(title: String, body: Part)] {
        var result: [(String, Part)] = []
        let trimmedArgs = step.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = step.command {
            if let purpose = step.commandPurpose { result.append((String(localized: "要做的事"), .note(purpose))) }
            result.append((String(localized: "命令"), .mono(command, prompt: true)))
        } else if step.isFileTool, let path = step.path {
            result.append((String(localized: "文件"), .mono(ChatStep.displayPath(path, workspace: workspace))))
        } else if !trimmedArgs.isEmpty && trimmedArgs != "{}" {
            result.append((String(localized: "细节"), .mono(step.prettyArguments)))
        }
        let resultTitle = String(localized: "结果")
        let text = step.result.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case .failed:
            result.append((String(localized: "出错原因"), .mono(text.isEmpty ? String(localized: "失败") : text, error: true)))
        case .succeeded:
            let changes = step.kind == .edit ? step.diffChanges : []
            if !changes.isEmpty {
                result.append((String(localized: "改动"), .diff(changes)))
            } else if let content = step.writtenContent, !content.isEmpty {
                result.append((String(localized: "内容"), .mono(content)))
            } else if !text.isEmpty {
                result.append((resultTitle, .mono(text)))
                if step.images?.isEmpty == false { result.append(("", .images)) }
            } else if step.images?.isEmpty == false {
                result.append((resultTitle, .images))
            } else {
                result.append((resultTitle, .note(String(localized: "没有返回内容"))))
            }
        case .denied:
            result.append((resultTitle, .note(String(localized: "你没有允许这一步"))))
        default: break
        }
        if result.isEmpty { result.append((String(localized: "状态"), .note(status.active ? String(localized: "正在执行…") : String(localized: "暂无详情")))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = step.openedPage, let showBrowser {
                Button("查看网页") { showBrowser(url) }.font(.subheadline).padding(.horizontal, 12).padding(.top, 10)
            }
            let all = sections
            ForEach(all.indices, id: \.self) { index in
                let section = all[index]
                if index > 0 && !section.title.isEmpty { Divider().overlay(ChatColors.line) }
                VStack(alignment: .leading, spacing: 4) {
                    if !section.title.isEmpty {
                        Text(section.title).font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(ChatColors.muted)
                    }
                    content(section.body)
                }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChatColors.line, lineWidth: 0.5))
    }

    @ViewBuilder private func content(_ body: Part) -> some View {
        switch body {
        case .mono(let text, let prompt, let error):
            ScrollView {
                (prompt ? Text(verbatim: "$ ").foregroundStyle(ChatColors.muted) + Text(verbatim: text) : Text(verbatim: text))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(error ? Color.red : ChatColors.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
        case .note(let text):
            Text(text).font(.footnote).foregroundStyle(ChatColors.muted)
        case .diff(let changes):
            ScrollView { DiffLinesView(changes: changes) }.frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
        case .images:
            if let host, let images = step.images { HostImageGallery(host: host, images: images) }
        }
    }
}

/// Line-level diff of one or more changes, with 「@@ 第 i/n 处修改 @@」 between them.
struct DiffLinesView: View {
    let changes: [ToolFileChange]
    var wrap = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(changes.indices, id: \.self) { index in
                if changes.count > 1 {
                    Text(verbatim: String(localized: "@@ 第 \(index + 1)/\(changes.count) 处修改 @@"))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ChatColors.muted)
                        .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                let lines = changes[index].displayLines
                ForEach(lines.indices, id: \.self) { i in
                    let line = lines[i]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: line.prefix == " " ? " " : line.prefix)
                            .foregroundStyle(line.prefix == "+" ? Color.green : line.prefix == "−" ? Color.red : ChatColors.muted)
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(ChatColors.ink)
                            .lineLimit(wrap ? nil : 1)
                            .fixedSize(horizontal: !wrap, vertical: true)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                    .background(line.prefix == "+" ? Color.green.opacity(0.12) : line.prefix == "−" ? Color.red.opacity(0.12) : Color.clear)
                }
            }
        }.textSelection(.enabled)
    }
}

/// Three or more consecutive calls: one summary line; the running ones stay visible below it.
struct ToolGroupView: View {
    let entries: [ToolEntry]
    var live = false
    var workspace = ""
    var host: Harness?
    var chat: Conversation?
    @State private var expanded = false

    var body: some View {
        let summary = ToolSummary.label(entries)
        let shown = entries.filter { $0.status.active || $0.approval != nil }
        let tail = shown.isEmpty && live ? Array(entries.suffix(1)) : shown
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.collapseCurve) { expanded.toggle() }
            } label: {
                HStack(spacing: StreamRow.gap) {
                    ToolGlyph(name: ToolSummary.leadingTool(entries))
                    Text(summary.label).font(StreamRow.label).foregroundStyle(ChatColors.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if summary.failed > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            Text(verbatim: "\(summary.failed)").font(.system(size: 12, weight: .medium, design: .monospaced))
                        }.foregroundStyle(Color.red)
                    }
                    StreamChevron(open: expanded)
                }.frame(minHeight: StreamRow.minHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.failed > 0 ? summary.label + String(localized: "，\(summary.failed) 个失败") : summary.label)
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .accessibilityAddTraits(.isButton)
            if expanded {
                StreamThread {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            ToolRowView(step: entry.step, status: entry.status, workspace: workspace, host: host, chat: chat, approval: entry.approval)
                        }
                    }
                }.transition(.reveal())
            } else {
                // The live batch under the summary: the rows swap with a short crossfade as calls start and end.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tail) { entry in
                        ToolRowView(step: entry.step, status: entry.status, workspace: workspace, host: host, chat: chat, approval: entry.approval)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.std(Motion.quick), value: tail.map(\.id))
                .transition(.reveal())
            }
        }
    }
}

/// The thinking row: 「思考中 · 0:12」 while it thinks, 「思考了 12 秒」 after. The reasoning itself only shows when the row is opened.
struct ThinkingRow: View {
    let text: String
    let active: Bool
    @State private var expanded = false
    /// When this row started thinking on screen, and how long it took; unknown for rows loaded from history.
    @State private var began: Date?
    @State private var took: TimeInterval?
    @AppStorage("chatTypeSize") private var typeSize = ChatTypeSize.standard

    private var title: String {
        if active { return String(localized: "思考中") }
        if let took { return String(localized: "思考了 \(ChatFormat.span(took))") }
        return String(localized: "思考")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.collapseCurve) { expanded.toggle() }
            } label: {
                HStack(spacing: StreamRow.gap) {
                    // 思考时的轨道图标 7.2 秒转一圈，停下时回正。
                    TimelineView(.animation(paused: !active || Motion.reduced)) { context in
                        let turn = active && !Motion.reduced ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 7.2) / 7.2 : 0
                        OrbitGlyph(size: 15).foregroundStyle(active ? StreamRow.brand : ChatColors.tertiary)
                            .rotationEffect(.degrees(turn * 360))
                    }
                        .frame(width: StreamRow.lead, height: StreamRow.lead)
                    HStack(spacing: 0) {
                        SweepLabel(text: title, active: active).font(StreamRow.label)
                        if active, let began {
                            StreamDot()
                            TimelineView(.periodic(from: began, by: 1)) { context in
                                Text(verbatim: ActivityStrip.clock(max(0, context.date.timeIntervalSince(began))))
                                    .font(StreamRow.detail).monospacedDigit().foregroundStyle(ChatColors.tertiary)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    StreamChevron(open: expanded)
                }.frame(minHeight: StreamRow.minHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .accessibilityAddTraits(.isButton)
            if expanded {
                StreamThread {
                    // The full text: the answer's type, 0.9× and in the secondary colour.
                    ChatAnswer(text: text.trimmingCharacters(in: .whitespacesAndNewlines), font: .system(size: 14.5))
                        .foregroundStyle(ChatColors.secondary).textSelection(.enabled)
                }.padding(.top, 4).padding(.bottom, 8)
                .transition(.reveal())
            }
        }
        .animation(Motion.collapseCurve, value: expanded)
        .onAppear { if active, began == nil { began = Date() } }
        .onChange(of: active) { old, new in
            if new, began == nil { began = Date() }
            if old && !new {
                if let began { took = Date().timeIntervalSince(began) }
                expanded = false
            }
        }
    }
}

/// A finished turn's process folded into one line:「已完成 · 操作手机 6 步 · 改了 2 个文件」.
struct TurnProcessView<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.collapseCurve) { expanded.toggle() }
            } label: {
                HStack(spacing: StreamRow.gap) {
                    Image(systemName: "checkmark.circle").font(.system(size: 17)).foregroundStyle(ChatColors.tertiary)
                        .frame(width: StreamRow.lead, height: StreamRow.lead)
                    Text(label).font(StreamRow.label).foregroundStyle(ChatColors.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    StreamChevron(open: expanded)
                }.frame(minHeight: StreamRow.minHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .accessibilityAddTraits(.isButton)
            if expanded {
                StreamThread { VStack(alignment: .leading, spacing: 0) { content() } }
                    .padding(.vertical, 4).transition(.reveal())
            }
        }
    }
}

/// Thinking and tool calls of one reply, used by the local chat and replays.
struct ChatStepsView: View {
    let thinking: String
    let steps: [ChatStep]
    let live: Bool
    var workspace = ""
    var host: Harness?

    private func status(_ step: ChatStep) -> ToolStatus {
        switch step.state {
        case "running": live ? .running : .cancelled
        case "ok": .succeeded
        case "denied": .denied
        case "cancelled": .cancelled
        default: .failed
        }
    }

    var body: some View {
        let entries = steps.enumerated().map { index, step in
            ToolEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID(), step: step, status: status(step))
        }
        VStack(alignment: .leading, spacing: 0) {
            if !thinking.isEmpty { ThinkingRow(text: thinking, active: live && steps.isEmpty) }
            if entries.count >= 3 {
                ToolGroupView(entries: entries, live: live, workspace: workspace, host: host)
            } else {
                ForEach(entries) { entry in
                    ToolRowView(step: entry.step, status: entry.status, workspace: workspace, host: host)
                }
            }
        }.padding(.vertical, 2)
    }
}

/// One tool call shown on its own (actions panel, replays).
struct ToolDetails: View {
    let step: ChatStep
    let live: Bool
    var workspace = ""
    var host: Harness?
    var title: String?

    var body: some View {
        let status: ToolStatus = switch step.state {
        case "running": live ? .running : .cancelled
        case "ok": .succeeded
        case "denied": .denied
        case "cancelled": .cancelled
        default: .failed
        }
        ToolRowView(step: step, status: status, workspace: workspace, host: host, title: title)
    }
}
