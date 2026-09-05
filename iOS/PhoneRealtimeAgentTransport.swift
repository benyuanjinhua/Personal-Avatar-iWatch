import Foundation
import os

/// ESS-391 production transport adapter: wraps `AudioRealtimeAgentSession` so
/// it conforms to `PhoneRealtimeSession.Transport`, translating Watch-side
/// `RealtimeUplinkEnvelope`/`RealtimeDownlinkEnvelope` ↔ Agent
/// `AudioRealtimeAgentCodec.UplinkFrame`/`DownlinkEvent`.
///
/// The iPhone is the **sole generation owner** (ESS-391 §契约). When Watch
/// sends a `bargein.request` uplink, this transport advances generation,
/// sends `cancel(from_generation)` on the Agent WSS, and replies with a
/// `generation.open(new_gen)` downlink envelope.
///
/// Codec boundaries:
///   - Uplink: Watch envelope → Agent frame (stream.start, audio.append,
///     audio.commit, cancel). Playback receipts and fallback are no-ops
///     through the Agent path (the Agent does not consume Bridge receipts).
///   - Downlink: Agent event → Watch envelope (ready is logged; audio.delta
///     and audio.done carry generation+finalSequence per ESS-404).
@MainActor
final class PhoneRealtimeAgentTransport: PhoneRealtimeSession.Transport {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "AgentTransport"
    )

    /// Log module for `PhoneAgentClientLog` entries emitted by this
    /// enqueue-to-Watch adapter (ESS-525 §1 requires
    /// `downlink_enqueued` / `play_started` / `play_finished`).
    private static let logModule = "agent_bridge"

    /// Caller-provided sink that pushes decoded downlink envelopes back to
    /// `PhoneConnectivity.forwardRealtimeDownlink`.
    var onDownlink: ((RealtimeDownlinkEnvelope) -> Void)?

    /// Caller-provided sink so `PhoneRealtimeSession` can signal state
    /// changes to its coordinator (used for UI/log evidence).
    var onStateChange: ((PhoneRealtimeSession.State) -> Void)?

    private var agentSession: AudioRealtimeAgentSession
    private let replacementSession: (Int) async throws -> AudioRealtimeAgentSession
    private let requestId: String
    private let sessionId: String

    /// Current turn generation. iPhone owns this counter; Watch requests
    /// advancement via `bargein.request`.
    private var gate: BargeInGenerationCoordinator
    private var cancelTimeout: Task<Void, Never>?
    private var didEmitTransportFailure = false

    /// ESS-1139：这条 socket 上**还有没有上游工作在跑**。
    ///
    /// 它由本适配器已经在消费的 `task.state` 流独占喂养，与 Watch 的
    /// `ToolTurnAggregate` 分工明确：那边管「这一轮该显示什么、能不能开下一轮」
    /// 并随 `startNextTurn` 重置；这边只管「这条 socket 关得掉吗」，回合重置
    /// 动不了它。真机三条用例丢结果的正是这条边——Watch 已经进了下一轮，
    /// 而 iPhone 手上这条 socket 上的 Codex 任务还在跑，却被无条件 `close`。
    private(set) var upstreamWorkLedger = UpstreamWorkLedger()

    /// 判定用时钟。生产用单调时钟，测试可注入。
    var nowMs: () -> Int64 = { RealtimeSocketLifetimePolicy.monotonicNowMs() }

    /// Pending completion for the latest `send` call — the Agent transport
    /// is asynchronous (WSS), so `send` reports completion via this pending
    /// closure on error or next success.
    private var pendingSendCompletion: (@MainActor (Error?) -> Void)?

    init(
        config: AudioRealtimeAgentConfig,
        agentSession: AudioRealtimeAgentSession,
        requestId: String,
        sessionId: String,
        generation: Int = 0,
        replacementSession: @escaping (Int) async throws -> AudioRealtimeAgentSession
    ) {
        self.agentSession = agentSession
        self.requestId = requestId
        self.sessionId = sessionId
        self.gate = BargeInGenerationCoordinator(generation: generation)
        self.replacementSession = replacementSession
        wireAgentSession()
        _ = agentSession.connect(requestId: requestId, generation: generation)
    }

    // MARK: - PhoneRealtimeSession.Transport

    func send(_ envelope: RealtimeUplinkEnvelope, completion: @escaping @MainActor (Error?) -> Void) {
        pendingSendCompletion = completion
        switch envelope.kind {
        case .streamStart:
            // Agent path: stream.start is already sent by `connect()`. If
            // Watch re-sends, it's idempotent — no WSS frame needed.
            Self.logger.debug("agent stream.start (idempotent) rid=\(self.requestId.prefix(8), privacy: .public)")
            completion(nil)

        case .audioAppend:
            guard let append = envelope.append else {
                completion(NSError(domain: "PhoneRealtimeAgentTransport", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "missing audio.append payload"]))
                return
            }
            agentSession.sendAudioChunk(append, requestId: requestId, generation: gate.generation)
            // Agent session handles send completion internally; report ack
            // synchronously to keep the PhoneRealtimeSession contract.
            completion(nil)

        case .audioCommit:
            guard let commit = envelope.commit else {
                completion(NSError(domain: "PhoneRealtimeAgentTransport", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "missing audio.commit payload"]))
                return
            }
            agentSession.commitUplink(requestId: requestId, generation: gate.generation,
                                      finalSequence: commit.sequence)
            completion(nil)

        case .bargeInRequest:
            guard let ask = envelope.bargeIn else {
                completion(NSError(domain: "PhoneRealtimeAgentTransport", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "missing bargein.request payload"]))
                return
            }
            handleBargeInRequest(fromGeneration: ask.fromGeneration)
            completion(nil)

        case .playbackStarted, .playbackEnded:
            // Playback receipts from Watch are forwarded to the Agent
            // Gateway as playback.started/playback.ended uplink frames.
            guard let receipt = envelope.playback else {
                completion(nil)
                return
            }
            if envelope.kind == .playbackStarted {
                agentSession.transport?.send(
                    .playbackStarted(sessionId: sessionId, requestId: requestId,
                                     responseId: receipt.requestId)
                ) { _ in }
                completion(nil)
            } else {
                agentSession.transport?.send(
                    .playbackEnded(sessionId: sessionId, requestId: requestId,
                                   responseId: receipt.requestId)
                ) { _ in }
                completion(nil)
            }

        case .fallback:
            let reason = envelope.fallback?.reason ?? "bridge_fallback"
            agentSession.disconnect(reason: reason)
            onStateChange?(.failed(reason: reason))
            completion(nil)
        }
    }

    func receive(handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void) {
        // The Agent session delivers events via callbacks (onAudioDelta,
        // onAudioDone, etc.) wired in `wireAgentSession()`. The `receive`
        // contract in `PhoneRealtimeSession.Transport` is start-once +
        // continuous delivery — we satisfy it by keeping the Agent session
        // alive and pushing events through `onDownlink`.
        //
        // No additional receive-loop setup is needed; the callback wiring
        // is idempotent per `wireAgentSession`.
    }

    func close(reason: String) {
        cancelTimeout?.cancel()
        // ESS-1139 验收 6：**每一次**客户端主动关闭都必须在 bridge.log 里带上
        // 原因与当时的上游账本。事故复盘卡在「客户端关闭了 WSS」而说不出为什么，
        // 就是因为这里以前只写 `os.Logger`——真机导出的 bridge.log 里根本没有
        // 这条边。
        PhoneAgentClientLog.info(
            module: Self.logModule, event: "agent_socket_close",
            requestId: requestId, sessionId: sessionId,
            detail: "reason=\(reason) gen=\(gate.generation) \(upstreamWorkLedger.logDetail)"
        )
        agentSession.disconnect(reason: reason)
    }

    // MARK: - Generation owner

    private func handleBargeInRequest(fromGeneration: Int) {
        Self.logger.info(
            "agent bargein.request from_gen=\(fromGeneration, privacy: .public) current=\(self.gate.generation, privacy: .public)"
        )
        guard case .cancel(let old) = gate.request(from: fromGeneration) else { return }
        agentSession.cancel(requestId: requestId, generation: old, reason: "barge-in") { [weak self] in
            self?.failReplacement("cancel_failed")
        }
        cancelTimeout?.cancel()
        cancelTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.settleCancel(old)
        }
    }

    private func settleCancel(_ old: Int) {
        guard case .mintAndConnect(let next) = gate.cancelSettled(generation: old) else { return }
        cancelTimeout?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await replacementSession(next)
                agentSession.disconnect(reason: "generation_replaced")
                agentSession = fresh
                wireAgentSession()
                guard fresh.connect(requestId: requestId, generation: next) else {
                    failReplacement("wss_upgrade_failed")
                    return
                }
            } catch {
                failReplacement("token_mint_failed")
            }
        }
    }

    private func failReplacement(_ reason: String) {
        guard case .fallback = gate.fail(reason) else { return }
        agentSession.disconnect(reason: reason)
        onDownlink?(.bargeInFailed(
            requestId: requestId, sessionId: sessionId,
            fromGeneration: gate.generation, reason: reason
        ))
        onStateChange?(.failed(reason: reason))
    }

    // MARK: - Agent session wiring

    private func wireAgentSession() {
        agentSession.onAudioDelta = { [weak self] chunk, responseId, gen in
            guard let self else { return }
            guard self.gate.shouldForwardDownlink(generation: gen) else {
                PhoneAgentClientLog.info(
                    module: Self.logModule,
                    event: "downlink_audio_delta_stale_generation",
                    requestId: self.requestId, sessionId: self.sessionId,
                    detail: "seq=\(chunk.sequence) frame_gen=\(gen) current_gen=\(self.gate.generation)"
                )
                return
            }
            let envelope = RealtimeDownlinkEnvelope.audioDelta(
                chunk, responseId: responseId, generation: gen
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_enqueued",
                requestId: self.requestId, sessionId: self.sessionId,
                detail: "type=audio.delta seq=\(chunk.sequence) bytes=\(chunk.payload.count) gen=\(gen)"
            )
            self.onDownlink?(envelope)
        }
        agentSession.onAudioDone = { [weak self] rid, responseId, gen, finalSeq in
            guard let self else { return }
            guard self.gate.shouldForwardDownlink(generation: gen) else {
                PhoneAgentClientLog.info(
                    module: Self.logModule,
                    event: "downlink_audio_done_stale_generation",
                    requestId: rid, sessionId: self.sessionId,
                    detail: "final_seq=\(finalSeq) frame_gen=\(gen) current_gen=\(self.gate.generation)"
                )
                return
            }
            // ESS-1139：**判据搬到顺序有保证的这一侧**。网关在有序 WSS 上先发
            // `tool_call_pending` / `task.state`、后发 `audio.done`，但 WCSession
            // 那一跳不保证跨消息顺序（见 `RealtimeDownlinkEnvelope
            // .progressSequence` 的注释与 `RealtimePlaybackReceiptTracker
            // .requestDrain` 里的同一条事实）。Watch 因此可能在还没拿到任何
            // 工具证据的那一瞬间，把阶段播报的这条终态当成回合答完。
            // 这里就地把账本的结论钉在帧上，Watch 不必再赌两条消息的到达顺序。
            // 回合级 `audio.done` **只记事实，不清账**：真机天气用例里它是阶段
            // 播报的收口，而 Codex 任务此后还要跑 10s；拿它去宣布任务结束正是
            // 那次 1.2s 关闭的授权来源。记账放在代际门禁**之后**——被判陈旧的
            // 那一帧属于上一代，不该改写本代账本。
            self.upstreamWorkLedger.noteTurnTerminal(atMs: self.nowMs())
            let workOutstanding = self.upstreamWorkLedger.hasOutstandingWork
            let envelope = RealtimeDownlinkEnvelope.audioDone(
                requestId: rid, sessionId: self.sessionId,
                responseId: responseId,
                generation: gen,
                finalSequence: finalSeq,
                upstreamWorkOutstanding: workOutstanding
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_enqueued",
                requestId: rid, sessionId: self.sessionId,
                detail: "type=audio.done final_seq=\(finalSeq) gen=\(gen) "
                    + "upstream_work_outstanding=\(workOutstanding) "
                    + self.upstreamWorkLedger.logDetail
            )
            self.onDownlink?(envelope)
        }
        // ESS-971：段落屏障。与 `onAudioDone` 共用同一套 generation 门禁，
        // 但**不**触发任何回合终态——它只是「这一段完了」。
        agentSession.onAudioSegmentDone = { [weak self] rid, responseId, gen, segIdx, finalSeq in
            guard let self else { return }
            guard self.gate.shouldForwardDownlink(generation: gen) else {
                PhoneAgentClientLog.info(
                    module: Self.logModule,
                    event: "downlink_audio_segment_done_stale_generation",
                    requestId: rid, sessionId: self.sessionId,
                    detail: "segment_index=\(segIdx) final_seq=\(finalSeq) frame_gen=\(gen) current_gen=\(self.gate.generation)"
                )
                return
            }
            let envelope = RealtimeDownlinkEnvelope.audioSegmentDone(
                requestId: rid, sessionId: self.sessionId,
                responseId: responseId, generation: gen,
                segmentIndex: segIdx, finalSequence: finalSeq
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_enqueued",
                requestId: rid, sessionId: self.sessionId,
                detail: "type=audio.segment_done segment_index=\(segIdx) final_seq=\(finalSeq) gen=\(gen)"
            )
            self.onDownlink?(envelope)
        }
        // ESS-1097：任务生命周期。**刻意不过 generation 门禁**——一个仍在跑的
        // 工具任务恰恰是「不许换代」的理由，用换代后的门禁把它滤掉，等于让
        // Watch 永远看不到那个把它拦在思考态的信号。陈旧性由 Watch 侧的
        // request_id 归属闸门（`SessionController.acceptsTurnEvent`）承担。
        agentSession.onTaskState = { [weak self] rid, gen, taskId, status, progress, answer in
            guard let self else { return }
            // ESS-1139：先记账、后转发。账本是本条 socket 能不能被关掉的唯一
            // 依据，它必须在任何转发失败/丢弃之前就落定——否则 Watch 那一侧
            // 一旦漏收，iPhone 也跟着以为「上游没活了」，两层同时失明。
            self.upstreamWorkLedger.noteTaskState(
                taskId: taskId, status: status, atMs: self.nowMs()
            )
            let envelope = RealtimeDownlinkEnvelope.taskState(
                requestId: rid, sessionId: self.sessionId,
                generation: gen, taskId: taskId, status: status,
                progress: progress, answer: answer
            )
            // ESS-1100：进展文本本身**不落日志**——它是上游自由文本，可能带
            // 用户内容（计划 detail / 授权 summary）。只记序号与类目，真机复盘
            // 靠它们把「UI 显示的第几条」与网关的 `downlink_task_state` 对上。
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_enqueued",
                requestId: rid, sessionId: self.sessionId,
                detail: "type=task.state task_id=\(taskId ?? "nil") status=\(status) gen=\(gen) "
                    + "progress_seq=\(progress?.sequence?.description ?? "nil") "
                    + "progress_category=\(progress?.category ?? "nil") "
                    // ESS-1111：答案增量同理只记序号与长度，不落原文。
                    + "answer_seq=\(answer?.sequence?.description ?? "nil") "
                    + "answer_len=\(answer?.delta.count ?? 0)"
            )
            self.onDownlink?(envelope)
        }
        agentSession.onError = { [weak self] code, rid, gen, retriable, detail in
            guard let self else { return }
            Self.logger.error(
                "agent gateway error code=\(code, privacy: .public) rid=\(rid.prefix(8), privacy: .public) gen=\(gen) retriable=\(retriable)"
            )
            if !retriable {
                // ESS-1139：不可重试的网关错误 = 这条 socket 上不会再有上游
                // 事实。如实清账，否则一个永远关不掉的 socket 会把 supersede
                // 一路顶到 180s 绝对上限。
                self.upstreamWorkLedger.noteUpstreamSettled(atMs: self.nowMs())
                self.onStateChange?(.failed(reason: "gateway_error_\(code)"))
            }
        }
        agentSession.onCancelAck = { [weak self] rid, gen, cancelledRespId in
            guard let self else { return }
            Self.logger.info(
                "agent cancel.ack rid=\(rid.prefix(8), privacy: .public) gen=\(gen) cancelled=\(cancelledRespId.prefix(8), privacy: .public)"
            )
            self.settleCancel(gen)
        }
        agentSession.onConnectionStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected(let sid, let rid, let gen):
                Self.logger.info(
                    "agent connected sid=\(sid.prefix(8), privacy: .public) rid=\(rid.prefix(8), privacy: .public) gen=\(gen)"
                )
                self.onStateChange?(.active(requestId: rid, sessionId: sid))
                if case .open(let opened) = self.gate.ready(generation: gen) {
                    self.onDownlink?(.generationOpen(requestId: rid, sessionId: sid, generation: opened))
                    Self.logger.info("agent generation.open rid=\(rid.prefix(8), privacy: .public) sid=\(sid.prefix(8), privacy: .public) gen=\(opened)")
                }
            case .failed(let sid, let reason):
                Self.logger.error(
                    "agent failed sid=\(sid.prefix(8), privacy: .public) reason=\(reason, privacy: .public)"
                )
                // ESS-1139：socket 真的没了 ⇒ 账本清零。保住一条已死的 socket
                // 不叫防御，叫拦住下一轮。
                self.upstreamWorkLedger.noteUpstreamSettled(atMs: self.nowMs())
                if !self.didEmitTransportFailure {
                    self.didEmitTransportFailure = true
                    PhoneAgentClientLog.error(
                        module: Self.logModule,
                        event: "transport_failure_enqueued",
                        requestId: self.requestId, sessionId: self.sessionId,
                        detail: "reason=\(reason) gen=\(self.gate.generation)",
                        code: "ERR_REALTIME_TRANSPORT_FAILED"
                    )
                    self.onDownlink?(.transportFailed(
                        requestId: self.requestId,
                        sessionId: self.sessionId,
                        generation: self.gate.generation,
                        reason: reason
                    ))
                }
                self.onStateChange?(.failed(reason: reason))
            case .connecting:
                self.onStateChange?(.connecting(requestId: self.requestId, sessionId: self.sessionId))
            default:
                break
            }
        }
    }
}
