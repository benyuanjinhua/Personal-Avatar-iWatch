import AVFoundation
import Foundation

/// 播放上下文（ESS-41 L4 取证）：request_id + 音频来源贯穿 session 激活、
/// player init/start/finish/error 全链日志，与 Bridge/iPhone 侧同一
/// request_id 串成 L1→L4 证据链。
struct SpeechPlaybackContext {
    let requestId: String
    /// welcome | result_direct | result_background
    let source: String

    static let welcome = SpeechPlaybackContext(requestId: "welcome", source: "welcome")
}

/// 语音播放器：只播真实链路语音（Qwen Audio Realtime 生成、AudioPipe 转码的
/// AAC/M4A），不做系统 TTS（ESS-40 起系统 TTS 随静态 demo 一并移除）。
///
/// ESS-42 取证：会话激活、音频路由、播放器创建、play() 返回、完成/解码
/// 错误/系统中断回调全部走统一 WatchLog，context 为 request_id（结果播放）
/// 或 welcome-<id>（欢迎语），Mac 侧按同一 id 串链。
///
/// ESS-38 复测加固：完成回调携带 success——只有正常播完才算交付，调用方
/// 绝不能在失败时清掉密文；失败原因同时落 `lastError` 供 UI 展示。
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    /// 最近一次播放失败的可读原因（语音失败必须可观测，不允许静默）。
    @Published private(set) var lastError: String?

    private var audioPlayer: AVAudioPlayer?
    private var onFinish: ((Bool) -> Void)?
    /// 当前播放的取证关联 id（request_id / welcome attempt id）。
    private var context: String?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        // 播放中断（电话/系统占用）是真机欢迎语「响一半没了」的候选根因，必须留痕。
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let kind = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                guard let self, self.isPlaying || kind == .ended else { return }
                WatchLog.info(
                    "player", "session_interruption", requestId: self.context,
                    detail: kind == .began ? "began" : "ended"
                )
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// 播放语音片段（ESS-29）。数据只在内存中解密，不落明文文件。
    /// ESS-41 B3：播放前必须激活 .playback 会话——watchOS 冷启动默认会话下
    /// AVAudioPlayer 可能静默无输出（play() 返回 true 但听不到），这正是
    /// 真机欢迎语不响的首要候选根因。激活失败不中止播放尝试，但落取证日志。
    ///
    /// onFinish(success)：正常播完 → true；解码/启动/中途失败 → false。
    /// 主动 stop()（用户打断）不回调——打断不算失败也不算交付。
    @discardableResult
    func play(data: Data, context: String? = nil, onFinish: ((Bool) -> Void)? = nil) -> Bool {
        stop()
        lastError = nil
        self.context = context
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            WatchLog.info(
                "player", "session_activated", requestId: context,
                detail: "category=playback route=\(Self.routeDescription(session))"
            )
        } catch {
            WatchLog.error(
                "player", "session_activation_failed", requestId: context,
                detail: "route=\(Self.routeDescription(session))", error: error
            )
            lastError = "音频会话激活失败（\((error as NSError).code)）"
            // 不中止：仍尝试播放，结果由 play() 返回值与回调体现
        }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            WatchLog.error(
                "player", "player_init_failed", requestId: context,
                detail: "bytes=\(data.count)", error: error
            )
            lastError = "语音解码失败（\((error as NSError).code)）"
            self.context = nil
            onFinish?(false)
            return false
        }
        player.delegate = self
        audioPlayer = player
        self.onFinish = onFinish
        player.prepareToPlay()
        isPlaying = player.play()
        if !isPlaying {
            WatchLog.error(
                "player", "play_returned_false", requestId: context,
                detail: "bytes=\(data.count) duration=\(player.duration)",
                code: "ERR_PLAY_RETURNED_FALSE"
            )
            lastError = "语音播放启动失败"
            audioPlayer = nil
            self.onFinish = nil
            self.context = nil
            onFinish?(false)
        } else {
            WatchLog.info(
                "player", "play_started", requestId: context,
                detail: String(format: "bytes=%d duration=%.2fs", data.count, player.duration)
            )
        }
        return isPlaying
    }

    func stop() {
        if isPlaying {
            WatchLog.info("player", "stopped", requestId: context)
        }
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        onFinish = nil // 主动打断：不回调（既非成功交付，也非播放失败）
        context = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            WatchLog.info("player", "play_finished", requestId: self.context, detail: "successfully=\(flag)")
            if !flag { self.lastError = "语音播放中断（解码错误）" }
            self.isPlaying = false
            self.audioPlayer = nil
            self.context = nil
            let callback = self.onFinish
            self.onFinish = nil
            callback?(flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            WatchLog.error(
                "player", "decode_error", requestId: self.context,
                code: "ERR_AUDIO_DECODE", error: error
            )
        }
    }

    private static func routeDescription(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue)(\($0.portName))" }
            .joined(separator: "+")
        return outputs.isEmpty ? "none" : outputs
    }
}
