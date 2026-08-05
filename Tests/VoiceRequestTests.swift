import XCTest
@testable import WristAgentCore

final class UUIDv7Tests: XCTestCase {
    func testVersionAndVariantBits() {
        let uuid = UUIDv7.generate()
        let bytes = uuid.uuid
        XCTAssertEqual(bytes.6 >> 4, 0x7, "版本位必须是 7")
        XCTAssertEqual(bytes.8 >> 6, 0b10, "变体位必须是 RFC 9562 的 10")
    }

    func testTimestampRoundTrip() {
        let timestamp: UInt64 = 1_753_920_000_123
        let uuid = UUIDv7.make(timestampMs: timestamp, random: Array(repeating: 0xFF, count: 10))
        XCTAssertEqual(UUIDv7.timestampMs(of: uuid), timestamp)
    }

    func testTimeOrdering() {
        let earlier = UUIDv7.make(timestampMs: 1_000, random: Array(repeating: 0xFF, count: 10))
        let later = UUIDv7.make(timestampMs: 2_000, random: Array(repeating: 0x00, count: 10))
        XCTAssertLessThan(earlier.uuidString, later.uuidString, "时间戳更早的 UUIDv7 字典序应更小")
    }

    func testUniqueness() {
        let ids = Set((0..<1_000).map { _ in UUIDv7.generate().uuidString })
        XCTAssertEqual(ids.count, 1_000)
    }
}

final class VoiceRequestEnvelopeTests: XCTestCase {
    private func makeEnvelope(sha256: String = String(repeating: "a", count: 64)) -> VoiceRequestEnvelope {
        VoiceRequestEnvelope.voiceRequest(
            createdAt: Date(timeIntervalSince1970: 1_753_920_000),
            audio: VoiceAudioDescriptor(codec: "aac", sampleRate: 16_000, channels: 1, durationMs: 10_000, sha256: sha256)
        )
    }

    func testJSONUsesSnakeCaseContractKeys() throws {
        let json = String(data: try makeEnvelope().jsonData(), encoding: .utf8)!
        for key in ["protocol_version", "request_id", "created_at", "sample_rate", "duration_ms", "sha256"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "缺少契约字段 \(key)：\(json)")
        }
    }

    func testRoundTrip() throws {
        let envelope = makeEnvelope()
        let decoded = try VoiceRequestEnvelope.decode(from: envelope.jsonData())
        XCTAssertEqual(decoded, envelope)
        XCTAssertNil(decoded.validate())
    }

    func testRejectsUnsupportedProtocolVersion() {
        let envelope = VoiceRequestEnvelope(
            protocolVersion: "9.9",
            requestId: UUIDv7.generate().uuidString,
            type: VoiceRequestEnvelope.voiceRequestType,
            createdAt: Date(),
            audio: makeEnvelope().audio,
            parentRequestId: nil,
            contextSummary: nil
        )
        XCTAssertEqual(envelope.validate(), .unsupportedProtocolVersion("9.9"))
    }

    func testRejectsInvalidAudio() {
        XCTAssertNotNil(makeEnvelope(sha256: "deadbeef").validate(), "短 sha256 必须被拒")
        let stereo = VoiceRequestEnvelope.voiceRequest(
            audio: VoiceAudioDescriptor(codec: "aac", sampleRate: 16_000, channels: 2, durationMs: 1_000, sha256: String(repeating: "a", count: 64))
        )
        XCTAssertNotNil(stereo.validate(), "双声道必须被拒")
        let tooLong = VoiceRequestEnvelope.voiceRequest(
            audio: VoiceAudioDescriptor(codec: "aac", sampleRate: 16_000, channels: 1, durationMs: 61_000, sha256: String(repeating: "a", count: 64))
        )
        XCTAssertNotNil(tooLong.validate(), "超过 60 秒必须被拒")
        let tooShort = VoiceRequestEnvelope.voiceRequest(
            audio: VoiceAudioDescriptor(codec: "aac", sampleRate: 16_000, channels: 1, durationMs: 60, sha256: String(repeating: "a", count: 64))
        )
        XCTAssertEqual(
            tooShort.validate(),
            .invalidAudio("duration_ms 超出 [300, 60000]"),
            "Bridge 无法处理的短录音必须在 Watch 侧拒绝"
        )
    }
}

final class VoiceRequestInboxTests: XCTestCase {
    private var directory: URL!
    private var inbox: VoiceRequestInbox!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        inbox = try VoiceRequestInbox(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRequest(audio: Data) -> (VoiceRequestEnvelope, Data) {
        let envelope = VoiceRequestEnvelope.voiceRequest(
            audio: VoiceAudioDescriptor(
                codec: "aac",
                sampleRate: 16_000,
                channels: 1,
                durationMs: 10_000,
                sha256: VoiceDigest.sha256Hex(of: audio)
            )
        )
        return (envelope, audio)
    }

    func testAcceptsValidRequestAndPersistsFile() throws {
        let (envelope, audio) = makeRequest(audio: Data("hello watch".utf8))
        guard case .accepted(let accepted, let fileURL) = inbox.ingest(envelope: envelope, audioData: audio) else {
            return XCTFail("应当接收合法请求")
        }
        XCTAssertEqual(accepted.requestId, envelope.requestId)
        XCTAssertEqual(try Data(contentsOf: fileURL), audio)
        XCTAssertEqual(inbox.entries.count, 1)
    }

    func testDuplicateRequestIsDroppedIdempotently() {
        let (envelope, audio) = makeRequest(audio: Data("same payload".utf8))
        _ = inbox.ingest(envelope: envelope, audioData: audio)
        let outcome = inbox.ingest(envelope: envelope, audioData: audio)
        XCTAssertEqual(outcome, .duplicate(requestId: envelope.requestId))
        XCTAssertEqual(inbox.entries.count, 1, "重发同一文件不能产生第二个请求")
    }

    func testChecksumMismatchIsRejectedAndNotStored() {
        let (envelope, _) = makeRequest(audio: Data("original".utf8))
        let outcome = inbox.ingest(envelope: envelope, audioData: Data("tampered".utf8))
        guard case .rejected(.checksumMismatch) = outcome else {
            return XCTFail("sha256 不一致必须拒收，实际结果：\(outcome)")
        }
        XCTAssertTrue(inbox.entries.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(envelope.requestId).m4a").path),
            "校验失败的音频不允许落盘"
        )
    }

    func testSameRequestIdDifferentContentIsConflict() {
        let (envelope, audio) = makeRequest(audio: Data("first".utf8))
        _ = inbox.ingest(envelope: envelope, audioData: audio)

        let other = Data("second".utf8)
        let conflicting = VoiceRequestEnvelope(
            protocolVersion: envelope.protocolVersion,
            requestId: envelope.requestId,
            type: envelope.type,
            createdAt: envelope.createdAt,
            audio: VoiceAudioDescriptor(
                codec: "aac",
                sampleRate: 16_000,
                channels: 1,
                durationMs: 5_000,
                sha256: VoiceDigest.sha256Hex(of: other)
            ),
            parentRequestId: nil,
            contextSummary: nil
        )
        let outcome = inbox.ingest(envelope: conflicting, audioData: other)
        XCTAssertEqual(outcome, .rejected(.requestIdConflict(requestId: envelope.requestId)))
        XCTAssertEqual(inbox.entries.count, 1)
    }

    func testDedupIndexSurvivesRelaunch() throws {
        let (envelope, audio) = makeRequest(audio: Data("persisted".utf8))
        _ = inbox.ingest(envelope: envelope, audioData: audio)

        let relaunched = try VoiceRequestInbox(directory: directory)
        let outcome = relaunched.ingest(envelope: envelope, audioData: audio)
        XCTAssertEqual(outcome, .duplicate(requestId: envelope.requestId), "去重索引必须跨进程持久化")
    }

    func testTwentyConsecutiveRequestsAllAccepted() {
        for index in 0..<20 {
            let (envelope, audio) = makeRequest(audio: Data("request-\(index)".utf8))
            guard case .accepted = inbox.ingest(envelope: envelope, audioData: audio) else {
                return XCTFail("第 \(index + 1) 次请求应当成功")
            }
        }
        XCTAssertEqual(inbox.entries.count, 20)
    }
}
