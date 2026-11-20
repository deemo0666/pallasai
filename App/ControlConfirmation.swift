import Foundation

/// Labels from the observed app are compared as data on both platforms.
enum ControlConfirmation {
    private static let sendIcons = ["↑", "⬆", "➤", "arrow.up", "paperplane", "paper plane"]

    /// Steps that also require device owner authentication in that mode.
    static func serious(_ label: String) -> Bool {
        let lower = label.lowercased()
        if sendIcons.contains(where: lower.contains) { return true }
        if ["发送", "发布", "发表", "删除", "移除", "清空", "支付", "付款", "转账", "购买", "下单", "提现", "充值", "订阅", "捐"]
            .contains(where: lower.contains) { return true }
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["send", "post", "publish", "delete", "remove", "erase", "pay", "purchase", "buy", "checkout",
                                    "transfer", "withdraw", "subscribe", "donate", "tip"]) { return true }
        return words.contains("place") && words.contains("order") || lower.contains("order now")
    }

    /// Steps that ask before a press.
    static func risky(_ label: String) -> Bool {
        let lower = label.lowercased()
        if sendIcons.contains(where: lower.contains) { return true }
        if ["发送", "发布", "发表", "删除", "移除", "清空", "支付", "付款", "转账", "购买", "下单", "提现", "充值",
            "提交", "确认", "预订", "预定", "叫车", "订阅", "退订", "同意"].contains(where: lower.contains) {
            return true
        }
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        // Also covers "Place your order", "Complete reservation", and "Cancel Subscription".
        if !words.isDisjoint(with: ["send", "post", "publish", "delete", "remove", "erase", "pay", "purchase", "buy", "checkout",
                                    "transfer", "withdraw", "submit", "confirm", "request", "reserve", "book", "subscribe",
                                    "unsubscribe", "agree", "accept", "redeem", "donate", "refill"]) { return true }
        if words.contains("place") && words.contains("order") || lower.contains("order now") || lower.contains("complete reservation") { return true }
        return words.contains("cancel") && !words.isDisjoint(with: ["subscription", "membership", "plan", "order", "ride", "trip",
                                                                     "reservation", "booking", "premium", "service", "line"])
    }
}
