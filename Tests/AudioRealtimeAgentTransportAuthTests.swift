import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-885 regression tests for the WSS upgrade auth contract.
///
/// The 2026-08-19 real-device incident: the iPhone was logged by the Gateway
/// as `ws_upgrade_rejected ERR_TOKEN_INVALID reason=missing_bearer` despite
/// the client setting `Authorization: Bearer <token>`. Root cause was that
/// the dev universal token `rtk_dev_universal` contained underscores, which
/// the Gateway `extractBearer` regex (`rtk_[A-Za-z0-9]+`) rejects. These
/// tests pin three invariants:
///
///   1. the upgrade request actually carries `Authorization: Bearer <token>`;
///   2. a missing bearer fails closed at config resolution;
///   3. the dev universal token stays within the Gateway's bearer format.
@MainActor
final class AudioRealtimeAgentTransportAuthTests: XCTestCase {

    private func makeConfig(authToken: String) -> AudioRealtimeAgentConfig {
        AudioRealtimeAgentConfig(
            gatewayURL: URL(string: "wss://agent.example/api/realtime")!,
            authToken: authToken,
            deviceId: "dut"
        )
    }

    func testUpgradeRequestCarriesAuthorizationBearer() {
        let config = makeConfig(authToken: "rtk_devuniversal")
        let request = AudioRealtimeAgentTransport.makeUpgradeRequest(
            config: config, sessionId: "sess-1", requestId: "req-1", generation: 1
        )
        XCTAssertNotNil(request, "upgrade request must be buildable")
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer rtk_devuniversal",
            "the WSS upgrade must carry the bearer token in the Authorization header"
        )
    }

    func testUpgradeRequestCarriesScopeQueryItems() {
        let config = makeConfig(authToken: "rtk_devuniversal")
        let request = AudioRealtimeAgentTransport.makeUpgradeRequest(
            config: config, sessionId: "sess-2", requestId: "req-2", generation: 3
        )
        guard let url = request?.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            XCTFail("upgrade request must have a parseable URL")
            return
        }
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(items["device_id"], "dut")
        XCTAssertEqual(items["session_id"], "sess-2")
        XCTAssertEqual(items["request_id"], "req-2")
        XCTAssertEqual(items["generation"], "3")
    }

    func testDevUniversalTokenMatchesGatewayBearerFormat() {
        // The Gateway's extractBearer accepts exactly `rtk_[A-Za-z0-9]+`.
        // Any underscore beyond the `rtk_` prefix is rejected — this is the
        // ESS-885 root cause and must never regress.
        let token = AudioRealtimeAgentFeatureFlag.devUniversalToken
        XCTAssertNotNil(
            token.range(of: #"^rtk_[A-Za-z0-9]+$"#, options: .regularExpression),
            "devUniversalToken must match rtk_[A-Za-z0-9]+ (no underscores after rtk_)"
        )
    }

    func testEmptyAuthTokenFailsConfigValidation() {
        // A missing bearer must fail closed — an empty token must never reach
        // the WSS upgrade.
        if case .success = AudioRealtimeAgentConfig.validate(
            urlString: "wss://agent.example/api/realtime",
            authToken: "",
            deviceId: "dut"
        ) {
            XCTFail("an empty auth token must be rejected")
        }
    }
}
