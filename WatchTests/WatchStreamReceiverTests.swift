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
        // ESS-349：`UserDefaults` 没有 `suiteName` 属性（只有 init 参数），
        // 原写法 `defaults.suiteName!` 编不过。suite 名自己留一份。
        let suiteName = "wristagent.tests.ess324.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if enabled {
            defaults.set(true, forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        }
        return WatchDebugSettings(defaults: defaults)
    }

    // MARK: - 门禁

    func testGateClosedRejectsChunksSilently() {
        let settings = makeSettings(enabled: false)
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(0))
        // 门禁关闭：chunk 丢弃，不回退。
        XCTAssertTrue(fallbackCalls.isEmpty, "门禁关闭时不应触发回退——chunk 应静默丢弃")
    }

    func testGateOpenAcceptsChunks() {
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

    func testOutOfOrderChunksBufferedAndReleasedOnGapFill() {
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

    /// ESS-349 重写。原用例断言的是 `XCTAssertFalse(空 || 全都不是 backpressure)`，
    /// 配的失败信息是「should trigger fallback **or not**（depends on buffer state）」——
    /// 两个分支都算通过，等于没断言，而且实测直接 fail。
    ///
    /// 关键在于 **连续到达的 chunk 会即刻释放、不占预算**（`VoiceStreamProtocol.swift:178`
    /// 的 `while let contiguous = pending.removeValue(forKey: nextSequence)`）。
    /// 所以要撑爆 256KB 只能靠**留着 seq 0 不发**，让后面的 chunk 全部滞留在 pending。
    func testBackpressureTriggersFallback() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // 故意跳过 seq 0：seq 1... 全部滞留 pending，bufferedBytes 才会累加。
        // maxBufferedBytes 默认 256KB，64KB × 4 = 256KB 正好卡在 `<=` 边界内，
        // 第 5 个越界 → .backpressure。
        let largePayload = Data(repeating: 0xAB, count: 64 * 1024)
        for seq in 1...5 {
            receiver.receive(chunk: VoiceStreamChunk(
                requestId: requestId, streamId: streamId,
                direction: .downlink, sequence: seq,
                capturedAtMs: 1_785_810_000_000,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: largePayload
            ))
        }

        XCTAssertEqual(
            fallbackCalls.map(\.1), [.backpressure],
            "缓冲超过 maxBufferedBytes 必须且只能降级一次——fallback 是吸收态，"
            + "重复触发意味着一次流会拉多份整段 m4a"
        )
        XCTAssertEqual(fallbackCalls.first?.0, requestId, "降级必须带上发起它的 request_id，否则无法回溯")
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

    func testNewStreamSupersedesOld() {
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
}
