import Foundation

/// ESS-402 feature flag for the Audio Realtime Agent direct path.
///
/// When enabled, the iPhone connects directly to the Audio Realtime Agent
/// Gateway via WSS. When disabled, the system falls back to the existing
/// Mac Bridge relay path. The flag allows incremental rollout and a quick
/// revert if the direct path encounters Gateway-side issues.
///
/// The flag is backed by `UserDefaults` with a runtime override for tests. It
/// reads `audio_realtime_agent_direct_enabled` (Bool, default `true` on clean
/// install) and `audio_realtime_agent_gateway_url` (String, the WSS endpoint).
///
/// **F6**: This flag stores only the Gateway URL and routing preference in
/// UserDefaults. Device identity and its long-lived credential remain together
/// in `RelayCredentialsStore` (iPhone Keychain). The ephemeral auth token is
/// managed separately by the caller (obtained via
/// `POST /v1/realtime/session-token`) and NEVER stored here or in Keychain.
struct AudioRealtimeAgentFeatureFlag {
    enum Key {
        static let directEnabled = "audio_realtime_agent_direct_enabled"
        static let gatewayURL = "audio_realtime_agent_gateway_url"
    }

    /// ESS-447 dev-cluster Gateway URL: Jackson's Mac mini exposed via the
    /// Multica magic-workspace DNS. Real devices on the same Tailnet resolve
    /// this hostname to the Mac mini's LAN address; the TLS cert served by
    /// the Gateway is signed for this exact CN. Callers may still override
    /// via `setGatewayURLString(_:)` (e.g. staging / prod deployments).
    static let devDefaultGatewayURLString =
        "wss://jackson-macmac-mini.magic.workspace.beer:8444/api/realtime"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDirectPathEnabled: Bool {
        guard defaults.object(forKey: Key.directEnabled) != nil else { return true }
        return defaults.bool(forKey: Key.directEnabled)
    }

    /// ESS-459: returns the user-configured WSS endpoint, or the dev-cluster
    /// default (`devDefaultGatewayURLString`) when no override has been set.
    /// User values written via `setGatewayURLString(_:)` always take priority;
    /// removing the key from UserDefaults restores the dev default.
    var gatewayURLString: String {
        if let user = defaults.string(forKey: Key.gatewayURL), !user.isEmpty {
            return user
        }
        return Self.devDefaultGatewayURLString
    }

    func setDirectPathEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.directEnabled)
    }

    func setGatewayURLString(_ urlString: String) {
        defaults.set(urlString, forKey: Key.gatewayURL)
    }

    static func validateGatewayURLString(_ value: String) -> AudioRealtimeAgentConfig.ValidationError? {
        switch AudioRealtimeAgentConfig.validate(
            urlString: value.trimmingCharacters(in: .whitespacesAndNewlines),
            authToken: "validation-placeholder", deviceId: "validation-device"
        ) {
        case .success: return nil
        case .failure(let error): return error
        }
    }

    static func redactedCredentialDescription(_ credential: String) -> String {
        credential.isEmpty ? "未配置" : "••••••••"
    }

    /// Resolve a valid config from the flag state. Returns `nil` when the
    /// direct path is disabled, the URL/unconfigured, or the ephemeral
    /// token is missing (the caller must supply the token separately since
    /// it's single-use and never persisted).
    func resolveConfig(
        ephemeralToken: String,
        deviceId: String,
        allowInsecure: Bool = false
    ) -> AudioRealtimeAgentConfig? {
        guard isDirectPathEnabled else { return nil }
        let urlString = gatewayURLString
        guard !urlString.isEmpty, !deviceId.isEmpty, !ephemeralToken.isEmpty else {
            return nil
        }
        switch AudioRealtimeAgentConfig.validate(
            urlString: urlString, authToken: ephemeralToken,
            deviceId: deviceId, allowInsecure: allowInsecure
        ) {
        case .success(let config): return config
        case .failure: return nil
        }
    }
}
