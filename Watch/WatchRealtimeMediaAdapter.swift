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

    let session: RealtimeMediaSession
    private let recorder: Recorder
    private let player: Player
    private let transport: Transport
    private let fullFileFallback: FullFileFallback
    private let logger: (String) -> Void
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
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.session = session
        self.recorder = recorder
        self.player = player
        self.transport = transport
        self.fullFileFallback = fullFileFallback
        self.logger = logger
        wire()
    }

    private func wire() {
        recorder.onFrame = { [weak self] frame in self?.session.pushMicrophonePCM(frame) }
        recorder.onFailure = { [weak self] _ in self?.session.markUplinkTransportFailed() }
        player.onPlaybackEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started(let requestId, let sessionId, let responseId):
                // ESS-330 v3: forward the response_id the player emitted
                // (which was preserved per chunk through the reorder buffer).
                // No session_id substitution — Bixuan's acceptance criteria
                // explicitly forbids that.
                guard let handle = self.currentTurn,
                      handle.requestId == requestId, handle.sessionId == sessionId,
                      let responseId else { break }
                self.transport.sendPlaybackStarted(handle: handle, responseId: responseId)
            case .ended(let requestId, let sessionId, let responseId, let bytesPlayed):
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

    /// ESS-404 §3.4: called by the outer timer service when the 2.0 s
    /// done-barrier expires without the barrier releasing. Delegated to
    /// the coordinator, which absorbs into a single fallback.
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
            player.stop(barge: false)
            logger("downlink_fallback reason=\(reason)")
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
                player.finish(responseId: responseId)
                WatchLog.info(
                    "realtime", "done_barrier_released",
                    requestId: currentTurn?.requestId,
                    detail: "response_id=\(responseId ?? "nil") final_seq=\(final) waited_ms=0"
                )
            case .zeroAudio(let responseId):
                // -1 zero-audio contract. No `.ended` is expected; no
                // `player.finish(...)` because there is nothing to drain.
                WatchLog.info(
                    "realtime", "done_zero_audio",
                    requestId: currentTurn?.requestId,
                    detail: "response_id=\(responseId ?? "nil") final_seq=-1"
                )
            case .waiting(let missing, let responseId):
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
                // ESS-442 B3: done for a strictly-future generation. Watch
                // never received `generation.open` for this one — surface as
                // a distinct log event so diagnosis routes to the missing
                // downlink `generation.open`, not to a stale-frame drop.
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
            player.finish(responseId: responseId)
            WatchLog.info(
                "realtime", "done_barrier_released",
                requestId: currentTurn?.requestId,
                detail: "response_id=\(responseId ?? "nil") final_seq=\(final)"
            )
        case .bargeInRequested(let handle, let fromGeneration):
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
            if handle == currentTurn {
                currentTurn = nil
                currentResponseId = nil
            }
            logger("turn_finished request=\(handle.requestId) reason=\(reason)")
        }
    }
}
