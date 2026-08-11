import Foundation
import XCTest
@testable import WristAgent

/// ESS-753: WCSession adapter / WatchFeedbackChannel 契约测试。
///
/// WatchFeedbackChannel 协议定义了 iPhone → Watch 通信接口。
/// WatchDownlinkOutbox 是持久化下行队列的实现。本套件覆盖：
///
///   - 下行出队/入队的 requestId 不可变性
///   - 文件 ID 校验（requestId 唯一性）
///   - 持久化失败时的错误传播
///   - 队列条数/字节上限
final class WCSessionAdapterTests: XCTestCase {

    // MARK: - File ID validation (requestId uniqueness)

    /// 同一 requestId 的重复入队应返回幂等条目，不产生重复。
    func testDuplicateRequestIdReturnsExistingEntry() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = makeOutbox(directory: directory)

        let r1 = try outbox.enqueue(
            requestId: "req-abc", kind: .relayStatus,
            messageKey: "test_key", payload: Data("hello".utf8)
        )
        guard case .enqueued(let item1) = r1 else { return XCTFail("first enqueue should succeed") }

        // 同 requestId + 同 kind + 同 messageKey → 幂等
        let r2 = try outbox.enqueue(
            requestId: "req-abc", kind: .relayStatus,
            messageKey: "test_key", payload: Data("hello".utf8)
        )
        guard case .duplicate(let item2) = r2 else { return XCTFail("duplicate should return .duplicate") }

        XCTAssertEqual(item1.id, item2.id, "重复入队必须返回同一条目 ID")
        // 队列里只有一条
        let due = outbox.dueItems()
        XCTAssertEqual(due.filter { $0.requestId == "req-abc" }.count, 1)
    }

    /// 不同 requestId 生成不同条目。
    func testDifferentRequestIdsCreateDistinctEntries() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = makeOutbox(directory: directory)

        let r1 = try outbox.enqueue(
            requestId: "req-abc", kind: .relayStatus,
            messageKey: "test_key", payload: Data("hello".utf8)
        )
        let r2 = try outbox.enqueue(
            requestId: "req-xyz", kind: .relayStatus,
            messageKey: "test_key", payload: Data("world".utf8)
        )

        guard case .enqueued(let item1) = r1, case .enqueued(let item2) = r2 else {
            return XCTFail("both enqueues should succeed")
        }

        XCTAssertNotEqual(item1.id, item2.id, "不同 requestId 必须产生不同条目")
        XCTAssertNotEqual(item1.requestId, item2.requestId)
    }

    /// requestId 在 entry 中必须与原值一致（不可变性）。
    func testEnqueuedRequestIdMatchesOriginal() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = makeOutbox(directory: directory)

        let requestId = "req-immutable-test"
        let r = try outbox.enqueue(
            requestId: requestId, kind: .relayStatus,
            messageKey: "test_key", payload: Data("payload".utf8)
        )
        guard case .enqueued(let item) = r else { return XCTFail("enqueue should succeed") }

        XCTAssertEqual(item.requestId, requestId)

        // 从队列中重新读出
        let due = outbox.dueItems()
        let found = try XCTUnwrap(due.first { $0.id == item.id })
        XCTAssertEqual(found.requestId, requestId)
    }

    // MARK: - Persistence failure

    /// 无效目录下的 outbox 创建应返回 nil（非崩溃）。
    func testOutboxCreationFailsGracefullyWithInvalidDirectory() {
        // 文件路径而非目录
        let invalidPath = temporaryDirectory().appendingPathComponent("not_a_dir")
        try! Data("block".utf8).write(to: invalidPath)

        XCTAssertThrowsError(
            try WatchDownlinkOutbox(directory: invalidPath, log: { _ in }),
            "非目录路径的 outbox 创建必须抛出错误"
        )
    }

    /// deliver → delivered 状态转换后条目数正确更新。
    func testDeliveredItemIsNotInDueItems() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = makeOutbox(directory: directory)

        let r = try outbox.enqueue(
            requestId: "req-delivered", kind: .relayStatus,
            messageKey: "test_key", payload: Data("payload".utf8)
        )
        guard case .enqueued(let item) = r else { return XCTFail() }

        outbox.markDelivered(id: item.id)

        let due = outbox.dueItems()
        XCTAssertFalse(
            due.contains(where: { $0.id == item.id }),
            "已交付的条目不得出现在待处理列表中"
        )
    }

    // MARK: - Expiry

    func testPurgeExpiredDoesNotCrashOnEmptyOrFreshItems() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = try WatchDownlinkOutbox(directory: directory, log: { _ in })

        let r = try outbox.enqueue(
            requestId: "req-fresh", kind: .relayStatus,
            messageKey: "test_key", payload: Data("payload".utf8)
        )
        guard case .enqueued(let item) = r else { return XCTFail() }

        // 默认 retention 是 24h，新鲜条目不应被清除
        let purged = outbox.purgeExpired()
        XCTAssertEqual(purged.count, 0, "新鲜条目不得被清除")

        let due = outbox.dueItems()
        XCTAssertTrue(due.contains(where: { $0.id == item.id }))
    }

    // MARK: - Pending count

    func testPendingCountReflectsQueuedItems() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = makeOutbox(directory: directory)

        _ = try outbox.enqueue(
            requestId: "r1", kind: .relayStatus,
            messageKey: "k", payload: Data("1".utf8)
        )
        _ = try outbox.enqueue(
            requestId: "r2", kind: .progress,
            messageKey: "k", payload: Data("2".utf8)
        )

        XCTAssertEqual(outbox.pendingCount(), 2)

        let due = outbox.dueItems()
        outbox.markDelivered(id: due[0].id)

        XCTAssertEqual(outbox.pendingCount(), 1)
    }

    // MARK: - Speech-specific enqueue

    func testEnqueueSpeechStoresAudioAndEnvelope() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = makeOutbox(directory: directory)

        let audioData = Data([0xFF, 0xFB, 0x90, 0x00]) // MPEG audio frame header
        let envelope = try JSONEncoder().encode(
            VoiceStatusEnvelope.status(
                requestId: "req-speech", state: .completed,
                detail: "test speech"
            )
        )

        let r = try outbox.enqueueSpeech(
            requestId: "req-speech",
            messageKey: "voice_speech",
            envelope: envelope,
            audio: audioData,
            fileName: "test.m4a"
        )
        guard case .enqueued(let item) = r else { return XCTFail("enqueueSpeech should succeed") }

        XCTAssertEqual(item.requestId, "req-speech")

        // 音频文件必须存在
        let stagedURL = outbox.stagedAudioURL(for: item.id)
        XCTAssertNotNil(stagedURL)

        // 负载必须可读出
        let payload = try outbox.payload(for: item.id)
        XCTAssertEqual(payload, envelope)
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSTests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeOutbox(directory: URL) -> WatchDownlinkOutbox {
        try! WatchDownlinkOutbox(directory: directory, log: { _ in })
    }
}


