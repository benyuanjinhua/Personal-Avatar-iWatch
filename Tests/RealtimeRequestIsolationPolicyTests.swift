import XCTest
@testable import WristAgentCore

final class RealtimeRequestIsolationPolicyTests: XCTestCase {
    func testAcceptsOnlyExactActiveRequestAndSession() {
        XCTAssertTrue(RealtimeRequestIsolationPolicy.accepts(
            incomingRequestId: "request-5", incomingSessionId: "session-a",
            activeRequestId: "request-5", activeSessionId: "session-a"
        ))
        XCTAssertFalse(RealtimeRequestIsolationPolicy.accepts(
            incomingRequestId: "request-4", incomingSessionId: "session-a",
            activeRequestId: "request-5", activeSessionId: "session-a"
        ))
        XCTAssertFalse(RealtimeRequestIsolationPolicy.accepts(
            incomingRequestId: "request-5", incomingSessionId: "session-old",
            activeRequestId: "request-5", activeSessionId: "session-a"
        ))
    }

    func testFiveTurnsRejectEveryLatePriorTurn() {
        let session = "conversation-session"
        let requests = (1...5).map { "request-\($0)" }
        let active = try! XCTUnwrap(requests.last)

        for stale in requests.dropLast() {
            XCTAssertFalse(RealtimeRequestIsolationPolicy.accepts(
                incomingRequestId: stale, incomingSessionId: session,
                activeRequestId: active, activeSessionId: session
            ))
        }
        XCTAssertTrue(RealtimeRequestIsolationPolicy.accepts(
            incomingRequestId: active, incomingSessionId: session,
            activeRequestId: active, activeSessionId: session
        ))
    }

    func testRejectsUnscopedAnnouncement() {
        XCTAssertFalse(RealtimeRequestIsolationPolicy.accepts(
            incomingRequestId: "", incomingSessionId: "session-a",
            activeRequestId: "request-1", activeSessionId: "session-a"
        ))
        XCTAssertFalse(RealtimeRequestIsolationPolicy.accepts(
            incomingRequestId: "request-1", incomingSessionId: "",
            activeRequestId: "request-1", activeSessionId: "session-a"
        ))
    }
}
