import Foundation
import os

/// ESS-321 iPhone WSS session that carries the realtime media loop between
/// the watch (via WatchConnectivity) and the bridge (via WSS).
///
/// Responsibilities:
///
///  * open one WSS connection per request/session id and keep it hot while
///    the turn is alive;
///  * translate the Watch's `RealtimeUplinkEnvelope` into WSS text messages
///    the bridge expects (`stream.start`, `audio.append`, `audio.commit`)
///    and forward them frame-by-frame — no aggregation, no re-ordering;
///  * decode the bridge's downlink events into a `RealtimeDownlinkEnvelope`
///    and hand it back to `PhoneConnectivity` which forwards to the watch;
///  * expose a deterministic disconnect / cancel / lifecycle-switch API so
///    the caller can guarantee "no double execution, no stale playback".
///
/// The wire transport is injected via `Transport` so unit tests can
/// substitute an in-memory pipe; production wraps `URLSessionWebSocketTask`.
@MainActor
final class PhoneRealtimeSession {
    protocol Transport: AnyObject {
        func send(_ envelope: RealtimeUplinkEnvelope, completion: @escaping @MainActor (Error?) -> Void)
        func receive(handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void)
        func close(reason: String)
        /// ESS-1139：这条 socket 上还有没有上游工作在跑。Agent transport 由它
        /// 消费的 `task.state` 流独占喂养；Bridge transport 与测试替身走默认
        /// 实现（空账本 = 没有在飞工作），行为与本单之前逐字相同。
        var upstreamWorkLedger: UpstreamWorkLedger { get }
    }

    enum State: Equatable {
        case idle
        case connecting(requestId: String, sessionId: String)
        case active(requestId: String, sessionId: String)
        case cancelled
        case failed(reason: String)
    }

    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "RealtimeSession"
    )

    /// Bridge PR #113 `server.mjs` requires the WSS handshake to carry
    /// `?request_id=` and `?session_id=` in the URL query AND the request-id
    /// used for HMAC signing to match `request_id` — otherwise the socket
    /// closes with `ERR_STREAM_OWNERSHIP`. The factory therefore takes the
    /// (requestId, sessionId) tuple for the turn it will serve.
    private let transportFactory: (_ requestId: String, _ sessionId: String) -> Transport?
    private var currentTransport: Transport?
    private(set) var state: State = .idle
    /// ESS-751：下行主链路（转发 / 断连缓冲 / 重连重放）收在
    /// `Shared/RealtimeDownlinkRelay.swift`，因为 `iOS/` 没有单测 target——
    /// 留在这里这条链路就只能靠人眼复核，正是它两次写错还合入的原因。
    private var pendingDownlink = RealtimeDownlinkRelay()
    /// ESS-960：已判终态的回合闸门。判定逻辑与用例在
    /// `Shared/RealtimeTurnGate` + `Tests/RealtimeTurnGateTests`。
    private var turnGate = RealtimeTurnGate()
    /// ESS-391: Agent transports deliver events via callbacks rather than
    /// the Bridge-style `receive(handler:)` loop. When `true`, `scheduleReceive`
    /// is a no-op — the transport itself wires downlink delivery.
    var isAgentTransport: Bool = false

    /// Emits every decoded downlink envelope. `PhoneConnectivity` bridges this
    /// back to the watch via `WatchDownlinkOutbox` and reports whether that
    /// durable queue actually took ownership —— ESS-751：只有它没接住的才留副本。
    var onDownlink: ((RealtimeDownlinkEnvelope) -> RealtimeDownlinkDisposition)?
    /// Emits state transitions so callers can flip UI or log evidence.
    var onStateChange: ((State) -> Void)?

    /// ESS-1139 判定用时钟。生产用单调时钟。
    var nowMs: () -> Int64 = { RealtimeSocketLifetimePolicy.monotonicNowMs() }

    /// ESS-1139 日志收敛：一次被拦下的 supersede 会被**每一个上行帧**重问一遍
    /// （`forward(_:)` 的 `.audioAppend` 分支，真机节奏 ≈184ms）。逐帧打 error
    /// 就是 ESS-960 那场 47 秒刷屏的翻版。首条如实打 error，其余只累计，解除
    /// 时补一条汇总——「拦了多久、拦了多少帧」仍然可直接 grep。
    private var blockedCloseReason: String?
    private var blockedCloseCount = 0

    /// ESS-1139 复审整改（毕玄 2026-09-05 阻断）：**被推迟的那次关闭**。
    ///
    /// 「保住 socket」只有在会话层同时保住 transport 引用、会话状态与下行缓冲
    /// 时才成立。少了这条记录，一次 hold 就变成「物理没关、逻辑失管」——
    /// 比直接关掉更糟：socket 还占着，回调却全被身份闸门拒掉。
    ///
    /// 记下来还有第二个作用：**有界性需要一个重试点**。`RealtimeSocketLifetime
    /// Policy` 的静默预算与绝对上限只有在被再次问到时才会生效，而背景态下
    /// 不会再有第二次 `lifecycleInterrupted`。
    private var deferredClose: (cause: RealtimeSocketCloseCause, reason: String)?
    private var deferredCloseRetryArmed = false

    /// 被推迟的关闭多久重问一次策略。取上游静默预算：到点时若上游确实静默，
    /// 策略会当场放行；若还在持续下发，策略继续 hold 并重新武装，最终由
    /// `absoluteHoldCapMs` 兜底。因此重试次数有界，socket 不会永久泄漏。
    static let deferredCloseRetrySeconds: TimeInterval =
        TimeInterval(RealtimeSocketLifetimePolicy.upstreamSilenceBudgetMs) / 1000

    /// 重试计时器接缝。生产用 `Task.sleep`；测试注入以零睡眠驱动。
    var scheduleDeferredCloseRetry: (TimeInterval, @escaping @MainActor () -> Void) -> Void = {
        seconds, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            fire()
        }
    }

    // MARK: - ESS-1159 播放排空屏障（复审阻断 1）

    /// 已经开始、还没播完的 `response_id`。
    ///
    /// 由 Watch 的 `playback.started` / `playback.ended` 回执独占喂养。它回答
    /// 收口三条件里的第三条：**播放队列排空了吗**。放在会话层是因为回执正是
    /// 在这里落地（`forward` 的 `.playbackStarted/.playbackEnded` 分支）。
    private(set) var playbackInFlight: Set<String> = []

    /// 回合终态（`audio.done`）已经到过。屏障的第二条件。
    private var sawTurnTerminalForDeferredClose = false

    /// 排空屏障的兜底计时器是否已武装。与 `deferredCloseRetryArmed` 一样，
    /// **任何时刻至多一支**——否则每一帧回执都会再武装一支，旧的仍会到点。
    private var playbackDrainCapArmed = false

    /// 首帧渲染回执的宽限：`audio.done` 到达时若还没有任何 `playback.started`，
    /// 给 WCSession 那一跳一点时间把回执送上来，再决定收口。
    ///
    /// 取 2s，与 Watch 侧 `WatchRealtimeMediaAdapter.doneBarrierTimeoutSeconds`
    /// 同值——它量的是同一件事：一帧本该已经在路上的消息还要多久才算不来了。
    /// 不取更大值：没有音频的回合（纯错误终态）不该为一个不会到来的回执白等。
    static let deferredClosePlaybackReceiptGraceSeconds: TimeInterval = 2.0

    /// 播放真的在跑时的排空上限。
    ///
    /// 直接复用 `RealtimeSocketLifetimePolicy.absoluteHoldCapMs`（180s，与
    /// `SessionController.toolTurnHardTimeoutSeconds` 同源），**不新造第二个
    /// 数字**：这条 socket 无论因为什么原因被保住，天花板都是同一个。
    static let deferredClosePlaybackDrainCapSeconds: TimeInterval =
        TimeInterval(RealtimeSocketLifetimePolicy.absoluteHoldCapMs) / 1000

    /// 排空屏障计时器接缝。生产用 `Task.sleep`；测试注入以零睡眠驱动。
    var schedulePlaybackDrainCap: (TimeInterval, @escaping @MainActor () -> Void) -> Void = {
        seconds, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            fire()
        }
    }

    /// ESS-1159：`stream.fallback` 的动因映射。
    ///
    /// 归类**只看帧上的结构化字段**，不解析 `reason` 字符串。字段缺席（老 Watch
    /// 进程）时按可抢占处理，即本单之前的行为——理由见
    /// `RealtimeUplinkFallbackDescriptor.kind` 的注释。
    static func closeCause(
        for descriptor: RealtimeUplinkFallbackDescriptor
    ) -> RealtimeSocketCloseCause {
        switch descriptor.kind {
        case .uplinkFailure: return .uplinkFallback
        case .userCancelled, nil: return .userExit
        }
    }

    /// 一次播放回执落地。
    private func notePlaybackReceipt(kind: RealtimeUplinkKind, responseId: String) {
        switch kind {
        case .playbackStarted:
            playbackInFlight.insert(responseId)
        case .playbackEnded:
            playbackInFlight.remove(responseId)
            // 排空的那一刻就是屏障第三条件成立的那一刻——立刻重问，而不是
            // 干等一个计时器周期。前两条件不成立时 `retryDeferredClose`
            // 自己会再挡回去。
            if deferredClose != nil, sawTurnTerminalForDeferredClose, playbackInFlight.isEmpty {
                retryDeferredClose(trigger: "playback_drained")
            }
        default:
            break
        }
    }

    /// 这次重试要不要被排空屏障挡下。`nil` = 放行。
    ///
    /// 只挡**回合终态**触发的那一次快路径；两支兜底计时器
    /// （`playback_receipt_grace` / `playback_drain_cap`）和上游静默重试
    /// （`retry_timer`）一律放行，否则「保住 socket」会变成永久泄漏。
    private func playbackDrainGate(
        trigger: String
    ) -> (reason: String, phase: String, capSeconds: TimeInterval)? {
        switch trigger {
        case "audio_done":
            // 终态刚到。播放已经在跑 ⇒ 等排空；还没跑 ⇒ 给首帧回执一点宽限。
            guard sawTurnTerminalForDeferredClose else { return nil }
            if !playbackInFlight.isEmpty {
                return ("playback_in_flight", "playback_drain_cap",
                        Self.deferredClosePlaybackDrainCapSeconds)
            }
            return ("awaiting_first_receipt", "playback_receipt_grace",
                    Self.deferredClosePlaybackReceiptGraceSeconds)
        case "playback_receipt_grace":
            // 宽限到点。这段时间里播放**真的**开始了就升级成排空上限继续等；
            // 一帧回执都没来，就认账「这一轮没有音频要放」，照常收口。
            guard !playbackInFlight.isEmpty else { return nil }
            return ("playback_in_flight", "playback_drain_cap",
                    Self.deferredClosePlaybackDrainCapSeconds)
        default:
            // `playback_drained` / `playback_drain_cap` / `retry_timer` 一律放行。
            // 少了这一条，「保住 socket」就会变成永久泄漏。
            return nil
        }
    }

    private func armPlaybackDrainCap(seconds: TimeInterval, phase: String) {
        guard !playbackDrainCapArmed else { return }
        playbackDrainCapArmed = true
        schedulePlaybackDrainCap(seconds) { [weak self] in
            guard let self else { return }
            // 与 `deferredCloseRetryArmed` 同一条纪律：标志只由计时器回调复位，
            // 这样任何时刻至多一支在跑，宽限→排空上限的升级也才武装得进来。
            self.playbackDrainCapArmed = false
            guard self.deferredClose != nil else { return }
            PhoneAgentClientLog.info(
                module: "phone_session", event: "realtime_playback_drain_timer_fired",
                requestId: Self.turnIdentity(of: self.state)?.requestId ?? "",
                sessionId: Self.turnIdentity(of: self.state)?.sessionId ?? "",
                detail: "phase=\(phase) playback_in_flight=\(self.playbackInFlight.count)"
            )
            self.retryDeferredClose(trigger: phase)
        }
    }

    private func cancelPlaybackDrainGate() {
        sawTurnTerminalForDeferredClose = false
        playbackInFlight.removeAll(keepingCapacity: false)
    }

    init(transportFactory: @escaping (_ requestId: String, _ sessionId: String) -> Transport?) {
        self.transportFactory = transportFactory
    }

    /// ESS-1139：**唯一的关闭出口**。
    ///
    /// 这条 socket 关不关，由 `RealtimeSocketLifetimePolicy` 按「动因 + 上游
    /// 工作账本」裁决；本方法只负责把裁决落到 transport 上并如实留证。
    /// 散在各处的 `currentTransport?.close(reason:)` 全部收敛到这里——真机
    /// 事故里杀掉三个回合的正是其中一条没有任何任务感知的调用。
    ///
    /// - Returns: 这次是否真的关闭了。`false` = 上游还有活在跑，socket 保住了。
    @discardableResult
    private func closeCurrentTransport(
        cause: RealtimeSocketCloseCause, reason: String
    ) -> Bool {
        let identity = Self.turnIdentity(of: state)
        guard let transport = currentTransport else {
            deferredClose = nil
            flushBlockedCloseSummary(identity)
            return true
        }
        let decision = RealtimeSocketLifetimePolicy.decide(
            cause: cause, ledger: transport.upstreamWorkLedger, nowMs: nowMs()
        )
        switch decision {
        case .close(let detail):
            deferredClose = nil
            flushBlockedCloseSummary(identity)
            PhoneAgentClientLog.info(
                module: "phone_session", event: "realtime_socket_close",
                requestId: identity?.requestId ?? "", sessionId: identity?.sessionId ?? "",
                detail: "reason=\(reason) \(detail)"
            )
            transport.close(reason: reason)
            return true
        case .hold(let detail):
            // 上游还在干活：不关、不换 transport、不丢 socket。这条日志就是
            // 「客户端为什么没有关」的直接证据，与网关的 `socket_closed`
            // 一一对照。
            deferredClose = (cause, reason)
            armDeferredCloseRetry()
            blockedCloseCount += 1
            if blockedCloseReason == nil {
                blockedCloseReason = reason
                PhoneAgentClientLog.error(
                    module: "phone_session", event: "realtime_socket_close_blocked",
                    requestId: identity?.requestId ?? "", sessionId: identity?.sessionId ?? "",
                    detail: "reason=\(reason) \(detail)",
                    code: "ERR_REALTIME_CLOSE_BLOCKED_TASK_IN_FLIGHT"
                )
            }
            return false
        }
    }

    /// ESS-1139：一次拦截结束时补一条汇总，然后归零。
    private func flushBlockedCloseSummary(_ identity: (requestId: String, sessionId: String)?) {
        guard let blocked = blockedCloseReason else { return }
        PhoneAgentClientLog.info(
            module: "phone_session", event: "realtime_socket_close_blocked_summary",
            requestId: identity?.requestId ?? "", sessionId: identity?.sessionId ?? "",
            detail: "reason=\(blocked) blocked_attempts=\(blockedCloseCount)"
        )
        blockedCloseReason = nil
        blockedCloseCount = 0
    }

    /// Forward a Watch-side envelope. Opens the WSS session lazily on
    /// `stream.start` and tears it down on `audio.commit` completion or on
    /// the coordinator's fallback signal.
    func forward(
        _ envelope: RealtimeUplinkEnvelope,
        completion: ((Bool) -> Void)? = nil
    ) {
        switch envelope.kind {
        case .streamStart:
            guard let start = envelope.start else { return }
            // ESS-539 的陈旧缓冲清理**不在这里**了。
            //
            // ESS-1139 第二轮复审阻断（毕玄 2026-09-05）：它原先无条件跑在
            // `openIfNeeded` **之前**。旧 transport 还挂着在飞任务、
            // WCSession 暂时接不住、缓冲里正压着待重放的答案时，新 request 的
            // `stream.start` 会先把那批帧清掉；随后 supersede 被任务感知策略
            // 正确地判成 hold，socket 与 state 都保住了，**可答案缓冲已经没了**。
            // 保住一条空转的 socket 不叫保住答案。
            //
            // 现在清理跟着「新一轮真的建起来了」这个事实走，落在 `openIfNeeded`
            // 里换完 transport 之后。判据见那里的注释。
            guard openIfNeeded(
                requestId: start.requestId, sessionId: start.sessionId, trigger: .turnStart
            ) else {
                completion?(false)
                return
            }
        case .audioAppend:
            guard let append = envelope.append else { return }
            guard openIfNeeded(
                requestId: append.requestId, sessionId: append.streamId, trigger: .uplinkFrame
            ) else {
                completion?(false)
                return
            }
        case .audioCommit:
            guard let commit = envelope.commit else { return }
            guard openIfNeeded(
                requestId: commit.requestId, sessionId: commit.sessionId, trigger: .turnCommit
            ) else {
                completion?(false)
                return
            }
        case .playbackStarted, .playbackEnded:
            guard let receipt = envelope.playback else { return }
            // ESS-525 §1 acceptance: `play_started` / `play_finished`
            // must land in `bridge.log` for the same request_id as the
            // Gateway downlink. Watch reports the receipt via WCSession
            // uplink; that arrives here — log before we hand it off.
            PhoneAgentClientLog.info(
                module: "phone_session",
                event: envelope.kind == .playbackStarted ? "play_started" : "play_finished",
                requestId: receipt.requestId, sessionId: receipt.sessionId,
                detail: "response_id=\(receipt.responseId)"
            )
            guard openIfNeeded(
                requestId: receipt.requestId, sessionId: receipt.sessionId, trigger: .receipt
            ) else {
                completion?(false)
                return
            }
            // ESS-1159 复审整改（毕玄阻断 1）：播放回执参与收口屏障。
            // 整改前这两个回执只被转发和记日志，`retryDeferredClose` 在
            // `audio.done` 那一刻就关掉了 WSS——「播放队列完成后才收口」这条
            // 门禁根本没有实现点。
            notePlaybackReceipt(kind: envelope.kind, responseId: receipt.responseId)
        case .fallback:
            guard let descriptor = envelope.fallback else { return }
            // ESS-1159：Watch 的快速上行通道死了 **≠** 这条 WSS 死了。
            //
            // 整改前这里写死 `cause: .transportFailure`——那是「传输真死」的
            // 动因，`overridesInFlightUpstreamWork == true`，于是无论账本上
            // 挂着多少未结任务，一条 `stream.fallback` 都当场把 socket 关掉。
            // 而 `stream.fallback` 的全部来源都在 Watch 自己那一侧
            // （`RealtimeUplinkStream.FallbackReason`：录音器故障、WCSession
            // 送不出去、没采到音频、上行背压、本轮取消），说的是
            // **Watch↔iPhone** 那一跳；此刻 iPhone 手上这条 WSS 仍在收
            // `task.state`，上游的 Codex 任务照跑不误。关掉它 = 网关对上游
            // `mute` + `terminate`，最终答案随即被判 `socket_closed` 丢弃。
            //
            // 现在它走 `.uplinkFallback`，与 supersede / UI 状态 / 本地超时
            // 同档：由账本裁决，并且**收口是原子的**——只有真的关掉了才动
            // 会话状态与 transport 引用（同 `endTurn` 的整改口径）。
            // hold 时那次关闭记进 `deferredClose`，由重试计时器与后续下行
            // 共同兑现，最终由静默预算 / 绝对上限收口。
            //
            // 上行语义一个字未改：完整文件回退走的是另一条链路
            // （`fullFileFallback`），与这条 socket 的存亡无关，因此无论
            // 裁决如何都照常回 `true`。
            //
            // ESS-1159 复审整改（毕玄阻断 2）：**动因由帧上的结构化归类决定，
            // 不是所有 `stream.fallback` 都 hold**。
            //
            // `RealtimeUplinkStream.FallbackReason.cancelled` 的文档口径是
            // 「user cancel / new turn / lifecycle switch」——那是用户意图，
            // 必须当场收口；把它一并 hold 到终态 / 30s 静默 / 180s 上限，
            // 等于用「保住答案」去劫持用户，正是本单要求 2 禁止的形状。
            // 归类走 `RealtimeUplinkFallbackKind`（Watch 侧由
            // `FallbackReason.wireKind` 产出），不解析 reason 字符串。
            let cause = Self.closeCause(for: descriptor)
            guard closeCurrentTransport(cause: cause, reason: descriptor.reason) else {
                PhoneAgentClientLog.info(
                    module: "phone_session", event: "realtime_uplink_fallback_deferred",
                    requestId: descriptor.requestId, sessionId: descriptor.sessionId,
                    detail: "reason=\(descriptor.reason) cause=\(cause.rawValue) "
                        + "kind=\(descriptor.kind?.rawValue ?? "absent") "
                        + "retained=transport|state|pending_downlink "
                        + "pending=\(pendingDownlink.pendingCount)"
                )
                completion?(true)
                return
            }
            transition(to: .failed(reason: descriptor.reason))
            currentTransport = nil
            completion?(true)
            return
        case .bargeInRequest:
            // ESS-391: forward barge-in to transport. For Bridge transports
            // this is a no-op (Bridge doesn't understand generation); for
            // Agent transports this triggers generation advance → cancel →
            // generation.open downlink.
            guard let ask = envelope.bargeIn else { return }
            Self.logger.info(
                "realtime bargein.request request=\(ask.requestId, privacy: .public) from_gen=\(ask.fromGeneration, privacy: .public)"
            )
            guard let transport = currentTransport else {
                completion?(false)
                return
            }
            transport.send(envelope) { [weak self] error in
                if let error {
                    Self.logger.error(
                        "bargein.request send failed: \(String(describing: error), privacy: .public)"
                    )
                }
                completion?(error == nil)
            }
            return
        }
        guard let transport = currentTransport else {
            completion?(false)
            return
        }
        transport.send(envelope) { [weak self] error in
            if let error {
                Self.logger.error(
                    "realtime uplink send failed error=\(String(describing: error), privacy: .public)"
                )
                self?.transition(to: .failed(reason: "send_failed"))
                self?.closeCurrentTransport(cause: .transportFailure, reason: "send_failed")
                self?.currentTransport = nil
            }
            completion?(error == nil)
        }
        if envelope.kind == .audioCommit {
            // Commit is the last uplink frame; the bridge will finish playback
            // via `audio.done` and then close the socket.
        }
    }

    /// Watch reported the turn is over (audio.done acknowledged and playback
    /// finished) — or the user cancelled. Either way, tear down the WSS.
    ///
    /// ESS-1139：`cause` 不再由本方法猜。用户显式退出与生命周期打断的语义
    /// 完全不同——前者压过在飞任务，后者不得压过——把两者塞进同一个字符串
    /// reason 里再现场解析，正是判定会随措辞漂移的来源。
    ///
    /// ESS-1139 复审整改（毕玄 2026-09-05 阻断）：**收口是原子的**。
    ///
    /// 整改前这里先 `transition(to: .cancelled)`、再问策略、然后**无条件**
    /// 清 `currentTransport` 与 `pendingDownlink`。于是 hold 只保住了物理
    /// socket，会话层却已经把它丢了：
    ///   • `receiveAgentDownlink` 的 `currentTransport === transport` 不成立
    ///     → 迟到的 `task.state` / `audio.done` 全被判 `superseded_transport`；
    ///   • `state` 已是 `.cancelled` → 身份闸门第二道也拒；
    ///   • `pendingDownlink.discardAll()` 把已缓冲的下行一并丢掉。
    /// 结果比直接关掉更糟——socket 还占着，答案却一样送不到。
    ///
    /// 现在顺序反过来：**先问策略，只有真的关掉了才动会话状态与缓冲**。
    /// hold 时 transport 引用、`state`、`pendingDownlink` 三者原样保留，
    /// 下行能力完整；关闭动作记进 `deferredClose`，由 `armDeferredCloseRetry`
    /// 与每一帧下行共同承担重试，最终由策略的静默预算 / 绝对上限收口。
    ///
    /// - Returns: 是否真的收口了。`false` = 上游还有活在跑，会话原样保留。
    @discardableResult
    func endTurn(reason: String, cause: RealtimeSocketCloseCause = .userExit) -> Bool {
        guard closeCurrentTransport(cause: cause, reason: reason) else {
            PhoneAgentClientLog.info(
                module: "phone_session", event: "realtime_end_turn_deferred",
                requestId: Self.turnIdentity(of: state)?.requestId ?? "",
                sessionId: Self.turnIdentity(of: state)?.sessionId ?? "",
                detail: "reason=\(reason) cause=\(cause.rawValue) "
                    + "retained=transport|state|pending_downlink "
                    + "pending=\(pendingDownlink.pendingCount)"
            )
            return false
        }
        transition(to: .cancelled)
        currentTransport = nil
        // ESS-1159：这一轮真的收了，播放屏障的两条件随本轮一起作废。
        cancelPlaybackDrainGate()
        // ESS-1139 第三轮复审整改（毕玄 2026-09-05）：**收口不清缓冲**。
        //
        // 这里原先无条件 `pendingDownlink.discardAll()`，是一次确定性的数据丢失：
        // consumer（WCSession）全程不可达时，最终 `task.state completed` /
        // answer / `audio.done` 会**依次进缓冲**；而 `audio.done` 正是触发
        // `retryDeferredClose` 的那一帧——账本此刻已无未结任务，关闭获准，
        // 紧接着这一行就把刚刚存进去的最终答案全部抹掉。等的就是那三帧，
        // 收口的动作却顺手删了它们。
        //
        // 现在全文件只保留**一条**作废规则，与 `openIfNeeded` 里那条同源：
        // **只有新一轮真的建起来，上一轮的缓冲才作废**。收口只是「这条 socket
        // 不再收新帧」，与「已经收到、还没送出去的帧还算不算数」是两件事。
        //
        // 不会泄漏：`RealtimeDownlinkRelay` 自带三条上限（条数 / 512KB /
        // 30s 时长），过期与超量由它自己收口；真开了新一轮时 `openIfNeeded`
        // 会清。
        PhoneAgentClientLog.info(
            module: "phone_session", event: "realtime_end_turn_closed",
            requestId: Self.turnIdentity(of: state)?.requestId ?? "",
            sessionId: Self.turnIdentity(of: state)?.sessionId ?? "",
            detail: "reason=\(reason) cause=\(cause.rawValue) "
                + "retained_pending_downlink=\(pendingDownlink.pendingCount)"
        )
        // ESS-987：回合边界是压制日志的收口点——把这一轮攒下的计数打成一条
        // 汇总，而不是逐帧刷屏。
        emit(turnGate.flushSuppressionSummaries())
        return true
    }

    /// ESS-1139：被推迟的关闭到点重问一次策略。
    ///
    /// 只武装一支计时器：策略仍判 hold 时由 `retryDeferredClose` 重新武装，
    /// 因此任何时刻至多一支在跑。有界性来自策略本身——上游静默满预算、或
    /// 从第一次出现未结任务起满绝对上限，`decide` 就会放行。
    private func armDeferredCloseRetry() {
        guard !deferredCloseRetryArmed else { return }
        deferredCloseRetryArmed = true
        scheduleDeferredCloseRetry(Self.deferredCloseRetrySeconds) { [weak self] in
            guard let self else { return }
            // armed 标志**只由计时器回调复位**。若让下行触发的重试也复位它，
            // 每一帧下行都会再武装一支新计时器（真机节奏下就是一秒好几支），
            // 旧的那些仍会到点触发——一个本该单支的计时器变成 Task 泄漏。
            self.deferredCloseRetryArmed = false
            self.retryDeferredClose(trigger: "retry_timer")
        }
    }

    /// ESS-1139：重试那次被推迟的关闭。
    ///
    /// 两个触发点，缺一不可：
    /// - `armDeferredCloseRetry` 的计时器 —— 覆盖「上游从此静默」，没有它
    ///   背景态下不会再有第二次询问，socket 会一直占着；
    /// - 回合终态 `audio.done`（`receiveAgentDownlink`）—— 覆盖「上游真的说完
    ///   了」，让收口在那一刻立刻发生，而不是干等一个计时器周期。**只认终态**
    ///   的理由见该调用点的注释。
    private func retryDeferredClose(trigger: String) {
        guard let pending = deferredClose else { return }
        guard currentTransport != nil else {
            deferredClose = nil
            cancelPlaybackDrainGate()
            return
        }
        // ESS-1159 复审整改（阻断 1）：**三条件屏障**。业务终态（账本无未结
        // 任务，由策略裁决）+ 唯一最终 `audio.done`（本方法的 `audio_done`
        // 触发点）+ **播放队列完成**，三者齐了才收口。第三条以前完全缺席。
        //
        // 两条兜底计时器把它限死，socket 不会因为一个永远不到的回执而泄漏：
        // 回执宽限（首帧渲染回执还在 WCSession 路上）与排空上限。
        if let gate = playbackDrainGate(trigger: trigger) {
            PhoneAgentClientLog.info(
                module: "phone_session", event: "realtime_deferred_close_awaiting_playback",
                requestId: Self.turnIdentity(of: state)?.requestId ?? "",
                sessionId: Self.turnIdentity(of: state)?.sessionId ?? "",
                detail: "trigger=\(trigger) gate=\(gate.reason) "
                    + "playback_in_flight=\(playbackInFlight.count) "
                    + "cap_s=\(Int(gate.capSeconds))"
            )
            armPlaybackDrainCap(seconds: gate.capSeconds, phase: gate.phase)
            return
        }
        cancelPlaybackDrainGate()
        PhoneAgentClientLog.info(
            module: "phone_session", event: "realtime_deferred_close_retry",
            requestId: Self.turnIdentity(of: state)?.requestId ?? "",
            sessionId: Self.turnIdentity(of: state)?.sessionId ?? "",
            detail: "trigger=\(trigger) reason=\(pending.reason) cause=\(pending.cause.rawValue)"
        )
        // `endTurn` 自己会在真的关掉时清引用与缓冲；仍是 hold 就再武装一支。
        guard endTurn(reason: pending.reason, cause: pending.cause) else { return }
        // ESS-1159：被推迟的那次关闭兑现时，**终态语义不得退化**。
        // `endTurn` 的收口状态是 `.cancelled`（「这一轮收了」），而
        // `.uplinkFallback` 表达的是「Watch 的快速上行通道判死了」——协调层与
        // 真机日志靠 `.failed(reason:)` 才看得出这一轮是回退收场，不是正常收口。
        // 立即收口时那条 `transition(to: .failed(...))` 走的是 `forward` 里的
        // 同一行；推迟之后必须在这里补上，否则同一个事件因为「有没有被推迟」
        // 而落到两个不同的终态。
        if pending.cause == .uplinkFallback {
            transition(to: .failed(reason: pending.reason))
        }
    }

    /// System reported the phone entered background / lost network / the
    /// watch went unreachable. Same tear-down semantics — the coordinator on
    /// the watch will treat any next envelope as a new turn.
    func lifecycleInterrupted(reason: String) {
        Self.logger.notice(
            "realtime session interrupted reason=\(reason, privacy: .public)"
        )
        // ESS-1139：返回值刻意丢弃——生命周期打断没有「失败」可言。上游还有活
        // 在跑时它推迟收口并原样保留会话，这本身就是正确结果，不是错误。
        _ = endTurn(reason: "lifecycle_\(reason)", cause: .lifecycle)
    }

    /// ESS-751：唯一的下行出口。消费者**真正接手**（持久 outbox 入队成功）
    /// 才算转发完成且不留副本；它没接住时才进断连缓冲，受三条上限约束。
    private func deliverDownlink(_ envelope: RealtimeDownlinkEnvelope) {
        let outcome = pendingDownlink.deliver(
            envelope, nowSeconds: Date().timeIntervalSince1970, send: onDownlink
        )
        guard outcome.buffered else { return }
        Self.logger.notice(
            "realtime downlink buffered for replay dropped=\(outcome.dropped, privacy: .public) pending=\(self.pendingDownlink.pendingCount, privacy: .public) bytes=\(self.pendingDownlink.pendingBytes, privacy: .public)"
        )
    }

    /// 断连重放：WCSession activation / reachability / watch-state 恢复时由
    /// `PhoneConnectivity` 调用。按序重投，每条恰好一次；仍未被接手的回到
    /// 同一有界缓冲（保留首次入队时间，时长上限不会被重放刷新）。
    /// - Returns: 本次被消费者接手的条数。
    @discardableResult
    func replayPendingDownlink(trigger: String) -> Int {
        let outcome = pendingDownlink.replay(
            nowSeconds: Date().timeIntervalSince1970, send: onDownlink
        )
        guard !outcome.isIdle else { return 0 }
        Self.logger.notice(
            "realtime downlink replay trigger=\(trigger, privacy: .public) attempted=\(outcome.attempted, privacy: .public) handled=\(outcome.handled, privacy: .public) rebuffered=\(outcome.rebuffered, privacy: .public) dropped=\(outcome.dropped, privacy: .public)"
        )
        return outcome.handled
    }

    /// ESS-1139：会话层**是否还握着**这条 socket。
    ///
    /// 复审阻断正是「物理没关、逻辑失管」——hold 之后 `currentTransport` 被清，
    /// 后续回调全被第一道身份闸门拒掉。那条不变量必须能被断言，不能只靠人眼
    /// 复核；`currentTransport` 本身是 private，这里给出只读投影。
    var hasCurrentTransportForTesting: Bool { currentTransport != nil }

    /// 当前缓冲深度（条数 / 字节），供测试与排查对账。
    var pendingDownlinkStats: (count: Int, bytes: Int) {
        (pendingDownlink.pendingCount, pendingDownlink.pendingBytes)
    }

    /// Current identity for lifecycle evidence. The iPhone app logs scene
    /// transitions with this tuple so a socket failure can be aligned with
    /// the exact Gateway request instead of an unscoped app-level message.
    var currentTurnIdentity: (requestId: String, sessionId: String)? {
        Self.turnIdentity(of: state)
    }

    /// Agent transports push events through callbacks instead of the Bridge
    /// receive loop. Funnel them through the same current-transport gate so a
    /// callback already queued by a superseded turn cannot reach Watch.
    func receiveAgentDownlink(
        _ envelope: RealtimeDownlinkEnvelope,
        from transport: Transport
    ) {
        guard currentTransport === transport else {
            logDroppedDownlink(envelope, reason: "superseded_transport")
            return
        }
        guard case .active(let activeRequestId, let activeSessionId) = state,
              RealtimeRequestIsolationPolicy.accepts(
                incomingRequestId: envelope.requestId,
                incomingSessionId: envelope.sessionId,
                activeRequestId: activeRequestId,
                activeSessionId: activeSessionId
              ) else {
            logDroppedDownlink(envelope, reason: "request_session_mismatch")
            return
        }
        deliverDownlink(envelope)
        // ESS-1139：**只有回合终态**才立即重问一次被推迟的关闭。
        //
        // 这里的判据必须精确到 `audio.done`，不能是「任意一帧」：网关的顺序是
        // `task.state completed` → 最终答案音频 → `audio.done`，而账本在
        // `task.state completed` 那一刻就已经没有未结任务了。若逐帧重试，
        // 收口会发生在任务终态与最终答案之间——正好把答案切掉，等于把本单要修
        // 的那个 bug 换个地方重演。
        //
        // 终态之后再问就安全了：此时既没有未结任务、上游也说完了。仍在跑的
        // 情况（阶段播报的终态）策略会照常 hold，由计时器继续兜底。
        if deferredClose != nil, envelope.kind == .audioDone {
            // ESS-1159 复审整改（阻断 1）：终态先入账，屏障才看得见它。
            sawTurnTerminalForDeferredClose = true
            retryDeferredClose(trigger: "audio_done")
        }
    }

    /// 把闸门给的日志指令翻译成 `bridge.log` 事件。首条与汇总用**不同事件名**，
    /// 这样「`realtime_reopen_suppressed` 一轮几条」仍是可直接 grep 的口径。
    private func emit(_ logs: [RealtimeTurnGate.LogLine]) {
        for line in logs {
            switch line {
            case .suppressed(let requestId, let sessionId, let reason, let closedTurns):
                PhoneAgentClientLog.info(
                    module: "phone_session",
                    event: "realtime_reopen_suppressed",
                    requestId: requestId, sessionId: sessionId,
                    detail: "reason=\(reason) closed_turns=\(closedTurns) suppressed=1"
                )
            case .suppressedSummary(let requestId, let sessionId, let reason, let total):
                PhoneAgentClientLog.info(
                    module: "phone_session",
                    event: "realtime_reopen_suppressed_summary",
                    requestId: requestId, sessionId: sessionId,
                    detail: "reason=\(reason) suppressed_total=\(total)"
                )
            }
        }
    }

    /// 建立（或复用）本回合的通道。
    ///
    /// - Returns: 这个信封**该不该继续往下走**。`false` = 闸门拦下，调用方必须
    ///   直接丢弃：不建通道，也不落到 `transport.send`。后者尤其重要——一个已
    ///   判死回合的迟到帧若继续下落，会被发到**下一轮**的 transport 上，
    ///   把新回合的 Gateway sequence 打乱。
    ///
    /// 闸门放在状态短路**之后**：正在服务本回合（`.connecting` / `.active`）
    /// 时根本不存在「重开」，此时问闸门会把一条健康链路上的帧误伤掉
    /// （握手退避窗口内尤其明显）。
    @discardableResult
    private func openIfNeeded(
        requestId: String, sessionId: String, trigger: RealtimeTurnGate.Trigger
    ) -> Bool {
        switch state {
        case .active(let activeRequest, let activeSession)
                where activeRequest == requestId && activeSession == sessionId:
            return true
        case .connecting(let pendingRequest, let pendingSession)
                where pendingRequest == requestId && pendingSession == sessionId:
            return true
        default:
            break
        }
        // ESS-960：一个已判终态的回合不得被上行帧复活。这里以前是直接
        // 落进 `default: break` 往下建通道，而本方法由**每一个上行音频帧**
        // 调用——2026-08-21 真机因此打出 255 次握手 / 47 秒的重连风暴，
        // 节奏 ≈184ms 正是上行帧节奏。
        //
        // ESS-987：闸门不再只是「拦住重开」——`admit(...)` 直接给出「收不收
        // 这个信封」+「该打哪几条日志」，本方法把结论原样上交给 `forward(_:)`。
        // 判定、退避、日志收敛全部在 `Shared/RealtimeTurnGate`（`iOS/` 没有
        // 单测 target，留在这里就只能靠人眼复核）。
        let verdict = turnGate.admit(
            requestId: requestId, sessionId: sessionId,
            trigger: trigger, nowSeconds: Date().timeIntervalSince1970
        )
        emit(verdict.logs)
        guard verdict.isAdmitted else { return false }
        // ESS-1139：**这里就是真机上杀掉三个回合的那一行**。
        //
        // 旧代码无条件 `close(reason: "supersede")`：Watch 一旦（因为阶段播报
        // 的回合级 `audio.done` 抢在 `task.state` 之前落地）开了下一轮，
        // iPhone 就把一条上游 Codex 任务还在跑的 socket 关掉，网关随即对上游
        // 发 `mute` 并 `terminate`，此后所有帧按 `socket_closed` 丢弃——天气
        // 在任务启动后 1.2s、知识库在 11.5s，答案再也送不回来。
        //
        // 现在换 transport 之前先问账本：上游还有活在跑就**不换、不关**，
        // 本信封原地丢弃（Watch 侧由 ESS-1097 的回合闸门 + 180s 绝对上限兜底）。
        // 判定与有界性全在 `Shared/RealtimeSocketLifetimePolicy`。
        guard closeCurrentTransport(cause: .turnSupersede, reason: "supersede") else {
            return false
        }
        guard let transport = transportFactory(requestId, sessionId) else {
            transition(to: .failed(reason: "no_transport"))
            return false
        }
        currentTransport = transport
        // ESS-539 / ESS-1139 第二轮复审整改：陈旧下行缓冲在**新一轮真的建起来
        // 之后**才清。
        //
        // 不变量收敛成一句可判定的话：**只有真的换了一轮，上一轮的缓冲才作废**。
        // 于是三条边自动落到正确的一侧——
        //   • 被策略判 hold（上游还有活在跑）：根本走不到这里，缓冲原样保留，
        //     恢复后照常重放；
        //   • 被 ESS-960 闸门拦下 / transport 工厂失败：同样走不到这里，
        //     上一轮仍是当前那一轮，它的缓冲不该被一个没建成的新轮清掉；
        //   • 同一轮重发的 `stream.start`（方法开头就短路返回了）：不再误清
        //     自己的缓冲——这是把清理挪进来顺带修掉的一条。
        //
        // 触发面刻意维持 ESS-539 原样：只有 `.turnStart` 清。`.uplinkFrame` /
        // `.turnCommit` 触发的 supersede 本来就不清，这次不顺手扩大。
        if trigger == .turnStart, !pendingDownlink.isEmpty {
            let discarded = pendingDownlink.discardAll()
            Self.logger.info(
                "realtime discarding \(discarded) stale downlink envelopes from previous session"
            )
            PhoneAgentClientLog.info(
                module: "phone_session", event: "realtime_stale_downlink_discarded",
                requestId: requestId, sessionId: sessionId,
                detail: "discarded=\(discarded) reason=new_turn_established"
            )
        }
        transition(to: .connecting(requestId: requestId, sessionId: sessionId))
        scheduleReceive(transport)
        // Agent WSS connect is asynchronous. Its adapter reports the real
        // `.active` transition; announcing readiness here races token mint /
        // socket upgrade and recreates the false-ready failure mode.
        if !isAgentTransport {
            transition(to: .active(requestId: requestId, sessionId: sessionId))
        }
        return true
    }

    /// Accept state changes only from the transport serving the current turn.
    /// A superseded socket may still deliver a queued callback after close.
    func agentTransportDidChangeState(_ newState: State, from transport: Transport) {
        guard currentTransport === transport else { return }
        transition(to: newState)
    }

    private func scheduleReceive(_ transport: Transport) {
        // ESS-391: Agent transports deliver downlink events via callbacks
        // (wired in PhoneRealtimeAgentTransport), not through this loop.
        if isAgentTransport { return }
        transport.receive { [weak self, weak transport] result in
            guard let self, let transport, self.currentTransport === transport else { return }
            switch result {
            case .success(let envelope):
                self.deliverDownlink(envelope)
                self.scheduleReceive(transport)
            case .failure(let error):
                Self.logger.error(
                    "realtime downlink recv failed error=\(String(describing: error), privacy: .public)"
                )
                self.transition(to: .failed(reason: "recv_failed"))
                self.currentTransport = nil
            }
        }
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        // ESS-960：把「这一轮还能不能重开」落成状态，后续上行帧就再也泵不出
        // 无节制的握手。
        //
        // 区分两种失败（2026-08-21 18:27 真机教的）：
        //
        // - **已经 `.active` 过**：握手成功、token 已被网关消耗。Gateway token
        //   是单次上行的（见 `AudioRealtimeAgentSession` "maxReconnectAttempts
        //   = 0 — single-use tokens make reconnect impossible without a fresh
        //   token"），重开在协议上不可能成功 → 一次即终态。
        // - **还停在 `.connecting`**：握手压根没成功，token 没进过网关的账，
        //   重试是合理的。上一版把这种也判终态，结果当晚网关因 ESS-886 复发
        //   对所有握手回 401，整轮当场判死，用户连说话的机会都没有。
        //   现在允许有界重试（闸门内计数），超限才封。
        if case .failed(let reason) = newState, let turn = Self.turnIdentity(of: state) {
            let wasActive: Bool
            if case .active = state { wasActive = true } else { wasActive = false }
            turnGate.noteFailure(
                requestId: turn.requestId, sessionId: turn.sessionId,
                wasActive: wasActive, nowSeconds: Date().timeIntervalSince1970
            )
            PhoneAgentClientLog.info(
                module: "phone_session",
                event: "realtime_turn_failed",
                requestId: turn.requestId, sessionId: turn.sessionId,
                detail: "reason=\(reason) was_active=\(wasActive) "
                    + "closed_turns=\(turnGate.closedTurnCount)"
            )
        }
        state = newState
        onStateChange?(newState)
    }

    /// 从状态里取出它服务的回合身份；`idle` / `cancelled` / `failed` 不带身份。
    private static func turnIdentity(of state: State) -> (requestId: String, sessionId: String)? {
        switch state {
        case .connecting(let requestId, let sessionId), .active(let requestId, let sessionId):
            return (requestId, sessionId)
        case .idle, .cancelled, .failed:
            return nil
        }
    }

    private func logDroppedDownlink(_ envelope: RealtimeDownlinkEnvelope, reason: String) {
        let incomingGeneration = envelope.generation.map { String($0) } ?? "nil"
        let active: String
        switch state {
        case .active(let requestId, let sessionId), .connecting(let requestId, let sessionId):
            active = "current_request=\(requestId) current_session=\(sessionId)"
        default:
            active = "current_state=\(String(describing: state))"
        }
        PhoneAgentClientLog.info(
            module: "phone_session",
            event: "downlink_stale_request_dropped",
            requestId: envelope.requestId,
            sessionId: envelope.sessionId,
            detail: "reason=\(reason) incoming_generation=\(incomingGeneration) \(active)"
        )
    }
}

// MARK: - ESS-1139 默认账本

extension PhoneRealtimeSession.Transport {
    /// Bridge transport 与测试替身没有 `task.state` 这条流，也就没有「上游还有
    /// 活在跑」可言。默认给空账本 = 一律放行关闭，行为与本单之前逐字相同——
    /// 新闸门只对真正携带任务生命周期的 Agent transport 生效。
    var upstreamWorkLedger: UpstreamWorkLedger { UpstreamWorkLedger() }
}
