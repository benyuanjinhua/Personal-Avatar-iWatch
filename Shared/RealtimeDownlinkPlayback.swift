import Foundation

/// ESS-321 downlink playback buffer.
///
/// The watch receives 24k PCM16 `audio.delta` chunks from the bridge. This
/// buffer:
///
///  * enforces session/request isolation — late frames from a stale session
///    never enter the current playback pipeline (barge-in case);
///  * reorders out-of-order frames within a bounded sequence window and
///    guarantees monotonic emission to the real playback engine;
///  * caps total buffered bytes so runaway downlinks do not exhaust the
///    watch's tiny RAM;
///  * absorbs the single fallback signal — after we lose the fast channel
///    only one full-file playback path may run per turn.
///
/// The buffer is pure and side-effect-free. Callers (`RealtimePlaybackEngine`
/// on watch, tests on the simulated closed loop) drive it deterministically
/// and dispatch the resulting frames to their playback engine of choice.
struct RealtimeDownlinkPlayback: Sendable {
    struct SessionKey: Equatable, Hashable, Sendable {
        let requestId: String
        let sessionId: String

        init(requestId: String, sessionId: String) {
            self.requestId = requestId
            self.sessionId = sessionId
        }
    }

    enum DropReason: Equatable, Sendable {
        case staleSession(SessionKey)
        case bargedInBefore
        case sessionEnded
        case duplicate
        case validation(VoiceStreamValidationError)
    }

    enum FallbackReason: Equatable, Sendable {
        case sequenceWindowExceeded
        case backpressure
        case gapTimedOut
        case bridgeReportedFallback
        case invalidChunk(VoiceStreamValidationError)
    }

    enum Outcome: Equatable, Sendable {
        case buffered
        case ready([VoiceStreamChunk])
        case dropped(DropReason)
        case fallback(FallbackReason)
        case alreadyFellBack
        case bargedIn(cleared: Int)
    }

    let format: RealtimeMediaFormat
    let maxBufferedBytes: Int
    let maxSequenceWindow: Int
    let validator: VoiceStreamValidator

    private(set) var currentSession: SessionKey?
    private(set) var didFallback = false
    private(set) var didSessionEnd = false
    private(set) var nextSequence: Int = 0
    private(set) var bufferedBytes: Int = 0
    private var pending: [Int: VoiceStreamChunk] = [:]
    private var emittedSequences: Set<Int> = []

    init(
        format: RealtimeMediaFormat = .downlinkPCM16,
        maxBufferedBytes: Int = 384 * 1024,
        maxSequenceWindow: Int = 48,
        validator: VoiceStreamValidator = VoiceStreamValidator(
            maxPayloadBytes: 64 * 1024,
            allowedCodecs: ["pcm_s16le"],
            allowedSampleRates: [24_000]
        )
    ) {
        self.format = format
        self.maxBufferedBytes = maxBufferedBytes
        self.maxSequenceWindow = maxSequenceWindow
        self.validator = validator
    }

    /// Point the buffer at a new (requestId, sessionId) pair. Any pending
    /// frames from a prior session are dropped as if `bargeIn` had fired,
    /// and the sequence counter resets.
    @discardableResult
    mutating func attach(session: SessionKey) -> Outcome {
        let previousBytes = bufferedBytes
        pending.removeAll(keepingCapacity: false)
        emittedSequences.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        nextSequence = 0
        didFallback = false
        didSessionEnd = false
        currentSession = session
        return .bargedIn(cleared: previousBytes)
    }

    /// User started a new turn / interrupted an in-flight response mid-play.
    /// Clears every buffered byte and reports how many bytes were dropped so
    /// the caller can log an evidence event. The current session is retained
    /// so subsequent `audio.delta` for the same session are still admitted.
    @discardableResult
    mutating func bargeIn() -> Outcome {
        let previousBytes = bufferedBytes
        pending.removeAll(keepingCapacity: false)
        emittedSequences.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        nextSequence = 0
        didSessionEnd = false
        return .bargedIn(cleared: previousBytes)
    }

    /// End of a session (either `audio.done` or `response.interrupted`).
    /// Late frames after this are dropped as `.sessionEnded`.
    @discardableResult
    mutating func endSession() -> Outcome {
        didSessionEnd = true
        return .buffered
    }

    /// Feed the next `audio.delta` chunk into the buffer.
    mutating func ingest(_ chunk: VoiceStreamChunk) -> Outcome {
        guard let session = currentSession else {
            return .dropped(.staleSession(SessionKey(requestId: chunk.requestId, streamId: chunk.streamId)))
        }
        guard chunk.requestId == session.requestId, chunk.streamId == session.sessionId else {
            return .dropped(.staleSession(SessionKey(requestId: chunk.requestId, streamId: chunk.streamId)))
        }
        guard chunk.direction == .downlink else {
            return .dropped(.validation(.unsupportedCodec)) // reused error surface
        }
        guard !didFallback else { return .alreadyFellBack }
        guard !didSessionEnd else { return .dropped(.sessionEnded) }
        if let error = validator.validate(chunk) {
            return trigger(fallback: .invalidChunk(error))
        }

        if chunk.sequence < nextSequence || pending[chunk.sequence] != nil ||
            emittedSequences.contains(chunk.sequence) {
            return .dropped(.duplicate)
        }
        guard chunk.sequence - nextSequence <= maxSequenceWindow else {
            return trigger(fallback: .sequenceWindowExceeded)
        }
        guard bufferedBytes + chunk.payload.count <= maxBufferedBytes else {
            return trigger(fallback: .backpressure)
        }

        pending[chunk.sequence] = chunk
        bufferedBytes += chunk.payload.count

        var ready: [VoiceStreamChunk] = []
        while let contiguous = pending.removeValue(forKey: nextSequence) {
            bufferedBytes -= contiguous.payload.count
            emittedSequences.insert(nextSequence)
            ready.append(contiguous)
            nextSequence += 1
        }
        return ready.isEmpty ? .buffered : .ready(ready)
    }

    /// Callers drive this from their own clock — a real timer on the watch,
    /// a virtual clock in tests. Triggers the one-shot fallback when the head
    /// of line has been stuck too long.
    mutating func gapTimedOut() -> Outcome {
        guard !didFallback else { return .alreadyFellBack }
        guard !pending.isEmpty else { return .buffered }
        return trigger(fallback: .gapTimedOut)
    }

    /// Called when the bridge itself reports the fast channel failed (e.g.
    /// upstream `stream.dropped` or WSS teardown). Absorbing: identical
    /// semantics to a local gap timeout so the caller only ever executes
    /// the full-file fallback once.
    mutating func markBridgeFallback() -> Outcome {
        trigger(fallback: .bridgeReportedFallback)
    }

    private mutating func trigger(fallback reason: FallbackReason) -> Outcome {
        guard !didFallback else { return .alreadyFellBack }
        didFallback = true
        pending.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        return .fallback(reason)
    }
}

private extension RealtimeDownlinkPlayback.SessionKey {
    init(requestId: String, streamId: String) {
        self.init(requestId: requestId, sessionId: streamId)
    }
}
