import AVFoundation
import Combine
import Foundation

enum RecorderError: LocalizedError {
    case permissionDenied
    case sessionActivationFailed
    case cannotCreateRecorder
    case noRecording

    static let recordingTooShortDescription = "录音太短，请按住多说一会儿。"

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "麦克风权限未开启，请前往手表设置 → 隐私 → 麦克风，允许腕语访问。"
        case .sessionActivationFailed: return "录音启动失败，请松开后再按住重试。"
        case .cannotCreateRecorder: return "录音器启动失败，请松开后再按住重试。"
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
    /// ESS-219：录音开始的单调时钟戳，取代 AVAudioRecorder.currentTime
    /// 计时。真机在 2026-08-03 16:30/16:35 两次出现 duration_ms=5.1e7ms
    /// (≈14.2 小时，量级贴近 deviceCurrentTime/系统 uptime)——currentTime 在
    /// 会话被抢占 / record(forDuration:) 到点自停后不返回文档承诺的 0，
    /// 而是给出与 deviceCurrentTime 混淆的值。改用 DispatchTime 自己算差值。
    private var recordingStartUptime: DispatchTime?

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
            throw RecorderError.cannotCreateRecorder
        }
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true
        guard audioRecorder.prepareToRecord(), audioRecorder.record(forDuration: Self.maxDuration) else {
            WatchLog.error("recorder", "record_start_failed", code: "ERR_RECORD_START")
            throw RecorderError.cannotCreateRecorder
        }

        currentURL = url
        recorder = audioRecorder
        recordingStartUptime = .now()
        isRecording = true
        startMetering()
        WatchLog.info("recorder", "record_started", detail: "aac \(Self.sampleRate)Hz max=\(Int(Self.maxDuration))s")
    }

    /// 结束录音并保留文件（transferFile 需要文件在传输完成前存在）。
    func finish() throws -> Recording {
        // ESS-225 P0 hotfix（2026-08-04 09:05 真机复现）：
        // wall-clock delta（`elapsedRecordingMs()`）在 `releaseRequestedWhileStarting`
        // 路径下失真——用户按住 → `Task { await recorder.start() }` 在 `await
        // requestPermission()` 里挂起 → 用户释放触发 `pressEnded`（未见 isRecording
        // 因 start 尚未完成）→ `releaseRequestedWhileStarting = true` → start 恢复
        // 后跑完 `record()` 并立刻在完成 handler 里 `finishRecording()`——从
        // recordingStartUptime 到 finish() 内 elapsedRecordingMs() 只隔几毫秒，
        // 但 `AVAudioRecorder(prepareToRecord + record(forDuration: 60))` 已为 60s
        // 音频预分配了 ~24KB 的 M4A 容器表，文件字节数与真实音频毫不成比例。
        // 结果：`duration_ms=1/12`，进 `PushToTalkController.finishRecording` 的
        // `duration >= minimumAudioDurationMs (300)` 阈值判定后被 `recording_too_short_local`
        // 挡掉——用户按下、松手、请求根本不发。P0 用户可见阻断。
        //
        // 修法：`AVURLAsset(url:).duration` 读取 m4a 容器内 mdat 的真实音频秒数，
        // 这是唯一与文件字节数强相关的时长源。wall-clock 保留只做取证对照。
        let wallClockMs = elapsedRecordingMs()
        recorder?.stop()
        recordingStartUptime = nil
        stopMetering()
        isRecording = false
        releaseSession(reason: "finish")

        guard let url = currentURL, let data = try? Data(contentsOf: url), !data.isEmpty else {
            WatchLog.error(
                "recorder", "record_empty",
                detail: "duration_ms=\(wallClockMs)", code: "ERR_NO_RECORDING"
            )
            throw RecorderError.noRecording
        }
        currentURL = nil
        recorder = nil

        let assetMs = Self.audioAssetDurationMs(url: url)
        let durationMs = Self.sanitizeDurationMs(rawMs: assetMs ?? wallClockMs)

        // ESS-225 AC #5：字节数与时长严重不自洽时告警。asset 路径接管后，
        // 触发条件收窄为「asset 也读不出真实时长 & wall-clock 又与字节数不匹配」——
        // 未来同类漂移仍会自动可见，且带上 wall-clock/asset 两个证据字段。
        if let mismatchDetail = Self.durationBytesMismatch(durationMs: durationMs, bytes: data.count) {
            WatchLog.error(
                "recorder", "duration_bytes_inconsistent",
                detail: "\(mismatchDetail) wall_clock_ms=\(wallClockMs) asset_ms=\(assetMs.map(String.init) ?? "-")",
                code: "ERR_DURATION_INCONSISTENT"
            )
        }

        WatchLog.info(
            "recorder", "record_finished",
            detail: "duration_ms=\(durationMs) bytes=\(data.count) wall_clock_ms=\(wallClockMs) asset_ms=\(assetMs.map(String.init) ?? "-")"
        )
        return Recording(fileURL: url, data: data, durationMs: max(1, durationMs))
    }

    /// ESS-225 P0：读 m4a 容器内音频真实秒数，返回 ms；失败或非法（NaN/∞/≤0）返回 nil。
    /// AVURLAsset.duration 是 sync deprecated 但对本地小文件行为稳定——finish() 是
    /// sync 契约（transferFile 依赖同步返回 Recording），保持 sync 优于把整条链改 async。
    static func audioAssetDurationMs(url: URL) -> Int? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    func cancel() {
        WatchLog.info("recorder", "record_cancelled")
        recorder?.stop()
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
        currentURL = nil
        recorder = nil
        recordingStartUptime = nil
        isRecording = false
        stopMetering()
        releaseSession(reason: "cancel")
    }

    /// ESS-219：单调时钟计算录音时长，并对超过 `maxDuration` 的异常量级
    /// 留痕、截断到上限。返回值保证在 `[0, maxDuration*1000]` 区间内，
    /// 供 `record_finished` 落日志与 `Recording.durationMs` 一致使用。
    private func elapsedRecordingMs() -> Int {
        guard let start = recordingStartUptime else { return 0 }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return Self.sanitizeDurationMs(rawMs: Int(elapsedNs / 1_000_000))
    }

    /// ESS-219 验收标准：`duration_ms` 超过录音上限视为计算错误，留痕后截断。
    /// 独立 static 便于单测直接验证边界，无需真实起录。
    static func sanitizeDurationMs(rawMs: Int) -> Int {
        let maxMs = Int(maxDuration * 1000)
        if rawMs > maxMs {
            WatchLog.error(
                "recorder", "record_duration_out_of_range",
                detail: "raw_ms=\(rawMs) max_ms=\(maxMs)",
                code: "ERR_DURATION_OVERFLOW"
            )
            return maxMs
        }
        return max(0, rawMs)
    }

    /// ESS-225 AC #5 防御门：字节数与时长不自洽时返回 detail，调用点落
    /// `duration_bytes_inconsistent` 事件。AAC 32kbps ≈ 4000B/s；expected_ms
    /// = bytes * 1000 / 4000；允许 3× 冗余覆盖 AAC 起始/结束帧与容器开销。
    ///
    /// 真机窗口 (2026-08-03 16:20~16:40) 校准：
    /// - 正常样本 `duration_ms=4318 bytes=42887` → expected≈10721 → 门内（3573~32163）
    /// - 异常样本 `duration_ms=51129344 bytes=43296` → expected≈10824 → 门外（触发）
    /// - 异常样本 `duration_ms=31 bytes=24588`     → expected≈6147  → 门外（触发）
    ///
    /// <4KB 的样本走 too_short 阈值判定，本门不参与以避免噪声。
    static func durationBytesMismatch(durationMs: Int, bytes: Int) -> String? {
        guard bytes >= 4_000, durationMs >= 0 else { return nil }
        let bytesPerSecond = 4_000 // AVEncoderBitRateKey 32_000 bps
        let expectedMs = bytes * 1_000 / bytesPerSecond
        let lowerBound = expectedMs / 3
        let upperBound = expectedMs * 3
        guard durationMs < lowerBound || durationMs > upperBound else { return nil }
        return "duration_ms=\(durationMs) bytes=\(bytes) expected_ms≈\(expectedMs)"
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
