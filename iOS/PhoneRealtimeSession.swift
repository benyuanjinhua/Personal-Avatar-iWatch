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

    init(transportFactory: @escaping (_ requestId: String, _ sessionId: String) -> Transport?) {
        self.transportFactory = transportFactory
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
            // ESS-539: a new stream.start means a new turn. Discard any
            // downlink envelopes queued from a previous incomplete session
            // so they don't pollute the new turn's playback.
            if !pendingDownlink.isEmpty {
                let discarded = pendingDownlink.discardAll()
                Self.logger.info(
                    "realtime discarding \(discarded) stale downlink envelopes from previous session"
                )
            }
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
        case .fallback:
            guard let descriptor = envelope.fallback else { return }
            transition(to: .failed(reason: descriptor.reason))
            currentTransport?.close(reason: descriptor.reason)
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
                self?.currentTransport?.close(reason: "send_failed")
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
    func endTurn(reason: String) {
        transition(to: .cancelled)
        currentTransport?.close(reason: reason)
        currentTransport = nil
        pendingDownlink.discardAll()
        // ESS-987：回合边界是压制日志的收口点——把这一轮攒下的计数打成一条
        // 汇总，而不是逐帧刷屏。
        emit(turnGate.flushSuppressionSummaries())
    }

    /// System reported the phone entered background / lost network / the
    /// watch went unreachable. Same tear-down semantics — the coordinator on
    /// the watch will treat any next envelope as a new turn.
    func lifecycleInterrupted(reason: String) {
        Self.logger.notice(
            "realtime session interrupted reason=\(reason, privacy: .public)"
        )
        endTurn(reason: "lifecycle_\(reason)")
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
        currentTransport?.close(reason: "supersede")
        guard let transport = transportFactory(requestId, sessionId) else {
            transition(to: .failed(reason: "no_transport"))
            return false
        }
        currentTransport = transport
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
