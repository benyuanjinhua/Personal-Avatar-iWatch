import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-751 下行**主链路**回归。
///
/// 这批用例针对的是复审阻断项：`PendingDownlinkBufferTests` 只证明了容器算法
/// 正确，证明不了「系统会不会入队、会不会重放」。这里把消费者（对应
/// `PhoneConnectivity` → `WatchDownlinkOutbox`）做成可开关的假件，跑完整链路：
///
/// 1. 健康长流 5000 帧 → 常驻 0；
/// 2. 断连帧进入缓冲；
/// 3. 恢复后按序、**恰好一次**重放；
/// 4. 重放持续失败仍满足条数 / 字节 / 时长上限，且时长不被重放刷新。
final class RealtimeDownlinkRelayTests: XCTestCase {
    private let requestId = "33333333-0000-0000-0000-000000000001"
    private let sessionId = "44444444-0000-0000-0000-000000000001"

    /// 假消费者：`isConnected` 模拟持久 outbox 是否接得住，并记录每次投递。
    private final class FakeConsumer {
        var isConnected = true
        private(set) var sent: [Int] = []

        func send(_ envelope: RealtimeDownlinkEnvelope) -> RealtimeDownlinkDisposition {
            sent.append(envelope.sequence ?? -1)
            return isConnected ? .handled : .deferred
        }
    }

    // MARK: - 1. 健康长流不驻留

    func testHealthyLongStreamKeepsNothingResident() {
        var relay = RealtimeDownlinkRelay()
        let consumer = FakeConsumer()
        var now: TimeInterval = 1_800_000_000

        for sequence in 0..<5_000 {
            now += 0.02
            let outcome = relay.deliver(delta(sequence, bytes: 1_920), nowSeconds: now, send: consumer.send)
            XCTAssertFalse(outcome.buffered)
        }

        XCTAssertEqual(relay.pendingCount, 0, "已成功转发的帧不得保留副本")
        XCTAssertEqual(relay.pendingBytes, 0)
        XCTAssertEqual(consumer.sent.count, 5_000)
        XCTAssertTrue(relay.replay(nowSeconds: now, send: consumer.send).isIdle)
    }

    // MARK: - 2. 断连帧进入缓冲

    func testDisconnectedFramesEnterBuffer() {
        var relay = RealtimeDownlinkRelay()
        let consumer = FakeConsumer()
        var now: TimeInterval = 1_800_000_000

        consumer.isConnected = false
        for sequence in 0..<4 {
            now += 0.02
            XCTAssertTrue(relay.deliver(delta(sequence, bytes: 640), nowSeconds: now, send: consumer.send).buffered)
        }

        XCTAssertEqual(relay.pendingCount, 4)
        XCTAssertEqual(relay.pendingBytes, 4 * 640)
    }

    /// 没有消费者（回调还没装上）等同断连，不能静默丢。
    func testMissingConsumerBuffersInsteadOfDropping() {
        var relay = RealtimeDownlinkRelay()
        XCTAssertTrue(relay.deliver(delta(0, bytes: 640), nowSeconds: 1_800_000_000, send: nil).buffered)
        XCTAssertEqual(relay.pendingCount, 1)
    }

    // MARK: - 3. 恢复后按序、恰好一次重放

    func testReplayAfterRecoveryDeliversEachFrameOnceInOrder() {
        var relay = RealtimeDownlinkRelay()
        let consumer = FakeConsumer()
        var now: TimeInterval = 1_800_000_000

        // 连通：前两帧直接送达，不留副本。
        for sequence in 0..<2 {
            now += 0.02
            relay.deliver(delta(sequence, bytes: 640), nowSeconds: now, send: consumer.send)
        }
        // 断连：接下来四帧进缓冲。
        consumer.isConnected = false
        for sequence in 2..<6 {
            now += 0.02
            relay.deliver(delta(sequence, bytes: 640), nowSeconds: now, send: consumer.send)
        }
        XCTAssertEqual(consumer.sent, [0, 1, 2, 3, 4, 5], "断连时也要先尝试投递一次")

        // 恢复：重放一次，按序补投，缓冲清空。
        consumer.isConnected = true
        let outcome = relay.replay(nowSeconds: now + 1, send: consumer.send)
        XCTAssertEqual(outcome, .init(attempted: 4, handled: 4, rebuffered: 0, dropped: 0))
        XCTAssertEqual(consumer.sent, [0, 1, 2, 3, 4, 5, 2, 3, 4, 5], "补投必须按原序")
        XCTAssertEqual(relay.pendingCount, 0)

        // 第二次重放不得重复投递。
        XCTAssertTrue(relay.replay(nowSeconds: now + 2, send: consumer.send).isIdle)
        XCTAssertEqual(consumer.sent.count, 10, "已接手的帧不得二次投递")
    }

    /// 回合切换（新的 stream.start）必须丢掉上一轮待送帧，重放不得跨回合。
    func testDiscardAllDropsPreviousTurnFrames() {
        var relay = RealtimeDownlinkRelay()
        let consumer = FakeConsumer()
        consumer.isConnected = false
        for sequence in 0..<3 {
            relay.deliver(delta(sequence, bytes: 640), nowSeconds: 1_800_000_000, send: consumer.send)
        }

        XCTAssertEqual(relay.discardAll(), 3)
        XCTAssertTrue(relay.isEmpty)

        consumer.isConnected = true
        XCTAssertTrue(relay.replay(nowSeconds: 1_800_000_001, send: consumer.send).isIdle)
        XCTAssertEqual(consumer.sent, [0, 1, 2], "上一轮的帧不得补投到新回合")
    }

    // MARK: - 4. 重放持续失败仍有界

    func testPersistentlyFailingReplayStaysWithinAllThreeLimits() {
        var relay = RealtimeDownlinkRelay(maxCount: 8, maxBytes: 16 * 1_024, maxAge: 3_600)
        let consumer = FakeConsumer()
        consumer.isConnected = false
        var now: TimeInterval = 1_800_000_000

        // 长流全程断连：5000 帧全部投递失败。
        for sequence in 0..<5_000 {
            now += 0.02
            relay.deliver(delta(sequence, bytes: 1_920), nowSeconds: now, send: consumer.send)
            XCTAssertLessThanOrEqual(relay.pendingCount, 8)
            XCTAssertLessThanOrEqual(relay.pendingBytes, 16 * 1_024)
        }
        // 字节上限先咬住：16 KiB / 1920 = 8 帧。
        XCTAssertEqual(relay.pendingCount, 8)
        XCTAssertEqual(relay.droppedCount, 5_000 - 8, "被上限截掉的条数必须可对账，不能静默")

        // 反复重放且反复失败：仍然不越界。
        for _ in 0..<20 {
            now += 1
            let outcome = relay.replay(nowSeconds: now, send: consumer.send)
            XCTAssertEqual(outcome.attempted, 8)
            XCTAssertEqual(outcome.handled, 0)
            XCTAssertEqual(outcome.rebuffered, 8)
            XCTAssertLessThanOrEqual(relay.pendingCount, 8)
            XCTAssertLessThanOrEqual(relay.pendingBytes, 16 * 1_024)
        }
        // 保留的仍是流的尾部（重连后还有意义的那一段）。
        XCTAssertEqual(relay.pendingCount, 8)
    }

    /// 时长上限不得被重放刷新——否则一条一直失败的帧可以永久驻留。
    func testReplayDoesNotResetAgeLimit() {
        var relay = RealtimeDownlinkRelay(maxCount: 64, maxBytes: 512 * 1_024, maxAge: 30)
        let consumer = FakeConsumer()
        consumer.isConnected = false
        let start: TimeInterval = 1_800_000_000

        relay.deliver(delta(0, bytes: 640), nowSeconds: start, send: consumer.send)
        XCTAssertEqual(relay.pendingCount, 1)

        // 每 10 秒重放一次且一直失败：前两轮仍在窗口内会重投，
        // 第 31 秒这一轮必须因时长上限被淘汰——重放不给它续命。
        for step in 1...2 {
            let outcome = relay.replay(nowSeconds: start + Double(step) * 10 + 1, send: consumer.send)
            XCTAssertEqual(outcome.attempted, 1, "第 \(step) 轮应仍在窗口内")
            XCTAssertEqual(outcome.rebuffered, 1)
        }
        let expiredRound = relay.replay(nowSeconds: start + 31, send: consumer.send)
        XCTAssertEqual(expiredRound, .init(attempted: 0, handled: 0, rebuffered: 0, dropped: 1))
        XCTAssertEqual(relay.pendingCount, 0, "超过 30 秒的帧不得因重放而续命")
        XCTAssertEqual(relay.droppedCount, 1)
    }

    func testExpiredFramesAreNotReplayed() {
        var relay = RealtimeDownlinkRelay(maxCount: 64, maxBytes: 512 * 1_024, maxAge: 30)
        let consumer = FakeConsumer()
        consumer.isConnected = false
        let start: TimeInterval = 1_800_000_000
        relay.deliver(delta(0, bytes: 640), nowSeconds: start, send: consumer.send)

        consumer.isConnected = true
        // 断连持续到超出时长上限：这一帧对播放已无意义，不补投，只记淘汰。
        let outcome = relay.replay(nowSeconds: start + 120, send: consumer.send)
        XCTAssertEqual(outcome, .init(attempted: 0, handled: 0, rebuffered: 0, dropped: 1))
        XCTAssertEqual(consumer.sent, [0], "过期帧不得在两分钟后补投")
        XCTAssertTrue(relay.isEmpty)
    }

    // MARK: - 字节口径

    func testPayloadBytesCountsAudioAndTranscript() {
        XCTAssertEqual(RealtimeDownlinkRelay.payloadBytes(of: delta(0, bytes: 1_920)), 1_920)
        let transcript = RealtimeDownlinkEnvelope.transcriptDelta(
            requestId: requestId, sessionId: sessionId, text: "腕语"
        )
        XCTAssertEqual(RealtimeDownlinkRelay.payloadBytes(of: transcript), "腕语".utf8.count)
    }

    // MARK: - Helpers

    private func delta(_ sequence: Int, bytes: Int) -> RealtimeDownlinkEnvelope {
        .audioDelta(
            VoiceStreamChunk(
                requestId: requestId,
                streamId: sessionId,
                direction: .downlink,
                sequence: sequence,
                capturedAtMs: 1_800_000_000_000 + Int64(sequence),
                codec: "pcm_s16le",
                sampleRate: 24_000,
                payload: Data(repeating: UInt8(sequence % 255), count: bytes)
            )
        )
    }
}
