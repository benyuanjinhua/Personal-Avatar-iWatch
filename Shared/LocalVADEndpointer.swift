import Foundation

public struct LocalVADConfiguration: Equatable, Sendable {
    public var sampleRate: Int
    /// 判定门的**上限**：帧能量超过它一定算语音。历史固定阈值（-35 dBFS），
    /// `VoiceBargeInDetector` 也以它为基准，故语义与取值保持不变。
    public var speechRMS: Double
    /// 判定门的**下限**：噪声底再低，门也不会低于它。
    ///
    /// ESS-865：`.voiceChat`（AEC）路径下麦克风增益比 `.spokenAudio` 低得多，
    /// 固定 0.018 的门在真机上一次都没被跨过（08-11 起 13 次录音 0 次
    /// `speech_started`，而 `.spokenAudio` 的 08-09/08-10 是 68 次录音 29 次）。
    /// 下限取 -49 dBFS，让被 AEC 压低的正常说话仍能起判。
    public var minimumSpeechRMS: Double
    /// 相对噪声底的信噪比要求（线性倍数，3.0 ≈ +9.5 dB）。
    public var noiseFloorRatio: Double
    /// 噪声底的最小统计窗口。窗内取最小值作为底噪估计（min-statistics）。
    public var noiseWindowMs: Int64
    public var speechStartMs: Int64
    public var endpointSilenceMs: Int64
    public var playbackGuardMs: Int64
    /// 单轮硬上限。**必须小于 `AudioRecorder.maxDuration`**：AVAudioRecorder
    /// 到点自停后本地 AAC 收尾会走进「从未起录」误判（ESS-865 真机
    /// `raw_ms=61912` / `bytes=261121` 被整轮丢弃）。
    public var maximumTurnMs: Int64

    public init(
        sampleRate: Int = 16_000,
        speechRMS: Double = 0.018,
        minimumSpeechRMS: Double = 0.0035,
        noiseFloorRatio: Double = 3.0,
        noiseWindowMs: Int64 = 2_000,
        speechStartMs: Int64 = 100,
        endpointSilenceMs: Int64 = 700,
        playbackGuardMs: Int64 = 300,
        maximumTurnMs: Int64 = 55_000
    ) {
        precondition(sampleRate > 0)
        precondition(speechRMS >= 0)
        precondition(minimumSpeechRMS >= 0)
        precondition(minimumSpeechRMS <= speechRMS)
        precondition(noiseFloorRatio >= 1)
        precondition(noiseWindowMs > 0)
        precondition(speechStartMs > 0)
        precondition(endpointSilenceMs > 0)
        precondition(playbackGuardMs >= 0)
        precondition(maximumTurnMs > 0)
        self.sampleRate = sampleRate
        self.speechRMS = speechRMS
        self.minimumSpeechRMS = minimumSpeechRMS
        self.noiseFloorRatio = noiseFloorRatio
        self.noiseWindowMs = noiseWindowMs
        self.speechStartMs = speechStartMs
        self.endpointSilenceMs = endpointSilenceMs
        self.playbackGuardMs = playbackGuardMs
        self.maximumTurnMs = maximumTurnMs
    }
}

public enum LocalVADEvent: Equatable, Sendable {
    public enum FinalReason: String, Equatable, Sendable {
        case silence
        case maximumDuration = "maximum_duration"
    }

    case speechStarted(atMs: Int64)
    case speechFinal(atMs: Int64, reason: FinalReason)
}

/// ESS-865：每轮的能量取证快照。真机上「VAD 为什么不断句」此前完全不可观测
/// （日志里既没有电平也没有门限），这是本单排查耗掉一整轮真机的直接原因。
public struct LocalVADMetrics: Equatable, Sendable {
    public var frameCount: Int
    public var speechFrameCount: Int
    public var lastRMS: Double
    public var peakRMS: Double
    public var noiseFloorRMS: Double
    public var thresholdRMS: Double
    public var didDetectSpeech: Bool

    /// 供 `WatchLog.detail` 直接拼接的一行取证串。
    public var logDetail: String {
        func fixed(_ value: Double) -> String { String(format: "%.5f", value) }
        return "frames=\(frameCount) speech_frames=\(speechFrameCount) "
            + "rms=\(fixed(lastRMS)) peak_rms=\(fixed(peakRMS)) "
            + "noise_floor=\(fixed(noiseFloorRMS)) threshold=\(fixed(thresholdRMS)) "
            + "speech_detected=\(didDetectSpeech)"
    }
}

/// Deterministic PCM16 endpoint detector. Callers own the microphone and use
/// the emitted events to drive their session reducer and commit transaction.
///
/// ESS-865：判定门从「固定绝对阈值」改为「噪声底 × 信噪比，并被绝对上下限
/// 夹住」。固定阈值同时有两个失败方向，真机各踩中一个：门相对麦克风增益偏高
/// 时**永不断句**（本单），偏低时把环境噪声当说话。噪声底用最小统计
/// （窗内最小值）估计——语音的音节间谷底远高于真实静音，所以窗口内的最小值
/// 收敛到底噪而不是说话人电平。
public struct LocalVADEndpointer: Sendable {
    public private(set) var configuration: LocalVADConfiguration

    private var turnStartedAtMs: Int64 = 0
    private var speechCandidateStartedAtMs: Int64?
    private var speechStartedAtMs: Int64?
    private var lastSpeechAtMs: Int64?
    private var guardUntilMs: Int64 = 0
    private var isFinal = false

    // 最小统计：当前子窗最小值 + 上一个完整子窗最小值，噪声底取二者较小。
    private var currentWindowMinRMS = Double.infinity
    private var previousWindowMinRMS = Double.infinity
    private var windowStartedAtMs: Int64 = 0
    private var observedFrameCount = 0
    private var speechFrameCount = 0
    private var lastRMS: Double = 0
    private var peakRMS: Double = 0

    /// 预热帧数：底噪估计至少要这么多帧才作数，`speechStarted` 也要等到
    /// 预热完成才确认。
    ///
    /// 为什么起判也要等：预热窗内判定门只能取绝对下限（最灵敏），稳态环境噪声
    /// 会被判成说话；若此时就确认起判，噪声房间里每一轮都会「起判 → 0.7s 后
    /// 断句 → 提交一段噪声 → 没听清 → 重新聆听」空转。等 300ms 拿到底噪再确认，
    /// 噪声就落在门下。代价只是「起判时刻」晚 300ms——**音频本身一帧不丢**
    /// （所有帧从第 0 帧起照常上行），候选起点也保留原时刻。
    private static let noiseFloorWarmupFrames = 3

    private var isNoiseFloorWarmedUp: Bool {
        observedFrameCount >= Self.noiseFloorWarmupFrames
    }

    public init(configuration: LocalVADConfiguration = LocalVADConfiguration()) {
        self.configuration = configuration
    }

    public mutating func updateConfiguration(_ configuration: LocalVADConfiguration) {
        self.configuration = configuration
    }

    public mutating func reset(atMs: Int64 = 0) {
        turnStartedAtMs = atMs
        speechCandidateStartedAtMs = nil
        speechStartedAtMs = nil
        lastSpeechAtMs = nil
        guardUntilMs = atMs
        isFinal = false
        currentWindowMinRMS = .infinity
        previousWindowMinRMS = .infinity
        windowStartedAtMs = atMs
        observedFrameCount = 0
        speechFrameCount = 0
        lastRMS = 0
        peakRMS = 0
    }

    /// 回答播完：开一段回声守卫窗，并把本轮聆听窗重新起算（用户的下一句
    /// 只可能发生在回答播完之后）。
    public mutating func playbackEnded(atMs: Int64) {
        speechCandidateStartedAtMs = nil
        lastSpeechAtMs = nil
        guardUntilMs = atMs + configuration.playbackGuardMs
        turnStartedAtMs = guardUntilMs
        windowStartedAtMs = guardUntilMs
    }

    /// 当前判定门。噪声底 × 信噪比，被 `[minimumSpeechRMS, speechRMS]` 夹住。
    public var thresholdRMS: Double {
        min(configuration.speechRMS,
            max(configuration.minimumSpeechRMS, noiseFloorRMS * configuration.noiseFloorRatio))
    }

    /// 当前底噪估计。预热完成前返回「刚好让门落在绝对下限」的值。
    public var noiseFloorRMS: Double {
        let observed = min(currentWindowMinRMS, previousWindowMinRMS)
        guard isNoiseFloorWarmedUp, observed.isFinite else {
            return configuration.minimumSpeechRMS / configuration.noiseFloorRatio
        }
        return observed
    }

    public var metrics: LocalVADMetrics {
        LocalVADMetrics(
            frameCount: observedFrameCount,
            speechFrameCount: speechFrameCount,
            lastRMS: lastRMS,
            peakRMS: peakRMS,
            noiseFloorRMS: noiseFloorRMS,
            thresholdRMS: thresholdRMS,
            didDetectSpeech: speechStartedAtMs != nil
        )
    }

    public mutating func processPCM16(_ pcm: Data, frameStartedAtMs: Int64) -> [LocalVADEvent] {
        guard !isFinal, !pcm.isEmpty else { return [] }
        let frameDurationMs = durationMs(forPCM16ByteCount: pcm.count)
        guard frameDurationMs > 0 else { return [] }
        let frameEndedAtMs = frameStartedAtMs + frameDurationMs

        // 上限从**本轮起点**算，不再要求「已经起判过语音」。真机上正是
        // 「一次都没起判」那条路径把回合悬到 60s 录音自停之后（ESS-865）。
        if frameEndedAtMs - turnStartedAtMs >= configuration.maximumTurnMs {
            isFinal = true
            return [.speechFinal(atMs: frameEndedAtMs, reason: .maximumDuration)]
        }

        // 回声守卫窗内的帧既不判定也不参与底噪统计——它们是扬声器余音。
        guard frameStartedAtMs >= guardUntilMs else { return [] }

        let rms = Self.rms(ofPCM16: pcm)
        observeNoiseFloor(rms: rms, frameEndedAtMs: frameEndedAtMs)
        let isSpeech = rms >= thresholdRMS
        if isSpeech { speechFrameCount += 1 }

        if isSpeech {
            lastSpeechAtMs = frameEndedAtMs
            if speechStartedAtMs == nil {
                let candidateStart = speechCandidateStartedAtMs ?? frameStartedAtMs
                speechCandidateStartedAtMs = candidateStart
                if isNoiseFloorWarmedUp,
                   frameEndedAtMs - candidateStart >= configuration.speechStartMs {
                    speechStartedAtMs = candidateStart
                    return [.speechStarted(atMs: candidateStart)]
                }
            }
            return []
        }

        speechCandidateStartedAtMs = nil
        guard speechStartedAtMs != nil, let lastSpeechAtMs else { return [] }
        if frameEndedAtMs - lastSpeechAtMs >= configuration.endpointSilenceMs {
            isFinal = true
            return [.speechFinal(atMs: frameEndedAtMs, reason: .silence)]
        }
        return []
    }

    /// 滑动最小统计。子窗满一个 `noiseWindowMs` 就轮转，噪声底取「当前子窗
    /// 最小值」与「上一个完整子窗最小值」中较小者——保证估计覆盖至少一个
    /// 完整窗口的历史，同时能在一个窗口内跟上环境变化。
    private mutating func observeNoiseFloor(rms: Double, frameEndedAtMs: Int64) {
        observedFrameCount += 1
        lastRMS = rms
        peakRMS = max(peakRMS, rms)
        if frameEndedAtMs - windowStartedAtMs > configuration.noiseWindowMs {
            previousWindowMinRMS = currentWindowMinRMS
            currentWindowMinRMS = .infinity
            windowStartedAtMs = frameEndedAtMs
        }
        currentWindowMinRMS = min(currentWindowMinRMS, rms)
    }

    public static func rms(ofPCM16 pcm: Data) -> Double {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumSquares = 0.0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples.prefix(sampleCount) {
                let normalized = Double(Int16(littleEndian: sample)) / Double(Int16.max)
                sumSquares += normalized * normalized
            }
        }
        return sqrt(sumSquares / Double(sampleCount))
    }

    private func durationMs(forPCM16ByteCount byteCount: Int) -> Int64 {
        let samples = byteCount / MemoryLayout<Int16>.size
        return Int64(samples * 1_000 / configuration.sampleRate)
    }
}
