import XCTest
@testable import WristAgent_Watch_App

/// ESS-321 watch integration smoke test. Drives `WatchRealtimeMediaAdapter`
/// with mock recorder/player/transport and asserts the coordinator's events
/// are routed to the right seam (transport for uplink, player for playback,
/// single-shot fallback on transport failure).
@MainActor
final class WatchRealtimeMediaAdapterTests: XCTestCase {
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
        private(set) var finished = false
        private(set) var stopped = false

        var enqueuedChunks: [VoiceStreamChunk] { enqueuedPlayables.map(\.chunk) }

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws { preparedFor = turn }
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
            enqueuedPlayables.append(contentsOf: playables)
        }
        func bargeIn(clearedBytes: Int) { bargedInBytes.append(clearedBytes) }
        func finish() { finished = true }
        func stop(barge: Bool) { stopped = true }
    }

    private final class MockTransport: WatchRealtimeMediaAdapter.Transport {
        private(set) var startEvents: [RealtimeStreamStart] = []
        private(set) var appendEvents: [VoiceStreamChunk] = []
        private(set) var commitEvents: [RealtimeStreamCommit] = []
        private(set) var playbackStartEvents: [(RealtimeMediaSession.TurnHandle, String)] = []
        private(set) var playbackEndEvents: [(RealtimeMediaSession.TurnHandle, String, Int)] = []
        private(set) var fallbackEvents: [(RealtimeMediaSession.TurnHandle,
                                          RealtimeUplinkStream.FallbackReason)] = []

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

    func testAudioDoneKeepsSessionAliveForNextResponse() {
        let requestId = "44444444-4444-4444-4444-444444444450"
        let sessionId = "55555555-5555-5555-5555-555555555550"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [sessionId])
        let handle = adapter.beginTurn(requestId: requestId)

        func chunk(sequence: Int, byte: UInt8) -> VoiceStreamChunk {
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: sequence, capturedAtMs: Int64(sequence + 1),
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: byte, count: 48)
            )
        }

        adapter.ingestDownlink(chunk(sequence: 0, byte: 0x11), responseId: "resp-a")
        adapter.markDownlinkComplete()
        XCTAssertTrue(player.finished)
        XCTAssertEqual(adapter.currentTurn, handle)

        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-a", bytesPlayed: 48
        ))
        adapter.ingestDownlink(chunk(sequence: 1, byte: 0x22), responseId: "resp-b")

        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0, 1])
        XCTAssertEqual(transport.playbackEndEvents.map(\.1), ["resp-a"])
        XCTAssertEqual(adapter.currentTurn, handle)
    }

    func testCancelAfterAudioDoneRejectsLateChunk() {
        let requestId = "44444444-4444-4444-4444-444444444451"
        let sessionId = "55555555-5555-5555-5555-555555555551"
        var logs: [String] = []
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let session = RealtimeMediaSession(sessionIdFactory: { sessionId })
        let adapter = WatchRealtimeMediaAdapter(
            session: session, recorder: recorder, player: player, transport: transport,
            logger: { logs.append($0) }
        )
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.markDownlinkComplete()
        adapter.cancel()

        let lateChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x33, count: 48)
        )
        adapter.ingestDownlink(lateChunk, responseId: "resp-late")

        XCTAssertTrue(player.enqueuedChunks.isEmpty)
        XCTAssertNil(adapter.currentTurn)
        XCTAssertTrue(logs.contains(where: { $0.contains("downlink_drop reason=staleSession") }))
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
    }
}
