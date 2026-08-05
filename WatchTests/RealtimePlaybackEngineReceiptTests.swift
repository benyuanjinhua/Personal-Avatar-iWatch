import XCTest
import AVFoundation
@testable import WristAgent_Watch_App

/// ESS-335 asserts the invariants the pre-fix engine violated:
///
///  * `playback.started` fires only after the first buffer *really* played
///    (its `.dataPlayedBack` completion callback fired) — not on schedule.
///  * `playback.ended` fires only when the input is complete AND every
///    scheduled buffer's completion has fired. `audio.done` must NOT stop
///    the queue mid-drain.
///  * `bytes_played` on the ended receipt equals the sum of actually
///    rendered bytes, never the sum of queued bytes.
///  * Barge-in never lets dropped bytes count toward `bytes_played` of a
///    subsequent receipt.
///
/// The engine reads AVAudioEngine at init time. To keep the test hermetic
/// we drive the accounting via the `internal` `simulateBufferCompletion`
/// hook, which is the same entry point the real `AVAudioPlayerNode`
/// completion closure would call. `enqueue`'s call into
/// `playerNode.scheduleBuffer` is a no-op on a non-started AVAudioEngine,
/// so the counters see the same code path either way.
@MainActor
final class RealtimePlaybackEngineReceiptTests: XCTestCase {
    private var engine: RealtimePlaybackEngine!
    private var events: [RealtimePlaybackEngine.PlaybackEvent] = []
    private let handle = RealtimeMediaSession.TurnHandle(
        requestId: "req-ess335",
        sessionId: "sess-ess335"
    )

    override func setUp() {
        super.setUp()
        engine = RealtimePlaybackEngine(audioEngine: AVAudioEngine())
        events = []
        engine.onPlaybackEvent = { [weak self] in self?.events.append($0) }
        // We deliberately skip engine.prepare(for:) — that would try to
        // start a real AVAudioEngine which is unavailable in the test
        // harness. Instead we set currentTurn via the same public entry
        // points that the coordinator uses; `bindTurnForTest` is the
        // narrowest hook.
        engine.bindTurnForTest(handle)
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    /// The pre-fix engine emitted `.started` from `enqueue` the moment it
    /// pushed a buffer at `scheduleBuffer`. The fix defers `.started` until
    /// the first buffer's `.dataPlayedBack` completion fires.
    func testStartedDoesNotFireOnEnqueueAloneButDoesOnFirstBufferCompletion() {
        engine.enqueueBytesForTest(96)
        XCTAssertTrue(events.isEmpty,
                      "started must not fire on scheduleBuffer — pre-fix regression")
        XCTAssertEqual(engine.bytesQueued, 96)
        XCTAssertEqual(engine.bytesPlayed, 0)

        engine.simulateBufferCompletion(bytes: 96)
        XCTAssertEqual(events, [
            .started(requestId: handle.requestId, sessionId: handle.sessionId)
        ])
        XCTAssertEqual(engine.bytesPlayed, 96)
    }

    /// audio.done arriving before the buffers finish rendering must NOT
    /// stop the player and must NOT emit `.ended` prematurely — the
    /// pre-fix path called playerNode.stop() + reset() here, which threw
    /// away the tail and reported queued bytes as played.
    func testAudioDoneKeepsQueueDrainingAndEndsWithRealBytes() {
        engine.enqueueBytesForTest(200)
        engine.enqueueBytesForTest(300)
        engine.enqueueBytesForTest(500)
        XCTAssertEqual(engine.bytesQueued, 1000)
        XCTAssertEqual(engine.pendingBuffers, 3)

        // audio.done arrives before every buffer has been rendered.
        engine.signalInputComplete()
        XCTAssertTrue(engine.awaitingCompletion)
        XCTAssertFalse(events.contains(where: { if case .ended = $0 { return true }; return false }),
                       ".ended must not fire while buffers are still queued")

        // First render — .started fires now.
        engine.simulateBufferCompletion(bytes: 200)
        XCTAssertEqual(events, [
            .started(requestId: handle.requestId, sessionId: handle.sessionId)
        ])

        // Second render — still draining, no .ended yet.
        engine.simulateBufferCompletion(bytes: 300)
        XCTAssertEqual(events.count, 1)

        // Third + last render — .ended fires with real 1000 bytes.
        engine.simulateBufferCompletion(bytes: 500)
        XCTAssertEqual(events.last,
                       .ended(requestId: handle.requestId,
                              sessionId: handle.sessionId, bytesPlayed: 1000))
    }

    /// If `signalInputComplete` arrives after every buffer already
    /// rendered, `.ended` fires immediately with the real byte total.
    func testAudioDoneAfterFullDrainEndsImmediatelyWithRealBytes() {
        engine.enqueueBytesForTest(400)
        engine.simulateBufferCompletion(bytes: 400)
        XCTAssertEqual(events.last,
                       .started(requestId: handle.requestId, sessionId: handle.sessionId))

        engine.signalInputComplete()
        XCTAssertEqual(events.last,
                       .ended(requestId: handle.requestId,
                              sessionId: handle.sessionId, bytesPlayed: 400))
    }

    /// Empty response (audio.done with no delta ever) — the engine must
    /// still emit an `.ended` so the adapter can close the coordinator
    /// turn. `bytesPlayed` is truthfully 0.
    func testEmptyResponseAudioDoneStillEmitsEndedWithZeroBytes() {
        engine.signalInputComplete()
        XCTAssertEqual(events, [
            .ended(requestId: handle.requestId, sessionId: handle.sessionId, bytesPlayed: 0)
        ])
    }

    /// Barge-in must drop the unrendered portion and NOT let it count
    /// toward `bytesPlayed` of any subsequent `.ended` receipt.
    func testBargeInDroppedBytesNeverCountedTowardBytesPlayed() {
        engine.enqueueBytesForTest(100)
        engine.enqueueBytesForTest(200)
        engine.enqueueBytesForTest(300)

        // Only 100 bytes really made it to the speaker.
        engine.simulateBufferCompletion(bytes: 100)

        // User talks over the response. The coordinator drops 40 unemitted
        // bytes from the downlink buffer; the engine drops the remaining
        // 500 (200 + 300) it had scheduled-but-not-rendered.
        engine.bargeIn(clearedBytes: 40)
        XCTAssertEqual(events.last,
                       .bargedIn(requestId: handle.requestId,
                                 sessionId: handle.sessionId,
                                 bytesDropped: 40 + 500))
        XCTAssertEqual(engine.bytesPlayed, 0, "barge-in must reset played count")

        // A follow-on response arrives on the same turn. Only its bytes
        // should be counted — the dropped ones are gone.
        engine.enqueueBytesForTest(150)
        engine.simulateBufferCompletion(bytes: 150)
        engine.signalInputComplete()
        XCTAssertEqual(events.last,
                       .ended(requestId: handle.requestId,
                              sessionId: handle.sessionId, bytesPlayed: 150))
    }

    /// A `.dataPlayedBack` completion that arrives after `bargeIn` /
    /// `stop` cleared the turn must be dropped silently — otherwise late
    /// callbacks would double-count.
    func testBufferCompletionAfterStopIsAbsorbed() {
        engine.enqueueBytesForTest(100)
        engine.bargeIn(clearedBytes: 0)
        events.removeAll()

        // A late completion for a buffer that was actually cleared —
        // should be a no-op, no receipt fired.
        engine.simulateBufferCompletion(bytes: 100)
        XCTAssertTrue(events.isEmpty,
                      "late buffer completion must not resurrect a torn-down turn")
    }
}
