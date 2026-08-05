import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-330 v3 + ESS-335 regression tests. Together these lock down the
/// per-chunk `response_id` preservation Bixuan's counter-example demanded
/// and the real-completion-driven playback receipts ESS-335 required.
final class RealtimeResponseIdAndPlaybackTests: XCTestCase {
    private let requestId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let sessionId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private func chunk(
        _ sequence: Int, bytes: Int = 64
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId, streamId: sessionId, direction: .downlink,
            sequence: sequence, capturedAtMs: 1_800_000_000_000 + Int64(sequence),
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: UInt8(sequence % 255), count: bytes)
        )
    }

    private func attachedBuffer() -> RealtimeDownlinkPlayback {
        var buffer = RealtimeDownlinkPlayback()
        _ = buffer.attach(session: .init(requestId: requestId, sessionId: sessionId))
        return buffer
    }

    // MARK: - ESS-330 v3: Bixuan's counter-example

    func testOutOfOrderReleaseKeepsResponseIdPerChunk() {
        // Bixuan's exact scenario: resp-B/seq1 buffered, then resp-A/seq0
        // arrives and releases both [0(A), 1(B)]. The old global
        // `currentResponseId` mis-routed both to the latest arrival's id.
        var buffer = attachedBuffer()
        XCTAssertEqual(buffer.ingest(chunk(1), responseId: "resp-B"), .buffered)
        guard case .ready(let released) = buffer.ingest(chunk(0), responseId: "resp-A") else {
            return XCTFail("expected release of [0, 1] on seq=0 arrival")
        }
        XCTAssertEqual(released.map(\.chunk.sequence), [0, 1])
        XCTAssertEqual(released.map(\.responseId), ["resp-A", "resp-B"])
    }

    func testTwoResponsesInOneSessionReleaseWithOwnIds() {
        var buffer = attachedBuffer()
        for i in 0..<3 {
            let responseId = i < 2 ? "resp-A" : "resp-B"
            guard case .ready(let released) = buffer.ingest(chunk(i), responseId: responseId) else {
                return XCTFail("expected single-chunk release at seq=\(i)")
            }
            XCTAssertEqual(released.first?.chunk.sequence, i)
            XCTAssertEqual(released.first?.responseId, responseId)
        }
    }

    func testMissingResponseIdReleasesAsNil() {
        var buffer = attachedBuffer()
        guard case .ready(let released) = buffer.ingest(chunk(0), responseId: nil) else {
            return XCTFail("expected release")
        }
        XCTAssertNil(released.first?.responseId, "nil response_id must not be fabricated")
    }

    // MARK: - ESS-335: real-completion-driven playback receipts

    func testStartedDoesNotFireOnEnqueue() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-1", bytes: 100)
        tracker.enqueue(responseId: "resp-1", bytes: 100)
        // No completion has fired — no receipts.
        XCTAssertEqual(tracker.responseOrder, ["resp-1"])
    }

    func testStartedFiresOnFirstCompletionOnly() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-1", bytes: 100)
        tracker.enqueue(responseId: "resp-1", bytes: 200)
        let first = tracker.bufferCompleted(responseId: "resp-1", bytes: 100)
        XCTAssertEqual(first.started?.responseId, "resp-1")
        XCTAssertNil(first.ended, "no ended without drain request")
        let second = tracker.bufferCompleted(responseId: "resp-1", bytes: 200)
        XCTAssertNil(second.started, "started fires exactly once per response")
        XCTAssertNil(second.ended, "no ended without drain request")
    }

    func testEndedFiresAfterDrainAndAllBuffersComplete() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-1", bytes: 100)
        tracker.enqueue(responseId: "resp-1", bytes: 200)
        _ = tracker.bufferCompleted(responseId: "resp-1", bytes: 100)
        // Drain requested before last buffer completes — ended waits.
        XCTAssertNil(tracker.requestDrain(), "ended waits for last buffer")
        let last = tracker.bufferCompleted(responseId: "resp-1", bytes: 200)
        XCTAssertEqual(last.ended, RealtimePlaybackReceiptTracker.EndedReceipt(
            responseId: "resp-1", bytesPlayed: 300
        ))
    }

    func testEndedFiresImmediatelyWhenDrainArrivesAfterLastCompletion() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-1", bytes: 100)
        _ = tracker.bufferCompleted(responseId: "resp-1", bytes: 100)
        let ended = tracker.requestDrain()
        XCTAssertEqual(ended, RealtimePlaybackReceiptTracker.EndedReceipt(
            responseId: "resp-1", bytesPlayed: 100
        ))
    }

    func testBargeExcludesUnplayedBytes() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-1", bytes: 100)
        tracker.enqueue(responseId: "resp-1", bytes: 200)
        tracker.enqueue(responseId: "resp-1", bytes: 300)
        _ = tracker.bufferCompleted(responseId: "resp-1", bytes: 100)
        // 200 + 300 bytes queued but not yet played — barge drops them.
        let receipts = tracker.bargeAll()
        XCTAssertEqual(receipts, [
            RealtimePlaybackReceiptTracker.BargedInReceipt(
                responseId: "resp-1", bytesDropped: 500
            )
        ])
    }

    func testEarlierResponseEndsWhenSupersededAndFullyPlayed() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-A", bytes: 100)
        tracker.enqueue(responseId: "resp-B", bytes: 200)
        // A's only buffer completes AFTER B has been queued — A is now
        // superseded, so its ended fires without needing an explicit drain.
        let receipts = tracker.bufferCompleted(responseId: "resp-A", bytes: 100)
        XCTAssertEqual(receipts.ended, RealtimePlaybackReceiptTracker.EndedReceipt(
            responseId: "resp-A", bytesPlayed: 100
        ))
    }

    func testDrainWithNoQueueEmitsEmptyEnded() {
        var tracker = RealtimePlaybackReceiptTracker()
        let ended = tracker.requestDrain()
        XCTAssertEqual(ended, RealtimePlaybackReceiptTracker.EndedReceipt(
            responseId: nil, bytesPlayed: 0
        ))
    }

    func testIdentifiedDrainBeforeDeltaWaitsForRealPlayback() {
        var tracker = RealtimePlaybackReceiptTracker()

        XCTAssertNil(
            tracker.requestDrain(responseId: "resp-late"),
            "identified audio.done must not fabricate a zero-byte receipt before its delta arrives"
        )
        tracker.enqueue(responseId: "resp-late", bytes: 192)
        let completed = tracker.bufferCompleted(responseId: "resp-late", bytes: 192)

        XCTAssertEqual(completed.started?.responseId, "resp-late")
        XCTAssertEqual(completed.ended, RealtimePlaybackReceiptTracker.EndedReceipt(
            responseId: "resp-late", bytesPlayed: 192
        ))
    }

    func testAnonymousResponseTracksIndependentlyButEmitsNilId() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: nil, bytes: 128)
        let first = tracker.bufferCompleted(responseId: nil, bytes: 128)
        XCTAssertEqual(first.started, RealtimePlaybackReceiptTracker.StartedReceipt(
            responseId: nil
        ))
        let ended = tracker.requestDrain()
        XCTAssertEqual(ended, RealtimePlaybackReceiptTracker.EndedReceipt(
            responseId: nil, bytesPlayed: 128
        ))
    }
}
