import XCTest
@testable import WristAgentCore

/// ESS-1097：`task.state` 两跳线格（Gateway → iPhone、iPhone → Watch）的契约。
///
/// 为什么值得单独立测：ESS-971 的教训是「协议上线、客户端没接」——网关日志里
/// 事件明明在发，Watch 侧只落一条 `downlink_decode_unrecognised`。工具回合的
/// 任务信号一旦在任一跳被丢掉，UI 就只能拿回合屏障当真相，本单修的 bug 当场复发。
final class Ess1097TaskStateWireTests: XCTestCase {

    private let sessionId = "sess-1097"
    private let requestId = "01a02e3e-3225-7da8-a6ca-7b40e4695b09"

    // MARK: - Gateway → iPhone（AudioRealtimeAgentCodec）

    func testTaskStateDecodesAsFirstClassEvent() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "generation": 3, "task_id": "task-77", "status": "running",
        ])
        guard case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("task.state 必须是一等事件，不能落到 unrecognised")
        }
        guard case .taskState(let sid, let rid, let gen, let taskId, let status) = event else {
            return XCTFail("decoded as \(event)")
        }
        XCTAssertEqual(sid, sessionId)
        XCTAssertEqual(rid, requestId)
        XCTAssertEqual(gen, 3)
        XCTAssertEqual(taskId, "task-77")
        XCTAssertEqual(status, "running")
    }

    /// `tool_call_pending` 阶段上游还没有任务号——缺 `task_id` 不得判死整帧。
    func testTaskStateWithoutTaskIdDecodesAsToolCallLatch() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "status": "tool_call_pending",
        ])
        guard case .event(.taskState(_, _, let gen, let taskId, let status)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("缺 task_id 不该让整帧解码失败")
        }
        XCTAssertNil(taskId)
        XCTAssertEqual(gen, 0, "generation 只用于取证，缺省按 0")
        XCTAssertEqual(status, "tool_call_pending")
    }

    /// `status` 是判定输入，缺了就没法判——这一条必须判死，不能猜。
    func testTaskStateWithoutStatusIsMalformed() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "task_id": "task-77",
        ])
        guard case .malformed = AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("缺 status 必须判 malformed，不得猜一个终态出来")
        }
    }

    // MARK: - iPhone → Watch（RealtimeDownlinkEnvelope）

    func testDownlinkEnvelopeRoundTripsTaskState() throws {
        let envelope = RealtimeDownlinkEnvelope.taskState(
            requestId: requestId, sessionId: sessionId,
            generation: 2, taskId: "task-77", status: "running"
        )
        let data = try JSONEncoder().encode(envelope)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["kind"] as? String, "task.state")
        XCTAssertEqual(raw["task_id"] as? String, "task-77")
        XCTAssertEqual(raw["task_status"] as? String, "running")

        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.kind, .taskState)
        XCTAssertEqual(decoded.taskId, "task-77")
        XCTAssertEqual(decoded.taskStatus, "running")
    }

    func testDownlinkEnvelopeCarriesNilTaskIdForToolCallLatch() throws {
        let envelope = RealtimeDownlinkEnvelope.taskState(
            requestId: requestId, sessionId: sessionId,
            taskId: nil, status: "tool_call_pending"
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)
        XCTAssertNil(decoded.taskId)
        XCTAssertEqual(decoded.taskStatus, "tool_call_pending")
    }

    /// 滚动升级窗口：老版本进程投递的信封没有 `task_id` / `task_status` 两个键，
    /// 必须照常解码（ESS-971 给 `RealtimeDownlinkKind` 加 `.unrecognised` 的同一条理由）。
    func testPreEss1097EnvelopeStillDecodes() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "protocol_version": RealtimeWireVersion.downlink,
            "kind": "audio.done", "request_id": requestId, "session_id": sessionId,
            "final_sequence": 7,
        ])
        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: json)
        XCTAssertEqual(decoded.kind, .audioDone)
        XCTAssertNil(decoded.taskId)
        XCTAssertNil(decoded.taskStatus)
    }

    /// 反向兼容：尚未升级的一侧收到 `task.state` 时降级为 `.unrecognised`，
    /// 而不是把整条下行丢掉。
    func testUnknownKindStillDegradesGracefully() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "protocol_version": RealtimeWireVersion.downlink,
            "kind": "task.something_new", "request_id": requestId, "session_id": sessionId,
        ])
        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: json)
        XCTAssertEqual(decoded.kind, .unrecognised)
    }
}
