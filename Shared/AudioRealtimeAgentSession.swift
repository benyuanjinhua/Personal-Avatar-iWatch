import Foundation
import os

/// ESS-402 Audio Realtime Agent session manager. Aligned with Gateway PR #159
/// (`AudioRealtimeGateway/realtime-session.mjs`).
///
/// Manages a direct WSS connection to the Audio Realtime Agent Gateway, handling
/// session lifecycle (open → session.start → ready → streaming → close),
/// heartbeat (client `ping` / Gateway `pong` / `server_ping`), connection
/// state observability, and structured logging with `session_id`/`request_id`/
/// `generation`/`sequence` (no token or raw audio in logs).
///
/// ### Reconnect posture (F4/F5)
///
/// `maxReconnectAttempts` defaults to 0. The Gateway issues single-use tokens
/// (TTL ≤ 90 s per ESS-388 A1). A disconnected WSS cannot reconnect within the
/// same turn — a fresh token from `POST /v1/realtime/session-token` is required.
/// Token refresh is an ESS-401 integration concern. When the socket drops, the
/// session emits `.failed` and callers fall back to the Bridge path.
///
/// No retransmission queue: reconnection is disallowed, so sequence continuity
/// across sockets is not applicable.
@MainActor
final class AudioRealtimeAgentSession {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "AgentRealtimeSession"
    )

    /// Log module tag emitted in `PhoneAgentClientLog` entries so bridge.log
    /// grep queries stay stable across refactors.
    static let logModule = "agent_session"

    /// ESS-842: outer timer that bounds the wait between `audio.commit` and the
    /// first downlink frame of the response. Injected so tests drive it
    /// deterministically; production uses the `Task.sleep`-backed default.
    /// Same seam as `WatchRealtimeMediaAdapter.BarrierTimer`.
    protocol ResponseWaitTimer: AnyObject {
        /// Arm (or re-arm) the timer. Cancels any prior pending fire.
        @MainActor func arm(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void)
        /// Cancel any pending fire. Idempotent.
        @MainActor func cancel()
    }

    /// Error code surfaced (and logged) when the client's own wait budget runs
    /// out. Distinct from the Gateway's `ERR_UPSTREAM_NO_RESPONSE`: seeing THIS
    /// code means the Gateway never spoke at all, so the next investigation
    /// starts at the socket, not at the upstream.
    static let awaitResponseTimeoutCode = "ERR_CLIENT_AWAIT_RESPONSE_TIMEOUT"

    // MARK: - Connection state

    enum ConnectionState: Equatable, CustomStringConvertible {
        case disconnected
        case connecting(sessionId: String)
        case waitingForReady(sessionId: String)
        case connected(sessionId: String, requestId: String, generation: Int)
        case failed(sessionId: String, reason: String)
        case closed

        var description: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting(let sid): return "connecting(session:\(sid.prefix(8)))"
            case .waitingForReady(let sid): return "waiting(session:\(sid.prefix(8)))"
            case .connected(let sid, let rid, let gen):
                return "connected(session:\(sid.prefix(8)),req:\(rid.prefix(8)),gen:\(gen))"
            case .failed(let sid, let reason):
                return "failed(session:\(sid.prefix(8)),reason:\(reason))"
            case .closed: return "closed"
            }
        }
    }

    // MARK: - Turn identity

    /// Turn identifiers scoped to this session. Aligned with Gateway scope:
    /// `session_id` + `request_id` + `generation` (Number).
    struct TurnIdentity: Equatable, Sendable {
        let sessionId: String
        let requestId: String
        let generation: Int
        /// Gateway-assigned `response_id` from the `ready` frame.
        var responseId: String?
        /// Sequences already delivered to the Watch (dedup).
        var deliveredSequences: Set<Int> = []
        /// Max `final_sequence` from `audio.done` (for barrier).
        var finalSequence: Int?
    }

    // MARK: - Configuration

    private let config: AudioRealtimeAgentConfig
    private let sessionId: String

    // MARK: - State

    private(set) var connectionState: ConnectionState = .disconnected
    /// ESS-391: exposed for PhoneRealtimeAgentTransport to send playback
    /// receipts (playback.started/playback.ended) and other frames that
    /// don't have dedicated convenience methods.
    private(set) var transport: AudioRealtimeAgentTransport?
    private var currentTurn: TurnIdentity?
    private var heartbeatTimer: Timer?
    private var pendingUplink: [AudioRealtimeAgentCodec.UplinkFrame] = []
    /// ESS-842: armed when `audio.commit` actually leaves for the Gateway,
    /// cancelled by the first frame of the response.
    private let responseWaitTimer: ResponseWaitTimer
    private(set) var isAwaitingResponse = false

    /// Emitted on every `ConnectionState` transition.
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    /// Emitted when a downlink `audio.delta` chunk is ready for Watch playback.
    /// Params: (VoiceStreamChunk, responseId, generation).
    var onAudioDelta: ((VoiceStreamChunk, String?, Int) -> Void)?

    /// Emitted when the Gateway signals the audio response is complete (`audio.done`).
    /// Params: (requestId, responseId, generation, finalSequence).
    var onAudioDone: ((String, String?, Int, Int) -> Void)?

    /// Emitted on Gateway `error`.
    /// Params: (code, requestId, generation, retriable, detail).
    var onError: ((String, String, Int, Bool, String?) -> Void)?

    /// Emitted when Gateway confirms cancel (`cancel.ack`).
    var onCancelAck: ((String, Int, String) -> Void)?

    // MARK: - Init

    init(
        config: AudioRealtimeAgentConfig,
        sessionId: String = UUID().uuidString,
        responseWaitTimer: ResponseWaitTimer = TaskBasedResponseWaitTimer()
    ) {
        self.config = config
        self.sessionId = sessionId
        self.responseWaitTimer = responseWaitTimer
    }

    // MARK: - Public API

    /// Open the WSS connection and send `session.start`.
    @discardableResult
    func connect(requestId: String, generation: Int) -> Bool {
        guard case .disconnected = connectionState else {
            Self.logger.warning("agent session already in state \(self.connectionState.description, privacy: .public)")
            return false
        }
        self.currentTurn = TurnIdentity(
            sessionId: sessionId, requestId: requestId, generation: generation
        )
        guard let transport = AudioRealtimeAgentTransport.create(
            config: config, sessionId: sessionId,
            requestId: requestId, generation: generation
        ) else {
            transition(to: .failed(sessionId: sessionId, reason: "no_transport"))
            return false
        }
        self.transport = transport
        transition(to: .connecting(sessionId: sessionId))
        startReceiveLoop(transport)
        transition(to: .waitingForReady(sessionId: sessionId))
        // Send session.start — auth is in the HTTP header, not the JSON payload
        let startFrame = AudioRealtimeAgentCodec.UplinkFrame.sessionStart(
            sessionId: sessionId, requestId: requestId,
            generation: generation, protocolVersion: 1
        )
        transport.send(startFrame) { [weak self] error in
            if let error {
                Self.logger.error("session.start send failed: \(String(describing: error), privacy: .public)")
                self?.handleTransportFailure(reason: "start_failed")
            }
        }
        Self.logger.info(
            "agent session.start sid=\(self.sessionId.prefix(8), privacy: .public) rid=\(requestId.prefix(8), privacy: .public) gen=\(generation)"
        )
        return true
    }

    /// Send an uplink audio chunk.
    func sendAudioChunk(_ chunk: VoiceStreamChunk, requestId: String, generation: Int) {
        let frame = AudioRealtimeAgentCodec.UplinkFrame.audioAppend(
            sessionId: sessionId, requestId: requestId, generation: generation,
            sequence: chunk.sequence,
            sampleRate: chunk.sampleRate, codec: chunk.codec,
            audioBase64: chunk.payload.base64EncodedString()
        )
        guard let transport, case .connected = connectionState else {
            pendingUplink.append(frame)
            return
        }
        transport.send(frame) { [weak self] error in
            if let error {
                Self.logger.error("agent uplink send failed: \(String(describing: error), privacy: .public)")
                self?.handleTransportFailure(reason: "send_failed")
            }
        }
    }

    /// Commit uplink.
    func commitUplink(requestId: String, generation: Int, finalSequence: Int) {
        let frame = AudioRealtimeAgentCodec.UplinkFrame.audioCommit(
            sessionId: sessionId, requestId: requestId, generation: generation,
            sequence: finalSequence
        )
        guard let transport, case .connected = connectionState else {
            // Queued behind `ready`; the wait budget starts when the frame
            // really leaves, in `flushPendingUplink`.
            pendingUplink.append(frame)
            return
        }
        transport.send(frame) { [weak self] error in
            if let error {
                Self.logger.error("agent commit send failed: \(String(describing: error), privacy: .public)")
                self?.handleTransportFailure(reason: "commit_failed")
            }
        }
        armResponseWait(requestId: requestId, generation: generation)
    }

    /// Send cancel (user barge-in).
    func cancel(requestId: String, generation: Int, reason: String? = nil,
                onFailure: (() -> Void)? = nil) {
        let frame = AudioRealtimeAgentCodec.UplinkFrame.cancel(
            sessionId: sessionId, requestId: requestId, generation: generation, reason: reason
        )
        transport?.send(frame) { error in
            if let error {
                Self.logger.error("cancel send failed: \(String(describing: error), privacy: .public)")
                onFailure?()
            }
        }
    }

    /// Tear down.
    func disconnect(reason: String) {
        stopHeartbeat()
        cancelResponseWait()
        transport?.close(reason: reason)
        transport = nil
        pendingUplink.removeAll(keepingCapacity: false)
        transition(to: .closed)
    }

    // MARK: - Receive loop

    private func startReceiveLoop(_ transport: AudioRealtimeAgentTransport) {
        transport.receive { [weak self, weak transport] result in
            guard let self, let transport, self.transport === transport else { return }
            switch result {
            case .event(let event):
                self.handleDownlinkEvent(event)
            case .unrecognised(let type):
                Self.logger.info("agent unrecognised downlink type=\(type, privacy: .public)")
            case .malformed(let bytes):
                // ESS-525: protocol drift — the transport already logged
                // `downlink_decode_failed`. Do NOT close the session; the
                // receive loop stays live for the next frame.
                Self.logger.error("agent malformed downlink frame bytes=\(bytes)")
            case .error(let error):
                Self.logger.error("agent receive error: \(String(describing: error), privacy: .public)")
                self.handleTransportFailure(reason: "recv_error")
            }
        }
    }

    private func handleDownlinkEvent(_ event: AudioRealtimeAgentCodec.DownlinkEvent) {
        switch event {
        case .ready(let sid, let rid, let gen, let respId, let hbMs, _):
            guard sid == sessionId, let turn = currentTurn,
                  turn.requestId == rid, turn.generation == gen else {
                Self.logger.warning("ready scope mismatch")
                return
            }
            Self.logger.info(
                "agent ready sid=\(sid.prefix(8), privacy: .public) rid=\(rid.prefix(8), privacy: .public) gen=\(gen) resp=\(respId.prefix(8), privacy: .public) hb=\(hbMs)ms"
            )
            currentTurn?.responseId = respId
            transition(to: .connected(sessionId: sid, requestId: rid, generation: gen))
            startHeartbeat(intervalMs: hbMs)
            flushPendingUplink()

        case .audioDelta(let sid, let rid, let respId, let gen, let seq,
                         let sampleRate, let codec, let audioBytes):
            guard sid == sessionId, let turn = currentTurn,
                  turn.requestId == rid else { return }
            // Dedup
            if turn.deliveredSequences.contains(seq) {
                Self.logger.debug("agent dup seq=\(seq) — dropped")
                PhoneAgentClientLog.info(
                    module: Self.logModule,
                    event: "downlink_audio_delta_dup",
                    requestId: rid, sessionId: sid,
                    detail: "seq=\(seq) gen=\(gen)"
                )
                return
            }
            cancelResponseWait()
            currentTurn?.deliveredSequences.insert(seq)
            Self.logger.info(
                "agent audio.delta rid=\(rid.prefix(8), privacy: .public) gen=\(gen) resp=\(respId.prefix(8), privacy: .public) seq=\(seq) bytes=\(audioBytes.count)"
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_audio_delta_accepted",
                requestId: rid, sessionId: sid,
                detail: "seq=\(seq) gen=\(gen) bytes=\(audioBytes.count) sr=\(sampleRate) codec=\(codec)"
            )
            let chunk = VoiceStreamChunk(
                requestId: rid, streamId: sid, direction: .downlink,
                sequence: seq, capturedAtMs: 1,
                codec: codec, sampleRate: sampleRate,
                payload: audioBytes, endOfStream: false
            )
            onAudioDelta?(chunk, respId, gen)

        case .audioDone(let sid, let rid, let respId, let gen, let finalSeq):
            guard sid == sessionId, let turn = currentTurn,
                  turn.requestId == rid else { return }
            cancelResponseWait()
            currentTurn?.finalSequence = finalSeq
            Self.logger.info(
                "agent audio.done rid=\(rid.prefix(8), privacy: .public) gen=\(gen) resp=\(respId.prefix(8), privacy: .public) final_seq=\(finalSeq)"
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_audio_done_accepted",
                requestId: rid, sessionId: sid,
                detail: "final_seq=\(finalSeq) gen=\(gen)"
            )
            onAudioDone?(rid, respId, gen, finalSeq)

        case .cancelAck(let sid, let rid, let gen, let cancelledRespId):
            guard sid == sessionId else { return }
            cancelResponseWait()
            Self.logger.info(
                "agent cancel.ack rid=\(rid.prefix(8), privacy: .public) gen=\(gen) cancelled_resp=\(cancelledRespId.prefix(8), privacy: .public)"
            )
            onCancelAck?(rid, gen, cancelledRespId)

        case .error(let code, let sid, let rid, let gen, let retriable, let detail):
            guard sid == sessionId else { return }
            cancelResponseWait()
            Self.logger.error(
                "agent error code=\(code, privacy: .public) rid=\(rid.prefix(8), privacy: .public) gen=\(gen) retriable=\(retriable) detail=\(detail ?? "nil", privacy: .public)"
            )
            onError?(code, rid, gen, retriable, detail)
            // Hard errors close the session
            if !retriable {
                handleTransportFailure(reason: "gateway_error_\(code)")
            }

        case .pong(let nonce):
            Self.logger.debug("agent pong nonce=\(nonce.prefix(8))")

        case .serverPing(let at):
            Self.logger.debug("agent server_ping at=\(at)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat(intervalMs: Int) {
        stopHeartbeat()
        let interval = max(5.0, Double(intervalMs) / 1000.0)
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sendPing()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendPing() {
        guard let transport, case .connected = connectionState else { return }
        let nonce = UUID().uuidString
        transport.send(.ping(nonce: nonce)) { [weak self] error in
            if let error {
                Self.logger.error("ping failed: \(String(describing: error), privacy: .public)")
                self?.handleTransportFailure(reason: "ping_failed")
            }
        }
    }

    // MARK: - Failure

    private func handleTransportFailure(reason: String) {
        stopHeartbeat()
        cancelResponseWait()
        // F4: maxReconnectAttempts = 0 — single-use tokens make reconnect
        // impossible without a fresh token. Fail immediately.
        transition(to: .failed(sessionId: sessionId, reason: reason))
        transport?.close(reason: reason)
        transport = nil
    }

    // MARK: - Pending uplink flush

    private func flushPendingUplink() {
        guard let transport, !pendingUplink.isEmpty else { return }
        let frames = pendingUplink
        pendingUplink.removeAll(keepingCapacity: false)
        var flushedCommit: (requestId: String, generation: Int)?
        for frame in frames {
            if case .audioCommit(_, let requestId, let generation, _) = frame {
                flushedCommit = (requestId, generation)
            }
            transport.send(frame) { error in
                if let error {
                    Self.logger.error("pending uplink flush failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        // ESS-842: a commit that waited for `ready` only reaches the Gateway
        // here, so this is where its wait budget starts.
        if let flushedCommit {
            armResponseWait(requestId: flushedCommit.requestId, generation: flushedCommit.generation)
        }
    }

    // MARK: - ESS-842 response wait budget

    /// Start (or restart) the post-commit wait budget.
    ///
    /// The budget deliberately outlasts the Gateway's own committed-turn
    /// deadline (`AudioRealtimeAgentConfig.gatewayResponseDeadline` + delivery
    /// margin): the Gateway is the party that knows WHY there is no answer, so
    /// the client must still be listening when it says so. This timer only
    /// fires when even that never arrives — and then it leaves an explicit
    /// reason instead of the bare `1006` the incident left behind.
    private func armResponseWait(requestId: String, generation: Int) {
        isAwaitingResponse = true
        PhoneAgentClientLog.info(
            module: Self.logModule, event: "await_response_started",
            requestId: requestId, sessionId: sessionId,
            detail: "budget_s=\(config.responseWaitTimeout) gen=\(generation)"
        )
        responseWaitTimer.arm(after: config.responseWaitTimeout) { [weak self] in
            self?.handleResponseWaitTimeout(requestId: requestId, generation: generation)
        }
    }

    /// Cancel the budget — the response has started (or the turn is over).
    private func cancelResponseWait() {
        guard isAwaitingResponse else { return }
        isAwaitingResponse = false
        responseWaitTimer.cancel()
    }

    private func handleResponseWaitTimeout(requestId: String, generation: Int) {
        guard isAwaitingResponse else { return }
        isAwaitingResponse = false
        Self.logger.error(
            "agent await response timeout rid=\(requestId.prefix(8), privacy: .public) gen=\(generation)"
        )
        PhoneAgentClientLog.error(
            module: Self.logModule, event: "await_response_timeout",
            requestId: requestId, sessionId: sessionId,
            detail: "budget_s=\(config.responseWaitTimeout) gen=\(generation)",
            code: Self.awaitResponseTimeoutCode
        )
        onError?(Self.awaitResponseTimeoutCode, requestId, generation, true, "no downlink within client wait budget")
        // Close with a reason. A turn that ends here must be greppable as
        // `await_response_timeout`, never as an unexplained 1006.
        disconnect(reason: "await_response_timeout")
    }

    // MARK: - Testing hooks

    /// Test-only funnel — drives `handleDownlinkEvent` without the
    /// URLSession-backed receive loop. Real code paths go through
    /// `startReceiveLoop` → `handleDownlinkEvent`; tests bypass the
    /// transport so they can exercise decoded events deterministically.
    func handleForTesting(event: AudioRealtimeAgentCodec.DownlinkEvent) {
        handleDownlinkEvent(event)
    }

    // MARK: - State transitions

    private func transition(to newState: ConnectionState) {
        guard connectionState != newState else { return }
        connectionState = newState
        Self.logger.info(
            "agent session state → \(newState.description, privacy: .public)"
        )
        onConnectionStateChange?(newState)
    }
}

/// ESS-842 default `ResponseWaitTimer`. Same `Task { Task.sleep }` shape as
/// `TaskBasedBarrierTimer` so both outer timers behave identically under
/// cancellation and app lifecycle. `arm(...)` cancels any prior scheduling.
@MainActor
final class TaskBasedResponseWaitTimer: AudioRealtimeAgentSession.ResponseWaitTimer {
    private var task: Task<Void, Never>?

    /// Non-isolated init so the session's default argument can build one from
    /// a nonisolated context; `task` is only touched from `arm` / `cancel`.
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
