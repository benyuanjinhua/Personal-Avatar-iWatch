import XCTest
@testable import WristAgentCore

/// ESS-1111：答案文本增量的装配与两跳线格（Gateway → iPhone、iPhone → Watch）。
///
/// 缺口（本单实现前）：Codex 长任务的最终答案只有「播完整段音频」一条到达
/// 路径。ESS-1109 真机取证里任务仍在跑时连接就断了，24 s 后完成的答案无法
/// 回传，用户从头到尾只看到一句「正在思考」。上游 ESS-1110 已经把答案 token
/// 投影成有序的 `task.stream{category:'text'}`，网关把它落在 `task.state` 的
/// `answer_delta` / `answer_seq` 上——本文件钉的是客户端这一侧。
final class Ess1111AnswerStreamTests: XCTestCase {

    private let sessionId = "sess-1111"
    private let requestId = "req-1111"

    // MARK: - 装配（AnswerStreamAssembly）

    func testDeltasAppendInSequenceOrder() {
        var stream = AnswerStreamAssembly()
        XCTAssertEqual(stream.apply(sequence: 1, delta: "杭州"), .applied)
        XCTAssertEqual(stream.apply(sequence: 2, delta: "今天"), .applied)
        XCTAssertEqual(stream.apply(sequence: 3, delta: "晴"), .applied)
        XCTAssertEqual(stream.text, "杭州今天晴")
        XCTAssertEqual(stream.appliedCount, 3)
        XCTAssertTrue(stream.hasAnswer)
    }

    /// 重复投递必须被丢弃，否则同一段话会出现两遍。
    func testDuplicateSequenceIsDropped() {
        var stream = AnswerStreamAssembly()
        XCTAssertEqual(stream.apply(sequence: 1, delta: "杭州"), .applied)
        XCTAssertEqual(stream.apply(sequence: 1, delta: "杭州"), .duplicate)
        XCTAssertEqual(stream.text, "杭州")
        XCTAssertEqual(stream.droppedCount, 1)
    }

    /// 迟到的旧片段被追加到新片段后面 = 一段读不通的话。这是 WCSession 那一跳
    /// 不保证顺序的直接后果，也是 `answer_seq` 存在的唯一理由。
    func testOutOfOrderDeltaIsDropped() {
        var stream = AnswerStreamAssembly()
        stream.apply(sequence: 5, delta: "晴")
        XCTAssertEqual(stream.apply(sequence: 2, delta: "今天"), .outOfOrder)
        XCTAssertEqual(stream.text, "晴")
    }

    /// 滚动升级窗口：老网关不带 `answer_seq`。照常显示，但不推进序号闸门——
    /// 把没带号的帧一律丢掉，等于让答案流在升级期间整个消失。
    func testMissingSequenceStillApplies() {
        var stream = AnswerStreamAssembly()
        XCTAssertEqual(stream.apply(sequence: nil, delta: "杭州"), .applied)
        XCTAssertEqual(stream.apply(sequence: nil, delta: "今天晴"), .applied)
        XCTAssertEqual(stream.text, "杭州今天晴")
        XCTAssertNil(stream.latestSequence)
    }

    func testEmptyDeltaIsRejected() {
        var stream = AnswerStreamAssembly()
        XCTAssertEqual(stream.apply(sequence: 1, delta: ""), .empty)
        XCTAssertEqual(stream.apply(sequence: 1, delta: nil), .empty)
        XCTAssertNil(stream.text)
        XCTAssertFalse(stream.hasAnswer)
    }

    /// 长答案：丢头保尾。正在生成的那一头才是用户此刻在读的内容。
    func testLongAnswerKeepsTailWithinBudget() {
        var stream = AnswerStreamAssembly()
        let chunk = String(repeating: "甲", count: 100)
        for seq in 1...6 { stream.apply(sequence: seq, delta: chunk) }
        let text = try! XCTUnwrap(stream.text)
        XCTAssertTrue(text.hasPrefix(AnswerStreamAssembly.truncationMarker),
                      "被截断时必须让用户看出「上面还有」")
        XCTAssertEqual(text.count, AnswerStreamAssembly.maxRetainedCharacters + 1)
        XCTAssertEqual(stream.receivedCharacters, 600)
        XCTAssertTrue(stream.isTruncated)
    }

    /// 换回合必须整体清空：上一轮的半句答案挂在新一轮的屏幕上，
    /// 用户会把它当成这一轮的回答。
    func testClearResetsEverything() {
        var stream = AnswerStreamAssembly()
        stream.apply(sequence: 3, delta: "杭州")
        stream.clear()
        XCTAssertNil(stream.text)
        XCTAssertNil(stream.latestSequence)
        XCTAssertEqual(stream.appliedCount, 0)
        XCTAssertEqual(stream.receivedCharacters, 0)
        // 清空后序号从头开始，新一轮的 seq=1 不会被旧闸门挡掉。
        XCTAssertEqual(stream.apply(sequence: 1, delta: "深圳"), .applied)
    }

    /// 日志摘要不得包含答案原文——它是用户内容。
    func testLogDetailNeverCarriesAnswerText() {
        var stream = AnswerStreamAssembly()
        stream.apply(sequence: 1, delta: "杭州今天晴")
        XCTAssertFalse(stream.logDetail.contains("杭州"))
        XCTAssertTrue(stream.logDetail.contains("answer_seq=1"))
        XCTAssertTrue(stream.logDetail.contains("answer_len=5"))
    }

    // MARK: - 线格一：Gateway → iPhone（AudioRealtimeAgentCodec）

    func testTaskStateCarriesAnswerDelta() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "generation": 1, "task_id": "work_codex", "status": "running",
            "answer_delta": "杭州今天", "answer_seq": 7,
        ])
        guard case .event(.taskState(_, _, _, let taskId, let status, let progress, let answer)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("带答案增量的 task.state 必须照常解码")
        }
        XCTAssertEqual(taskId, "work_codex")
        XCTAssertEqual(status, "running")
        XCTAssertNil(progress, "答案帧不夹带进展")
        XCTAssertEqual(answer?.delta, "杭州今天")
        XCTAssertEqual(answer?.sequence, 7)
    }

    /// 老网关（ESS-1100 及更早）的帧一个答案键都没有：必须逐字保持原行为。
    func testTaskStateWithoutAnswerKeysIsUnchanged() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "generation": 1, "task_id": "work_codex", "status": "running",
            "progress_text": "正在查询相关信息", "progress_seq": 2,
        ])
        guard case .event(.taskState(_, _, _, _, let status, let progress, let answer)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("老帧必须继续解码")
        }
        XCTAssertEqual(status, "running")
        XCTAssertEqual(progress?.text, "正在查询相关信息")
        XCTAssertNil(answer)
    }

    /// 展示面字段的缺陷不得把整帧判死——那会连带丢掉本帧真正关键的 `status`。
    func testEmptyAnswerDeltaDoesNotKillTheFrame() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "task.state", "session_id": sessionId, "request_id": requestId,
            "generation": 1, "task_id": "work_codex", "status": "running",
            "answer_delta": "", "answer_seq": 9,
        ])
        guard case .event(.taskState(_, _, _, _, let status, _, let answer)) =
                AudioRealtimeAgentCodec.decodeOutcome(json) else {
            return XCTFail("空增量只是「这一帧没有新答案」，不是坏帧")
        }
        XCTAssertEqual(status, "running")
        XCTAssertNil(answer)
    }

    // MARK: - 线格二：iPhone → Watch（RealtimeDownlinkEnvelope / WCSession 跳）

    func testEnvelopeRoundTripsAnswerDelta() throws {
        let envelope = RealtimeDownlinkEnvelope.taskState(
            requestId: requestId, sessionId: sessionId, generation: 1,
            taskId: "work_codex", status: "running",
            progress: nil,
            answer: AgentTaskAnswerDelta(sequence: 4, delta: "杭州今天晴")
        )
        let data = try JSONEncoder().encode(envelope)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(raw["answer_delta"] as? String, "杭州今天晴")
        XCTAssertEqual(raw["answer_seq"] as? Int, 4)

        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)
        XCTAssertEqual(decoded.kind, .taskState)
        XCTAssertEqual(decoded.answerDelta, "杭州今天晴")
        XCTAssertEqual(decoded.answerSequence, 4)
    }

    /// 反向兼容：没有答案的任务帧**一个键都不多**，老 Watch 逐字节不受影响。
    func testEnvelopeWithoutAnswerCarriesNoAnswerKeys() throws {
        let envelope = RealtimeDownlinkEnvelope.taskState(
            requestId: requestId, sessionId: sessionId, generation: 1,
            taskId: "work_codex", status: "running"
        )
        let data = try JSONEncoder().encode(envelope)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(raw["answer_delta"])
        XCTAssertNil(raw["answer_seq"])
    }

    /// 未升级的一侧发来的帧没有答案键，解码不得失败（向前兼容）。
    func testEnvelopeFromOlderPeerStillDecodes() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "protocol_version": RealtimeWireVersion.downlink,
            "kind": "task.state", "request_id": requestId, "session_id": sessionId,
            "task_id": "work_codex", "task_status": "running",
        ])
        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: json)
        XCTAssertEqual(decoded.taskStatus, "running")
        XCTAssertNil(decoded.answerDelta)
        XCTAssertNil(decoded.answerSequence)
    }

    /// 两跳合起来跑一遍 24 s 长任务的答案流：乱序 + 重复 + 迟到都进来，
    /// 装配出来的仍然是一段读得通的话。
    func testTwoHopAnswerStreamSurvivesDuplicatesAndReordering() throws {
        var stream = AnswerStreamAssembly()
        let wire: [(Int, String)] = [
            (1, "杭州"), (2, "今天"), (2, "今天"), (3, "多云"), (1, "杭州"), (4, "转晴"),
        ]
        for (seq, delta) in wire {
            let json = try JSONSerialization.data(withJSONObject: [
                "protocol_version": RealtimeWireVersion.downlink,
                "kind": "task.state", "request_id": requestId, "session_id": sessionId,
                "task_id": "work_codex", "task_status": "running",
                "answer_delta": delta, "answer_seq": seq,
            ])
            let envelope = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: json)
            let answer = AgentTaskAnswerDelta(
                sequence: envelope.answerSequence, delta: envelope.answerDelta
            )
            stream.apply(sequence: answer?.sequence, delta: answer?.delta)
        }
        XCTAssertEqual(stream.text, "杭州今天多云转晴")
        XCTAssertEqual(stream.appliedCount, 4)
        XCTAssertEqual(stream.droppedCount, 2)
    }
}
