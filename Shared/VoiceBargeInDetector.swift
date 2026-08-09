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

    public init(
        sampleRate: Int = 16_000,
        speechRMS: Double = 0.036,
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
    /// `atMs` is the wall-clock ms when the detector crossed the threshold.
    case bargeInDetected(atMs: Int64)
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
    }

    // MARK: - Detection

    /// Feed a PCM16 frame. Returns `.bargeInDetected` exactly once per
    /// speaking phase when the continuous-speech threshold is crossed.
    public mutating func processPCM16(
        _ pcm: Data,
        frameStartedAtMs: Int64
    ) -> [VoiceBargeInEvent] {
        guard !didFire, !pcm.isEmpty else { return [] }
        let frameDurationMs = durationMs(forPCM16ByteCount: pcm.count)
        guard frameDurationMs > 0 else { return [] }
        let frameEndedAtMs = frameStartedAtMs + frameDurationMs
        let isSpeech = LocalVADEndpointer.rms(ofPCM16: pcm) >= configuration.speechRMS

        // Frame falls inside the guard window → count as potential self-echo.
        if frameEndedAtMs <= guardUntilMs {
            if isSpeech { selfEchoFrameCount += 1 }
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
                events.append(.bargeInDetected(atMs: candidateStart))
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
