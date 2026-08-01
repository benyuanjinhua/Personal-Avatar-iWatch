import AVFoundation
import Foundation
import os

/// 语音播放器：只播真实链路语音（Qwen Audio Realtime 生成、AudioPipe 转码的
/// AAC/M4A），不做系统 TTS（ESS-40 起系统 TTS 随静态 demo 一并移除）。
///
/// ESS-38 复测加固：
/// - 完成回调携带 success——只有正常播完才算交付，调用方绝不能在失败时清文件；
/// - 播放前显式激活 AVAudioSession(.playback)：watchOS 冷启动默认会话下
///   AVAudioPlayer 可能 play()=true 但无声（与 ESS-41 B3 同因）；
/// - 全分支 os.Logger 取证（会话激活失败/解码失败/启动失败/起止），真机按
///   subsystem com.benyuan.wristagent.watch 过滤。
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    /// 最近一次播放失败的可读原因（语音失败必须可观测，不允许静默）。
    @Published private(set) var lastError: String?

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "SpeechPlayer")

    private var audioPlayer: AVAudioPlayer?
    private var onFinish: ((Bool) -> Void)?

    /// 播放语音片段（ESS-29）。数据只在内存中解密，不落明文文件。
    /// onFinish(success)：正常播完 → true；解码/启动/中途失败 → false。
    /// 主动 stop()（用户打断）不回调——打断不算失败也不算交付。
    @discardableResult
    func play(data: Data, onFinish: ((Bool) -> Void)? = nil) -> Bool {
        stop()
        lastError = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            let ns = error as NSError
            Self.logger.error("audio session activation failed: \(ns.domain, privacy: .public)#\(ns.code) \(ns.localizedDescription, privacy: .public)")
            lastError = "音频会话激活失败（\(ns.code)）"
            // 不中止：仍尝试播放，结果由 play() 返回值与回调体现
        }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            let ns = error as NSError
            Self.logger.error("AVAudioPlayer init failed (bytes=\(data.count)): \(ns.domain, privacy: .public)#\(ns.code)")
            lastError = "语音解码失败（\(ns.code)）"
            onFinish?(false)
            return false
        }
        player.delegate = self
        audioPlayer = player
        self.onFinish = onFinish
        player.prepareToPlay()
        isPlaying = player.play()
        if !isPlaying {
            Self.logger.error("AVAudioPlayer.play() returned false (bytes=\(data.count))")
            lastError = "语音播放启动失败"
            audioPlayer = nil
            self.onFinish = nil
            onFinish?(false)
        } else {
            Self.logger.info("playback started (bytes=\(data.count), duration=\(player.duration, format: .fixed(precision: 2))s)")
        }
        return isPlaying
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        onFinish = nil // 主动打断：不回调（既非成功交付，也非播放失败）
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            Self.logger.info("playback finished (successfully=\(flag))")
            if !flag { self.lastError = "语音播放中断（解码错误）" }
            self.isPlaying = false
            self.audioPlayer = nil
            let callback = self.onFinish
            self.onFinish = nil
            callback?(flag)
        }
    }
}
