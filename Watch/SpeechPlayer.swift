import AVFoundation
import Foundation

@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, cloudAudioBase64: String? = nil) {
        stop()
        if
            let cloudAudioBase64,
            let data = Data(base64Encoded: cloudAudioBase64)
        {
            if play(data: data) { return }
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.49
        synthesizer.speak(utterance)
    }

    /// 播放 Mac 返回的语音片段（ESS-29）。数据只在内存中解密，不落明文文件。
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
        synthesizer.stopSpeaking(at: .immediate)
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
