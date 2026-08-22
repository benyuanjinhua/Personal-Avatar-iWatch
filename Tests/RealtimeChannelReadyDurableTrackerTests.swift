import XCTest
@testable import WristAgentCore

/// ESS-869 architecture-review fix: the durable (`transferUserInfo`) delivery
/// of a channel ready must close its failure path — a failed system receipt
/// clears the dedup marker and retries (bounded), never leaving the marker set
/// forever. These tests drive the pure `RealtimeChannelReadyDurableTracker`
/// state machine (the iOS `PhoneConnectivity` wiring is the only part that
/// touches WCSession).
final class RealtimeChannelReadyDurableTrackerTests: XCTestCase {

    private func ready(_ id: String = "rid-1") -> RealtimeChannelReady {
        RealtimeChannelReady(requestId: id, sessionId: "sid-1")
    }

    /// First durable failure → same request_id can be re-enqueued → success
    /// receipt clears the in-flight state. This is the exact gap the review
    /// flagged as "durableReadyEnqueued == ready 永久挡住同一 ready 再入队".
    func testFailureClearsMarkerAndAllowsSameRequestIdReenqueue() {
        var tracker = RealtimeChannelReadyDurableTracker(maxAttempts: 3)
        let r = ready()

        XCTAssertEqual(tracker.requestEnqueue(r), .enqueue(attempt: 1))

        // A failed system receipt must not leave the marker set.
        XCTAssertEqual(tracker.recordReceipt(r, delivered: false), .retry)
        XCTAssertEqual(tracker.requestEnqueue(r), .enqueue(attempt: 2))

        // Success receipt clears in-flight state and resets the attempt count.
        XCTAssertNil(tracker.recordReceipt(r, delivered: true))
        XCTAssertEqual(tracker.attempts, 0)
        XCTAssertEqual(tracker.requestEnqueue(r), .enqueue(attempt: 1), "成功后重新计数")
    }

    /// While an entry is in flight, the same ready must not be enqueued again
    /// (no duplicate `transferUserInfo`).
    func testInFlightDedupSkipsSameReady() {
        var tracker = RealtimeChannelReadyDurableTracker()
        let r = ready()

        XCTAssertEqual(tracker.requestEnqueue(r), .enqueue(attempt: 1))
        XCTAssertEqual(tracker.requestEnqueue(r), .skip, "在途不得重复入队")
    }

    /// After `maxAttempts` failures the tracker gives up and blocks further
    /// enqueues for this turn — no infinite retry on repeated callbacks.
    func testBoundedRetryGivesUpAfterMaxAttempts() {
        var tracker = RealtimeChannelReadyDurableTracker(maxAttempts: 2)
        let r = ready()

        XCTAssertEqual(tracker.requestEnqueue(r), .enqueue(attempt: 1))
        XCTAssertEqual(tracker.recordReceipt(r, delivered: false), .retry)
        XCTAssertEqual(tracker.requestEnqueue(r), .enqueue(attempt: 2))
        XCTAssertEqual(tracker.recordReceipt(r, delivered: false), .giveUp)

        // Terminal: no further durable enqueue for this turn.
        XCTAssertTrue(tracker.gaveUp)
        XCTAssertEqual(tracker.requestEnqueue(r), .skip)
    }

    /// A newer turn supersedes the previous one and clears a terminal state.
    func testNewTurnResetClearsGiveUp() {
        var tracker = RealtimeChannelReadyDurableTracker(maxAttempts: 1)
        let first = ready("rid-1")
        let second = ready("rid-2")

        _ = tracker.requestEnqueue(first)
        XCTAssertEqual(tracker.recordReceipt(first, delivered: false), .giveUp)
        XCTAssertTrue(tracker.gaveUp)

        tracker.reset()

        XCTAssertFalse(tracker.gaveUp)
        XCTAssertEqual(tracker.requestEnqueue(second), .enqueue(attempt: 1))
    }

    /// A stale receipt for a different turn must not mutate the current state.
    func testStaleReceiptForDifferentReadyIsIgnored() {
        var tracker = RealtimeChannelReadyDurableTracker()
        let current = ready("rid-current")
        let stale = ready("rid-stale")

        _ = tracker.requestEnqueue(current)
        XCTAssertNil(tracker.recordReceipt(stale, delivered: false))
        XCTAssertEqual(tracker.inFlight, current, "陈旧回执不得清掉当前在途条目")
    }
}
