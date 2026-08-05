import XCTest
@testable import WristAgentCore

/// ESS-306 / D5 Gap-6：下行语音积压上限。
/// 覆盖：深度 2/3 无抑制、深度 4/5 抑制旧条目、`.probe` 不受影响、
/// 抑制后条目仍可投递、冷启动不重复执行。
final class WatchDownlinkOutboxBacklogTests: XCTestCase {
    private var directory: URL!
    private var clock: Date!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downlink-backlog-\\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_770_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeOutbox(
        log: @escaping (WatchDownlinkLogEvent) -> Void = { _ in }
    ) throws -> WatchDownlinkOutbox {
        var counter = 0
        return try WatchDownlinkOutbox(
            directory: directory,
            now: { self.clock },
            random: { _ in 0 },
            makeId: { counter += 1; return "item-\\(counter)" },
            log: log
        )
    }

    @discardableResult
    private func enqueueSpeech(_ outbox: WatchDownlinkOutbox, requestId: String, suffix: String) throws -> WatchDownlinkItem {
        let result = try outbox.enqueueSpeech(
            requestId: requestId, messageKey: "voice_speech_envelope",
            envelope: Data("env-\\(suffix)".utf8),
            audio: Data(repeating: 0xAB, count: 1024),
            fileName: "\\(requestId)-\\(suffix).m4a"
        )
        guard case .enqueued(let item) = result else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected enqueued"])
        }
        return item
    }

    private func item(by requestId: String, in outbox: WatchDownlinkOutbox) -> WatchDownlinkItem? {
        outbox.items.first { $0.requestId == requestId }
    }

    // MARK: - 深度 ≤ limit 时无抑制

    func testDepthTwoNoSuppression() throws {
        var events: [WatchDownlinkLogEvent] = []
        let outbox = try makeOutbox(log: { events.append($0) })
        try enqueueSpeech(outbox, requestId: "r1", suffix: "a")
        try enqueueSpeech(outbox, requestId: "r2", suffix: "b")

        XCTAssertEqual(outbox.items.count, 2)
        for item in outbox.items {
            XCTAssertFalse(item.autoPlaySuppressed, "深度 2 未超 limit=3，不应抑制")
        }
        XCTAssertFalse(events.contains { if case .speechBacklogSuppressed = $0 { return true }; return false })
    }

    func testDepthThreeNoSuppression() throws {
        let outbox = try makeOutbox()
        try enqueueSpeech(outbox, requestId: "r1", suffix: "a")
        try enqueueSpeech(outbox, requestId: "r2", suffix: "b")
        try enqueueSpeech(outbox, requestId: "r3", suffix: "c")

        XCTAssertEqual(outbox.items.count, 3)
        for item in outbox.items {
            XCTAssertFalse(item.autoPlaySuppressed, "深度 3 等于 limit=3，不应抑制")
        }
    }

    // MARK: - 深度 > limit 时抑制最旧的

    func testDepthFourSuppressesOldestOne() throws {
        var events: [WatchDownlinkLogEvent] = []
        let outbox = try makeOutbox(log: { events.append($0) })

        try enqueueSpeech(outbox, requestId: "r1", suffix: "a")
        clock = clock.addingTimeInterval(1)
        let item4 = try enqueueSpeech(outbox, requestId: "r2", suffix: "b")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r3", suffix: "c")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r4", suffix: "d")

        XCTAssertEqual(outbox.items.count, 4)

        let i1 = item(by: "r1", in: outbox)!
        let i2 = item(by: "r2", in: outbox)!
        let i3 = item(by: "r3", in: outbox)!
        let i4 = item(by: "r4", in: outbox)!

        XCTAssertTrue(i1.autoPlaySuppressed, "深度 4 > limit=3，最旧的 r1 应被抑制")
        XCTAssertFalse(i2.autoPlaySuppressed, "r2 不应被抑制")
        XCTAssertFalse(i3.autoPlaySuppressed, "r3 不应被抑制")
        XCTAssertFalse(i4.autoPlaySuppressed, "r4 不应被抑制")

        let suppressedEvents = events.filter { if case .speechBacklogSuppressed = $0 { return true }; return false }
        XCTAssertEqual(suppressedEvents.count, 1)
        if case .speechBacklogSuppressed(let count, _, _) = suppressedEvents[0] {
            XCTAssertEqual(count, 1)
        }
    }

    func testDepthFiveSuppressesOldestTwo() throws {
        let outbox = try makeOutbox()

        try enqueueSpeech(outbox, requestId: "r1", suffix: "a")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r2", suffix: "b")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r3", suffix: "c")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r4", suffix: "d")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r5", suffix: "e")

        XCTAssertEqual(outbox.items.count, 5)

        XCTAssertTrue(item(by: "r1", in: outbox)!.autoPlaySuppressed)
        XCTAssertTrue(item(by: "r2", in: outbox)!.autoPlaySuppressed)
        XCTAssertFalse(item(by: "r3", in: outbox)!.autoPlaySuppressed)
        XCTAssertFalse(item(by: "r4", in: outbox)!.autoPlaySuppressed)
        XCTAssertFalse(item(by: "r5", in: outbox)!.autoPlaySuppressed)
    }

    // MARK: - 抑制后条目仍可正常投递（不丢数据）

    func testSuppressedItemCanStillBeDelivered() throws {
        let outbox = try makeOutbox()

        let item1 = try enqueueSpeech(outbox, requestId: "r1", suffix: "a")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r2", suffix: "b")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r3", suffix: "c")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(outbox, requestId: "r4", suffix: "d")

        let i1 = item(by: "r1", in: outbox)!
        XCTAssertTrue(i1.autoPlaySuppressed)
        XCTAssertEqual(i1.state, .queued, "抑制改变的是 autoPlaySuppressed 标志，不是队列状态")

        XCTAssertEqual(outbox.pendingCount(), 4)

        outbox.markInFlight(id: i1.id)
        outbox.markDelivered(id: i1.id)
        let delivered = item(by: "r1", in: outbox)!
        XCTAssertEqual(delivered.state, .delivered)
        XCTAssertTrue(delivered.autoPlaySuppressed, "抑制标志在交付后也应保留（供 Watch 侧判断）")
    }

    // MARK: - .probe 不受影响

    func testProbeItemsNotAffectedByBacklogCap() throws {
        let outbox = try makeOutbox()

        try enqueueSpeech(outbox, requestId: "r1", suffix: "a")
        try enqueueSpeech(outbox, requestId: "r2", suffix: "b")
        try enqueueSpeech(outbox, requestId: "r3", suffix: "c")
        try enqueueSpeech(outbox, requestId: "r4", suffix: "d")

        let result = try outbox.enqueueProbe(
            requestId: "probe-1", messageKey: "voice_probe",
            envelope: Data("probe-env".utf8),
            audio: Data(repeating: 0xCD, count: 512),
            fileName: "probe.m4a"
        )
        guard case .enqueued(let probeItem) = result else {
            return XCTFail("probe 应入队")
        }
        XCTAssertFalse(probeItem.autoPlaySuppressed, ".probe 不应受 speech backlog 影响")
    }

    // MARK: - 冷启动恢复后不重复执行抑制

    func testColdRestartDoesNotReExecuteSuppression() throws {
        let first = try makeOutbox()

        try enqueueSpeech(first, requestId: "r1", suffix: "a")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(first, requestId: "r2", suffix: "b")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(first, requestId: "r3", suffix: "c")
        clock = clock.addingTimeInterval(1)
        try enqueueSpeech(first, requestId: "r4", suffix: "d")

        XCTAssertEqual(first.items.filter { $0.autoPlaySuppressed }.count, 1)

        let suppressedBefore = first.items.filter { $0.autoPlaySuppressed }.count
        let reopened = try makeOutbox()
        let suppressedAfter = reopened.items.filter { $0.autoPlaySuppressed }.count

        XCTAssertEqual(reopened.items.count, 4, "条目应全部恢复")
        XCTAssertEqual(suppressedAfter, suppressedBefore,
                       "冷启动不应重新触发 backlog 抑制：标志已持久化在 index.json 中")
    }

    // MARK: - backlog 阈值只有一处定义

    func testBacklogLimitIsSingleConstant() throws {
        XCTAssertEqual(WatchDownlinkOutbox.speechAutoPlayLimit, 3)
    }
}
