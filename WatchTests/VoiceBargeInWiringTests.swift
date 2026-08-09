import XCTest

@testable import WristAgent_Watch_App

/// ESS-650 F2-2 / F2-3 / F2-4 的接线证据（R-02.1）。
///
/// 小梁复核口径逐条对应本文件的用例：
/// - **VAD-only 必须零上行** → `testSpeakingCaptureProducesZeroUplink`
/// - **零额外空轮** → `testBargeInListeningProducesNoExtraTurn`
/// - **gate 动态切换即时停止采集** → `testGateFlippedOffStopsCaptureImmediately`
///
/// 用的是**生产接线本体**（`SessionTurnWiring.connect` + `attachSessionEvents`），
/// 不是接线副本——副本只能证明副本对，证明不了生产路径接上了。
@MainActor
final class VoiceBargeInWiringTests: XCTestCase {

    // MARK: - 测试台

    private final class MockRecorder: WatchRealtimeMediaAdapter.Recorder {
        var onFrame: ((Data) -> Void)?
        var onFailure: ((Error) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start() throws { startCount += 1 }
        func stop() { stopCount += 1 }
        func feed(_ data: Data) { onFrame?(data) }
    }

    private final class MockPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {}
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {}
        func bargeIn(clearedBytes: Int) {}
        func finish(responseId: String?) {}
        func stop(barge: Bool) {}
    }

    private final class MockTransport: WatchRealtimeMediaAdapter.Transport {
        private(set) var appendEvents: [VoiceStreamChunk] = []
        private(set) var commitEvents: [RealtimeStreamCommit] = []

        func sendStreamStart(_ start: RealtimeStreamStart, conversationId: String?, turnId: String?) {}
        func sendAudioAppend(_ chunk: VoiceStreamChunk, conversationId: String?, turnId: String?) {
            appendEvents.append(chunk)
        }
        func sendAudioCommit(_ commit: RealtimeStreamCommit, conversationId: String?, turnId: String?) {
            commitEvents.append(commit)
        }
        func sendPlaybackStarted(handle: RealtimeMediaSession.TurnHandle, responseId: String) {}
        func sendPlaybackEnded(handle: RealtimeMediaSession.TurnHandle, responseId: String, bytesPlayed: Int) {}
        func fallbackToCompleteFile(handle: RealtimeMediaSession.TurnHandle,
                                    reason: RealtimeUplinkStream.FallbackReason) {}
        func sendBargeInRequest(_ request: RealtimeBargeInRequest) {}
    }

    private final class LogCapture: @unchecked Sendable {
        struct Entry { let module: String; let event: String; let detail: String? }
        private let lock = NSLock()
        private var entries: [Entry] = []

        func install() {
            WatchLog.setObserver { [weak self] module, event, _, detail, _ in
                self?.lock.lock()
                self?.entries.append(Entry(module: module, event: event, detail: detail))
                self?.lock.unlock()
            }
        }
        func uninstall() { WatchLog.setObserver(nil) }
        func detail(_ event: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return entries.last { $0.event == event }?.detail
        }
        func count(_ event: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { $0.event == event }.count
        }
    }

    @MainActor
    private final class Harness {
        let session: SessionController
        let pushToTalk = PushToTalkController()
        let recorder = MockRecorder()
        let transport = MockTransport()
        let adapter: WatchRealtimeMediaAdapter
        let log = LogCapture()
        var gateEnabled = true
        private(set) var startedTurns: [RealtimeMediaSession.TurnHandle] = []

        init() {
            session = SessionController(
                defaults: UserDefaults(suiteName: "VoiceBargeInWiringTests.\(UUID().uuidString)")!
            )
            adapter = WatchRealtimeMediaAdapter(
                recorder: recorder, player: MockPlayer(), transport: transport,
                vadConfiguration: LocalVADConfiguration(),
                automaticallyCommitOnSpeechFinal: true
            )
            log.install()
            // 生产接线本体。
            SessionTurnWiring.connect(session: session, pushToTalk: pushToTalk, interruptSelfCheck: {})
            pushToTalk.useRealtimeAdapterForTests(adapter)
            pushToTalk.attachSessionEvents(to: adapter)
            session.voiceBargeInEnabled = { [weak self] in self?.gateEnabled ?? false }
            session.scheduleDelay = { _, _ in NoopToken() }
            session.playHaptic = { _ in }
            adapter.beginConversation()
            session.onBeginChannel = { [weak self] in self?.beginTurn() }
            session.onStartTurn = { [weak self] in self?.beginTurn() }
        }

        func tearDown() { log.uninstall() }

        private func beginTurn() -> String? {
            let handle = adapter.beginTurn(requestId: UUIDv7.generate().uuidString.lowercased())
            startedTurns.append(handle)
            return handle.requestId
        }

        /// 进会话 → 就绪 → 提交 → 起播，停在 speaking。
        func driveToSpeaking() {
            session.enterSession()
            guard let handle = startedTurns.last else { return XCTFail("首轮未起") }
            recorder.feed(Self.pcmFrame(rms: 0))
            guard let chunk = transport.appendEvents.last else { return XCTFail("无上行可 ack") }
            adapter.receiveUplinkAck(RealtimeUplinkAck(
                requestId: handle.requestId, sessionId: handle.sessionId,
                sequence: chunk.sequence, byteCount: chunk.payload.count
            ))
            pushToTalk.onSessionTurnCommitted?(handle.requestId)
            pushToTalk.onSessionAnswerStarted?(handle.requestId)
        }

        /// 100ms / 帧（16kHz PCM16）。
        static func pcmFrame(rms: Double) -> Data {
            var sample = Int16((rms * Double(Int16.max)).rounded()).littleEndian
            let bytes = withUnsafeBytes(of: &sample) { Data($0) }
            var data = Data(capacity: 3_200)
            for _ in 0..<1_600 { data.append(bytes) }
            return data
        }
    }

    private final class NoopToken: SessionDelayToken {
        func cancel() {}
    }

    private func makeHarness() -> Harness {
        let h = Harness()
        addTeardownBlock { @MainActor in h.tearDown() }
        return h
    }

    // MARK: - F2-2：零上行

    /// **小梁复核口径 1**：speaking 期间的采集只进 VAD 检测器，一帧都不许上行。
    /// 这是隐私与正确性的双重底线——回答播放期间用户说的话若被当成上行，
    /// 分身会把自己的回答当成新问题。
    func testSpeakingCaptureProducesZeroUplink() {
        let h = makeHarness()
        h.driveToSpeaking()
        XCTAssertEqual(h.session.turnPhase, .speaking)
        XCTAssertTrue(h.pushToTalk.isVoiceBargeInListening, "gate ON 时 speaking 必须开监听")
        let uplinkBefore = h.transport.appendEvents.count

        // 能量取 0.03：**高于**常规会话 VAD 的 0.018（常规路径下这些帧会被
        // 当成说话并上行），**低于**打断判据的 0.036（不触发打断，从而能
        // 干净地验证「整段 speaking 期间零上行」而不是「打断前零上行」）。
        for _ in 0..<20 { h.recorder.feed(Harness.pcmFrame(rms: 0.03)) }

        XCTAssertEqual(h.session.turnPhase, .speaking, "本用例前提：全程未被打断")
        XCTAssertTrue(h.pushToTalk.isVoiceBargeInListening)
        XCTAssertEqual(
            h.transport.appendEvents.count, uplinkBefore,
            "speaking 期间的采集必须零上行（F2-2）"
        )
        XCTAssertEqual(h.transport.commitEvents.count, 0, "更不得产生 commit")
    }

    /// 零上行不是靠「调用方记得别传」，而是结构性的：监听开着时
    /// `onFrame` 在 push 之前就早退。这里直接钉住那条分支。
    func testFramesAreRoutedToDetectorNotUplinkWhileListening() {
        let h = makeHarness()
        h.driveToSpeaking()

        for _ in 0..<20 { h.recorder.feed(Harness.pcmFrame(rms: 0.2)) }

        XCTAssertGreaterThan(
            h.log.count("barge_in_detected") + h.log.count("barge_in_energy_spike"), 0,
            "帧必须真的进了打断检测器"
        )
    }

    // MARK: - F2-2：零额外空轮

    /// **小梁复核口径 2**：打断监听不得凭空多出一轮。开监听、喂静音、
    /// 停监听全程，`beginTurn` 次数必须不变。
    func testBargeInListeningProducesNoExtraTurn() {
        let h = makeHarness()
        h.driveToSpeaking()
        let turnsAfterSpeaking = h.startedTurns.count

        for _ in 0..<10 { h.recorder.feed(Harness.pcmFrame(rms: 0)) }
        XCTAssertEqual(h.startedTurns.count, turnsAfterSpeaking, "监听期间不得开新轮")

        // 回答正常播完 → 才允许开下一轮，且只多一轮。
        h.pushToTalk.onSessionAnswerFinished?(h.startedTurns.last!.requestId, true, "endgame_success")
        XCTAssertEqual(h.startedTurns.count, turnsAfterSpeaking + 1, "播完只开一轮，不多不少")
        XCTAssertFalse(h.pushToTalk.isVoiceBargeInListening, "离开 speaking 必须停采")
        XCTAssertEqual(h.log.detail("barge_in_listening_stopped")?.contains("reason=answer_finished"), true)
    }

    // MARK: - F2-4：gate 动态切换

    /// **小梁复核口径 3**：speaking 进行中把 gate 翻到 OFF，必须**即时**停采，
    /// 不能等本轮回答播完——开关关了麦克风还开着是隐私违背。
    func testGateFlippedOffStopsCaptureImmediately() {
        let h = makeHarness()
        h.driveToSpeaking()
        XCTAssertTrue(h.pushToTalk.isVoiceBargeInListening)

        let stopsBefore = h.recorder.stopCount

        h.gateEnabled = false
        h.session.noteVoiceBargeInGateChanged(enabled: false)

        XCTAssertFalse(h.pushToTalk.isVoiceBargeInListening, "gate OFF 必须即时停采")
        XCTAssertEqual(
            h.recorder.stopCount, stopsBefore + 1,
            "「即时停采」必须落到 recorder.stop() 上——只翻标志位不停麦克风，"
                + "开关关了麦克风还开着，属隐私违背"
        )
        XCTAssertEqual(h.log.detail("barge_in_listening_stopped")?.contains("reason=gate_off"), true)
        XCTAssertEqual(h.session.turnPhase, .speaking, "gate 关掉不该顺手打断本轮回答")
    }

    /// gate 默认 OFF：speaking 期间根本不开麦（F2-4 + 隐私承诺）。
    func testGateOffNeverStartsCapture() {
        let h = makeHarness()
        h.gateEnabled = false

        h.driveToSpeaking()

        XCTAssertEqual(h.session.turnPhase, .speaking)
        XCTAssertFalse(h.pushToTalk.isVoiceBargeInListening, "gate OFF 时 speaking 不得采集")
        XCTAssertEqual(h.log.count("barge_in_listening_started"), 0)
    }

    // MARK: - F2-3：命中 → source=voice + detect_ms/stop_ms

    /// 连续 ≥300ms 高能量语音（且已过 400ms 守卫窗）→ 打断命中，
    /// 落 `session_speaking_interrupted source=voice`，且带 `detect_ms`/`stop_ms`。
    func testVoiceBargeInEmitsSourceVoiceWithDetectAndStopMs() {
        let h = makeHarness()
        h.driveToSpeaking()

        // 守卫窗 400ms：先喂 5 帧静音（500ms）越过守卫。
        for _ in 0..<5 { h.recorder.feed(Harness.pcmFrame(rms: 0)) }
        // 再喂 4 帧高能量（400ms ≥ 300ms 判据）。
        for _ in 0..<4 { h.recorder.feed(Harness.pcmFrame(rms: 0.2)) }

        let detail = h.log.detail("session_speaking_interrupted")
        XCTAssertNotNil(detail, "语音打断必须落 session_speaking_interrupted")
        XCTAssertTrue(detail?.contains("source=voice") == true, "实际=\(detail ?? "nil")")
        XCTAssertTrue(detail?.contains("detect_ms=") == true, "实际=\(detail ?? "nil")")
        XCTAssertTrue(detail?.contains("stop_ms=") == true, "实际=\(detail ?? "nil")")
        XCTAssertEqual(h.session.turnPhase, .listening, "打断后应立刻回到聆听")
        XCTAssertFalse(h.pushToTalk.isVoiceBargeInListening, "打断即离开 speaking，停采")
    }

    /// F2-6：点球打断仍然走同一入口，`source` 必须是 `orb_tap` 而不是 voice。
    func testOrbTapInterruptKeepsOrbTapSource() {
        let h = makeHarness()
        h.driveToSpeaking()

        h.session.interruptSpeaking()

        let detail = h.log.detail("session_speaking_interrupted")
        XCTAssertTrue(detail?.contains("source=orb_tap") == true, "实际=\(detail ?? "nil")")
    }

    /// 守卫窗内的高能量帧（起播瞬间的自身回声）不得触发打断，
    /// 且必须被计入自身回声计数供 F2-5 对账。
    func testEchoInsideGuardWindowDoesNotTriggerAndIsCounted() {
        let h = makeHarness()
        h.driveToSpeaking()

        // 守卫窗 400ms 内连续高能量 = 典型自身回声形态。
        for _ in 0..<3 { h.recorder.feed(Harness.pcmFrame(rms: 0.5)) }

        XCTAssertNil(h.log.detail("session_speaking_interrupted"), "守卫窗内不得触发打断")
        XCTAssertEqual(h.session.turnPhase, .speaking)
        XCTAssertGreaterThan(
            h.pushToTalk.voiceBargeInSelfEchoFrames, 0,
            "守卫窗内的高能量帧必须被计入自身回声，供 F2-5 对账"
        )
    }

    /// gate 在命中瞬间已被关掉时丢弃这次打断——用户刚关掉开关不该再被打断一次。
    func testDetectionAfterGateOffIsIgnored() {
        let h = makeHarness()
        h.driveToSpeaking()
        h.gateEnabled = false

        h.session.handleVoiceBargeIn(detectMs: 320)

        XCTAssertEqual(h.session.turnPhase, .speaking, "gate 已关，不得打断")
        XCTAssertEqual(h.log.detail("voice_barge_in_ignored")?.contains("reason=gate_off"), true)
    }

    // MARK: - 接线断言

    /// 接线没接上时上面所有行为断言都会「碰巧通过」（因为什么都不发生），
    /// 所以单独钉住出入口非 nil——这是 ESS-600 第一次复审被打回的教训。
    func testProductionWiringConnectsBargeInSeams() {
        let session = SessionController(
            defaults: UserDefaults(suiteName: "VoiceBargeInWiringTests.wiring.\(UUID().uuidString)")!
        )
        let pushToTalk = PushToTalkController()

        SessionTurnWiring.connect(session: session, pushToTalk: pushToTalk, interruptSelfCheck: {})

        XCTAssertNotNil(session.onBeginBargeInListening, "起监听未接 → speaking 永远不开麦")
        XCTAssertNotNil(session.onEndBargeInListening, "停监听未接 → 麦克风留在会话之外")
        XCTAssertNotNil(pushToTalk.onSessionVoiceBargeIn, "命中未接 → 语音打断永远不生效")
    }
}
