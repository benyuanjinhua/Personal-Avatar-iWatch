import Combine
import Foundation

/// 按住说话（ESS-22）：按下开始录音（最长 60 秒），松开生成
/// UUIDv7 request_id + 版本化信封，交给 WatchVoiceTransport 发送。
@MainActor
final class PushToTalkController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var recordingLevel: Float = 0

    let transport = WatchVoiceTransport()
    private let recorder = AudioRecorder()

    init() {
        recorder.$level
            .receive(on: RunLoop.main)
            .assign(to: &$recordingLevel)
    }

    func pressBegan() {
        guard state == .idle else { return }
        errorMessage = nil
        state = .recording
        Task {
            do {
                try await recorder.start()
            } catch {
                state = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    func pressEnded() {
        guard state == .recording else { return }
        state = .finishing
        defer { state = .idle }
        do {
            let recording = try recorder.finish()
            let envelope = VoiceRequestEnvelope.voiceRequest(
                audio: VoiceAudioDescriptor(
                    codec: "aac",
                    sampleRate: AudioRecorder.sampleRate,
                    channels: AudioRecorder.channels,
                    durationMs: recording.durationMs,
                    sha256: VoiceDigest.sha256Hex(of: recording.data)
                )
            )
            transport.send(envelope: envelope, recording: recording)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pressCancelled() {
        guard state == .recording else { return }
        recorder.cancel()
        state = .idle
    }
}
