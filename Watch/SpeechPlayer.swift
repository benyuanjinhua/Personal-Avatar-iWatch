import AVFoundation
import Foundation
import os

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
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "SpeechPlayer")

    private var audioPlayer: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private var currentContext: SpeechPlaybackContext?

    /// 播放语音片段（ESS-29）。数据只在内存中解密，不落明文文件。
    /// ESS-41 B3：播放前必须激活 .playback 会话——watchOS 冷启动默认会话下
    /// AVAudioPlayer 可能静默无输出（play() 返回 true 但听不到），这正是
    /// 真机欢迎语不响的首要候选根因。激活失败不中止播放尝试，但落取证日志。
    @discardableResult
    func play(data: Data, context: SpeechPlaybackContext, onFinish: (() -> Void)? = nil) -> Bool {
        stop()
        let rid = context.requestId
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let route = session.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            Self.logger.info("session activated (request_id=\(rid, privacy: .public), source=\(context.source, privacy: .public), route=\(route, privacy: .public))")
        } catch {
            Self.logger.error("session activation failed (request_id=\(rid, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        guard let player = try? AVAudioPlayer(data: data) else {
            Self.logger.error("AVAudioPlayer init failed (request_id=\(rid, privacy: .public), bytes=\(data.count))")
            onFinish?()
            return false
        }
        player.delegate = self
        audioPlayer = player
        self.onFinish = onFinish
        currentContext = context
        isPlaying = player.play()
        if !isPlaying {
            Self.logger.error("AVAudioPlayer.play() returned false (request_id=\(rid, privacy: .public), bytes=\(data.count))")
            audioPlayer = nil
            self.onFinish = nil
            currentContext = nil
            onFinish?()
        } else {
            Self.logger.info("playback started (request_id=\(rid, privacy: .public), source=\(context.source, privacy: .public), bytes=\(data.count), duration=\(player.duration, format: .fixed(precision: 2))s)")
        }
        return isPlaying
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        onFinish = nil
        currentContext = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let rid = self.currentContext?.requestId ?? "?"
            Self.logger.info("playback finished (request_id=\(rid, privacy: .public), successfully=\(flag))")
            self.isPlaying = false
            self.audioPlayer = nil
            self.currentContext = nil
            let callback = self.onFinish
            self.onFinish = nil
            callback?()
        }
    }
}
