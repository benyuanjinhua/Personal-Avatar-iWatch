import AVFoundation
import Foundation

/// Turn-scoped guard that keeps audio-session activation idempotent while
/// leaving a failed activation retryable on the next playable chunk.
struct RealtimePlaybackAudioSessionGate {
    private(set) var isActivated = false

    mutating func activate(using operation: () throws -> Void) throws {
        guard !isActivated else { return }
        try operation()
        isActivated = true
    }

    mutating func reset() {
        isActivated = false
    }
}

/// ESS-321 real playback engine for streamed `audio.delta` chunks.
///
/// The bridge/agent delivers 24 kHz mono PCM16 chunks. Rather than wait for
/// the whole M4A the way ESS-58 did (full-file `SpeechPlayer.play(data:)`),
/// we schedule each PCM chunk on an `AVAudioPlayerNode` as soon as the
/// `RealtimeDownlinkPlayback` buffer releases it.
///
/// **ESS-335 (this file, second revision)**: playback receipts now derive
/// from **real** buffer render completions, not from "we queued the buffer".
///
///   * `.started(responseId)` fires when the first buffer for that response
///     finishes rendering (or `.dataConsumed`, whichever happens first).
///   * `.ended(responseId, bytesPlayed)` fires when **every** queued buffer
///     for that response has rendered, AND either `audio.done` has been
///     acknowledged for the response OR the response boundary has moved on.
///   * `bytes_played` counts only the bytes whose completion callback fired.
///     Bytes dropped by barge-in/stop are excluded, so the Bridge sees the
///     truth instead of a fabricated "success".
///   * `finish()` no longer stops or resets the player — it flags the current
///     response as "no more buffers coming"; the queued tail keeps rendering.
///
/// **ESS-330 v3**: each queued chunk carries its own `response_id`; the
/// engine keeps per-response counters so multi-response sessions route
/// receipts correctly across out-of-order releases.
///
/// Real-device acceptance (P95 latency, lock-screen resume, etc.) is scoped
/// to ESS-265. Here we deliver deterministic client code the coordinator can
/// exercise via the simulated closed loop and via WatchTests.
@MainActor
final class RealtimePlaybackEngine: WatchRealtimeMediaAdapter.Player {
    enum PlaybackEvent: Equatable {
        /// ESS-335: fires only after the first buffer for `responseId` has
        /// actually started rendering — receiving/queueing a delta does not
        /// count as playback success.
        case started(requestId: String, sessionId: String, responseId: String?)
        /// ESS-335: fires when the LAST queued buffer for `responseId` has
        /// rendered. `bytesPlayed` counts only the bytes whose completion
        /// callback fired; bytes discarded by barge-in / stop are excluded.
        case ended(requestId: String, sessionId: String, responseId: String?, bytesPlayed: Int)
        case bargedIn(requestId: String, sessionId: String, responseId: String?, bytesDropped: Int)
        case failed(requestId: String, sessionId: String, responseId: String?, code: String)
    }

    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let format: AVAudioFormat
    /// ESS-532: the recorder activates `.playAndRecord` during recording then
    /// deactivates it in `finish()`. If the engine was started under the
    /// recorder's session, it keeps running after deactivation but produces
    /// silence — every delta enqueued thereafter is silently lost.
    /// Activating `.playback` on the first buffer closes that gap.
    private var audioSessionGate = RealtimePlaybackAudioSessionGate()

    private(set) var currentTurn: RealtimeMediaSession.TurnHandle?
    private(set) var isRunning = false
    /// ESS-335 receipt state machine lives in Shared/ for unit testability
    /// without AVFoundation. Every real completion callback pokes it; the
    /// tracker's returned receipts become the `.started/.ended` events we
    /// forward through `onPlaybackEvent`.
    private var tracker = RealtimePlaybackReceiptTracker()

    /// Coordinator subscribes here so the session can turn playback receipts
    /// into `playback.started` / `playback.ended` on the wire.
    var onPlaybackEvent: ((PlaybackEvent) -> Void)?

    init(format: RealtimeMediaFormat = .downlinkPCM16, audioEngine: AVAudioEngine = AVAudioEngine()) {
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: true
        ) else {
            // Unreachable in production; the format constants live in
            // `RealtimeMediaFormat` and are validated by unit tests.
            fatalError("Invalid downlink format")
        }
        self.format = audioFormat
        self.audioEngine = audioEngine
        self.playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
    }

    func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {
        stop(barge: false)
        currentTurn = turn
        tracker.reset()
        if !isRunning {
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
        }
        playerNode.play()
    }

    func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
        guard let turn = currentTurn else { return }
        // ESS-532/ESS-535: the recorder deactivates the shared AVAudioSession
        // when recording ends. AVAudioEngine was started under .playAndRecord;
        // after the session transitions, the engine needs a clean restart.
        //
        // ESS-535 fix v2 (OSStatus !pri = 561017449): the recorder's async
        // deactivation races with our activation. On device, calling
        // setActive(true) immediately after the recorder's setActive(false)
        // fails with '!pri' (session still in use). Deactivate first with
        // .notifyOthersOnDeactivation to yield, then re-activate cleanly.
        do {
            try audioSessionGate.activate {
                let session = AVAudioSession.sharedInstance()
                // Yield the session in case the recorder's async deactivation
                // hasn't completed — this is a no-op if already inactive.
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                // Restart the engine under the new playback session.
                if isRunning {
                    playerNode.stop()
                    audioEngine.stop()
                    isRunning = false
                }
                audioEngine.prepare()
                try audioEngine.start()
                isRunning = true
                playerNode.play()
                WatchLog.info(
                    "realtime", "playback_engine_restarted",
                    requestId: turn.requestId,
                    detail: "session=.playback engine_running=\(audioEngine.isRunning) player_playing=\(playerNode.isPlaying)"
                )
            }
        } catch {
            WatchLog.error(
                "realtime", "playback_audio_session_failed",
                requestId: turn.requestId,
                detail: "category=playback active=true",
                code: "ERR_AUDIO_SESSION", error: error
            )
            onPlaybackEvent?(.failed(
                requestId: turn.requestId, sessionId: turn.sessionId,
                responseId: nil, code: "ERR_AUDIO_SESSION"
            ))
            return
        }
        for playable in playables where
            playable.chunk.requestId == turn.requestId &&
            playable.chunk.streamId == turn.sessionId {
            guard let pcmBuffer = buffer(for: playable.chunk.payload) else { continue }
            let payloadBytes = playable.chunk.payload.count
            let responseId = playable.responseId
            tracker.enqueue(responseId: responseId, bytes: payloadBytes)

            // `.dataPlayedBack` fires once the buffer has actually been played
            // through the output. This is the "real" completion Bixuan
            // required in ESS-335, not the "we queued it" pseudo-event.
            playerNode.scheduleBuffer(
                pcmBuffer, at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.didCompleteBuffer(responseId: responseId, bytes: payloadBytes)
                }
            }
        }
    }

    /// Called by the coordinator when the user talks over the response — dump
    /// every queued buffer and emit the barge-in receipt PER response with
    /// their real not-yet-played bytes so Bridge sees an honest number.
    func bargeIn(clearedBytes: Int) {
        guard let turn = currentTurn else { return }
        playerNode.stop()
        playerNode.reset()
        for receipt in tracker.bargeAll() {
            onPlaybackEvent?(.bargedIn(
                requestId: turn.requestId, sessionId: turn.sessionId,
                responseId: receipt.responseId, bytesDropped: receipt.bytesDropped
            ))
        }
        _ = clearedBytes // reorder-buffer clear count — informational only
    }

    /// ESS-335: `audio.done` from Bridge means "no more deltas coming for
    /// the current response". It does NOT mean "stop the player and drop
    /// queued buffers". We flag the current response as drain-requested;
    /// `.ended` fires from `bufferCompleted` when its queue empties.
    func finish(responseId: String?) {
        guard let turn = currentTurn else { return }
        if let ended = tracker.requestDrain(responseId: responseId) {
            onPlaybackEvent?(.ended(
                requestId: turn.requestId, sessionId: turn.sessionId,
                responseId: ended.responseId, bytesPlayed: ended.bytesPlayed
            ))
        }
    }

    func stop(barge: Bool) {
        guard currentTurn != nil else { return }
        if barge {
            bargeIn(clearedBytes: 0)
        } else {
            playerNode.stop()
            playerNode.reset()
        }
        currentTurn = nil
        tracker.reset()
        audioSessionGate.reset()
    }

    func shutdown() {
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        isRunning = false
    }

    private func didCompleteBuffer(responseId: String?, bytes: Int) {
        guard let turn = currentTurn else { return }
        let receipts = tracker.bufferCompleted(responseId: responseId, bytes: bytes)
        if let started = receipts.started {
            onPlaybackEvent?(.started(
                requestId: turn.requestId, sessionId: turn.sessionId,
                responseId: started.responseId
            ))
        }
        if let ended = receipts.ended {
            onPlaybackEvent?(.ended(
                requestId: turn.requestId, sessionId: turn.sessionId,
                responseId: ended.responseId, bytesPlayed: ended.bytesPlayed
            ))
        }
    }

    private func buffer(for payload: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = AVAudioFrameCount(payload.count / bytesPerFrame)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount
        guard let channel = pcmBuffer.int16ChannelData?.pointee else { return nil }
        payload.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Int16.self).baseAddress {
                channel.update(from: base, count: Int(frameCount))
            }
        }
        return pcmBuffer
    }
}
