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
    private var transport: AudioRealtimeAgentTransport?
    private var currentTurn: TurnIdentity?
    private var heartbeatTimer: Timer?
    private var pendingUplink: [AudioRealtimeAgentCodec.UplinkFrame] = []

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

    init(config: AudioRealtimeAgentConfig, sessionId: String = UUID().uuidString) {
        self.config = config
        self.sessionId = sessionId
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
            pendingUplink.append(frame)
            return
        }
        transport.send(frame) { [weak self] error in
            if let error {
                Self.logger.error("agent commit send failed: \(String(describing: error), privacy: .public)")
                self?.handleTransportFailure(reason: "commit_failed")
            }
        }
    }

    /// Send cancel (user barge-in).
    func cancel(requestId: String, generation: Int, reason: String? = nil) {
        let frame = AudioRealtimeAgentCodec.UplinkFrame.cancel(
            sessionId: sessionId, requestId: requestId, generation: generation, reason: reason
        )
        transport?.send(frame) { error in
            if let error {
                Self.logger.error("cancel send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Tear down.
    func disconnect(reason: String) {
        stopHeartbeat()
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
                return
            }
            currentTurn?.deliveredSequences.insert(seq)
            Self.logger.info(
                "agent audio.delta rid=\(rid.prefix(8), privacy: .public) gen=\(gen) resp=\(respId.prefix(8), privacy: .public) seq=\(seq) bytes=\(audioBytes.count)"
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
            currentTurn?.finalSequence = finalSeq
            Self.logger.info(
                "agent audio.done rid=\(rid.prefix(8), privacy: .public) gen=\(gen) resp=\(respId.prefix(8), privacy: .public) final_seq=\(finalSeq)"
            )
            onAudioDone?(rid, respId, gen, finalSeq)

        case .cancelAck(let sid, let rid, let gen, let cancelledRespId):
            guard sid == sessionId else { return }
            Self.logger.info(
                "agent cancel.ack rid=\(rid.prefix(8), privacy: .public) gen=\(gen) cancelled_resp=\(cancelledRespId.prefix(8), privacy: .public)"
            )
            onCancelAck?(rid, gen, cancelledRespId)

        case .error(let code, let sid, let rid, let gen, let retriable, let detail):
            guard sid == sessionId else { return }
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
        for frame in frames {
            transport.send(frame) { error in
                if let error {
                    Self.logger.error("pending uplink flush failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
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
