import CryptoKit
import XCTest
@testable import WristAgentCore

private struct FixedKeyProvider: VoiceOutboxKeyProviding {
    let key: SymmetricKey
    func outboxKey() throws -> SymmetricKey { key }
}

final class RetryBackoffTests: XCTestCase {
    func testExponentialGrowthAndCapWithoutJitter() {
        let backoff = RetryBackoff(baseDelay: 2, maxDelay: 300, jitterRatio: 0)
        XCTAssertEqual(backoff.delay(forAttempt: 1), 2)
        XCTAssertEqual(backoff.delay(forAttempt: 2), 4)
        XCTAssertEqual(backoff.delay(forAttempt: 5), 32)
        XCTAssertEqual(backoff.delay(forAttempt: 20), 300, "封顶后保持 maxDelay")
    }

    func testJitterStaysWithinRatioBounds() {
        let backoff = RetryBackoff(baseDelay: 10, maxDelay: 300, jitterRatio: 0.2)
        let low = backoff.delay(forAttempt: 1) { range in range.lowerBound }
        let high = backoff.delay(forAttempt: 1) { range in range.upperBound }
        XCTAssertEqual(low, 8, accuracy: 0.001)
        XCTAssertEqual(high, 12, accuracy: 0.001)
    }
}

final class VoiceOutboxTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(size: .bits256)
    private let audio = Data("fake-aac-audio-payload-你好".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEnvelope(requestId: UUID = UUIDv7.generate(), audioData: Data? = nil) -> VoiceRequestEnvelope {
        let data = audioData ?? audio
        return VoiceRequestEnvelope.voiceRequest(
            requestId: requestId,
            createdAt: Date(timeIntervalSince1970: 1_753_920_000),
            audio: VoiceAudioDescriptor(
                codec: "aac", sampleRate: 16_000, channels: 1, durationMs: 8_200,
                sha256: VoiceDigest.sha256Hex(of: data)
            )
        )
    }

    private func makeOutbox(
        now: @escaping () -> Date = Date.init,
        retention: TimeInterval = 24 * 3600,
        jitterRatio: Double = 0
    ) throws -> VoiceOutbox {
        try VoiceOutbox(
            directory: directory,
            keyProvider: FixedKeyProvider(key: key),
            backoff: RetryBackoff(baseDelay: 2, maxDelay: 300, jitterRatio: jitterRatio),
            retention: retention,
            now: now
        )
    }

    func testEnqueueIsUniqueOnRequestId() throws {
        let outbox = try makeOutbox()
        let envelope = makeEnvelope()

        guard case .enqueued = try outbox.enqueue(envelope: envelope, audioData: audio) else {
            return XCTFail("首次入队应返回 enqueued")
        }
        guard case .duplicate(let existing) = try outbox.enqueue(envelope: envelope, audioData: audio) else {
            return XCTFail("同 request_id 重复入队应幂等返回 duplicate")
        }
        XCTAssertEqual(existing.requestId, envelope.requestId)
        XCTAssertEqual(outbox.entries.count, 1, "不产生第二个请求")
    }

    func testTerminalFailureAbsorbsDuplicateCloseAndRequestReplay() throws {
        let outbox = try makeOutbox()
        let envelope = makeEnvelope()
        _ = try outbox.enqueue(envelope: envelope, audioData: audio)
        for _ in 0..<3 { outbox.markFailed(requestId: envelope.requestId) }

        outbox.markTerminalFailed(requestId: envelope.requestId, code: "ERR_TRANSPORT")
        outbox.markTerminalFailed(requestId: envelope.requestId, code: "ERR_BAD_RESPONSE")

        let failed = try XCTUnwrap(outbox.entry(for: envelope.requestId))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.attemptCount, 3)
        XCTAssertEqual(failed.failureCode, "ERR_TRANSPORT")
        XCTAssertTrue(outbox.dueEntries(at: .distantFuture).isEmpty)
        guard case .duplicate(let replay) = try outbox.enqueue(envelope: envelope, audioData: audio) else {
            return XCTFail("终态 request_id 重放必须幂等")
        }
        XCTAssertEqual(replay.state, .failed)
        XCTAssertEqual(outbox.entries.count, 1)
    }

    func testSameRequestIdDifferentAudioIsRejected() throws {
        let outbox = try makeOutbox()
        let requestId = UUIDv7.generate()
        _ = try outbox.enqueue(envelope: makeEnvelope(requestId: requestId), audioData: audio)

        let other = Data("different-audio".utf8)
        XCTAssertThrowsError(
            try outbox.enqueue(envelope: makeEnvelope(requestId: requestId, audioData: other), audioData: other)
        ) { error in
            XCTAssertEqual(error as? VoiceOutboxError, .requestIdConflict(requestId: requestId.uuidString.lowercased()))
        }
    }

    func testAudioIsEncryptedAtRestAndRoundTrips() throws {
        let outbox = try makeOutbox()
        let envelope = makeEnvelope()
        _ = try outbox.enqueue(envelope: envelope, audioData: audio)

        let encrypted = try Data(contentsOf: directory.appendingPathComponent("\(envelope.requestId).enc"))
        XCTAssertNil(
            encrypted.range(of: audio),
            "落盘文件不得包含明文音频"
        )
        XCTAssertEqual(try outbox.audioData(for: envelope.requestId), audio, "解密后应还原原始音频")
    }

    func testTamperedCiphertextFailsClosed() throws {
        let outbox = try makeOutbox()
        let envelope = makeEnvelope()
        _ = try outbox.enqueue(envelope: envelope, audioData: audio)

        let url = directory.appendingPathComponent("\(envelope.requestId).enc")
        var tampered = try Data(contentsOf: url)
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: url)
        XCTAssertThrowsError(try outbox.audioData(for: envelope.requestId))
    }

    func testEntriesSurviveRestart() throws {
        let envelope = makeEnvelope()
        _ = try (try makeOutbox()).enqueue(envelope: envelope, audioData: audio)

        let reopened = try makeOutbox()
        XCTAssertEqual(reopened.entries.map(\.requestId), [envelope.requestId], "重启后 outbox 从磁盘恢复")
        XCTAssertEqual(try reopened.audioData(for: envelope.requestId), audio)
    }

    func testMarkFailedBacksOffAndKeepsRequestId() throws {
        var clock = Date(timeIntervalSince1970: 1_753_920_000)
        let outbox = try makeOutbox(now: { clock })
        let envelope = makeEnvelope()
        _ = try outbox.enqueue(envelope: envelope, audioData: audio)

        XCTAssertEqual(outbox.dueEntries().map(\.requestId), [envelope.requestId], "入队即到期")

        let first = outbox.markFailed(requestId: envelope.requestId)
        XCTAssertEqual(first, clock.addingTimeInterval(2))
        XCTAssertTrue(outbox.dueEntries().isEmpty, "退避期内不重试")

        clock = clock.addingTimeInterval(3)
        XCTAssertEqual(outbox.dueEntries().map(\.requestId), [envelope.requestId], "到期后同一 request_id 重新可上送")

        let second = outbox.markFailed(requestId: envelope.requestId)
        XCTAssertEqual(second, clock.addingTimeInterval(4), "第二次失败退避翻倍")
        XCTAssertEqual(outbox.entry(for: envelope.requestId)?.attemptCount, 2)
    }

    func testMarkDeliveredDeletesCiphertextButKeepsEntry() throws {
        let outbox = try makeOutbox()
        let envelope = makeEnvelope()
        _ = try outbox.enqueue(envelope: envelope, audioData: audio)

        outbox.markDelivered(requestId: envelope.requestId)

        let entry = outbox.entry(for: envelope.requestId)
        XCTAssertEqual(entry?.state, .delivered)
        XCTAssertNotNil(entry?.deliveredAt)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(envelope.requestId).enc").path),
            "成功交付后音频立即删除"
        )
        XCTAssertTrue(outbox.dueEntries().isEmpty)
    }

    func testPurgeExpiredDropsOldEntriesAndAudio() throws {
        var clock = Date(timeIntervalSince1970: 1_753_920_000)
        let outbox = try makeOutbox(now: { clock }, retention: 3600)
        let stale = makeEnvelope()
        _ = try outbox.enqueue(envelope: stale, audioData: audio)
        outbox.markFailed(requestId: stale.requestId)

        clock = clock.addingTimeInterval(2 * 3600)
        let fresh = makeEnvelope()
        _ = try outbox.enqueue(envelope: fresh, audioData: audio)

        let expired = outbox.purgeExpired()
        XCTAssertEqual(expired.map(\.requestId), [stale.requestId], "超保留期的排队条目被放弃并上报")
        XCTAssertEqual(outbox.entries.map(\.requestId), [fresh.requestId])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(stale.requestId).enc").path),
            "过期音频一并删除"
        )
    }

    func testRemoveDropsPoisonEntry() throws {
        let outbox = try makeOutbox()
        let envelope = makeEnvelope()
        _ = try outbox.enqueue(envelope: envelope, audioData: audio)

        outbox.remove(requestId: envelope.requestId)
        XCTAssertTrue(outbox.entries.isEmpty)
        XCTAssertThrowsError(try outbox.audioData(for: envelope.requestId))
    }

    func testDueEntriesAreFIFO() throws {
        var clock = Date(timeIntervalSince1970: 1_753_920_000)
        let outbox = try makeOutbox(now: { clock })
        let first = makeEnvelope()
        _ = try outbox.enqueue(envelope: first, audioData: audio)
        clock = clock.addingTimeInterval(1)
        let second = makeEnvelope()
        _ = try outbox.enqueue(envelope: second, audioData: audio)

        XCTAssertEqual(outbox.dueEntries().map(\.requestId), [first.requestId, second.requestId])
    }
}
