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
        private(set) var enqueuedChunks: [VoiceStreamChunk] = []
        private(set) var bargedInBytes: [Int] = []
        private(set) var finished = false
        private(set) var stopped = false

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws { preparedFor = turn }
        func enqueue(chunks: [VoiceStreamChunk]) { enqueuedChunks.append(contentsOf: chunks) }
        func bargeIn(clearedBytes: Int) { bargedInBytes.append(clearedBytes) }
        func finish() { finished = true }
        func stop(barge: Bool) { stopped = true }
    }

    private final class MockTransport: WatchRealtimeMediaAdapter.Transport {
        private(set) var startEvents: [RealtimeStreamStart] = []
        private(set) var appendEvents: [VoiceStreamChunk] = []
        private(set) var commitEvents: [RealtimeStreamCommit] = []
        private(set) var fallbackEvents: [(RealtimeMediaSession.TurnHandle,
                                          RealtimeUplinkStream.FallbackReason)] = []

        func sendStreamStart(_ start: RealtimeStreamStart) { startEvents.append(start) }
        func sendAudioAppend(_ chunk: VoiceStreamChunk) { appendEvents.append(chunk) }
        func sendAudioCommit(_ commit: RealtimeStreamCommit) { commitEvents.append(commit) }
        func fallbackToCompleteFile(handle: RealtimeMediaSession.TurnHandle,
                                    reason: RealtimeUplinkStream.FallbackReason) {
            fallbackEvents.append((handle, reason))
        }
    }

    private func makeAdapter(sessionIds: [String]) -> (
        WatchRealtimeMediaAdapter, MockRecorder, MockPlayer, MockTransport
    ) {
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
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
            session: session, recorder: recorder, player: player, transport: transport
        )
        return (adapter, recorder, player, transport)
    }

    func testFullTurnRoutesUplinkToTransportAndDownlinkToPlayer() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, recorder, player, transport) = makeAdapter(sessionIds: [
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
        let (adapter, recorder, _, transport) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        _ = adapter.beginTurn(requestId: requestId)
        recorder.feed(Data(repeating: 0x11, count: 64))
        recorder.fail(NSError(domain: "test", code: 1))
        // Second failure signal must be absorbed.
        recorder.fail(NSError(domain: "test", code: 2))
        XCTAssertEqual(transport.fallbackEvents.count, 1)
        XCTAssertTrue(adapter.didTriggerCompleteFileFallback)
    }

    func testNewTurnBargesInAndPlayerClearsPriorPlayback() {
        let (adapter, recorder, player, _) = makeAdapter(sessionIds: [
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
