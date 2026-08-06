import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-442 regression tests. Guards the three defects Jackson raised in the
/// second review of PR #164 that landed in main without repair: barrier
/// twice-release on late chunks (B1), silent generation-swap dropping the
/// entire next generation (B2), and future-generation `audio.done` masquerading
/// as stale (B3). Each defect gets both a buffer-level unit and — for B1 —
/// a coordinator-level integration test, since the buffer and its caller
/// share the fault.
final class Ess442RegressionTests: XCTestCase {
    private let requestId = "e5544442-e554-e554-e554-e55444424442"
    private let sessionId = "5e5510dd-5e55-10dd-5e55-10dd5e5510dd"

    private func attached() -> RealtimeDownlinkPlayback {
        var buffer = RealtimeDownlinkPlayback(maxBufferedBytes: 4 * 1024, maxSequenceWindow: 32)
        _ = buffer.attach(session: .init(requestId: requestId, sessionId: sessionId))
        return buffer
    }

    private func delta(_ sequence: Int, bytes: Int = 128) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId, streamId: sessionId, direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1_800_000_000_000 + Int64(sequence),
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: UInt8(sequence % 255), count: bytes)
        )
    }

    // MARK: - B1

    /// Sync release must clear the barrier so `checkBarrierRelease` does NOT
    /// fire a second time on the next tick.
    func testB1_SyncReleaseClearsPendingFinalSequence() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        for i in 0..<3 {
            _ = buffer.ingest(delta(i), responseId: "r1", generation: 1)
        }

        guard case .barrierReleased(let final, _) = buffer.markDone(
            finalSequence: 2, responseId: "r1", generation: 1
        ) else {
            return XCTFail("expected sync .barrierReleased when seq 0..2 already emitted")
        }
        XCTAssertEqual(final, 2)

        XCTAssertNil(
            buffer.checkBarrierRelease(),
            "sync release must clear pendingFinalSequence — otherwise a late chunk re-fires the barrier"
        )
        XCTAssertEqual(buffer.barrierState, .notArmed, "barrier state must fold to notArmed after sync release")
    }

    /// Direct: after sync release, a duplicate / late chunk must NOT re-arm
    /// the barrier through the ingest → `checkBarrierRelease` path.
    func testB1_LateChunkAfterSyncReleaseDoesNotDoubleRelease() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        for i in 0..<3 {
            _ = buffer.ingest(delta(i), responseId: "r1", generation: 1)
        }
        _ = buffer.markDone(finalSequence: 2, responseId: "r1", generation: 1)
        _ = buffer.endSession()

        // Duplicate late arrival — main-line trace: WCSession delivers the
        // same delta twice. Buffer must ignore it, and the coordinator's
        // barrier tick after ingest must not fire again.
        let late = buffer.ingest(delta(2), responseId: "r1", generation: 1)
        if case .dropped(.sessionEnded) = late {} else if case .dropped(.duplicate) = late {} else {
            XCTFail("late delta must be dropped as .sessionEnded or .duplicate, got \(late)")
        }
        XCTAssertNil(buffer.checkBarrierRelease(), "barrier must not re-fire after sync release + endSession")
    }

    /// Coordinator-level: end-to-end reproduction of the double
    /// `.doneBarrierReleased` event that would have shown up on-device.
    /// Before the fix: exactly one `.doneArrived(.barrierReleased)` followed
    /// by one `.doneBarrierReleased` — two `player.finish` calls, two log
    /// lines under the same `response_id`. After: only the `.doneArrived`.
    func testB1_CoordinatorEmitsSingleReleaseOnLateChunk() {
        var events: [RealtimeMediaSession.Event] = []
        let sessionIds = ["11111111-0000-0000-0000-000000000001"]
        var idx = 0
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(uplinkFrameBytes: 128),
            now: { 1_800_000_000_000 },
            sessionIdFactory: { defer { idx += 1 }; return sessionIds[min(idx, sessionIds.count - 1)] }
        )
        session.onEvent = { events.append($0) }
        let handle = session.beginTurn(requestId: "22222222-0000-0000-0000-000000000001")
        session.openGeneration(1)

        for i in 0..<3 {
            session.receiveDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-A", generation: 1
            )
        }
        session.receiveDone(finalSequence: 2, responseId: "r-A", generation: 1)

        // Simulate a duplicate / late downlink chunk arriving AFTER the
        // synchronous barrier release.
        session.receiveDownlink(
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: 2,
                capturedAtMs: 1_800_000_000_002,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: 2, count: 64)
            ),
            responseId: "r-A", generation: 1
        )

        var doneArrivedReleased = 0
        var doneBarrierReleased = 0
        for event in events {
            switch event {
            case .doneArrived(_, .barrierReleased):
                doneArrivedReleased += 1
            case .doneBarrierReleased:
                doneBarrierReleased += 1
            default:
                break
            }
        }
        XCTAssertEqual(doneArrivedReleased, 1, "sync release must fire .doneArrived(.barrierReleased) exactly once")
        XCTAssertEqual(
            doneBarrierReleased, 0,
            "late chunk after sync release must NOT trigger a second .doneBarrierReleased (B1 regression)"
        )
    }

    // MARK: - B2

    /// `.open(g) → .open(g+1)` without a Watch-initiated barge-in must reset
    /// buffer bookkeeping so the new generation's `delta(0)` is admitted,
    /// not rejected as duplicate against the prior generation's emitted set.
    func testB2_OpenGenerationTransitionResetsBufferState() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        for i in 0..<3 {
            _ = buffer.ingest(delta(i), responseId: "r-old", generation: 1)
        }
        XCTAssertEqual(buffer.nextSequence, 3, "sanity: emitted seq 0..2 under gen 1")

        // Directly promote from `.open(1)` to `.open(2)` without the Watch
        // calling `bargeIn()` first. This transition is UNREACHABLE on
        // main today (no `generation.open` sender exists in the codebase —
        // ESS-402 will land the iPhone-side sender), so the test guards a
        // defensive fix; it auto-covers a real regression path the moment
        // that sender ships. Verified reachability trail: L2 evidence in
        // ESS-442 thread 6ab9c363.
        _ = buffer.openGeneration(2)
        XCTAssertEqual(buffer.nextSequence, 0, "new generation must start at seq 0 again")

        let outcome = buffer.ingest(delta(0), responseId: "r-new", generation: 2)
        guard case .ready(let released) = outcome else {
            return XCTFail("new generation's seq 0 must be admitted after B2 fix, got \(outcome)")
        }
        XCTAssertEqual(released.map(\.chunk.sequence), [0])
    }

    /// The idempotent same-generation call must NOT reset — otherwise a
    /// spurious `openGeneration(g)` re-run mid-turn would wipe in-flight
    /// state.
    func testB2_SameGenerationIsStillIdempotent() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        for i in 0..<3 {
            _ = buffer.ingest(delta(i), responseId: "r", generation: 1)
        }
        _ = buffer.openGeneration(1)
        XCTAssertEqual(buffer.nextSequence, 3, "idempotent openGeneration(same) must not reset")
    }

    // MARK: - B3

    /// `audio.done` with a strictly-greater generation must surface on its
    /// own case so the adapter can log `future_generation_dropped kind=done`.
    func testB3_FutureGenerationDoneReturnsDedicatedOutcome() {
        var buffer = attached()
        _ = buffer.openGeneration(1)

        let outcome = buffer.markDone(finalSequence: 4, responseId: "r-future", generation: 3)
        guard case .droppedFutureGeneration(let incoming, let active) = outcome else {
            return XCTFail("expected .droppedFutureGeneration, got \(outcome)")
        }
        XCTAssertEqual(incoming, 3)
        XCTAssertEqual(active, 1)
        // Same posture as the stale case — Watch refuses to self-promote; the
        // current-generation session stays open.
        XCTAssertFalse(buffer.didSessionEnd, "future-generation done must not close the current session")
    }
}
