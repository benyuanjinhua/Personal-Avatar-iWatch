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
/// ### Reconnect posture (F4/F5 clarification)
///
/// - `maxReconnectAttempts` defaults to **0**: the Gateway issues single-use
///   tokens. A disconnected WSS cannot be reconnected within the same turn
///   without a fresh token from `POST /v1/realtime/session-token`. Token
///   refresh is a downstream ESS-401 integration concern. When the socket
///   drops, the session emits `.failed` and the caller falls back to the
///   existing Bridge path.
/// - No retransmission queue is maintained: reconnection is disallowed, so
///   sequence continuity across sockets is moot.
struct AudioRealtimeAgentConfig: Sendable, Equatable {
    let gatewayURL: URL
    /// Ephemeral single-use bearer token (≤ 90 s TTL). Memory only.
    let authToken: String
    /// Device identity for scope binding (sent as `device_id` URL query param).
    let deviceId: String
    let connectionTimeout: TimeInterval
    /// Default heartbeat interval matches Gateway's default (15 s).
    let heartbeatInterval: TimeInterval
    /// 0 = no reconnect. Single-use tokens make reconnect structurally
    /// impossible without a fresh token (F4).
    let maxReconnectAttempts: Int

    init(
        gatewayURL: URL,
        authToken: String,
        deviceId: String,
        connectionTimeout: TimeInterval = 10.0,
        heartbeatInterval: TimeInterval = 15.0,
        maxReconnectAttempts: Int = 0
    ) {
        self.gatewayURL = gatewayURL
        self.authToken = authToken
        self.deviceId = deviceId
        self.connectionTimeout = connectionTimeout
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
