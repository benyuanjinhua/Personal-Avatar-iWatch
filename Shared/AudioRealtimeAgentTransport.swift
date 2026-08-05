import Foundation
import os

/// ESS-402 WebSocket transport for the Audio Realtime Agent Gateway.
///
/// Wraps a `URLSessionWebSocketTask` speaking the Agent Gateway protocol
/// (see `AudioRealtimeAgentCodec`). The transport layer is deliberately minimal:
/// open, send, receive loop, close — with auth via the `Authorization` header.
/// Reconnection, heartbeat, and session lifecycle live in
/// `AudioRealtimeAgentSession`.
///
/// This is NOT a drop-in replacement for `PhoneRealtimeWebSocketTransport` —
/// the Agent Gateway protocol is distinct from the Bridge protocol, so the
/// caller must route through `AudioRealtimeAgentSession` instead of
/// `PhoneRealtimeSession` when the direct path is enabled.
@MainActor
final class AudioRealtimeAgentTransport {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "AgentRealtimeTransport"
    )

    /// Downlink event decoded from the Agent Gateway.
    enum DownlinkResult {
        case event(AudioRealtimeAgentCodec.DownlinkEvent)
        case unrecognised(type: String)
        case error(Error)
    }

    private let task: URLSessionWebSocketTask
    private let sessionId: String
    private var isClosed = false

    init(task: URLSessionWebSocketTask, sessionId: String) {
        self.task = task
        self.sessionId = sessionId
        task.resume()
    }

    // MARK: - Factory

    /// Create a transport from an `AudioRealtimeAgentConfig`. The Gateway URL
    /// is extended with `?session_id=<sessionId>` for routing, and the
    /// `Authorization: Bearer <token>` header carries the auth token.
    static func create(
        config: AudioRealtimeAgentConfig,
        sessionId: String
    ) -> AudioRealtimeAgentTransport? {
        guard var components = URLComponents(
            url: config.gatewayURL, resolvingAgainstBaseURL: false
        ) else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "session_id", value: sessionId))
        components.queryItems = queryItems
        guard let resolvedURL = components.url else { return nil }

        var request = URLRequest(url: resolvedURL)
        request.timeoutInterval = config.connectionTimeout
        request.setValue(
            "Bearer \(config.authToken)",
            forHTTPHeaderField: "Authorization"
        )

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        return AudioRealtimeAgentTransport(task: task, sessionId: sessionId)
    }

    // MARK: - Send

    /// Send an Agent uplink frame. The completion fires on `@MainActor`.
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
        Self.logger.debug(
            "agent uplink type=\(String(describing: text.prefix(80)), privacy: .public)"
        )
        task.send(.string(text)) { error in
            Task { @MainActor in completion(error) }
        }
    }

    // MARK: - Receive

    /// Start the receive loop. The handler is called with every decoded
    /// downlink event; when the socket closes or errors, the handler receives
    /// `.error(...)`. Unknown event types produce `.unrecognised(...)` — the
    /// caller should log and keep receiving.
    func receive(handler: @escaping @MainActor (DownlinkResult) -> Void) {
        guard !isClosed else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let message):
                    let raw: String?
                    switch message {
                    case .string(let text): raw = text
                    case .data(let data): raw = String(data: data, encoding: .utf8)
                    @unknown default: raw = nil
                    }
                    guard let raw else {
                        handler(.error(NSError(
                            domain: "AudioRealtimeAgentTransport", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "unknown message kind"]
                        )))
                        return
                    }
                    let outcome = AudioRealtimeAgentCodec.decodeOutcome(raw)
                    switch outcome {
                    case .event(let event):
                        // Log key identifiers (no token, no raw audio)
                        Self.logger.debug(
                            "agent downlink type event session_id=\(String(describing: self.sessionId), privacy: .public)"
                        )
                        handler(.event(event))
                        self.receive(handler: handler)
                    case .unrecognised(let type):
                        Self.logger.info(
                            "agent downlink unrecognised type=\(type, privacy: .public)"
                        )
                        handler(.unrecognised(type: type))
                        self.receive(handler: handler)
                    case .malformed:
                        Self.logger.error("agent downlink malformed frame")
                        handler(.error(NSError(
                            domain: "AudioRealtimeAgentTransport", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "malformed agent downlink frame"]
                        )))
                    }
                case .failure(let error):
                    Self.logger.error(
                        "agent downlink recv failed error=\(String(describing: error), privacy: .public)"
                    )
                    handler(.error(error))
                }
            }
        }
    }

    // MARK: - Close

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        Self.logger.info(
            "agent socket close reason=\(reason, privacy: .public)"
        )
        task.cancel(with: .goingAway, reason: reason.data(using: .utf8))
    }
}
