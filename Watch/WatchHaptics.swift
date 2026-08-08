import WatchKit

/// ESS-55：交互 cue → WKHapticType。触觉默认全开（待白梦林拍板是否可配置）。
/// 结果到达用 .notification（系统语义上最强的「来看一眼」），失败用 .failure。
/// ESS-154：每次播放都落 `haptic_played` 结构化日志——之前触觉是否真的
/// 播了在日志上无法证明，T2 决策的验收（用户是否被震到）依赖它作为
/// R-02.1 意义上的运行时证据。requestId 可选：欢迎语/无回合触觉传 nil。
enum WatchHaptics {
    static func play(_ cue: VoiceInteractionCue, requestId: String? = nil) {
        WKInterfaceDevice.current().play(cue.hapticType)
        WatchLog.info(
            "haptic", "haptic_played", requestId: requestId,
            detail: "cue=\(cue.rawValue)"
        )
    }
}

private extension VoiceInteractionCue {
    var hapticType: WKHapticType {
        switch self {
        case .recordingStarted: return .start
        case .requestSubmitted: return .success
        case .taskAccepted: return .click
        case .resultArrived: return .notification
        case .turnFailed: return .failure
        // ESS-573 会话触觉口径（PRD §3.5.5）：就绪 .click（最重要——
        // 「可以开口」的唯一信号）、退出 .stop、通道失败 .failure。
        case .sessionReady: return .click
        case .sessionExit: return .stop
        case .sessionChannelFailed: return .failure
        }
    }
}
