import AVFoundation
import Foundation

/// ESS-522 S-2/S-3：本地兜底确认计时器。
///
/// 用户说完话（ASR final）后，Watch 收到 `.accepted` 状态时启动 1.5 秒计时器：
/// - 后台在时限内给出可播确认（语音到达）→ 取消本地兜底，避免双播
/// - 后台未在时限内给出可播确认 → 播放本地兜底确认语音（`ConfirmFallback.m4a`）
/// - 确认播放结束后，回调通知主屏释放；迟到确认不得覆盖当前对话
///
/// 线程：全部 `@MainActor`。
@MainActor
final class VoiceConfirmTimer {
    /// 1.5 秒确认计时阈值（验收标准明确要求的数字）。
    static let confirmThresholdSeconds: TimeInterval = 1.5

    /// 本地兜底语音资源名（Watch Resources 目录下的 .m4a）。
    /// 资源不存在时降级为纯日志 + 触觉，不播放语音。
    static let fallbackResourceName = "ConfirmFallback"

    enum Outcome: Equatable {
        /// 后台确认及时到达——语音已播或可播，不需要本地兜底。
        case backendConfirmationArrived
        /// 1.5 秒超时，播放了本地兜底确认语音。
        case localFallbackPlayed
        /// 1.5 秒超时，本地兜底语音资源缺失，只落日志 + 触觉。
        case localFallbackMissing
    }

    /// 确认流程结束后回调（无论本地还是后台确认）。用于主屏释放。
    var onConfirmComplete: ((String, Outcome) -> Void)?

    private let player: SpeechPlayer
    private var watchdogTask: Task<Void, Never>?
    private var requestId: String?

    init(player: SpeechPlayer) {
        self.player = player
    }

    /// 启动确认计时器。`requestId` 用于取证日志与回调解绑。
    func arm(requestId: String) {
        cancel(reason: "new_confirm")
        self.requestId = requestId
        let threshold = Self.confirmThresholdSeconds
        let capturedRequestId = requestId
        watchdogTask = Task { [weak self] in
            let nanos = UInt64(threshold * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.requestId == capturedRequestId else { return }
                self.fireLocalFallback(requestId: capturedRequestId)
            }
        }
        WatchLog.info(
            "confirm", "timer_armed", requestId: requestId,
            detail: "threshold_s=\(Int(threshold))"
        )
    }

    /// 后台确认到达（语音已可播或已开始播）——取消本地计时器。
    /// 调用方必须在收到可播确认的路径上调用此方法，且不得在
    /// `fireLocalFallback` 之后（已播兜底）再调用。
    func cancel(reason: String) {
        guard watchdogTask != nil else {
            // Silence duplicate cancel — caller may fire on multiple
            // overlapping paths.
            return
        }
        watchdogTask?.cancel()
        watchdogTask = nil
        let capturedRequestId = requestId
        requestId = nil
        if let capturedRequestId {
            WatchLog.info(
                "confirm", "timer_cancelled", requestId: capturedRequestId,
                detail: "reason=\(reason)"
            )
            onConfirmComplete?(capturedRequestId, .backendConfirmationArrived)
        }
    }

    /// 1.5 秒到期——播放本地兜底确认语音。
    private func fireLocalFallback(requestId: String) {
        watchdogTask = nil
        self.requestId = nil

        guard let audioData = loadFallbackAudio() else {
            WatchLog.error(
                "confirm", "fallback_audio_missing", requestId: requestId,
                detail: "resource=\(Self.fallbackResourceName).m4a",
                code: "ERR_CONFIRM_FALLBACK_MISSING"
            )
            // 资源缺失仍算一次「确认」——落触觉，不傻等。
            WatchHaptics.play(.taskAccepted, requestId: requestId)
            onConfirmComplete?(requestId, .localFallbackMissing)
            return
        }

        WatchLog.info(
            "confirm", "fallback_play_started", requestId: requestId,
            detail: "bytes=\(audioData.count) threshold_s=\(Int(Self.confirmThresholdSeconds))"
        )
        _ = player.play(data: audioData, context: requestId) { [weak self] _ in
            guard let self else { return }
            WatchLog.info(
                "confirm", "fallback_play_finished", requestId: requestId
            )
            self.onConfirmComplete?(requestId, .localFallbackPlayed)
        }
    }

    /// 加载本地兜底语音资源。
    private func loadFallbackAudio() -> Data? {
        guard let url = Bundle.main.url(
            forResource: Self.fallbackResourceName,
            withExtension: "m4a"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// 强制取消（用户中断 / 回合终止）。
    func forceCancel(requestId captured: String? = nil) {
        let capturedRequestId = requestId ?? captured
        watchdogTask?.cancel()
        watchdogTask = nil
        requestId = nil
        if let capturedRequestId {
            WatchLog.info(
                "confirm", "timer_force_cancelled", requestId: capturedRequestId
            )
        }
    }

    /// 是否正在等待确认。
    var isArmed: Bool {
        watchdogTask != nil && requestId != nil
    }
}
