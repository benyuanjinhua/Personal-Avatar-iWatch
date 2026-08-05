import XCTest
@testable import WristAgentCore

/// ESS-38：Bridge 真实 WSS 契约（turn.state / snapshot）的解码与
/// Watch 状态机映射。此前 iPhone 端解码的是 Bridge 从未发送的旧事件形状，
/// 下行链路在解码层即断裂——这里把契约钉死。
final class BridgeTurnProjectionTests: XCTestCase {
    private let requestId = "019fbbdd-5c39-70fa-9760-dc262ee092b0"

    private func projection(
        status: String,
        detail: String? = nil,
        extra: String = ""
    ) -> BridgeTurnProjection? {
        let json = """
        {"type":"turn.state","turn":{
            "request_id":"\(requestId)",
            "device_id":"dev_1",
            "status":"\(status)",
            "detail":\(detail.map { "\"\($0)\"" } ?? "null"),
            "path":"background",
            "task_id":"task_bg"
            \(extra.isEmpty ? "" : "," + extra)
        }}
        """
        return BridgeEventMessage.decode(from: Data(json.utf8))?.turn
    }

    func testDecodesTurnStateWithAudioResult() throws {
        let turn = try XCTUnwrap(projection(
            status: "completed",
            extra: """
            "result":{"text":"完成","audio":{"sha256":"abc123","codec":"m4a","duration_ms":1500,"size_bytes":32000}}
            """
        ))
        XCTAssertEqual(turn.status, "completed")
        XCTAssertEqual(turn.result?.text, "完成")
        XCTAssertEqual(turn.result?.audio?.sha256, "abc123")
        XCTAssertEqual(turn.result?.audio?.durationMs, 1500)
    }

    func testDecodesSnapshotWithMultipleTurns() throws {
        let json = """
        {"type":"snapshot","turns":[
            {"request_id":"\(requestId)","status":"processing","detail":"realtime_processing"}
        ]}
        """
        let message = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8)))
        XCTAssertEqual(message.type, "snapshot")
        XCTAssertEqual(message.turns?.count, 1)
        XCTAssertEqual(message.turns?.first?.turnState, .realtimeProcessing)
        XCTAssertNil(BridgeEventMessage.decode(from: Data("not-json".utf8)), "坏 JSON 返回 nil 不崩溃")
    }

    func testDecodesInterimWithDeliverySequenceAndAudio() throws {
        let json = """
        {"type":"turn.interim","interim":{
          "request_id":"\(requestId)","delivery_sequence":1,
          "text":"收到，正在处理，请稍后",
          "audio":{"base64":"ZmFrZQ==","sha256":"abcd","codec":"m4a","duration_ms":900,"size_bytes":4}
        }}
        """
        let interim = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8))?.interim)
        XCTAssertEqual(interim.requestId, requestId)
        XCTAssertEqual(interim.deliverySequence, 1)
        XCTAssertEqual(interim.text, "收到，正在处理，请稍后")
        XCTAssertEqual(interim.audio?.durationMs, 900)
    }

    func testDecodesProgressWithValidFields() throws {
        let json = """
        {"type":"turn.progress","progress":{
          "kind":"progress","request_id":"\(requestId)","sequence":2,
          "text":"Step 2/5: 正在查询数据库","occurred_at":"2026-08-04T10:00:00.000Z"
        }}
        """
        let progress = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8))?.progress)
        XCTAssertTrue(progress.isValid)
        XCTAssertEqual(progress.kind, "progress")
        XCTAssertEqual(progress.sequence, 2)
    }

    func testProgressRejectsInvalidKind() {
        let json = """
        {"type":"turn.progress","progress":{
          "kind":"bad","request_id":"\(requestId)","sequence":1,
          "text":"bad","occurred_at":"2026-08-04T10:00:00.000Z"
        }}
        """
        let progress = BridgeEventMessage.decode(from: Data(json.utf8))?.progress
        XCTAssertNotNil(progress)
        XCTAssertFalse(progress?.isValid ?? true)
    }

    func testFailedTurnExposesErrorCode() throws {
        let turn = try XCTUnwrap(projection(
            status: "failed",
            detail: "background_processing",
            extra: """
            "error":"ERR_VOICE_BUSY"
            """
        ))
        XCTAssertEqual(turn.status, "failed")
        XCTAssertEqual(turn.errorCode, "ERR_VOICE_BUSY")
        XCTAssertEqual(turn.turnState, .failed)
    }

    func testCancelledTurnState() throws {
        let turn = try XCTUnwrap(projection(status: "cancelled"))
        XCTAssertEqual(turn.turnState, .cancelled)
        XCTAssertNil(turn.errorCode)
    }

    func testCompletedTurnResultPayload() throws {
        let turn = try XCTUnwrap(projection(
            status: "completed",
            extra: """
            "result":{"text":"任务完成","audio":{"sha256":"def456","codec":"m4a","duration_ms":2000,"size_bytes":48000}}
            """
        ))
        let payload = try XCTUnwrap(turn.resultPayload)
        XCTAssertEqual(payload.summary, "任务完成")
        XCTAssertEqual(payload.speechSha256, "def456")
        XCTAssertEqual(payload.speechDurationMs, 2000)
    }

    func testPermissionRequiredNeedsPayload() throws {
        let without = try XCTUnwrap(projection(status: "permission_required"))
        XCTAssertNil(without.statusEnvelope(), "权限载荷缺失时宁缺毋滥")

        let with = try XCTUnwrap(projection(
            status: "permission_required",
            detail: "background_permission",
            extra: """
            "permission":{"id":"perm_1","title":"允许修改 README.md？","description":"写入仓库文件"}
            """
        ))
        let envelope = try XCTUnwrap(with.statusEnvelope())
        XCTAssertNil(envelope.validate())
        XCTAssertEqual(envelope.permission?.id, "perm_1")
        XCTAssertEqual(envelope.permission?.target, "允许修改 README.md？")
    }

    // MARK: - ESS-324 B3: voice.stream.chunk 解码

    func testDecodesVoiceStreamChunkDownlink() throws {
        let payload = Data(repeating: 0xAB, count: 240)
        let sha = VoiceStreamChunk.sha256(payload)
        let json = """
        {"type":"voice.stream.chunk","chunk":{
            "protocol_version":2,
            "request_id":"\(requestId)",
            "stream_id":"019fcd76-0000-7000-8000-000000000001",
            "direction":"downlink",
            "sequence":0,
            "captured_at_ms":1722786540000,
            "codec":"pcm_s16le",
            "sample_rate":24000,
            "payload":"\(payload.base64EncodedString())",
            "payload_sha256":"\(sha)",
            "end_of_stream":false
        }}
        """
        let message = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8)))
        XCTAssertEqual(message.type, "voice.stream.chunk")
        let chunk = try XCTUnwrap(message.chunk)
        XCTAssertEqual(chunk.protocolVersion, 2)
        XCTAssertEqual(chunk.requestId, requestId)
        XCTAssertEqual(chunk.direction, .downlink)
        XCTAssertEqual(chunk.sequence, 0)
        XCTAssertEqual(chunk.codec, "pcm_s16le")
        XCTAssertEqual(chunk.sampleRate, 24000)
        XCTAssertEqual(chunk.payload, payload)
        XCTAssertEqual(chunk.payloadSha256.lowercased(), sha.lowercased())
        XCTAssertFalse(chunk.endOfStream)
    }

    func testDecodesVoiceStreamChunkEndOfStream() throws {
        let payload = Data([0x00, 0x00])
        let sha = VoiceStreamChunk.sha256(payload)
        let json = """
        {"type":"voice.stream.chunk","chunk":{
            "protocol_version":2,
            "request_id":"\(requestId)",
            "stream_id":"019fcd76-0000-7000-8000-000000000002",
            "direction":"downlink",
            "sequence":42,
            "captured_at_ms":1722786541000,
            "codec":"pcm_s16le",
            "sample_rate":24000,
            "payload":"\(payload.base64EncodedString())",
            "payload_sha256":"\(sha)",
            "end_of_stream":true
        }}
        """
        let message = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8)))
        let chunk = try XCTUnwrap(message.chunk)
        XCTAssertEqual(chunk.sequence, 42)
        XCTAssertTrue(chunk.endOfStream)
    }

    func testNonStreamEventHasNilChunk() throws {
        let json = """
        {"type":"turn.state","turn":{"request_id":"\(requestId)","status":"accepted"}}
        """
        let message = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8)))
        XCTAssertEqual(message.type, "turn.state")
        XCTAssertNotNil(message.turn)
        XCTAssertNil(message.chunk, "非流式事件 chunk 应为 nil")
    }
}
