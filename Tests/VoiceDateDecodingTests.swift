import XCTest
@testable import WristAgentCore

/// ESS-386：Bridge 下行时间戳是 JS `Date#toISOString()`（固定 `.sssZ` 毫秒）。
/// 旧 SDK 上 `.iso8601` 默认策略不含 `.withFractionalSeconds`，`.000Z` 静默
/// 解码失败。三个解码入口统一换成 `VoiceDateDecoding.strategy` 后，`.000Z`
/// 与 `Z` 两种格式都必须能解出，且指向同一时刻。
final class VoiceDateDecodingTests: XCTestCase {

    private let expectedEpoch: TimeInterval = 1_785_837_600 // 2026-08-04T10:00:00Z

    // MARK: - VoiceProtocolJSON（VoiceStatusEnvelope / BridgeEventMessage 共用）

    func testStatusEnvelopeDecodesMillisTimestamp() throws {
        let envelope = try decodeStatusEnvelope(occurredAt: "2026-08-04T10:00:00.000Z")
        XCTAssertEqual(envelope.occurredAt.timeIntervalSince1970, expectedEpoch, accuracy: 0.001)
    }

    func testStatusEnvelopeDecodesPlainTimestamp() throws {
        let envelope = try decodeStatusEnvelope(occurredAt: "2026-08-04T10:00:00Z")
        XCTAssertEqual(envelope.occurredAt.timeIntervalSince1970, expectedEpoch, accuracy: 0.001)
    }

    /// Bridge 现网 `turn.progress` 的真实形状（server.mjs:1212 发出的字段），
    /// 回归 ESS-368 被静默丢弃的那类事件。
    func testBridgeEventMessageDecodesMillisProgressTimestamp() throws {
        let json = """
        {"type":"turn.progress","progress":{
          "kind":"asr_partial","request_id":"\(UUID().uuidString.lowercased())","sequence":1,
          "text":"hello","occurred_at":"2026-08-04T10:00:00.000Z"
        }}
        """
        let message = try XCTUnwrap(
            BridgeEventMessage.decode(from: Data(json.utf8)),
            "带毫秒时间戳的 turn.progress 不得再被静默丢弃"
        )
        XCTAssertNotNil(message.progress)
    }

    // MARK: - VoiceRequestEnvelope

    func testVoiceRequestEnvelopeDecodesMillisCreatedAt() throws {
        let json = """
        {"protocol_version":"1.0","request_id":"\(UUID().uuidString.lowercased())",
         "type":"voice_request","created_at":"2026-08-04T10:00:00.000Z",
         "audio":{"codec":"aac","sample_rate":16000,"channels":1,"duration_ms":1000,
                  "sha256":"\(String(repeating: "a", count: 64))"}}
        """
        let envelope = try VoiceRequestEnvelope.decode(from: Data(json.utf8))
        XCTAssertEqual(envelope.createdAt.timeIntervalSince1970, expectedEpoch, accuracy: 0.001)
    }

    func testVoiceRequestEnvelopeDecodesPlainCreatedAt() throws {
        let json = """
        {"protocol_version":"1.0","request_id":"\(UUID().uuidString.lowercased())",
         "type":"voice_request","created_at":"2026-08-04T10:00:00Z",
         "audio":{"codec":"aac","sample_rate":16000,"channels":1,"duration_ms":1000,
                  "sha256":"\(String(repeating: "a", count: 64))"}}
        """
        let envelope = try VoiceRequestEnvelope.decode(from: Data(json.utf8))
        XCTAssertEqual(envelope.createdAt.timeIntervalSince1970, expectedEpoch, accuracy: 0.001)
    }

    // MARK: - VoiceRelayEvents（RelayEventCoding / VoiceRelayEvent 两处解码器）

    func testRelayStatusUpdateDecodesMillisTimestamp() throws {
        let json = """
        {"protocol_version":"1.0","request_id":"\(UUID().uuidString.lowercased())",
         "phase":"completed","detail":null,"error_code":null,"failure_stage":null,
         "updated_at":"2026-08-04T10:00:00.000Z"}
        """
        let update = try XCTUnwrap(RelayStatusUpdate.decode(from: Data(json.utf8)))
        XCTAssertEqual(update.updatedAt.timeIntervalSince1970, expectedEpoch, accuracy: 0.001)
    }

    func testRelayStatusUpdateDecodesPlainTimestamp() throws {
        let json = """
        {"protocol_version":"1.0","request_id":"\(UUID().uuidString.lowercased())",
         "phase":"completed","detail":null,"error_code":null,"failure_stage":null,
         "updated_at":"2026-08-04T10:00:00Z"}
        """
        let update = try XCTUnwrap(RelayStatusUpdate.decode(from: Data(json.utf8)))
        XCTAssertEqual(update.updatedAt.timeIntervalSince1970, expectedEpoch, accuracy: 0.001)
    }

    func testVoiceRelayEventDecodesMillisTimestamp() throws {
        let json = """
        {"request_id":"\(UUID().uuidString.lowercased())","event":"status",
         "status":"completed","occurred_at":"2026-08-04T10:00:00.000Z"}
        """
        let event = try XCTUnwrap(VoiceRelayEvent.decode(from: Data(json.utf8)))
        XCTAssertEqual(event.occurredAt?.timeIntervalSince1970 ?? 0, expectedEpoch, accuracy: 0.001)
    }

    func testVoiceRelayEventDecodesPlainTimestamp() throws {
        let json = """
        {"request_id":"\(UUID().uuidString.lowercased())","event":"status",
         "status":"completed","occurred_at":"2026-08-04T10:00:00Z"}
        """
        let event = try XCTUnwrap(VoiceRelayEvent.decode(from: Data(json.utf8)))
        XCTAssertEqual(event.occurredAt?.timeIntervalSince1970 ?? 0, expectedEpoch, accuracy: 0.001)
    }

    // MARK: - 坏输入仍要失败（容错不等于吞掉一切）

    func testGarbageTimestampStillFails() {
        let json = """
        {"protocol_version":"1.0","request_id":"\(UUID().uuidString.lowercased())",
         "phase":"completed","updated_at":"not-a-date"}
        """
        XCTAssertNil(RelayStatusUpdate.decode(from: Data(json.utf8)))
    }

    // MARK: - helpers

    private func decodeStatusEnvelope(occurredAt: String) throws -> VoiceStatusEnvelope {
        let json = """
        {"protocol_version":"1.0","request_id":"\(UUID().uuidString.lowercased())",
         "type":"voice_status","state":"completed","occurred_at":"\(occurredAt)"}
        """
        return try VoiceStatusEnvelope.decode(from: Data(json.utf8))
    }
}
