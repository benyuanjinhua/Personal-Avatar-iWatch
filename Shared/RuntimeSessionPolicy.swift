import Foundation

/// ESS-45：ExtendedRuntimeSession 持有/释放决策（纯函数，可单测）。
/// 目标：语音回合期间（录音 → 等待 → 播放结束）持有 runtime session，
/// 空闲即释放，回落系统默认熄屏策略；一切持有都有界（grace 窗口 +
/// self-care 会话系统级 10 分钟上限），避免电量黑洞。
enum RuntimeSessionPolicy {
    /// completed 已到但结果语音仍在 transferFile 途中的等待上限。
    /// 超过即释放——结果语音迟到时由 WCSession 队列在下次唤醒补投（ESS-38/47）。
    static let resultAudioGrace: TimeInterval = 120

    enum Decision: Equatable {
        case hold(reason: String)
        case release
    }

    /// 决策 + 需要重新评估的时间点（grace 到期时必须再跑一次 decide 才会释放）。
    struct Verdict: Equatable {
        let decision: Decision
        let reviewAt: Date?
    }

    /// ESS-58：会话被系统收回后，回到前台时是否允许自动重持。
    /// 入参是 WKExtendedRuntimeSessionInvalidationReason.rawValue（Shared 不
    /// 依赖 WatchKit，故传裸值；resignedFrontmost=3 已与真机日志
    /// reason_code=3 对上）。
    /// - resignedFrontmost(3)：锁屏/切走导致，不是预算耗尽——解锁回前台且
    ///   仍有持有理由时应重持，否则剩余回合被锁屏吞掉。
    /// - expired(2)/error(-1)/其它：维持 ESS-45 有界执行，不自动续命。
    static func allowsRestartAfterForeground(invalidationReasonCode: Int) -> Bool {
        invalidationReasonCode == 3
    }

    /// - Parameters:
    ///   - turns: 回合日志全量（新的在前，最多 20 条）。
    ///   - deliveredRequestIds: 本次进程内已完成播放交付的 request_id
    ///     （播放后 speechFileName 被清空，仅凭 journal 无法区分「已播完」
    ///     和「音频还没到」，需要这份内存标记）。
    ///   - isRecording: 按住说话进行中（含收尾 finishing）。
    ///   - isPlaying: 播放器播放中（结果语音或欢迎语）。
    static func decide(
        turns: [VoiceTurnRecord],
        deliveredRequestIds: Set<String>,
        isRecording: Bool,
        isPlaying: Bool,
        now: Date
    ) -> Verdict {
        if isRecording { return Verdict(decision: .hold(reason: "recording"), reviewAt: nil) }
        if isPlaying { return Verdict(decision: .hold(reason: "playing"), reviewAt: nil) }
        if let active = turns.first(where: \.isActive) {
            return Verdict(decision: .hold(reason: "turn_active:\(active.requestId)"), reviewAt: nil)
        }
        // completed 且结果声明带语音、但尚未播放交付：
        // - 语音已落盘（speechFileName 非空）→ 等自动播放接手；
        // - 语音还在路上 → 给 transferFile 留 grace 窗口，App 挂起会掐断传输。
        // 两种都以终态时间 + grace 为上限，历史回合自然不持有。
        for turn in turns {
            guard
                turn.currentState == .completed,
                !deliveredRequestIds.contains(turn.requestId),
                turn.speechFileName != nil || turn.result?.speechSha256 != nil,
                let terminalAt = turn.events.last?.at
            else { continue }
            let deadline = terminalAt.addingTimeInterval(resultAudioGrace)
            guard now < deadline else { continue }
            let reason = turn.speechFileName != nil ? "speech_unplayed" : "awaiting_result_audio"
            return Verdict(
                decision: .hold(reason: "\(reason):\(turn.requestId)"),
                reviewAt: deadline
            )
        }
        return Verdict(decision: .release, reviewAt: nil)
    }
}
