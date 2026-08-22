import Foundation
import os

/// ESS-402 WebSocket transport for the Audio Realtime Agent Gateway.
///
/// Wraps a `URLSessionWebSocketTask` speaking the Agent Gateway protocol
/// (see `AudioRealtimeAgentCodec`, aligned with Gateway PR #159
/// `AudioRealtimeGateway/realtime-session.mjs`).
///
/// The transport layer is deliberately minimal: open, send, receive loop,
/// close. Auth is via the HTTP `Authorization: Bearer <token>` header (token
/// never appears in the JSON payload). Reconnection, heartbeat, and session
/// lifecycle live in `AudioRealtimeAgentSession`.
///
/// ESS-525 fixes applied here:
///   1. **URLSession is retained.** Previously `create(...)` built an
///      ephemeral session in a local variable, kept only the task, and
///      returned — ARC then released the session immediately. A
///      `URLSessionTask` does not strong-reference its owning session, so
///      the task's underlying socket got torn down mid-turn, surfacing on
///      the Gateway as `close_code=1006 reason=peer_closed done_emitted=true`
///      (ESS-525 L1 evidence, 2026-08-07 09:48:34).
///   2. **Malformed frames no longer terminate the receive loop.** The old
///      switch ended the loop and left the socket half-open; a single stray
///      keepalive or future field would silently freeze all downlink for the
///      remainder of the turn. Now the transport logs, notifies, and keeps
///      pulling — matching the Bridge transport's `.unrecognised` handling.
///   3. **Close code / reason are captured.** A `URLSessionWebSocketDelegate`
///      surfaces the WSS close frame; both peer-initiated closes and our own
///      `close(reason:)` land in the same structured evidence sink.
///   4. **Per-frame structured evidence is emitted** so `bridge.log` has
///      client-side `downlink_frame_received` / `downlink_decode_ok` /
///      `downlink_decode_failed` / `wss_close` entries greppable by
///      `request_id` — matching ESS-525 acceptance §1.
@MainActor
final class AudioRealtimeAgentTransport {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "AgentRealtimeTransport"
    )

    /// Log module tag used in `PhoneAgentClientLog` entries emitted by this
    /// transport. Kept as a constant so grep queries in `bridge.log` (e.g.
    /// `module=agent_transport`) stay stable across refactors.
    static let logModule = "agent_transport"

    enum DownlinkResult {
        case event(AudioRealtimeAgentCodec.DownlinkEvent)
        case unrecognised(type: String)
        /// A frame arrived but the codec could not parse it. The receive
        /// loop keeps running — malformed frames are protocol drift, not a
        /// terminal error (ESS-525 fix #2).
        case malformed(bytes: Int)
        /// The socket-level receive itself failed — this IS terminal.
        case error(Error)
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let requestId: String
    private let sessionId: String
    private let generation: Int
    private var isClosed = false
    private let closeObserver: CloseObserver

    init(
        session: URLSession,
        task: URLSessionWebSocketTask,
        sessionId: String,
        requestId: String,
        generation: Int,
        closeObserver: CloseObserver
    ) {
        self.session = session
        self.task = task
        self.sessionId = sessionId
        self.requestId = requestId
        self.generation = generation
        self.closeObserver = closeObserver
        closeObserver.attach { [weak self] code, reason in
            Task { @MainActor in self?.handleSocketClosed(code: code, reason: reason) }
        }
        task.resume()
    }

    // MARK: - Factory

    /// Create a transport from an `AudioRealtimeAgentConfig`.
    ///
    /// The Gateway URL is extended with `?device_id=&session_id=&request_id=
    /// &generation=` query params for scope binding (Gateway PR #159 verifies
    /// these against the token scope on upgrade). The `Authorization: Bearer
    /// <token>` header carries the ephemeral auth token.
    ///
    /// The URLSession is stored on the returned transport (ESS-525 fix #1) —
    /// a delegate captures the WSS close frame so ESS-525 §1 close_code/
    /// reason evidence lands in `bridge.log`. The session is invalidated
    /// on `close(reason:)` so its delegate queue does not leak between turns.
    static func create(
        config: AudioRealtimeAgentConfig,
        sessionId: String,
        requestId: String,
        generation: Int
    ) -> AudioRealtimeAgentTransport? {
        guard var components = URLComponents(
            url: config.gatewayURL, resolvingAgainstBaseURL: false
        ) else { return nil }
        let deviceId = config.deviceId
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "device_id", value: deviceId))
        queryItems.append(URLQueryItem(name: "session_id", value: sessionId))
        queryItems.append(URLQueryItem(name: "request_id", value: requestId))
        queryItems.append(URLQueryItem(name: "generation", value: String(generation)))
        components.queryItems = queryItems
        guard let resolvedURL = components.url else { return nil }

        var request = URLRequest(url: resolvedURL)
        request.timeoutInterval = config.connectionTimeout
        request.setValue(
            "Bearer \(config.authToken)",
            forHTTPHeaderField: "Authorization"
        )

        let closeObserver = CloseObserver(
            requestId: requestId, sessionId: sessionId, generation: generation
        )
        let session = URLSession(
            configuration: .ephemeral,
            delegate: closeObserver,
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: request)
        return AudioRealtimeAgentTransport(
            session: session, task: task,
            sessionId: sessionId, requestId: requestId, generation: generation,
            closeObserver: closeObserver
        )
    }

    // MARK: - Send

    /// Send an Agent uplink frame.
    ///
    /// **F2 fix**: The log uses `AudioRealtimeAgentCodec.logTag(_:)` which
    /// emits only type + identity fields — never the raw JSON payload. This
    /// keeps token bytes, raw audio, and other sensitive data out of the
    /// Apple unified log even at `.debug` level.
    func send(
        _ frame: AudioRealtimeAgentCodec.UplinkFrame,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        guard !isClosed else {
            completion(NSError(
                domain: "AudioRealtimeAgentTransport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "socket already closed"]
            ))
            return
        }
        guard let text = AudioRealtimeAgentCodec.encode(frame) else {
            completion(NSError(
                domain: "AudioRealtimeAgentTransport", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "frame encode failed"]
            ))
            return
        }
        // F2: structured log tag — type + identity only, no raw payload prefix
        Self.logger.debug("\(AudioRealtimeAgentCodec.logTag(frame), privacy: .public)")
        task.send(.string(text)) { error in
            Task { @MainActor in completion(error) }
        }
    }

    // MARK: - Receive

    func receive(handler: @escaping @MainActor (DownlinkResult) -> Void) {
        guard !isClosed else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let message):
                    self.handleReceivedMessage(message, handler: handler)
                case .failure(let error):
                    let ns = error as NSError
                    Self.logger.error(
                        "agent downlink recv failed error=\(String(describing: error), privacy: .public)"
                    )
                    PhoneAgentClientLog.error(
                        module: Self.logModule,
                        event: "downlink_recv_failed",
                        requestId: self.requestId,
                        sessionId: self.sessionId,
                        detail: "domain=\(ns.domain) code=\(ns.code)"
                    )
                    handler(.error(error))
                }
            }
        }
    }

    private func handleReceivedMessage(
        _ message: URLSessionWebSocketTask.Message,
        handler: @escaping @MainActor (DownlinkResult) -> Void
    ) {
        let raw: String?
        let byteCount: Int
        switch message {
        case .string(let text):
            raw = text
            byteCount = text.utf8.count
        case .data(let data):
            raw = String(data: data, encoding: .utf8)
            byteCount = data.count
        @unknown default:
            raw = nil
            byteCount = 0
        }
        guard let raw else {
            PhoneAgentClientLog.error(
                module: Self.logModule,
                event: "downlink_frame_unknown_kind",
                requestId: requestId, sessionId: sessionId,
                detail: "bytes=\(byteCount)"
            )
            handler(.error(NSError(
                domain: "AudioRealtimeAgentTransport", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "unknown message kind"]
            )))
            // Non-terminal: keep pulling frames.
            receive(handler: handler)
            return
        }
        PhoneAgentClientLog.info(
            module: Self.logModule,
            event: "downlink_frame_received",
            requestId: requestId, sessionId: sessionId,
            detail: "bytes=\(byteCount)"
        )
        let outcome = AudioRealtimeAgentCodec.decodeOutcome(raw)
        switch outcome {
        case .event(let event):
            Self.logger.debug("RECV type event")
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_decode_ok",
                requestId: requestId, sessionId: sessionId,
                detail: "type=\(logType(for: event)) bytes=\(byteCount)"
            )
            handler(.event(event))
            receive(handler: handler)
        case .unrecognised(let type):
            Self.logger.info(
                "agent downlink unrecognised type=\(type, privacy: .public)"
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_decode_unrecognised",
                requestId: requestId, sessionId: sessionId,
                detail: "type=\(type) bytes=\(byteCount)"
            )
            handler(.unrecognised(type: type))
            receive(handler: handler)
        case .malformed:
            // ESS-525 fix #2: log, notify, and keep receiving — a single
            // bad frame no longer freezes downlink for the rest of the turn.
            Self.logger.error("agent downlink malformed frame bytes=\(byteCount)")
            PhoneAgentClientLog.error(
                module: Self.logModule,
                event: "downlink_decode_failed",
                requestId: requestId, sessionId: sessionId,
                detail: "bytes=\(byteCount)",
                code: "ERR_MALFORMED_FRAME"
            )
            handler(.malformed(bytes: byteCount))
            receive(handler: handler)
        }
    }

    // MARK: - Close

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        Self.logger.info(
            "agent socket close reason=\(reason, privacy: .public)"
        )
        PhoneAgentClientLog.info(
            module: Self.logModule,
            event: "wss_close_initiated",
            requestId: requestId, sessionId: sessionId,
            detail: "reason=\(reason)"
        )
        task.cancel(with: .goingAway, reason: reason.data(using: .utf8))
        // ESS-525 fix #1 companion: releasing the delegate queue so the
        // session and its observer do not leak between turns. We call
        // finishTasksAndInvalidate rather than invalidateAndCancel so the
        // outgoing close frame still flushes.
        session.finishTasksAndInvalidate()
    }

    private func handleSocketClosed(code: Int, reason: String?) {
        // Delivered from the URLSessionWebSocketDelegate callback below —
        // this is the authoritative WSS close code the peer / stack saw.
        PhoneAgentClientLog.info(
            module: Self.logModule,
            event: "wss_closed",
            requestId: requestId, sessionId: sessionId,
            detail: "close_code=\(code) reason=\(reason ?? "")"
        )
        Self.logger.info(
            "agent wss closed code=\(code, privacy: .public) reason=\(reason ?? "", privacy: .public)"
        )
    }

    private func logType(for event: AudioRealtimeAgentCodec.DownlinkEvent) -> String {
        switch event {
        case .ready: return "ready"
        case .audioDelta: return "audio.delta"
        case .audioDone: return "audio.done"
        case .segmentDropped: return "audio.segment_dropped"
        case .cancelAck: return "cancel.ack"
        case .error: return "error"
        case .pong: return "pong"
        case .serverPing: return "server_ping"
        }
    }
}

// MARK: - Close observer

/// URLSession delegate that captures WSS close frames so they can be logged
/// with the same request/session identity as the rest of the turn. Kept
/// package-internal — the transport is the only caller.
///
/// Delegate methods run on the URLSession's internal queue. `attach` hands
/// back the payload via a `@Sendable` closure so the transport can hop back
/// to `@MainActor` before touching its state.
final class CloseObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    typealias Callback = @Sendable (_ code: Int, _ reason: String?) -> Void

    private let identifier: String
    private let lock = NSLock()
    private var callback: Callback?

    init(requestId: String, sessionId: String, generation: Int) {
        self.identifier = "rid=\(requestId.prefix(8)) sid=\(sessionId.prefix(8)) gen=\(generation)"
    }

    func attach(_ cb: @escaping Callback) {
        lock.lock(); defer { lock.unlock() }
        callback = cb
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        lock.lock()
        let cb = callback
        lock.unlock()
        cb?(closeCode.rawValue, reasonString)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // A completed task without a preceding didCloseWith means the socket
        // failed at the TCP layer — surface it as close_code=0 so the sink
        // sees a `wss_closed` event either way.
        guard let error else { return }
        let ns = error as NSError
        lock.lock()
        let cb = callback
        lock.unlock()
        cb?(0, "transport_error:\(ns.domain)#\(ns.code)")
    }
}
