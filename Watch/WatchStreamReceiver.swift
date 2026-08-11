import AVFoundation
import Foundation
import os

/// ESS-324 B4：Watch 端流式下行 chunk 接收器。
///
/// 职责：
/// - 接收 iPhone 转发来的 `voice.stream.chunk`（`VoiceStreamChunk`，`direction == .downlink`）
/// - 经 `VoiceStreamReorderBuffer` 重排/校验后，用 `StreamingAudioPlayer` 逐片 PCM 首包即播
/// - 以 `WatchDebugSettings.isStreamingActive` 为总门禁
/// - 降级：buffer 超时/越窗/背压时走 `voice.stream.fallback` 回退整段 m4a
///
/// 线程：全部 `@MainActor`；`didReceiveMessageData` 通过 `Task { @MainActor in }` 进入。
@MainActor
final class WatchStreamReceiver: ObservableObject {
    private static let logger = Logger(
        subsystem: "beer.workspace.wristagent", category: "StreamReceiver"
    )

    /// 单 stream 状态：每个 request_id 最多一个活跃下行流。
    private struct StreamState {
        var buffer: VoiceStreamReorderBuffer
        let requestId: String
        let streamId: String
        let startedAt: Date
        let streamingGeneration: Int
        var player: StreamingAudioPlaying?
        var gapTimer: Task<Void, Never>?
        var playedSequence: Int = 0
        var didFallback: Bool = false
    }

    // MARK: - Dependencies (injected for testability)

    private let debugSettings: WatchDebugSettings
    let fallbackHandler: (String, VoiceStreamFallbackReason) -> Void
    /// ESS-748 seam: tests inject a fake so the start-failure path can be
    /// exercised without audio hardware (hosted CI has none — see
    /// `HostedCITestGate`). Production uses the real `StreamingAudioPlayer`.
    private let makePlayer: @MainActor (String) -> StreamingAudioPlaying

    // MARK: - State

    private var activeStream: StreamState?
    private var disableObserverToken: UUID?
    /// ESS-509: WCSession health monitor, started when streaming begins.
    private let keepAlive = RealtimeSessionKeepAlive()

    /// 门禁：编译期 OFF + debug 开关。
    var gateOpen: Bool { debugSettings.isStreamingActive }

    /// Snapshot for tests (ESS-748): sequence actually handed to the player for
    /// the active stream, or nil when there is none. Production paths do not
    /// read this. Asserting it stays at 0 is how "a dead player must not
    /// advance the stream" is proven.
    var activePlayedSequence: Int? { activeStream?.playedSequence }

    // MARK: - Init

    init(
        debugSettings: WatchDebugSettings,
        makePlayer: @escaping @MainActor (String) -> StreamingAudioPlaying = { context in
            StreamingAudioPlayer(sampleRate: 24_000, context: context)
        },
        fallbackHandler: @escaping (String, VoiceStreamFallbackReason) -> Void
    ) {
        self.debugSettings = debugSettings
        self.makePlayer = makePlayer
        self.fallbackHandler = fallbackHandler
        disableObserverToken = debugSettings.onStreamingDisabled { [weak self] in
            Task { @MainActor in self?.cancelAll(reason: "streaming_disabled") }
        }
    }

    deinit {
        if let token = disableObserverToken {
            Task { @MainActor [weak debugSettings, token] in
                debugSettings?.removeDisableHandler(token)
            }
        }
    }

    // MARK: - Entry

    /// 接收来自 WCSession `didReceiveMessageData` 的 downlink chunk。
    func receive(chunk: VoiceStreamChunk) {
        guard chunk.direction == .downlink else {
            Self.logger.warning("receive_non_downlink_chunk seq=\(chunk.sequence)")
            return
        }
        guard gateOpen else {
            Self.logger.info("chunk_rejected_gate_closed request_id=\(chunk.requestId) seq=\(chunk.sequence)")
            return
        }
        let currentGen = debugSettings.streamingGeneration
        if let active = activeStream, active.streamingGeneration != currentGen {
            cancelAll(reason: "generation_mismatch")
            return
        }

        // 新 stream 或同一 stream 的后续 chunk
        if let active = activeStream, active.requestId == chunk.requestId {
            // 同一 stream：追加 chunk
        } else {
            // 新 stream：终止旧流
            if activeStream != nil {
                cancelAll(reason: "new_stream_supersedes")
            }
            activeStream = StreamState(
                buffer: VoiceStreamReorderBuffer(),
                requestId: chunk.requestId,
                streamId: chunk.streamId,
                startedAt: Date(),
                streamingGeneration: currentGen
            )
            // ESS-509: start WCSession keep-alive when streaming begins
            keepAlive.start()
            WatchLog.info(
                "stream", "stream_started",
                requestId: chunk.requestId,
                detail: "stream_id=\(chunk.streamId) gen=\(currentGen)"
            )
        }

        guard var stream = activeStream, !stream.didFallback else { return }
        let result = stream.buffer.append(chunk)
        apply(result: result, stream: &stream)
        activeStream = stream
    }

    // MARK: - Buffer result handling

    private func apply(result: VoiceStreamBufferResult, stream: inout StreamState) {
        switch result {
        case .accepted:
            scheduleGapTimer(stream: &stream)

        case .duplicate:
            break

        case .ready(let chunks):
            // ESS-748: the player must be proven live before the sequence
            // advances. A failed start / failed enqueue means nothing was ever
            // scheduled — degrade the whole turn instead of dropping audio.
            guard let player = ensurePlayer(stream: &stream) else { return }
            let pcmData = assemblePCM(from: chunks)
            do {
                try player.append(pcmData: pcmData)
            } catch {
                playerFailed(error, stage: "append", stream: &stream)
                return
            }
            stream.playedSequence = stream.buffer.nextSequence

            let endOfStream = chunks.contains(where: \.endOfStream)
            if endOfStream {
                stream.player?.markEndOfStream()
            } else {
                scheduleGapTimer(stream: &stream)
            }

        case .fallback(let reason):
            triggerFallback(requestId: stream.requestId, reason: reason, stream: &stream)

        case .alreadyFellBack:
            break
        }
    }

    // MARK: - Gap timer

    private func scheduleGapTimer(stream: inout StreamState) {
        stream.gapTimer?.cancel()
        let capturedRequestId = stream.requestId
        stream.gapTimer = Task { [weak self] in
            let timeout = VoiceStreamConstants.gapTimeoutSeconds
            let nanos = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, var active = self.activeStream,
                      active.requestId == capturedRequestId, !active.didFallback else { return }
                let result = active.buffer.gapTimedOut()
                self.apply(result: result, stream: &active)
                self.activeStream = active
            }
        }
    }

    // MARK: - Player

    /// Returns a started player, or `nil` after having triggered exactly one
    /// fallback for this stream (ESS-748).
    private func ensurePlayer(stream: inout StreamState) -> StreamingAudioPlaying? {
        if let existing = stream.player { return existing }
        let player = makePlayer(stream.requestId)
        do {
            try player.start()
        } catch {
            playerFailed(error, stage: "start", stream: &stream)
            return nil
        }
        stream.player = player
        return player
    }

    /// Single funnel for "the PCM path is dead": log the runtime evidence, then
    /// degrade the turn to the complete-file channel. `triggerFallback` is
    /// absorbing, so at most one fallback fires per stream.
    private func playerFailed(_ error: Error, stage: String, stream: inout StreamState) {
        WatchLog.error(
            "stream", "player_unavailable",
            requestId: stream.requestId,
            detail: "stage=\(stage) error=\(error.localizedDescription)",
            code: "ERR_STREAM_PLAYER_UNAVAILABLE"
        )
        triggerFallback(requestId: stream.requestId, reason: .playerUnavailable, stream: &stream)
    }

    // MARK: - Helpers

    private func assemblePCM(from chunks: [VoiceStreamChunk]) -> Data {
        chunks.reduce(into: Data()) { $0.append($1.payload) }
    }

    private func triggerFallback(requestId: String, reason: VoiceStreamFallbackReason, stream: inout StreamState) {
        stream.didFallback = true
        stream.gapTimer?.cancel()
        stream.gapTimer = nil
        stream.player?.stop()
        stream.player = nil
        keepAlive.stop()  // ESS-509
        WatchLog.error(
            "stream", "fallback",
            requestId: requestId,
            detail: "reason=\(reason)",
            code: "ERR_STREAM_FALLBACK"
        )
        fallbackHandler(requestId, reason)
    }

    // MARK: - Lifecycle

    /// 外部取消（用户主动关闭、回合终止等）。
    func cancelStream(requestId: String) {
        guard let active = activeStream, active.requestId == requestId else { return }
        active.gapTimer?.cancel()
        active.player?.stop()
        activeStream = nil
        keepAlive.stop()  // ESS-509
        WatchLog.info("stream", "stream_cancelled", requestId: requestId)
    }

    func cancelAll(reason: String) {
        guard let active = activeStream else { return }
        active.gapTimer?.cancel()
        active.player?.stop()
        keepAlive.stop()  // ESS-509
        WatchLog.info("stream", "stream_cancelled_all",
                       requestId: active.requestId,
                       detail: "reason=\(reason)")
        activeStream = nil
    }
}

// MARK: - StreamingAudioPlaying

/// ESS-748: the receiver's view of the PCM player. `start` / `append` are
/// throwing because a failure there means *no audio was scheduled* — the
/// receiver has to hear about it to degrade the turn.
@MainActor
protocol StreamingAudioPlaying: AnyObject {
    func start() throws
    func append(pcmData: Data) throws
    func markEndOfStream()
    func stop()
}

/// Failures that make the streaming PCM path unusable for the rest of the turn.
enum StreamingAudioPlayerError: Error, LocalizedError, Equatable {
    /// `append` was called on a player whose `start()` never succeeded.
    case notStarted
    /// `AVAudioPCMBuffer` allocation failed for the given payload size.
    case bufferAllocationFailed(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "streaming player not started"
        case .bufferAllocationFailed(let bytes):
            return "PCM buffer allocation failed for \(bytes) bytes"
        }
    }
}

// MARK: - StreamingAudioPlayer (PCM via AVAudioEngine)

/// 逐片 PCM 播放器：用 `AVAudioEngine` + `AVAudioPlayerNode` 实现无缝续播。
/// 首片入队即自动起播；之后 `append(pcmData:)` 直接把 buffer 排进 player node 队列。
@MainActor
final class StreamingAudioPlayer: StreamingAudioPlaying {
    private let sampleRate: Double
    private let context: String
    private let pcmFormat: AVAudioFormat
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode

    private var isStarted = false
    private var isEndOfStream = false
    private var totalBytes = 0
    private var totalBuffers = 0

    private static let logger = Logger(
        subsystem: "beer.workspace.wristagent", category: "StreamPlayer"
    )

    init(sampleRate: Int, context: String) {
        self.sampleRate = Double(sampleRate)
        self.context = context

        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: self.sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("StreamingAudioPlayer: unsupported PCM format")
        }
        self.pcmFormat = fmt
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: fmt)
    }

    /// ESS-748: throws instead of swallowing. A silent start failure left the
    /// receiver advancing sequences into a dead player — audio vanished with
    /// no error surface and no complete-file degradation.
    func start() throws {
        guard !isStarted else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            try engine.start()
            playerNode.play()
            isStarted = true
            WatchLog.info(
                "stream", "player_started",
                requestId: context,
                detail: "format=pcm_s16le sample_rate=\(Int(sampleRate))"
            )
        } catch {
            WatchLog.error(
                "stream", "player_start_failed",
                requestId: context,
                detail: "error=\(error.localizedDescription)",
                code: "ERR_STREAM_PLAYER_START"
            )
            throw error
        }
    }

    func append(pcmData: Data) throws {
        guard isStarted else { throw StreamingAudioPlayerError.notStarted }
        guard !pcmData.isEmpty else { return }
        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: frameCount
        ) else {
            Self.logger.error("buffer_alloc_failed bytes=\(pcmData.count)")
            throw StreamingAudioPlayerError.bufferAllocationFailed(bytes: pcmData.count)
        }
        buffer.frameLength = frameCount
        pcmData.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            memcpy(buffer.int16ChannelData!.pointee, base, pcmData.count)
        }
        playerNode.scheduleBuffer(buffer)
        totalBytes += pcmData.count
        totalBuffers += 1

        if totalBuffers == 1 {
            WatchLog.info(
                "stream", "first_buffer_scheduled",
                requestId: context,
                detail: "frames=\(frameCount) bytes=\(pcmData.count)"
            )
        }
    }

    func markEndOfStream() {
        guard !isEndOfStream else { return }
        isEndOfStream = true
        WatchLog.info(
            "stream", "end_of_stream",
            requestId: context,
            detail: "total_bytes=\(totalBytes) buffers=\(totalBuffers)"
        )
        // 播完当前队列后停止
        playerNode.scheduleBuffer(
            AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 0)!,
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        playerNode.stop()
        engine.stop()
        isStarted = false
        WatchLog.info(
            "stream", "player_stopped",
            requestId: context,
            detail: "total_bytes=\(totalBytes) buffers=\(totalBuffers)"
        )
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Constants

enum VoiceStreamConstants {
    /// Gap timeout: how long to wait for a missing sequence before declaring fallback.
    static let gapTimeoutSeconds: TimeInterval = 1.5
}
