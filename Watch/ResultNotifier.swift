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
        deliverNotification(requestId: turn.requestId, content: content, sourceLabel: "result")
        return true
    }

    // MARK: - 通知投递（含提交失败重试）

    /// 向 UNUserNotificationCenter 提交通知请求。成功才 markNotified；提交失败按退避重试，
    /// 上限 3 次。重试调度依赖 `DispatchQueue.main.asyncAfter`，仅存活进程内有效；
    /// 进程退出后重试不会自动恢复（决策见 ESS-788 架构复审）。
    /// 注意：本方法异步提交后立即返回，此时尚不知道最终投递结果。`notifyResultIfEligible`
    /// 的返回值语义是"已发起投递尝试"而非"已送达"——调用方兜底触觉的重检已列为跟进项。
    private func deliverNotification(
        requestId: String,
        content: UNMutableNotificationContent,
        sourceLabel: String,
        retryLogDetail: String = ""
    ) {
        center.add(UNNotificationRequest(
            identifier: "result-\(requestId)", content: content, trigger: nil
        )) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let action = self.policy.evaluateDelivery(requestId: requestId, error: error)
                switch action {
                case .markNotified:
                    WatchLog.info(
                        "notify", "result_notified", requestId: requestId,
                        detail: "source=\(sourceLabel)\(retryLogDetail.isEmpty ? "" : " retry_attempt=\(self.policy.retryAttemptCount(requestId: requestId))")"
                    )
                    self.policy.markNotified(requestId: requestId)
                case .retry(let delay):
                    WatchLog.error(
                        "notify", "result_notify_failed", requestId: requestId,
                        detail: "source=\(sourceLabel)\(retryLogDetail.isEmpty ? "" : " \(retryLogDetail)")",
                        error: error
                    )
                    WatchLog.info(
                        "notify", "result_notify_retry_scheduled", requestId: requestId,
                        detail: "delay=\(Int(delay))s attempt=\(self.policy.retryAttemptCount(requestId: requestId)) source=\(sourceLabel)"
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.deliverNotification(
                            requestId: requestId, content: content,
                            sourceLabel: sourceLabel,
                            retryLogDetail: "retry_attempt=\(self.policy.retryAttemptCount(requestId: requestId))"
                        )
                    }
                case .exhausted:
                    WatchLog.error(
                        "notify", "result_notify_failed", requestId: requestId,
                        detail: "source=\(sourceLabel)\(retryLogDetail.isEmpty ? "" : " \(retryLogDetail)")",
                        error: error
                    )
                    WatchLog.info(
                        "notify", "result_notify_retry_exhausted", requestId: requestId,
                        detail: "source=\(sourceLabel)"
                    )
                }
            }
        }
    }

    /// ESS-154 T2：播放终局失败的横幅告知。**不再看 T1 的 `short_task` /
    /// `app_active`**——播放失败恰好否定了「结果已用别的方式呈现」这个前提。
    /// 仍受 `notAuthorized`（系统级不可发）与 `hasNotified`（幂等，与 T1 共用
    /// `ResultNotificationPolicy` 记账，同一 request_id 一辈子只推一条）约束。
    /// 返回 true 表示已发出（结构化日志有 `result_notified` + `source=`）。
    @discardableResult
    func notifyPlaybackFailureIfEligible(
        requestId: String,
        resultSummary: String,
        reasonLabel: String
    ) -> Bool {
        cancelProvisional(requestId: requestId)
        if !isAuthorized {
            WatchLog.info(
                "notify", "playback_failure_notify_skipped", requestId: requestId,
                detail: "reason=not_authorized playback_reason=\(reasonLabel)"
            )
            return false
        }
        if policy.hasNotified(requestId: requestId) {
            WatchLog.info(
                "notify", "playback_failure_notify_skipped", requestId: requestId,
                detail: "reason=already_notified playback_reason=\(reasonLabel)"
            )
            return false
        }
        let content = UNMutableNotificationContent()
        let text = PlaybackEndgamePolicy.failureNotificationContent(resultSummary: resultSummary)
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = ["request_id": requestId]
        deliverNotification(
            requestId: requestId, content: content,
            sourceLabel: "playback_failure",
            retryLogDetail: "playback_reason=\(reasonLabel)"
        )
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
