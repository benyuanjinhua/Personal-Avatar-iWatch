import XCTest
@testable import WristAgentCore

/// ESS-21 B1：iPhone → Watch 下行可靠投递。
/// 这些用例直接对着线上事故复现：覆盖安装后 iPhone 锁屏 → WCSession 未激活 →
/// 原实现静默 return，Mac 侧显示「已推送」而 Watch 永远收不到。
final class WatchDownlinkOutboxTests: XCTestCase {
    private var directory: URL!
    private var clock: Date!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downlink-\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_770_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeOutbox(
        retention: TimeInterval = 24 * 3600,
        log: @escaping (WatchDownlinkLogEvent) -> Void = { _ in }
    ) throws -> WatchDownlinkOutbox {
        var counter = 0
        return try WatchDownlinkOutbox(
            directory: directory,
            retention: retention,
            now: { self.clock },
            random: { _ in 0 },
            makeId: { counter += 1; return "item-\(counter)" },
            log: log
        )
    }

    private let requestId = "018f4c6e-0000-7000-8000-000000000001"

    // MARK: - 核心回归：会话不可用不得丢弃

    func testDeferredItemStaysQueuedAndIsLogged() throws {
        var events: [WatchDownlinkLogEvent] = []
        let outbox = try makeOutbox(log: { events.append($0) })
        let item = try XCTUnwrap(enqueueStatus(outbox))

        // 模拟 flush 时发现 WCSession 未激活。
        outbox.markDeferred(id: item.id, reason: "session-not-activated:activate")

        XCTAssertEqual(outbox.items.first?.state, .queued, "会话不可用时条目必须留在队列，不能被丢弃")
        XCTAssertEqual(outbox.items.first?.attemptCount, 0, "deferred 不应消耗重试预算，否则用户打开 App 后还要干等退避")
        XCTAssertEqual(outbox.dueItems().count, 1, "会话恢复后应立刻可投递")
        XCTAssertTrue(events.contains(.deferred(
            requestId: requestId, kind: .relayStatus, itemId: item.id,
            reason: "session-not-activated:activate"
        )), "延迟投递必须留痕，不能静默")
    }

    func testDeliveredOnlyAfterSystemReceipt() throws {
        let outbox = try makeOutbox()
        let item = try XCTUnwrap(enqueueStatus(outbox))

        outbox.markInFlight(id: item.id)
        XCTAssertEqual(outbox.items.first?.state, .inFlight)
        XCTAssertEqual(outbox.pendingCount(), 1, "交给系统还没回执，不算送达")

        outbox.markDelivered(id: item.id)
        XCTAssertEqual(outbox.items.first?.state, .delivered)
        XCTAssertEqual(outbox.pendingCount(), 0)
        XCTAssertThrowsError(try outbox.payload(for: item.id), "送达后载荷应删除")
    }

    func testInFlightRecoversToQueuedAcrossRelaunch() throws {
        let first = try makeOutbox()
        let item = try XCTUnwrap(enqueueStatus(first))
        first.markInFlight(id: item.id)

        // 进程被杀：没有拿到 didFinish 回执。
        let reopened = try makeOutbox()
        XCTAssertEqual(reopened.items.first?.state, .queued, "没有回执就不算送达，重启后必须重投")
        XCTAssertEqual(reopened.dueItems().count, 1)
        XCTAssertNoThrow(try reopened.payload(for: item.id), "重投所需的载荷必须还在盘上")
    }

    // MARK: - 重试与退避

    func testFailureBacksOffAndRetriesLater() throws {
        let outbox = try makeOutbox()
        let item = try XCTUnwrap(enqueueStatus(outbox))
        outbox.markInFlight(id: item.id)

        let next = try XCTUnwrap(outbox.markFailed(id: item.id, reason: "WCErrorCodeDeliveryFailed"))
        XCTAssertEqual(outbox.items.first?.state, .queued)
        XCTAssertEqual(outbox.items.first?.attemptCount, 1)
        XCTAssertEqual(outbox.items.first?.lastError, "WCErrorCodeDeliveryFailed")
        XCTAssertTrue(outbox.dueItems().isEmpty, "退避窗口内不应重复投递")
        XCTAssertEqual(outbox.dueItems(at: next).count, 1, "退避到期后必须重投")
        XCTAssertEqual(outbox.earliestNextAttempt(), next)
    }

    func testDuplicateEnvelopeIsIdempotent() throws {
        let outbox = try makeOutbox()
        _ = try enqueueStatus(outbox)
        // Bridge 快照重放会重复推同一状态，不能堆积成多条下行。
        let again = try outbox.enqueue(
            requestId: requestId, kind: .relayStatus,
            messageKey: "voice_relay_status", payload: Data("s1".utf8)
        )
        guard case .duplicate = again else { return XCTFail("同载荷重复入队应判定为 duplicate") }
        XCTAssertEqual(outbox.items.count, 1)
    }

    func testDifferentPayloadSameRequestQueuesSeparately() throws {
        let outbox = try makeOutbox()
        _ = try enqueueStatus(outbox)
        let second = try outbox.enqueue(
            requestId: requestId, kind: .relayStatus,
            messageKey: "voice_relay_status", payload: Data("s2".utf8)
        )
        guard case .enqueued = second else { return XCTFail("状态推进属于新条目，不应被当成重复") }
        XCTAssertEqual(outbox.items.count, 2)
    }

    // MARK: - 结果语音

    func testSpeechAudioIsStagedAndSurvivesCallerFileDeletion() throws {
        let outbox = try makeOutbox()
        let audio = Data(repeating: 0xAB, count: 4096)
        let result = try outbox.enqueueSpeech(
            requestId: requestId, messageKey: "voice_speech_envelope",
            envelope: Data("env".utf8), audio: audio, fileName: "\(requestId).m4a"
        )
        guard case .enqueued(let item) = result else { return XCTFail("语音应入队") }

        let staged = try XCTUnwrap(outbox.stagedAudioURL(for: item.id), "音频必须被队列自持有")
        XCTAssertEqual(try Data(contentsOf: staged), audio)
        XCTAssertEqual(
            try XCTUnwrap(outbox.item(stagedFileName: item.stagedFileName ?? "")).id, item.id,
            "必须能用 didFinish 带回的文件名反查条目"
        )

        outbox.markInFlight(id: item.id)
        outbox.markDelivered(id: item.id)
        XCTAssertNil(outbox.stagedAudioURL(for: item.id), "送达后暂存音频应删除（§8 不留存）")
    }

    func testSpeechWithDifferentAudioIsNotDeduped() throws {
        let outbox = try makeOutbox()
        _ = try outbox.enqueueSpeech(
            requestId: requestId, messageKey: "voice_speech_envelope",
            envelope: Data("env".utf8), audio: Data("a".utf8), fileName: "a.m4a"
        )
        let second = try outbox.enqueueSpeech(
            requestId: requestId, messageKey: "voice_speech_envelope",
            envelope: Data("env".utf8), audio: Data("b".utf8), fileName: "b.m4a"
        )
        guard case .enqueued = second else {
            return XCTFail("同回合换了音频内容，不能按信封摘要误判为重复")
        }
    }

    // MARK: - 过期

    func testExpiredQueuedItemIsReportedNotSilentlyDropped() throws {
        var events: [WatchDownlinkLogEvent] = []
        let outbox = try makeOutbox(retention: 60, log: { events.append($0) })
        let item = try XCTUnwrap(enqueueStatus(outbox))

        clock = clock.addingTimeInterval(120)
        let expired = outbox.purgeExpired()

        XCTAssertEqual(expired.map(\.id), [item.id])
        XCTAssertTrue(events.contains(.expired(
            requestId: requestId, kind: .relayStatus, itemId: item.id
        )), "放弃投递必须可观测")
        XCTAssertTrue(outbox.items.isEmpty)
    }

    // MARK: - 顺序

    func testDueItemsPreserveEnqueueOrder() throws {
        let outbox = try makeOutbox()
        for index in 0..<3 {
            _ = try outbox.enqueue(
                requestId: requestId, kind: .voiceStatus,
                messageKey: "voice_status_envelope", payload: Data("s\(index)".utf8)
            )
        }
        XCTAssertEqual(
            outbox.dueItems().map(\.payloadSha256).count, 3
        )
        XCTAssertEqual(outbox.dueItems().map(\.id), ["item-1", "item-2", "item-3"],
                       "Watch 时间线依赖状态顺序")
    }

    private func enqueueStatus(_ outbox: WatchDownlinkOutbox) throws -> WatchDownlinkItem? {
        let result = try outbox.enqueue(
            requestId: requestId, kind: .relayStatus,
            messageKey: "voice_relay_status", payload: Data("s1".utf8)
        )
        guard case .enqueued(let item) = result else { return nil }
        return item
    }
}
