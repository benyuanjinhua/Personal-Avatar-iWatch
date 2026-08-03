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
    /// watchOS 的内建扬声器不支持 `.longFormAudio` 激活。真机上该组合会稳定
    /// 返回 561145203（resourceNotAvailable），并且紧随其后的同会话回退也
    /// 会失败。扬声器因此直接使用默认 route policy；蓝牙等外部输出仍保留
    /// long-form，以维持锁屏/后台播放合同。
    enum PlaybackRoutePolicy: Equatable {
        case longForm
        case foreground
    }

    static func playbackRoutePolicy(hasBuiltInSpeakerOutput: Bool) -> PlaybackRoutePolicy {
        hasBuiltInSpeakerOutput ? .foreground : .longForm
    }

    /// 播放激活状态机的下一步。所有路径最终只能到 `play` 或
    /// `retainForReplay`。
    /// ESS-73：中断标志不再是新播放请求的闸门——`.ended` 通知不保证投递
    /// （中断方不归还会话、App 曾挂起都会丢），等 `.ended` 会把播放通道
    /// 永久锁死。新 play() 一律直接尝试激活，让激活结果说话：硬件仍被
    /// 占用时激活自然失败（'!pla'），落入既有 exhausted→retainForReplay
    /// 路径，不会更糟。
    enum PlaybackActivationAction: Equatable {
        case activateLongForm
        case activateForeground
        case play
        case retainForReplay
    }

    /// `nil` 表示该级激活尚未尝试。把是否允许 `play()` 的判定集中在纯函数
    /// 中，避免异步回调的某条失败分支绕过门禁。
    static func nextPlaybackActivationAction(
        longFormSucceeded: Bool?,
        foregroundSucceeded: Bool?
    ) -> PlaybackActivationAction {
        guard let longFormSucceeded else { return .activateLongForm }
        if longFormSucceeded { return .play }
        guard let foregroundSucceeded else { return .activateForeground }
        return foregroundSucceeded ? .play : .retainForReplay
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
