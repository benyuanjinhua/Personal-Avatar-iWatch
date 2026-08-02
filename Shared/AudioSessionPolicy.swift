import Foundation

/// ESS-61：共享 AVAudioSession 在「long_form 播放 ↔ 录音」之间切换的决策
/// （纯函数，可单测）。
/// 背景：ESS-58 在播放路径把共享会话设成 .longFormAudio 路由策略；该策略
/// 是粘性的——录音侧不带 policy 参数的 setCategory 重载不会把它复位，
/// .longFormAudio 与 .playAndRecord 不相容 → setCategory/setActive 抛
/// NSOSStatusErrorDomain#-50（paramErr），录音全灭（真机取证 04:52:45–47
/// 连续 6 次）。同一次取证还发现 activate() 回调 error=nil 但
/// activated=false 被当成功，88 秒音频一声没出（play_returned_false）。
enum AudioSessionPolicy {
    /// 播放激活状态机的下一步。所有路径最终只能到 `play` 或
    /// `retainForReplay`；中断期间只能等待，不能碰音频会话。
    enum PlaybackActivationAction: Equatable {
        case waitForInterruptionEnd
        case activateLongForm
        case activateForeground
        case play
        case retainForReplay
    }

    /// `nil` 表示该级激活尚未尝试。把是否允许 `play()` 的判定集中在纯函数
    /// 中，避免异步回调的某条失败分支绕过门禁。
    static func nextPlaybackActivationAction(
        interrupted: Bool,
        longFormSucceeded: Bool?,
        foregroundSucceeded: Bool?
    ) -> PlaybackActivationAction {
        if interrupted { return .waitForInterruptionEnd }
        guard let longFormSucceeded else { return .activateLongForm }
        if longFormSucceeded { return .play }
        guard let foregroundSucceeded else { return .activateForeground }
        return foregroundSucceeded ? .play : .retainForReplay
    }

    // MARK: ESS-73 中断信任窗口

    /// watchOS 不保证投递 interruption .ended（真机取证 2026-08-02 09:12：
    /// .began ×4 后全库 0 条 .ended，后续所有播放被无限 defer，直到重启 App）。
    /// 中断标记只在本窗口内可信。取值下界：S5 自检在合成 .began 后 ~400ms 内
    /// 断言 defer 且零激活尝试，窗口必须覆盖它；上界：窗口有多长，
    /// 「有语音却无声」的死区就有多长。
    static let interruptionTrustWindow: TimeInterval = 5

    /// 中断闸门是否仍然生效：收到过 .began、尚未被 .ended 清除（beganAt 非
    /// nil）、且未超过信任窗口。过期后播放请求改为直接尝试激活——真中断下
    /// 激活自然失败，落入既有 exhausted→retainForReplay 路径，不会更糟。
    static func interruptionGateEngaged(beganAt: Date?, now: Date) -> Bool {
        guard let beganAt else { return false }
        return now.timeIntervalSince(beganAt) < interruptionTrustWindow
    }

    /// defer 后的自动重试延迟：等信任窗口过期即重试。窗口已过期时给最小
    /// 正延迟，避免同步重入。
    static func deferredRetryDelay(beganAt: Date, now: Date) -> TimeInterval {
        max(0.1, interruptionTrustWindow - now.timeIntervalSince(beganAt))
    }

    // MARK: F2 播放激活判定

    /// `activated == false` 与 `error != nil` 一律视为激活失败：只有会话
    /// 真正激活了才允许 play()，否则回落前台会话重配——宁可锁屏被挂起，
    /// 也不许在未激活的会话上静默失声。
    static func playbackActivationSucceeded(activated: Bool, hasError: Bool) -> Bool {
        activated && !hasError
    }

    // MARK: F1 录音会话配置序列

    /// 录音会话配置的一次尝试。
    enum RecordingAttempt: Equatable {
        /// 首选：先 setActive(false, .notifyOthersOnDeactivation) 清掉上一次
        /// 播放留下的激活状态，再用带 policy 参数的重载显式声明 .default，
        /// 把 .longFormAudio 复位。
        case resetRoutePolicy
        /// 回落：复位后仍失败时，最简 .playAndRecord（policy 显式 .default、
        /// 不带 options）再试一次。
        case minimal
    }

    /// 尝试序列：resetRoutePolicy → minimal → 放弃（报用户可读错误，原始
    /// OSStatus 只进日志不进 UI）。
    static func nextRecordingAttempt(after attempt: RecordingAttempt?) -> RecordingAttempt? {
        switch attempt {
        case nil: return .resetRoutePolicy
        case .resetRoutePolicy: return .minimal
        case .minimal: return nil
        }
    }
}
