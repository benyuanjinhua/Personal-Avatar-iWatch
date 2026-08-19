import Foundation
import UserNotifications

/// 窄协议：抽象 `UNUserNotificationCenter.add` 调用，使 `deliverNotification`
/// 的投递/重试/耗尽链路可在 WatchTests 中用返回 error 的 fake 驱动（ESS-788 /
/// ESS-754 复审要求 R-02.1 模拟器运行时证据）。
protocol NotificationSubmitter {
    /// 提交通知请求；completion 在提交完成后回调（与 UNUserNotificationCenter.add
    /// 同形），error != nil 表示提交失败。
    func submit(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
}

/// 生产实现：直连 UNUserNotificationCenter.current()。
extension UNUserNotificationCenter: NotificationSubmitter {
    func submit(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        add(request, withCompletionHandler: completion)
    }
}
