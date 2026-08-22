import XCTest
@testable import WristAgentCore

/// ESS-960：已判终态的回合不得被上行帧复活。
///
/// 事故形态（2026-08-21 真机 `request_id=01a02531-03e5`）：255 次握手 /
/// 47 秒，节奏 ≈184ms = 上行帧节奏。这里钉住的是「第 2..N 帧不再开通道」。
final class RealtimeTurnGateTests: XCTestCase {
    private let rid = "01a02531-03e5-7925-a838-abacbd8f50fa"
    private let sid = "78829197-723E-4253-A84F-C1B7E3267A21"

    /// 未失败时一律放行——不能因为加了闸门就把正常链路拦住。
    func testOpensWhenNothingFailed() {
        let gate = RealtimeTurnGate()
        XCTAssertEqual(gate.decide(requestId: rid, sessionId: sid, isTurnStart: false), .open)
        XCTAssertEqual(gate.decide(requestId: rid, sessionId: sid, isTurnStart: true), .open)
    }

    /// 事故复现的核心断言：终态失败后，后续上行帧全部被拦。
    func testTerminalFailureSuppressesEveryLaterUplinkFrame() {
        var gate = RealtimeTurnGate()
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: true)

        // 真机那一轮 47 秒里泵了 255 次；这里用 20 帧代表同一形态。
        for _ in 0..<20 {
            XCTAssertEqual(
                gate.decide(requestId: rid, sessionId: sid, isTurnStart: false),
                .suppress(reason: "turn_closed_terminal")
            )
        }
    }

    /// ESS-960 整改（2026-08-21 18:27 真机）：**握手从未成功**时不得判终态。
    ///
    /// 当时网关因 ESS-886 复发对所有握手回 401（`missing_bearer`），客户端拿到
    /// `-1011`；上一版闸门把「第一次握手就被拒」也当成终态，整轮当场判死，
    /// 用户连说话的机会都没有。「token 单次使用、重开必然失败」这条理由只适用于
    /// **已经握手成功过**的通道——那时 token 才真的被消耗了。
    func testHandshakeFailureDoesNotCloseImmediately() {
        var gate = RealtimeTurnGate()
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false)
        XCTAssertEqual(gate.decide(requestId: rid, sessionId: sid, isTurnStart: false), .open)
        XCTAssertEqual(gate.closedTurnCount, 0)
    }

    /// 但握手重试必须有界——无界就退回 255 次风暴。
    func testRepeatedHandshakeFailuresEventuallyClose() {
        var gate = RealtimeTurnGate(maxHandshakeAttempts: 3)
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false)
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false)
        XCTAssertEqual(gate.decide(requestId: rid, sessionId: sid, isTurnStart: false), .open)
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false)
        XCTAssertEqual(
            gate.decide(requestId: rid, sessionId: sid, isTurnStart: false),
            .suppress(reason: "turn_closed_terminal")
        )
    }

    /// 已经握手成功过再断：token 确实被消耗了，一次即终态。
    func testFailureAfterActiveClosesImmediately() {
        var gate = RealtimeTurnGate()
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: true)
        XCTAssertEqual(
            gate.decide(requestId: rid, sessionId: sid, isTurnStart: false),
            .suppress(reason: "turn_closed_terminal")
        )
    }

    /// `stream.start` 是「开新一轮」的显式意图，永远放行，并解封该回合。
    func testTurnStartAlwaysOpensAndClearsTheSeal() {
        var gate = RealtimeTurnGate()
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: true)
        XCTAssertEqual(gate.decide(requestId: rid, sessionId: sid, isTurnStart: true), .open)

        gate.noteTurnStart(requestId: rid, sessionId: sid)
        XCTAssertEqual(gate.decide(requestId: rid, sessionId: sid, isTurnStart: false), .open)
        XCTAssertEqual(gate.closedTurnCount, 0)
    }

    /// 只封被判死的那一个回合，别的回合不受牵连。
    func testOtherTurnsUnaffected() {
        var gate = RealtimeTurnGate()
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: true)
        XCTAssertEqual(gate.decide(requestId: "other-rid", sessionId: sid, isTurnStart: false), .open)
        XCTAssertEqual(gate.decide(requestId: rid, sessionId: "other-sid", isTurnStart: false), .open)
    }

    /// 同一回合重复判死不重复入表。
    func testRepeatedTerminalFailureIsIdempotent() {
        var gate = RealtimeTurnGate()
        for _ in 0..<10 { gate.noteFailure(requestId: rid, sessionId: sid, wasActive: true) }
        XCTAssertEqual(gate.closedTurnCount, 1)
    }

    /// 有界：不会无限增长。无界集合正是 ESS-742/743/744 那一类缺陷。
    func testClosedTurnsAreBounded() {
        var gate = RealtimeTurnGate(capacity: 4)
        for i in 0..<50 {
            gate.noteFailure(requestId: "rid-\(i)", sessionId: sid, wasActive: true)
        }
        XCTAssertEqual(gate.closedTurnCount, 4)
        // 最近 4 个仍被封
        XCTAssertEqual(
            gate.decide(requestId: "rid-49", sessionId: sid, isTurnStart: false),
            .suppress(reason: "turn_closed_terminal")
        )
        // 被挤出去的老回合放行（它早就不会再有帧进来，丢掉无损）
        XCTAssertEqual(gate.decide(requestId: "rid-0", sessionId: sid, isTurnStart: false), .open)
    }
}
