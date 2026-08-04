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
            detail: nil,
            extra: """
            "result":{
                "text":"文件整理完成。",
                "audio_base64":null,
                "truncated":false,
                "speech_text":"都办妥了，放心。",
                "source":"task_presentation",
                "audio":{"sha256":"ABCD","codec":"m4a","duration_ms":1000,"size_bytes":48008}
            }
            """
        ))
        XCTAssertEqual(turn.requestId, requestId)
        XCTAssertEqual(turn.result?.text, "文件整理完成。")
        XCTAssertEqual(turn.result?.speechText, "都办妥了，放心。")
        XCTAssertEqual(turn.result?.audio?.durationMs, 1000)
        XCTAssertEqual(turn.result?.audio?.sizeBytes, 48008)
        XCTAssertEqual(turn.result?.audio?.codec, "m4a")
    }

    func testDecodesSnapshot() throws {
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

    func testDecodesValidatedTextOnlyProgress() throws {
        let json = """
        {"type":"turn.progress","progress":{
          "kind":"progress","request_id":"\(requestId)","sequence":2,
          "text":"正在翻你的笔记","occurred_at":"2026-08-02T02:00:00Z"
        }}
        """
        let progress = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8))?.progress)
        XCTAssertTrue(progress.isValid)
        XCTAssertEqual(progress.sequence, 2)
        XCTAssertEqual(progress.text, "正在翻你的笔记")
    }

    func testStateMappingMatrix() {
        XCTAssertEqual(projection(status: "accepted")?.turnState, .accepted)
        XCTAssertEqual(projection(status: "processing", detail: "decoding")?.turnState, .realtimeProcessing)
        XCTAssertEqual(projection(status: "processing", detail: "realtime_processing")?.turnState, .realtimeProcessing)
        XCTAssertEqual(projection(status: "processing", detail: "background_accepted")?.turnState, .backgroundAccepted)
        XCTAssertEqual(projection(status: "processing", detail: "background_running")?.turnState, .backgroundProcessing)
        XCTAssertEqual(projection(status: "processing", detail: "write_denied_read_only")?.turnState, .backgroundProcessing)
        XCTAssertEqual(projection(status: "completed")?.turnState, .completed)
        XCTAssertEqual(projection(status: "failed")?.turnState, .failed)
        XCTAssertEqual(projection(status: "cancelled")?.turnState, .cancelled)
        XCTAssertNil(projection(status: "something_new")?.turnState, "未知状态忽略，不中断事件流")
    }

    func testCompletedEnvelopeCarriesResultAndValidates() throws {
        let turn = try XCTUnwrap(projection(
            status: "completed",
            extra: """
            "result":{"text":"完成了。","truncated":true,
                      "audio":{"sha256":"AB12","codec":"m4a","duration_ms":800,"size_bytes":100}}
            """
        ))
        let envelope = try XCTUnwrap(turn.statusEnvelope())
        XCTAssertNil(envelope.validate())
        XCTAssertEqual(envelope.state, .completed)
        XCTAssertEqual(envelope.result?.summary, "完成了。")
        XCTAssertEqual(envelope.result?.isTruncated, true)
        XCTAssertEqual(envelope.result?.speechSha256, "ab12", "sha 统一小写供 Watch 校验")
        XCTAssertEqual(envelope.result?.speechDurationMs, 800)
    }

    func testCompletedFallsBackToSpeechTextThenPlaceholder() throws {
        let speechOnly = try XCTUnwrap(projection(
            status: "completed",
            extra: #""result":{"speech_text":"办好了。"}"#
        ))
        XCTAssertEqual(speechOnly.resultPayload?.summary, "办好了。")
        XCTAssertNil(speechOnly.resultPayload?.speechSha256, "无音频元数据 → 纯文本降级")

        let empty = try XCTUnwrap(projection(status: "completed", extra: #""result":{}"#))
        XCTAssertEqual(empty.resultPayload?.summary, "已完成")
    }

    func testFailedEnvelopeCarriesStableErrorCode() throws {
        let turn = try XCTUnwrap(projection(
            status: "failed",
            detail: "manual_confirmation_required",
            extra: #""error":"ERR_WORK_TIMEOUT""#
        ))
        let envelope = try XCTUnwrap(turn.statusEnvelope())
        XCTAssertEqual(envelope.state, .failed)
        XCTAssertEqual(envelope.detail, "刚才这件事没成，点重试再来一次；还不行就再说一遍。")
        XCTAssertEqual(envelope.failureStage, .execution)
    }

    func testAudioTooShortMapsToFriendlyRetryHint() throws {
        // ESS-41 B2：「没听清」类失败给可执行中文提示，不裸露错误码。
        for code in ["ERR_AUDIO_TOO_SHORT", "ERR_TRANSCRIPT_DISCARDED"] {
            let turn = try XCTUnwrap(projection(status: "failed", extra: #""error":"\#(code)""#))
            XCTAssertEqual(turn.detailText, "没听清，请重说")
        }
        let other = try XCTUnwrap(projection(status: "failed", extra: #""error":"ERR_WORK_TIMEOUT""#))
        XCTAssertEqual(other.detailText, "刚才这件事没成，点重试再来一次；还不行就再说一遍。")
    }

    func testPermissionRequiredNeedsPayload() throws {
        let without = try XCTUnwrap(projection(status: "permission_required"))
        XCTAssertNil(without.statusEnvelope(), "权限载荷缺失时宁缺毋滥")

        let with = try XCTUnwrap(projection(
            status: "permission_required",
            detail: "background_permission",
            extra: #""permission":{"id":"perm_1","title":"允许修改 README.md？","description":"写入仓库文件"}"#
        ))
        let envelope = try XCTUnwrap(with.statusEnvelope())
        XCTAssertNil(envelope.validate())
        XCTAssertEqual(envelope.permission?.id, "perm_1")
        XCTAssertEqual(envelope.permission?.target, "允许修改 README.md？")
    }
}
