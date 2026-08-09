import Foundation

// MARK: - ESS-650 Voice Barge-In Detector

/// Dedicated voice-activity detector for barge-in during AI answer playback.
///
/// F2-5 anti-false-trigger requirements:
/// - 400 ms silence window after playback starts (`playbackGuardMs`)
/// - Energy threshold +6 dB above normal speech RMS (`speechRMS`)
/// - 300 ms minimum continuous speech before triggering (`speechStartMs`)
///
/// This detector is separate from the normal conversation VAD — it runs only
/// during the `.speaking` turn phase when `voiceBargeInEnabled` is true, and
/// its output triggers `session_speaking_interrupted source=voice`.
public struct VoiceBargeInConfiguration: Equatable, Sendable {
    /// Sample rate of incoming PCM frames.
    public var sampleRate: Int
    /// RMS threshold — +6 dB above the normal conversation VAD threshold.
    /// Normal is 0.018; +6 dB = 0.018 × 2 ≈ 0.036.
    public var speechRMS: Double
    /// Minimum continuous speech duration before declaring barge-in (300 ms).
    public var speechStartMs: Int64
    /// Silence window after playback starts — reject everything in this
    /// window to prevent self-echo false triggers (400 ms).
    public var playbackGuardMs: Int64

    /// 相对正常对话 VAD 阈值抬高的分贝数。ESS-650 F2-5 规定 +6dB。
    public static let thresholdBoostDB: Double = 6.0

    /// ESS-650：由常态 VAD 阈值 + `thresholdBoostDB` **推导**，不写死 0.036。
    /// 常态阈值（`LocalVADConfiguration.speechRMS`）将来被调时这里自动跟随，
    /// 不会留下「常态阈值降了、打断阈值还停在旧值」的静默漂移。
    public static let defaultSpeechRMS: Double =
        LocalVADConfiguration().speechRMS * pow(10.0, thresholdBoostDB / 20.0)

    public init(
        sampleRate: Int = 16_000,
        speechRMS: Double = VoiceBargeInConfiguration.defaultSpeechRMS,
        speechStartMs: Int64 = 300,
        playbackGuardMs: Int64 = 400
    ) {
        precondition(sampleRate > 0)
        precondition(speechRMS >= 0)
        precondition(speechStartMs > 0)
        precondition(playbackGuardMs >= 0)
        self.sampleRate = sampleRate
        self.speechRMS = speechRMS
        self.speechStartMs = speechStartMs
        self.playbackGuardMs = playbackGuardMs
    }
}

public enum VoiceBargeInEvent: Equatable, Sendable {
    /// Speech detected for ≥ speechStartMs after the guard window.
    ///
    /// ESS-650：两个时刻都由 detector 给出，调用方不要再读一次时钟——
    /// - `startedAtMs`：起说时刻（连续段第一帧的起点）
    /// - `detectedAtMs`：判定命中时刻（凑满 `speechStartMs` 那一帧的终点）
    ///
    /// `detect_ms = detectedAtMs − startedAtMs`（ESS-655 契约：「起说 → 判定
    /// 命中」的真实耗时）。用「起播 → 起说」冒充 detect_ms 会把「用户第几秒
    /// 插的话」当成检测延迟，两者不是一回事。
    case bargeInDetected(startedAtMs: Int64, detectedAtMs: Int64)
    /// First frame above the RMS threshold — for logging only, not a trigger.
    case energySpike(atMs: Int64)
}

/// Deterministic PCM16 barge-in endpoint detector. Runs independently of the
/// normal conversation VAD; callers own the microphone during the speaking
/// phase and feed frames here. Fires exactly once per speaking phase
/// (absorbing — after the first trigger, all subsequent frames are ignored).
public struct VoiceBargeInDetector: Sendable {
    public private(set) var configuration: VoiceBargeInConfiguration

    private var speechCandidateStartedAtMs: Int64?
    private var speechStartedAtMs: Int64?
    private var guardUntilMs: Int64 = 0
    private var didFire = false
    /// Count of frames whose RMS ≥ configuration.speechRMS while the guard
    /// is still active. These are potential self-echo frames; the caller
    /// should accumulate this across multiple speaking rounds and report
    /// `session_barge_in_self_echo` at end-of-session or on gate evaluation.
    public private(set) var selfEchoFrameCount = 0

    // MARK: - 单轮对账（ESS-650 F2-5 的「零」需要能与「没在听」区分开）

    /// 本轮（自 `playbackStarted` 起）喂进来的总帧数。没有这个数，
    /// `self_echo_frames=0` 既可能是 AEC 干净、也可能是监听压根没跑起来，
    /// 两者在日志里长得一模一样。
    public private(set) var roundFrameCount = 0
    /// 本轮守卫窗内的超阈帧数。跨轮累计值仍在 `selfEchoFrameCount`。
    public private(set) var roundSelfEchoFrameCount = 0
    /// 本轮守卫窗内观测到的最大 RMS —— `session_barge_in_self_echo` 的
    /// `energy_db` 由它换算：只报「有没有回声」不够，要报「回声有多大」
    /// 才知道离阈值还剩多少余量。
    public private(set) var roundPeakGuardRMS: Double = 0

    /// 本轮守卫窗峰值的分贝（相对满量程）。无回声时返回 `-120.0`，
    /// 不返回 `-inf`——`energy_db` 要过 `.decimal` 校验。
    public var roundPeakGuardDB: Double {
        guard roundPeakGuardRMS > 0 else { return -120.0 }
        return max(-120.0, 20.0 * log10(roundPeakGuardRMS))
    }

    public init(configuration: VoiceBargeInConfiguration = VoiceBargeInConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    /// Call when answer playback starts. Arms the 400 ms guard window.
    public mutating func playbackStarted(atMs: Int64) {
        speechCandidateStartedAtMs = nil
        speechStartedAtMs = nil
        guardUntilMs = atMs + configuration.playbackGuardMs
        didFire = false
        // ESS-650：单轮对账清零；跨轮累计的 selfEchoFrameCount 不动。
        roundFrameCount = 0
        roundSelfEchoFrameCount = 0
        roundPeakGuardRMS = 0
    }

    /// Call when answer playback ends normally (not interrupted).
    /// Resets internal state; selfEchoFrameCount persists across rounds.
    public mutating func playbackEnded() {
        speechCandidateStartedAtMs = nil
        speechStartedAtMs = nil
        didFire = false
    }

    /// Reset the entire detector (including self-echo counter).
    public mutating func reset(atMs: Int64 = 0) {
        speechCandidateStartedAtMs = nil
        speechStartedAtMs = nil
        guardUntilMs = atMs
        didFire = false
        selfEchoFrameCount = 0
        roundFrameCount = 0
        roundSelfEchoFrameCount = 0
        roundPeakGuardRMS = 0
    }

    // MARK: - Detection

    /// Feed a PCM16 frame. Returns `.bargeInDetected` exactly once per
    /// speaking phase when the continuous-speech threshold is crossed.
    public mutating func processPCM16(
        _ pcm: Data,
        frameStartedAtMs: Int64
    ) -> [VoiceBargeInEvent] {
        guard !pcm.isEmpty else { return [] }
        let frameDurationMs = durationMs(forPCM16ByteCount: pcm.count)
        guard frameDurationMs > 0 else { return [] }
        // ESS-650：帧计数在吸收态之后照记——「本轮到底收了多少帧」是
        // 「监听确实在跑」的证据，不该因为已经触发过就停止记账。
        roundFrameCount += 1
        guard !didFire else { return [] }
        let frameEndedAtMs = frameStartedAtMs + frameDurationMs
        let rms = LocalVADEndpointer.rms(ofPCM16: pcm)
        let isSpeech = rms >= configuration.speechRMS

        // Frame falls inside the guard window → count as potential self-echo.
        if frameEndedAtMs <= guardUntilMs {
            if isSpeech {
                selfEchoFrameCount += 1
                roundSelfEchoFrameCount += 1
                roundPeakGuardRMS = max(roundPeakGuardRMS, rms)
            }
            return []
        }

        guard isSpeech else {
            speechCandidateStartedAtMs = nil
            return []
        }

        // First energy spike outside the guard window — log it.
        var events: [VoiceBargeInEvent] = []
        if speechStartedAtMs == nil && speechCandidateStartedAtMs == nil {
            events.append(.energySpike(atMs: frameStartedAtMs))
        }

        if speechStartedAtMs == nil {
            let candidateStart = speechCandidateStartedAtMs ?? frameStartedAtMs
            speechCandidateStartedAtMs = candidateStart
            if frameEndedAtMs - candidateStart >= configuration.speechStartMs {
                speechStartedAtMs = candidateStart
                didFire = true
                events.append(.bargeInDetected(
                    startedAtMs: candidateStart, detectedAtMs: frameEndedAtMs
                ))
            }
        }

        return events
    }

    // MARK: - Internal

    private func durationMs(forPCM16ByteCount byteCount: Int) -> Int64 {
        let samples = byteCount / MemoryLayout<Int16>.size
        return Int64(samples * 1_000 / configuration.sampleRate)
    }
}
