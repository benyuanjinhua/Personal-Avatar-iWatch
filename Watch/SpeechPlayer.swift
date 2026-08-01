import AVFoundation
import Foundation
import os

/// 语音播放器：只播真实链路语音（Qwen Audio Realtime 生成、AudioPipe 转码的
/// AAC/M4A），不做系统 TTS（ESS-40 起系统 TTS 随静态 demo 一并移除）。
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "SpeechPlayer")

    private var audioPlayer: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    /// 播放语音片段（ESS-29）。数据只在内存中解密，不落明文文件。
    /// ESS-41 B3：播放前必须激活 .playback 会话——watchOS 冷启动默认会话下
    /// AVAudioPlayer 可能静默无输出（play() 返回 true 但听不到），这正是
    /// 真机欢迎语不响的首要候选根因。激活失败不中止播放尝试，但落取证日志。
    @discardableResult
    func play(data: Data, onFinish: (() -> Void)? = nil) -> Bool {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            Self.logger.error("audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
        guard let player = try? AVAudioPlayer(data: data) else {
            Self.logger.error("AVAudioPlayer init failed (bytes=\(data.count))")
            onFinish?()
            return false
        }
        player.delegate = self
        audioPlayer = player
        self.onFinish = onFinish
        isPlaying = player.play()
        if !isPlaying {
            Self.logger.error("AVAudioPlayer.play() returned false (bytes=\(data.count))")
            audioPlayer = nil
            self.onFinish = nil
            onFinish?()
        } else {
            Self.logger.info("playback started (bytes=\(data.count), duration=\(player.duration, format: .fixed(precision: 2))s)")
        }
        return isPlaying
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        onFinish = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            Self.logger.info("playback finished (successfully=\(flag))")
            self.isPlaying = false
            self.audioPlayer = nil
            let callback = self.onFinish
            self.onFinish = nil
            callback?()
        }
    }
}
