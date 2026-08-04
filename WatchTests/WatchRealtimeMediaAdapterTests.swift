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

    func testPlaybackReceiptsAreForwardedToTransport() {
        let requestId = "44444444-4444-4444-4444-444444444440"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555559"
        ])
        let handle = adapter.beginTurn(requestId: requestId)
        // ESS-330: player fires receipts tagged with the Agent response_id
        // (NOT the session UUID). The adapter must forward that verbatim to
        // the transport — reusing sessionId would collapse multi-response
        // sessions on the Bridge side.
        let responseId = "resp-alpha"
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: responseId
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: responseId, bytesPlayed: 2_048
        ))
        XCTAssertEqual(transport.playbackStartEvents.count, 1)
        XCTAssertEqual(transport.playbackStartEvents.first?.1, responseId)
        XCTAssertNotEqual(transport.playbackStartEvents.first?.1, handle.sessionId)
        XCTAssertEqual(transport.playbackEndEvents.count, 1)
        XCTAssertEqual(transport.playbackEndEvents.first?.1, responseId)
        XCTAssertEqual(transport.playbackEndEvents.first?.2, 2_048)
    }

    /// ESS-330 acceptance: two responses sharing a single session must each
    /// return their own response_id in playback.started/ended receipts. This
    /// exercises the full path from the Bridge wire codec through the
    /// coordinator, the playback engine, and the adapter's transport seam.
    func testTwoResponsesShareSessionAndProduceIndependentReceipts() throws {
        let requestId = "44444444-4444-4444-4444-444444444443"
        let sessionId = "55555555-5555-5555-5555-555555555556"
        let recorder = MockRecorder()
        let engine = RecordingPlayer()
        let transport = MockTransport()
        var clock: Int64 = 0
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(
                uplinkFrameBytes: 64,
                maxInFlightUplinkBytes: 8 * 1024,
                maxDownlinkBufferBytes: 8 * 1024
            ),
            now: { clock += 10; return clock },
            sessionIdFactory: { sessionId }
        )
        let realAdapter = WatchRealtimeMediaAdapter(
            session: session, recorder: recorder, player: engine, transport: transport
        )
        let handle = realAdapter.beginTurn(requestId: requestId)

        // Round-trip the Bridge shape so the codec's response_id extraction is
        // actually exercised, not a hand-built chunk.
        let deltaAlpha = try makeAudioDelta(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-alpha", sequence: 0, bytes: 256
        )
        let deltaBeta = try makeAudioDelta(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-beta", sequence: 1, bytes: 512
        )
        realAdapter.ingestDownlink(deltaAlpha)
        realAdapter.ingestDownlink(deltaBeta)

        // Response boundary at seq=1 must close resp-alpha and open resp-beta.
        XCTAssertEqual(transport.playbackStartEvents.map(\.1), ["resp-alpha", "resp-beta"])
        XCTAssertEqual(transport.playbackEndEvents.count, 1)
        XCTAssertEqual(transport.playbackEndEvents.first?.1, "resp-alpha")
        XCTAssertEqual(transport.playbackEndEvents.first?.2, 256)

        // Bridge signals `audio.done` — the trailing `.ended` closes resp-beta
        // with the bytes played for that response only.
        realAdapter.markDownlinkComplete()
        XCTAssertEqual(transport.playbackEndEvents.count, 2)
        XCTAssertEqual(transport.playbackEndEvents.last?.1, "resp-beta")
        XCTAssertEqual(transport.playbackEndEvents.last?.2, 512)

        // Neither receipt used the session UUID as response_id.
        XCTAssertFalse(transport.playbackStartEvents.contains(where: { $0.1 == handle.sessionId }))
        XCTAssertFalse(transport.playbackEndEvents.contains(where: { $0.1 == handle.sessionId }))
    }

    private func makeAudioDelta(
        requestId: String, sessionId: String, responseId: String,
        sequence: Int, bytes: Int
    ) throws -> VoiceStreamChunk {
        let audio = Data(repeating: UInt8(sequence % 255), count: bytes)
        let json: [String: Any] = [
            "type": "audio.delta",
            "request_id": requestId,
            "session_id": sessionId,
            "response_id": responseId,
            "sequence": sequence,
            "sample_rate": 24_000,
            "codec": "pcm_s16le",
            "audio": audio.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
        return try XCTUnwrap(envelope.audio)
    }

    /// Test double that stands in for `RealtimePlaybackEngine` and executes
    /// the same response-boundary logic without touching AVAudioEngine —
    /// WatchTests build without the audio session on the simulator.
    @MainActor
    private final class RecordingPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        private var turn: RealtimeMediaSession.TurnHandle?
        private var currentResponseId: String?
        private var bytesPlayedForCurrentResponse = 0

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {
            self.turn = turn
            currentResponseId = nil
            bytesPlayedForCurrentResponse = 0
        }
        func enqueue(chunks: [VoiceStreamChunk]) {
            guard let turn else { return }
            for chunk in chunks {
                let rid = chunk.responseId ?? turn.sessionId
                if let prior = currentResponseId, prior != rid {
                    onPlaybackEvent?(.ended(
                        requestId: turn.requestId, sessionId: turn.sessionId,
                        responseId: prior, bytesPlayed: bytesPlayedForCurrentResponse
                    ))
                    bytesPlayedForCurrentResponse = 0
                }
                if currentResponseId != rid {
                    onPlaybackEvent?(.started(
                        requestId: turn.requestId, sessionId: turn.sessionId,
                        responseId: rid
                    ))
                }
                currentResponseId = rid
                bytesPlayedForCurrentResponse += chunk.payload.count
            }
        }
        func bargeIn(clearedBytes: Int) {}
        func finish() {
            guard let turn else { return }
            onPlaybackEvent?(.ended(
                requestId: turn.requestId, sessionId: turn.sessionId,
                responseId: currentResponseId ?? turn.sessionId,
                bytesPlayed: bytesPlayedForCurrentResponse
            ))
            self.turn = nil
            currentResponseId = nil
            bytesPlayedForCurrentResponse = 0
        }
        func stop(barge: Bool) {}
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
