import Foundation
import os

/// ESS-402 configuration for the Audio Realtime Agent Gateway WSS direct connection.
///
/// Validates the WSS URL (production requires `wss://`), reads the auth token from
/// the Keychain (in-memory only, never logged), and exposes feature-flag state so
/// callers can fall back to the existing Bridge path when the direct agent path is
/// unavailable or disabled.
struct AudioRealtimeAgentConfig: Sendable, Equatable {
    /// The Gateway WSS endpoint. Production must be `wss://`; development allows
    /// `ws://` for local testing on trusted networks.
    let gatewayURL: URL

    /// Auth token loaded from the Keychain. Never persisted to UserDefaults or
    /// written to logs.
    let authToken: String

    /// How long the client waits for a `session.created` or `heartbeat_ack`
    /// after connecting before declaring the socket dead.
    let connectionTimeout: TimeInterval

    /// Heartbeat interval in seconds. The client sends `heartbeat` and expects
    /// `heartbeat_ack` within `connectionTimeout`.
    let heartbeatInterval: TimeInterval

    /// Maximum number of reconnection attempts before declaring failure.
    /// Per the acceptance criteria: one safe reconnection before first packet,
    /// with deduplication to prevent double delivery.
    let maxReconnectAttempts: Int

    /// Initializer with sensible production defaults.
    init(
        gatewayURL: URL,
        authToken: String,
        connectionTimeout: TimeInterval = 10.0,
        heartbeatInterval: TimeInterval = 30.0,
        maxReconnectAttempts: Int = 1
    ) {
        self.gatewayURL = gatewayURL
        self.authToken = authToken
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

    /// Validate the gateway URL. Production (non-debug) rejects `ws://`; both
    /// modes reject non-absolute URLs and URLs without a host.
    ///
    /// - Parameter allowInsecure: When `true`, `ws://` is accepted (debug builds
    ///   on trusted LANs). Defaults to `false`.
    /// - Returns: The validated config, or a `ValidationError`.
    static func validate(
        urlString: String,
        authToken: String,
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
        case "wss":
            break
        case "ws":
            guard allowInsecure else {
                return .failure(.invalidScheme(scheme))
            }
        default:
            return .failure(.invalidScheme(scheme))
        }
        guard !authToken.isEmpty else {
            return .failure(.invalidScheme("missing auth token — cannot connect without credentials"))
        }
        return .success(AudioRealtimeAgentConfig(gatewayURL: url, authToken: authToken))
    }

    // MARK: - Keychain-backed token loading

    /// Attempt to load a stored agent auth token from the Keychain. Returns
    /// `nil` when no token has been saved or the read fails; callers should
    /// treat this as "direct path unavailable" and fall back to Bridge.
    static func loadTokenFromKeychain() -> String? {
        let token = SecureTokenStore.read()
        return token.isEmpty ? nil : token
    }

    /// Persist the agent auth token to the Keychain. The token is stored
    /// `AfterFirstUnlockThisDeviceOnly` — it survives background but not
    /// a device restore / full erase.
    static func saveTokenToKeychain(_ token: String) {
        SecureTokenStore.save(token)
    }

    /// Convenience: build a config from the Keychain-stored token. Returns
    /// `nil` when the token is unavailable or the URL is malformed.
    static func fromKeychain(
        urlString: String,
        allowInsecure: Bool = false
    ) -> AudioRealtimeAgentConfig? {
        guard let token = loadTokenFromKeychain(), !token.isEmpty else { return nil }
        switch validate(urlString: urlString, authToken: token, allowInsecure: allowInsecure) {
        case .success(let config): return config
        case .failure: return nil
        }
    }
}
