import WatchKit

/// ESS-55：交互 cue → WKHapticType。触觉默认全开（待白梦林拍板是否可配置）。
/// 结果到达用 .notification（系统语义上最强的「来看一眼」），失败用 .failure。
enum WatchHaptics {
    static func play(_ cue: VoiceInteractionCue) {
        WKInterfaceDevice.current().play(cue.hapticType)
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
        }
    }
}
