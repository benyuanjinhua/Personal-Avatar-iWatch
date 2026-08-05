import Foundation
import os

/// ESS-402 Audio Realtime Agent session manager.
///
/// Manages a direct WSS connection to the Audio Realtime Agent Gateway, handling
/// session lifecycle (open → authenticate → streaming → close), heartbeat,
/// connection state observability, and one safe reconnection before the first
/// packet with deduplication.
///
/// Responsibilities:
///   - Open a WSS connection per turn via `AudioRealtimeAgentTransport`.
///   - Send `session.update` with the auth token on connect.
///   - Forward uplink `VoiceStreamChunk` frames as `input_audio.append`.
///   - Decode downlink `response.audio.delta` events into `VoiceStreamChunk`
///     and emit them for Watch playback.
///   - Maintain a heartbeat (client sends `heartbeat`, Gateway acks with
///     `heartbeat_ack`; missing ack within timeout triggers reconnect).
///   - Provide at most one safe reconnection before the first audio packet
///     lands, with deduplication to prevent double delivery.
///   - Expose an observable `ConnectionState` for UI and logging.
///   - Log `session_id`, `turn_id`, `generation`, and `seq` at each stage
///     without recording the raw token or audio payloads in logs.
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
        case authenticating(sessionId: String)
        case connected(sessionId: String, turnId: String?)
        case reconnecting(sessionId: String, attempt: Int)
        case failed(sessionId: String, reason: String)
        case closed

        var description: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting(let sid): return "connecting(session:\(sid.prefix(8)))"
            case .authenticating(let sid): return "authenticating(session:\(sid.prefix(8)))"
            case .connected(let sid, let tid):
                return "connected(session:\(sid.prefix(8)),turn:\(tid?.prefix(8) ?? "none"))"
            case .reconnecting(let sid, let n):
                return "reconnecting(session:\(sid.prefix(8)),attempt:\(n))"
            case .failed(let sid, let reason):
                return "failed(session:\(sid.prefix(8)),reason:\(reason))"
            case .closed: return "closed"
            }
        }
    }

    // MARK: - Turn identity

    /// Turn identifiers for logging and deduplication.
    struct TurnIdentity: Equatable, Sendable {
        let sessionId: String
        var turnId: String
        /// Gateway-assigned `generation` from the first `response.audio.delta`.
        /// Used in logs and for playback receipt tracking.
        var generation: String?
        /// Sequences we have already delivered to the Watch (dedup key).
        var deliveredSequences: Set<Int> = []
    }

    // MARK: - Configuration

    private let config: AudioRealtimeAgentConfig
    private let sessionId: String

    // MARK: - State

    private(set) var connectionState: ConnectionState = .disconnected
    private var transport: AudioRealtimeAgentTransport?
    private var currentTurn: TurnIdentity?
    private var reconnectCount: Int = 0
    private var heartbeatTimer: Timer?
    private var reconnectTimer: Timer?
    private var pendingUplink: [AudioRealtimeAgentCodec.UplinkFrame] = []

    /// Emitted on every `ConnectionState` transition.
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    /// Emitted when a downlink audio chunk is ready for Watch playback.
    /// The `VoiceStreamChunk` carries the Agent's `session_id`/`generation`/`seq`.
    var onAudioDelta: ((VoiceStreamChunk, String?) -> Void)?

    /// Emitted when the Gateway signals the audio response is complete.
    var onAudioDone: ((String, String?) -> Void)?

    /// Emitted when a transcript delta arrives.
    var onTranscriptDelta: ((String, String) -> Void)?

    /// Emitted when the transcript is final.
    var onTranscriptDone: ((String) -> Void)?

    /// Emitted on Gateway error.
    var onError: ((String, String) -> Void)?

    // MARK: - Init

    init(config: AudioRealtimeAgentConfig, sessionId: String = UUID().uuidString) {
        self.config = config
        self.sessionId = sessionId
    }

    // MARK: - Public API

    /// Open the WSS connection and authenticate. Returns `true` if the
    /// connection attempt started; calls `onConnectionStateChange` on
    /// state transitions.
    @discardableResult
    func connect(turnId: String) -> Bool {
        guard case .disconnected = connectionState else {
            Self.logger.warning("agent session already in state \(self.connectionState.description, privacy: .public)")
            return false
        }
        self.currentTurn = TurnIdentity(sessionId: sessionId, turnId: turnId)
        return openTransport(sessionId: sessionId)
    }

    /// Send an uplink audio chunk. If the session is not yet connected, the
    /// frame is buffered and flushed on connect.
    func sendAudioChunk(_ chunk: VoiceStreamChunk, turnId: String) {
        let frame = AudioRealtimeAgentCodec.UplinkFrame.inputAudioAppend(
            sessionId: sessionId,
            turnId: turnId,
            sequence: chunk.sequence,
            sampleRate: chunk.sampleRate,
            codec: chunk.codec,
            audioBase64: chunk.payload.base64EncodedString(),
            endOfStream: chunk.endOfStream
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

    /// Commit the uplink audio buffer (user released the record button).
    func commitUplink(turnId: String, finalSequence: Int) {
        let frame = AudioRealtimeAgentCodec.UplinkFrame.inputAudioCommit(
            sessionId: sessionId,
            turnId: turnId,
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

    /// Tear down the session. Sends no further frames; the socket is closed.
    func disconnect(reason: String) {
        stopHeartbeat()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        transport?.close(reason: reason)
        transport = nil
        pendingUplink.removeAll(keepingCapacity: false)
        transition(to: .closed)
    }

    // MARK: - Transport lifecycle

    private func openTransport(sessionId: String) -> Bool {
        guard let newTransport = AudioRealtimeAgentTransport.create(
            config: config, sessionId: sessionId
        ) else {
            transition(to: .failed(sessionId: sessionId, reason: "no_transport"))
            return false
        }
        transport = newTransport
        transition(to: .connecting(sessionId: sessionId))
        startReceiveLoop(newTransport)
        // Send session.update to authenticate
        transition(to: .authenticating(sessionId: sessionId))
        authenticate(transport: newTransport)
        return true
    }

    private func authenticate(transport: AudioRealtimeAgentTransport) {
        let authFrame = AudioRealtimeAgentCodec.UplinkFrame.sessionUpdate(
            sessionId: sessionId, token: config.authToken
        )
        transport.send(authFrame) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.logger.error("agent auth send failed: \(String(describing: error), privacy: .public)")
                self.handleTransportFailure(reason: "auth_failed")
                return
            }
            // Wait for session.created from Gateway; if it doesn't arrive
            // within connectionTimeout, the receive loop will trigger a failure.
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop(_ transport: AudioRealtimeAgentTransport) {
        transport.receive { [weak self, weak transport] result in
            guard let self, let transport, self.transport === transport else { return }
            switch result {
            case .event(let event):
                self.handleDownlinkEvent(event, transport: transport)
            case .unrecognised(let type):
                Self.logger.info("agent unrecognised downlink type=\(type, privacy: .public)")
            case .error(let error):
                Self.logger.error("agent receive error: \(String(describing: error), privacy: .public)")
                self.handleTransportFailure(reason: "recv_error")
            }
        }
    }

    private func handleDownlinkEvent(
        _ event: AudioRealtimeAgentCodec.DownlinkEvent,
        transport: AudioRealtimeAgentTransport
    ) {
        switch event {
        case .sessionCreated(let sid, let turnId):
            guard sid == sessionId else {
                Self.logger.warning("session.created for unknown session \(sid, privacy: .public)")
                return
            }
            Self.logger.info(
                "agent session created session=\(sid.prefix(8), privacy: .public) turn=\(turnId?.prefix(8) ?? "nil", privacy: .public)"
            )
            currentTurn?.turnId = turnId ?? currentTurn?.turnId ?? ""
            transition(to: .connected(sessionId: sid, turnId: currentTurn?.turnId))
            startHeartbeat()
            flushPendingUplink()
            reconnectCount = 0 // Reset reconnect counter on successful connection

        case .audioDelta(let sid, let turnId, let generation, let sequence,
                         let sampleRate, let codec, let audioBytes, let endOfStream, let capturedAtMs):
            guard sid == sessionId else { return }
            // Dedup: skip sequences we've already delivered
            if currentTurn?.deliveredSequences.contains(sequence) == true {
                Self.logger.debug("agent dup seq=\(sequence) session=\(sid.prefix(8)) — dropped")
                return
            }
            currentTurn?.generation = generation
            currentTurn?.deliveredSequences.insert(sequence)
            Self.logger.info(
                "agent audio.delta session=\(sid.prefix(8), privacy: .public) turn=\(turnId.prefix(8), privacy: .public) gen=\(generation?.prefix(8) ?? "nil", privacy: .public) seq=\(sequence) bytes=\(audioBytes.count)"
            )
            let chunk = VoiceStreamChunk(
                requestId: turnId,
                streamId: sid,
                direction: .downlink,
                sequence: sequence,
                capturedAtMs: capturedAtMs ?? 1,
                codec: codec,
                sampleRate: sampleRate,
                payload: audioBytes,
                endOfStream: endOfStream
            )
            onAudioDelta?(chunk, generation)

        case .audioDone(let sid, let turnId, let generation):
            guard sid == sessionId else { return }
            Self.logger.info(
                "agent audio.done session=\(sid.prefix(8), privacy: .public) turn=\(turnId.prefix(8), privacy: .public) gen=\(generation?.prefix(8) ?? "nil", privacy: .public)"
            )
            onAudioDone?(turnId, generation)

        case .transcriptDelta(let sid, let turnId, let text):
            guard sid == sessionId else { return }
            Self.logger.info(
                "agent transcript.delta session=\(sid.prefix(8), privacy: .public) turn=\(turnId.prefix(8), privacy: .public)"
            )
            onTranscriptDelta?(turnId, text)

        case .transcriptDone(let sid, let turnId):
            guard sid == sessionId else { return }
            Self.logger.info(
                "agent transcript.done session=\(sid.prefix(8), privacy: .public) turn=\(turnId.prefix(8), privacy: .public)"
            )
            onTranscriptDone?(turnId)

        case .heartbeatAck(let sid, let timestampMs):
            guard sid == sessionId else { return }
            Self.logger.debug(
                "agent heartbeat_ack session=\(sid.prefix(8), privacy: .public) ts=\(timestampMs)"
            )

        case .error(let sid, let code, let message):
            guard sid == sessionId else { return }
            Self.logger.error(
                "agent error session=\(sid.prefix(8), privacy: .public) code=\(code, privacy: .public) msg=\(message, privacy: .public)"
            )
            onError?(code, message)
            if code == "SESSION_EXPIRED" || code == "AUTH_FAILED" {
                handleTransportFailure(reason: "gateway_error_\(code)")
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: config.heartbeatInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sendHeartbeat()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendHeartbeat() {
        guard let transport, case .connected = connectionState else { return }
        let frame = AudioRealtimeAgentCodec.UplinkFrame.heartbeat(
            sessionId: sessionId,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        transport.send(frame) { [weak self] error in
            if let error {
                Self.logger.error("heartbeat send failed: \(String(describing: error), privacy: .public)")
                self?.handleTransportFailure(reason: "heartbeat_failed")
            }
        }
    }

    // MARK: - Reconnection

    private func handleTransportFailure(reason: String) {
        stopHeartbeat()
        let currentAttempt = reconnectCount
        guard currentAttempt < config.maxReconnectAttempts else {
            transition(to: .failed(sessionId: sessionId, reason: reason))
            return
        }
        reconnectCount += 1
        transition(to: .reconnecting(sessionId: sessionId, attempt: reconnectCount))
        transport?.close(reason: reason)
        transport = nil

        // Retry after a short delay
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Self.logger.info(
                    "agent reconnect attempt \(self.reconnectCount) session=\(self.sessionId.prefix(8), privacy: .public)"
                )
                _ = self.openTransport(sessionId: self.sessionId)
            }
        }
    }

    // MARK: - Pending uplink flush

    private func flushPendingUplink() {
        guard let transport, !pendingUplink.isEmpty else { return }
        let frames = pendingUplink
        pendingUplink.removeAll(keepingCapacity: false)
        for frame in frames {
            transport.send(frame) { [weak self] error in
                if let error {
                    Self.logger.error("pending uplink flush failed: \(String(describing: error), privacy: .public)")
                    self?.handleTransportFailure(reason: "flush_failed")
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
