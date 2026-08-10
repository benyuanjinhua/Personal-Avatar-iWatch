import XCTest
@testable import WristAgent_Watch_App

/// ESS-321 watch integration smoke test. Drives `WatchRealtimeMediaAdapter`
/// with mock recorder/player/transport and asserts the coordinator's events
/// are routed to the right seam (transport for uplink, player for playback,
/// single-shot fallback on transport failure).
@MainActor
final class WatchRealtimeMediaAdapterTests: XCTestCase {

    func testVADFinalAutomaticallyCommitsExactlyOnce() {
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let adapter = WatchRealtimeMediaAdapter(
            recorder: recorder,
            player: player,
            transport: transport,
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: true
        )
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        adapter.beginTurn(requestId: "57557557-5575-4575-8575-575575575575")
        recorder.feed(Self.pcmFrame(rms: 0.08))
        recorder.feed(Self.pcmFrame(rms: 0.08))
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0)) }
        recorder.feed(Self.pcmFrame(rms: 0))

        XCTAssertTrue(recorder.didStop)
        XCTAssertEqual(transport.commitEvents.count, 1)
        XCTAssertEqual(vadEvents.count, 2)
        guard case .speechFinal(_, .silence) = vadEvents.last else {
            return XCTFail("expected silence speech.final")
        }
    }

    private static func pcmFrame(rms: Double) -> Data {
        var sample = Int16((rms * Double(Int16.max)).rounded()).littleEndian
        let bytes = withUnsafeBytes(of: &sample) { Data($0) }
        var data = Data(capacity: 3_200)
        for _ in 0..<1_600 { data.append(bytes) }
        return data
    }

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

    func testRenderRecoveryAlwaysRestartsOnFirstDeltaAfterSessionActivation() {
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartEngine(
            firstDeltaAfterSessionActivation: true,
            engineIsRunning: true
        ), "AVAudioEngine may report running after the shared session lost its output route")
    }

    func testRenderRecoveryRestartsStoppedEngineOnLaterDelta() {
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartEngine(
            firstDeltaAfterSessionActivation: false,
            engineIsRunning: false
        ))
    }

    func testRenderRecoveryDoesNotRestartHealthyEngineOrNode() {
        XCTAssertFalse(RealtimeRenderRecoveryPolicy.shouldRestartEngine(
            firstDeltaAfterSessionActivation: false,
            engineIsRunning: true
        ))
        XCTAssertFalse(RealtimeRenderRecoveryPolicy.shouldRestartNode(
            engineWasRestarted: false,
            nodeIsPlaying: true
        ))
    }

    func testRenderRecoveryRestartsNodeWheneverEngineWasRestarted() {
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartNode(
            engineWasRestarted: true,
            nodeIsPlaying: true
        ))
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartNode(
            engineWasRestarted: false,
            nodeIsPlaying: false
        ))
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
        /// ESS-650：与真实引擎同语义——入队即出声，`bargeIn`/`stop` 即静音。
        private(set) var isRenderingDownlink = false

        var enqueuedChunks: [VoiceStreamChunk] { enqueuedPlayables.map(\.chunk) }

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws { preparedFor = turn }
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
            enqueuedPlayables.append(contentsOf: playables)
            if !playables.isEmpty { isRenderingDownlink = true }
        }
        func bargeIn(clearedBytes: Int) {
            bargedInBytes.append(clearedBytes)
            isRenderingDownlink = false
        }
        func finish(responseId: String?) { finishInvocations.append(responseId) }
        func stop(barge: Bool) {
            stopped = true
            isRenderingDownlink = false
        }
    }

    private final class MockTransport: WatchRealtimeMediaAdapter.Transport {
        private(set) var startEvents: [RealtimeStreamStart] = []
        private(set) var appendEvents: [VoiceStreamChunk] = []
        private(set) var commitEvents: [RealtimeStreamCommit] = []
        private(set) var playbackStartEvents: [(RealtimeMediaSession.TurnHandle, String)] = []
        private(set) var playbackEndEvents: [(RealtimeMediaSession.TurnHandle, String, Int)] = []
        private(set) var fallbackEvents: [(RealtimeMediaSession.TurnHandle,
                                          RealtimeUplinkStream.FallbackReason)] = []
        private(set) var bargeInRequests: [RealtimeBargeInRequest] = []
        private(set) var identities: [(String?, String?)] = []

        func sendStreamStart(_ start: RealtimeStreamStart, conversationId: String?, turnId: String?) {
            startEvents.append(start); identities.append((conversationId, turnId))
        }
        func sendAudioAppend(_ chunk: VoiceStreamChunk, conversationId: String?, turnId: String?) {
            appendEvents.append(chunk); identities.append((conversationId, turnId))
        }
        func sendAudioCommit(_ commit: RealtimeStreamCommit, conversationId: String?, turnId: String?) {
            commitEvents.append(commit); identities.append((conversationId, turnId))
        }
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

    /// ESS-527 test double for the internal barrier timer. Captures the most
    /// recent `arm(...)` callback so the test can fire it synchronously
    /// without depending on wall-clock `Task.sleep`. `@MainActor` because
    /// `BarrierTimer` requirements are actor-isolated and the callback the
    /// tests want to fire is `@MainActor () -> Void`.
    @MainActor
    final class ManualBarrierTimer: WatchRealtimeMediaAdapter.BarrierTimer {
        private(set) var armCount = 0
        private(set) var cancelCount = 0
        private(set) var lastRequestedInterval: TimeInterval?
        private var pending: (@MainActor () -> Void)?

        var isArmed: Bool { pending != nil }

        nonisolated init() {}

        func arm(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) {
            armCount += 1
            lastRequestedInterval = seconds
            pending = fire
        }

        func cancel() {
            cancelCount += 1
            pending = nil
        }

        /// Simulate the sleep expiring. Returns whether a callback fired.
        @discardableResult
        func fire() -> Bool {
            guard let callback = pending else { return false }
            pending = nil
            callback()
            return true
        }
    }

    private func makeAdapter(
        sessionIds: [String],
        barrierTimer: WatchRealtimeMediaAdapter.BarrierTimer = TaskBasedBarrierTimer()
    ) -> (
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
            fullFileFallback: { handle, reason in counter.record(handle, reason) },
            barrierTimer: barrierTimer
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

    func testUplinkAckReleasesBudgetAndLogsRuntimeReceipt() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, recorder, _, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        let handle = adapter.beginTurn(requestId: requestId)
        recorder.feed(Data(repeating: 0x11, count: 64))
        let chunk = try! XCTUnwrap(transport.appendEvents.first)

        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))
        // Duplicate receipt is ignored by the byte ledger and produces no
        // second accepted-ACK log event.
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))

        recorder.feed(Data(repeating: 0x22, count: 64))
        adapter.commit()
        XCTAssertEqual(transport.appendEvents.map(\.sequence), [0, 1])
        XCTAssertEqual(transport.commitEvents.first?.sequence, 1)
    }

    /// ESS-573：首个被对端接受的 uplink ack = 通道就绪的唯一真实信号，
    /// 每回合只发一次（复审硬约束：不得同步宣告 ready）。
    func testFirstAcceptedAckSignalsChannelReadyOncePerTurn() {
        let requestId = "44444444-4444-4444-4444-444444440573"
        let (adapter, recorder, _, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555550573"
        ])
        var readyEvents: [String] = []
        adapter.onChannelReady = { readyEvents.append($0) }

        let handle = adapter.beginTurn(requestId: requestId)
        // 发起录音本身不得触发 ready（无同步宣告）。
        XCTAssertTrue(readyEvents.isEmpty)

        recorder.feed(Data(repeating: 0x11, count: 64))
        let chunk = try! XCTUnwrap(transport.appendEvents.first)

        // 错误身份的 ack 不得触发 ready。
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: "99999999-9999-9999-9999-999999999999",
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))
        XCTAssertTrue(readyEvents.isEmpty)

        // 首个被接受的 ack 触发一次。
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))
        XCTAssertEqual(readyEvents, [requestId])

        // 同回合后续 ack 不再触发。
        recorder.feed(Data(repeating: 0x22, count: 64))
        let second = try! XCTUnwrap(transport.appendEvents.last)
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: second.sequence,
            byteCount: second.payload.count
        ))
        XCTAssertEqual(readyEvents, [requestId])
    }

    func testTransportReadySignalsBeforeUserSpeaksAndRejectsStaleTurn() {
        let requestId = "44444444-4444-4444-4444-444444440695"
        let sessionId = "55555555-5555-5555-5555-555555550695"
        let (adapter, _, _, _, _) = makeAdapter(sessionIds: [sessionId])
        var readyEvents: [String] = []
        adapter.onChannelReady = { readyEvents.append($0) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.receiveChannelReady(RealtimeChannelReady(
            requestId: "99999999-9999-9999-9999-999999999999",
            sessionId: handle.sessionId
        ))
        XCTAssertTrue(readyEvents.isEmpty)

        adapter.receiveChannelReady(RealtimeChannelReady(
            requestId: handle.requestId,
            sessionId: handle.sessionId
        ))
        adapter.receiveChannelReady(RealtimeChannelReady(
            requestId: handle.requestId,
            sessionId: handle.sessionId
        ))
        XCTAssertEqual(readyEvents, [requestId])
    }

    /// ESS-573：新回合重置 ready 信号——下一回合的首个 ack 必须再次触发
    /// （多轮会话里每轮的就绪都要能独立确认）。
    func testChannelReadyRearoundsForNextTurn() {
        let (adapter, recorder, _, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555550001",
            "55555555-5555-5555-5555-555555550002"
        ])
        var readyEvents: [String] = []
        adapter.onChannelReady = { readyEvents.append($0) }

        let first = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444440001")
        recorder.feed(Data(repeating: 0x11, count: 64))
        let firstChunk = try! XCTUnwrap(transport.appendEvents.last)
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: first.requestId, sessionId: first.sessionId,
            sequence: firstChunk.sequence, byteCount: firstChunk.payload.count
        ))

        let second = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444440002")
        recorder.feed(Data(repeating: 0x33, count: 64))
        let secondChunk = try! XCTUnwrap(transport.appendEvents.last)
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: second.requestId, sessionId: second.sessionId,
            sequence: secondChunk.sequence, byteCount: secondChunk.payload.count
        ))

        XCTAssertEqual(readyEvents, [first.requestId, second.requestId])
    }

    /// ESS-573：快速上行死亡（采集 tap 失败 → 传输失败兜底）如实上报，
    /// 会话层据此刻意告知并退出——「不假装还在对话」。
    func testUplinkTransportFailureSignalsFallbackEvent() {
        let requestId = "44444444-4444-4444-4444-444444440574"
        let (adapter, recorder, _, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555550574"
        ])
        var fallbackEvents: [String] = []
        adapter.onUplinkFallback = { fallbackEvents.append($0) }

        enum FakeRecorderError: Error { case tapDied }
        adapter.beginTurn(requestId: requestId)
        recorder.fail(FakeRecorderError.tapDied)

        XCTAssertEqual(fallbackEvents, [requestId])
    }

    func testRealPlaybackCompletionEmitsDeliveryReceiptAndWatchLog() {
        let requestId = "44444444-4444-4444-4444-444444445216"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555216"
        ])
        final class LogSink { var events: [(String, String?)] = [] }
        let sink = LogSink()
        WatchLog.setObserver { _, event, _, detail, _ in sink.events.append((event, detail)) }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-final", bytesPlayed: 4_800
        ))

        XCTAssertEqual(transport.playbackEndEvents.count, 1)
        XCTAssertEqual(transport.playbackEndEvents.first?.1, "resp-final")
        XCTAssertEqual(transport.playbackEndEvents.first?.2, 4_800)
        let delivered = sink.events.first { $0.0 == "result_delivered_after_render" }
        XCTAssertNotNil(delivered)
        XCTAssertTrue(delivered?.1?.contains("response_id=resp-final bytes_played=4800") == true)
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

    func testRealtimePlaybackStartedHasDedicatedLifecycleCallback() {
        let requestId = "44444444-4444-4444-4444-4444444444b0"
        let sessionId = "55555555-5555-5555-5555-55555555b000"
        let (adapter, recorder, player, _, _) = makeAdapter(sessionIds: [sessionId])
        var playbackStartedCount = 0
        adapter.onRealtimePlaybackStarted = { playbackStartedCount += 1 }
        let handle = adapter.beginTurn(requestId: requestId)

        // A fallback resolves the pending hold but must not claim that real
        // playback started; the breather still protects the fallback wait.
        recorder.fail(NSError(domain: "test", code: 1))
        XCTAssertEqual(playbackStartedCount, 0)

        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-start"
        ))
        XCTAssertEqual(playbackStartedCount, 1)
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
        WatchLog.setObserver { module, event, _, detail, _ in
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

    // MARK: - ESS-527 outer timer regressions

    /// ESS-527 acceptance 1: barrier armed + missing tail + timeout → exactly
    /// one `.doneBarrierTimedOut` fallback surfaces, with the structured
    /// `done_barrier_timeout` log carrying the missing seq list. Before this
    /// fix the internal timer was never armed so this trace produced 13
    /// minutes of silence and zero fallback events (bridge.log evidence in
    /// ESS-527 body).
    func testEss527_BarrierTimeoutTriggersExactlyOneFallback() {
        let requestId = "44444444-4444-4444-4444-444444444527"
        let sessionId = "55555555-5555-5555-5555-555555555527"
        let timer = ManualBarrierTimer()
        let (adapter, _, _, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )

        struct LogEvent { let module: String; let event: String; let detail: String? }
        final class LogSink { var events: [LogEvent] = [] }
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.events.append(LogEvent(module: module, event: event, detail: detail))
        }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        // Only seq 0..1 arrive. final_sequence=3 leaves 2..3 pending forever.
        for i in 0..<2 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527A", generation: 1
            )
        }
        adapter.markDownlinkComplete(
            responseId: "r-527A", generation: 1, finalSequence: 3
        )

        // The waiting branch must arm the timer at exactly the 2.0 s budget.
        XCTAssertTrue(timer.isArmed, "barrier waiting must arm the outer timer — this is the ESS-527 dead-code fix")
        XCTAssertEqual(timer.armCount, 1)
        XCTAssertEqual(
            timer.lastRequestedInterval,
            WatchRealtimeMediaAdapter.doneBarrierTimeoutSeconds
        )

        // Fire the timer. Adapter routes it through `session.doneBarrierTimeout()`
        // → `.playbackFallback(.doneBarrierTimedOut([2,3]))` → single
        // structured error log; a second fire is a no-op (buffer absorbs).
        XCTAssertTrue(timer.fire())
        XCTAssertFalse(timer.fire(), "second fire must be absorbed; the buffer's alreadyFellBack path swallows it")

        let timeoutLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_timeout"
        }
        XCTAssertEqual(
            timeoutLogs.count, 1,
            "done_barrier_timeout must surface exactly once — ESS-527 acceptance"
        )
        let detail = timeoutLogs.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("missing_seq=[2, 3]"),
            "done_barrier_timeout must carry the missing seq list; got detail=\(detail)"
        )
    }

    /// ESS-527 acceptance 2: barrier armed + late deltas fill the missing
    /// set → coordinator emits `.doneBarrierReleased` and the adapter
    /// cancels the timer BEFORE it can fire. `player.finish` is called
    /// exactly once (the async release path) and no fallback is surfaced.
    func testEss527_LateDeltasReleaseBarrierAndCancelTimer() {
        let requestId = "44444444-4444-4444-4444-444444444528"
        let sessionId = "55555555-5555-5555-5555-555555555528"
        let timer = ManualBarrierTimer()
        let (adapter, _, player, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )

        struct LogEvent { let module: String; let event: String; let detail: String? }
        final class LogSink { var events: [LogEvent] = [] }
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.events.append(LogEvent(module: module, event: event, detail: detail))
        }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        // Head deltas 0..1 arrive first.
        for i in 0..<2 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527B", generation: 1
            )
        }
        // Done arrives BEFORE tail deltas — barrier waits, timer arms.
        adapter.markDownlinkComplete(
            responseId: "r-527B", generation: 1, finalSequence: 3
        )
        XCTAssertTrue(timer.isArmed, "waiting branch must arm the timer")
        XCTAssertEqual(player.finishCount, 0, "player must NOT drain while the barrier is waiting")
        let cancelsBefore = timer.cancelCount

        // Tail deltas 2..3 land — this should trigger the coordinator's
        // async `checkBarrierRelease()` → `.doneBarrierReleased` and the
        // adapter must cancel the pending timer.
        for i in 2...3 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527B", generation: 1
            )
        }
        XCTAssertFalse(timer.isArmed, "async release must cancel the pending barrier timer")
        XCTAssertGreaterThan(timer.cancelCount, cancelsBefore)

        // Exactly one drain, and it is the async-release path (no waited_ms=0
        // marker; that string belongs to the sync path exclusively).
        XCTAssertEqual(
            player.finishCount, 1,
            "player.finish must be invoked exactly once even after a late release"
        )
        XCTAssertEqual(player.finishInvocations.first as? String, "r-527B")

        let releaseLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_released"
        }
        XCTAssertEqual(releaseLogs.count, 1, "done_barrier_released must be emitted exactly once")
        XCTAssertFalse(
            releaseLogs.first?.detail?.contains("waited_ms=0") ?? true,
            "the async release path must not carry the sync-only waited_ms=0 marker"
        )

        // Timer firing after cancellation is a no-op — this guards against
        // a stray real-time task racing the cancel and stacking a fallback.
        XCTAssertFalse(timer.fire())
        let fallbackLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_timeout"
        }
        XCTAssertTrue(fallbackLogs.isEmpty, "no barrier-timeout fallback must fire on the async-release path")
    }

    /// ESS-527: synchronous barrier release (all seqs present before done)
    /// must not arm the timer at all. Guards against a regression where
    /// the sync path accidentally lands in the waiting branch first.
    func testEss527_SyncBarrierReleaseDoesNotArmTimer() {
        let requestId = "44444444-4444-4444-4444-444444444529"
        let sessionId = "55555555-5555-5555-5555-555555555529"
        let timer = ManualBarrierTimer()
        let (adapter, _, _, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        for i in 0...2 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527C", generation: 1
            )
        }
        adapter.markDownlinkComplete(
            responseId: "r-527C", generation: 1, finalSequence: 2
        )
        XCTAssertEqual(timer.armCount, 0, "sync release must not arm the barrier timer")
        XCTAssertFalse(timer.isArmed)
    }

    /// ESS-527: `-1` zero-audio done contract must not arm the timer — there
    /// are no missing seqs to wait for and nothing to drain.
    func testEss527_ZeroAudioContractDoesNotArmTimer() {
        let requestId = "44444444-4444-4444-4444-444444444530"
        let sessionId = "55555555-5555-5555-5555-555555555530"
        let timer = ManualBarrierTimer()
        let (adapter, _, _, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )
        _ = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        adapter.markDownlinkComplete(
            responseId: "r-527D", generation: 1, finalSequence: -1
        )
        XCTAssertEqual(timer.armCount, 0)
    }
}
