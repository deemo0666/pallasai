import Foundation

/// Where a settings row or search result leads.
enum SettingsTarget: String, Hashable, Identifiable {
    case account, chatGPT, claude, thirdParty, models, decisionAI, permission, memory
    case phone, phoneCall, webSearch, plugins, theme, textSize, foldTurns
    case interface, enterSends, quickPanel, tableTint, notifications, privacy, sharedLinks
    case remoteHosts, engine, engineParams, about, licenses, community
    case performance, engineStatus, diagnostics, language, folders, tailscale, connectors, observe
    var id: String { rawValue }
}

/// One entry of 搜索设置: a row, where it sits, and the words that find it.
struct SettingsSpot: Identifiable {
    let target: SettingsTarget
    let title: String
    let path: [String]
    let keywords: String
    var id: SettingsTarget { target }

    private static let root = String(localized: "设置")
    private static let accountPath = [root, String(localized: "账号与模型")]
    private static let abilityPath = [root, String(localized: "能力")]
    private static let chatPath = [root, String(localized: "对话")]
    private static let generalPath = [root, String(localized: "通用")]
    private static let advancedPath = [root, String(localized: "高级")]
    private static let helpPath = [root, String(localized: "帮助与关于")]

    private static let openSpots: [SettingsSpot] = [
        .init(target: .account, title: String(localized: "DeepSeek 账号"), path: accountPath, keywords: String(localized: "账号,余额,充值,登录,退出登录,API Key,用量,DeepSeek")),
        .init(target: .thirdParty, title: String(localized: "使用自己的 API Key"), path: accountPath, keywords: String(localized: "API Key,Base URL,OpenAI,Responses,接入,第三方接入,服务商,对话长度,上下文长度,第三方模型")),
        .init(target: .models, title: String(localized: "模型"), path: accountPath, keywords: String(localized: "模型服务,渠道,供应商,换模型,OpenRouter,ChatGPT,Claude,新对话默认")),
        .init(target: .remoteHosts, title: String(localized: "我的设备"), path: abilityPath, keywords: String(localized: "电脑,连接电脑,切换设备,远程,远程主机,主机,服务器,SSH,启动时连接,自动连接,iPad,iPhone,附近,配对,扫码,传文件,发文件,互传,AirDrop")),
        .init(target: .connectors, title: String(localized: "连接器"), path: abilityPath, keywords: String(localized: "连接器,邮件,邮箱,Gmail,Outlook,日历,提醒事项,通讯录,授权,账号,电脑访问")),
        .init(target: .webSearch, title: String(localized: "联网搜索"), path: abilityPath, keywords: String(localized: "搜索,上网,联网,API Key")),
        .init(target: .plugins, title: String(localized: "插件"), path: abilityPath, keywords: String(localized: "扩展,市场,安装插件,插件市场,导入插件")),
        .init(target: .memory, title: String(localized: "记忆"), path: abilityPath, keywords: String(localized: "记忆,记住,偏好,关于你,笔记,忘记,整理记忆")),
        .init(target: .folders, title: String(localized: "授权文件夹"), path: abilityPath, keywords: String(localized: "文件夹,文件,授权,访问文件,工作区")),
        .init(target: .permission, title: String(localized: "权限"), path: chatPath, keywords: String(localized: "权限,别问我,确认,审批,自动允许,只看不改,改动先问我,全部放行,AI 帮我把关,默认权限,系统权限,相机,麦克风,照片,本地网络,通知,日历,提醒事项,通讯录,授权,系统设置")),
        .init(target: .theme, title: String(localized: "外观"), path: [root], keywords: String(localized: "主题,配色,颜色,主题色,强调色,图标,深色,浅色,暗色,夜间,深色模式,跟随系统,壁纸,启动画面")),
        .init(target: .textSize, title: String(localized: "对话字号"), path: [root, String(localized: "外观")], keywords: String(localized: "字号,字体,文字大小,大字,字体大小")),
        .init(target: .foldTurns, title: String(localized: "完成后收起过程"), path: [root, String(localized: "外观")], keywords: String(localized: "收起,折叠,过程,步骤")),
        .init(target: .language, title: String(localized: "语言"), path: generalPath, keywords: String(localized: "语言,中文,英文,English,简体中文,Language")),
        .init(target: .interface, title: String(localized: "界面"), path: generalPath, keywords: String(localized: "界面,原生")),
        .init(target: .enterSends, title: String(localized: "外接键盘按 Enter 发送"), path: generalPath + [String(localized: "界面")], keywords: String(localized: "键盘,Enter,回车,发送,换行")),
        .init(target: .quickPanel, title: String(localized: "左滑快捷入口"), path: generalPath + [String(localized: "界面")], keywords: String(localized: "左滑,快捷入口,手势,滑动,目录,自定义目录,快捷,常用入口")),
        .init(target: .tableTint, title: String(localized: "表格底色"), path: generalPath + [String(localized: "界面")], keywords: String(localized: "表格,底色,表头,斑马纹,条纹,背景")),
        .init(target: .notifications, title: String(localized: "通知"), path: generalPath, keywords: String(localized: "提醒,推送,横幅,消息,铃声")),
        .init(target: .privacy, title: String(localized: "隐私与分享"), path: generalPath, keywords: String(localized: "隐私,数据,日志,分享,统计")),
        .init(target: .sharedLinks, title: String(localized: "我的分享链接"), path: generalPath + [String(localized: "隐私与分享")], keywords: String(localized: "分享链接,链接,公开链接,分享")),
        .init(target: .about, title: String(localized: "关于"), path: helpPath, keywords: String(localized: "关于,版本,版本号,许可,源代码,Apache-2.0,检查更新,Star,原作者")),
        .init(target: .licenses, title: String(localized: "第三方许可"), path: helpPath + [String(localized: "关于")], keywords: String(localized: "许可证,开源,License,第三方")),
        .init(target: .engine, title: String(localized: "本机运行"), path: advancedPath, keywords: String(localized: "本机,本机运行,本机引擎,引擎,关闭引擎,开启引擎,省电,内存")),
        .init(target: .engineStatus, title: String(localized: "本机运行状态"), path: advancedPath, keywords: String(localized: "运行状态,引擎状态,启动失败,没能启动,重新连接,切到本机,Node,运行时")),
        .init(target: .engineParams, title: String(localized: "运行参数"), path: advancedPath, keywords: String(localized: "引擎参数,引擎设置,高级,参数,子任务,子代理,命令执行,插件清单")),
        .init(target: .diagnostics, title: String(localized: "诊断"), path: advancedPath, keywords: String(localized: "诊断,报告,日志,错误,排查,复制")),
        .init(target: .performance, title: String(localized: "性能"), path: advancedPath, keywords: String(localized: "性能,刷新率,120Hz,高刷,模糊,毛玻璃,动效,动画,省电,发热,流畅")),
    ]

    static let all: [SettingsSpot] = openSpots + closedSpots
    private static let closedSpots: [SettingsSpot] = []

    /// Title matches first, then keyword matches, each in table order.
    static func hits(_ query: String, in spots: [SettingsSpot] = all) -> [SettingsSpot] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let titled = spots.filter { $0.title.localizedCaseInsensitiveContains(q) }
        let worded = spots.filter { spot in !titled.contains { $0.target == spot.target } && spot.keywords.localizedCaseInsensitiveContains(q) }
        return titled + worded
    }
}
