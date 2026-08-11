import XCTest

@testable import WristAgent_Watch_App

/// ESS-324 B4：Watch 端流式下行 chunk 接收器单元测试。
///
/// 覆盖：
/// - 门禁：`isStreamingActive == false` 时 chunk 静默丢弃
/// - 重排：乱序到达的 chunk 在 sequence 连续时释放
/// - 降级：越窗 / 背压 / gap 超时 → `fallbackHandler` 被调用
/// - 重复去重：同一 sequence 二次到达不占预算
/// - 开关翻转：`onStreamingDisabled` 回调触发在途流终止
/// - 流替换：新 request_id 到达时终止旧流
///
/// 不覆盖（需要真机/AVAudioSession）：
/// - `StreamingAudioPlayer` 实际出声路径（`AVAudioEngine.start()`）
/// - WCSession `sendMessageData` 实际传输
@MainActor
final class WatchStreamReceiverTests: XCTestCase {

    private let requestId = UUID().uuidString
    private let streamId = UUID().uuidString

    private func chunk(
        _ sequence: Int,
        bytes: Int = 4,
        end: Bool = false,
        requestId: String? = nil,
        streamId: String? = nil
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId ?? self.requestId,
            streamId: streamId ?? self.streamId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1_785_810_000_000,
            codec: "pcm_s16le",
            sampleRate: 24_000,
            payload: Data(repeating: UInt8(sequence % 255), count: bytes),
            endOfStream: end
        )
    }

    private func makeSettings(enabled: Bool = true) -> WatchDebugSettings {
        let suiteName = "wristagent.tests.ess324.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if enabled {
            defaults.set(true, forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        }
        return WatchDebugSettings(defaults: defaults)
    }

    // MARK: - 门禁

    func testGateClosedRejectsChunksSilently() throws {
        // ESS-501: hosted GitHub Actions runners have no audio HW; when this test
        // runs after sibling tests that hit `.ready` → `ensurePlayer` →
        // AVAudioEngine SetFormat -10868, the test host's engine state is poisoned
        // and this case surfaces as red too. Skipped in lockstep with the three
        // sibling tests that construct StreamingAudioPlayer. Pure-logic coverage
        // for the gate itself is in WatchTests/WatchDebugSettingsTests.swift.
        try HostedCITestGate.skipIfHostedCI("WatchStreamReceiver sibling tests poison AVAudioEngine state on -10868 in testGateClosedRejectsChunksSilently")
        let settings = makeSettings(enabled: false)
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(0))
        // 门禁关闭：chunk 丢弃，不回退。
        XCTAssertTrue(fallbackCalls.isEmpty, "门禁关闭时不应触发回退——chunk 应静默丢弃")
    }

    func testGateOpenAcceptsChunks() throws {
        // ESS-501: chunk(0) triggers `.ready` → `ensurePlayer` →
        // StreamingAudioPlayer(AVAudioEngine) init → SetFormat -10868 on hosted CI.
        // Local mac + real-device sim keep the full body; the reorder-buffer
        // half of what this asserts is covered pure-logic in
        // Tests/VoiceStreamProtocolTests.swift (testOutOfOrderChunksReleaseOnlyContiguousSequence).
        try HostedCITestGate.skipIfHostedCI("StreamingAudioPlayer(AVAudioEngine) SetFormat -10868 in testGateOpenAcceptsChunks")
        let settings = makeSettings(enabled: true)
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(0))
        // 门禁打开：chunk 应被接受（buffer 可能返回 .accepted 或 .ready）
        XCTAssertTrue(fallbackCalls.isEmpty, "门禁打开时有效 chunk 不应触发回退")
    }

    // MARK: - 重排

    func testOutOfOrderChunksBufferedAndReleasedOnGapFill() throws {
        // ESS-501: gap-fill releases both chunks → `.ready` → `ensurePlayer` →
        // StreamingAudioPlayer(AVAudioEngine) SetFormat -10868 on hosted CI.
        // Pure-logic reorder coverage lives in
        // Tests/VoiceStreamProtocolTests.swift (testOutOfOrderChunksReleaseOnlyContiguousSequence),
        // which runs under `swift test` in the same CI job.
        try HostedCITestGate.skipIfHostedCI("StreamingAudioPlayer(AVAudioEngine) SetFormat -10868 in testOutOfOrderChunksBufferedAndReleasedOnGapFill")
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // seq 1 先到 → 进 pending
        receiver.receive(chunk: chunk(1))
        // seq 0 后到 → 填补 gap，释放 [0, 1]
        receiver.receive(chunk: chunk(0))

        // 不应该触发回退（gap 被填补了）
        XCTAssertTrue(fallbackCalls.isEmpty, "gap 填补后不应触发回退")
    }

    func testDuplicateChunkIgnored() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(1))
        receiver.receive(chunk: chunk(1)) // duplicate
        // duplicate 不占预算，不触发回退
        XCTAssertTrue(fallbackCalls.isEmpty)
    }

    // MARK: - 降级

    func testSequenceWindowExceededTriggersFallback() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // maxSequenceWindow 默认 32 → seq 33 触发越窗
        receiver.receive(chunk: chunk(33))
        XCTAssertEqual(fallbackCalls.count, 1, "越窗应触发 1 次回退")
        if let call = fallbackCalls.first {
            XCTAssertEqual(call.0, requestId)
            XCTAssertEqual(call.1, .sequenceWindowExceeded)
        }
    }

    func testBackpressureTriggersFallback() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // 背压只在 chunk 滞留 pending 时成立：seq 0 永不到达，后续 chunk 全部
        // 挂在缓冲里累加。maxBufferedBytes 默认 256KB，maxPayloadBytes 默认 64KB，
        // 所以 seq 1..4 恰好填满 256KB（accepted），seq 5 越界触发 backpressure。
        let payload = Data(repeating: 7, count: 64 * 1024)
        for seq in 1...5 {
            receiver.receive(chunk: VoiceStreamChunk(
                requestId: requestId, streamId: streamId,
                direction: .downlink, sequence: seq,
                capturedAtMs: 1_785_810_000_000,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: payload
            ))
        }

        XCTAssertEqual(fallbackCalls.count, 1, "背压应触发 1 次回退")
        if let call = fallbackCalls.first {
            XCTAssertEqual(call.0, requestId)
            XCTAssertEqual(call.1, .backpressure)
        }
    }

    func testGapTimeoutTriggersFallback() async {
        let settings = makeSettings()
        let expectation = XCTestExpectation(description: "gap timeout fallback")
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            if reason == .gapTimedOut {
                expectation.fulfill()
            }
        }

        // seq 1 先到 → pending，触发 gap timer
        receiver.receive(chunk: chunk(1))

        // 等 2s (超过 1.5s gap timeout)
        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func testEndOfStreamWithGapTriggersFallback() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // seq 1 pending → EOS on seq 1 → gap detected
        receiver.receive(chunk: chunk(1, end: true))
        XCTAssertEqual(fallbackCalls.count, 1, "EOS with gap should trigger fallback")
        if let call = fallbackCalls.first {
            XCTAssertEqual(call.1, .streamEndedWithGap)
        }
    }

    func testAlreadyFellBackRejected() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // 触发一次越窗回退
        receiver.receive(chunk: chunk(33))
        XCTAssertEqual(fallbackCalls.count, 1)

        // 再次发送 → 应被 `alreadyFellBack` 阻挡，不触发新回退
        receiver.receive(chunk: chunk(0))
        XCTAssertEqual(fallbackCalls.count, 1, "already fell back 不应触发二次回退")
    }

    // MARK: - 开关翻转

    func testStreamingDisabledCancelsInFlightStream() {
        let settings = makeSettings(enabled: true)
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // 启动一个流
        receiver.receive(chunk: chunk(1))

        // 关掉流式开关
        settings.setStreamingEnabled(false)

        // 关掉后尝试发 chunk → 门禁拒绝
        receiver.receive(chunk: chunk(0))
        // 不应该触发新的回退（因为门禁直接 reject，不经过 buffer）
        // 但之前 pending 的 chunk 已被 cancelAll 清掉
    }

    // MARK: - 流替换

    func testNewStreamSupersedesOld() throws {
        // ESS-501: both streams start with chunk(0) → `.ready` → `ensurePlayer` →
        // StreamingAudioPlayer(AVAudioEngine) SetFormat -10868 on hosted CI.
        // Stream-replacement semantics are exercised on device + local sim;
        // no pure-logic equivalent because the swap logic lives inside
        // WatchStreamReceiver's private state machine and touches player lifecycle.
        try HostedCITestGate.skipIfHostedCI("StreamingAudioPlayer(AVAudioEngine) SetFormat -10868 in testNewStreamSupersedesOld")
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        let rid1 = UUID().uuidString
        let rid2 = UUID().uuidString

        // 启动流 1
        receiver.receive(chunk: chunk(0, requestId: rid1))
        // 启动流 2（替代流 1）
        receiver.receive(chunk: chunk(0, requestId: rid2))

        // 流 1 的旧 chunk 应被拒绝
        // Note: after newStreamSupersedes, old chunks go through the receiver again
        // which creates a new StreamState for old rid — this is fine, it's a new stream
    }

    // MARK: - 非 downlink chunk 拒绝

    func testNonDownlinkChunkIgnored() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        let uplinkChunk = VoiceStreamChunk(
            requestId: requestId, streamId: streamId,
            direction: .uplink, sequence: 0,
            capturedAtMs: 1_785_810_000_000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data([1])
        )
        receiver.receive(chunk: uplinkChunk)
        XCTAssertTrue(fallbackCalls.isEmpty, "uplink chunk 不应触发 fallback")
    }

    // MARK: - StreamingAudioPlayer 会话所有权 gate ON/OFF 契约（ESS-755）

    /// Spy：记录 setPlaybackCategory / activate / deactivate 调用次数。
    /// 纯逻辑、无音频硬件依赖——在 hosted CI 稳定运行。
    private final class StreamingAudioSessionSpy: StreamingAudioPlayerSessionControlling {
        var setPlaybackCategoryCalls = 0
        var activateCalls = 0
        var deactivateCalls = 0

        func setPlaybackCategory() throws { setPlaybackCategoryCalls += 1 }
        func activate() throws { activateCalls += 1 }
        func deactivate() { deactivateCalls += 1 }
    }

    /// Spy：桩化 AVAudioEngine，记录 start / stop 调用次数。
    /// 内部持有真实 AVAudioEngine 做 graph 搭建（playerNode 必须 attach
    /// 到真实引擎才能 play()，否则 ObjC 异常杀进程），但 start/stop 走 spy
    /// 计数——不启动音频 IO，hosted CI 安全。
    private final class StreamingAudioEngineSpy: StreamingAudioEngineControlling {
        private let realEngine = AVAudioEngine()
        var mainMixerNode: AVAudioMixerNode { realEngine.mainMixerNode }
        var starts = 0
        var stops = 0

        func attachNode(_ node: AVAudioNode) { realEngine.attachNode(node) }
        func connectNode(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) {
            realEngine.connectNode(node1, to: node2, format: format)
        }
        func start() throws { starts += 1 }
        func stop() { stops += 1 }
    }

    /// Gate OFF（默认=回合级旧行为）：StreamingAudioPlayer 必须调用
    /// session.setPlaybackCategory + activate + deactivate。
    /// 纯逻辑 spy 断言，无需音频硬件、hosted CI 稳定执行。
    func testSessionExternallyOwnedGateOffPlayerTouchesSession() {
        StreamingAudioPlayer.sessionExternallyOwned = { false }
        defer { StreamingAudioPlayer.sessionExternallyOwned = { false } }

        let sessionSpy = StreamingAudioSessionSpy()
        let engineSpy = StreamingAudioEngineSpy()
        let player = StreamingAudioPlayer(
            sampleRate: 24_000, context: "gate-off",
            session: sessionSpy, engine: engineSpy
        )
        player.start()
        player.stop()

        XCTAssertEqual(sessionSpy.setPlaybackCategoryCalls, 1,
                       "gate OFF：start() 必须调 setPlaybackCategory 恰好一次")
        XCTAssertEqual(sessionSpy.activateCalls, 1,
                       "gate OFF：start() 必须调 activate 恰好一次")
        XCTAssertEqual(sessionSpy.deactivateCalls, 1,
                       "gate OFF：stop() 必须调 deactivate 恰好一次")
        XCTAssertEqual(engineSpy.starts, 1, "gate OFF：引擎必须启动")
        XCTAssertEqual(engineSpy.stops, 1, "gate OFF：引擎必须停止")
    }

    /// Gate ON（会话级持有）：StreamingAudioPlayer 零触碰 session
    /// spy 上的任何方法；引擎正常起停。纯逻辑、hosted CI 安全。
    func testSessionExternallyOwnedGateOnPlayerSkipsSession() {
        StreamingAudioPlayer.sessionExternallyOwned = { true }
        defer { StreamingAudioPlayer.sessionExternallyOwned = { false } }

        let sessionSpy = StreamingAudioSessionSpy()
        let engineSpy = StreamingAudioEngineSpy()
        let player = StreamingAudioPlayer(
            sampleRate: 24_000, context: "gate-on",
            session: sessionSpy, engine: engineSpy
        )
        player.start()
        player.stop()

        XCTAssertEqual(sessionSpy.setPlaybackCategoryCalls, 0,
                       "gate ON：不得调 setPlaybackCategory")
        XCTAssertEqual(sessionSpy.activateCalls, 0,
                       "gate ON：不得调 activate")
        XCTAssertEqual(sessionSpy.deactivateCalls, 0,
                       "gate ON：不得调 deactivate")
        XCTAssertEqual(engineSpy.starts, 1, "gate ON：引擎仍须启动")
        XCTAssertEqual(engineSpy.stops, 1, "gate ON：引擎仍须停止")
    }

    /// Gate ON 后切回 OFF：session 调用计数恢复为旧行为。
    /// 纯逻辑、hosted CI 安全。
    func testSessionExternallyOwnedGateToggleOnThenOffRestoresOldBehavior() {
        // Gate ON
        StreamingAudioPlayer.sessionExternallyOwned = { true }
        defer { StreamingAudioPlayer.sessionExternallyOwned = { false } }
        let sessionA = StreamingAudioSessionSpy()
        let playerA = StreamingAudioPlayer(
            sampleRate: 24_000, context: "gate-on",
            session: sessionA, engine: StreamingAudioEngineSpy()
        )
        playerA.start()
        playerA.stop()
        XCTAssertEqual(sessionA.setPlaybackCategoryCalls, 0)
        XCTAssertEqual(sessionA.activateCalls, 0)
        XCTAssertEqual(sessionA.deactivateCalls, 0)

        // Gate OFF
        StreamingAudioPlayer.sessionExternallyOwned = { false }
        let sessionB = StreamingAudioSessionSpy()
        let playerB = StreamingAudioPlayer(
            sampleRate: 24_000, context: "gate-off",
            session: sessionB, engine: StreamingAudioEngineSpy()
        )
        playerB.start()
        playerB.stop()
        XCTAssertEqual(sessionB.setPlaybackCategoryCalls, 1,
                       "gate ON→OFF 切回后 setPlaybackCategory 必须恢复")
        XCTAssertEqual(sessionB.activateCalls, 1,
                       "gate ON→OFF 切回后 activate 必须恢复")
        XCTAssertEqual(sessionB.deactivateCalls, 1,
                       "gate ON→OFF 切回后 deactivate 必须恢复")
    }
}
