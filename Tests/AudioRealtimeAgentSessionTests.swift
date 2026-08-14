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

    func testFeatureFlagDefaultsToEnabled() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag")!
        defaults.removePersistentDomain(forName: "test_ess402_flag")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        XCTAssertTrue(flag.isDirectPathEnabled)
        // ESS-459: default URL is the dev cluster, not empty
        XCTAssertEqual(flag.gatewayURLString, AudioRealtimeAgentFeatureFlag.devDefaultGatewayURLString)
    }

    func testGatewayValidationRejectsEveryNonWSSScheme() {
        for value in ["http://agent.example", "https://agent.example", "ws://agent.example", "not a url"] {
            XCTAssertNotNil(AudioRealtimeAgentFeatureFlag.validateGatewayURLString(value), value)
        }
        XCTAssertNil(AudioRealtimeAgentFeatureFlag.validateGatewayURLString("wss://agent.example/api/realtime"))
    }

    func testCredentialRedactionNeverContainsSecret() {
        let secret = "top-secret-long-key"
        let redacted = AudioRealtimeAgentFeatureFlag.redactedCredentialDescription(secret)
        XCTAssertFalse(redacted.contains(secret))
        XCTAssertEqual(redacted, "••••••••")
    }

    /// ESS-459: user-configured URL always takes priority over the dev default.
    func testFeatureFlagUserURLOverridesDevDefault() {
        let defaults = UserDefaults(suiteName: "test_ess459_user_override")!
        defaults.removePersistentDomain(forName: "test_ess459_user_override")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        // Fresh install → dev default
        XCTAssertEqual(flag.gatewayURLString, AudioRealtimeAgentFeatureFlag.devDefaultGatewayURLString)
        // User sets custom URL
        let customURL = "wss://staging.example.com:8444/api/realtime"
        flag.setGatewayURLString(customURL)
        XCTAssertEqual(flag.gatewayURLString, customURL)
        // After clearing UserDefaults key → back to dev default
        defaults.removeObject(forKey: AudioRealtimeAgentFeatureFlag.Key.gatewayURL)
        XCTAssertEqual(flag.gatewayURLString, AudioRealtimeAgentFeatureFlag.devDefaultGatewayURLString)
    }

    func testFeatureFlagEnableAndPersist() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag_2")!
        defaults.removePersistentDomain(forName: "test_ess402_flag_2")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        flag.setDirectPathEnabled(true)
        flag.setGatewayURLString("wss://agent.example.com/api/realtime")
        XCTAssertTrue(flag.isDirectPathEnabled)
        XCTAssertEqual(flag.gatewayURLString, "wss://agent.example.com/api/realtime")

        flag.setDirectPathEnabled(false)
        XCTAssertFalse(flag.isDirectPathEnabled)
        XCTAssertEqual(flag.gatewayURLString, "wss://agent.example.com/api/realtime")
    }

    func testFeatureFlagResolveConfigReturnsNilWhenDisabled() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag_3")!
        defaults.removePersistentDomain(forName: "test_ess402_flag_3")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        flag.setDirectPathEnabled(false)
        flag.setGatewayURLString("wss://agent.example.com/api/realtime")
        XCTAssertNil(flag.resolveConfig(ephemeralToken: authToken, deviceId: "iphone-x"))
    }

    func testFeatureFlagResolveConfigReturnsConfigWhenEnabled() {
        let defaults = UserDefaults(suiteName: "test_ess402_flag_4")!
        defaults.removePersistentDomain(forName: "test_ess402_flag_4")
        let flag = AudioRealtimeAgentFeatureFlag(defaults: defaults)
        flag.setDirectPathEnabled(true)
        flag.setGatewayURLString("wss://agent.example.com/api/realtime")
        let config = flag.resolveConfig(ephemeralToken: authToken, deviceId: "iphone-x")
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

    // MARK: - ESS-842 post-commit wait budget

    /// Manual timer so the budget is exercised without waiting real seconds.
    final class ManualResponseWaitTimer: AudioRealtimeAgentSession.ResponseWaitTimer {
        private(set) var armedAfter: TimeInterval?
        private(set) var cancelCount = 0
        private var fire: (@MainActor () -> Void)?

        nonisolated init() {}

        func arm(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) {
            armedAfter = seconds
            self.fire = fire
        }

        func cancel() {
            cancelCount += 1
            armedAfter = nil
            fire = nil
        }

        /// Fire whatever is armed, exactly as the real timer would on expiry.
        @MainActor func expire() {
            let pending = fire
            fire = nil
            pending?()
        }
    }

    private func makeCommittedSession(
        timer: ManualResponseWaitTimer,
        waitTimeout: TimeInterval = 15.0
    ) -> AudioRealtimeAgentSession {
        let session = AudioRealtimeAgentSession(
            config: AudioRealtimeAgentConfig(
                gatewayURL: URL(string: "wss://agent.example.com/api/realtime")!,
                authToken: authToken, deviceId: deviceId,
                responseWaitTimeout: waitTimeout
            ),
            sessionId: sessionId,
            responseWaitTimer: timer
        )
        session.connect(requestId: requestId, generation: 1)
        // Commit while the handshake is still open: the frame queues, and the
        // budget must NOT start until `ready` actually flushes it.
        session.commitUplink(requestId: requestId, generation: 1, finalSequence: 3)
        XCTAssertNil(timer.armedAfter, "排队中的 commit 不该起表")
        XCTAssertFalse(session.isAwaitingResponse)
        session.handleForTesting(event: .ready(
            sessionId: sessionId, requestId: requestId, generation: 1,
            responseId: "\(requestId):gen1", heartbeatIntervalMs: 15_000, protocolVersion: 1
        ))
        return session
    }

    /// 阻断项 1 的相对时序不变量：客户端等待预算必须活得比 Gateway 的
    /// committed-turn deadline + 送达余量更久，否则 Gateway 的结构化错误会发给一个
    /// 已经走掉的客户端 —— 那正是事故里只留下 1006 的形状。
    func testResponseWaitBudgetOutlastsGatewayDeadline() {
        let config = makeConfig()
        XCTAssertGreaterThan(
            config.responseWaitTimeout,
            AudioRealtimeAgentConfig.gatewayResponseDeadline
                + AudioRealtimeAgentConfig.gatewayErrorDeliveryMargin,
            "客户端必须等得过 Gateway 的 deadline 加送达余量"
        )
        // 事故实测：commit 之后客户端只被观测到存活 10.153s。预算不得短于它，
        // 否则我们会主动制造同一个「客户端先走」的形状。
        XCTAssertGreaterThanOrEqual(config.responseWaitTimeout, 10.153)
    }

    func testCommitArmsWaitBudgetOnlyWhenTheFrameLeaves() {
        let timer = ManualResponseWaitTimer()
        let session = makeCommittedSession(timer: timer)
        XCTAssertEqual(timer.armedAfter, 15.0, "commit 冲刷后才起表，且用配置的预算")
        XCTAssertTrue(session.isAwaitingResponse)
    }

    func testFirstAudioDeltaCancelsTheWaitBudget() {
        let timer = ManualResponseWaitTimer()
        let session = makeCommittedSession(timer: timer)
        session.handleForTesting(event: .audioDelta(
            sessionId: sessionId, requestId: requestId, responseId: "\(requestId):gen1",
            generation: 1, sequence: 0, sampleRate: 24_000, codec: "pcm_s16le",
            audioBytes: Data([0, 1, 2, 3])
        ))
        XCTAssertFalse(session.isAwaitingResponse)
        XCTAssertEqual(timer.cancelCount, 1)
        // 一个迟到的过期回调不得再打断已经在回答的回合。
        timer.expire()
        XCTAssertFalse(session.isAwaitingResponse)
    }

    /// Gateway 的 error 帧就是我们在等的那个「答案」——收到就撤表，不再自杀式关闭。
    func testGatewayErrorCancelsTheWaitBudget() {
        let timer = ManualResponseWaitTimer()
        let session = makeCommittedSession(timer: timer)
        session.handleForTesting(event: .error(
            code: "ERR_UPSTREAM_NO_RESPONSE", sessionId: sessionId, requestId: requestId,
            generation: 1, retriable: true, detail: "upstream produced no response"
        ))
        XCTAssertFalse(session.isAwaitingResponse)
        XCTAssertEqual(timer.cancelCount, 1)
    }

    /// 预算耗尽（连 Gateway 的错误帧都没等到）时，必须留下明确原因，
    /// 而不是事故里那条无从解释的 1006。
    func testExhaustedWaitBudgetSurfacesAnExplicitReason() {
        let timer = ManualResponseWaitTimer()
        let session = makeCommittedSession(timer: timer)
        var errors: [(String, String, Int, Bool)] = []
        session.onError = { code, rid, gen, retriable, _ in
            errors.append((code, rid, gen, retriable))
        }
        timer.expire()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.0, AudioRealtimeAgentSession.awaitResponseTimeoutCode)
        XCTAssertEqual(errors.first?.1, requestId)
        XCTAssertEqual(errors.first?.3, true, "无回答是可重试的，不是协议违约")
        XCTAssertFalse(session.isAwaitingResponse)
        XCTAssertEqual(session.connectionState, .closed)
    }
}
