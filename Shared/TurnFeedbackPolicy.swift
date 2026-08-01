import Foundation

/// 回合反馈事件（ESS-53 §4）：状态机变迁中值得主动提示用户的节点。
/// 触觉/声音的具体映射在 Watch 适配层（WatchHaptics），这里只做纯策略。
enum TurnFeedbackEvent: Equatable {
    /// 语音已到手机（waiting_for_mac）：松手后的第一个"收到了"确认。
    case deliveredToPhone
    /// Mac 已受理（accepted）：视觉推进，默认不触觉（避免连环震动）。
    case accepted
    /// 需要用户确认高风险动作（permission_required）。
    case needsConfirmation
    /// 结果可用（completed）。
    case completed
    /// 失败（failed）。
    case failed
    /// 已取消（cancelled）：用户自己发起，默认不触觉。
    case cancelled
}

/// 状态机变迁 → 反馈事件的纯映射（ESS-53）。
/// - 由 journal 快照 diff 驱动，不依赖 UI 挂载；同一回合同一状态只触发一次。
/// - 冷启动静默 seed：首次观察到的存量回合不补发事件，避免重开 App 触觉风暴。
struct TurnFeedbackPolicy {
    private var lastStates: [String: VoiceTurnState] = [:]
    private var seeded = false

    /// 观察一次回合快照，返回本次需要提示的事件（按快照内顺序）。
    mutating func observe(turns: [(requestId: String, state: VoiceTurnState)]) -> [TurnFeedbackEvent] {
        defer {
            lastStates = Dictionary(uniqueKeysWithValues: turns.map { ($0.requestId, $0.state) })
            seeded = true
        }
        guard seeded else { return [] }

        var events: [TurnFeedbackEvent] = []
        for turn in turns {
            let previous = lastStates[turn.requestId]
            guard previous != turn.state else { continue }
            // 首次出现的回合只对"已经走到值得提示的状态"发一次事件；
            // 已知回合按变迁发。状态机单调前进 + 终态吸收保证不会重复。
            if let event = Self.event(for: turn.state) {
                events.append(event)
            }
        }
        return events
    }

    /// 到达某状态时对用户的提示事件；等待/处理中状态不主动打扰。
    static func event(for state: VoiceTurnState) -> TurnFeedbackEvent? {
        switch state {
        case .waitingForMac: return .deliveredToPhone
        case .accepted: return .accepted
        case .permissionRequired: return .needsConfirmation
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .recorded, .waitingForPhone, .realtimeProcessing,
             .backgroundAccepted, .backgroundProcessing:
            return nil
        }
    }
}
