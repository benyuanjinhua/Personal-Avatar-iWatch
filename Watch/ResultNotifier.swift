import Foundation
import UserNotifications
import WatchKit

/// ESS-55 超长任务本地通知（白梦林 2026-08-02 拍板纳入本期）。
/// 决策与幂等在 ResultNotificationPolicy（Shared，可单测）；本类只做
/// UNUserNotificationCenter 交互：JIT 授权、结果通知、兜底预约、点通知直达全文。
@MainActor
final class ResultNotifier: NSObject, ObservableObject {
    /// 首次长任务场景是否需要展示授权引导卡（冷启动不弹，见产品细则 #1）。
    @Published private(set) var shouldPromptAuthorization = false
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    let policy: ResultNotificationPolicy
    /// 点通知直达该条结果全文（由 PushToTalkController 注入）。
    var onOpenResult: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    /// 用户在引导卡上点过「暂不」：不再展示引导卡（不得反复弹窗骚扰，细则 #2）。
    private let promptDeclinedKey = "wristagent.watch.notification-prompt-declined"

    init(policy: ResultNotificationPolicy) {
        self.policy = policy
        super.init()
        center.delegate = self
        refreshAuthorizationStatus()
    }

    private func refreshAuthorizationStatus() {
        center.getNotificationSettings { settings in
            Task { @MainActor in
                self.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    private var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    // MARK: - JIT 授权（细则 #1/#2）

    /// 首次长任务被受理时调用：只在从未决定过、且用户没点过「暂不」时亮引导卡。
    /// 授权状态已确定（同意或拒绝）都不再打扰——拒绝的降级路径是触觉 + 未读。
    func longTaskAccepted(requestId: String) {
        switch authorizationStatus {
        case .notDetermined:
            if defaults.bool(forKey: promptDeclinedKey) {
                WatchLog.info("notify", "prompt_suppressed_declined", requestId: requestId)
            } else {
                shouldPromptAuthorization = true
                WatchLog.info("notify", "prompt_shown", requestId: requestId)
            }
        case .denied:
            WatchLog.info("notify", "skip_denied_fallback_haptic_unread", requestId: requestId)
        default:
            scheduleProvisional(requestId: requestId)
        }
    }

    /// 引导卡「开启提醒」：走系统授权，成功后为当前长任务补预约兜底。
    func requestAuthorization(activeLongTaskRequestId: String?) {
        shouldPromptAuthorization = false
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.refreshAuthorizationStatus()
                if let error {
                    WatchLog.error("notify", "authorization_failed", error: error)
                    return
                }
                WatchLog.info("notify", "authorization_result", detail: "granted=\(granted)")
                if granted, let requestId = activeLongTaskRequestId {
                    self.scheduleProvisional(requestId: requestId)
                }
            }
        }
    }

    /// 引导卡「暂不」：记住，不再骚扰；通知能力静默降级为触觉 + 未读。
    func declinePrompt() {
        shouldPromptAuthorization = false
        defaults.set(true, forKey: promptDeclinedKey)
        WatchLog.info("notify", "prompt_declined")
    }

    // MARK: - 结果通知（主路径）

    /// 结果入账时调用。返回 true = 已发通知（调用方跳过 .notification 触觉，
    /// 同一结果只震一次，细则 #4）。
    @discardableResult
    func notifyResultIfEligible(turn: VoiceTurnRecord, completedAt: Date) -> Bool {
        cancelProvisional(requestId: turn.requestId)
        let isAppActive = WKApplication.shared().applicationState == .active
        if let reason = policy.skipReason(
            requestId: turn.requestId,
            turnCreatedAt: turn.createdAt,
            completedAt: completedAt,
            isAppActive: isAppActive,
            isAuthorized: isAuthorized
        ) {
            WatchLog.info("notify", "result_notify_skipped", requestId: turn.requestId, detail: reason.rawValue)
            return false
        }
        let content = UNMutableNotificationContent()
        let text = ResultNotificationPolicy.notificationContent(
            resultSummary: turn.result?.displaySummary ?? ""
        )
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = ["request_id": turn.requestId]
        // identifier = request_id：系统层第三重幂等（同 id 替换不叠加）。
        center.add(UNNotificationRequest(
            identifier: "result-\(turn.requestId)", content: content, trigger: nil
        )) { error in
            Task { @MainActor in
                if let error {
                    WatchLog.error("notify", "result_notify_failed", requestId: turn.requestId, error: error)
                } else {
                    WatchLog.info("notify", "result_notified", requestId: turn.requestId)
                }
            }
        }
        policy.markNotified(requestId: turn.requestId)
        return true
    }

    // MARK: - 兜底预约（B 路径：结果可能始终没到手表）

    /// 长任务受理时预约：超过 ExtendedRuntimeSession 上限仍无终态才触发，
    /// 结果（或失败/取消）先到就取消。文案不承诺「有结果」，只召回。
    func scheduleProvisional(requestId: String) {
        guard isAuthorized else { return }
        guard !policy.hasNotified(requestId: requestId) else { return }
        let content = UNMutableNotificationContent()
        let text = ResultNotificationPolicy.provisionalContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = ["request_id": requestId]
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: ResultNotificationPolicy.provisionalFallbackSeconds, repeats: false
        )
        center.add(UNNotificationRequest(
            identifier: "pending-\(requestId)", content: content, trigger: trigger
        ))
        WatchLog.info(
            "notify", "provisional_scheduled", requestId: requestId,
            detail: "fire_in_s=\(Int(ResultNotificationPolicy.provisionalFallbackSeconds))"
        )
    }

    func cancelProvisional(requestId: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["pending-\(requestId)"])
    }
}

// MARK: - 点通知直达 + 前台静默（细则 #3）

extension ResultNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let requestId = userInfo["request_id"] as? String else { return }
        await MainActor.run {
            WatchLog.info("notify", "notification_opened", requestId: requestId)
            self.onOpenResult?(requestId)
        }
    }

    /// App 已在前台时不叠加系统横幅——界面本身就是状态，触觉链路已覆盖。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
