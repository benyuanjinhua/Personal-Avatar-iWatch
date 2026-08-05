import Foundation

/// ESS-402 feature flag for the Audio Realtime Agent direct path.
///
/// When enabled, the iPhone connects directly to the Audio Realtime Agent
/// Gateway via WSS. When disabled, the system falls back to the existing
/// Mac Bridge relay path. The flag allows incremental rollout and a quick
/// revert if the direct path encounters Gateway-side issues.
///
/// The flag is backed by `UserDefaults` with a runtime override for tests. It
/// reads `audio_realtime_agent_direct_enabled` (Bool, default `false` on clean
/// install) and `audio_realtime_agent_gateway_url` (String, the WSS endpoint).
///
/// **F6**: This flag stores the Gateway URL and device identity in
/// UserDefaults. The ephemeral auth token is managed separately by the
/// caller (obtained via `POST /v1/realtime/session-token`) and NEVER stored
/// here or in Keychain. The long-lived device credential for HMAC-signing
/// the session-token request lives in the existing `SecureTokenStore`.
struct AudioRealtimeAgentFeatureFlag {
    enum Key {
        static let directEnabled = "audio_realtime_agent_direct_enabled"
        static let gatewayURL = "audio_realtime_agent_gateway_url"
        static let deviceId = "audio_realtime_agent_device_id"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDirectPathEnabled: Bool {
        defaults.bool(forKey: Key.directEnabled)
    }

    var gatewayURLString: String {
        defaults.string(forKey: Key.gatewayURL) ?? ""
    }

    var deviceId: String {
        defaults.string(forKey: Key.deviceId) ?? ""
    }

    func setDirectPathEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.directEnabled)
    }

    func setGatewayURLString(_ urlString: String) {
        defaults.set(urlString, forKey: Key.gatewayURL)
    }

    func setDeviceId(_ deviceId: String) {
        defaults.set(deviceId, forKey: Key.deviceId)
    }

    /// Resolve a valid config from the flag state. Returns `nil` when the
    /// direct path is disabled, the URL/unconfigured, or the ephemeral
    /// token is missing (the caller must supply the token separately since
    /// it's single-use and never persisted).
    func resolveConfig(
        ephemeralToken: String,
        allowInsecure: Bool = false
    ) -> AudioRealtimeAgentConfig? {
        guard isDirectPathEnabled else { return nil }
        let urlString = gatewayURLString
        let devId = deviceId
        guard !urlString.isEmpty, !devId.isEmpty, !ephemeralToken.isEmpty else {
            return nil
        }
        switch AudioRealtimeAgentConfig.validate(
            urlString: urlString, authToken: ephemeralToken,
            deviceId: devId, allowInsecure: allowInsecure
        ) {
        case .success(let config): return config
        case .failure: return nil
        }
    }
}
