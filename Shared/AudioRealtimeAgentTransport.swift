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
@MainActor
final class AudioRealtimeAgentTransport {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "AgentRealtimeTransport"
    )

    enum DownlinkResult {
        case event(AudioRealtimeAgentCodec.DownlinkEvent)
        case unrecognised(type: String)
        case error(Error)
    }

    private let task: URLSessionWebSocketTask
    /// Keep the owning session alive for exactly as long as the WebSocket.
    /// The direct-Agent path uses an ephemeral session (unlike the legacy
    /// Bridge path's `URLSession.shared`), so retaining only its task leaves
    /// the session lifetime implicit and can terminate an otherwise healthy
    /// WSS with an abnormal close.
    private let urlSession: URLSession?
    private let sessionId: String
    private let requestId: String
    private var isClosed = false
    private var consecutiveMalformedFrames = 0
    private static let malformedFrameLimit = 3

    init(
        task: URLSessionWebSocketTask,
        sessionId: String,
        requestId: String = "unknown",
        urlSession: URLSession? = nil
    ) {
        self.task = task
        self.sessionId = sessionId
        self.requestId = requestId
        self.urlSession = urlSession
        task.resume()
    }

    // MARK: - Factory

    /// Create a transport from an `AudioRealtimeAgentConfig`.
    ///
    /// The Gateway URL is extended with `?device_id=&session_id=&request_id=
    /// &generation=` query params for scope binding (Gateway PR #159 verifies
    /// these against the token scope on upgrade). The `Authorization: Bearer
    /// <token>` header carries the ephemeral auth token.
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

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        return AudioRealtimeAgentTransport(
            task: task, sessionId: sessionId, requestId: requestId,
            urlSession: session
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
                    Self.logger.info(
                        "downlink_frame_received request_id=\(self.requestId, privacy: .public) session_id=\(self.sessionId, privacy: .public)"
                    )
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
                        self.consecutiveMalformedFrames = 0
                        Self.logger.info(
                            "downlink_decode_succeeded request_id=\(self.requestId, privacy: .public) session_id=\(self.sessionId, privacy: .public)"
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
                        self.consecutiveMalformedFrames += 1
                        let error = NSError(
                            domain: "AudioRealtimeAgentTransport", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "malformed agent downlink frame"]
                        )
                        Self.logger.error(
                            "downlink_decode_failed request_id=\(self.requestId, privacy: .public) session_id=\(self.sessionId, privacy: .public) consecutive=\(self.consecutiveMalformedFrames, privacy: .public)"
                        )
                        if self.consecutiveMalformedFrames >= Self.malformedFrameLimit {
                            handler(.error(error))
                        } else {
                            self.receive(handler: handler)
                        }
                    }
                case .failure(let error):
                    let closeReason = self.task.closeReason.flatMap {
                        String(data: $0, encoding: .utf8)
                    } ?? "nil"
                    Self.logger.error(
                        "agent downlink recv failed request_id=\(self.requestId, privacy: .public) session_id=\(self.sessionId, privacy: .public) close_code=\(self.task.closeCode.rawValue, privacy: .public) close_reason=\(closeReason, privacy: .public) error=\(String(describing: error), privacy: .public)"
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
        urlSession?.finishTasksAndInvalidate()
    }
}
