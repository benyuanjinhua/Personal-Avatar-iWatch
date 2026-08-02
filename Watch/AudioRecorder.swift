import AVFoundation
import Combine
import Foundation

enum RecorderError: LocalizedError {
    case permissionDenied
    case sessionActivationFailed
    case cannotCreateRecorder
    case noRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "没有麦克风权限，请在手表设置中允许腕语使用麦克风。"
        case .sessionActivationFailed: return "录音启动失败，请松开后再按住重试。"
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
        guard granted else {
            WatchLog.error("recorder", "permission_denied", code: "ERR_MIC_PERMISSION")
            throw RecorderError.permissionDenied
        }

        // ESS-61：上一次播放会把共享会话设成 .longFormAudio 路由策略（ESS-58），
        // 该策略是粘性的且与 .playAndRecord 不相容，不显式复位则 setCategory/
        // setActive 抛 -50（paramErr），录音全灭。尝试序列见 AudioSessionPolicy。
        let session = AVAudioSession.sharedInstance()
        var attempt = AudioSessionPolicy.nextRecordingAttempt(after: nil)
        var configured = false
        while let current = attempt {
            do {
                try Self.configureSession(session, attempt: current)
                if current != .resetRoutePolicy {
                    WatchLog.info("recorder", "session_recovered", detail: "attempt=\(current)")
                }
                configured = true
                break
            } catch {
                WatchLog.error(
                    "recorder", "session_activation_failed",
                    detail: "attempt=\(current)", error: error
                )
                attempt = AudioSessionPolicy.nextRecordingAttempt(after: current)
            }
        }
        guard configured else {
            // 原始 OSStatus 只进上面的日志；用户看到的是可行动中文文案（F3）。
            throw RecorderError.sessionActivationFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wristagent-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let audioRecorder: AVAudioRecorder
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            WatchLog.error("recorder", "recorder_init_failed", error: error)
            throw error
        }
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true
        guard audioRecorder.prepareToRecord(), audioRecorder.record(forDuration: Self.maxDuration) else {
            WatchLog.error("recorder", "record_start_failed", code: "ERR_RECORD_START")
            throw RecorderError.cannotCreateRecorder
        }

        currentURL = url
        recorder = audioRecorder
        isRecording = true
        startMetering()
        WatchLog.info("recorder", "record_started", detail: "aac \(Self.sampleRate)Hz max=\(Int(Self.maxDuration))s")
    }

    /// 结束录音并保留文件（transferFile 需要文件在传输完成前存在）。
    func finish() throws -> Recording {
        let durationMs = Int(((recorder?.currentTime ?? 0) * 1000).rounded())
        recorder?.stop()
        stopMetering()
        isRecording = false
        releaseSession(reason: "finish")

        guard let url = currentURL, let data = try? Data(contentsOf: url), !data.isEmpty else {
            WatchLog.error(
                "recorder", "record_empty",
                detail: "duration_ms=\(durationMs)", code: "ERR_NO_RECORDING"
            )
            throw RecorderError.noRecording
        }
        currentURL = nil
        recorder = nil
        WatchLog.info("recorder", "record_finished", detail: "duration_ms=\(durationMs) bytes=\(data.count)")
        return Recording(fileURL: url, data: data, durationMs: max(1, durationMs))
    }

    func cancel() {
        WatchLog.info("recorder", "record_cancelled")
        recorder?.stop()
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
        currentURL = nil
        recorder = nil
        isRecording = false
        stopMetering()
        releaseSession(reason: "cancel")
    }

    /// ESS-72：录音结束必须把共享会话交还出去。录音把会话激活成
    /// .playAndRecord 后一直占着资源，紧随其后的播放两级激活全部
    /// !res（AVAudioSession resourceNotAvailable, 561145203）——ESS-61 修了
    /// 「播放 → 录音」方向，这里补上「录音 → 播放」方向。失败不抛错
    /// （播放侧激活自会重试并留痕），但必须留 session_released 事件：
    /// 全量取证里 recorder 模块此前没有任何交还观测点，修没修都无法验证。
    private func releaseSession(reason: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            WatchLog.info("recorder", "session_released", detail: "reason=\(reason) result=true")
        } catch {
            WatchLog.error(
                "recorder", "session_released",
                detail: "reason=\(reason) result=false", error: error
            )
        }
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

    /// 录音会话配置（ESS-61 F1）。两条路都要覆盖「上一次播放用过 long_form」
    /// 的前置状态：先 setActive(false, .notifyOthersOnDeactivation) 清掉播放
    /// 侧的激活（失败不致命——播放器在 pressBegan 已停，残留激活也会被随后
    /// 的 setCategory 覆盖），再用带 policy 参数的重载显式声明 .default 复位
    /// 路由策略。minimal 回落去掉 mode/options，只保留最简 .playAndRecord。
    private static func configureSession(
        _ session: AVAudioSession, attempt: AudioSessionPolicy.RecordingAttempt
    ) throws {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        switch attempt {
        case .resetRoutePolicy:
            if #available(watchOS 11.0, *) {
                try session.setCategory(
                    .playAndRecord, mode: .spokenAudio, policy: .default, options: [.allowBluetooth]
                )
            } else {
                try session.setCategory(.playAndRecord, mode: .spokenAudio, policy: .default, options: [])
            }
        case .minimal:
            try session.setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
        }
        try session.setActive(true)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
