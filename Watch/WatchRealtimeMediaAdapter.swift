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
        /// ESS-650（F2-3）：播放器此刻是否还在出声。`stop_ms` 若只量到同步
        /// 函数返回，量的是调用开销而不是停播延迟（ESS-667 复审阻断 4）。
        var isRenderingDownlink: Bool { get }
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
        func sendStreamStart(_ start: RealtimeStreamStart, conversationId: String?, turnId: String?)
        func sendAudioAppend(_ chunk: VoiceStreamChunk, conversationId: String?, turnId: String?)
        func sendAudioCommit(_ commit: RealtimeStreamCommit, conversationId: String?, turnId: String?)
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
    /// First PCM frame reached the realtime playback engine. This is distinct
    /// from `onRealtimePendingResolved`, which also fires for fallback/cancel
    /// paths where background keep-alive must remain active.
    var onRealtimePlaybackStarted: (@MainActor () -> Void)?
    var onVADEvent: (@MainActor (LocalVADEvent) -> Void)?

    /// ESS-600：**realtime 回答音频真实起播**（`RealtimePlaybackEngine` 的
    /// 第一个 buffer 已经渲染，不是收到 delta、不是入队成功）。realtime 是
    /// 默认播放路径，会话回合状态机的 `thinking → speaking` 必须由这里驱动——
    /// 只接完整文件 `SpeechPlayer` 那条回退路径等于核心闭环没接通
    /// （ESS-600 复审阻断 1）。
    var onAnswerPlaybackStarted: (@MainActor (RealtimeMediaSession.TurnHandle) -> Void)?
    /// ESS-600：**realtime 回答音频真实播完**（最后一个排队 buffer 渲染完毕）。
    /// 只有本回合（requestId + sessionId 双匹配）的事件才上报；上一轮的迟到
    /// `.ended` 在这里就被 `currentTurn` 挡掉，并留证 `stale_playback_dropped`。
    var onAnswerPlaybackFinished: (@MainActor (RealtimeMediaSession.TurnHandle, _ bytesPlayed: Int) -> Void)?
    /// ESS-600：realtime 播放失败。失败不得伪装成播完——会话层据此走
    /// `session_answer_failed` 的显式恢复路径。
    var onAnswerPlaybackFailed: (@MainActor (RealtimeMediaSession.TurnHandle, _ code: String) -> Void)?

    /// ESS-573: 真实通道就绪事件——本回合**首个被对端接受的 uplink ack**
    /// 到达时触发一次。该 ack 由 iPhone 在 WSS 实际发出音频后回发
    /// （PhoneConnectivity.acknowledgeRealtimeAppendIfNeeded），因此它证明
    /// Watch→iPhone→Bridge 全链路已通，而不是本地「录音开始了」。
    /// ESS-573 复审硬性要求：会话 UI 的 connecting → listening 只能由
    /// 这个真实事件驱动，不得在发起录音后同步宣告 ready。
    var onChannelReady: (@MainActor (_ requestId: String) -> Void)?
    /// ESS-960：通道终态（iPhone → Watch）。接线在 `attachSessionEvents`，
    /// 终点是 `SessionController.markChannelFailed(.channelEvent)`。
    var onChannelFailed: (@MainActor (_ requestId: String, _ reason: String) -> Void)?

    /// ESS-573: 快速上行通道死亡事件（传输失败 / 缓冲溢出 / 采集 tap
    /// 失败等，经 RealtimeMediaSession 单发兜底）。会话模式据此刻意
    /// 告知并退出——「不假装还在对话」。PTT 路径不受影响（完整文件
    /// 回退照常交付）。
    var onUplinkFallback: (@MainActor (_ requestId: String) -> Void)?

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
    /// ESS-600：回答播完后的 VAD 静默窗，**跨回合保留**。
    /// `beginTurn` 里的 `reset(atMs:)` 会把守卫清成「此刻」——在自动重新
    /// 聆听下这正好把守卫清掉了：上一轮回答刚播完就开麦，扬声器余音与
    /// 混响会被当成用户开口（Watch 无 AEC）。把守卫带过回合边界，让新一轮
    /// 的头 `playbackGuardMs` 不参与断句判定。
    private var vadGuardUntilMs: Int64 = 0
    /// ESS-865：上一次落 `vad_level` 取证的帧时刻。真机排查「VAD 为什么不
    /// 断句」此前没有任何电平/门限观测点，只能靠猜——这条周期采样是本单
    /// 唯一能在下一次真机跑里直接判定「门高了还是麦克风哑了」的证据。
    private var vadLastLevelLogAtMs: Int64?
    /// 取证采样周期。2s 一条，一轮 55s 上限最多 28 条，不淹没日志。
    private static let vadLevelLogIntervalMs: Int64 = 2_000

    // MARK: - ESS-650 语音打断（F2-2 / F2-3）

    /// speaking 期间的打断监听是否开着。为真时麦克风帧**只**喂
    /// `VoiceBargeInDetector`，绝不进上行（F2-2「零上行」）。
    private(set) var isBargeInListening = false
    private var bargeInDetector = VoiceBargeInDetector()
    private var bargeInFrameStartedAtMs: Int64 = 0
    /// 本次 speaking 的起播时刻，用于算 `detect_ms`（起说 → 判定命中）。
    private var bargeInPlaybackStartedAtMs: Int64 = 0
    /// 语音打断命中。参数是 `detect_ms`——ESS-655 埋点契约要求把「慢在检测」
    /// 与「慢在停播」分开，停播耗时由 `SessionController` 就地量。
    var onVoiceBargeInDetected: (@MainActor (_ detectMs: Int) -> Void)?
    private(set) var didTriggerCompleteFileFallback = false
    /// ESS-573: 每回合只向上一层宣告一次「通道就绪」（首个 ack）。
    private var didSignalChannelReady = false
    private(set) var currentTurn: RealtimeMediaSession.TurnHandle?
    /// ESS-330: latest `response_id` observed on `audio.delta` for the current
    /// turn. Bridge PR #113 (`realtime-media-session.mjs:67-70`) tags every
    /// delta with the real Agent response_id and expects playback receipts
    /// (`playback.started/ended`) to echo the same value so multi-response
    /// sessions stay disambiguated. Cleared when the turn ends.
    private(set) var currentResponseId: String?

    /// ESS-509: called when the adapter finishes the current turn (any reason).
    /// The outer controller uses this to release the WCSession keep-alive hold
    /// since the realtime path is done and no more downlink deltas are expected.
    var onTurnFinished: (@MainActor (RealtimeMediaSession.TurnHandle, RealtimeMediaSession.FinishReason) -> Void)?

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
            // ESS-650 F2-2：speaking 期间的打断监听是**只进 VAD、零上行**的。
            // 这条早退是「零上行」的唯一实现点——绝不能改成「先 push 再判断」，
            // 那样回答播放期间用户的每一帧都会被当成新一轮输入送上去。
            guard !self.isBargeInListening else {
                self.consumeBargeIn(frame)
                return
            }
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
                self.onRealtimePlaybackStarted?()
                self.onRealtimePendingResolved?()
                // ESS-330 v3: forward the response_id the player emitted
                // (which was preserved per chunk through the reorder buffer).
                // No session_id substitution — Bixuan's acceptance criteria
                // explicitly forbids that.
                guard let handle = self.currentTurn,
                      handle.requestId == requestId, handle.sessionId == sessionId else {
                    self.logStalePlayback(event: "started", requestId: requestId, sessionId: sessionId)
                    break
                }
                // ESS-600：首帧已渲染 = 回答真实开口。会话回合状态机
                // thinking → speaking 的唯一驱动源（realtime 侧）。
                WatchLog.info(
                    "realtime", "play_started", requestId: requestId,
                    detail: "path=realtime response_id=\(responseId ?? "nil") turn_id=\(handle.turnId)"
                )
                self.onAnswerPlaybackStarted?(handle)
                guard let responseId else { break }
                self.transport.sendPlaybackStarted(handle: handle, responseId: responseId)
            case .ended(let requestId, let sessionId, let responseId, let bytesPlayed):
                self.playbackEndedForVADGuard()
                guard let handle = self.currentTurn,
                      handle.requestId == requestId, handle.sessionId == sessionId else {
                    self.logStalePlayback(event: "ended", requestId: requestId, sessionId: sessionId)
                    break
                }
                if let responseId {
                    self.transport.sendPlaybackEnded(
                        handle: handle,
                        responseId: responseId,
                        bytesPlayed: bytesPlayed
                    )
                    WatchLog.info(
                        "realtime", "result_delivered_after_render",
                        requestId: requestId,
                        detail: "response_id=\(responseId) bytes_played=\(bytesPlayed)"
                    )
                }
                // ESS-600：最后一个排队 buffer 已渲染 = 回答真实说完，
                // 会话据此自动开下一轮采集（speaking → listening）。
                WatchLog.info(
                    "realtime", "play_finished", requestId: requestId,
                    detail: "path=realtime response_id=\(responseId ?? "nil") bytes_played=\(bytesPlayed) turn_id=\(handle.turnId)"
                )
                // 一个回合可能携带多个 response（`RealtimePlaybackReceiptTracker`
                // 的 `superseded` 分支：被更新的 response 顶掉的旧 response 也会
                // 发 `.ended`）。只有**当前** response 播完才算这一轮答完——
                // 拿被顶掉的旧 response 去开下一轮，用户还没听到新回答就被重新
                // 开麦了。responseId 任一侧为 nil 时不做此判定（旧链路无 id）。
                if let responseId, let current = self.currentResponseId, responseId != current {
                    WatchLog.info(
                        "realtime", "superseded_response_ended", requestId: requestId,
                        detail: "response_id=\(responseId) current_response_id=\(current)"
                    )
                    break
                }
                self.onAnswerPlaybackFinished?(handle, bytesPlayed)
                // A playback `.ended` event closes only this response. One
                // realtime session may carry multiple responses, so ending
                // the downlink here would reject the next response's chunks
                // as `.sessionEnded`. Explicit cancel, interruption, or the
                // next turn remains responsible for closing/replacing it.
            case .bargedIn:
                break
            case .failed(let requestId, let sessionId, _, let code):
                WatchLog.error(
                    "realtime", "playback_engine_failed",
                    requestId: requestId,
                    detail: "playback_event=failed",
                    code: code
                )
                // ESS-600：播放失败绝不记成播完。会话层走显式失败恢复。
                guard let handle = self.currentTurn,
                      handle.requestId == requestId, handle.sessionId == sessionId else {
                    self.logStalePlayback(event: "failed", requestId: requestId, sessionId: sessionId)
                    break
                }
                self.onAnswerPlaybackFailed?(handle, code)
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
        didSignalChannelReady = false
        currentResponseId = nil
        vadFrameStartedAtMs = Self.uptimeMs()
        vadLastLevelLogAtMs = nil
        // ESS-600：守卫带过回合边界（见 `vadGuardUntilMs`）。
        vadEndpointer?.reset(atMs: max(vadFrameStartedAtMs, vadGuardUntilMs))
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

    /// ESS-600：不属于当前回合的播放事件被丢弃时留证。上一轮的迟到
    /// `.started/.ended` 若被当成本轮事件上报，会话会在用户还没说话时
    /// 就跳到下一轮——「旧音频零补播」这条验收正是钉这里。
    private func logStalePlayback(event: String, requestId: String, sessionId: String) {
        WatchLog.info(
            "realtime", "stale_playback_dropped", requestId: requestId,
            detail: "event=\(event) session_id=\(sessionId) current_request_id=\(currentTurn?.requestId ?? "nil")"
        )
    }

    /// ESS-600：会话边界。进入实时对话时开一个 conversation，退出时关闭——
    /// `conversation_id` 由 `ConversationHandle` 唯一铸造并在整段会话内保持
    /// 不变，`turn_id` 每轮 `beginTurn` 递增（见 `RealtimeMediaSession.beginTurn`）。
    @discardableResult
    func beginConversation() -> ConversationHandle {
        session.beginConversation()
    }

    /// ESS-600：关闭会话边界。关闭后旧回合的迟到事件因无 conversation 存续
    /// 而被拒，不会漏进下一次会话。
    func closeConversation() {
        session.closeConversation()
    }

    func playbackEndedForVADGuard(atMs: Int64? = nil) {
        let effectiveAtMs = atMs ?? Self.uptimeMs()
        vadEndpointer?.playbackEnded(atMs: effectiveAtMs)
        vadFrameStartedAtMs = effectiveAtMs
        vadGuardUntilMs = effectiveAtMs + (vadEndpointer?.configuration.playbackGuardMs ?? 0)
    }

    // MARK: - ESS-650 打断监听生命周期

    /// F2-2：进入 speaking 时开启「只听不传」的打断监听。
    ///
    /// 复用同一个 recorder（不另起第二路采集：两路麦克风在 watchOS 上必然
    /// 抢会话）；开关只在 `onFrame` 的分流上，因此「零上行」是结构性的，
    /// 不依赖调用方记得关。gate OFF 时调用方根本不调本函数。
    func beginBargeInListening(atMs: Int64? = nil) {
        guard !isBargeInListening else { return }
        let atMs = atMs ?? Self.uptimeMs()
        isBargeInListening = true
        bargeInFrameStartedAtMs = atMs
        bargeInPlaybackStartedAtMs = atMs
        bargeInDetector.playbackStarted(atMs: atMs)
        do {
            try recorder.start()
        } catch {
            // 起采失败不阻断回答播放——打断退化为「只能点球」，如实留证。
            isBargeInListening = false
            WatchLog.error(
                "realtime", "barge_in_listen_start_failed",
                requestId: currentTurn?.requestId,
                detail: "error=\(error.localizedDescription)", error: error
            )
            return
        }
        WatchLog.info(
            "realtime", "barge_in_listening_started", requestId: currentTurn?.requestId,
            detail: "uplink=disabled guard_ms=\(bargeInDetector.configuration.playbackGuardMs)"
        )
    }

    /// ESS-650 F2-5：一轮打断监听的对账单。会话层拿它落
    /// `session_barge_in_self_echo`（`turn_index` 只有会话层知道）。
    struct BargeInRoundSummary: Equatable {
        /// 本轮真的喂进检测器的帧数。**`frames > 0` 才说明监听跑过**——
        /// 没有这个数，`self_echo_frames=0` 和「压根没在听」无法区分。
        let frames: Int
        /// 本轮守卫窗内的超阈帧数（自身回声）。F2-5 的门禁读数。
        let selfEchoFrames: Int
        /// 会话内累计自身回声帧数。
        let cumulativeSelfEchoFrames: Int
        /// 本轮守卫窗峰值能量（dB，满量程相对值）。无回声为 -120.0。
        let peakGuardDB: Double
    }

    /// 结束打断监听（回答播完 / 被打断 / gate 关掉 / 退出会话）。
    /// `reason` 进日志，便于把「gate 动态关闭即时停采」与其它停采区分开。
    /// - Returns: 本轮对账单；本来就没在监听时返回 nil（幂等调用不产生假账）。
    @discardableResult
    func endBargeInListening(reason: String) -> BargeInRoundSummary? {
        guard isBargeInListening else { return nil }
        isBargeInListening = false
        recorder.stop()
        let summary = BargeInRoundSummary(
            frames: bargeInDetector.roundFrameCount,
            selfEchoFrames: bargeInDetector.roundSelfEchoFrameCount,
            cumulativeSelfEchoFrames: bargeInDetector.selfEchoFrameCount,
            peakGuardDB: bargeInDetector.roundPeakGuardDB
        )
        bargeInDetector.playbackEnded()
        WatchLog.info(
            "realtime", "barge_in_listening_stopped", requestId: currentTurn?.requestId,
            detail: "reason=\(reason) frames=\(summary.frames) "
                + "self_echo_frames=\(summary.selfEchoFrames) "
                + "cumulative_self_echo_frames=\(summary.cumulativeSelfEchoFrames)"
        )
        return summary
    }

    /// ESS-650（F2-3）：下行播放器此刻是否还在出声。停播确认的唯一读点——
    /// 「我们调用过 stop()」不是停播证据。
    var isRenderingDownlink: Bool { player.isRenderingDownlink }

    /// 累计的疑似自身回声帧数（守卫窗内的高能量帧）。F2-5 的对账口径。
    var bargeInSelfEchoFrameCount: Int { bargeInDetector.selfEchoFrameCount }

    /// 打断监听的帧消费：**只**喂检测器，不碰上行、不碰会话 VAD。
    private func consumeBargeIn(_ frame: Data) {
        let events = bargeInDetector.processPCM16(frame, frameStartedAtMs: bargeInFrameStartedAtMs)
        bargeInFrameStartedAtMs += Int64(
            frame.count / MemoryLayout<Int16>.size * 1_000 / vadSampleRate
        )
        for event in events {
            switch event {
            case .energySpike(let atMs):
                WatchLog.info(
                    "realtime", "barge_in_energy_spike", requestId: currentTurn?.requestId,
                    detail: "at_ms=\(atMs)"
                )
            case .bargeInDetected(let startedAtMs, let detectedAtMs):
                // ESS-650：`detect_ms` 是**起说 → 判定命中**（ESS-655 契约，
                // `PhoneModeTelemetry.swift` 的 speakingInterrupted 注释）。
                // 早先这里算的是「起播 → 起说」——那是「用户第几秒插的话」，
                // 用它冒充检测延迟会让 F2-3 的延迟口径整体失真。
                let detectMs = Int(max(0, detectedAtMs - startedAtMs))
                let sincePlaybackMs = Int(max(0, startedAtMs - bargeInPlaybackStartedAtMs))
                WatchLog.info(
                    "realtime", "barge_in_detected", requestId: currentTurn?.requestId,
                    detail: "at_ms=\(startedAtMs) detect_ms=\(detectMs) "
                        + "since_playback_ms=\(sincePlaybackMs)"
                )
                onVoiceBargeInDetected?(detectMs)
            }
        }
    }

    private func consumeVAD(_ frame: Data) {
        guard var endpointer = vadEndpointer else { return }
        let frameStartedAtMs = vadFrameStartedAtMs
        let events = endpointer.processPCM16(frame, frameStartedAtMs: frameStartedAtMs)
        vadFrameStartedAtMs += Int64(
            frame.count / MemoryLayout<Int16>.size * 1_000 / vadSampleRate
        )
        vadEndpointer = endpointer
        logVADLevelIfDue(metrics: endpointer.metrics, frameStartedAtMs: frameStartedAtMs)
        for event in events {
            switch event {
            case .speechStarted(let atMs):
                WatchLog.info(
                    "vad", "speech_started", requestId: currentTurn?.requestId,
                    detail: "at_ms=\(atMs) \(endpointer.metrics.logDetail)"
                )
            case .speechFinal(let atMs, let reason):
                WatchLog.info(
                    "vad", "speech_final", requestId: currentTurn?.requestId,
                    detail: "at_ms=\(atMs) reason=\(reason.rawValue) \(endpointer.metrics.logDetail)"
                )
                if automaticallyCommitOnSpeechFinal {
                    recorder.stop()
                    session.commitUplink()
                }
            }
            onVADEvent?(event)
        }
    }

    /// ESS-865：周期性落一条能量/门限取证。首帧必落一条（`vadLastLevelLogAtMs`
    /// 初值为 nil），因此「一轮里一条 vad_level 都没有」本身就是「帧根本
    /// 没进 VAD」的判据，与「进了 VAD 但没跨门」可以直接区分开。
    private func logVADLevelIfDue(metrics: LocalVADMetrics, frameStartedAtMs: Int64) {
        if let last = vadLastLevelLogAtMs,
           frameStartedAtMs - last < Self.vadLevelLogIntervalMs { return }
        vadLastLevelLogAtMs = frameStartedAtMs
        WatchLog.info(
            "vad", "vad_level", requestId: currentTurn?.requestId,
            detail: "at_ms=\(frameStartedAtMs) \(metrics.logDetail)"
        )
    }

    static func uptimeMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }

    func receiveUplinkAck(_ ack: RealtimeUplinkAck) {
        guard session.acknowledgeUplink(ack) else { return }
        WatchLog.info(
            "realtime", "uplink_ack_received", requestId: ack.requestId,
            detail: "sequence=\(ack.sequence) bytes=\(ack.byteCount)"
        )
        // ESS-573: 首个被对端接受的 ack = 通道就绪的唯一真实信号。
        if !didSignalChannelReady {
            didSignalChannelReady = true
            onChannelReady?(ack.requestId)
        }
    }

    func receiveChannelReady(_ ready: RealtimeChannelReady) {
        guard let turn = currentTurn,
              turn.requestId == ready.requestId,
              turn.sessionId == ready.sessionId else {
            WatchLog.info(
                "realtime", "stale_channel_ready_dropped", requestId: ready.requestId,
                detail: "session_id=\(ready.sessionId)"
            )
            return
        }
        guard !didSignalChannelReady else { return }
        didSignalChannelReady = true
        WatchLog.info(
            "realtime", "channel_ready_received", requestId: ready.requestId,
            detail: "session_id=\(ready.sessionId) source=transport_connected"
        )
        onChannelReady?(ready.requestId)
    }

    /// ESS-960 缺陷 4：iPhone 侧实时通道走到终态（Gateway `retriable:false`、
    /// 通道死亡、显式回退）。与 `markDownlinkBridgeFallback` 分开：那条是
    /// 「下行快通道死了，降级到整文件，用户还能拿到结果」，这条是
    /// 「本回合的通道彻底没了」，必须让用户看见。
    func receiveChannelFailed(_ failed: RealtimeChannelFailed) {
        guard let turn = currentTurn,
              turn.requestId == failed.requestId,
              turn.sessionId == failed.sessionId else {
            WatchLog.info(
                "realtime", "stale_channel_failed_dropped", requestId: failed.requestId,
                detail: "session_id=\(failed.sessionId) reason=\(failed.reason)"
            )
            return
        }
        WatchLog.error(
            "realtime", "channel_failed_received", requestId: failed.requestId,
            detail: "session_id=\(failed.sessionId) reason=\(failed.reason)",
            code: "ERR_REALTIME_CHANNEL_FAILED"
        )
        onChannelFailed?(failed.requestId, failed.reason)
    }

    /// Called when the user starts speaking again mid-response.
    func bargeIn() {
        session.bargeInDownlink()
    }

    /// ESS-865：本回合上行是否已提交（供 PTT 层判定「未提交回合」的清理
    /// 是否还成立）。
    var hasCommittedUplink: Bool { session.didCommitUplink }

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
            let handle = currentTurn
            transport.sendStreamStart(
                start,
                conversationId: handle?.conversationId,
                turnId: handle?.turnId
            )
        case .uplinkAppend(let chunk):
            let handle = currentTurn
            transport.sendAudioAppend(
                chunk,
                conversationId: handle?.conversationId,
                turnId: handle?.turnId
            )
        case .uplinkCommit(let commit):
            let handle = currentTurn
            transport.sendAudioCommit(
                commit,
                conversationId: handle?.conversationId,
                turnId: handle?.turnId
            )
        case .uplinkFallback(let reason, let handle):
            recorder.stop()
            player.stop(barge: false)
            // ESS-573: 快速上行已死——无论完整文件回退是否执行，都向
            // 会话层如实上报（PTT 层忽略此回调，行为不变）。
            onUplinkFallback?(handle.requestId)
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
            onTurnFinished?(handle, reason)
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
