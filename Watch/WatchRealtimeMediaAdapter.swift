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
        func enqueue(chunks: [VoiceStreamChunk])
        func bargeIn(clearedBytes: Int)
        func finish()
        func stop(barge: Bool)
    }

    protocol Transport: AnyObject {
        func sendStreamStart(_ start: RealtimeStreamStart)
        func sendAudioAppend(_ chunk: VoiceStreamChunk)
        func sendAudioCommit(_ commit: RealtimeStreamCommit)
        func fallbackToCompleteFile(handle: RealtimeMediaSession.TurnHandle,
                                    reason: RealtimeUplinkStream.FallbackReason)
    }

    let session: RealtimeMediaSession
    private let recorder: Recorder
    private let player: Player
    private let transport: Transport
    private let logger: (String) -> Void
    private(set) var didTriggerCompleteFileFallback = false
    private(set) var currentTurn: RealtimeMediaSession.TurnHandle?

    init(
        session: RealtimeMediaSession = RealtimeMediaSession(),
        recorder: Recorder,
        player: Player,
        transport: Transport,
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.session = session
        self.recorder = recorder
        self.player = player
        self.transport = transport
        self.logger = logger
        wire()
    }

    private func wire() {
        recorder.onFrame = { [weak self] frame in self?.session.pushMicrophonePCM(frame) }
        recorder.onFailure = { [weak self] _ in self?.session.markUplinkTransportFailed() }
        player.onPlaybackEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .ended:
                self.session.markDownlinkFinished()
            case .bargedIn, .failed, .started:
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
    func ingestDownlink(_ chunk: VoiceStreamChunk) {
        session.receiveDownlink(chunk)
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
                transport.fallbackToCompleteFile(handle: handle, reason: reason)
                logger("uplink_fallback reason=\(reason) request=\(handle.requestId)")
            }
        case .playbackReady(let frames):
            player.enqueue(chunks: frames)
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
            }
            logger("turn_finished request=\(handle.requestId) reason=\(reason)")
        }
    }
}
