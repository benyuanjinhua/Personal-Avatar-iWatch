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
/// ESS-402 requires that:
///   - The direct path is off by default (existing Bridge path unchanged).
///   - Enabling it does not mutate Bridge configuration.
///   - The flag can be toggled at runtime without an app restart.
struct AudioRealtimeAgentFeatureFlag {
    enum Key {
        static let directEnabled = "audio_realtime_agent_direct_enabled"
        static let gatewayURL = "audio_realtime_agent_gateway_url"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the Audio Realtime Agent direct path is enabled. Defaults to
    /// `false` — the existing Bridge path is the safe default.
    var isDirectPathEnabled: Bool {
        defaults.bool(forKey: Key.directEnabled)
    }

    /// The configured Gateway WSS URL string. May be empty when unconfigured.
    var gatewayURLString: String {
        defaults.string(forKey: Key.gatewayURL) ?? ""
    }

    /// Enable or disable the direct path. When disabled, existing Bridge
    /// configuration is untouched.
    func setDirectPathEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.directEnabled)
    }

    /// Persist the Gateway URL string. Callers must validate the URL before
    /// storing it here.
    func setGatewayURLString(_ urlString: String) {
        defaults.set(urlString, forKey: Key.gatewayURL)
    }

    /// Resolve a valid `AudioRealtimeAgentConfig` from the current flag state
    /// and Keychain. Returns `nil` when the direct path is disabled, the URL
    /// is unconfigured, or the token is missing — all of which are treated as
    /// "use Bridge fallback".
    func resolveConfig(allowInsecure: Bool = false) -> AudioRealtimeAgentConfig? {
        guard isDirectPathEnabled else { return nil }
        let urlString = gatewayURLString
        guard !urlString.isEmpty else { return nil }
        return AudioRealtimeAgentConfig.fromKeychain(
            urlString: urlString,
            allowInsecure: allowInsecure
        )
    }
}
