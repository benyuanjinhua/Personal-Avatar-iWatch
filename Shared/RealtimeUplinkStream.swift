import Foundation

/// ESS-321 uplink state machine. Owns the sequence counter for the single
/// stream a turn produces, tracks the one-shot fallback flag and enforces
/// the reachable-only best-effort semantics of the fast channel.
///
/// Transport binding lives outside this type (`WatchVoiceTransport` posts the
/// resulting chunks via `sendMessageData`; `PhoneRealtimeSession` forwards them
/// through the WSS session). The state machine is deterministic and pure so
/// that the ESS-321 simulated closed loop can exercise all edge cases without
/// touching WatchConnectivity / AVAudioEngine.
struct RealtimeUplinkStream: Sendable {
    enum Frame: Equatable, Sendable {
        case streamStart(RealtimeStreamStart)
        case audioAppend(VoiceStreamChunk)
        case audioCommit(RealtimeStreamCommit)
    }

    enum FallbackReason: Equatable, Sendable {
        case cancelled
        case transportFailed
        case backpressure
        case sequenceOverflow
        /// The microphone tap started but produced no PCM before commit.
        /// Committing an empty upstream buffer is guaranteed to fail, so use
        /// the retained complete-file recording instead of silently ending.
        case noAudioFrames
        case invalidPayload(VoiceStreamValidationError)
    }

    enum Outcome: Equatable, Sendable {
        case emitted([Frame])
        case ignoredAfterCommit
        case ignoredAfterFallback
        /// Duplicate audio.append received for a sequence already emitted —
        /// e.g. transport retry harness re-submitting a chunk. Sequence stays
        /// monotonic, no frame is emitted.
        case duplicate
        case fallback(FallbackReason)
    }

    let requestId: String
    let sessionId: String
    let format: RealtimeMediaFormat
    let maxSequenceGap: Int
    let maxInFlightBytes: Int
    let sequenceLimit: Int

    private(set) var nextSequence: Int = 0
    private(set) var inFlightBytes: Int = 0
    private(set) var didStart = false
    private(set) var didCommit = false
    private(set) var didFallback = false
    private(set) var fallbackReason: FallbackReason?
    private var emittedSequences: [Int: Int] = [:]

    init(
        requestId: String,
        sessionId: String,
        format: RealtimeMediaFormat = .uplinkPCM16,
        maxSequenceGap: Int = 32,
        maxInFlightBytes: Int = 256 * 1024,
        sequenceLimit: Int = 4_096
    ) {
        precondition(UUID(uuidString: requestId) != nil, "requestId must be a UUID string")
        precondition(UUID(uuidString: sessionId) != nil, "sessionId must be a UUID string")
        self.requestId = requestId
        self.sessionId = sessionId
        self.format = format
        self.maxSequenceGap = maxSequenceGap
        self.maxInFlightBytes = maxInFlightBytes
        self.sequenceLimit = sequenceLimit
    }

    /// Emit the `stream.start` frame. Idempotent: repeated calls return no
    /// frames (they still count as a normal ack, not a fallback trigger).
    mutating func start(capturedAtMs: Int64) -> Outcome {
        guard !didFallback else { return .ignoredAfterFallback }
        guard !didStart else { return .emitted([]) }
        didStart = true
        return .emitted([.streamStart(RealtimeStreamStart(
            requestId: requestId,
            sessionId: sessionId,
            format: format,
            capturedAtMs: capturedAtMs
        ))])
    }

    /// Append a raw PCM frame. The state machine assigns the next monotonic
    /// sequence and returns the emitted `audio.append` frame (or a fallback
    /// signal if the frame violates the contract).
    mutating func appendPCM(_ payload: Data, capturedAtMs: Int64, endOfStream: Bool = false) -> Outcome {
        guard !didFallback else { return .ignoredAfterFallback }
        guard !didCommit else { return .ignoredAfterCommit }
        guard didStart else {
            // `start` is a hard precondition — a producer that skips it lost
            // its lifecycle discipline; fall back rather than fake a start.
            return trigger(fallback: .cancelled)
        }
        guard nextSequence < sequenceLimit else {
            return trigger(fallback: .sequenceOverflow)
        }
        guard inFlightBytes + payload.count <= maxInFlightBytes else {
            return trigger(fallback: .backpressure)
        }
        let sequence = nextSequence
        let chunk = VoiceStreamChunk(
            requestId: requestId,
            streamId: sessionId,
            direction: .uplink,
            sequence: sequence,
            capturedAtMs: capturedAtMs,
            codec: format.codec,
            sampleRate: format.sampleRate,
            payload: payload,
            endOfStream: endOfStream
        )
        if let error = VoiceStreamValidator().validate(chunk) {
            return trigger(fallback: .invalidPayload(error))
        }
        nextSequence += 1
        emittedSequences[sequence] = payload.count
        inFlightBytes += payload.count
        return .emitted([.audioAppend(chunk)])
    }

    /// Emit the `audio.commit` frame. After commit no more appends are accepted.
    mutating func commit(capturedAtMs: Int64) -> Outcome {
        guard !didFallback else { return .ignoredAfterFallback }
        guard didStart else { return trigger(fallback: .cancelled) }
        guard !didCommit else { return .emitted([]) }
        guard nextSequence > 0 else { return trigger(fallback: .noAudioFrames) }
        didCommit = true
        return .emitted([.audioCommit(RealtimeStreamCommit(
            requestId: requestId,
            sessionId: sessionId,
            sequence: nextSequence - 1,
            capturedAtMs: capturedAtMs
        ))])
    }

    /// Called when the transport (`sendMessageData` failure, WSS disconnect,
    /// system cancel) reports the fast channel is dead. First call flips the
    /// stream into fallback; subsequent calls are absorbed so the full-file
    /// path can only be triggered once per request.
    mutating func markTransportFailed() -> Outcome {
        trigger(fallback: .transportFailed)
    }

    /// Called on user cancel / new turn / lifecycle switch.
    mutating func markCancelled() -> Outcome {
        trigger(fallback: .cancelled)
    }

    /// Report a delivered ack from the peer. Frees the in-flight byte budget
    /// used by the sequenced payload; unknown sequences are ignored.
    @discardableResult
    mutating func acknowledge(sequence: Int, byteCount: Int) -> Bool {
        guard byteCount > 0,
              let emittedByteCount = emittedSequences[sequence],
              emittedByteCount == byteCount else { return false }
        emittedSequences.removeValue(forKey: sequence)
        inFlightBytes = max(0, inFlightBytes - emittedByteCount)
        return true
    }

    private mutating func trigger(fallback reason: FallbackReason) -> Outcome {
        if didFallback { return .ignoredAfterFallback }
        didFallback = true
        fallbackReason = reason
        emittedSequences.removeAll(keepingCapacity: false)
        inFlightBytes = 0
        return .fallback(reason)
    }
}

struct RealtimeStreamStart: Equatable, Sendable, Codable {
    let requestId: String
    let sessionId: String
    let codec: String
    let sampleRate: Int
    let channelCount: Int
    let capturedAtMs: Int64

    init(requestId: String, sessionId: String, format: RealtimeMediaFormat, capturedAtMs: Int64) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.codec = format.codec
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
        self.capturedAtMs = capturedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case codec
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
        case capturedAtMs = "captured_at_ms"
    }
}

struct RealtimeStreamCommit: Equatable, Sendable, Codable {
    let requestId: String
    let sessionId: String
    /// Sequence of the final `audio.append` frame. The Agent Gateway rejects
    /// a commit whose sequence does not equal its last accepted uplink frame.
    let sequence: Int
    let capturedAtMs: Int64

    init(requestId: String, sessionId: String, sequence: Int, capturedAtMs: Int64) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.sequence = sequence
        self.capturedAtMs = capturedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case sequence
        case capturedAtMs = "captured_at_ms"
    }
}
