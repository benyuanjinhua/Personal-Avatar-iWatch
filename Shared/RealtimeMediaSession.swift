import Foundation

/// ESS-321 coordinator that stitches the uplink sequencer and downlink
/// playback buffer together into a single turn-scoped façade.
///
/// The coordinator has no knowledge of AVAudioEngine, WCSession, or WSS. It
/// simply exposes deterministic transitions for a turn:
///
///   1. `beginTurn(requestId:)` — allocate a session id, prime uplink+downlink
///   2. `pushMicrophonePCM(_:)` — receive raw 16k mono PCM16 frames
///   3. `commitUplink()` — sender signalled end of user speech
///   4. `receiveDownlink(_:)` — enqueue a bridge-provided `audio.delta`
///   5. `bargeIn()` — user talked over the response, clear playback + abort
///      the current downlink session
///   6. `finishTurn(reason:)` — end the turn cleanly (audio.done, cancel, etc.)
///
/// The single `RealtimeMediaEvent` stream is the exhaust; the watch/iPhone
/// transports subscribe to it and forward frames on the wire, while
/// `RealtimePlaybackEngine` on watch consumes downlink `.playbackReady`
/// events. `Tests/` drive the coordinator directly to prove the closed loop.
final class RealtimeMediaSession {
    struct Configuration: Sendable {
        var uplinkFormat: RealtimeMediaFormat
        var downlinkFormat: RealtimeMediaFormat
        var uplinkFrameBytes: Int
        var maxInFlightUplinkBytes: Int
        var maxDownlinkBufferBytes: Int
        var maxUplinkSequence: Int

        init(
            uplinkFormat: RealtimeMediaFormat = .uplinkPCM16,
            downlinkFormat: RealtimeMediaFormat = .downlinkPCM16,
            uplinkFrameBytes: Int = 2 * 16_000 / 10, // 100 ms of 16k mono PCM16 = 3200 bytes
            maxInFlightUplinkBytes: Int = 256 * 1024,
            maxDownlinkBufferBytes: Int = 384 * 1024,
            maxUplinkSequence: Int = 4_096
        ) {
            self.uplinkFormat = uplinkFormat
            self.downlinkFormat = downlinkFormat
            self.uplinkFrameBytes = uplinkFrameBytes
            self.maxInFlightUplinkBytes = maxInFlightUplinkBytes
            self.maxDownlinkBufferBytes = maxDownlinkBufferBytes
            self.maxUplinkSequence = maxUplinkSequence
        }
    }

    enum Event: Equatable, Sendable {
        case uplinkStart(RealtimeStreamStart)
        case uplinkAppend(VoiceStreamChunk)
        case uplinkCommit(RealtimeStreamCommit)
        case uplinkFallback(RealtimeUplinkStream.FallbackReason, RealtimeMediaSession.TurnHandle)
        /// ESS-330 v3: playable chunks carry their own response_id so late
        /// contiguous releases don't inherit a globally-latest id.
        case playbackReady([RealtimeDownlinkPlayback.PlayableChunk])
        case playbackCleared(bytesDropped: Int)
        case playbackFallback(RealtimeDownlinkPlayback.FallbackReason, RealtimeMediaSession.TurnHandle)
        case downlinkDropped(RealtimeDownlinkPlayback.DropReason)
        /// ESS-404 §3.3: `audio.done` arrived. `outcome` distinguishes barrier
        /// released vs waiting vs `-1` zero-audio vs the degrade path when
        /// `final_sequence` is absent.
        case doneArrived(TurnHandle, RealtimeDownlinkPlayback.DoneOutcome)
        /// ESS-404 §3.3: the barrier crossed after new deltas landed. Distinct
        /// from `doneArrived` so the coordinator's caller can emit
        /// `done_barrier_released` at exactly the moment of release.
        case doneBarrierReleased(TurnHandle, finalSequence: Int, responseId: String?)
        /// ESS-404 §5: Watch asks iPhone to advance generation. Adapter
        /// forwards this as a `bargein.request` uplink envelope.
        case bargeInRequested(TurnHandle, fromGeneration: Int)
        /// ESS-404 §3.5: gate promoted to `.open(generation)` — pending
        /// window closed, deltas resume.
        case generationOpened(TurnHandle, fromGeneration: Int?, toGeneration: Int)
        case turnFinished(TurnHandle, FinishReason)
    }

    enum FinishReason: Equatable, Sendable {
        case audioDone
        case cancelled
        case interrupted
        case fallback
    }

    struct TurnHandle: Equatable, Hashable, Sendable {
        let requestId: String
        let sessionId: String

        init(requestId: String, sessionId: String) {
            self.requestId = requestId
            self.sessionId = sessionId
        }
    }

    let configuration: Configuration
    private let now: () -> Int64
    private let sessionIdFactory: () -> String

    /// Deterministic clock injection for tests; production uses wall time.
    init(
        configuration: Configuration = Configuration(),
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        sessionIdFactory: @escaping () -> String = { UUID().uuidString }
    ) {
        self.configuration = configuration
        self.now = now
        self.sessionIdFactory = sessionIdFactory
    }

    private var pcmScratch = Data()
    private var currentTurn: TurnHandle?
    private var uplink: RealtimeUplinkStream?
    private(set) var downlink = RealtimeDownlinkPlayback()

    /// Fanout for `Event`s. The transport / playback engine subscribes exactly
    /// once each; the closed-loop tests subscribe from XCTest.
    var onEvent: ((Event) -> Void)?

    var activeTurn: TurnHandle? { currentTurn }

    /// Start a new turn. Any in-flight uplink is aborted (single-fallback)
    /// and the downlink buffer barges in so the old session's late frames
    /// are rejected.
    func beginTurn(requestId: String) -> TurnHandle {
        finishTurn(reason: .interrupted)
        let sessionId = sessionIdFactory()
        let handle = TurnHandle(requestId: requestId, sessionId: sessionId)
        currentTurn = handle
        var stream = RealtimeUplinkStream(
            requestId: requestId,
            sessionId: sessionId,
            format: configuration.uplinkFormat,
            maxInFlightBytes: configuration.maxInFlightUplinkBytes,
            sequenceLimit: configuration.maxUplinkSequence
        )
        let startOutcome = stream.start(capturedAtMs: now())
        uplink = stream
        pcmScratch.removeAll(keepingCapacity: true)
        _ = downlink.attach(session: RealtimeDownlinkPlayback.SessionKey(
            requestId: requestId, sessionId: sessionId
        ))
        emit(outcome: startOutcome, handle: handle)
        return handle
    }

    /// Feed raw microphone bytes. The coordinator packs them into
    /// `configuration.uplinkFrameBytes`-sized frames (100 ms by default) and
    /// emits one `audio.append` per full frame. Any tail bytes stay in the
    /// scratch buffer until the next call.
    func pushMicrophonePCM(_ data: Data) {
        guard let handle = currentTurn else { return }
        guard var stream = uplink, !stream.didFallback, !stream.didCommit else { return }
        pcmScratch.append(data)
        let frameBytes = configuration.uplinkFrameBytes
        while pcmScratch.count >= frameBytes {
            let frame = pcmScratch.prefix(frameBytes)
            pcmScratch.removeFirst(frameBytes)
            let outcome = stream.appendPCM(Data(frame), capturedAtMs: now())
            emit(outcome: outcome, handle: handle)
            if case .fallback = outcome { break }
        }
        uplink = stream
    }

    /// User released the button (or the recorder finished). Flushes any tail
    /// bytes as one final `audio.append` (marked endOfStream) and emits the
    /// `audio.commit` frame.
    func commitUplink() {
        guard let handle = currentTurn, var stream = uplink else { return }
        if !pcmScratch.isEmpty, !stream.didFallback, !stream.didCommit {
            let tail = pcmScratch
            pcmScratch.removeAll(keepingCapacity: true)
            let outcome = stream.appendPCM(tail, capturedAtMs: now(), endOfStream: true)
            emit(outcome: outcome, handle: handle)
        }
        let commit = stream.commit(capturedAtMs: now())
        emit(outcome: commit, handle: handle)
        uplink = stream
    }

    /// Transport reported the fast uplink is dead (`sendMessageData` failure,
    /// WSS teardown, etc.). Absorbs the single fallback signal per turn.
    func markUplinkTransportFailed() {
        guard let handle = currentTurn, var stream = uplink else { return }
        let outcome = stream.markTransportFailed()
        uplink = stream
        emit(outcome: outcome, handle: handle)
    }

    /// User cancelled mid-record.
    func cancelUplink() {
        guard let handle = currentTurn, var stream = uplink else { return }
        let outcome = stream.markCancelled()
        uplink = stream
        emit(outcome: outcome, handle: handle)
    }

    /// Feed a downlink `audio.delta` chunk into the playback buffer. The
    /// coordinator publishes `.playbackReady([...])` when contiguous frames
    /// have accumulated and are ready for the playback engine.
    /// `responseId` is the Bridge `audio.delta.response_id` for this chunk;
    /// the reorder buffer keeps the pairing intact across out-of-order
    /// releases so playback receipts route to the correct response.
    /// `generation` is the ESS-404 turn generation; nil traces the legacy
    /// admit path so pre-ESS-403 traffic still works during rollout.
    func receiveDownlink(
        _ chunk: VoiceStreamChunk,
        responseId: String? = nil,
        generation: Int? = nil
    ) {
        guard let handle = currentTurn else {
            onEvent?(.downlinkDropped(.staleSession(
                RealtimeDownlinkPlayback.SessionKey(requestId: chunk.requestId, sessionId: chunk.streamId)
            )))
            return
        }
        let outcome = downlink.ingest(chunk, responseId: responseId, generation: generation)
        switch outcome {
        case .ready(let frames):
            onEvent?(.playbackReady(frames))
        case .buffered, .alreadyFellBack:
            break
        case .bargedIn(let cleared):
            onEvent?(.playbackCleared(bytesDropped: cleared))
        case .dropped(let reason):
            onEvent?(.downlinkDropped(reason))
        case .fallback(let reason):
            onEvent?(.playbackFallback(reason, handle))
        }
        // ESS-404 §3.3: a delta that filled the barrier's missing set must
        // trigger release right here — otherwise the coordinator would sit
        // on `pendingFinalSequence` until the next barrier tick and delay
        // `player.finish(...)` past the point of the last render.
        if let release = downlink.checkBarrierRelease() {
            if case .barrierReleased(let final, let responseId) = release {
                _ = downlink.endSession()
                onEvent?(.doneBarrierReleased(handle, finalSequence: final, responseId: responseId))
            }
        }
    }

    /// ESS-404 §3.3: `audio.done` arrived for the current turn. Delegates to
    /// the buffer's barrier logic and emits `doneArrived(...)` with the
    /// decision. `generation` guards against stale done events closing a
    /// newer generation's session (U8 core regression).
    func receiveDone(
        finalSequence: Int?,
        responseId: String? = nil,
        generation: Int? = nil
    ) {
        guard let handle = currentTurn else { return }
        let outcome = downlink.markDone(
            finalSequence: finalSequence, responseId: responseId, generation: generation
        )
        onEvent?(.doneArrived(handle, outcome))
        switch outcome {
        case .barrierReleased, .zeroAudio:
            // Barrier released synchronously — either seq 0…n already there
            // or the explicit `-1` zero-audio contract. Safe to close the
            // downlink session so late frames from THIS response are
            // rejected as `.sessionEnded` (a new response's deltas still
            // arrive under the same generation once the coordinator's next
            // turn opens).
            _ = downlink.endSession()
        case .missingFinalSequence:
            // Gateway did not send `final_sequence` (legacy / rollout).
            // Spec §3.2 row 3 degrades to `n = max emitted seq` — meaning
            // we treat the barrier as already satisfied by what we have
            // and release. The drain still fires (so the player renders
            // the tail and the multi-response turn stays alive), but the
            // structured contract-violation log is what makes the error
            // visible so the Gateway side gets fixed.
            break
        case .waiting,
             .droppedStaleGeneration,
             .droppedFutureGeneration,
             .droppedPendingGeneration:
            break
        }
    }

    /// ESS-404 §3.4: 2.0 s done-barrier timer fired without the barrier
    /// releasing. Delegates to the buffer's single-shot fallback path so
    /// the caller only ever executes the structured-failure flow once.
    func doneBarrierTimeout() {
        guard let handle = currentTurn else { return }
        let outcome = downlink.doneBarrierTimedOut()
        if case .fallback(let reason) = outcome {
            onEvent?(.playbackFallback(reason, handle))
        }
    }

    /// ESS-404 §3.5: iPhone confirmed the new generation. Promotes the
    /// downlink gate and emits `generationOpened(...)` so the adapter can
    /// log `bargein_generation_opened`.
    func openGeneration(_ generation: Int) {
        guard let handle = currentTurn else { return }
        let previous = downlink.activeGeneration
        _ = downlink.openGeneration(generation)
        onEvent?(.generationOpened(handle, fromGeneration: previous, toGeneration: generation))
    }

    /// User talked over the response — dump every buffered downlink byte,
    /// transition the gate to `.pending`, and ask the transport to send a
    /// `bargein.request` up to iPhone so it can advance the generation.
    ///
    /// **ESS-404 §5**: the pending window drops every incoming event until
    /// `openGeneration(_:)` fires. `fromGeneration` is the generation Watch
    /// last observed (or -1 if the gate was still `.unset`).
    func bargeInDownlink() {
        guard let handle = currentTurn else { return }
        let fromGeneration = downlink.activeGeneration ?? -1
        let cleared = downlink.bargeIn()
        if case .bargedIn(let bytes) = cleared { onEvent?(.playbackCleared(bytesDropped: bytes)) }
        onEvent?(.bargeInRequested(handle, fromGeneration: fromGeneration))
    }

    /// Bridge WSS reported the downlink fast channel died — collapse to the
    /// existing full-file fallback exactly once per turn.
    func markDownlinkBridgeFallback() {
        guard let handle = currentTurn else { return }
        let outcome = downlink.markBridgeFallback()
        if case .fallback(let reason) = outcome {
            onEvent?(.playbackFallback(reason, handle))
        }
    }

    /// Downlink head-of-line gap timeout tick.
    func downlinkGapTimeout() {
        guard let handle = currentTurn else { return }
        let outcome = downlink.gapTimedOut()
        if case .fallback(let reason) = outcome {
            onEvent?(.playbackFallback(reason, handle))
        }
    }

    /// Finish the current turn. Idempotent: repeated calls are silent.
    func finishTurn(reason: FinishReason) {
        guard let handle = currentTurn else { return }
        if var stream = uplink {
            if !stream.didFallback, !stream.didCommit {
                _ = stream.markCancelled()
            }
            uplink = stream
        }
        _ = downlink.endSession()
        currentTurn = nil
        uplink = nil
        pcmScratch.removeAll(keepingCapacity: true)
        onEvent?(.turnFinished(handle, reason))
    }

    private func emit(outcome: RealtimeUplinkStream.Outcome, handle: TurnHandle) {
        switch outcome {
        case .emitted(let frames):
            for frame in frames {
                switch frame {
                case .streamStart(let start): onEvent?(.uplinkStart(start))
                case .audioAppend(let chunk): onEvent?(.uplinkAppend(chunk))
                case .audioCommit(let commit): onEvent?(.uplinkCommit(commit))
                }
            }
        case .fallback(let reason):
            onEvent?(.uplinkFallback(reason, handle))
        case .duplicate, .ignoredAfterCommit, .ignoredAfterFallback:
            break
        }
    }
}
