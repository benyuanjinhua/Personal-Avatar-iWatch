import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-404 unit tests U1–U15 (spec §8.1).
///
/// U1–U6 cover the done barrier and its release / degrade paths (G2 + G3).
/// U7–U10 cover generation isolation (G4). U11 is the `-1` zero-audio
/// contract; U12 the missing-`final_sequence` degrade. U13–U15 cover
/// barge-in interaction with the state machine and the mutual-cancel
/// requirement between the gap timer and the done-barrier timer.
///
/// U8 / U10 / U12 are the three core regressions called out in the spec —
/// reviewer priority is on those three.
final class Ess404DoneBarrierAndGenerationTests: XCTestCase {
    // Validator requires UUID-shaped ids (see `VoiceStreamValidator`).
    private let requestId = "e5540404-e554-e554-e554-e55404040404"
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

    // MARK: - U1: done before any delta with final_seq=3 → DoneWaiting

    func testU1_DoneBeforeFirstDeltaEntersDoneWaiting() {
        var buffer = attached()
        _ = buffer.openGeneration(3)

        let outcome = buffer.markDone(finalSequence: 3, responseId: "r1", generation: 3)

        guard case .waiting(let missing, let responseId) = outcome else {
            return XCTFail("expected .waiting, got \(outcome)")
        }
        XCTAssertEqual(missing, [0, 1, 2, 3])
        XCTAssertEqual(responseId, "r1")
        XCTAssertEqual(buffer.barrierState, .waiting(missing: [0, 1, 2, 3]))
        XCTAssertFalse(buffer.didSessionEnd, "session must not close while barrier is waiting")
    }

    // MARK: - U2: barrier releases after seq 0..3 arrive

    func testU2_BarrierReleasesWhenMissingDeltasArrive() {
        var buffer = attached()
        _ = buffer.openGeneration(3)
        _ = buffer.markDone(finalSequence: 3, responseId: "r1", generation: 3)

        for i in 0..<3 {
            _ = buffer.ingest(delta(i), responseId: "r1", generation: 3)
            XCTAssertNil(buffer.checkBarrierRelease(), "barrier still waiting at seq \(i)")
        }
        _ = buffer.ingest(delta(3), responseId: "r1", generation: 3)
        guard case .barrierReleased(let final, let responseId) = buffer.checkBarrierRelease() else {
            return XCTFail("expected barrier release after seq 0..3")
        }
        XCTAssertEqual(final, 3)
        XCTAssertEqual(responseId, "r1")
    }

    // MARK: - U3: barrier timeout without delta completion

    func testU3_BarrierTimeoutTriggersFallback() {
        var buffer = attached()
        _ = buffer.openGeneration(3)
        _ = buffer.markDone(finalSequence: 3, responseId: "r1", generation: 3)

        let timeout = buffer.doneBarrierTimedOut()
        guard case .fallback(.doneBarrierTimedOut(let missing)) = timeout else {
            return XCTFail("expected barrier timeout fallback, got \(timeout)")
        }
        XCTAssertEqual(missing, [0, 1, 2, 3])
        // Absorbing: a second timeout does not re-fire the fallback.
        XCTAssertEqual(buffer.doneBarrierTimedOut(), .alreadyFellBack)
    }

    // MARK: - U4: partial deltas + done + tail deltas → release after tail

    func testU4_DoneBeforeTailDoesNotCloseSession() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(0), responseId: "r1", generation: 1)
        _ = buffer.ingest(delta(1), responseId: "r1", generation: 1)

        let arrival = buffer.markDone(finalSequence: 4, responseId: "r1", generation: 1)
        if case .barrierReleased = arrival {
            return XCTFail("barrier must not release before tail arrives")
        }

        for i in 2...4 {
            let outcome = buffer.ingest(delta(i), responseId: "r1", generation: 1)
            if case .dropped(.sessionEnded) = outcome {
                XCTFail("session closed prematurely at seq \(i) — this is the G2 regression")
            }
        }
        guard case .barrierReleased(let final, _) = buffer.checkBarrierRelease() else {
            return XCTFail("expected barrier release after tail")
        }
        XCTAssertEqual(final, 4)
    }

    // MARK: - U5: duplicate seq is rejected, bytes accounting unaffected

    func testU5_DuplicateSequenceIsRejected() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(0, bytes: 100), responseId: "r1", generation: 1)
        _ = buffer.ingest(delta(1, bytes: 100), responseId: "r1", generation: 1)
        _ = buffer.ingest(delta(2, bytes: 100), responseId: "r1", generation: 1)

        XCTAssertEqual(
            buffer.ingest(delta(1, bytes: 100), responseId: "r1", generation: 1),
            .dropped(.duplicate)
        )
    }

    // MARK: - U6: out-of-order 2,1 → in-order release 1,2

    func testU6_OutOfOrderDeltasReleaseInSequence() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(0), responseId: "r1", generation: 1)
        XCTAssertEqual(
            buffer.ingest(delta(2), responseId: "r1", generation: 1),
            .buffered
        )
        guard case .ready(let released) = buffer.ingest(delta(1), responseId: "r1", generation: 1) else {
            return XCTFail("expected release of seq 1,2 after gap fill")
        }
        XCTAssertEqual(released.map(\.chunk.sequence), [1, 2])
    }

    // MARK: - U7: activeGeneration=5, incoming delta gen=4 → dropped

    func testU7_StaleGenerationDeltaIsDropped() {
        var buffer = attached()
        _ = buffer.openGeneration(5)

        switch buffer.ingest(delta(0), responseId: "r1", generation: 4) {
        case .dropped(.staleGeneration(let incoming, let active)):
            XCTAssertEqual(incoming, 4)
            XCTAssertEqual(active, 5)
        default:
            XCTFail("expected .staleGeneration drop")
        }
    }

    // MARK: - U8 (core regression): stale done must NOT close current session

    func testU8_StaleGenerationDoneDoesNotCloseCurrentSession() {
        var buffer = attached()
        _ = buffer.openGeneration(5)

        let outcome = buffer.markDone(finalSequence: 2, responseId: "r-old", generation: 4)
        guard case .droppedStaleGeneration(let incoming, let active) = outcome else {
            return XCTFail("expected stale-generation drop, got \(outcome)")
        }
        XCTAssertEqual(incoming, 4)
        XCTAssertEqual(active, 5)

        // G4 core: the current-generation session must still be open. A
        // gen-5 delta arriving now must be admitted, not `.sessionEnded`.
        let admitted = buffer.ingest(delta(0), responseId: "r-new", generation: 5)
        if case .dropped(.sessionEnded) = admitted {
            XCTFail("stale generation's done closed the current session — G4 regressed")
        }
    }

    // MARK: - U9: pending window drops every delta

    func testU9_PendingWindowDropsIncomingDeltas() {
        var buffer = attached()
        _ = buffer.openGeneration(5)
        _ = buffer.bargeIn()

        switch buffer.ingest(delta(0), responseId: "r", generation: 6) {
        case .dropped(.pendingGeneration(let incoming)):
            XCTAssertEqual(incoming, 6)
        default:
            XCTFail("expected pending-generation drop")
        }
        // Even chunks with no generation are dropped in the pending window
        // — the whole point is "we don't know which stream to trust".
        switch buffer.ingest(delta(0), responseId: "r", generation: nil) {
        case .dropped(.pendingGeneration):
            break
        default:
            XCTFail("legacy delta must also drop in pending window")
        }
    }

    // MARK: - U10 (core regression): stale delta after barge-in must NOT re-open

    func testU10_StaleDeltaAfterBargeInIsRejected() {
        var buffer = attached()
        _ = buffer.openGeneration(5)
        _ = buffer.ingest(delta(0), responseId: "r-old", generation: 5)
        _ = buffer.bargeIn()
        _ = buffer.openGeneration(6)

        // A stale gen-5 delta with seq=0 arrives after barge-in. Before
        // ESS-404 this was admitted because `nextSequence` had been reset
        // to 0. Now it must be dropped as `.staleGeneration`.
        switch buffer.ingest(delta(0), responseId: "r-old", generation: 5) {
        case .dropped(.staleGeneration(let incoming, let active)):
            XCTAssertEqual(incoming, 5)
            XCTAssertEqual(active, 6)
        default:
            XCTFail("stale gen-5 delta must NOT be re-admitted after barge-in — G4 regressed")
        }
    }

    // MARK: - U11: final_sequence=-1 → zero-audio, immediate completion

    func testU11_FinalSequenceMinusOneMarksZeroAudio() {
        var buffer = attached()
        _ = buffer.openGeneration(1)

        let outcome = buffer.markDone(finalSequence: -1, responseId: "r-zero", generation: 1)
        guard case .zeroAudio(let responseId) = outcome else {
            return XCTFail("expected .zeroAudio for final_seq=-1, got \(outcome)")
        }
        XCTAssertEqual(responseId, "r-zero")
        XCTAssertEqual(buffer.barrierState, .zeroAudio)
    }

    // MARK: - U12 (core regression): missing final_sequence must NOT emit zero-byte ended

    func testU12_MissingFinalSequenceDegradesWithoutZeroByteEnded() {
        var buffer = attached()
        _ = buffer.openGeneration(1)

        let outcome = buffer.markDone(finalSequence: nil, responseId: "r-bad", generation: 1)
        guard case .missingFinalSequence(let nextSeqSeen, let responseId) = outcome else {
            return XCTFail("expected .missingFinalSequence, got \(outcome)")
        }
        // No deltas were seen, so `nextSeqSeen == -1`. Critically this
        // outcome is NOT `.barrierReleased` / `.zeroAudio` — meaning the
        // adapter will emit `done_missing_final_sequence` (structured
        // failure) instead of the pre-ESS-404 zero-byte `.ended`.
        XCTAssertEqual(nextSeqSeen, -1)
        XCTAssertEqual(responseId, "r-bad")

        // Cross-check the tracker: `requestDrain` with no delta seen must
        // also emit no receipt (the G3 fix inside the tracker layer).
        var tracker = RealtimePlaybackReceiptTracker()
        XCTAssertNil(tracker.requestDrain(), "tracker must not fabricate zero-byte ended")
    }

    // MARK: - U13: bargeIn clears buffered bytes and reports them

    func testU13_BargeInReportsDroppedBytesAndTransitionsToPending() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(0, bytes: 256), responseId: "r", generation: 1)
        _ = buffer.ingest(delta(2, bytes: 256), responseId: "r", generation: 1) // buffered

        let outcome = buffer.bargeIn()
        guard case .bargedIn(let cleared) = outcome else {
            return XCTFail("expected .bargedIn outcome")
        }
        // Seq 0 was released (its 256 bytes accounted for), seq 2 was still
        // buffered so its 256 bytes remain in `bufferedBytes` at barge time.
        XCTAssertEqual(cleared, 256)
        XCTAssertEqual(buffer.generationState, .pending)
        XCTAssertEqual(buffer.activeGeneration, nil)
    }

    // MARK: - U14: cancel-failed collapses to single fallback

    func testU14_BargeInCancelFailedAbsorbsToSingleFallback() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.bargeIn()
        // Simulate iPhone reporting cancel failure by triggering the same
        // absorbing path (bridge fallback). A second failure signal must
        // fold to `.alreadyFellBack`, i.e. only one full-file fallback.
        XCTAssertEqual(buffer.markBridgeFallback(), .fallback(.bridgeReportedFallback))
        XCTAssertEqual(buffer.markBridgeFallback(), .alreadyFellBack)
    }

    // MARK: - U15: gap timer and barrier timer share a single fallback slot

    func testU15_GapAndBarrierTimersShareSingleFallback() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(1), responseId: "r", generation: 1) // head-of-line stuck at 0
        _ = buffer.markDone(finalSequence: 3, responseId: "r", generation: 1)

        // Gap timer fires first: single fallback consumed.
        XCTAssertEqual(buffer.gapTimedOut(), .fallback(.gapTimedOut))
        // Barrier timer fires second: absorbed, no double-execution.
        XCTAssertEqual(buffer.doneBarrierTimedOut(), .alreadyFellBack)
    }

    // MARK: - U16 (ESS-442 B1): synchronous release + late chunk → no second release

    /// Reproduces ESS-442 B1: `markDone`'s synchronous release path retained
    /// `pendingFinalSequence`, so a late / duplicate downlink chunk arriving
    /// after `endSession()` re-satisfied `checkBarrierRelease()` and produced
    /// a second `.barrierReleased` — leading to a duplicate
    /// `done_barrier_released` log entry and a second `player.finish(...)`.
    func testU16_SyncReleaseThenLateChunkDoesNotDoubleRelease() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(0), responseId: "r-late", generation: 1)
        _ = buffer.ingest(delta(1), responseId: "r-late", generation: 1)
        _ = buffer.ingest(delta(2), responseId: "r-late", generation: 1)

        // Barrier arms + releases synchronously because 0..2 are already in.
        let arrival = buffer.markDone(finalSequence: 2, responseId: "r-late", generation: 1)
        guard case .barrierReleased(let final, let rid) = arrival else {
            return XCTFail("expected synchronous barrier release, got \(arrival)")
        }
        XCTAssertEqual(final, 2)
        XCTAssertEqual(rid, "r-late")

        // Coordinator closes the session after synchronous release.
        _ = buffer.endSession()

        // Late / duplicate delta comes in through the reorder buffer — it is
        // dropped as .sessionEnded / .duplicate. Either way the coordinator
        // then polls `checkBarrierRelease()` and it MUST NOT fire again.
        _ = buffer.ingest(delta(2), responseId: "r-late", generation: 1)
        XCTAssertNil(
            buffer.checkBarrierRelease(),
            "barrier must not release a second time after sync release + endSession"
        )
        // Barrier state is also cleared — sanity check on the invariant.
        XCTAssertEqual(buffer.barrierState, .notArmed)
    }

    // MARK: - U17 (ESS-442 B2): openGeneration `.open(g) → .open(g+1)` accepts new seq 0

    /// Reproduces ESS-442 B2: `openGeneration` did not reset the buffer state
    /// on `.open(g) → .open(g+1)`, so the new generation's seq 0 fell into the
    /// old `emittedSequences` set and was dropped as `.duplicate`. iPhone can
    /// legitimately advance the generation via the wire `generation.open`
    /// envelope (`Shared/RealtimeMediaWireFormat.swift` +
    /// `Watch/WatchSettingsStore.swift`), so this path IS reachable without a
    /// Watch-initiated `bargeIn()`.
    func testU17_OpenGenerationOpenToOpenAcceptsNewFirstDelta() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(0), responseId: "r-g1", generation: 1)
        _ = buffer.ingest(delta(1), responseId: "r-g1", generation: 1)
        _ = buffer.ingest(delta(2), responseId: "r-g1", generation: 1)

        // iPhone-driven direct promotion — Watch never called `bargeIn()`.
        _ = buffer.openGeneration(2)

        XCTAssertEqual(buffer.activeGeneration, 2)
        XCTAssertEqual(buffer.nextSequence, 0, "sequence counter must reset for new gen")

        // New generation's seq 0 must be released, not dropped as duplicate.
        let outcome = buffer.ingest(delta(0), responseId: "r-g2", generation: 2)
        guard case .ready(let released) = outcome else {
            return XCTFail(
                "gen-2 seq 0 must be accepted after direct .open(g)->.open(g+1), got \(outcome)"
            )
        }
        XCTAssertEqual(released.map(\.chunk.sequence), [0])
        XCTAssertEqual(released.first?.responseId, "r-g2")

        // The old generation's emitted set must not leak into the new one.
        let secondFrame = buffer.ingest(delta(1), responseId: "r-g2", generation: 2)
        if case .dropped = secondFrame {
            XCTFail("gen-2 seq 1 must not inherit gen-1 emitted state, got \(secondFrame)")
        }
    }

    /// Complementary to U17: the idempotent path (`openGeneration(g)` when
    /// already `.open(g)`) must NOT wipe emitted state and reject in-flight
    /// deltas — that would be a regression of its own.
    func testU17b_OpenGenerationSameGenIsStillIdempotent() {
        var buffer = attached()
        _ = buffer.openGeneration(1)
        _ = buffer.ingest(delta(0), responseId: "r", generation: 1)
        _ = buffer.ingest(delta(1), responseId: "r", generation: 1)

        _ = buffer.openGeneration(1) // no-op

        XCTAssertEqual(buffer.nextSequence, 2, "same-gen open must not reset counters")
        XCTAssertEqual(
            buffer.ingest(delta(1), responseId: "r", generation: 1),
            .dropped(.duplicate),
            "already-emitted seq must still dedupe after idempotent open"
        )
    }

    // MARK: - U18 (ESS-442 B3): future generation on done routes to its own outcome

    /// Reproduces ESS-442 B3: `markDone` folded `.futureGeneration` into
    /// `.droppedStaleGeneration`, so the adapter logged
    /// `stale_generation_dropped kind=done` for a done that Watch had not yet
    /// seen `generation.open` for. Diagnosis-critical: stale means "old frame
    /// arrived late"; future means "we missed a `generation.open` downlink" —
    /// they route to different fixes.
    func testU18_FutureGenerationDoneRoutesToFutureOutcome() {
        var buffer = attached()
        _ = buffer.openGeneration(3)

        let outcome = buffer.markDone(finalSequence: 2, responseId: "r-future", generation: 5)
        guard case .droppedFutureGeneration(let incoming, let active) = outcome else {
            return XCTFail("expected .droppedFutureGeneration, got \(outcome)")
        }
        XCTAssertEqual(incoming, 5)
        XCTAssertEqual(active, 3)

        // Session must remain open under the current generation — a future
        // done must not close it.
        let admitted = buffer.ingest(delta(0), responseId: "r-now", generation: 3)
        if case .dropped(.sessionEnded) = admitted {
            XCTFail("future-generation done closed the current session")
        }
    }
}
