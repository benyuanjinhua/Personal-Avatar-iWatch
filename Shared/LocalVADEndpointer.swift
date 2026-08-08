import Foundation

public struct LocalVADConfiguration: Equatable, Sendable {
    public var sampleRate: Int
    public var speechRMS: Double
    public var speechStartMs: Int64
    public var endpointSilenceMs: Int64
    public var playbackGuardMs: Int64
    public var maximumTurnMs: Int64

    public init(
        sampleRate: Int = 16_000,
        speechRMS: Double = 0.018,
        speechStartMs: Int64 = 100,
        endpointSilenceMs: Int64 = 700,
        playbackGuardMs: Int64 = 300,
        maximumTurnMs: Int64 = 60_000
    ) {
        precondition(sampleRate > 0)
        precondition(speechRMS >= 0)
        precondition(speechStartMs > 0)
        precondition(endpointSilenceMs > 0)
        precondition(playbackGuardMs >= 0)
        precondition(maximumTurnMs > 0)
        self.sampleRate = sampleRate
        self.speechRMS = speechRMS
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

/// Deterministic PCM16 endpoint detector. Callers own the microphone and use
/// the emitted events to drive their session reducer and commit transaction.
public struct LocalVADEndpointer: Sendable {
    public private(set) var configuration: LocalVADConfiguration

    private var speechCandidateStartedAtMs: Int64?
    private var speechStartedAtMs: Int64?
    private var lastSpeechAtMs: Int64?
    private var guardUntilMs: Int64 = 0
    private var isFinal = false

    public init(configuration: LocalVADConfiguration = LocalVADConfiguration()) {
        self.configuration = configuration
    }

    public mutating func updateConfiguration(_ configuration: LocalVADConfiguration) {
        self.configuration = configuration
    }

    public mutating func reset(atMs: Int64 = 0) {
        speechCandidateStartedAtMs = nil
        speechStartedAtMs = nil
        lastSpeechAtMs = nil
        guardUntilMs = atMs
        isFinal = false
    }

    public mutating func playbackEnded(atMs: Int64) {
        speechCandidateStartedAtMs = nil
        lastSpeechAtMs = nil
        guardUntilMs = atMs + configuration.playbackGuardMs
    }

    public mutating func processPCM16(_ pcm: Data, frameStartedAtMs: Int64) -> [LocalVADEvent] {
        guard !isFinal, !pcm.isEmpty else { return [] }
        let frameDurationMs = durationMs(forPCM16ByteCount: pcm.count)
        guard frameDurationMs > 0 else { return [] }
        let frameEndedAtMs = frameStartedAtMs + frameDurationMs

        if let startedAt = speechStartedAtMs,
           frameEndedAtMs - startedAt >= configuration.maximumTurnMs {
            isFinal = true
            return [.speechFinal(atMs: frameEndedAtMs, reason: .maximumDuration)]
        }

        guard frameStartedAtMs >= guardUntilMs else { return [] }
        let isSpeech = Self.rms(ofPCM16: pcm) >= configuration.speechRMS

        if isSpeech {
            lastSpeechAtMs = frameEndedAtMs
            if speechStartedAtMs == nil {
                let candidateStart = speechCandidateStartedAtMs ?? frameStartedAtMs
                speechCandidateStartedAtMs = candidateStart
                if frameEndedAtMs - candidateStart >= configuration.speechStartMs {
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
