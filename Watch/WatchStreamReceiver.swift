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
/// 顺序契约（ESS-747 / ESS-777）：**当前流只能前进，不能倒退。**
/// - 一条分片必须带合法的 `request_id` + `stream_id`；两者一起才是流身份。
/// - 同 `request_id` 换 `stream_id` 的分片一律丢弃，不得顶掉正在播的流。
/// - 只有「不比水位线旧的新 `request_id`」能取代在飞流。水位线
///   `admittedTurnFloorMs` 取自回合 `request_id` 的 UUIDv7 时间戳——
///   一条**由协议携带、单调递增**的回合序号（RFC 9562 前 48 位）。
/// - 流一旦终结（被取代 / 取消 / 回退），其 `request_id` 进有界墓碑。
///
/// 两层各自负责什么，别混：
/// - **水位线**是顺序正确性的下限：比它旧的回合永远开不了流，与墓碑
///   是否淘汰无关。这正是 ESS-777 判定「有界墓碑淘汰后旧流可再抢占」
///   的补法——不能靠一个会被 FIFO 淘汰的集合来保证顺序。
/// - **墓碑**只是最近 32 条的精确拒绝缓存（日志更好读），并兜住不带
///   时序的 `request_id`（非 UUIDv7）。它不是正确性边界。
///
/// 线程：全部 `@MainActor`；`didReceiveMessageData` 通过 `Task { @MainActor in }` 进入。
@MainActor
final class WatchStreamReceiver: ObservableObject {
    private static let logger = Logger(
        subsystem: "beer.workspace.wristagent", category: "StreamReceiver"
    )

    /// 流身份：`request_id` + `stream_id` 一起才唯一标识一条下行流。
    /// 与 `RealtimeDownlinkPlayback.SessionKey` 同一语义，命名保持一致。
    struct StreamKey: Hashable {
        let requestId: String
        let streamId: String

        init(requestId: String, streamId: String) {
            self.requestId = requestId
            self.streamId = streamId
        }

        init(chunk: VoiceStreamChunk) {
            self.init(requestId: chunk.requestId, streamId: chunk.streamId)
        }
    }

    /// 单 stream 状态：每个 request_id 最多一个活跃下行流。
    private struct StreamState {
        var buffer: VoiceStreamReorderBuffer
        let key: StreamKey
        let startedAt: Date
        let streamingGeneration: Int
        /// 本接收器内单调递增的流序号（generation）。只用于日志归因：
        /// 一条日志里能直接看出「第几条流被第几条流取代」。
        let serial: Int
        /// ESS-748：类型是协议而不是具体类——起播失败必须可判定并降级，
        /// 测试需要注入「起播必失败」的替身（模拟器造不出 AVAudioEngine 启动失败）。
        var player: StreamAudioPlaying?
        var gapTimer: Task<Void, Never>?
        var playedSequence: Int = 0
        var didFallback: Bool = false

        var requestId: String { key.requestId }
        var streamId: String { key.streamId }
    }

    // MARK: - Dependencies (injected for testability)

    private let debugSettings: WatchDebugSettings
    let fallbackHandler: (String, VoiceStreamFallbackReason) -> Void
    /// ESS-748 test seam：播放器构造缝。生产恒为 `StreamingAudioPlayer`；
    /// 单测注入「起播必失败」的替身——`AVAudioSession`/`AVAudioEngine` 的启动
    /// 失败在模拟器里无法稳定构造，没有这条缝，「起播失败必须降级」这条契约
    /// 就只能靠人眼复核（它当初正是这样漏掉的）。
    var makeStreamPlayer: (_ sampleRate: Int, _ context: String) -> StreamAudioPlaying =
        { sampleRate, context in
            StreamingAudioPlayer(sampleRate: sampleRate, context: context)
        }

    // MARK: - State

    private var activeStream: StreamState?
    private var disableObserverToken: UUID?
    /// ESS-747：已终结流的墓碑（tombstone）。有界 FIFO，只保留最近
    /// `maxRetiredRequests` 个——它负责**精确**拒绝最近若干条旧流（含
    /// 不带时序的 id），但**不是**顺序正确性的下限，见 `admittedTurnFloorMs`。
    private var retiredRequestIds: Set<String> = []
    private var retiredOrder: [String] = []
    /// ESS-777 复审阻断项：墓碑一旦 FIFO 淘汰，被淘汰的旧流又能重新抢占
    /// 当前流（窗口只是从下一轮推迟到第 33 轮以后）。所以顺序正确性不能
    /// 靠这个有界集合，必须靠一个**不会被淘汰**的单调水位线。
    ///
    /// 取值：迄今**准入过**的最新一轮的 UUIDv7 时间戳。回合 `request_id`
    /// 由 Watch 自己在 `PushToTalkController.pressBegan` 用
    /// `UUIDv7.generate()` 生成（RFC 9562 前 48 位为 Unix 毫秒），下行流的
    /// `request_id` 是同一个 id 原样回来的——因此这是一条**由协议携带、
    /// 接收端可校验、单调递增**的回合序号，不是到达顺序拍出来的本地 serial。
    ///
    /// 契约：比水位线更旧的回合**永远**开不了新流，与墓碑是否淘汰无关。
    private var admittedTurnFloorMs: UInt64?
    /// ESS-747：本接收器内单调递增的流序号，见 `StreamState.serial`。
    /// 只用于日志归因，**不参与**任何顺序判定。
    private var streamSerial = 0
    /// ESS-509: WCSession health monitor, started when streaming begins.
    private let keepAlive = RealtimeSessionKeepAlive()

    /// 墓碑上限：只是「精确拒绝」的缓存深度，超出即淘汰最旧的一条。
    /// 淘汰**不会**打开顺序漏洞——被淘汰的旧回合由 `admittedTurnFloorMs` 兜底。
    static let maxRetiredRequests = 32

    /// 门禁：编译期 OFF + debug 开关。
    var gateOpen: Bool { debugSettings.isStreamingActive }

    // MARK: - Observability (tests + logs)

    var activeRequestId: String? { activeStream?.requestId }
    var activeStreamId: String? { activeStream?.streamId }
    var activeStreamSerial: Int? { activeStream?.serial }
    var activeBufferedBytes: Int? { activeStream?.buffer.bufferedBytes }
    var retiredRequestCount: Int { retiredRequestIds.count }
    var admittedTurnFloor: UInt64? { admittedTurnFloorMs }

    // MARK: - Init

    init(
        debugSettings: WatchDebugSettings,
        fallbackHandler: @escaping (String, VoiceStreamFallbackReason) -> Void
    ) {
        self.debugSettings = debugSettings
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
        // ESS-747：身份不合法的分片不得参与「谁是当前流」的判定。放行的话，
        // 一条 request_id 为垃圾值的分片会先顶掉在飞的流、再因 invalidChunk
        // 回退——用一条无法归因的分片打死一个正在播的回答。
        guard UUID(uuidString: chunk.requestId) != nil,
              UUID(uuidString: chunk.streamId) != nil else {
            Self.logger.warning("chunk_rejected_invalid_identity seq=\(chunk.sequence)")
            return
        }

        let key = StreamKey(chunk: chunk)
        // ESS-747：墓碑优先于一切。已终结的 request_id 无论换不换 stream_id
        // 都不能重开——这正是「旧回答迟到抢占新回答」的入口。
        guard !retiredRequestIds.contains(key.requestId) else {
            WatchLog.info(
                "stream", "chunk_rejected_retired_stream",
                requestId: chunk.requestId,
                detail: "stream_id=\(chunk.streamId) seq=\(chunk.sequence)"
            )
            return
        }

        if let active = activeStream {
            if active.key == key {
                // 同一 stream：追加 chunk
            } else if active.requestId == key.requestId {
                // ESS-747：同 request_id 异 stream_id。一个回合只有一条下行流，
                // 第二条 stream_id 只可能是重传或残留——直接丢弃，**不得**顶掉
                // 在飞的流（顶掉即把已播到一半的回答从头再来）。
                WatchLog.info(
                    "stream", "chunk_rejected_stream_id_mismatch",
                    requestId: chunk.requestId,
                    detail: "incoming_stream_id=\(chunk.streamId) active_stream_id=\(active.streamId) seq=\(chunk.sequence)"
                )
                return
            } else {
                // 新 request_id：只有**不比水位线旧**的回合才配取代在飞流。
                guard admitAsNewTurn(key: key, seq: chunk.sequence) else { return }
                retire(active, reason: "new_stream_supersedes")
                startStream(key: key, generation: currentGen)
            }
        } else {
            guard admitAsNewTurn(key: key, seq: chunk.sequence) else { return }
            startStream(key: key, generation: currentGen)
        }

        guard var stream = activeStream, !stream.didFallback else { return }
        let result = stream.buffer.append(chunk)
        apply(result: result, stream: &stream)
        activeStream = stream
    }

    // MARK: - Stream lifecycle (ESS-747)

    /// 能否把这条分片当作**新一轮**来开流。
    ///
    /// 判据是回合时序水位线，不是墓碑：`request_id` 是 UUIDv7 时，比水位线
    /// 更旧的回合永远开不了流——墓碑淘汰与否都一样（ESS-777 阻断项）。
    ///
    /// 不带时序的 `request_id`（非 UUIDv7）无法比较，退回「墓碑精确拒绝」
    /// 这一层，保持既有行为，不拿随机位当时间戳用；此时也不动水位线，
    /// 免得一个随机高位把之后所有合法回合全挡在门外。
    ///
    /// 被拒的回合不会因此丢答案：整段 m4a 走 `transferSpeech` 可靠通道，
    /// 与 chunk 流并行（见 `WatchAppDelegate` 接线注释），这里只丢流式快路径。
    private func admitAsNewTurn(key: StreamKey, seq: Int) -> Bool {
        guard let incomingTurnMs = UUIDv7.turnTimestampMs(ofString: key.requestId) else {
            return true  // 无时序：只由墓碑把关
        }
        if let floor = admittedTurnFloorMs, incomingTurnMs < floor {
            WatchLog.info(
                "stream", "chunk_rejected_stale_turn",
                requestId: key.requestId,
                detail: "stream_id=\(key.streamId) seq=\(seq) turn_ms=\(incomingTurnMs) floor_ms=\(floor)"
            )
            return false
        }
        admittedTurnFloorMs = max(admittedTurnFloorMs ?? incomingTurnMs, incomingTurnMs)
        return true
    }

    /// 开一条新流。调用方必须已确认：身份合法、未进墓碑、时序不旧于水位线、
    /// 旧流已 `retire`。
    private func startStream(key: StreamKey, generation: Int) {
        streamSerial += 1
        activeStream = StreamState(
            buffer: VoiceStreamReorderBuffer(),
            key: key,
            startedAt: Date(),
            streamingGeneration: generation,
            serial: streamSerial
        )
        // ESS-509: start WCSession keep-alive when streaming begins
        keepAlive.start()
        WatchLog.info(
            "stream", "stream_started",
            requestId: key.requestId,
            detail: "stream_id=\(key.streamId) gen=\(generation) serial=\(streamSerial)"
        )
    }

    /// 终结一条流并立墓碑：停计时器与播放器、清活跃态、记 `request_id`。
    /// 单向操作——同一 `request_id` 此后不会再被接受。
    private func retire(_ stream: StreamState, reason: String) {
        stream.gapTimer?.cancel()
        stream.player?.stop()
        if activeStream?.key == stream.key { activeStream = nil }
        keepAlive.stop()  // ESS-509
        tombstone(stream.key.requestId)
        WatchLog.info(
            "stream", "stream_retired",
            requestId: stream.requestId,
            detail: "stream_id=\(stream.streamId) serial=\(stream.serial) reason=\(reason)"
        )
    }

    /// 有界 FIFO 墓碑。超出上限即淘汰最旧的一条——上限远大于一次会话的
    /// 回合数，被淘汰的 `request_id` 早已不可能还有分片在路上。
    private func tombstone(_ requestId: String) {
        guard retiredRequestIds.insert(requestId).inserted else { return }
        retiredOrder.append(requestId)
        while retiredOrder.count > Self.maxRetiredRequests {
            let evicted = retiredOrder.removeFirst()
            retiredRequestIds.remove(evicted)
        }
    }

    // MARK: - Buffer result handling

    private func apply(result: VoiceStreamBufferResult, stream: inout StreamState) {
        switch result {
        case .accepted:
            scheduleGapTimer(stream: &stream)

        case .duplicate:
            break

        case .ready(let chunks):
            let pcmData = assemblePCM(from: chunks)
            // ESS-748：播放器起不来就**立刻降级一次**，不再推进序列。
            // 推进了等于宣称「这段已经放过了」，整段回答会静默消失。
            guard ensurePlayer(stream: &stream) else {
                triggerFallback(reason: .playerStartFailed, stream: &stream)
                return
            }
            stream.player?.append(pcmData: pcmData)
            stream.playedSequence = stream.buffer.nextSequence

            let endOfStream = chunks.contains(where: \.endOfStream)
            if endOfStream {
                stream.player?.markEndOfStream()
            } else {
                scheduleGapTimer(stream: &stream)
            }

        case .fallback(let reason):
            triggerFallback(reason: reason, stream: &stream)

        case .alreadyFellBack:
            break
        }
    }

    // MARK: - Gap timer

    private func scheduleGapTimer(stream: inout StreamState) {
        stream.gapTimer?.cancel()
        // ESS-747：计时器认的是完整流身份，不是只认 request_id——否则同
        // request_id 的另一条流会被上一条流的超时误伤。
        let capturedKey = stream.key
        stream.gapTimer = Task { [weak self] in
            let timeout = VoiceStreamConstants.gapTimeoutSeconds
            let nanos = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, var active = self.activeStream,
                      active.key == capturedKey, !active.didFallback else { return }
                let result = active.buffer.gapTimedOut()
                self.apply(result: result, stream: &active)
                self.activeStream = active
            }
        }
    }

    // MARK: - Player

    /// ESS-748：起播失败时**不保存 player**（保存一个永远不出声的实例，
    /// 后续 append 全部静默丢弃），并把失败如实交回调用方。
    /// - Returns: 播放器是否可用。
    private func ensurePlayer(stream: inout StreamState) -> Bool {
        if stream.player != nil { return true }
        let player = makeStreamPlayer(24_000, stream.requestId)
        do {
            try player.start()
        } catch {
            return false
        }
        stream.player = player
        return true
    }

    // MARK: - Helpers

    private func assemblePCM(from chunks: [VoiceStreamChunk]) -> Data {
        chunks.reduce(into: Data()) { $0.append($1.payload) }
    }

    private func triggerFallback(reason: VoiceStreamFallbackReason, stream: inout StreamState) {
        let requestId = stream.requestId
        stream.didFallback = true
        stream.gapTimer?.cancel()
        stream.gapTimer = nil
        stream.player?.stop()
        stream.player = nil
        keepAlive.stop()  // ESS-509
        // ESS-747：回退是终局——整段 m4a 由可靠通道接管，这条流的任何后续
        // 分片（含换了 stream_id 的重传）都必须被丢弃，不能再起播放。
        tombstone(requestId)
        WatchLog.error(
            "stream", "fallback",
            requestId: requestId,
            detail: "reason=\(reason)",
            code: "ERR_STREAM_FALLBACK"
        )
        fallbackHandler(requestId, reason)
    }

    // MARK: - Lifecycle

    /// 外部取消（用户主动关闭、回合终止等）。取消即立墓碑：被取消的回合
    /// 不会因为一条迟到分片又活过来。
    func cancelStream(requestId: String) {
        guard let active = activeStream, active.requestId == requestId else { return }
        retire(active, reason: "cancelled")
        WatchLog.info("stream", "stream_cancelled", requestId: requestId)
    }

    func cancelAll(reason: String) {
        guard let active = activeStream else { return }
        retire(active, reason: reason)
        WatchLog.info("stream", "stream_cancelled_all",
                       requestId: active.requestId,
                       detail: "reason=\(reason)")
    }
}

// MARK: - StreamingAudioPlayer (PCM via AVAudioEngine)

/// ESS-748：流播放器的可注入接缝。抽成协议只为一件事——让「起播失败必须
/// 立即降级、不得推进序列」这条契约可以在 CI 上被断言；模拟器里无法稳定
/// 制造 `AVAudioEngine` 启动失败。
@MainActor
protocol StreamAudioPlaying: AnyObject {
    /// 起播。**失败必须抛出**，调用方据此降级（返回 Void 会让失败静默）。
    func start() throws
    func append(pcmData: Data)
    func markEndOfStream()
    func stop()
}

/// 逐片 PCM 播放器：用 `AVAudioEngine` + `AVAudioPlayerNode` 实现无缝续播。
/// 首片入队即自动起播；之后 `append(pcmData:)` 直接把 buffer 排进 player node 队列。
@MainActor
final class StreamingAudioPlayer: StreamAudioPlaying {
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

    /// ESS-748：起播失败必须**可判定**。
    ///
    /// 修这条之前本函数捕获错误后返回 Void，调用方无从得知起播失败：
    /// receiver 照旧保存 player、照旧推进 `playedSequence`、照旧在 EOS 时
    /// 标记结束，而 `append` 因 `isStarted == false` 静默丢弃每一帧——
    /// 结果是音频整段消失、用户没有任何提示、也不会降级到完整文件。
    ///
    /// - Throws: 底层 `AVAudioSession` / `AVAudioEngine` 的启动错误。
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

    func append(pcmData: Data) {
        guard isStarted, !pcmData.isEmpty else { return }
        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: frameCount
        ) else {
            Self.logger.error("buffer_alloc_failed bytes=\(pcmData.count)")
            return
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
