import AVFoundation
import Foundation

@MainActor
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, cloudAudioBase64: String? = nil) {
        stop()
        if
            let cloudAudioBase64,
            let data = Data(base64Encoded: cloudAudioBase64),
            let player = try? AVAudioPlayer(data: data)
        {
            audioPlayer = player
            player.play()
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.49
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
    }
}

