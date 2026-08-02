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
/// ESS-42 取证：会话激活、音频路由、播放器创建、play() 返回、完成/解码
/// 错误/系统中断回调全部走统一 WatchLog，context 为 request_id（结果播放）
/// 或 welcome-<id>（欢迎语），Mac 侧按同一 id 串链。
/// ESS-58 后台音频：watchOS 上锁屏/降腕/切走后还要出声，唯一正路是
/// WKBackgroundModes=audio + .playback 会话带 .longFormAudio 路由策略 +
/// 异步 activate()——纯 setActive(true) 的前台会话在 App 挂起时播放被无声
/// 截断（真机取证 play_started 无 play_finished）。激活失败回落前台会话，
/// 宁可只在前台响也不失声；未播完一律走 onFinish(false) 交由上层保留重播。
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false

    private var audioPlayer: AVAudioPlayer?
    /// 收尾回调：true=完整播完；false=未播完（截断/解码失败/起播失败）。
    private var onFinish: ((Bool) -> Void)?
    /// 当前播放的取证关联 id（request_id / welcome attempt id）。
    private var context: String?
    private var interruptionObserver: NSObjectProtocol?
    /// 异步激活期间又来了新 play()/stop() 时，旧激活回调据此作废。
    private var playbackGeneration = 0

    var currentContext: String? { isPlaying ? context : nil }

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
    /// 返回 true 表示播放请求已受理（播放器创建成功、会话激活已在途）；
    /// play_started 在激活完成后落日志。onFinish(true) 仅在完整播完时回调，
    /// 其余路径（起播失败/截断/解码失败）回调 onFinish(false)。
    @discardableResult
    func play(data: Data, context: String? = nil, onFinish: ((Bool) -> Void)? = nil) -> Bool {
        stop()
        self.context = context
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            WatchLog.error(
                "player", "player_init_failed", requestId: context,
                detail: "bytes=\(data.count)", error: error
            )
            self.context = nil
            onFinish?(false)
            return false
        }
        player.delegate = self
        audioPlayer = player
        self.onFinish = onFinish
        isPlaying = true
        playbackGeneration += 1
        let generation = playbackGeneration
        activateSession(context: context) { [weak self] in
            guard let self, self.playbackGeneration == generation, self.audioPlayer === player else { return }
            self.beginPlayback(player, bytes: data.count)
        }
        return true
    }

    /// ESS-58 方案 A：优先 .longFormAudio + 异步 activate()（watchOS 后台
    /// 音频的系统合同）；setCategory 抛错（旧系统/参数拒绝）时回落原有
    /// 前台同步激活，行为等同 ESS-41 B3，不失声但锁屏会被挂起。
    private func activateSession(context: String?, completion: @escaping @MainActor () -> Void) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            WatchLog.error(
                "player", "session_policy_rejected", requestId: context,
                detail: "fallback=foreground", error: error
            )
            activateForegroundFallback(context: context)
            completion()
            return
        }
        session.activate { [weak self] activated, error in
            Task { @MainActor in
                guard let self else { return }
                // ESS-61 F2：activated=false 且 error=nil 也是失败（真机取证
                // 88 秒静默），一律回落前台会话，不许在未激活的会话上 play()。
                if AudioSessionPolicy.playbackActivationSucceeded(activated: activated, hasError: error != nil) {
                    WatchLog.info(
                        "player", "session_activated", requestId: context,
                        detail: "category=playback policy=long_form activated=true "
                            + "route=\(Self.routeDescription(session))"
                    )
                } else {
                    WatchLog.error(
                        "player", "session_activation_failed", requestId: context,
                        detail: "policy=long_form activated=\(activated) fallback=foreground "
                            + "route=\(Self.routeDescription(session))",
                        error: error
                    )
                    self.activateForegroundFallback(context: context)
                }
                completion()
            }
        }
    }

    /// ESS-41 B3 原路径：watchOS 冷启动默认会话下 AVAudioPlayer 可能静默无
    /// 输出，播放前必须激活 .playback；激活失败不中止播放尝试，但落取证日志。
    private func activateForegroundFallback(context: String?) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            WatchLog.info(
                "player", "session_activated", requestId: context,
                detail: "category=playback policy=foreground route=\(Self.routeDescription(session))"
            )
        } catch {
            WatchLog.error(
                "player", "session_activation_failed", requestId: context,
                detail: "policy=foreground route=\(Self.routeDescription(session))", error: error
            )
        }
    }

    private func beginPlayback(_ player: AVAudioPlayer, bytes: Int) {
        let started = player.play()
        if started {
            WatchLog.info(
                "player", "play_started", requestId: context,
                detail: String(format: "bytes=%d duration=%.2fs", bytes, player.duration)
            )
        } else {
            WatchLog.error(
                "player", "play_returned_false", requestId: context,
                detail: "bytes=\(bytes) duration=\(player.duration)",
                code: "ERR_PLAY_RETURNED_FALSE"
            )
            finishPlayback(successfully: false)
        }
    }

    /// 回前台钩子（ESS-58）：后台音频路径正常时声音一直在响，无事发生；
    /// App 曾被挂起截断（播放标记在、播放器已停）则原位续播，续不动才
    /// 判未播完——播放不允许静默消失。
    func recoverAfterForeground() {
        guard let audioPlayer else { return }
        let action = PlaybackRecoveryPolicy.onForeground(
            hasActivePlayback: isPlaying,
            playerReportsPlaying: audioPlayer.isPlaying
        )
        guard action == .resume else { return }
        let position = String(
            format: "pos=%.2fs duration=%.2fs", audioPlayer.currentTime, audioPlayer.duration
        )
        if audioPlayer.play() {
            WatchLog.info("player", "play_resumed", requestId: context, detail: position)
        } else {
            WatchLog.error(
                "player", "play_resume_failed", requestId: context,
                detail: position, code: "ERR_PLAY_RESUME"
            )
            finishPlayback(successfully: false)
        }
    }

    /// 当前播放进度快照（ESS-48 字幕对位）。按 context 对账：player 正在播
    /// 别的内容（如欢迎语）或已停止时返回 nil，字幕视图据此进入回看态。
    func progress(matching context: String) -> (time: TimeInterval, duration: TimeInterval)? {
        guard isPlaying, self.context == context, let audioPlayer, audioPlayer.duration > 0 else {
            return nil
        }
        return (audioPlayer.currentTime, audioPlayer.duration)
    }

    func stop(reason: String = "explicit") {
        if isPlaying, let audioPlayer {
            WatchLog.info(
                "player", "stopped", requestId: context,
                detail: String(
                    format: "reason=%@ pos=%.2fs duration=%.2fs",
                    reason, audioPlayer.currentTime, audioPlayer.duration
                )
            )
        }
        playbackGeneration += 1
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        onFinish = nil
        context = nil
    }

    private func finishPlayback(successfully: Bool) {
        audioPlayer = nil
        isPlaying = false
        context = nil
        let callback = onFinish
        onFinish = nil
        callback?(successfully)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            WatchLog.info("player", "play_finished", requestId: self.context, detail: "successfully=\(flag)")
            self.finishPlayback(successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            WatchLog.error(
                "player", "decode_error", requestId: self.context,
                code: "ERR_AUDIO_DECODE", error: error
            )
            self.isPlaying = false
            self.audioPlayer = nil
            self.onFinish = nil
            self.context = nil
        }
    }

    private static func routeDescription(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue)(\($0.portName))" }
            .joined(separator: "+")
        return outputs.isEmpty ? "none" : outputs
    }
}
