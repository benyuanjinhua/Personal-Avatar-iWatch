import AVFoundation
import Combine
import Foundation

enum RecorderError: LocalizedError {
    case permissionDenied
    case sessionActivationFailed
    case cannotCreateRecorder
    case noRecording
    /// ESS-375: 短按（tap-and-release）导致 AVAudioRecorder.record() 返回后
    /// 尚未开始采集就被 stop()，产出只有容器头（~24KB）的空文件。
    case recordingNeverStarted
    /// ESS-538: 录音进行中被降腕息屏/会话中断截断，容器内只剩不可用残片
    /// （裁决见 RecordingInterruptionPolicy）。残片不提交回合——真机实测
    /// 316ms 残片走完上传+识别全程后「没听清，请重说」。
    case recordingInterrupted

    static let recordingTooShortDescription = "按住时间太短，请按住不放再说。"

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "麦克风权限未开启，请前往手表设置 → 隐私 → 麦克风，允许腕语访问。"
        case .sessionActivationFailed: return "录音启动失败，请松开后再按住重试。"
        case .cannotCreateRecorder: return "录音器启动失败，请松开后再按住重试。"
        case .noRecording: return "没有录到语音。"
        case .recordingNeverStarted: return RecorderError.recordingTooShortDescription
        case .recordingInterrupted: return "刚才录音被打断了，请按住重新说一次。"
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

    /// ESS-375: AAC 32kbps / 16kHz / mono / max=60s 配置下，M4A 容器(fytp+moov)的
    /// 固定开销量级。AVAudioRecorder.record(forDuration:) 在调用时就写入容器头并预分配
    /// mdat，若在音频采集真正开始前 stop()，文件只含容器结构，字节数 ≈ 此值。
    /// 08-04/08-05 四次取证均得 bytes=24588（跨两天、跨录音不变）—— 真实 AAC 录音
    /// 不存在此现象。用作「录音从未开始」的辅助判据。
    static let m4aContainerOverheadApprox = 24_588

    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var streamTimer: Timer?
    private var streamOffset = 0
    private var streamHandler: ((Data, Bool) -> Void)?
    private var currentURL: URL?
    /// ESS-219：录音开始的单调时钟戳，取代 AVAudioRecorder.currentTime
    /// 计时。真机在 2026-08-03 16:30/16:35 两次出现 duration_ms=5.1e7ms
    /// (≈14.2 小时，量级贴近 deviceCurrentTime/系统 uptime)——currentTime 在
    /// 会话被抢占 / record(forDuration:) 到点自停后不返回文档承诺的 0，
    /// 而是给出与 deviceCurrentTime 混淆的值。改用 DispatchTime 自己算差值。
    private var recordingStartUptime: DispatchTime?
    /// ESS-538：本次录音是否观测到断流（AVAudioSession 中断 .began，或
    /// 录音期间 scene 离开 active——降腕息屏）。只打标记不主动 stop，
    /// 收尾时交 RecordingInterruptionPolicy 裁决丢弃残片 / 放行完整录音。
    private var wasInterrupted = false
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        // ESS-538：录音中的会话中断此前零观测点——息屏断流后 recorder 仍按
        // 手势照常收尾，316ms 残片被当正常录音提交。与 SpeechPlayer 同款
        // 观察 interruptionNotification，began 打标记，ended 按系统建议续录。
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleSessionInterruption(notification) }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// ESS-538：外部断流标记（scene 离开 active / 会话中断 began）。
    /// 不主动 stop——用户可能立即抬腕续上（见中断 ended 续录），且手势
    /// 收尾路径必须保持原有语义；残片丢弃由 finish() 收尾时裁决。
    func noteExternalInterruption(reason: String) {
        guard isRecording else { return }
        let alreadyMarked = wasInterrupted
        wasInterrupted = true
        WatchLog.info(
            "recorder", "record_interrupted",
            detail: "reason=\(reason) already_marked=\(alreadyMarked)"
        )
    }

    /// ESS-538：录音中的会话中断处置。began 只打标记+留痕（系统此刻已断
    /// 音频，是否丢弃等手势收尾时按 RecordingInterruptionPolicy 裁决）；
    /// ended 且系统建议恢复时原地续录（快速降腕又抬腕、仍按着不放的场景
    /// 能救回尾部）。续录用剩余额度重设 maxDuration，守住 60s 上限。
    private func handleSessionInterruption(_ notification: Notification) {
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard let kind = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
        switch kind {
        case .began:
            noteExternalInterruption(reason: "audio_session_interruption")
        case .ended:
            guard isRecording, let recorder else { return }
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard options.contains(.shouldResume) else {
                WatchLog.info("recorder", "record_interruption_ended", detail: "resume=false")
                return
            }
            let remainingMs = max(0, Int(Self.maxDuration * 1000) - elapsedRecordingMs())
            let resumed = recorder.record(forDuration: TimeInterval(remainingMs) / 1_000)
            WatchLog.info(
                "recorder", "record_resumed",
                detail: "result=\(resumed) remaining_ms=\(remainingMs)"
            )
        @unknown default:
            return
        }
    }

    func start(streamHandler: ((Data, Bool) -> Void)? = nil) async throws {
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
        wasInterrupted = false
        self.streamHandler = streamHandler
        streamOffset = 0
        if streamHandler != nil {
            streamTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.emitStreamBytes(end: false) }
            }
        }
        startMetering()
        WatchLog.info("recorder", "record_started", detail: "aac \(Self.sampleRate)Hz max=\(Int(Self.maxDuration))s")
    }

    /// 结束录音并保留文件（transferFile 需要文件在传输完成前存在）。
    ///
    /// ESS-225 P0：wall-clock delta（`elapsedRecordingMs()`）在
    /// `PushToTalkController.releaseRequestedWhileStarting` 路径下失真——
    /// `start()` 的 `await requestPermission()` 挂起期间用户释放 → pressEnded
    /// 只置位 defer 标志 → start 恢复后立即 `finishRecording()`，从
    /// `recordingStartUptime` 到此处只隔几毫秒，但 `AVAudioRecorder` 已为 60s
    /// maxDuration 预分配了 ~24KB M4A 容器表。修法：`AVURLAsset(url:).duration`
    /// 读取 mdat 真实音频秒数作为主时长源，wall-clock 保留做取证对照。
    /// `AVURLAsset.duration` sync 虽 deprecated，但本地小文件行为稳定；
    /// `finish()` 是 sync 契约（transferFile 依赖同步返回 Recording），保持
    /// sync 优于把整条链改 async。
    ///
    /// ESS-375 字段口径说明（三者在单里必须同时出现、互相可对照）：
    /// - `duration_ms`：主时长（优先 `asset_ms`，回落 `wall_clock_ms`），
    ///   即 `sanitizeDurationMs(assetMs ?? wallClockMs)`，用作 Recording 入参。
    /// - `wall_clock_ms`：`elapsedRecordingMs()` 单调时钟差值，
    ///   起点 = `start()` 里 `recordingStartUptime = .now()` 那一刻（`record()` 返回后）。
    ///   口径偏大（包含了 recorder init 开销），仅取证对照，不作为主时长源。
    /// - `asset_ms`：`AVURLAsset(url:).duration` 读取的 M4A 容器内音频真实秒数 × 1000。
    ///   这是文件字节量最直接的时长映射，ESS-225 起作为主时长源。
    func finish() throws -> Recording {
        let wallClockMs = elapsedRecordingMs()

        // ESS-375: AVAudioRecorder.record() 是异步生效的——record() 返回后
        // 硬件可能尚未开始采集。短按路径下(record()→ stop() < 100ms) recorder
        // 的 isRecording 仍为 false，此时文件只含 M4A 容器头（~24KB），不含任何
        // 音频帧。先检查再 stop，避免产出固定大小空文件被误读为真实录音。
        let wasRecording = recorder?.isRecording == true
        recorder?.stop()
        emitStreamBytes(end: true)
        streamTimer?.invalidate()
        streamTimer = nil
        streamHandler = nil
        recordingStartUptime = nil
        stopMetering()
        isRecording = false
        releaseSession(reason: "finish")

        let assetMs = currentURL.flatMap { Self.audioAssetDurationMs(url: $0) }
        let durationMs = Self.sanitizeDurationMs(rawMs: assetMs ?? wallClockMs)

        guard let url = currentURL else {
            WatchLog.error(
                "recorder", "record_empty",
                detail: "duration_ms=\(durationMs) url=nil", code: "ERR_NO_RECORDING"
            )
            throw RecorderError.noRecording
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            let code = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                ? "ERR_FILE_NOT_FOUND" : "ERR_FILE_READ"
            WatchLog.error(
                "recorder", "record_read_failed",
                detail: "duration_ms=\(durationMs) error=\(error.localizedDescription)", code: code
            )
            throw RecorderError.noRecording
        }
        guard !data.isEmpty else {
            WatchLog.error(
                "recorder", "record_empty",
                detail: "duration_ms=\(wallClockMs)", code: "ERR_NO_RECORDING"
            )
            throw RecorderError.noRecording
        }

        // ESS-375: 录音从未真正开始 → 清理无效 M4A 文件后抛出专用错误。
        // 判定条件（OR）：① stop() 前 recorder.isRecording 为 false，或
        // ② 文件字节数 ≤ M4A 容器头近似值（24,588B），双重兜底确保不误判。
        //
        // bytes=24588 来源说明（R-04.3 待验证）：
        // 08-04/08-05 四次真机取证均得此值（跨两天、跨录音一字节不差），
        // 推断为 AVAudioRecorder 在 record(forDuration:) 时预分配的 M4A
        // 容器结构（ftyp+moov+空 mdat）。由于样本在手表上不可导出做 ffprobe
        // box dump，此结论当前属实证推断（empirical, 4/4 consistent），
        // 需真机验证时补充 ffprobe 取证。代码层用双重守卫（isRecording +
        // 字节数 ≤ 容器开销阈值）兜底，即使该值随系统版本变化也不漏判。
        if !wasRecording || data.count <= Self.m4aContainerOverheadApprox {
            WatchLog.error(
                "recorder", "recording_never_started",
                detail: "wall_clock_ms=\(wallClockMs) bytes=\(data.count) was_recording=\(wasRecording) container_overhead=\(Self.m4aContainerOverheadApprox)",
                code: "ERR_AUDIO_TOO_SHORT"
            )
            // ESS-375 L2 fix: 无效 M4A 文件必须在 throw 前清理。
            // 此前 currentURL/recorder 置 nil 在 throw 之后（不可达），
            // temp 文件泄漏、recorder 引用悬空。
            try? FileManager.default.removeItem(at: url)
            currentURL = nil
            recorder = nil
            throw RecorderError.recordingNeverStarted
        }

        // ESS-538: 录音被降腕息屏/会话中断截断、容器内只剩不可用残片 →
        // 丢弃并提示重说，不提交回合（真机实测 asset=316ms / wall=5.9s 的
        // 残片越过 300ms 解码门，走完上传+识别全程后「没听清，请重说」）。
        // 音频够长（用户说完才息屏）则照常提交——本 issue 验收的 fallback
        // 语义是「已录片段安全收尾」，不是一刀切丢弃。
        if RecordingInterruptionPolicy.shouldDiscardAsFragment(
            assetMs: assetMs, wallClockMs: wallClockMs, wasInterrupted: wasInterrupted
        ) {
            WatchLog.error(
                "recorder", "record_interrupted_discarded",
                detail: "asset_ms=\(assetMs.map(String.init) ?? "-") wall_clock_ms=\(wallClockMs) bytes=\(data.count) was_interrupted=\(wasInterrupted)",
                code: "ERR_RECORDING_INTERRUPTED"
            )
            try? FileManager.default.removeItem(at: url)
            currentURL = nil
            recorder = nil
            throw RecorderError.recordingInterrupted
        }

        currentURL = nil
        recorder = nil

        // ESS-225 AC #5：字节数与时长严重不自洽时告警。asset 路径接管后，
        // 正常路径不再触发；仅在 asset 也读不出且 wall-clock 又与字节数
        // 不匹配时才告警，带 wall_clock_ms / asset_ms 双字段对照。
        if let mismatchDetail = Self.durationBytesMismatch(durationMs: durationMs, bytes: data.count) {
            WatchLog.error(
                "recorder", "duration_bytes_inconsistent",
                detail: "\(mismatchDetail) wall_clock_ms=\(wallClockMs) asset_ms=\(assetMs.map(String.init) ?? "-")",
                code: "ERR_DURATION_INCONSISTENT"
            )
        }

        WatchLog.info(
            "recorder", "record_finished",
            detail: "duration_ms=\(durationMs) bytes=\(data.count) wall_clock_ms=\(wallClockMs) asset_ms=\(assetMs.map(String.init) ?? "-") interrupted=\(wasInterrupted)"
        )
        return Recording(fileURL: url, data: data, durationMs: max(1, durationMs))
    }

    /// ESS-225 P0：读 m4a 容器内音频真实秒数，返回 ms；失败或非法（≤0/NaN/∞）返回 nil。
    /// 用于取代 wall-clock 作为主时长源——wall-clock 在 `releaseRequestedWhileStarting`
    /// 路径下失真，而容器 duration 与文件字节数强相关，不受此影响。
    static func audioAssetDurationMs(url: URL) -> Int? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    func cancel() {
        WatchLog.info("recorder", "record_cancelled")
        recorder?.stop()
        streamTimer?.invalidate()
        streamTimer = nil
        streamHandler = nil
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
        currentURL = nil
        recorder = nil
        recordingStartUptime = nil
        isRecording = false
        stopMetering()
        releaseSession(reason: "cancel")
    }

    private func emitStreamBytes(end: Bool) {
        guard let streamHandler, let currentURL,
              let snapshot = try? Data(contentsOf: currentURL), snapshot.count >= streamOffset else { return }
        var offset = streamOffset
        while offset < snapshot.count {
            let upper = min(offset + 64 * 1024, snapshot.count)
            streamHandler(snapshot.subdata(in: offset..<upper), false)
            offset = upper
        }
        streamOffset = snapshot.count
        if end { streamHandler(Data(), true) }
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
