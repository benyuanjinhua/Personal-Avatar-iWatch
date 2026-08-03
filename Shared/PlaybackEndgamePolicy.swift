import Foundation

/// ESS-154 T2「播放终局」告知决策（纯函数，可 macOS 单测）。
///
/// 背景：告知只在结果入账时发生一次（`ResultNotificationPolicy` = T1），
/// 播放失败不改变回合状态，`VoiceCuePolicy` 之后不再发任何 cue。
/// 于是 `SpeechPlayer.finishPlayback(successfully: false)` 之后**零告知**——
/// 承诺了语音的用户听不到、也不知道播失败了。ESS-80 判定新增 T2 决策点：
/// 把「播放终局」反馈回告知链路。UNUserNotificationCenter 与真实 haptic
/// 由 Watch 层（ResultNotifier / WatchHaptics）执行；本类型只出策略。
///
/// **T1 与 T2 的取舍**：T1 的 `short_task` / `app_active` 前提是「结果已用别的
/// 方式呈现给用户」（短任务用户仍在看表、前台 App 有 UI）。播放失败恰好
/// **否定这个前提**——因此 T2-2/T2-4（激活穷尽 / 挂起超时）必须**无视** T1 的这
/// 两条跳过。幂等仍走 `ResultNotificationPolicy.hasNotified`（按 request_id 记账），
/// 同一回合无论 T1/T2 通道都只推一次横幅。
///
/// T2-3（中断截断）不发横幅——`unfinishedPlaybackIds` 已让结果卡片显示
/// 「未播完 · 重播」入口，横幅会形成骚扰；触觉仍要震，让熄屏用户感知。
enum PlaybackEndgame: String, Equatable {
    /// `play_finished successfully=true`：唯一「用户已听见」终局，不再补告知。
    case success
    /// 会话激活失败（`playback_activation_exhausted`）：从未 `play()`，
    /// 音频保留可重播。ESS-226 后单阶段激活（`.default` 或 opt-in `.longFormAudio`），
    /// 失败即走本终局；此前的 long-form + foreground 两级失败历史仍收敛到这里。
    case exhausted
    /// 播放中被系统中断截断（`playback_halted_by_interruption`）：
    /// 硬件已被抢走，本段作废；语音留仓可重播。
    case halted
    /// 起播 30s 内无 `play_started`——激活回调丢失/挂起（历史 `playback_deferred`
    /// 后 ≥30s 无终局的等价场景）：认作失败终局，避免播放通道静默吊死。
    case deferredTimeout
    /// `AVAudioPlayer.play()` 直接返回 false：会话激活过但播放器起播失败。
    case playRejected
    /// 回前台续播失败（`play_resume_failed`）：App 曾挂起，续播试无效。
    case resumeFailed

    /// 是否是「用户没听见」的失败终局（用于 T2 判决与幂等）。
    var isFailure: Bool {
        self != .success
    }

    /// 结构化日志用 detail 里的 endgame 字段值。
    var logToken: String { rawValue }
}

/// T2 决策产出：给 Watch 层的动作清单。nil = 该终局无需 T2 追加动作。
struct PlaybackEndgameOutcome: Equatable {
    /// 需要播放的触觉 cue；nil 表示不震。
    let haptic: VoiceInteractionCue?
    /// 是否应尝试发本地横幅（还需过 `notAuthorized` / `hasNotified` 幂等，
    /// 由 `ResultNotifier.notifyPlaybackFailureIfEligible` 收口）。
    let shouldNotifyBanner: Bool
    /// 结构化日志用：命中的判据（`exhausted` / `halted` / `deferred_timeout` / …）。
    let reasonLabel: String
}

enum PlaybackEndgamePolicy {
    /// T2-4 挂起超时阈值：`play()` 请求发出 30 秒内若无 `play_started`（或
    /// 任何终局事件），视为激活回调丢失/挂起，落地成失败终局并告知用户。
    /// ESS-226 后单阶段激活正常握手 << 数秒；30s 阈值绰绰有余。再等下去
    /// 用户已经离开界面，告知反而无意义。
    static let deferredTimeoutSeconds: TimeInterval = 30

    /// 结果播放终局 → T2 追加动作。
    /// - `.success`：无追加（T1 已在结果入账时判过）；
    /// - `.halted`：触觉 + UI 已有「未播完 · 重播」入口，不再发横幅；
    /// - `.exhausted` / `.deferredTimeout` / `.playRejected` / `.resumeFailed`：
    ///   触觉 + 横幅，横幅**无视** T1 的 `short_task` / `app_active`。
    static func outcome(for endgame: PlaybackEndgame) -> PlaybackEndgameOutcome? {
        switch endgame {
        case .success:
            return nil
        case .halted:
            return PlaybackEndgameOutcome(
                haptic: .turnFailed, shouldNotifyBanner: false,
                reasonLabel: "halted"
            )
        case .exhausted:
            return PlaybackEndgameOutcome(
                haptic: .turnFailed, shouldNotifyBanner: true,
                reasonLabel: "exhausted"
            )
        case .deferredTimeout:
            return PlaybackEndgameOutcome(
                haptic: .turnFailed, shouldNotifyBanner: true,
                reasonLabel: "deferred_timeout"
            )
        case .playRejected:
            return PlaybackEndgameOutcome(
                haptic: .turnFailed, shouldNotifyBanner: true,
                reasonLabel: "play_rejected"
            )
        case .resumeFailed:
            return PlaybackEndgameOutcome(
                haptic: .turnFailed, shouldNotifyBanner: true,
                reasonLabel: "resume_failed"
            )
        }
    }

    /// 播放失败横幅文案（纯函数，可测）。诚实告知「没能播出」，指路到全文和重播。
    /// 结果摘要放正文前段，让用户在锁屏也能看到关键信息；空摘要退回固定文案。
    static func failureNotificationContent(resultSummary: String) -> (title: String, body: String) {
        let trimmed = resultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.isEmpty {
            body = "点开看文字，或点重播再试一次"
        } else {
            let head = String(trimmed.prefix(48))
            let ellipsis = trimmed.count > 48 ? "…" : ""
            body = "\(head)\(ellipsis) · 点开看文字"
        }
        return (title: "语音没能播出", body: body)
    }
}
