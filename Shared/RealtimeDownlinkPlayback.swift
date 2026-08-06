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
/// **ESS-404 additions**:
///  * `activeGeneration` gates delta/done acceptance — stale generations
///    (`< active`) are dropped instead of closing the current session; a
///    barge-in transitions to `.pending` so nothing plays until iPhone
///    confirms the new generation via `openGeneration(_:)`.
///  * `markDone(finalSequence:)` implements the done barrier: `n ≥ 0`
///    releases only after seq 0…n are all emitted; `-1` is the explicit
///    zero-audio contract; `nil` degrades under `done_missing_final_sequence`.
///  * `endSession()` is now barrier-gated — before ESS-404 it flipped
///    `didSessionEnd` unconditionally, which is exactly the "close-on-done"
///    behaviour G2 flagged.
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

    /// ESS-404 §3.5: three-state generation gate. `.unset` is the initial /
    /// legacy path (chunks with no `generation` are admitted the old way);
    /// `.pending` is the post-barge-in window that drops everything until
    /// `openGeneration(_:)` fires; `.open(g)` accepts g and rejects
    /// stale/future values.
    enum GenerationState: Equatable, Sendable {
        case unset
        case pending
        case open(Int)
    }

    /// ESS-404 §3.3: barrier decision, computed each time a delta or done
    /// updates the buffer. `zeroAudio` is the explicit `-1` contract; the
    /// missing-list carries the seq numbers still owed under `waiting` and
    /// `missingFinalSequence` so `done_barrier_waiting` / degradation logs
    /// have actionable payloads.
    enum BarrierState: Equatable, Sendable {
        case notArmed
        case waiting(missing: [Int])
        case released(finalSequence: Int)
        case zeroAudio
        case missingFinalSequence(nextSeqSeen: Int)
    }

    enum DoneOutcome: Equatable, Sendable {
        case barrierReleased(finalSequence: Int, responseId: String?)
        case zeroAudio(responseId: String?)
        case waiting(missing: [Int], responseId: String?)
        case missingFinalSequence(nextSeqSeen: Int, responseId: String?)
        case droppedStaleGeneration(incoming: Int, active: Int)
        /// ESS-442 B3: `audio.done` carried a generation strictly greater
        /// than `activeGeneration`. Same posture as delta futures — Watch
        /// refuses to self-promote — but distinct from stale so log routing
        /// and diagnosis stay sharp.
        case droppedFutureGeneration(incoming: Int, active: Int)
        case droppedPendingGeneration(incoming: Int?)
    }

    enum DropReason: Equatable, Sendable {
        case staleSession(SessionKey)
        case bargedInBefore
        case sessionEnded
        case duplicate
        case validation(VoiceStreamValidationError)
        /// ESS-404: incoming generation is strictly less than `activeGeneration`.
        case staleGeneration(incoming: Int, active: Int)
        /// ESS-404: incoming generation is strictly greater than `activeGeneration` —
        /// Watch should have received `generation.open` first, so this is a
        /// contract violation and Watch refuses to self-promote.
        case futureGeneration(incoming: Int, active: Int)
        /// ESS-404: post-barge-in window; `activeGeneration == nil` and we
        /// drop everything until `openGeneration(_:)` fires.
        case pendingGeneration(incoming: Int?)
    }

    enum FallbackReason: Equatable, Sendable {
        case sequenceWindowExceeded
        case backpressure
        case gapTimedOut
        case bridgeReportedFallback
        case invalidChunk(VoiceStreamValidationError)
        /// ESS-404: 2.0 s done-barrier timeout (ESS-388 A3). Distinct from
        /// gapTimedOut so log routing / error surface stays sharp.
        case doneBarrierTimedOut(missing: [Int])
    }

    /// ESS-330 v3: a chunk released for playback is paired with the exact
    /// Bridge `response_id` it arrived with — not a global "most recent" id.
    /// Bixuan's counter-example proved the global version misroutes when
    /// frames arrive out of order (`resp-B/seq1` first, `resp-A/seq0` later).
    struct PlayableChunk: Equatable, Sendable {
        let chunk: VoiceStreamChunk
        let responseId: String?
    }

    enum Outcome: Equatable, Sendable {
        case buffered
        case ready([PlayableChunk])
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
    /// ESS-330 v3: response_id per pending chunk, drained in lock-step with
    /// `pending`. Absent when Bridge omits `response_id` on a delta.
    private var pendingResponseIds: [Int: String?] = [:]
    private(set) var emittedSequences: Set<Int> = []
    /// ESS-404: generation gate state; see `GenerationState`.
    private(set) var generationState: GenerationState = .unset
    /// ESS-404 §3.3: barrier tracking. `nil` when done has not arrived; set
    /// once by `markDone` and re-evaluated on subsequent ingests.
    private(set) var pendingFinalSequence: Int?
    /// The `response_id` supplied with `audio.done`, held so barrier release
    /// can hand it back to the caller for `player.finish(responseId:)`.
    private(set) var pendingDoneResponseId: String?
    /// Highest seq released so far, retained for the missing-final-sequence
    /// degradation path where Gateway omits the barrier value entirely.
    private var maxEmittedSequence: Int = -1

    var activeGeneration: Int? {
        if case .open(let g) = generationState { return g }
        return nil
    }

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
    /// and the sequence counter resets. Generation state is reset to
    /// `.unset` — the caller is responsible for `openGeneration(_:)` before
    /// any generation-bearing chunk arrives.
    @discardableResult
    mutating func attach(session: SessionKey) -> Outcome {
        let previousBytes = bufferedBytes
        resetBufferState()
        currentSession = session
        didFallback = false
        didSessionEnd = false
        generationState = .unset
        return .bargedIn(cleared: previousBytes)
    }

    /// User started a new turn / interrupted an in-flight response mid-play.
    /// Clears every buffered byte and reports how many bytes were dropped so
    /// the caller can log an evidence event.
    ///
    /// **ESS-404**: barge-in now transitions the generation gate to `.pending`.
    /// The current session is retained (so late frames from the OLD generation
    /// with the same requestId/sessionId are dropped as `.staleGeneration`
    /// rather than promoted through `nextSequence = 0`), but every incoming
    /// event is dropped until iPhone confirms the new generation via
    /// `openGeneration(_:)`. This closes G4 — before ESS-404 the old
    /// implementation zeroed `nextSequence` and re-admitted late frames.
    @discardableResult
    mutating func bargeIn() -> Outcome {
        let previousBytes = bufferedBytes
        resetBufferState()
        didSessionEnd = false
        generationState = .pending
        return .bargedIn(cleared: previousBytes)
    }

    /// End of a session (either `audio.done` after the barrier releases, or
    /// `response.interrupted`). Late frames after this are dropped as
    /// `.sessionEnded`.
    ///
    /// **ESS-404**: no longer called on raw `audio.done`; the coordinator
    /// invokes it only after `markDone` reports `.barrierReleased` /
    /// `.zeroAudio` or after a barrier timeout.
    @discardableResult
    mutating func endSession() -> Outcome {
        didSessionEnd = true
        return .buffered
    }

    /// ESS-404 §3.5: iPhone announced the new generation. Promotes the gate
    /// from `.pending` or `.unset` to `.open(generation)`. Also clears
    /// per-turn barrier state so a new response can start under this
    /// generation. Idempotent for the same generation.
    ///
    /// **ESS-442 B2**: transitioning from `.open(g)` directly to `.open(g+1)`
    /// must reset the sequence / emitted-set / buffer bookkeeping.
    /// Otherwise the new generation's `delta(0)` collides with
    /// `emittedSequences` from the previous generation and gets rejected
    /// as `.duplicate`, silently dropping the whole generation.
    /// `.pending → .open` already routes through `bargeIn()`, which reset
    /// the buffer state; the reset is only missing on `.open(g) → .open(g+1)`.
    ///
    /// **Reachability today (main, verified by Jackson Bai in ESS-442
    /// thread 6ab9c363)**: unreachable, but only because the SENDER of
    /// `generation.open` is not yet implemented. The receive-side is
    /// fully wired (`Shared/RealtimeMediaWireFormat.swift:210` enum,
    /// `Shared/RealtimeBridgeWireCodec.swift:252-254` decoder,
    /// `Watch/WatchSettingsStore.swift:340-343` unguarded route to
    /// `adapter.openGeneration(_)`), and NO iPhone-side sender wires it
    /// yet — `iOS/PhoneRealtimeSession.swift:87` notes ESS-402 is the
    /// ticket that will land it. So this reset is a proactively-planted
    /// guard, NOT a "contract forbids iPhone from self-advancing" —
    /// current status is defensive; auto-upgrades to P0 the moment ESS-402
    /// (or any other work) wires a `generation.open` sender.
    @discardableResult
    mutating func openGeneration(_ generation: Int) -> Outcome {
        if case .open(let existing) = generationState, existing == generation {
            return .buffered
        }
        if case .open = generationState {
            resetBufferState()
        }
        generationState = .open(generation)
        pendingFinalSequence = nil
        pendingDoneResponseId = nil
        didSessionEnd = false
        return .buffered
    }

    /// Feed the next `audio.delta` chunk into the buffer. `responseId` carries
    /// the Bridge `audio.delta.response_id` for THIS chunk — the reorder
    /// buffer keeps the pairing intact so a chunk that had to wait for a
    /// contiguous predecessor still emerges with its original response id.
    ///
    /// **ESS-404**: `generation`, when non-nil, is checked against the gate.
    /// A `nil` generation preserves the legacy path so pre-ESS-403 traffic
    /// still works during rollout.
    mutating func ingest(
        _ chunk: VoiceStreamChunk,
        responseId: String? = nil,
        generation: Int? = nil
    ) -> Outcome {
        guard let session = currentSession else {
            return .dropped(.staleSession(SessionKey(requestId: chunk.requestId, streamId: chunk.streamId)))
        }
        guard chunk.requestId == session.requestId, chunk.streamId == session.sessionId else {
            return .dropped(.staleSession(SessionKey(requestId: chunk.requestId, streamId: chunk.streamId)))
        }
        guard chunk.direction == .downlink else {
            return .dropped(.validation(.unsupportedCodec)) // reused error surface
        }
        if let drop = generationDropReason(incoming: generation) {
            return .dropped(drop)
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
        pendingResponseIds[chunk.sequence] = responseId
        bufferedBytes += chunk.payload.count

        var ready: [PlayableChunk] = []
        while let contiguous = pending.removeValue(forKey: nextSequence) {
            let releasedResponseId = pendingResponseIds.removeValue(forKey: nextSequence) ?? nil
            bufferedBytes -= contiguous.payload.count
            emittedSequences.insert(nextSequence)
            maxEmittedSequence = max(maxEmittedSequence, nextSequence)
            ready.append(PlayableChunk(chunk: contiguous, responseId: releasedResponseId))
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

    /// ESS-404 §3.4: 2.0 s done-barrier timeout. Only meaningful once
    /// `markDone` has armed the barrier (`pendingFinalSequence != nil`) and
    /// it has NOT already released. Distinct from the 1.5 s gap timeout —
    /// the caller is expected to cancel the other when one fires (spec
    /// §3.4 "先触发者负责单次回退").
    mutating func doneBarrierTimedOut() -> Outcome {
        guard !didFallback else { return .alreadyFellBack }
        guard let target = pendingFinalSequence, target >= 0 else { return .buffered }
        // Barrier already met — timeout is a no-op (release path takes over).
        if allEmittedThrough(target) { return .buffered }
        return trigger(fallback: .doneBarrierTimedOut(missing: missingSequences(upTo: target)))
    }

    /// Called when the bridge itself reports the fast channel died (e.g.
    /// upstream `stream.dropped` or WSS teardown). Absorbing: identical
    /// semantics to a local gap timeout so the caller only ever executes
    /// the full-file fallback once.
    mutating func markBridgeFallback() -> Outcome {
        trigger(fallback: .bridgeReportedFallback)
    }

    /// ESS-404 §3.3: `audio.done` arrived. Returns the barrier decision so
    /// the coordinator can either invoke `endSession` + `player.finish(...)`
    /// immediately, arm a 2.0 s timer, or degrade under
    /// `done_missing_final_sequence`.
    ///
    /// Called with `generation == nil` on legacy paths; the gate rejects
    /// mismatched generations here just like `ingest`, so a stale `audio.done`
    /// can no longer close the current-generation session (that is the G4
    /// core-regression U8 covers).
    mutating func markDone(
        finalSequence: Int?,
        responseId: String? = nil,
        generation: Int? = nil
    ) -> DoneOutcome {
        if let drop = generationDropReason(incoming: generation) {
            switch drop {
            case .staleGeneration(let incoming, let active):
                return .droppedStaleGeneration(incoming: incoming, active: active)
            case .pendingGeneration(let incoming):
                return .droppedPendingGeneration(incoming: incoming)
            case .futureGeneration(let incoming, let active):
                // ESS-442 B3: future generation on done — same posture as
                // delta (`.futureGeneration`) but on its own surface so the
                // adapter can log `future_generation_dropped kind=done`,
                // not `stale_generation_dropped`. Watch refuses to
                // self-promote either way; the current session stays open.
                return .droppedFutureGeneration(incoming: incoming, active: active)
            default:
                return .droppedPendingGeneration(incoming: generation)
            }
        }
        pendingDoneResponseId = responseId
        guard let target = finalSequence else {
            // Contract violation: Gateway omitted `final_sequence`. Degrade
            // to "n = max emitted seq" per §3.2 row 3 and let the caller
            // decide whether to release now or arm the barrier.
            let seen = maxEmittedSequence
            return .missingFinalSequence(nextSeqSeen: seen, responseId: responseId)
        }
        if target < 0 {
            // Explicit zero-audio contract. `-1` is the ONLY legit value for
            // "done without any delta"; this is exactly the G3 fix — the
            // caller no longer needs to guess from "we never saw a delta".
            pendingFinalSequence = -1
            return .zeroAudio(responseId: responseId)
        }
        pendingFinalSequence = target
        if allEmittedThrough(target) {
            // ESS-442 B1: mirror `checkBarrierRelease()`. Without this, a
            // late / duplicate downlink chunk arriving after the sync
            // release re-triggers `checkBarrierRelease()` in the
            // coordinator's `receiveDownlink` tail, producing a second
            // `.doneBarrierReleased` event, a second `player.finish()`,
            // and a second `done_barrier_released` log line under the
            // same response_id.
            pendingFinalSequence = nil
            return .barrierReleased(finalSequence: target, responseId: responseId)
        }
        return .waiting(missing: missingSequences(upTo: target), responseId: responseId)
    }

    /// Re-evaluate the barrier after new deltas landed. Returns `.released`
    /// exactly once — subsequent calls after release fold to `nil`. Used by
    /// the coordinator after each `ingest` while the barrier is armed.
    mutating func checkBarrierRelease() -> DoneOutcome? {
        guard let target = pendingFinalSequence, target >= 0 else { return nil }
        guard allEmittedThrough(target) else { return nil }
        let responseId = pendingDoneResponseId
        pendingFinalSequence = nil
        return .barrierReleased(finalSequence: target, responseId: responseId)
    }

    /// Snapshot of the current barrier state for observability / test asserts.
    var barrierState: BarrierState {
        guard let target = pendingFinalSequence else { return .notArmed }
        if target < 0 { return .zeroAudio }
        if allEmittedThrough(target) { return .released(finalSequence: target) }
        return .waiting(missing: missingSequences(upTo: target))
    }

    // MARK: - Internals

    private mutating func trigger(fallback reason: FallbackReason) -> Outcome {
        guard !didFallback else { return .alreadyFellBack }
        didFallback = true
        pending.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        return .fallback(reason)
    }

    private mutating func resetBufferState() {
        pending.removeAll(keepingCapacity: false)
        pendingResponseIds.removeAll(keepingCapacity: false)
        emittedSequences.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        nextSequence = 0
        maxEmittedSequence = -1
        pendingFinalSequence = nil
        pendingDoneResponseId = nil
    }

    private func generationDropReason(incoming: Int?) -> DropReason? {
        switch generationState {
        case .unset:
            // Legacy admit: no generation contract in force yet.
            return nil
        case .pending:
            return .pendingGeneration(incoming: incoming)
        case .open(let active):
            guard let incoming else { return nil } // legacy chunk under active gen
            if incoming < active {
                return .staleGeneration(incoming: incoming, active: active)
            }
            if incoming > active {
                return .futureGeneration(incoming: incoming, active: active)
            }
            return nil
        }
    }

    private func allEmittedThrough(_ target: Int) -> Bool {
        guard target >= 0 else { return true }
        for seq in 0...target where !emittedSequences.contains(seq) {
            return false
        }
        return true
    }

    private func missingSequences(upTo target: Int) -> [Int] {
        guard target >= 0 else { return [] }
        return (0...target).filter { !emittedSequences.contains($0) }
    }
}

private extension RealtimeDownlinkPlayback.SessionKey {
    init(requestId: String, streamId: String) {
        self.init(requestId: requestId, sessionId: streamId)
    }
}
