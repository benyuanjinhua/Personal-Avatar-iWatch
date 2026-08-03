import XCTest
@testable import WristAgentCore

/// ESS-180：稳定 error_code 从 Bridge 投影一路走到 VoiceStatusEnvelope。
/// 旧路径把 code 塞进 detail 字符串，Watch 端要重新解析才能查表；这里
/// 把 errorCode 单独字段的存在与语义钉死，未来任何一头改坏都会被抓到。
final class BridgeTurnProjectionErrorCodeTests: XCTestCase {
    private let requestId = "019fbbdd-5c39-70fa-9760-dc262ee092b0"

    private func projection(status: String, error: String? = nil) -> BridgeTurnProjection {
        let errorFragment = error.map { #""error":"\#($0)","# } ?? ""
        let json = """
        {"type":"turn.state","turn":{
            "request_id":"\(requestId)",
            "device_id":"dev_1",
            "status":"\(status)",
            \(errorFragment)
            "path":"background","task_id":"task_bg"
        }}
        """
        return BridgeEventMessage.decode(from: Data(json.utf8))!.turn!
    }

    func testFailedProjectionExposesErrorCode() {
        let turn = projection(status: "failed", error: "ERR_VOICE_BUSY")
        XCTAssertEqual(turn.errorCode, "ERR_VOICE_BUSY")
    }

    func testCompletedProjectionErrorCodeIsNil() {
        // 成功回合恒无 error_code——语义上「completed + error」是账本 bug。
        let turn = projection(status: "completed")
        XCTAssertNil(turn.errorCode)
    }

    func testFailedWithoutErrorFieldReturnsNilNotEmpty() {
        let turn = projection(status: "failed", error: nil)
        XCTAssertNil(turn.errorCode, "空 error 字段返回 nil，让 catalog 走 generic")
    }

    func testStatusEnvelopeCarriesErrorCode() throws {
        let turn = projection(status: "failed", error: "ERR_REALTIME_STALLED")
        let envelope = try XCTUnwrap(turn.statusEnvelope())
        XCTAssertEqual(envelope.errorCode, "ERR_REALTIME_STALLED")
        XCTAssertEqual(envelope.state, .failed)
    }

    func testEnvelopeRoundTripsErrorCode() throws {
        let original = VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            detail: "ERR_WORK_TIMEOUT", failureStage: .execution,
            errorCode: "ERR_WORK_TIMEOUT"
        )
        let data = try original.jsonData()
        let decoded = try VoiceStatusEnvelope.decode(from: data)
        XCTAssertEqual(decoded.errorCode, "ERR_WORK_TIMEOUT")
    }

    func testLegacyEnvelopeWithoutErrorCodeStillDecodes() throws {
        // ESS-180 的字段是新加的——升级过程中在旧包生成的 JSON 里没有 error_code。
        // 解码兼容：字段缺席时 errorCode = nil，其余字段正常入账。
        let json = """
        {"protocol_version":"1.0","request_id":"\(requestId)","type":"voice_status",
         "state":"failed","occurred_at":"2026-08-01T00:00:00Z","detail":"legacy",
         "failure_stage":"execution","permission":null,"result":null,"audio_kind":null}
        """
        let envelope = try VoiceStatusEnvelope.decode(from: Data(json.utf8))
        XCTAssertNil(envelope.errorCode)
        XCTAssertEqual(envelope.state, .failed)
    }
}
