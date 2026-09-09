import Foundation

/// ESS-402 configuration for the Audio Realtime Agent Gateway WSS direct
/// connection. Aligned with Gateway PR #159 contract.
///
/// ### Token semantics (F6 clarification)
///
/// - `authToken` is an **ephemeral** single-use bearer token with a TTL of
///   ≤ 90 s, obtained via `POST /v1/realtime/session-token` (Gateway PR #159).
///   It lives in memory only — never persisted to Keychain or UserDefaults.
/// - The long-lived device credential (used to HMAC-sign the session-token
///   request) lives in `SecureTokenStore` per the existing Bridge auth model.
///   This module does NOT store ephemeral tokens to Keychain.
///
/// ### Reconnect posture
///
/// - This low-level session still reports a failed socket immediately and does
///   not reuse its single-use token.
/// - ESS-1176 recovery lives one layer up in `PhoneRealtimeAgentTransport`:
///   while its work ledger is outstanding it mints a fresh scope-bound token,
///   reconnects the same request/session/generation, and lets the Gateway
///   replay the bounded detached-turn journal.
struct AudioRealtimeAgentConfig: Sendable, Equatable {
    let gatewayURL: URL
    /// Ephemeral single-use bearer token (≤ 90 s TTL). Memory only.
    let authToken: String
    /// Device identity for scope binding (sent as `device_id` URL query param).
    let deviceId: String
    /// Desired handshake budget. It is intentionally not reused as the
    /// lifetime of a long-lived `URLSessionWebSocketTask`.
    let connectionTimeout: TimeInterval
    /// ESS-842: how long the client keeps waiting after `audio.commit` before
    /// it gives up on its own. It must stay **longer** than the Gateway's
    /// committed-turn deadline plus delivery margin — otherwise the client
    /// leaves first and the Gateway's structured `error` frame lands on a
    /// socket nobody is reading, which is exactly the failure the incident
    /// left behind as a bare `close_code=1006`.
    ///
    /// The ordering is asserted by `AudioRealtimeAgentSessionTests`
    /// (`testResponseWaitBudgetOutlastsGatewayDeadline`) against
    /// `gatewayResponseDeadline`.
    let responseWaitTimeout: TimeInterval
    /// Default heartbeat interval matches Gateway's default (15 s).
    let heartbeatInterval: TimeInterval
    /// Low-level same-token retry count. Kept at zero because replacement
    /// sessions must mint a fresh token in `PhoneRealtimeAgentTransport`.
    let maxReconnectAttempts: Int

    /// ESS-842 client-side mirror of the Gateway's shipped
    /// `agent_response_timeout_ms` (`AudioRealtimeGateway/config.json`, 8000 ms).
    /// Kept as a named constant so the wait-budget ordering is a checked
    /// invariant instead of two numbers that silently drift apart.
    static let gatewayResponseDeadline: TimeInterval = 8.0

    /// Margin the Gateway's `error` frame needs to travel and be handled
    /// (matches `ERROR_DELIVERY_MARGIN_MS` in
    /// `AudioRealtimeGateway/test/ess842-response-deadline.test.mjs`).
    static let gatewayErrorDeliveryMargin: TimeInterval = 1.5

    /// Headroom after the authoritative turn/socket hold cap. Keeping this
    /// separate makes the ordering reviewable without duplicating 180 s.
    static let webSocketLifetimeMargin: TimeInterval = 60.0

    /// The socket must outlive the authoritative client-side turn hold. Derive
    /// it from the policy instead of copying its current 180 s value so a
    /// future policy increase cannot silently re-introduce a mid-turn cutoff.
    static let minimumWebSocketLifetime: TimeInterval =
        TimeInterval(RealtimeSocketLifetimePolicy.absoluteHoldCapMs) / 1_000
        + webSocketLifetimeMargin

    init(
        gatewayURL: URL,
        authToken: String,
        deviceId: String,
        connectionTimeout: TimeInterval = 10.0,
        responseWaitTimeout: TimeInterval = 15.0,
        heartbeatInterval: TimeInterval = 15.0,
        maxReconnectAttempts: Int = 0
    ) {
        self.gatewayURL = gatewayURL
        self.authToken = authToken
        self.deviceId = deviceId
        self.connectionTimeout = connectionTimeout
        self.responseWaitTimeout = responseWaitTimeout
        self.heartbeatInterval = heartbeatInterval
        self.maxReconnectAttempts = maxReconnectAttempts
    }

    // MARK: - URL Validation

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidScheme(String)
        case missingHost
        case notAbsolute

        var description: String {
            switch self {
            case .invalidScheme(let scheme):
                return "不支持的协议：\(scheme)。生产环境必须使用 wss://"
            case .missingHost:
                return "Gateway URL 缺少 host"
            case .notAbsolute:
                return "Gateway URL 必须是绝对地址"
            }
        }
    }

    static func validate(
        urlString: String,
        authToken: String,
        deviceId: String,
        allowInsecure: Bool = false
    ) -> Result<AudioRealtimeAgentConfig, ValidationError> {
        guard let url = URL(string: urlString) else {
            return .failure(.notAbsolute)
        }
        guard url.host != nil, !(url.host ?? "").isEmpty else {
            return .failure(.missingHost)
        }
        guard let scheme = url.scheme?.lowercased() else {
            return .failure(.invalidScheme("(none)"))
        }
        switch scheme {
        case "wss": break
        case "ws":
            guard allowInsecure else { return .failure(.invalidScheme(scheme)) }
        default:
            return .failure(.invalidScheme(scheme))
        }
        guard !authToken.isEmpty else {
            return .failure(.invalidScheme("missing auth token"))
        }
        guard !deviceId.isEmpty else {
            return .failure(.invalidScheme("missing device_id"))
        }
        return .success(AudioRealtimeAgentConfig(
            gatewayURL: url, authToken: authToken, deviceId: deviceId
        ))
    }
}
