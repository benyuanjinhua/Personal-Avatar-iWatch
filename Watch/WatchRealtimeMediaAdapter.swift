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
        func finish()
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
                self.session.markDownlinkFinished()
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
    /// The adapter no longer clears the buffer on response boundaries — the
    /// per-chunk association survives release, so mixing responses in the
    /// buffer is safe. Barge-in remains an explicit user action, not an
    /// implicit response-id switch.
    func ingestDownlink(_ chunk: VoiceStreamChunk, responseId: String? = nil) {
        if let newResponseId = responseId { currentResponseId = newResponseId }
        session.receiveDownlink(chunk, responseId: responseId)
    }

    /// Bridge told the watch (via iPhone) that the downlink fast channel is
    /// dead. Absorbs to the one-shot fallback.
    func markDownlinkBridgeFallback() {
        session.markDownlinkBridgeFallback()
    }

    /// Bridge signalled `audio.done` for the current turn.
    func markDownlinkComplete() {
        player.finish()
        session.finishTurn(reason: .audioDone)
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
        case .playbackFallback(let reason, _):
            player.stop(barge: false)
            logger("downlink_fallback reason=\(reason)")
        case .downlinkDropped(let reason):
            logger("downlink_drop reason=\(reason)")
        case .turnFinished(let handle, let reason):
            if handle == currentTurn {
                currentTurn = nil
                currentResponseId = nil
            }
            logger("turn_finished request=\(handle.requestId) reason=\(reason)")
        }
    }
}
