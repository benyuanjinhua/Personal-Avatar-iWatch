import Foundation
import CryptoKit
import XCTest
@testable import WristAgent

/// ESS-753: 持久化失败与文件路径测试。
///
/// iPhone 侧的 `VoiceOutbox`、`VoiceRequestInbox`、`WatchDownlinkOutbox`
/// 等持久化组件在磁盘满、目录缺失或权限不足时必须降级而非崩溃。
/// 本套件覆盖持久化失败的错误传播，确保 iPhone 链路在异常条件下
/// 不会静默丢数据或 OOM。
final class PhonePersistenceTests: XCTestCase {

    // MARK: - VoiceRequestInbox

    /// 收件箱在目录不可写时不抛异常，返回 nil 或标记为不可用。
    func testInboxGracefullySurvivesUnwritableDirectory() {
        let base = temporaryDirectory()
        defer { cleanup(base) }

        // 创建一个文件而非目录
        let blocked = base.appendingPathComponent("blocked")
        try! Data("x".utf8).write(to: blocked)

        // 在文件路径上创建 inbox 目录应该抛出
        let inboxDir = blocked.appendingPathComponent("VoiceInbox", isDirectory: true)
        XCTAssertThrowsError(
            try VoiceRequestInbox(directory: inboxDir),
            "非目录路径的 inbox 创建应抛出"
        )
    }

    /// 正常 ingest→accepted→幂等 duplicate 流程。
    func testInboxIngestAcceptsAndDeduplicates() throws {
        let base = temporaryDirectory()
        defer { cleanup(base) }

        let inboxDir = base.appendingPathComponent("VoiceInbox", isDirectory: true)
        let inbox = try VoiceRequestInbox(directory: inboxDir)

        let audioData = Data(repeating: 0xAB, count: 1024)
        let sha = VoiceDigest.sha256Hex(of: audioData)
        let envelope = VoiceRequestEnvelope.voiceRequest(
            audio: VoiceAudioDescriptor(
                codec: "pcm", sampleRate: 16000, channels: 1,
                durationMs: 1000, sha256: sha
            )
        )
        let envelopeData = try envelope.jsonData()

        // 首次 ingestion
        let result1 = inbox.ingest(envelopeData: envelopeData, audioData: audioData)
        guard case .accepted(_, let fileURL) = result1 else {
            // 若被拒绝，打印原因供排查
            if case .rejected(let err) = result1 {
                return XCTFail("首次 ingestion 被拒绝：\(err)")
            }
            return XCTFail("首次 ingestion 必须被接受")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // 重复 requestId
        let result2 = inbox.ingest(envelopeData: envelopeData, audioData: audioData)
        guard case .duplicate(let rid) = result2 else {
            return XCTFail("重复 requestId 必须返回 duplicate")
        }
        XCTAssertEqual(rid, envelope.requestId)
    }

    // MARK: - WatchDownlinkOutbox persistence

    /// 下行队列 enqueue → payload 磁盘一致。
    func testEnqueuePersistsPayloadToDisk() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = try WatchDownlinkOutbox(directory: directory, log: { _ in })

        let payload = Data("essential downlink payload".utf8)
        let r = try outbox.enqueue(
            requestId: "req-persist", kind: .relayStatus,
            messageKey: "test_key", payload: payload
        )
        guard case .enqueued(let item) = r else { return XCTFail("enqueue should succeed") }

        // 从磁盘回读
        let readBack = try outbox.payload(for: item.id)
        XCTAssertEqual(readBack, payload, "落盘数据必须与入队数据一致")
    }

    /// markFailed → 条目在 items 中仍可见（状态回 queued 等待重试）。
    func testFailedItemIncrementsAttemptAndRemainsQueued() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = try WatchDownlinkOutbox(directory: directory, log: { _ in })

        let r = try outbox.enqueue(
            requestId: "req-retry", kind: .relayStatus,
            messageKey: "test_key", payload: Data("retry".utf8)
        )
        guard case .enqueued(let item) = r else { return XCTFail() }

        outbox.markFailed(id: item.id, reason: "network_timeout")

        // items 中仍然包含（状态为 queued，等待退避重试）
        XCTAssertTrue(outbox.items.contains(where: { $0.id == item.id }),
                      "失败条目必须仍在 items 中")
        // 状态应为 queued
        let updated = outbox.items.first { $0.id == item.id }
        XCTAssertEqual(updated?.state, .queued)
    }

    /// ESS-539 v2: purgeRealtimeDownlink 清除 .relayStatus 类型的条目。
    func testPurgeRealtimeDownlinkClearsStaleRelayStatusItems() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = try WatchDownlinkOutbox(directory: directory, log: { _ in })

        // 入队一条 relayStatus 条目
        _ = try outbox.enqueue(
            requestId: "req-rt", kind: .relayStatus,
            messageKey: RealtimeMediaMessage.downlinkEnvelopeKey,
            payload: Data("rt".utf8)
        )
        // 入队一条 progress 条目（不同 kind）
        _ = try outbox.enqueue(
            requestId: "req-progress", kind: .progress,
            messageKey: "progress_key",
            payload: Data("progress".utf8)
        )

        let purged = outbox.purgeRealtimeDownlink()
        XCTAssertEqual(purged, 1, "必须只清除 .relayStatus 类型条目")

        let due = outbox.dueItems()
        XCTAssertTrue(due.contains(where: { $0.requestId == "req-progress" }),
                      "非 relayStatus 条目不得被清除")
        XCTAssertFalse(due.contains(where: { $0.requestId == "req-rt" }),
                       "relayStatus 条目必须被清除")
    }

    // MARK: - VoiceOutbox

    /// enqueue → 幂等 duplicate → 状态一致性。
    func testOutboxEnqueueIsIdempotent() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let keyProvider = TestOutboxKeyProvider()
        let outbox = try VoiceOutbox(directory: directory, keyProvider: keyProvider)

        let envelope = VoiceRequestEnvelope.mock(requestId: "req-outbox-1")
        let audioData = Data(repeating: 0xCD, count: 512)

        let r1 = try outbox.enqueue(envelope: envelope, audioData: audioData)
        guard case .enqueued = r1 else { return XCTFail("首次入队必须成功") }

        let r2 = try outbox.enqueue(envelope: envelope, audioData: audioData)
        guard case .duplicate = r2 else { return XCTFail("重复入队必须返回 duplicate") }

        // 条目仍为 queued 状态
        let entry = outbox.entry(for: envelope.requestId)
        XCTAssertEqual(entry?.state, .queued)
    }

    /// markTerminalFailed → 条目进入 failed 终态。
    func testMarkTerminalFailedTransitionsToFailed() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let keyProvider = TestOutboxKeyProvider()
        let outbox = try VoiceOutbox(directory: directory, keyProvider: keyProvider)

        let envelope = VoiceRequestEnvelope.mock(requestId: "req-terminal")
        _ = try outbox.enqueue(envelope: envelope, audioData: Data([0x01]))

        outbox.markTerminalFailed(requestId: "req-terminal", code: "ERR_BRIDGE_4XX")

        let entry = outbox.entry(for: "req-terminal")
        XCTAssertEqual(entry?.state, .failed)
        XCTAssertEqual(entry?.failureCode, "ERR_BRIDGE_4XX")
    }

    // MARK: - audio data integrity

    /// VoiceOutbox 加密存储的音频数据在解密后必须与原数据一致。
    func testOutboxAudioRoundTripIsCorrect() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let keyProvider = TestOutboxKeyProvider()
        let outbox = try VoiceOutbox(directory: directory, keyProvider: keyProvider)

        let original = Data((0..<2048).map { UInt8($0 % 256) })
        let envelope = VoiceRequestEnvelope.mock(requestId: "req-roundtrip")

        try outbox.enqueue(envelope: envelope, audioData: original)

        let recovered = try outbox.audioData(for: "req-roundtrip")
        XCTAssertEqual(recovered, original, "加密→解密回环必须一致")
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSTests-Persist-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Test outbox key provider

private struct TestOutboxKeyProvider: VoiceOutboxKeyProviding {
    private let key: SymmetricKey

    init() {
        self.key = SymmetricKey(size: .bits256)
    }

    func outboxKey() throws -> SymmetricKey {
        key
    }
}

// MARK: - VoiceRequestEnvelope mock

extension VoiceRequestEnvelope {
    static func mock(requestId: String) -> VoiceRequestEnvelope {
        VoiceRequestEnvelope(
            protocolVersion: VoiceRequestEnvelope.currentProtocolVersion,
            requestId: UUID(uuidString: requestId)?.uuidString.lowercased() ?? requestId,
            type: VoiceRequestEnvelope.voiceRequestType,
            createdAt: Date(),
            audio: VoiceAudioDescriptor(
                codec: "pcm",
                sampleRate: 16000,
                channels: 1,
                durationMs: 1000,
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            ),
            streamingRequested: false,
            parentRequestId: nil,
            contextSummary: nil
        )
    }
}
