import WatchKit

/// 触觉反馈适配器（ESS-53 §4）：反馈事件 → WKHapticType。
/// 策略（何时触发、去重）在 TurnFeedbackPolicy；这里只负责映射和总开关。
/// 总开关沿用 iPhone 伴侣 App 的"触感反馈"配置（AgentConfiguration.hapticsEnabled）。
@MainActor
final class WatchHaptics {
    var isEnabled = true

    /// 按下开始录音：即时确认，不等录音器真正就绪。
    func playRecordStarted() { play(.start) }

    /// 松开发送：与开始成对，"说完了、收下了"。
    func playRecordStopped() { play(.stop) }

    /// 本地即时失败（无麦克风权限/空录音等，不经状态机）。
    func playLocalFailure() { play(.failure) }

    func play(event: TurnFeedbackEvent) {
        guard let type = Self.hapticType(for: event) else { return }
        play(type)
    }

    /// accepted / cancelled 不触觉：前者紧跟送达确认避免连环震动，后者是用户自己发起。
    static func hapticType(for event: TurnFeedbackEvent) -> WKHapticType? {
        switch event {
        case .deliveredToPhone: return .click
        case .needsConfirmation: return .notification
        case .completed: return .success
        case .failed: return .failure
        case .accepted, .cancelled: return nil
        }
    }

    private func play(_ type: WKHapticType) {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(type)
    }
}
