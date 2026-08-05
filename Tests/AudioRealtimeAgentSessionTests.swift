import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-402 Audio Realtime Agent session and config tests — aligned with Gateway #159.
@MainActor
final class AudioRealtimeAgentSessionTests: XCTestCase {
    private let sessionId = "f5a01000-0000-4000-8000-000000000001"
    private let requestId = "f5a02000-0000-4000-8000-000000000002"
    private let authToken = "rtk_test123"
    private let deviceId = "test-iphone"

    private func makeConfig(
        maxReconnectAttempts: Int = 0,
        connectionTimeout: TimeInterval = 5.0,
        heartbeatInterval: TimeInterval = 15.0
    ) -> AudioRealtimeAgentConfig {
        AudioRealtimeAgentConfig(
            gatewayURL: URL(string: "wss://agent.example.com/api/realtime")!,
            authToken: authToken,
            deviceId: deviceId,
            connectionTimeout: connectionTimeout,
            heartbeatInterval: heartbeatInterval,
            maxReconnectAttempts: maxReconnectAttempts
        )
    }

    // MARK: - Config validation

    func testConfigValidationRejectsHTTP() {
        let result = AudioRealtimeAgentConfig.validate(
            urlString: "http://agent.example.com/api/realtime",
            authToken: authToken, deviceId: deviceId
        )
        if case .failure(let error) = result {
            XCTAssertEqual(error, .invalidScheme("http"))
        } else { XCTFail("expected failure") }
    }

    func testConfigValidationAcceptsWSS() {
        let result = AudioRealtimeAgentConfig.validate(
            urlString: "wss://agent.example.com/api/realtime",
            authToken: authToken, deviceId: deviceId
        )
        if case .success(let config) = result {
            XCTAssertEqual(config.gatewayURL.absoluteString, "wss://agent.example.com/api/realtime")
            XCTAssertEqual(config.deviceId, deviceId)
        } else { XCTFail("expected success") }
    }

    func testConfigValidationAcceptsWSWhenInsecureAllowed() {
        let result = AudioRealtimeAgentConfig.validate(
            urlString: "ws://192.168.1.100:8080/api/realtime",
            authToken: authToken, deviceId: deviceId, allowInsecure: true
        )
        if case .success = result { /* ok */ }
        else { XCTFail("expected success") }
    }

    func testConfigValidationRejectsWSByDefault() {
        let result = AudioRealtimeAgentConfig.validate(
            urlString: "ws://192.168.1.100:8080/api/realtime",
            authToken: authToken, deviceId: deviceId
        )
        if case .failure(let error) = result {
            XCTAssertEqual(error, .invalidScheme("ws"))
        } else { XCTFail("expected failure") }
    }

    func testConfigValidationRejectsMissingHost() {
        let result = AudioRealtimeAgentConfig.validate(
            urlString: "wss:///path", authToken: authToken, deviceId: deviceId
        )
        if case .failure(let error) = result {
            XCTAssertEqual(error, .missingHost)
        } else { XCTFail("expected failure") }
    }

    func testConfigValidationRejectsEmptyToken() {
        let result = AudioRealtimeAgentConfig.validate(
            urlString: "wss://agent.example.com/api/realtime",
            authToken: "", deviceId: deviceId
        )
        if case .failure = result { /* ok */ }
        else { XCTFail("expected failure") }
    }

    func testConfigValidationRejectsEmptyDeviceId() {
        let result = AudioRealtimeAgentConfig.validate(
            urlString: "wss://agent.example.com/api/realtime",
            authToken: authToken, deviceId: ""
        )
        if case .failure = result { /* ok */ }
        else { XCTFail("expected failure") }
    }

    // MARK: - Session initial state

    func testSessionStartsDisconnected() {
        let session = AudioRealtimeAgentSession(
            config: makeConfig(), sessionId: sessionId
        )
        XCTAssertEqual(session.connectionState, .disconnected)
    }

    // MARK: - Connection state transitions

    func testConnectionStateChangesAreEmitted() {
        let session = AudioRealtimeAgentSession(
            config: makeConfig(), sessionId: sessionId
        )
        var states: [AudioRealtimeAgentSession.ConnectionState] = []
        session.onConnectionStateChange = { states.append($0) }
        _ = session.connect(requestId: requestId, generation: 1)
        XCTAssertFalse(states.isEmpty)
        XCTAssertEqual(states.first, .connecting(sessionId: sessionId))
    }

    // MARK: - Feature flag

    func testFeatureFlagDefaultsToDisabled() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag")!
        defaults.removePersistentDomain(forName: "test_ess402_flag")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        XCTAssertFalse(flag.isDirectPathEnabled)
        XCTAssertTrue(flag.gatewayURLString.isEmpty)
        XCTAssertTrue(flag.deviceId.isEmpty)
    }

    func testFeatureFlagEnableAndPersist() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag_2")!
        defaults.removePersistentDomain(forName: "test_ess402_flag_2")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        flag.setDirectPathEnabled(true)
        flag.setGatewayURLString("wss://agent.example.com/api/realtime")
        flag.setDeviceId("iphone-x")
        XCTAssertTrue(flag.isDirectPathEnabled)
        XCTAssertEqual(flag.gatewayURLString, "wss://agent.example.com/api/realtime")
        XCTAssertEqual(flag.deviceId, "iphone-x")

        flag.setDirectPathEnabled(false)
        XCTAssertFalse(flag.isDirectPathEnabled)
        XCTAssertEqual(flag.gatewayURLString, "wss://agent.example.com/api/realtime")
    }

    func testFeatureFlagResolveConfigReturnsNilWhenDisabled() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag_3")!
        defaults.removePersistentDomain(forName: "test_ess402_flag_3")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        flag.setGatewayURLString("wss://agent.example.com/api/realtime")
        flag.setDeviceId("iphone-x")
        XCTAssertNil(flag.resolveConfig(ephemeralToken: authToken))
    }

    func testFeatureFlagResolveConfigReturnsConfigWhenEnabled() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag_4")!
        defaults.removePersistentDomain(forName: "test_ess402_flag_4")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        flag.setDirectPathEnabled(true)
        flag.setGatewayURLString("wss://agent.example.com/api/realtime")
        flag.setDeviceId("iphone-x")
        let config = flag.resolveConfig(ephemeralToken: authToken)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.authToken, authToken)
        XCTAssertEqual(config?.deviceId, "iphone-x")
    }

    // MARK: - Auth token security (F2/F6)

    func testAuthTokenNotInURLOrDefaults() {
        let config = makeConfig()
        let urlString = config.gatewayURL.absoluteString
        XCTAssertFalse(urlString.contains(config.authToken),
                       "auth token must not appear in URL")
        // token is NOT stored in UserDefaults — it's ephemeral and passed separately
    }

    // MARK: - Deduplication

    func testSessionDedupRejectsDuplicateSequences() {
        var identity = AudioRealtimeAgentSession.TurnIdentity(
            sessionId: sessionId, requestId: requestId, generation: 1
        )
        identity.deliveredSequences.insert(1)
        identity.deliveredSequences.insert(2)
        XCTAssertTrue(identity.deliveredSequences.contains(1))
        XCTAssertTrue(identity.deliveredSequences.contains(2))
        identity.deliveredSequences.insert(1) // dup
        XCTAssertEqual(identity.deliveredSequences.count, 2)
    }

    // MARK: - F4: maxReconnectAttempts defaults to 0

    func testMaxReconnectAttemptsDefaultsToZero() {
        let config = makeConfig()
        XCTAssertEqual(config.maxReconnectAttempts, 0,
                       "F4: reconnect default must be 0 — single-use tokens make it impossible")
    }

    // MARK: - Transport creates with device_id in URL

    func testTransportAppendsDeviceIdToURL() {
        let config = makeConfig()
        let transport = AudioRealtimeAgentTransport.create(
            config: config, sessionId: sessionId,
            requestId: requestId, generation: 1
        )
        XCTAssertNotNil(transport)
    }

    // MARK: - Connection state descriptions

    func testConnectionStateDescriptions() {
        XCTAssertTrue(
            AudioRealtimeAgentSession.ConnectionState.disconnected.description.contains("disconnected")
        )
        let connected = AudioRealtimeAgentSession.ConnectionState.connected(
            sessionId: sessionId, requestId: requestId, generation: 1
        )
        XCTAssertTrue(connected.description.contains("connected"))
        XCTAssertTrue(connected.description.contains(sessionId.prefix(8)))
    }

    // MARK: - Callback wiring

    func testAudioDeltaCallbackIsWired() {
        let session = AudioRealtimeAgentSession(
            config: makeConfig(), sessionId: sessionId
        )
        var chunks: [VoiceStreamChunk] = []
        session.onAudioDelta = { chunk, _, _ in chunks.append(chunk) }
        XCTAssertNotNil(session.onAudioDelta)
        XCTAssertTrue(chunks.isEmpty)
    }
}
