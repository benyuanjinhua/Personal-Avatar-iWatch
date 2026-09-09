import XCTest
@testable import WristAgent

/// ESS-1176 N4: production recovery-state invariants. These tests exercise the
/// same gate used by `PhoneRealtimeAgentTransport`; no alternate test model.
final class Ess1176AgentRecoveryGateTests: XCTestCase {
    func testCloseInvalidatesInflightRecoveryAndPreventsReconnect() {
        var gate = AgentTransportRecoveryGate()
        guard case .scheduled(let ticket) = gate.start(
            nowMs: 12_000, generation: 7, hasOutstandingWork: true
        ) else { return XCTFail("expected recovery ticket") }

        gate.close()

        XCTAssertFalse(gate.accepts(ticket, generation: 7))
        XCTAssertEqual(
            gate.start(nowMs: 12_001, generation: 7, hasOutstandingWork: true),
            .ignored,
            "user close/cancel is terminal and must never mint another socket"
        )
    }

    func testBudgetExhaustionClaimsExactlyOneFailureTerminal() {
        var gate = AgentTransportRecoveryGate(maxAttempts: 3, budgetMs: 30_000)
        for attempt in 1...3 {
            guard case .scheduled(let ticket) = gate.start(
                nowMs: Int64(attempt * 1_000), generation: 2, hasOutstandingWork: true
            ) else { return XCTFail("attempt \(attempt) should be scheduled") }
            XCTAssertEqual(ticket.attempt, attempt)
        }

        XCTAssertEqual(
            gate.start(nowMs: 4_000, generation: 2, hasOutstandingWork: true),
            .terminal
        )
        XCTAssertEqual(
            gate.start(nowMs: 4_001, generation: 2, hasOutstandingWork: true),
            .ignored,
            "repeated failures after exhaustion must not emit a second terminal"
        )
    }

    func testBargeInSupersedesRecoveryAndOnlyNewestSessionMayInstall() {
        var gate = AgentTransportRecoveryGate()
        guard case .scheduled(let recovery) = gate.start(
            nowMs: 12_000, generation: 3, hasOutstandingWork: true
        ) else { return XCTFail("expected recovery ticket") }
        guard let replacement = gate.beginReplacement(generation: 4) else {
            return XCTFail("expected generation replacement ticket")
        }

        XCTAssertFalse(gate.accepts(recovery, generation: 4),
                       "old-generation recovery must become an orphan before install")
        XCTAssertTrue(gate.accepts(replacement, generation: 4),
                      "only the barge-in replacement remains eligible to install")
    }

    func testSuccessfulReconnectResetsBudgetForLaterIndependentIncident() {
        var gate = AgentTransportRecoveryGate(maxAttempts: 3, budgetMs: 30_000)
        guard case .scheduled(let first) = gate.start(
            nowMs: 10_000, generation: 1, hasOutstandingWork: true
        ) else { return XCTFail("expected first recovery") }
        XCTAssertTrue(gate.connected(first, generation: 1))
        XCTAssertEqual(gate.attempts, 0)
        XCTAssertNil(gate.startedAtMs)

        guard case .scheduled(let later) = gate.start(
            nowMs: 90_000, generation: 1, hasOutstandingWork: true
        ) else { return XCTFail("later incident needs a fresh budget") }
        XCTAssertEqual(later.attempt, 1)
    }
}
