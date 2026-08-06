import XCTest
@testable import WristAgent_Watch_App

/// ESS-321 watch integration smoke test. Drives `WatchRealtimeMediaAdapter`
/// with mock recorder/player/transport and asserts the coordinator's events
/// are routed to the right seam (transport for uplink, player for playback,
/// single-shot fallback on transport failure).
@MainActor
final class WatchRealtimeMediaAdapterTests: XCTestCase {

    func testRealtimePlaybackAudioSessionGateActivatesOncePerTurn() throws {
        var gate = RealtimePlaybackAudioSessionGate()
        var activations = 0

        try gate.activate { activations += 1 }
        try gate.activate { activations += 1 }

        XCTAssertTrue(gate.isActivated)
        XCTAssertEqual(activations, 1)

        gate.reset()
        try gate.activate { activations += 1 }
        XCTAssertEqual(activations, 2)
    }

    func testRealtimePlaybackAudioSessionGateRetriesAfterActivationFailure() {
        enum Failure: Error { case rejected }
        var gate = RealtimePlaybackAudioSessionGate()
        var attempts = 0

        XCTAssertThrowsError(try gate.activate {
            attempts += 1
            throw Failure.rejected
        })
        XCTAssertFalse(gate.isActivated)

        XCTAssertNoThrow(try gate.activate { attempts += 1 })
        XCTAssertTrue(gate.isActivated)
        XCTAssertEqual(attempts, 2)
    }

    private final class MockRecorder: WatchRealtimeMediaAdapter.Recorder {
        var onFrame: ((Data) -> Void)?
        var onFailure: ((Error) -> Void)?
        private(set) var didStart = false
        private(set) var didStop = false

        func start() throws { didStart = true }
        func stop() { didStop = true }

        func feed(_ data: Data) { onFrame?(data) }
        func fail(_ error: Error) { onFailure?(error) }
    }

    private final class MockPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        private(set) var preparedFor: RealtimeMediaSession.TurnHandle?
        private(set) var enqueuedPlayables: [RealtimeDownlinkPlayback.PlayableChunk] = []
        private(set) var bargedInBytes: [Int] = []
        /// ESS-442 B1 adapter-level regression: prove `player.finish(...)`
        /// is invoked *exactly once* on the sync-release + late-chunk trace,
        /// not just "was called at least once".
        private(set) var finishInvocations: [String?] = []
        var finished: Bool { !finishInvocations.isEmpty }
        var finishCount: Int { finishInvocations.count }
        private(set) var stopped = false

        var enqueuedChunks: [VoiceStreamChunk] { enqueuedPlayables.map(\.chunk) }

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws { preparedFor = turn }
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
            enqueuedPlayables.append(contentsOf: playables)
        }
        func bargeIn(clearedBytes: Int) { bargedInBytes.append(clearedBytes) }
        func finish(responseId: String?) { finishInvocations.append(responseId) }
        func stop(barge: Bool) { stopped = true }
    }

    private final class MockTransport: WatchRealtimeMediaAdapter.Transport {
        var onUplinkAcknowledged: ((RealtimeUplinkAck) -> Void)?
        private(set) var startEvents: [RealtimeStreamStart] = []
        private(set) var appendEvents: [VoiceStreamChunk] = []
        private(set) var commitEvents: [RealtimeStreamCommit] = []
        private(set) var playbackStartEvents: [(RealtimeMediaSession.TurnHandle, String)] = []
        private(set) var playbackEndEvents: [(RealtimeMediaSession.TurnHandle, String, Int)] = []
        private(set) var fallbackEvents: [(RealtimeMediaSession.TurnHandle,
                                          RealtimeUplinkStream.FallbackReason)] = []
        private(set) var bargeInRequests: [RealtimeBargeInRequest] = []

        func sendStreamStart(_ start: RealtimeStreamStart) { startEvents.append(start) }
        func sendAudioAppend(_ chunk: VoiceStreamChunk) { appendEvents.append(chunk) }
        func sendAudioCommit(_ commit: RealtimeStreamCommit) { commitEvents.append(commit) }
        func sendPlaybackStarted(handle: RealtimeMediaSession.TurnHandle, responseId: String) {
            playbackStartEvents.append((handle, responseId))
        }
        func sendPlaybackEnded(handle: RealtimeMediaSession.TurnHandle,
                               responseId: String, bytesPlayed: Int) {
            playbackEndEvents.append((handle, responseId, bytesPlayed))
        }
        func fallbackToCompleteFile(handle: RealtimeMediaSession.TurnHandle,
                                    reason: RealtimeUplinkStream.FallbackReason) {
            fallbackEvents.append((handle, reason))
        }
        func sendBargeInRequest(_ request: RealtimeBargeInRequest) {
            bargeInRequests.append(request)
        }
    }

    private final class FallbackCounter {
        private(set) var invocations: [(RealtimeMediaSession.TurnHandle,
                                        RealtimeUplinkStream.FallbackReason)] = []
        func record(_ handle: RealtimeMediaSession.TurnHandle,
                    _ reason: RealtimeUplinkStream.FallbackReason) {
            invocations.append((handle, reason))
        }
    }

    private func makeAdapter(sessionIds: [String]) -> (
        WatchRealtimeMediaAdapter, MockRecorder, MockPlayer, MockTransport, FallbackCounter
    ) {
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let counter = FallbackCounter()
        var index = 0
        var clock: Int64 = 0
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(
                uplinkFrameBytes: 64,
                maxInFlightUplinkBytes: 8 * 1024,
                maxDownlinkBufferBytes: 4 * 1024
            ),
            now: { clock += 10; return clock },
            sessionIdFactory: {
                defer { index += 1 }
                return sessionIds[min(index, sessionIds.count - 1)]
            }
        )
        let adapter = WatchRealtimeMediaAdapter(
            session: session, recorder: recorder, player: player, transport: transport,
            fullFileFallback: { handle, reason in counter.record(handle, reason) }
        )
        return (adapter, recorder, player, transport, counter)
    }

    func testTransportAcknowledgementReleasesCoordinatorUplinkBudget() {
        let requestId = "44444444-4444-4444-4444-444444445200"
        let sessionId = "55555555-5555-5555-5555-555555555200"
        let (adapter, recorder, _, transport, counter) = makeAdapter(sessionIds: [sessionId])
        _ = adapter.beginTurn(requestId: requestId)

        for sequence in 0..<160 { // 10KB total; adapter budget is 8KB.
            recorder.onFrame?(Data(repeating: UInt8(sequence % 255), count: 64))
            guard let chunk = transport.appendEvents.last else {
                return XCTFail("missing append at sequence \(sequence)")
            }
            let ack = RealtimeUplinkAck(
                requestId: chunk.requestId, sessionId: chunk.streamId,
                sequence: chunk.sequence, byteCount: chunk.payload.count
            )
            transport.onUplinkAcknowledged?(ack)
            transport.onUplinkAcknowledged?(ack)
        }
        adapter.commit()

        XCTAssertTrue(counter.invocations.isEmpty)
        XCTAssertEqual(transport.appendEvents.count, 160)
        XCTAssertEqual(transport.commitEvents.last?.sequence, 159)
    }

    func testFullTurnRoutesUplinkToTransportAndDownlinkToPlayer() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, recorder, player, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        let handle = adapter.beginTurn(requestId: requestId)
        XCTAssertTrue(recorder.didStart)
        XCTAssertEqual(player.preparedFor, handle)
        recorder.feed(Data(repeating: 0x11, count: 128)) // 2 frames of 64 bytes
        adapter.commit()

        XCTAssertEqual(transport.startEvents.count, 1)
        XCTAssertEqual(transport.appendEvents.map(\.sequence), [0, 1])
        XCTAssertEqual(transport.commitEvents.count, 1)

        // Simulate downlink chunk from iPhone → adapter → player.
        let downlinkChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1_800_000_000_000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x22, count: 96)
        )
        adapter.ingestDownlink(downlinkChunk)
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0])
    }

    func testTransportFailureTriggersOneShotCompleteFileFallback() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, recorder, _, transport, counter) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        _ = adapter.beginTurn(requestId: requestId)
        recorder.feed(Data(repeating: 0x11, count: 64))
        recorder.fail(NSError(domain: "test", code: 1))
        // Second failure signal must be absorbed.
        recorder.fail(NSError(domain: "test", code: 2))
        XCTAssertEqual(transport.fallbackEvents.count, 1)
        XCTAssertTrue(adapter.didTriggerCompleteFileFallback)
        // Full-file fallback closure invoked exactly once — proves the
        // adapter actually executes the reliable path, not just signals it.
        XCTAssertEqual(counter.invocations.count, 1)
        XCTAssertEqual(counter.invocations.first?.0.requestId, requestId)
    }

    func testZeroPCMFramesFallsBackToCompleteFileOnCommit() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, _, _, transport, counter) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        _ = adapter.beginTurn(requestId: requestId)

        adapter.commit()

        XCTAssertTrue(transport.commitEvents.isEmpty)
        XCTAssertEqual(transport.fallbackEvents.map(\.1), [.noAudioFrames])
        XCTAssertEqual(counter.invocations.map(\.1), [.noAudioFrames])
    }

    func testAdapterStampsRealBridgeResponseIdOnReceipts() {
        // ESS-330: two responses arrive within the same session; playback
        // receipts must echo the actual response_id observed on delta, not
        // the fabricated session id.
        let requestId = "44444444-4444-4444-4444-4444444444a0"
        let sessionId = "55555555-5555-5555-5555-55555555a000"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [sessionId])
        let handle = adapter.beginTurn(requestId: requestId)

        let chunkA = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x11, count: 48)
        )
        adapter.ingestDownlink(chunkA, responseId: "resp-alpha")
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-alpha"
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-alpha", bytesPlayed: 48
        ))

        // Second response with different response_id.
        let chunkB = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 1, capturedAtMs: 2,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x22, count: 48)
        )
        adapter.ingestDownlink(chunkB, responseId: "resp-beta")
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-beta"
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-beta", bytesPlayed: 48
        ))

        XCTAssertEqual(transport.playbackStartEvents.map(\.1), ["resp-alpha", "resp-beta"])
        XCTAssertEqual(transport.playbackEndEvents.map(\.1), ["resp-alpha", "resp-beta"])
        XCTAssertNotEqual(transport.playbackStartEvents.first?.1, handle.sessionId,
                          "session_id must not be used as response_id")
    }

    func testPlaybackReceiptsAreForwardedToTransport() {
        let requestId = "44444444-4444-4444-4444-444444444440"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555559"
        ])
        let handle = adapter.beginTurn(requestId: requestId)
        // Simulate the player firing real started/ended receipts with a real
        // response_id — nil ids no longer produce receipts (ESS-330 v3).
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-x"
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-x", bytesPlayed: 2_048
        ))
        XCTAssertEqual(transport.playbackStartEvents.count, 1)
        XCTAssertEqual(transport.playbackStartEvents.first?.1, "resp-x")
        XCTAssertEqual(transport.playbackEndEvents.count, 1)
        XCTAssertEqual(transport.playbackEndEvents.first?.2, 2_048)
    }

    func testAudioDoneAndPlayerEndedKeepRealtimeTurnAliveForNextResponse() {
        let requestId = "44444444-4444-4444-4444-444444444449"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555559"
        ])
        let handle = adapter.beginTurn(requestId: requestId)

        adapter.markDownlinkComplete(responseId: "resp-late")
        XCTAssertTrue(player.finished)
        XCTAssertEqual(adapter.currentTurn, handle,
                       "audio.done is only a drain marker; it must not clear the turn")

        let lateChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x33, count: 96)
        )
        adapter.ingestDownlink(lateChunk, responseId: "resp-late")
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0])

        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-late", bytesPlayed: 96
        ))
        XCTAssertEqual(adapter.currentTurn, handle,
                       "response ended must not close a multi-response realtime turn")

        let nextResponseChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 1, capturedAtMs: 2,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x44, count: 96)
        )
        adapter.ingestDownlink(nextResponseChunk, responseId: "resp-next")
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0, 1])
    }

    func testExplicitCancelClosesTurnAndRejectsLateChunks() {
        let requestId = "44444444-4444-4444-4444-444444444450"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555560"
        ])
        let handle = adapter.beginTurn(requestId: requestId)

        adapter.cancel()

        XCTAssertNil(adapter.currentTurn)
        XCTAssertTrue(player.stopped)

        let lateChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x55, count: 96)
        )
        adapter.ingestDownlink(lateChunk, responseId: "resp-cancelled")
        XCTAssertTrue(player.enqueuedChunks.isEmpty)
    }

    func testNewTurnBargesInAndPlayerClearsPriorPlayback() {
        let (adapter, recorder, player, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555",
            "66666666-6666-6666-6666-666666666666"
        ])
        let first = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444444441")
        recorder.feed(Data(repeating: 0x11, count: 64))
        let firstDownlink = VoiceStreamChunk(
            requestId: first.requestId, streamId: first.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1, codec: "pcm_s16le",
            sampleRate: 24_000, payload: Data(repeating: 0x22, count: 96)
        )
        adapter.ingestDownlink(firstDownlink)
        let second = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444444442")
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        // The player must have been asked to prepare for the new turn AND to
        // stop (barge) the prior playback via the coordinator.
        XCTAssertEqual(player.preparedFor, second)

        let staleChunk = VoiceStreamChunk(
            requestId: first.requestId, streamId: first.sessionId,
            direction: .downlink, sequence: 1, capturedAtMs: 2, codec: "pcm_s16le",
            sampleRate: 24_000, payload: Data(repeating: 0x33, count: 96)
        )
        adapter.ingestDownlink(staleChunk, responseId: "resp-stale")
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0],
                       "a new turn must reject late chunks from the replaced turn")
    }

    // MARK: - ESS-442 B1 adapter-level regression (毕玄 REQUEST CHANGES)

    /// Closes the loop 毕玄 flagged in his non-author review of #173: the
    /// coordinator-level test in `Tests/Ess442RegressionTests.swift` only
    /// counts `RealtimeMediaSession.Event`s, so it can't directly assert
    /// the three ESS-442 acceptance items on the `WatchRealtimeMediaAdapter`
    /// seam:
    ///
    ///   1. `player.finish(responseId:)` fires **exactly once**
    ///   2. WatchLog `done_barrier_released` is emitted **exactly once**
    ///   3. That unique log line contains `waited_ms=0` (proving the sync
    ///      path — not the async `.doneBarrierReleased` path — emitted it)
    ///
    /// Pre-fix trace on cd86154: two `player.finish`, two logs, one
    /// missing `waited_ms=0`. Post-fix: one `player.finish`, one log,
    /// present `waited_ms=0`.
    func testEss442B1_AdapterEmitsSingleFinishAndSingleReleaseLogWithWaitedMs() {
        let requestId = "44444444-4442-4442-4442-444444424b01"
        let sessionId = "55555555-5555-5555-5555-555555555b01"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [sessionId])

        struct LogEvent {
            let module: String
            let event: String
            let detail: String?
        }
        // Serial dispatch of observer callbacks is guaranteed by WatchLog's
        // internal lock, so a plain array captured by a class ref is safe.
        final class LogSink { var events: [LogEvent] = [] }
        let sink = LogSink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.events.append(LogEvent(module: module, event: event, detail: detail))
        }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)

        // Seq 0..2 delivered in order under generation 1.
        for i in 0..<3 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-B1", generation: 1
            )
        }
        // Synchronous barrier release path: done arrives after 0..2 already
        // emitted, so `markDone` returns `.barrierReleased` immediately and
        // the adapter's `.doneArrived(.barrierReleased)` branch fires
        // `player.finish` + the `waited_ms=0` log.
        adapter.markDownlinkComplete(
            responseId: "r-B1", generation: 1, finalSequence: 2
        )

        // The regression trigger: a duplicate / late downlink chunk after
        // the sync release. Pre-fix this would go through the coordinator's
        // `checkBarrierRelease()` tail and produce a second
        // `.doneBarrierReleased` → second `player.finish` + second log line.
        adapter.ingestDownlink(
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: 2,
                capturedAtMs: 1_800_000_000_002,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: 2, count: 64)
            ),
            responseId: "r-B1", generation: 1
        )

        // Acceptance 1: player.finish exactly once, carrying the right rid.
        XCTAssertEqual(
            player.finishCount, 1,
            "player.finish(...) must be invoked exactly once — a second call after sync release is the B1 regression"
        )
        XCTAssertEqual(player.finishInvocations.first as? String, "r-B1")

        // Acceptance 2 + 3: done_barrier_released emitted exactly once, and
        // the unique line contains `waited_ms=0` (marker for the sync path).
        let releaseLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_released"
        }
        XCTAssertEqual(
            releaseLogs.count, 1,
            "done_barrier_released must be logged exactly once — a duplicate line is R-02 evidence pollution (B1)"
        )
        let detail = releaseLogs.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("waited_ms=0"),
            "the unique done_barrier_released line must carry waited_ms=0 (sync path marker); got detail=\(detail)"
        )
        XCTAssertTrue(
            detail.contains("final_seq=2"),
            "the unique done_barrier_released line must carry final_seq=2; got detail=\(detail)"
        )
    }
}
