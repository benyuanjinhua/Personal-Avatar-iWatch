import Foundation

/// ESS-321 watch-side glue: owns the coordinator, wires the microphone tap,
/// the playback engine and the transport together.
///
/// The adapter is the single seam the rest of the watch app talks to. It
/// exists so:
///
///   * `PushToTalkController` can call `beginTurn` / `pushMicrophonePCM` /
///     `commitUplink` / `bargeIn` without knowing about the coordinator's
///     internal shape;
///   * `WatchVoiceTransport` gets a single callback for realtime chunks and
///     can keep its existing `sendMessageData` fast path;
///   * `PhoneConnectivity` (which owns the downlink) hands `audio.delta`
///     chunks to the adapter and the adapter feeds them into the coordinator;
///   * unit tests substitute the recorder / player with fakes and exercise
///     the whole loop deterministically.
///
/// The adapter does not touch AVAudioEngine or WCSession directly — the
/// injected `Recorder` / `Player` / `Transport` protocols draw the seam.
@MainActor
final class WatchRealtimeMediaAdapter {
    /// ESS-404 §3.4 / ESS-527: outer timer service that arms on
    /// `done_barrier_waiting` and calls `session.doneBarrierTimeout()` after
    /// `doneBarrierTimeoutSeconds`. Injected so tests can drive it
    /// deterministically; production uses the `Task.sleep`-backed default.
    protocol BarrierTimer: AnyObject {
        /// Arm (or re-arm) the timer. Cancels any prior pending fire.
        @MainActor func arm(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void)
        /// Cancel any pending fire. Idempotent.
        @MainActor func cancel()
    }

    /// ESS-404 §3.4: 2.0 s barrier budget. Matches the value the spec calls
    /// out and the buffer-level fallback reason (`.doneBarrierTimedOut`).
    static let doneBarrierTimeoutSeconds: TimeInterval = 2.0

    protocol Recorder: AnyObject {
        var onFrame: ((Data) -> Void)? { get set }
        var onFailure: ((Error) -> Void)? { get set }
        func start() throws
        func stop()
    }

    protocol Player: AnyObject {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)? { get set }
        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws
        /// ESS-330 v3: each playable carries its own response_id so per-response
        /// bookkeeping stays intact across out-of-order releases.
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk])
        func bargeIn(clearedBytes: Int)
        /// ESS-335: audio.done from Bridge no longer means "stop and drop
        /// queued buffers". `finish()` marks the response drain-requested;
        /// the player emits `.ended` only after the last queued buffer has
        /// actually rendered.
        func finish(responseId: String?)
        func stop(barge: Bool)
    }

    protocol Transport: AnyObject {
        func sendStreamStart(_ start: RealtimeStreamStart)
        func sendAudioAppend(_ chunk: VoiceStreamChunk)
        func sendAudioCommit(_ commit: RealtimeStreamCommit)
        /// Bridge PR #113 contract: real `playback.started/ended` receipts are
        /// forwarded up the WSS so the Bridge treats the Watch player as the
        /// authority — receiving `audio.delta` does not count.
        func sendPlaybackStarted(handle: RealtimeMediaSession.TurnHandle, responseId: String)
        func sendPlaybackEnded(handle: RealtimeMediaSession.TurnHandle, responseId: String, bytesPlayed: Int)
        /// Single-shot full-file fallback. The adapter GUARANTEES this is
        /// called at most once per turn; implementations must NOT trigger a
        /// double m4a upload themselves.
        func fallbackToCompleteFile(handle: RealtimeMediaSession.TurnHandle,
                                    reason: RealtimeUplinkStream.FallbackReason)
        /// ESS-404 §5: forward a `bargein.request` up to iPhone. iPhone
        /// owns the generation counter and is responsible for issuing
        /// `cancel(generation)` on the WSS.
        func sendBargeInRequest(_ request: RealtimeBargeInRequest)
    }

    /// Real single-shot full-file fallback executor. When the fast channel
    /// dies the coordinator triggers `.uplinkFallback`; the adapter routes
    /// that through this closure so the concrete Watch wiring (which knows
    /// how to grab the m4a from the parallel AudioRecorder and call
    /// `WatchVoiceTransport.send(envelope:recording:)`) can actually upload
    /// the recording exactly once. The adapter guarantees single execution
    /// via its own flag.
    typealias FullFileFallback = @MainActor (RealtimeMediaSession.TurnHandle,
                                             RealtimeUplinkStream.FallbackReason) -> Void

    /// ESS-532: called when the realtime playback pending state is resolved —
    /// either the first frame has started rendering, the turn fell back to
    /// complete-file, or the turn finished entirely. The PushToTalkController
    /// wires this to clear `realtimePlaybackPending` so the VoiceSessionKeeper
    /// can release the ExtendedRuntimeSession.
    var onRealtimePendingResolved: (@MainActor () -> Void)?
    var onVADEvent: (@MainActor (LocalVADEvent) -> Void)?

    let session: RealtimeMediaSession
    private let recorder: Recorder
    private let player: Player
    private let transport: Transport
    private let fullFileFallback: FullFileFallback
    private let logger: (String) -> Void
    private let barrierTimer: BarrierTimer
    private var vadEndpointer: LocalVADEndpointer?
    private let vadSampleRate: Int
    private let automaticallyCommitOnSpeechFinal: Bool
    private var vadFrameStartedAtMs: Int64 = 0
    private(set) var didTriggerCompleteFileFallback = false
    private(set) var currentTurn: RealtimeMediaSession.TurnHandle?
    /// ESS-330: latest `response_id` observed on `audio.delta` for the current
    /// turn. Bridge PR #113 (`realtime-media-session.mjs:67-70`) tags every
    /// delta with the real Agent response_id and expects playback receipts
    /// (`playback.started/ended`) to echo the same value so multi-response
    /// sessions stay disambiguated. Cleared when the turn ends.
    private(set) var currentResponseId: String?

    init(
        session: RealtimeMediaSession = RealtimeMediaSession(),
        recorder: Recorder,
        player: Player,
        transport: Transport,
        fullFileFallback: @escaping FullFileFallback = { _, _ in },
        logger: @escaping (String) -> Void = { _ in },
        barrierTimer: BarrierTimer = TaskBasedBarrierTimer(),
        vadConfiguration: LocalVADConfiguration? = nil,
        automaticallyCommitOnSpeechFinal: Bool = false
    ) {
        self.session = session
        self.recorder = recorder
        self.player = player
        self.transport = transport
        self.fullFileFallback = fullFileFallback
        self.logger = logger
        self.barrierTimer = barrierTimer
        self.vadEndpointer = vadConfiguration.map(LocalVADEndpointer.init(configuration:))
        self.vadSampleRate = vadConfiguration?.sampleRate ?? RealtimeMediaFormat.uplinkPCM16.sampleRate
        self.automaticallyCommitOnSpeechFinal = automaticallyCommitOnSpeechFinal
        wire()
    }

    private func wire() {
        recorder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.session.pushMicrophonePCM(frame)
            self.consumeVAD(frame)
        }
        recorder.onFailure = { [weak self] _ in self?.session.markUplinkTransportFailed() }
        player.onPlaybackEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started(let requestId, let sessionId, let responseId):
                // ESS-532: first frame rendered — playback is live now, the
                // ExtendedRuntimeSession can be released.
                self.onRealtimePendingResolved?()
                // ESS-330 v3: forward the response_id the player emitted
                // (which was preserved per chunk through the reorder buffer).
                // No session_id substitution — Bixuan's acceptance criteria
                // explicitly forbids that.
                guard let handle = self.currentTurn,
                      handle.requestId == requestId, handle.sessionId == sessionId,
                      let responseId else { break }
                self.transport.sendPlaybackStarted(handle: handle, responseId: responseId)
            case .ended(let requestId, let sessionId, let responseId, let bytesPlayed):
                self.playbackEndedForVADGuard()
                if let handle = self.currentTurn,
                   handle.requestId == requestId, handle.sessionId == sessionId,
                   let responseId {
                    self.transport.sendPlaybackEnded(
                        handle: handle,
                        responseId: responseId,
                        bytesPlayed: bytesPlayed
                    )
                }
                // A playback `.ended` event closes only this response. One
                // realtime session may carry multiple responses, so ending
                // the downlink here would reject the next response's chunks
                // as `.sessionEnded`. Explicit cancel, interruption, or the
                // next turn remains responsible for closing/replacing it.
            case .bargedIn, .failed:
                if case .failed(let rid, _, _, let code) = event {
                    WatchLog.error(
                        "realtime", "playback_engine_failed",
                        requestId: rid,
                        detail: "playback_event=failed",
                        code: code
                    )
                }
                break
            }
            self.logger("playback_event=\(event)")
        }
        session.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Called by the push-to-talk controller on trigger down. Opens a new
    /// coordinator turn (barging in on any prior one) and starts the mic tap.
    /// Falls back to the caller's existing full-file pipeline if the mic tap
    /// cannot start.
    func beginTurn(requestId: String) -> RealtimeMediaSession.TurnHandle {
        didTriggerCompleteFileFallback = false
        currentResponseId = nil
        vadFrameStartedAtMs = Self.uptimeMs()
        vadEndpointer?.reset(atMs: vadFrameStartedAtMs)
        // `session.beginTurn(...)` fires a `.turnFinished(...)` for any
        // existing turn which already cancels; the explicit cancel here is a
        // defence for the first-ever call (no prior turn to fire finished).
        barrierTimer.cancel()
        let handle = session.beginTurn(requestId: requestId)
        currentTurn = handle
        do {
            try recorder.start()
            try player.prepare(for: handle)
        } catch {
            logger("realtime_start_failed error=\(error)")
            session.markUplinkTransportFailed()
        }
        return handle
    }

    /// Called by the push-to-talk controller on trigger up. Stops the mic
    /// tap (flushing any tail bytes) then commits the uplink.
    func commit() {
        recorder.stop()
        session.commitUplink()
    }

    func playbackEndedForVADGuard(atMs: Int64? = nil) {
        let effectiveAtMs = atMs ?? Self.uptimeMs()
        vadEndpointer?.playbackEnded(atMs: effectiveAtMs)
        vadFrameStartedAtMs = effectiveAtMs
    }

    private func consumeVAD(_ frame: Data) {
        guard var endpointer = vadEndpointer else { return }
        let events = endpointer.processPCM16(frame, frameStartedAtMs: vadFrameStartedAtMs)
        vadFrameStartedAtMs += Int64(
            frame.count / MemoryLayout<Int16>.size * 1_000 / vadSampleRate
        )
        vadEndpointer = endpointer
        for event in events {
            switch event {
            case .speechStarted(let atMs):
                WatchLog.info("vad", "speech_started", detail: "at_ms=\(atMs)")
            case .speechFinal(let atMs, let reason):
                WatchLog.info("vad", "speech_final", detail: "at_ms=\(atMs) reason=\(reason.rawValue)")
                if automaticallyCommitOnSpeechFinal {
                    recorder.stop()
                    session.commitUplink()
                }
            }
            onVADEvent?(event)
        }
    }

    private static func uptimeMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }

    func receiveUplinkAck(_ ack: RealtimeUplinkAck) {
        guard session.acknowledgeUplink(ack) else { return }
        WatchLog.info(
            "realtime", "uplink_ack_received", requestId: ack.requestId,
            detail: "sequence=\(ack.sequence) bytes=\(ack.byteCount)"
        )
    }

    /// Called when the user starts speaking again mid-response.
    func bargeIn() {
        session.bargeInDownlink()
    }

    /// Cancel the current turn (user cancel, watch app deactivated, etc.).
    func cancel(reason: RealtimeMediaSession.FinishReason = .cancelled) {
        recorder.stop()
        session.cancelUplink()
        session.finishTurn(reason: reason)
        player.stop(barge: reason == .interrupted)
    }

    /// Feed a downlink chunk received from the iPhone. Called by
    /// `PhoneConnectivity` after WSS parses the `audio.delta` off the wire.
    ///
    /// `responseId` (ESS-330 v3) is the real Bridge `response_id` for THIS
    /// chunk. The reorder buffer keeps the pairing intact per-chunk, so
    /// out-of-order releases still route to the correct response. The player
    /// then emits started/ended per response_id.
    ///
    /// `generation` (ESS-404) is the turn generation; `nil` traces the
    /// legacy admit path so pre-ESS-403 traffic still works during rollout.
    ///
    /// The adapter no longer clears the buffer on response boundaries — the
    /// per-chunk association survives release, so mixing responses in the
    /// buffer is safe. Barge-in remains an explicit user action, not an
    /// implicit response-id switch.
    func ingestDownlink(
        _ chunk: VoiceStreamChunk,
        responseId: String? = nil,
        generation: Int? = nil
    ) {
        if let newResponseId = responseId { currentResponseId = newResponseId }
        session.receiveDownlink(chunk, responseId: responseId, generation: generation)
    }

    /// Bridge told the watch (via iPhone) that the downlink fast channel is
    /// dead. Absorbs to the one-shot fallback.
    func markDownlinkBridgeFallback() {
        session.markDownlinkBridgeFallback()
    }

    /// Bridge signalled `audio.done` for the current turn.
    ///
    /// **ESS-404 G3 fix**: `audio.done` no longer directly calls
    /// `player.finish(...)`. It flows through the coordinator's barrier
    /// logic — the player is only drained when the barrier releases (either
    /// synchronously in `receiveDone` if seq 0…final_seq are all there, or
    /// asynchronously via `checkBarrierRelease` after the missing deltas
    /// arrive). This is what closes G2 — a done before the last delta no
    /// longer prematurely closes the session.
    func markDownlinkComplete(
        responseId: String? = nil,
        generation: Int? = nil,
        finalSequence: Int? = nil
    ) {
        session.receiveDone(
            finalSequence: finalSequence,
            responseId: responseId,
            generation: generation
        )
    }

    /// ESS-404 §3.5: iPhone confirmed the new generation after Watch's
    /// `bargein.request`. Adapter forwards to the coordinator so the
    /// downlink gate exits `.pending` and deltas resume.
    func openGeneration(_ generation: Int) {
        session.openGeneration(generation)
    }

    /// ESS-404 §3.4 / ESS-527: called by the internal barrier timer (or
    /// manually from tests) when the 2.0 s done-barrier expires without the
    /// barrier releasing. Delegated to the coordinator, which absorbs into a
    /// single fallback. Prior to ESS-527 this was dead code — no caller ever
    /// scheduled the timer, so a `done_barrier_waiting` state persisted
    /// indefinitely and no fallback was surfaced. See `BarrierTimer` and the
    /// `.doneArrived(.waiting)` branch in `handle(_:)` for the wiring.
    func doneBarrierTimeout() {
        session.doneBarrierTimeout()
    }

    /// ESS-404 §5 exception branch: iPhone reported it could NOT send
    /// `cancel` on the WSS. Watch must collapse the pending window to a
    /// single fallback and surface the structured error to the user.
    func markBargeInFailed(reason: String) {
        WatchLog.error(
            "realtime", "bargein_cancel_failed",
            requestId: currentTurn?.requestId,
            detail: "reason=\(reason)",
            code: "ERR_BARGEIN_CANCEL_FAILED"
        )
        session.markDownlinkBridgeFallback()
    }

    private func handle(_ event: RealtimeMediaSession.Event) {
        switch event {
        case .uplinkStart(let start):
            transport.sendStreamStart(start)
        case .uplinkAppend(let chunk):
            transport.sendAudioAppend(chunk)
        case .uplinkCommit(let commit):
            transport.sendAudioCommit(commit)
        case .uplinkFallback(let reason, let handle):
            recorder.stop()
            player.stop(barge: false)
            if !didTriggerCompleteFileFallback {
                didTriggerCompleteFileFallback = true
                // Signal the peer (Bridge) that the fast channel is dead so
                // it releases the WSS resources — the message is a close, not
                // a new business event (`RealtimeBridgeWireCodec` translates
                // `.fallback` → `close`).
                transport.fallbackToCompleteFile(handle: handle, reason: reason)
                // Actually execute the full-file upload through the existing
                // reliable path. Called exactly once per turn thanks to the
                // flag above.
                fullFileFallback(handle, reason)
                logger("uplink_fallback reason=\(reason) request=\(handle.requestId)")
            }
            // ESS-532: uplink fallback resolves the pending state so the
            // VoiceSessionKeeper can release.
            onRealtimePendingResolved?()
        case .playbackReady(let playables):
            player.enqueue(playables: playables)
        case .playbackCleared(let bytesDropped):
            player.bargeIn(clearedBytes: bytesDropped)
            WatchLog.info(
                "realtime", "bargein_playback_stopped",
                requestId: currentTurn?.requestId,
                detail: "bytes_dropped=\(bytesDropped)"
            )
        case .playbackFallback(let reason, _):
            // Any playback fallback ends the barrier's relevance for this
            // turn. Cancel the timer so a late fire does not stack a second
            // fallback on top (the buffer would absorb it, but the log noise
            // is R-02 evidence pollution).
            barrierTimer.cancel()
            player.stop(barge: false)
            logger("downlink_fallback reason=\(reason)")
            // ESS-532: downlink fallback resolves pending so the keeper releases.
            onRealtimePendingResolved?()
            if case .doneBarrierTimedOut(let missing) = reason {
                WatchLog.error(
                    "realtime", "done_barrier_timeout",
                    requestId: currentTurn?.requestId,
                    detail: "missing_seq=\(missing)",
                    code: "ERR_DONE_BARRIER_TIMEOUT"
                )
            }
        case .downlinkDropped(let reason):
            logger("downlink_drop reason=\(reason)")
            switch reason {
            case .staleGeneration(let incoming, let active):
                WatchLog.info(
                    "realtime", "stale_generation_dropped",
                    requestId: currentTurn?.requestId,
                    detail: "incoming_gen=\(incoming) active_gen=\(active) kind=delta"
                )
            case .futureGeneration(let incoming, let active):
                WatchLog.info(
                    "realtime", "future_generation_dropped",
                    requestId: currentTurn?.requestId,
                    detail: "incoming_gen=\(incoming) active_gen=\(active)"
                )
            case .pendingGeneration(let incoming):
                WatchLog.info(
                    "realtime", "generation_pending_dropped",
                    requestId: currentTurn?.requestId,
                    detail: "incoming_gen=\(incoming.map(String.init) ?? "nil")"
                )
            default:
                break
            }
        case .doneArrived(_, let outcome):
            switch outcome {
            case .barrierReleased(let final, let responseId):
                // Synchronous release: seq 0…final already there when done
                // arrived. Drain the player now (this is the previous
                // `player.finish(...)` call, but gated by the barrier).
                barrierTimer.cancel()
                player.finish(responseId: responseId)
                WatchLog.info(
                    "realtime", "done_barrier_released",
                    requestId: currentTurn?.requestId,
                    detail: "response_id=\(responseId ?? "nil") final_seq=\(final) waited_ms=0"
                )
            case .zeroAudio(let responseId):
                // -1 zero-audio contract. No `.ended` is expected; no
                // `player.finish(...)` because there is nothing to drain.
                barrierTimer.cancel()
                WatchLog.info(
                    "realtime", "done_zero_audio",
                    requestId: currentTurn?.requestId,
                    detail: "response_id=\(responseId ?? "nil") final_seq=-1"
                )
            case .waiting(let missing, let responseId):
                // ESS-527: arm the outer timer so a barrier that never
                // fills is bounded. `checkBarrierRelease` on the coordinator
                // side re-enters this branch as `.doneBarrierReleased` (async)
                // as soon as the missing seqs land, at which point we cancel.
                barrierTimer.arm(
                    after: Self.doneBarrierTimeoutSeconds
                ) { [weak self] in self?.session.doneBarrierTimeout() }
                WatchLog.info(
                    "realtime", "done_barrier_waiting",
                    requestId: currentTurn?.requestId,
                    detail: "response_id=\(responseId ?? "nil") missing_seq=\(missing)"
                )
            case .missingFinalSequence(let seen, let responseId):
                // Legacy path (Gateway pre-ESS-403 doesn't send
                // `final_sequence`): degrade to `n = max emitted seq` and
                // still drain the player so the tail renders. The
                // structured error is what surfaces the contract violation.
                barrierTimer.cancel()
                WatchLog.error(
                    "realtime", "done_missing_final_sequence",
                    requestId: currentTurn?.requestId,
                    detail: "response_id=\(responseId ?? "nil") next_seq_seen=\(seen)",
                    code: "ERR_DONE_MISSING_FINAL_SEQUENCE"
                )
                player.finish(responseId: responseId)
            case .droppedStaleGeneration(let incoming, let active):
                WatchLog.info(
                    "realtime", "stale_generation_dropped",
                    requestId: currentTurn?.requestId,
                    detail: "incoming_gen=\(incoming) active_gen=\(active) kind=done"
                )
            case .droppedFutureGeneration(let incoming, let active):
                // ESS-442 B3: mirror the delta-side `future_generation_dropped`
                // log surface so a done carrying a generation the Watch has
                // not yet been promoted to no longer masquerades as `stale`.
                WatchLog.info(
                    "realtime", "future_generation_dropped",
                    requestId: currentTurn?.requestId,
                    detail: "incoming_gen=\(incoming) active_gen=\(active) kind=done"
                )
            case .droppedPendingGeneration(let incoming):
                WatchLog.info(
                    "realtime", "generation_pending_dropped",
                    requestId: currentTurn?.requestId,
                    detail: "incoming_gen=\(incoming.map(String.init) ?? "nil") kind=done"
                )
            }
        case .doneBarrierReleased(_, let final, let responseId):
            // Async release: late deltas filled the missing set. Cancel the
            // pending 2 s timer so it does not stack a redundant fallback on
            // an already-drained response.
            barrierTimer.cancel()
            player.finish(responseId: responseId)
            WatchLog.info(
                "realtime", "done_barrier_released",
                requestId: currentTurn?.requestId,
                detail: "response_id=\(responseId ?? "nil") final_seq=\(final)"
            )
        case .bargeInRequested(let handle, let fromGeneration):
            // Barge-in dumps every buffered downlink byte and moves the gate
            // into `.pending`; whatever the barrier was waiting on is now
            // moot. Cancel so the pending window does not inherit an armed
            // fallback from the prior generation.
            barrierTimer.cancel()
            WatchLog.info(
                "realtime", "bargein_requested",
                requestId: handle.requestId,
                detail: "from_gen=\(fromGeneration)"
            )
            transport.sendBargeInRequest(RealtimeBargeInRequest(
                requestId: handle.requestId,
                sessionId: handle.sessionId,
                fromGeneration: fromGeneration
            ))
        case .generationOpened(let handle, let from, let to):
            WatchLog.info(
                "realtime", "bargein_generation_opened",
                requestId: handle.requestId,
                detail: "from_gen=\(from.map(String.init) ?? "nil") to_gen=\(to)"
            )
        case .turnFinished(let handle, let reason):
            // Turn is over; any armed barrier belongs to a session that no
            // longer exists. Cancel so a subsequent turn does not inherit a
            // stray fire from the previous one.
            barrierTimer.cancel()
            if handle == currentTurn {
                currentTurn = nil
                currentResponseId = nil
            }
            // ESS-532: turn finished (audio.done + playback complete, or
            // cancel/interrupt) clears the pending hold so the
            // ExtendedRuntimeSession can be released.
            onRealtimePendingResolved?()
            logger("turn_finished request=\(handle.requestId) reason=\(reason)")
        }
    }
}

/// ESS-527 default `BarrierTimer` implementation. Mirrors the
/// `WatchStreamReceiver.scheduleGapTimer` pattern (`Task { Task.sleep }`)
/// so the barrier timer plays nicely with the same runtime and lifecycle
/// as the existing gap timer. `arm(...)` cancels any prior scheduling so
/// re-arming while waiting is safe.
@MainActor
final class TaskBasedBarrierTimer: WatchRealtimeMediaAdapter.BarrierTimer {
    private var task: Task<Void, Never>?

    /// Non-isolated init so the adapter's `barrierTimer:` default value can
    /// construct one from a nonisolated context. The stored `task` is only
    /// touched from `arm` / `cancel`, both of which are `@MainActor`.
    nonisolated init() {}

    func arm(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
