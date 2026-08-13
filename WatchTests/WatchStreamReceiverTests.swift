import AVFoundation
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
/// - 顺序正确性（ESS-747）：旧流迟到分片被墓碑丢弃、同 request_id 异
///   stream_id 不得抢占、取消/回退后不得复活、墓碑有界
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
        XCTAssertEqual(receiver.activeRequestId, rid1)
        // 启动流 2（替代流 1）
        receiver.receive(chunk: chunk(0, requestId: rid2))
        XCTAssertEqual(receiver.activeRequestId, rid2, "新 request_id 应取代旧流")

        // ESS-747：流 1 的迟到分片必须被丢弃，不得把当前流换回去。
        receiver.receive(chunk: chunk(1, requestId: rid1))
        XCTAssertEqual(receiver.activeRequestId, rid2, "旧流迟到分片不得抢占当前流")
        XCTAssertTrue(fallbackCalls.isEmpty)
    }

    // MARK: - ESS-747 顺序正确性：旧流不得抢占当前流

    /// 旧流迟到：rid1 被 rid2 取代后，rid1 的后续分片只能被丢弃。
    /// 用 seq 1（pending，不释放）避免构造 `StreamingAudioPlayer`，
    /// 因此本例在 hosted CI 上也能跑，不需要 `HostedCITestGate`。
    func testLateChunkFromSupersededStreamIsRejected() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        let rid1 = UUID().uuidString
        let sid1 = UUID().uuidString
        let rid2 = UUID().uuidString
        let sid2 = UUID().uuidString

        receiver.receive(chunk: chunk(1, requestId: rid1, streamId: sid1))
        XCTAssertEqual(receiver.activeRequestId, rid1)

        receiver.receive(chunk: chunk(1, requestId: rid2, streamId: sid2))
        XCTAssertEqual(receiver.activeRequestId, rid2)
        XCTAssertEqual(receiver.activeStreamId, sid2)
        let bufferedAfterSwap = receiver.activeBufferedBytes

        // 旧流迟到分片：既不能换流，也不能进新流的 buffer。
        receiver.receive(chunk: chunk(2, bytes: 64, requestId: rid1, streamId: sid1))
        XCTAssertEqual(receiver.activeRequestId, rid2, "旧流不得复活")
        XCTAssertEqual(receiver.activeStreamId, sid2)
        XCTAssertEqual(receiver.activeBufferedBytes, bufferedAfterSwap,
                       "旧流分片不得混入当前流缓冲")
        XCTAssertTrue(fallbackCalls.isEmpty, "丢弃旧分片不应触发回退")
    }

    /// 同 request_id、异 stream_id：一个回合只有一条下行流，第二条只可能是
    /// 重传/残留 —— 丢弃，且**不得**顶掉在飞的流。
    func testSameRequestIdDifferentStreamIdRejected() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        let rid = UUID().uuidString
        let sidA = UUID().uuidString
        let sidB = UUID().uuidString

        receiver.receive(chunk: chunk(1, bytes: 8, requestId: rid, streamId: sidA))
        XCTAssertEqual(receiver.activeStreamId, sidA)
        XCTAssertEqual(receiver.activeBufferedBytes, 8)
        let serialA = receiver.activeStreamSerial

        receiver.receive(chunk: chunk(2, bytes: 16, requestId: rid, streamId: sidB))
        XCTAssertEqual(receiver.activeStreamId, sidA, "异 stream_id 不得取代当前流")
        XCTAssertEqual(receiver.activeStreamSerial, serialA, "当前流不应被重建")
        XCTAssertEqual(receiver.activeBufferedBytes, 8, "异 stream_id 分片不得进缓冲")
        XCTAssertTrue(fallbackCalls.isEmpty)
    }

    /// 回退是终局：同一 request_id 换个 stream_id 重来也不能复活这条流。
    func testFallenBackStreamCannotBeResurrectedWithNewStreamId() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        let rid = UUID().uuidString
        let sidA = UUID().uuidString
        let sidB = UUID().uuidString

        // 越窗 → 回退（该 request_id 进墓碑）
        receiver.receive(chunk: chunk(33, requestId: rid, streamId: sidA))
        XCTAssertEqual(fallbackCalls.count, 1)
        let serialAfterFallback = receiver.activeStreamSerial

        // 换 stream_id 重发 seq 0：既不许重开流，也不许二次回退。
        receiver.receive(chunk: chunk(0, requestId: rid, streamId: sidB))
        XCTAssertEqual(fallbackCalls.count, 1, "已回退的 request_id 不应二次回退")
        XCTAssertEqual(receiver.activeStreamId, sidA, "已回退的流不得被新 stream_id 重开")
        XCTAssertEqual(receiver.activeStreamSerial, serialAfterFallback, "不得重建流状态")
    }

    /// 取消是显式终结：被取消的回合不因迟到分片重开。
    func testCancelledStreamCannotRestart() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        let rid = UUID().uuidString
        receiver.receive(chunk: chunk(1, requestId: rid))
        XCTAssertEqual(receiver.activeRequestId, rid)

        receiver.cancelStream(requestId: rid)
        XCTAssertNil(receiver.activeRequestId)

        receiver.receive(chunk: chunk(2, requestId: rid))
        XCTAssertNil(receiver.activeRequestId, "已取消的 request_id 不得重开流")
        XCTAssertTrue(fallbackCalls.isEmpty)
    }

    /// 身份非法（非 UUID）的分片不得参与「谁是当前流」的判定 —— 否则一条
    /// 无法归因的垃圾分片能顶掉正在播的回答。
    func testInvalidIdentityChunkCannotSupersedeActiveStream() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        let rid = UUID().uuidString
        receiver.receive(chunk: chunk(1, requestId: rid))
        XCTAssertEqual(receiver.activeRequestId, rid)

        receiver.receive(chunk: chunk(1, requestId: "not-a-uuid", streamId: "also-not"))
        XCTAssertEqual(receiver.activeRequestId, rid, "非法身份分片不得取代当前流")
        XCTAssertTrue(fallbackCalls.isEmpty)
    }

    /// 墓碑必须有界：长会话不能靠无限增长的 Set 维持顺序正确性。
    func testRetiredLedgerIsBounded() {
        let settings = makeSettings()
        let receiver = WatchStreamReceiver(debugSettings: settings) { _, _ in }

        let total = WatchStreamReceiver.maxRetiredRequests + 8
        for _ in 0..<total {
            receiver.receive(chunk: chunk(1, requestId: UUID().uuidString,
                                          streamId: UUID().uuidString))
        }
        XCTAssertEqual(receiver.retiredRequestCount, WatchStreamReceiver.maxRetiredRequests,
                       "墓碑应按 FIFO 淘汰，不得无限增长")
    }

    // MARK: - ESS-777 复审阻断项：墓碑淘汰后旧流仍不得抢占

    /// 生产路径的回合 id 是 UUIDv7（`PushToTalkController.pressBegan`），
    /// 这里按毫秒递增构造，保证「第 N 轮比第 N-1 轮新」是确定性的，不靠时钟。
    private func turnId(msOffset: UInt64) -> String {
        let random = (0..<10).map { _ in UInt8.random(in: .min ... .max) }
        return UUIDv7.make(timestampMs: 1_785_810_000_000 + msOffset, random: random)
            .uuidString.lowercased()
    }

    /// ESS-777 阻断项 1 的确定性回归：替换次数超过墓碑上限后，**最旧那一轮**
    /// 已被 FIFO 淘汰出墓碑；此时重放它的迟到分片，当前流必须纹丝不动。
    /// 修复前这条会红——旧流不再命中墓碑，会 `retire` 当前流并自立为 active。
    func testEvictedOldTurnStillCannotPreemptCurrentStream() {
        let settings = makeSettings()
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let receiver = WatchStreamReceiver(debugSettings: settings) { id, reason in
            fallbackCalls.append((id, reason))
        }

        // 第 0 轮：之后要被淘汰出墓碑的那一轮。
        let oldestRid = turnId(msOffset: 0)
        let oldestSid = UUID().uuidString
        receiver.receive(chunk: chunk(1, requestId: oldestRid, streamId: oldestSid))
        XCTAssertEqual(receiver.activeRequestId, oldestRid)

        // 再跑 maxRetiredRequests + 1 轮，把第 0 轮挤出墓碑。
        for index in 1...(WatchStreamReceiver.maxRetiredRequests + 1) {
            receiver.receive(chunk: chunk(1, requestId: turnId(msOffset: UInt64(index)),
                                          streamId: UUID().uuidString))
        }
        XCTAssertFalse(receiver.retiredRequestCount > WatchStreamReceiver.maxRetiredRequests)

        let currentRid = receiver.activeRequestId
        let currentSid = receiver.activeStreamId
        let currentSerial = receiver.activeStreamSerial
        let currentBuffered = receiver.activeBufferedBytes

        // 重放已被淘汰的第 0 轮的迟到分片。
        receiver.receive(chunk: chunk(2, bytes: 64, requestId: oldestRid, streamId: oldestSid))

        XCTAssertEqual(receiver.activeRequestId, currentRid, "被淘汰的旧回合不得成为当前流")
        XCTAssertEqual(receiver.activeStreamId, currentSid)
        XCTAssertEqual(receiver.activeStreamSerial, currentSerial, "当前流不得被重建")
        XCTAssertEqual(receiver.activeBufferedBytes, currentBuffered, "旧分片不得混入当前流缓冲")
        XCTAssertTrue(fallbackCalls.isEmpty)
    }

    /// 水位线只挡更旧的回合，不能把合法的新回合也挡掉。
    func testNewerTurnStillSupersedesCurrentStream() {
        let settings = makeSettings()
        let receiver = WatchStreamReceiver(debugSettings: settings) { _, _ in }

        let older = turnId(msOffset: 0)
        let newer = turnId(msOffset: 5_000)
        receiver.receive(chunk: chunk(1, requestId: older, streamId: UUID().uuidString))
        receiver.receive(chunk: chunk(1, requestId: newer, streamId: UUID().uuidString))

        XCTAssertEqual(receiver.activeRequestId, newer, "更新的回合必须能取代在飞流")
        XCTAssertEqual(receiver.admittedTurnFloor, UUIDv7.turnTimestampMs(ofString: newer))
    }

    /// 不带时序的 request_id（非 UUIDv7）不得抬高水位线——否则一个随机高位
    /// 会把之后所有合法回合永久挡在门外。
    func testNonV7RequestIdDoesNotMoveTheFloor() {
        let settings = makeSettings()
        let receiver = WatchStreamReceiver(debugSettings: settings) { _, _ in }

        let v4 = UUID().uuidString  // 随机版本，非 v7
        receiver.receive(chunk: chunk(1, requestId: v4, streamId: UUID().uuidString))
        XCTAssertNil(receiver.admittedTurnFloor, "非 v7 不参与时序判定")

        // 之后的合法 v7 回合仍能正常开流。
        let v7 = turnId(msOffset: 0)
        receiver.receive(chunk: chunk(1, requestId: v7, streamId: UUID().uuidString))
        XCTAssertEqual(receiver.activeRequestId, v7)
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

    /// Spy：纯计数 player node，不碰任何音频图。
    private final class StreamingAudioPlayerNodeSpy: StreamingAudioPlayerNodeControlling {
        var plays = 0
        var stops = 0
        var scheduled = 0

        func play() { plays += 1 }
        func stop() { stops += 1 }
        func schedule(_ buffer: AVAudioPCMBuffer) { scheduled += 1 }
        func scheduleTail(_ buffer: AVAudioPCMBuffer, onConsumed: @escaping @Sendable () -> Void) {
            scheduled += 1
        }
    }

    /// Spy：桩化 AVAudioEngine，记录 start / stop 调用次数。
    ///
    /// ESS-755：这里**不得**内持真实 `AVAudioEngine`。前一版这么做过，
    /// 在无音频硬件的 hosted runner 上 `connect(_:to:format:)` 返回 -10868
    /// （kAudioUnitErr_FormatNotSupported），三条契约测试全挂
    /// （run 31675357242）。建图已收进 `makePlayerNode`，spy 直接返回计数 node。
    private final class StreamingAudioEngineSpy: StreamingAudioEngineControlling {
        let node = StreamingAudioPlayerNodeSpy()
        var starts = 0
        var stops = 0

        func makePlayerNode(format: AVAudioFormat) -> any StreamingAudioPlayerNodeControlling {
            node
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
        // ESS-748：`start()` 已改为 throws（起播失败必须可判定）。本组用例只关心
        // 会话所有权 gate 是否触碰 AVAudioSession，起播成不成功不是断言对象。
        try? player.start()
        player.stop()

        XCTAssertEqual(sessionSpy.setPlaybackCategoryCalls, 1,
                       "gate OFF：start() 必须调 setPlaybackCategory 恰好一次")
        XCTAssertEqual(sessionSpy.activateCalls, 1,
                       "gate OFF：start() 必须调 activate 恰好一次")
        XCTAssertEqual(sessionSpy.deactivateCalls, 1,
                       "gate OFF：stop() 必须调 deactivate 恰好一次")
        XCTAssertEqual(engineSpy.starts, 1, "gate OFF：引擎必须启动")
        XCTAssertEqual(engineSpy.stops, 1, "gate OFF：引擎必须停止")
        XCTAssertEqual(engineSpy.node.plays, 1, "gate OFF：playerNode 必须起播")
        XCTAssertEqual(engineSpy.node.stops, 1, "gate OFF：playerNode 必须停播")
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
        // ESS-748：`start()` 已改为 throws（起播失败必须可判定）。本组用例只关心
        // 会话所有权 gate 是否触碰 AVAudioSession，起播成不成功不是断言对象。
        try? player.start()
        player.stop()

        XCTAssertEqual(sessionSpy.setPlaybackCategoryCalls, 0,
                       "gate ON：不得调 setPlaybackCategory")
        XCTAssertEqual(sessionSpy.activateCalls, 0,
                       "gate ON：不得调 activate")
        XCTAssertEqual(sessionSpy.deactivateCalls, 0,
                       "gate ON：不得调 deactivate")
        XCTAssertEqual(engineSpy.starts, 1, "gate ON：引擎仍须启动")
        XCTAssertEqual(engineSpy.stops, 1, "gate ON：引擎仍须停止")
        // gate ON 的意义是「跳过会话、但照常出声」——出声这一半必须被守护。
        XCTAssertEqual(engineSpy.node.plays, 1, "gate ON：playerNode 仍须起播")
        XCTAssertEqual(engineSpy.node.stops, 1, "gate ON：playerNode 仍须停播")
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
        try? playerA.start()
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
        try? playerB.start()
        playerB.stop()
        XCTAssertEqual(sessionB.setPlaybackCategoryCalls, 1,
                       "gate ON→OFF 切回后 setPlaybackCategory 必须恢复")
        XCTAssertEqual(sessionB.activateCalls, 1,
                       "gate ON→OFF 切回后 activate 必须恢复")
        XCTAssertEqual(sessionB.deactivateCalls, 1,
                       "gate ON→OFF 切回后 deactivate 必须恢复")
    }
}
