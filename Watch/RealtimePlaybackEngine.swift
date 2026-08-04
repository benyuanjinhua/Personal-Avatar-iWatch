import AVFoundation
import Foundation

/// ESS-321 real playback engine for streamed `audio.delta` chunks.
///
/// The bridge/agent delivers 24 kHz mono PCM16 chunks. Rather than wait for
/// the whole M4A the way ESS-58 did (full-file `SpeechPlayer.play(data:)`),
/// we schedule each PCM chunk on an `AVAudioPlayerNode` as soon as the
/// `RealtimeDownlinkPlayback` buffer releases it. `playback.started` fires
/// on the first scheduled buffer, `playback.ended` fires when the queue
/// drains and the coordinator confirms `audio.done`.
///
/// Real-device acceptance (P95 latency, lock-screen resume, etc.) is scoped
/// to ESS-265. Here we deliver deterministic client code the coordinator can
/// exercise via the simulated closed loop and via WatchTests.
@MainActor
final class RealtimePlaybackEngine: WatchRealtimeMediaAdapter.Player {
    /// ESS-330: every event carries `responseId` so upstream can attribute the
    /// receipt to the correct Agent response. A single session (turn) may span
    /// multiple responses when the user barges in mid-turn; the engine emits
    /// one `.started` + `.ended` pair per response, not per session.
    enum PlaybackEvent: Equatable {
        case started(requestId: String, sessionId: String, responseId: String)
        case ended(requestId: String, sessionId: String, responseId: String, bytesPlayed: Int)
        case bargedIn(requestId: String, sessionId: String, responseId: String, bytesDropped: Int)
        case failed(requestId: String, sessionId: String, responseId: String, code: String)
    }

    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let format: AVAudioFormat

    private(set) var currentTurn: RealtimeMediaSession.TurnHandle?
    private(set) var currentResponseId: String?
    private(set) var hasStartedPlayback = false
    private(set) var bytesQueued = 0
    private(set) var bytesQueuedForCurrentResponse = 0
    private(set) var isRunning = false

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
        currentResponseId = nil
        hasStartedPlayback = false
        bytesQueued = 0
        bytesQueuedForCurrentResponse = 0
        if !isRunning {
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
        }
        playerNode.play()
    }

    func enqueue(chunks: [VoiceStreamChunk]) {
        guard let turn = currentTurn else { return }
        for chunk in chunks where chunk.requestId == turn.requestId && chunk.streamId == turn.sessionId {
            guard let pcmBuffer = buffer(for: chunk.payload) else { continue }
            let payloadBytes = chunk.payload.count
            // ESS-330: a chunk without a response_id would let sessionId leak
            // back into the receipt. Fall back to sessionId here — but the
            // wire codec is expected to always populate it for Bridge
            // audio.delta traffic; treat a nil as an upstream contract bug
            // worth surfacing via the receipt string.
            let chunkResponseId = chunk.responseId ?? turn.sessionId
            // ESS-330: response boundary handling. When response_id flips
            // mid-session (barge-in produced a new Agent response on the same
            // session), close the prior response with `.ended` before opening
            // the new one with `.started`.
            if let prior = currentResponseId, prior != chunkResponseId {
                onPlaybackEvent?(.ended(
                    requestId: turn.requestId, sessionId: turn.sessionId,
                    responseId: prior, bytesPlayed: bytesQueuedForCurrentResponse
                ))
                bytesQueuedForCurrentResponse = 0
                hasStartedPlayback = false
            }
            playerNode.scheduleBuffer(pcmBuffer, at: nil, options: []) { [weak self] in
                Task { @MainActor in self?.didFinishBuffer(bytes: payloadBytes) }
            }
            bytesQueued += payloadBytes
            bytesQueuedForCurrentResponse += payloadBytes
            currentResponseId = chunkResponseId
            if !hasStartedPlayback {
                hasStartedPlayback = true
                onPlaybackEvent?(.started(
                    requestId: turn.requestId, sessionId: turn.sessionId,
                    responseId: chunkResponseId
                ))
            }
        }
    }

    /// Called by the coordinator when the user talks over the response — dump
    /// every queued buffer and emit the barge-in receipt.
    func bargeIn(clearedBytes: Int) {
        guard let turn = currentTurn else { return }
        playerNode.stop()
        playerNode.reset()
        hasStartedPlayback = false
        onPlaybackEvent?(.bargedIn(
            requestId: turn.requestId, sessionId: turn.sessionId,
            responseId: currentResponseId ?? turn.sessionId,
            bytesDropped: clearedBytes
        ))
        bytesQueuedForCurrentResponse = 0
    }

    /// Called by the coordinator when the bridge signalled `audio.done` and
    /// the buffer has drained. Emits `playback.ended`.
    func finish() {
        guard let turn = currentTurn else { return }
        playerNode.stop()
        playerNode.reset()
        onPlaybackEvent?(.ended(
            requestId: turn.requestId, sessionId: turn.sessionId,
            responseId: currentResponseId ?? turn.sessionId,
            bytesPlayed: bytesQueuedForCurrentResponse
        ))
        currentTurn = nil
        currentResponseId = nil
        hasStartedPlayback = false
        bytesQueued = 0
        bytesQueuedForCurrentResponse = 0
    }

    func stop(barge: Bool) {
        guard currentTurn != nil else { return }
        if barge {
            bargeIn(clearedBytes: bytesQueued)
        } else {
            playerNode.stop()
            playerNode.reset()
        }
        currentTurn = nil
        currentResponseId = nil
        hasStartedPlayback = false
        bytesQueued = 0
        bytesQueuedForCurrentResponse = 0
    }

    func shutdown() {
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        isRunning = false
    }

    private func didFinishBuffer(bytes: Int) {
        // Individual buffer callbacks are informational; `.ended` fires when
        // the coordinator calls `finish()`. We track completion by accounting.
        _ = bytes
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
