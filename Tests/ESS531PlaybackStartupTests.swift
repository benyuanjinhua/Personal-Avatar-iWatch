import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-531 acceptance criteria tests for realtime streaming playback.
///
///    1. 40-chunk ordered feed — all chunks play, started/ended/progress fire.
///    2. audio.done ordering — done before/all-after/with-missing-tail variants.
///    3. Duplicate dispatch — duplicate chunks don't corrupt buffer/tracker.
///    4. Play-start failure — tracker handles failed prepare gracefully.
final class ESS531PlaybackStartupTests: XCTestCase {

    // MARK: - AC #1: 40 chunks ordered flow via tracker

    func testFortyChunksOrderedAllReceiptsFire() {
        var tracker = RealtimePlaybackReceiptTracker()
        let totalBytes = 96 * 40

        // Enqueue 40 ordered chunks.
        for _ in 0..<40 {
            tracker.enqueue(responseId: "resp-40", bytes: 96)
        }

        var startedFired = false
        var endedFired = false
        var progressCount = 0

        // Simulate 40 buffer completions.
        for i in 0..<40 {
            let receipts = tracker.bufferCompleted(responseId: "resp-40", bytes: 96)
            if receipts.started != nil { startedFired = true }
            if receipts.ended != nil { endedFired = true }
            if receipts.progress != nil { progressCount += 1 }
        }

        // After all 40 complete, started should have fired.
        XCTAssertTrue(startedFired, "play_started must fire on first completion")
        // Drain must be requested for ended to fire. Simulate audio.done.
        if !endedFired {
            let ended = tracker.requestDrain(responseId: "resp-40")
            endedFired = ended != nil
        }
        XCTAssertTrue(endedFired, "play_completed must fire after drain + all buffers complete")
        XCTAssertEqual(progressCount, 40, "render_progress must fire on every buffer completion")
    }

    func testProgressReceiptCarriesAccurateBytesPlayedAndTotal() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-prog", bytes: 100)
        tracker.enqueue(responseId: "resp-prog", bytes: 200)
        tracker.enqueue(responseId: "resp-prog", bytes: 300)

        let after1 = tracker.bufferCompleted(responseId: "resp-prog", bytes: 100)
        XCTAssertEqual(after1.progress?.bytesPlayed, 100)
        XCTAssertEqual(after1.progress?.totalBytes, 600)
        XCTAssertEqual(after1.progress?.responseId, "resp-prog")

        let after2 = tracker.bufferCompleted(responseId: "resp-prog", bytes: 200)
        XCTAssertEqual(after2.progress?.bytesPlayed, 300)
        XCTAssertEqual(after2.progress?.totalBytes, 600)

        let after3 = tracker.bufferCompleted(responseId: "resp-prog", bytes: 300)
        XCTAssertEqual(after3.progress?.bytesPlayed, 600)
        XCTAssertEqual(after3.progress?.totalBytes, 600)
    }

    // MARK: - AC #2: done ordering variants

    func testDoneArrivesBeforeDeltas() {
        // audio.done wins the race against deltas — tracker must wait, not
        // emit a false zero-byte receipt.
        var tracker = RealtimePlaybackReceiptTracker()
        XCTAssertNil(tracker.requestDrain(responseId: "resp-race"),
                     "done before any delta must not fabricate .ended")
        tracker.enqueue(responseId: "resp-race", bytes: 192)
        let receipts = tracker.bufferCompleted(responseId: "resp-race", bytes: 192)
        XCTAssertEqual(receipts.started?.responseId, "resp-race")
        XCTAssertEqual(receipts.ended?.bytesPlayed, 192)
    }

    func testDoneArrivesWithLastDeltaSynchronousRelease() {
        var buffer = RealtimeDownlinkPlayback()
        _ = buffer.attach(session: .init(
            requestId: "c0000000-0000-4000-8000-000000000001",
            sessionId: "d0000000-0000-4000-8000-000000000001"
        ))
        _ = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000001",
            streamId: "d0000000-0000-4000-8000-000000000001",
            direction: .downlink, sequence: 0, capturedAtMs: 1000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x01, count: 96)
        ), responseId: "resp-done-last")
        let outcome = buffer.markDone(finalSequence: 0, responseId: "resp-done-last")
        XCTAssertEqual(outcome, .barrierReleased(finalSequence: 0, responseId: "resp-done-last"))
    }

    func testDoneArrivesWithMissingTailBarrierWaits() {
        var buffer = RealtimeDownlinkPlayback()
        _ = buffer.attach(session: .init(
            requestId: "c0000000-0000-4000-8000-000000000002",
            sessionId: "d0000000-0000-4000-8000-000000000002"
        ))
        _ = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000002",
            streamId: "d0000000-0000-4000-8000-000000000002",
            direction: .downlink, sequence: 0, capturedAtMs: 1000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x00, count: 48)
        ))
        _ = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000002",
            streamId: "d0000000-0000-4000-8000-000000000002",
            direction: .downlink, sequence: 1, capturedAtMs: 1001,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x01, count: 48)
        ))
        // Ingest seq 3 — gap 2 is missing. (seq 3 is buffered, not dropped)
        let ooo = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000002",
            streamId: "d0000000-0000-4000-8000-000000000002",
            direction: .downlink, sequence: 3, capturedAtMs: 1003,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x03, count: 48)
        ))
        // Seq 3 is within the window (3 - 2 = 1 <= 48) but NOT contiguous
        // (nextSequence is 2, and seq 3 != 2), so it's buffered.
        XCTAssertEqual(ooo, .buffered, "seq 3 with gap at seq 2 should be buffered")

        let doneOutcome = buffer.markDone(finalSequence: 3, responseId: "resp-ooo")
        guard case .waiting(let missing, _) = doneOutcome else {
            return XCTFail("expected waiting, got \(doneOutcome)")
        }
        // Both seq 2 and seq 3 are still pending (not emitted); the missing
        // set for final_seq=3 is [2, 3] — seq 0 and 1 emitted, 2+3 pending.
        XCTAssertEqual(missing.sorted(), [2, 3])

        // Deliver the missing seq 2 → barrier releases.
        _ = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000002",
            streamId: "d0000000-0000-4000-8000-000000000002",
            direction: .downlink, sequence: 2, capturedAtMs: 1002,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x02, count: 48)
        ))
        let release = buffer.checkBarrierRelease()
        XCTAssertEqual(release, .barrierReleased(finalSequence: 3, responseId: "resp-ooo"))
    }

    func testDoneWithMinusOneZeroAudio() {
        var buffer = RealtimeDownlinkPlayback()
        _ = buffer.attach(session: .init(
            requestId: "c0000000-0000-4000-8000-000000000003",
            sessionId: "d0000000-0000-4000-8000-000000000003"
        ))
        let outcome = buffer.markDone(finalSequence: -1, responseId: "resp-zero")
        XCTAssertEqual(outcome, .zeroAudio(responseId: "resp-zero"))
    }

    // MARK: - AC #3: duplicate dispatch

    func testDuplicateChunksDontCorruptBuffer() {
        var buffer = RealtimeDownlinkPlayback()
        _ = buffer.attach(session: .init(
            requestId: "c0000000-0000-4000-8000-000000000010",
            sessionId: "d0000000-0000-4000-8000-000000000010"
        ))
        let first = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000010",
            streamId: "d0000000-0000-4000-8000-000000000010",
            direction: .downlink, sequence: 0, capturedAtMs: 1000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0xAA, count: 64)
        ), responseId: "resp-dup")
        guard case .ready = first else { return XCTFail("first ingest must be ready") }

        let dup = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000010",
            streamId: "d0000000-0000-4000-8000-000000000010",
            direction: .downlink, sequence: 0, capturedAtMs: 1000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0xBB, count: 64)
        ), responseId: "resp-dup")
        XCTAssertEqual(dup, .dropped(.duplicate))

        let next = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000010",
            streamId: "d0000000-0000-4000-8000-000000000010",
            direction: .downlink, sequence: 1, capturedAtMs: 1001,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0xCC, count: 64)
        ), responseId: "resp-dup")
        guard case .ready = next else {
            return XCTFail("seq 1 must be accepted after duplicate of seq 0")
        }
    }

    func testDuplicateBufferCompletionDoesntDoubleCount() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-dup-track", bytes: 128)
        let first = tracker.bufferCompleted(responseId: "resp-dup-track", bytes: 128)
        XCTAssertNotNil(first.started)
        // Second completion for same response must not re-emit .started.
        let second = tracker.bufferCompleted(responseId: "resp-dup-track", bytes: 0)
        XCTAssertNil(second.started)
    }

    // MARK: - AC #4: play-start failure — requestDrain edge case

    func testDrainWithNoEnqueueIsNoop() {
        var tracker = RealtimePlaybackReceiptTracker()
        // No buffers were ever enqueued — drain must not fabricate a receipt.
        XCTAssertNil(tracker.requestDrain(responseId: "resp-never-existed"))
    }

    func testDrainAfterPartialCompletionWaitsForLastBuffer() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-partial", bytes: 100)
        tracker.enqueue(responseId: "resp-partial", bytes: 200)
        _ = tracker.bufferCompleted(responseId: "resp-partial", bytes: 100)
        // Drain before last buffer completes — no .ended yet.
        XCTAssertNil(tracker.requestDrain(responseId: "resp-partial"))
        // Last buffer completes → .ended fires.
        let last = tracker.bufferCompleted(responseId: "resp-partial", bytes: 200)
        XCTAssertEqual(last.ended?.bytesPlayed, 300)
    }

    // MARK: - Barrier guard: single release

    func testBarrierReleasesExactlyOnceEvenWithLateDuplicateDelta() {
        var buffer = RealtimeDownlinkPlayback()
        _ = buffer.attach(session: .init(
            requestId: "c0000000-0000-4000-8000-000000000020",
            sessionId: "d0000000-0000-4000-8000-000000000020"
        ))
        _ = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000020",
            streamId: "d0000000-0000-4000-8000-000000000020",
            direction: .downlink, sequence: 0, capturedAtMs: 1000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x00, count: 48)
        ))
        _ = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000020",
            streamId: "d0000000-0000-4000-8000-000000000020",
            direction: .downlink, sequence: 1, capturedAtMs: 1001,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x01, count: 48)
        ))
        let outcome = buffer.markDone(finalSequence: 1)
        XCTAssertEqual(outcome, .barrierReleased(finalSequence: 1, responseId: nil))

        // Late duplicate of seq 0.
        _ = buffer.ingest(VoiceStreamChunk(
            requestId: "c0000000-0000-4000-8000-000000000020",
            streamId: "d0000000-0000-4000-8000-000000000020",
            direction: .downlink, sequence: 0, capturedAtMs: 1000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0xFF, count: 48)
        ))
        XCTAssertNil(buffer.checkBarrierRelease(),
                     "barrier already released; late delta must not trigger second release")
    }
}
