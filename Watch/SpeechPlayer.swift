import AVFoundation
import Foundation

/// 语音播放器：只播真实链路语音（Qwen Audio Realtime 生成、AudioPipe 转码的
/// AAC/M4A），不做系统 TTS（ESS-40 起系统 TTS 随静态 demo 一并移除）。
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false

    private var audioPlayer: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    /// 播放语音片段（ESS-29）。数据只在内存中解密，不落明文文件。
    @discardableResult
    func play(data: Data, onFinish: (() -> Void)? = nil) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(data: data) else {
            onFinish?()
            return false
        }
        player.delegate = self
        audioPlayer = player
        self.onFinish = onFinish
        isPlaying = player.play()
        if !isPlaying {
            audioPlayer = nil
            self.onFinish = nil
            onFinish?()
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
            self.isPlaying = false
            self.audioPlayer = nil
            let callback = self.onFinish
            self.onFinish = nil
            callback?()
        }
    }
}
