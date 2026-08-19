import AVFoundation
import Foundation

/// Turn-scoped guard that keeps audio-session activation idempotent while
/// leaving a failed activation retryable on the next playable chunk.
///
/// ESS-509: gate now also manages the shared AVAudioSession so the realtime
/// playback engine and the SpeechPlayer don't fight over the same session.
struct RealtimePlaybackAudioSessionGate {
    private(set) var isActivated = false

    /// Activate the audio session for playback. Idempotent within a turn;
    /// `reset()` between turns makes it retryable on activation failure.
    mutating func activate(using operation: () throws -> Void) throws {
        guard !isActivated else { return }
        try operation()
        isActivated = true
    }

    /// ESS-509: activate the shared AVAudioSession for realtime playback.
    /// Uses `.playback` (not `.playAndRecord`) because this gate only guards
    /// the downlink playback side — the uplink mic tap owns `.playAndRecord`
    /// during recording. Deactivation is the caller's responsibility.
    mutating func activateAudioSession() throws {
        guard !isActivated else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        isActivated = true
    }

    /// ESS-509: deactivate the playback audio session. Called when the turn
    /// ends so the SpeechPlayer (or the next recording) can take over.
    mutating func deactivateAudioSession() {
        guard isActivated else { return }
        isActivated = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    mutating func reset() {
        isActivated = false
    }
}

/// ESS-534: decide whether the render path must be rebuilt after the recorder
/// releases the shared AVAudioSession. The first downlink after activation is
/// always rebuilt because AVAudioEngine may still report `isRunning == true`
/// even though the session deactivation has detached it from the output route.
/// ESS-554 rebase 注：enqueue 侧的调用点已随 main 的 ESS-509 架构移除
///（激活收敛到 prepare()），本纯函数策略保留——WatchRealtimeMediaAdapterTests
/// 仍在断言它的判定矩阵。
struct RealtimeRenderRecoveryPolicy {
    static func shouldRestartEngine(
        firstDeltaAfterSessionActivation: Bool,
        engineIsRunning: Bool
    ) -> Bool {
        firstDeltaAfterSessionActivation || !engineIsRunning
    }

    static func shouldRestartNode(
        engineWasRestarted: Bool,
        nodeIsPlaying: Bool
    ) -> Bool {
        engineWasRestarted || !nodeIsPlaying
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
    /// ESS-843 方案 B：`.voiceChat` AEC 模式会压低播放音量。对下行 PCM16
    /// 采样做线性增益补偿。4.0 ≈ +12dB——实测「声音太小」的补偿量，后续
    /// 真机可调。仅作用于下行播放，不影响录音/回声消除。
    var outputGain: Float = 4.0
    /// ESS-554：`.conversation` 时会话与引擎生命周期归
    /// ConversationAudioController——enqueue 不再做 `.playAndRecord →
    /// .playback` 翻转与每轮引擎重启（ESS-535 重启逻辑上移为会话级）。
    /// `.turn` 为旧路径（RealtimePlaybackAudioSessionGate）。
    private let lifecycleOwner: () -> RealtimeAudioLifecycleOwner

    private(set) var currentTurn: RealtimeMediaSession.TurnHandle?
    private(set) var isRunning = false

    /// ESS-650（F2-3）：停播确认。读 `AVAudioPlayerNode.isPlaying`——节点的
    /// **真实渲染状态**，不是「我们调用过 stop()」的意图。`bargeIn` / `stop`
    /// 里的 `playerNode.stop()` 是同步的，所以调用返回后这里即为 false；
    /// 万一某天不是（换实现、换节点），`session_interrupt_stop_unconfirmed`
    /// 会当场把它暴露出来，而不是让 stop_ms 悄悄变成一个好看的假数字。
    var isRenderingDownlink: Bool { playerNode.isPlaying }
    /// ESS-509: audio session gate that prevents the engine from stomping
    /// on another player's session (SpeechPlayer, StreamingAudioPlayer)
    /// and ensures deactivation happens exactly once per turn.
    /// ESS-554 rebase：本声明保留 ESS-509 版本（分支曾上移到 lifecycleOwner
    /// 旁，去重后只留这一份）。
    private var audioSessionGate = RealtimePlaybackAudioSessionGate()
    /// ESS-335 receipt state machine lives in Shared/ for unit testability
    /// without AVFoundation. Every real completion callback pokes it; the
    /// tracker's returned receipts become the `.started/.ended` events we
    /// forward through `onPlaybackEvent`.
    private var tracker = RealtimePlaybackReceiptTracker()

    /// Coordinator subscribes here so the session can turn playback receipts
    /// into `playback.started` / `playback.ended` on the wire.
    var onPlaybackEvent: ((PlaybackEvent) -> Void)?

    init(format: RealtimeMediaFormat = .downlinkPCM16, audioEngine: AVAudioEngine = AVAudioEngine(),
         lifecycleOwner: @escaping () -> RealtimeAudioLifecycleOwner = { .turn }) {
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
        self.lifecycleOwner = lifecycleOwner
        self.playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
    }

    func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {
        stop(barge: false)
        currentTurn = turn
        tracker.reset()
        if lifecycleOwner() == .conversation {
            // ESS-554：引擎由 controller 在会话 acquire 时启动并跨回合保持；
            // 本地 isRunning 记账与引擎真实状态对齐，仅在未跑时兜底启动。
            isRunning = audioEngine.isRunning
        } else {
            // ESS-509: activate the playback audio session idempotently per turn.
            // If another player (SpeechPlayer) owns the session, this will fail
            // and the caller (WatchRealtimeMediaAdapter) catches it as a fallback.
            try audioSessionGate.activateAudioSession()
        }
        if !isRunning {
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
        }
        playerNode.play()
    }

    func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
        guard let turn = currentTurn else { return }
        // ESS-554: `.conversation` 模式下整段会话翻转与引擎重启都不存在——
        // 会话由 ConversationAudioController 全程持有 `.playAndRecord`，
        // 引擎自 acquire 起一直挂在该会话上；
        // 只需保证 playerNode 在播（bargeIn 会停 node，新 delta 到来时恢复）。
        // ESS-554 rebase 注：`.turn` 路径的 ESS-534/535 enqueue 重建块已被
        // main 的 ESS-509 移除（激活收敛到 prepare() 的 audioSessionGate），
        // 此处不再保留旧 else 分支。
        if lifecycleOwner() == .conversation, !playerNode.isPlaying {
            playerNode.play()
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
        // ESS-509: release the playback audio session so other players can
        // activate. Idempotent — gate won't double-deactivate.
        audioSessionGate.deactivateAudioSession()
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
        let gain = outputGain
        if gain == 1.0 {
            payload.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: Int16.self).baseAddress {
                    channel.update(from: base, count: Int(frameCount))
                }
            }
        } else {
            // ESS-843 方案 B：对每个 Int16 采样做线性增益并 clamp 到 Int16 范围，
            // 补偿 .voiceChat 音量压低。放大先做再截断，避免溢出失真。
            payload.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
                for i in 0..<Int(frameCount) {
                    let sample = Int16(littleEndian: base[i])
                    let scaled = Float(sample) * gain
                    let clamped = max(Float(Int16.min), min(Float(Int16.max), scaled))
                    channel[i] = Int16(clamped)
                }
            }
        }
        return pcmBuffer
    }
}
