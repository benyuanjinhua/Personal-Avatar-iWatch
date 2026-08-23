import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-1097：`turn.task` 的线上契约。
///
/// 这条事件是本单唯一的新增协议面，它决定客户端能不能知道「工具还在跑」。
/// ESS-971 的教训写在 `RealtimeDownlinkKind` 的注释里——协议上线却毫无效果，
/// 是因为解码/分发链上有一环把它悄悄吞了。这里把整条链的每一环都钉死。
final class Ess1097TurnTaskWireTests: XCTestCase {

    private let sessionId = "e4f01000-0000-4000-8000-000000000001"
    private let requestId = "e4f02000-0000-4000-8000-000000000002"

    // MARK: - Gateway → iPhone（Agent WSS 编解码）

    func testDecodesTurnTaskEvent() {
        let json = """
        {"type":"turn.task","session_id":"\(sessionId)","request_id":"\(requestId)",
         "response_id":"resp-1","generation":3,"task_id":"task-9","status":"running",
         "terminal":false}
        """
        guard case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(json),
              case .taskState(let sid, let rid, let respId, let gen,
                              let taskId, let status, let terminal) = event else {
            return XCTFail("turn.task 必须解码成 .taskState")
        }
        XCTAssertEqual(sid, sessionId)
        XCTAssertEqual(rid, requestId)
        XCTAssertEqual(respId, "resp-1")
        XCTAssertEqual(gen, 3)
        XCTAssertEqual(taskId, "task-9")
        XCTAssertEqual(status, "running")
        XCTAssertFalse(terminal)
    }

    func testDecodesTerminalTurnTaskEvent() {
        let json = """
        {"type":"turn.task","session_id":"\(sessionId)","request_id":"\(requestId)",
         "generation":0,"task_id":"task-9","status":"completed","terminal":true}
        """
        guard case .event(.taskState(_, _, let respId, _, _, let status, let terminal)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("终态 turn.task 必须解码成功")
        }
        XCTAssertNil(respId, "response_id 可缺省——后台任务不一定挂在某个 response 上")
        XCTAssertEqual(status, "completed")
        XCTAssertTrue(terminal)
    }

    /// 缺 `status` / `terminal` 不得把整帧判死：一个没有 status 的任务事件
    /// 仍然证明「有任务在跑」，那正是本事件要传达的事实。缺 `terminal` 按
    /// 非终态处理（fail-closed：宁可多等一个**有界**的窗口，也不要提前收口）。
    func testMissingStatusAndTerminalDegradeInsteadOfFailing() {
        let json = """
        {"type":"turn.task","session_id":"\(sessionId)","request_id":"\(requestId)",
         "generation":1,"task_id":"task-9"}
        """
        guard case .event(.taskState(_, _, _, _, _, let status, let terminal)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("缺可选字段不得把整帧判死")
        }
        XCTAssertEqual(status, "unknown")
        XCTAssertFalse(terminal, "缺 terminal 必须按非终态处理")
    }

    /// 没有 `task_id` 的任务事件什么都证明不了——它无法参与去重，收下它只会
    /// 让闸门永远解不开。判 malformed，不进聚合。
    func testTurnTaskWithoutTaskIdIsMalformed() {
        for json in [
            """
            {"type":"turn.task","session_id":"\(sessionId)","request_id":"\(requestId)","generation":1}
            """,
            """
            {"type":"turn.task","session_id":"\(sessionId)","request_id":"\(requestId)",
             "generation":1,"task_id":""}
            """,
        ] {
            guard case .malformed = AudioRealtimeAgentCodec.decodeOutcome(json) else {
                return XCTFail("缺 / 空 task_id 必须判 malformed：\(json)")
            }
        }
    }

    // MARK: - iPhone → Watch（WCSession 信封）

    func testTurnTaskEnvelopeRoundTrip() throws {
        let envelope = RealtimeDownlinkEnvelope.turnTask(
            requestId: requestId, sessionId: sessionId,
            responseId: "resp-1", generation: 2,
            taskId: "task-9", status: "running", terminal: false
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)

        XCTAssertEqual(decoded.kind, .turnTask)
        XCTAssertEqual(decoded.requestId, requestId)
        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.generation, 2)
        XCTAssertEqual(decoded.taskId, "task-9")
        XCTAssertEqual(decoded.taskStatus, "running")
        XCTAssertEqual(decoded.taskTerminal, false)
        XCTAssertNil(decoded.audio, "任务事件不携带音频")
        XCTAssertNil(decoded.finalSequence, "任务事件不得触碰任何播放屏障")
        XCTAssertNil(decoded.transcript, "任务 id 不得借道 transcript 字段")
    }

    /// 三个新字段对既有 kind 完全透明：不写键，旧解码器一字不差。
    func testExistingKindsDoNotEmitTaskKeys() throws {
        let envelope = RealtimeDownlinkEnvelope.audioDone(
            requestId: requestId, sessionId: sessionId,
            responseId: "resp-1", generation: 1, finalSequence: 4
        )
        let data = try JSONEncoder().encode(envelope)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(raw["task_id"])
        XCTAssertNil(raw["task_status"])
        XCTAssertNil(raw["task_terminal"])
    }

    /// 滚动升级窗口：未升级的一侧收到 `turn.task` 必须降级成 `.unrecognised`
    /// 而不是整帧解码失败——那是丢掉整条下行，不是忽略一个字段。
    func testUnknownKindStillDecodesAsUnrecognised() throws {
        let json = """
        {"protocol_version":1,"kind":"turn.some_future_event",
         "request_id":"\(requestId)","session_id":"\(sessionId)"}
        """
        let decoded = try JSONDecoder().decode(
            RealtimeDownlinkEnvelope.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.kind, .unrecognised)
    }
}
