// 系统日志：连接和本机引擎的每一步，排查「连不上、卡住」时用 Console 或
// `log show --predicate 'subsystem == "<bundle id>"'` 读。只记状态、原因和端口，
// 不记地址里的令牌、API Key 或对话内容。

import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dsh-local"
    /// 与主机的连接：建立、断开、事件流结束。
    static let connection = Logger(subsystem: subsystem, category: "connection")
    /// 本机引擎：启动、探测、重新监听、自动重连。
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// AI 打电话：拨号、接通、接管、挂断和出错的原因（不记号码以外的通话内容）。
    static let call = Logger(subsystem: subsystem, category: "call")

    /// A session ID short enough to read in a log, enough to tell sessions apart.
    static func session(_ id: String?) -> String {
        guard let id else { return "-" }
        let unique = id.hasPrefix("session-") ? id.dropFirst("session-".count) : Substring(id)
        return String(unique.prefix(8))
    }

    /// What an error was, without its message (which can carry an address).
    static func reason(_ error: Error) -> String {
        if let host = error as? HostError { return "HostError(" + (host.code ?? "-") + ")" }
        let ns = error as NSError
        return ns.domain + "(" + String(ns.code) + ")"
    }
}
