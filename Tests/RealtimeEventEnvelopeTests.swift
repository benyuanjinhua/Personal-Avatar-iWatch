import XCTest
@testable import WristAgentCore

/// ESS-571: RealtimeEventEnvelope 契约测试。
///
/// 验证：
/// 1. 构造、编码、解码往返
/// 2. 工厂方法（便捷构造器）
/// 3. 合法性校验（isValid）
/// 4. 向后兼容（缺字段仍然可解码）
final class RealtimeEventEnvelopeTests: XCTestCase {

    private let convId = "11111111-1111-4111-8111-111111111111"
    private let turnId = "22222222-2222-4222-8222-222222222222"
    private let genId  = "33333333-3333-4333-8333-333333333333"
    private let respId = "44444444-4444-4444-8444-444444444444"

    // MARK: - 1. Round-trip

    func testEncodeDecodeRoundTrip() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: turnId,
            generationId: genId,
            responseId: respId,
            seq: 5,
            type: "input_audio.delta",
            createdAtMs: 1_800_000_000_000,
            payloadDict: ["audio": "dGVzdA==", "sample_rate": 16000]
        )

        guard let jsonString = envelope.encodeToString() else {
            XCTFail("编码失败")
            return
        }

        guard let decoded = RealtimeEventEnvelope.decode(from: jsonString) else {
            XCTFail("解码失败")
            return
        }

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.conversationId, convId)
        XCTAssertEqual(decoded.turnId, turnId)
        XCTAssertEqual(decoded.generationId, genId)
        XCTAssertEqual(decoded.responseId, respId)
        XCTAssertEqual(decoded.seq, 5)
        XCTAssertEqual(decoded.type, "input_audio.delta")
        XCTAssertEqual(decoded.createdAtMs, 1_800_000_000_000)

        let payloadAudio = decoded.payloadDict()["audio"] as? String
        XCTAssertEqual(payloadAudio, "dGVzdA==")
    }

    func testEncodeDecodeData() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: turnId,
            seq: 0,
            type: "conversation.open"
        )

        guard let data = envelope.encodeToData(),
              let decoded = RealtimeEventEnvelope.decode(from: data) else {
            XCTFail("Data 编解码失败")
            return
        }

        XCTAssertEqual(decoded.conversationId, convId)
        XCTAssertEqual(decoded.type, "conversation.open")
        XCTAssertNil(decoded.generationId)
        XCTAssertNil(decoded.responseId)
    }

    // MARK: - 2. Factory methods

    func testInputAudioDeltaFactory() {
        let envelope = RealtimeEventEnvelope.inputAudioDelta(
            conversationId: convId,
            turnId: turnId,
            seq: 1,
            audioBase64: "AAAA"
        )
        XCTAssertEqual(envelope.type, "input_audio.delta")
        XCTAssertEqual(envelope.conversationId, convId)
        XCTAssertEqual(envelope.turnId, turnId)
        XCTAssertEqual(envelope.seq, 1)
        XCTAssertEqual(envelope.payloadDict()["audio"] as? String, "AAAA")
        XCTAssertEqual(envelope.payloadDict()["sample_rate"] as? Int, 16_000)
        XCTAssertTrue(envelope.isValid)
    }

    func testResponseAudioDeltaFactory() {
        let envelope = RealtimeEventEnvelope.responseAudioDelta(
            conversationId: convId,
            turnId: turnId,
            generationId: genId,
            responseId: respId,
            seq: 3,
            audioBase64: "BBBB"
        )
        XCTAssertEqual(envelope.type, "response.audio.delta")
        XCTAssertEqual(envelope.generationId, genId)
        XCTAssertEqual(envelope.responseId, respId)
        XCTAssertEqual(envelope.payloadDict()["sample_rate"] as? Int, 24_000)
        XCTAssertTrue(envelope.isValid)
    }

    func testResponseCancelFactory() {
        let envelope = RealtimeEventEnvelope.responseCancel(
            conversationId: convId,
            turnId: turnId,
            generationId: genId,
            responseId: respId,
            seq: 7,
            playedBytes: 1024,
            playedDurationMs: 500,
            reason: "user_interrupt"
        )
        XCTAssertEqual(envelope.type, "response.cancel")
        XCTAssertEqual(envelope.payloadDict()["played_bytes"] as? Int, 1024)
        XCTAssertEqual(envelope.payloadDict()["played_duration_ms"] as? Int, 500)
        XCTAssertEqual(envelope.payloadDict()["reason"] as? String, "user_interrupt")
    }

    func testConversationLifecycleFactories() {
        let open = RealtimeEventEnvelope.conversationOpen(conversationId: convId)
        XCTAssertEqual(open.type, "conversation.open")
        XCTAssertEqual(open.turnId, "")
        XCTAssertEqual(open.seq, 0)

        let close = RealtimeEventEnvelope.conversationClose(
            conversationId: convId, seq: 10, reason: "timeout"
        )
        XCTAssertEqual(close.type, "conversation.close")
        XCTAssertEqual(close.payloadDict()["reason"] as? String, "timeout")

        let expire = RealtimeEventEnvelope.conversationWillExpire(
            conversationId: convId, seq: 11
        )
        XCTAssertEqual(expire.type, "conversation.will_expire")
    }

    // MARK: - 3. Validation

    func testValidEnvelope() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: turnId,
            seq: 1,
            type: "input_audio.delta",
            createdAtMs: 1_700_000_000_000
        )
        XCTAssertTrue(envelope.isValid)
    }

    func testInvalidSchemaVersion() {
        let envelope = RealtimeEventEnvelope(
            schemaVersion: 99,
            conversationId: convId,
            turnId: turnId,
            seq: 1,
            type: "test",
            createdAtMs: 1_700_000_000_000
        )
        XCTAssertFalse(envelope.isValid)
    }

    func testInvalidEventId() {
        let envelope = RealtimeEventEnvelope(
            eventId: "not-a-uuid",
            conversationId: convId,
            turnId: turnId,
            seq: 1,
            type: "test",
            createdAtMs: 1_700_000_000_000
        )
        XCTAssertFalse(envelope.isValid)
    }

    func testInvalidConversationId() {
        let envelope = RealtimeEventEnvelope(
            conversationId: "bad",
            turnId: turnId,
            seq: 1,
            type: "test",
            createdAtMs: 1_700_000_000_000
        )
        XCTAssertFalse(envelope.isValid)
    }

    func testEmptyTurnIdAllowedForConversationEvents() {
        let envelope = RealtimeEventEnvelope.conversationOpen(conversationId: convId)
        XCTAssertTrue(envelope.isValid, "conversation.open 允许空 turn_id")
    }

    func testInvalidTurnIdWhenNotEmpty() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: "not-a-uuid",
            seq: 1,
            type: "input_audio.delta",
            createdAtMs: 1_700_000_000_000
        )
        XCTAssertFalse(envelope.isValid, "非空的 turn_id 必须是合法 UUID")
    }

    func testNegativeSequence() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: turnId,
            seq: -1,
            type: "test",
            createdAtMs: 1_700_000_000_000
        )
        XCTAssertFalse(envelope.isValid)
    }

    func testEmptyType() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: turnId,
            seq: 1,
            type: "",
            createdAtMs: 1_700_000_000_000
        )
        XCTAssertFalse(envelope.isValid)
    }

    func testZeroCreatedAtMs() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: turnId,
            seq: 1,
            type: "test",
            createdAtMs: 0
        )
        XCTAssertFalse(envelope.isValid)
    }

    // MARK: - 4. Backward compatibility

    func testDecodeWithoutOptionalFields() {
        // Pre-migration envelope: only required fields
        let dict: [String: Any] = [
            "schema_version": 1,
            "event_id": UUID().uuidString,
            "conversation_id": convId,
            "turn_id": turnId,
            "seq": 0,
            "type": "input_audio.delta",
            "created_at_ms": Int64(1_700_000_000_000)
        ]
        guard let envelope = RealtimeEventEnvelope.decode(from: dict) else {
            XCTFail("缺少可选字段无法解码")
            return
        }
        XCTAssertNil(envelope.generationId)
        XCTAssertNil(envelope.responseId)
        XCTAssertTrue(envelope.payloadDict().isEmpty)
        XCTAssertTrue(envelope.isValid)
    }

    func testDecodeFromBridgeJSON() {
        // Simulate a Bridge message with new fields
        let bridgeJSON = """
        {
            "type": "audio.delta",
            "request_id": "\(turnId)",
            "session_id": "\(UUID().uuidString)",
            "sequence": 1,
            "sample_rate": 24000,
            "codec": "pcm_s16le",
            "audio": "dGVzdA==",
            "conversation_id": "\(convId)",
            "turn_id": "\(turnId)",
            "response_id": "\(respId)",
            "generation": 1
        }
        """
        // Verify Bridge codec extracts conversation_id and turn_id
        let codecOutcome = RealtimeBridgeWireCodec.decodeOutcome(bridgeJSON)
        guard case .envelope(let envelope) = codecOutcome else {
            XCTFail("Bridge decode 失败: \(codecOutcome)")
            return
        }
        XCTAssertEqual(envelope.conversationId, convId)
        XCTAssertEqual(envelope.turnId, turnId)
    }

    // MARK: - 5. Log safety

    func testLogDescriptionDoesNotLeakPayload() {
        let envelope = RealtimeEventEnvelope(
            conversationId: convId,
            turnId: turnId,
            seq: 1,
            type: "input_audio.delta",
            payloadDict: ["audio": "VERY_LONG_BASE64_STRING_THAT_SHOULD_NOT_APPEAR_IN_LOGS"]
        )
        let log = envelope.logDescription
        XCTAssertFalse(log.contains("VERY_LONG"), "logDescription 不得包含 payload 内容")
        XCTAssertFalse(log.contains("11111111-1111"), "logDescription 不得暴露完整 UUID")
        XCTAssertTrue(log.contains("11111111"), "logDescription 应包含前缀用于排查")
    }
}
