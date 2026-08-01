import AVFoundation
import Combine
import Foundation

enum RecorderError: LocalizedError {
    case permissionDenied
    case cannotCreateRecorder
    case noRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "没有麦克风权限，请在手表设置中允许腕语使用麦克风。"
        case .cannotCreateRecorder: return "无法启动录音，请稍后重试。"
        case .noRecording: return "没有录到语音。"
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    struct Recording {
        let fileURL: URL
        let data: Data
        let durationMs: Int
    }

    static let maxDuration: TimeInterval = 60
    static let sampleRate = 16_000
    static let channels = 1

    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentURL: URL?

    func start() async throws {
        let granted = await requestPermission()
        guard granted else { throw RecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        if #available(watchOS 11.0, *) {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth])
        } else {
            try session.setCategory(.playAndRecord, mode: .spokenAudio)
        }
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wristagent-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true
        guard audioRecorder.prepareToRecord(), audioRecorder.record(forDuration: Self.maxDuration) else {
            throw RecorderError.cannotCreateRecorder
        }

        currentURL = url
        recorder = audioRecorder
        isRecording = true
        startMetering()
    }

    /// 结束录音并保留文件（transferFile 需要文件在传输完成前存在）。
    func finish() throws -> Recording {
        let durationMs = Int(((recorder?.currentTime ?? 0) * 1000).rounded())
        recorder?.stop()
        stopMetering()
        isRecording = false

        guard let url = currentURL, let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw RecorderError.noRecording
        }
        currentURL = nil
        recorder = nil
        return Recording(fileURL: url, data: data, durationMs: max(1, durationMs))
    }

    func cancel() {
        recorder?.stop()
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
        currentURL = nil
        recorder = nil
        isRecording = false
        stopMetering()
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let decibels = recorder.averagePower(forChannel: 0)
                self.level = max(0.05, min(1, pow(10, decibels / 35)))
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
