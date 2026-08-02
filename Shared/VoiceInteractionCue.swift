import Foundation

/// ESS-55 触觉反馈的五个关键节点。手表贴腕，触觉是唯一不需要看屏幕、
/// 不需要环境安静、必定被感知的反馈通道；Watch 层把 cue 映射为 WKHapticType。
enum VoiceInteractionCue: String, CaseIterable, Equatable {
    /// 按下开始录音（本地即时反馈）。
    case recordingStarted
    /// 松手且录音有效，请求已提交。
    case requestSubmitted
    /// 请求被 Mac 受理（首次进入受理/处理态）。
    case taskAccepted
    /// 结果到达。熄屏时用户靠这一下知道该抬腕了。
    case resultArrived
    /// 回合失败。
    case turnFailed
}

/// 远端状态事件 → 触觉 cue 的映射与去重。
/// 状态事件可能乱序/重复（apply 已挡一层），同一回合的同一 cue 只发一次；
/// 「受理」允许跳过 accepted 直达 processing，因此按状态族判定而不是单点状态。
struct VoiceCuePolicy {
    private var delivered: [String: Set<VoiceInteractionCue>] = [:]

    /// 状态入账后调用；返回需要播放的 cue（无则 nil）。
    mutating func cue(for state: VoiceTurnState, requestId: String) -> VoiceInteractionCue? {
        guard let cue = Self.mapping(for: state) else { return nil }
        var sent = delivered[requestId] ?? []
        guard !sent.contains(cue) else { return nil }
        sent.insert(cue)
        delivered[requestId] = sent
        // 终态后该回合不会再有 cue，释放记账（防长期驻留增长）。
        if state.isTerminal { delivered[requestId] = nil }
        return cue
    }

    private static func mapping(for state: VoiceTurnState) -> VoiceInteractionCue? {
        switch state {
        case .accepted, .realtimeProcessing, .backgroundAccepted, .backgroundProcessing:
            return .taskAccepted
        case .completed:
            return .resultArrived
        case .failed:
            return .turnFailed
        case .recorded, .waitingForPhone, .waitingForMac, .permissionRequired, .cancelled:
            return nil
        }
    }
}
