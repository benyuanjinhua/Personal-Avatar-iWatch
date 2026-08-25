import XCTest
@testable import WristAgentCore

/// ESS-1100：进展文字两跳线格（Gateway → iPhone、iPhone → Watch）的契约。
///
/// 立测的理由与 ESS-1097 同源、且是同一条教训的下一节：ESS-971 的事故是
/// 「协议上线、客户端没接」。进展文字比任务状态更容易悄悄消失——它是**可选**
/// 字段，任一跳漏解一次，真机上的表现只是「还是那句正在思考」，没有任何报错。
final class Ess1100TaskProgressWireTests: XCTestCase {

    private let sessionId = "sess-1100"
    private let requestId = "01a02e3e-3225-7da8-a6ca-7b40e4695b09"

    // MARK: - Gateway → iPhone（AudioRealtimeAgentCodec）

    func testTaskStateDecodesProgressFields() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "generation": 3, "task_id": "task-77", "status": "running",
            "progress_text": "正在查询相关信息", "progress_category": "search",
            "progress_seq": 4,
        ])

        guard case .event(.taskState(_, _, _, let taskId, let status, let progress, _)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("task.state 必须是一等事件")
        }
        XCTAssertEqual(taskId, "task-77")
        XCTAssertEqual(status, "running")
        XCTAssertEqual(progress?.text, "正在查询相关信息")
        XCTAssertEqual(progress?.category, "search")
        XCTAssertEqual(progress?.sequence, 4)
    }

    /// 老网关不发这三个键。缺席只意味着「这一帧没话说」，绝不能连带把本帧
    /// 真正关键的 `status` 一起判死——那是把 ESS-1095 装回去。
    func testTaskStateWithoutProgressStillDecodesTheLifecycle() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "generation": 3, "task_id": "task-77", "status": "running",
        ])

        guard case .event(.taskState(_, _, _, let taskId, let status, let progress, _)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("缺进展字段不该让整帧解码失败")
        }
        XCTAssertEqual(taskId, "task-77")
        XCTAssertEqual(status, "running")
        XCTAssertNil(progress)
    }

    func testEmptyProgressTextDecodesAsNoProgress() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "status": "running", "task_id": "task-77",
            "progress_text": "", "progress_seq": 2,
        ])

        guard case .event(.taskState(_, _, _, _, _, let progress, _)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("空进展文本不该让整帧解码失败")
        }
        XCTAssertNil(progress, "空文本的「进展」对用户是零信息，等同没有")
    }

    /// 闩锁帧（`tool_call_pending`，无 task_id）同样可以带进展——上游在拿到
    /// 任务号之前也可能已经知道自己在做什么。
    func testToolCallLatchMayCarryProgress() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "status": "tool_call_pending",
            "progress_text": "正在处理", "progress_seq": 1,
        ])

        guard case .event(.taskState(_, _, _, let taskId, _, let progress, _)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("闩锁帧必须解得出来")
        }
        XCTAssertNil(taskId)
        XCTAssertEqual(progress?.text, "正在处理")
    }

    // MARK: - iPhone → Watch（RealtimeDownlinkEnvelope）

    func testDownlinkEnvelopeRoundTripsProgress() throws {
        let progress = AgentTaskProgress(sequence: 4, text: "正在查询相关信息", category: "search")
        let envelope = RealtimeDownlinkEnvelope.taskState(
            requestId: requestId, sessionId: sessionId,
            generation: 2, taskId: "task-77", status: "running", progress: progress
        )

        let data = try JSONEncoder().encode(envelope)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["progress_text"] as? String, "正在查询相关信息")
        XCTAssertEqual(raw["progress_category"] as? String, "search")
        XCTAssertEqual(raw["progress_seq"] as? Int, 4)

        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.progressText, "正在查询相关信息")
        XCTAssertEqual(decoded.progressSequence, 4)
    }

    /// 无进展时**一个键都不多**——老 Watch 收到的信封与 ESS-1097 时代逐字节相同。
    func testDownlinkEnvelopeOmitsProgressKeysWhenAbsent() throws {
        let envelope = RealtimeDownlinkEnvelope.taskState(
            requestId: requestId, sessionId: sessionId,
            generation: 2, taskId: "task-77", status: "running"
        )

        let data = try JSONEncoder().encode(envelope)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(raw["progress_text"])
        XCTAssertNil(raw["progress_category"])
        XCTAssertNil(raw["progress_seq"])
    }

    /// 老 iPhone 发来的、没有进展字段的信封必须照常解码（滚动升级窗口内
    /// WCSession 队列里真实存在混版，见 `RealtimeDownlinkKind.unrecognised` 注释）。
    func testLegacyEnvelopeWithoutProgressDecodes() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "protocol_version": RealtimeWireVersion.downlink,
            "kind": "task.state", "request_id": requestId, "session_id": sessionId,
            "task_id": "task-77", "task_status": "running",
        ])

        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: json)

        XCTAssertEqual(decoded.taskStatus, "running")
        XCTAssertNil(decoded.progressText)
        XCTAssertNil(decoded.progressSequence)
    }

    // MARK: - 端到端（解码 → 叙述）

    /// 两条真实进展从线格一路走到「该显示哪句话」，中间的迟到帧被挡掉。
    func testDecodedFramesDriveTheNarrationInOrder() throws {
        var narration = ToolProgressNarration()
        let frames: [[String: Any]] = [
            ["progress_text": "正在查询相关信息", "progress_category": "search", "progress_seq": 1],
            ["progress_text": "正在读取相关内容", "progress_category": "read", "progress_seq": 2],
            // 迟到重投的第 1 条
            ["progress_text": "正在查询相关信息", "progress_category": "search", "progress_seq": 1],
        ]

        var outcomes: [ToolProgressNarration.Outcome] = []
        for frame in frames {
            var payload: [String: Any] = [
                "type": "task.state", "session_id": sessionId, "request_id": requestId,
                "status": "running", "task_id": "task-77",
            ]
            payload.merge(frame) { _, new in new }
            let json = try JSONSerialization.data(withJSONObject: payload)
            guard case .event(.taskState(_, _, _, _, _, let progress, _)) =
                    AudioRealtimeAgentCodec.decodeOutcome(json),
                  let progress else {
                return XCTFail("每一帧都必须解出进展")
            }
            outcomes.append(narration.apply(
                sequence: progress.sequence, text: progress.text, category: progress.category
            ))
        }

        XCTAssertEqual(outcomes, [.applied, .applied, .outOfOrder])
        XCTAssertEqual(narration.text, "正在读取相关内容")
    }
}
