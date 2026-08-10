import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-650 整改补充套件：盯 ESS-667 架构复审里**尚未被覆盖**的那几条。
///
/// 与 `VoiceBargeInWiringTests`（PR #281 已有）的分工：那套证明「接线接上了、
/// 零上行、零空轮」；本套证明「gate 有入口且两个方向都闭环」「事件真的过得了
/// ESS-655 契约校验」「F2-5 的零有正面证据」「stop_ms 量的是停播而不是调用开销」。
///
/// 覆盖边界（如实声明）：`.voiceChat` 的真实 AEC 效果、真机路由、实测回声 dB
/// 降低量都验不了——那属于 R-02.5 关卡二，随装机取证。
@MainActor
final class VoiceBargeInEvidenceTests: XCTestCase {

    // MARK: - F2-1：AEC mode 与 ESS-61/72 降级阶梯

    func testGateOffKeepsSpokenAudioMode() throws {
        let session = FakeAudioSession()
        let controller = makeAudioController(session: session, gate: false)
        try controller.beginConversation(conversationId: "c-off")
        XCTAssertEqual(session.modes, [.spokenAudio])
    }

    func testGateOnUsesVoiceChatModeForAEC() throws {
        let session = FakeAudioSession()
        let controller = makeAudioController(session: session, gate: true)
        try controller.beginConversation(conversationId: "c-on")
        XCTAssertEqual(session.modes, [.voiceChat], "AEC 的唯一取得途径")
    }

    /// **降级阶梯不得被简化**（ESS-61/72 真机验证过的两级回落）：
    /// `.voiceChat` 被系统拒绝时仍然回落到 `.minimal` 的 `.default`，
    /// 与 gate OFF 时的失败路径完全一致。
    func testVoiceChatRejectionStillFallsBackToMinimalLadder() throws {
        let session = FakeAudioSession()
        session.rejectModes = [.voiceChat]
        let controller = makeAudioController(session: session, gate: true)
        try controller.beginConversation(conversationId: "c-fallback")
        XCTAssertEqual(session.modes, [.voiceChat, .default], "两级阶梯必须都走到")
        XCTAssertTrue(controller.isAcquired, "回落成功后会话仍然拿得到")
    }

    /// gate 是**实时读点**：翻转后下一次 beginConversation 就用新 mode，
    /// 不需要重建控制器。
    func testGateFlipAppliesToNextConversationWithoutRebuild() throws {
        let session = FakeAudioSession()
        var gate = false
        let controller = ConversationAudioController(
            session: session, captureControl: FakeEngine(), playbackControl: FakeEngine()
        )
        controller.voiceBargeInEnabled = { gate }

        try controller.beginConversation(conversationId: "c1")
        controller.endConversation(reason: .userExit)
        gate = true
        try controller.beginConversation(conversationId: "c2")

        XCTAssertEqual(session.modes, [.spokenAudio, .voiceChat])
    }

    // MARK: - F2-4：gate 的默认值、持久化与契约事件

    func testGateDefaultsOnForFreshInstall() {
        XCTAssertTrue(
            WatchDebugSettings(defaults: isolatedDefaults("default")).voiceBargeInEnabled,
            "ESS-711：新安装必须默认支持语音打断"
        )
    }

    func testGatePersistsAcrossRelaunch() {
        let defaults = isolatedDefaults("persist")
        WatchDebugSettings(defaults: defaults).setVoiceBargeInEnabled(false)
        XCTAssertFalse(WatchDebugSettings(defaults: defaults).voiceBargeInEnabled)
    }

    /// `voice_barge_in_gate` 必须过得了 ESS-655 契约校验。
    ///
    /// 整改前这条是手拼的 `state=… previous=… source=user`：`source` 不是契约
    /// 字段、必需的 `reason` 缺失，`PhoneModeCallMetrics` 会把整条丢进
    /// `rejected`——发了等于没发，gate 指标永远算不出来。
    func testGateEventSatisfiesTelemetryContract() throws {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        let settings = WatchDebugSettings(defaults: isolatedDefaults("contract"))

        settings.setVoiceBargeInEnabled(false)
        settings.setVoiceBargeInEnabled(true)

        let details = log.details(of: "voice_barge_in_gate")
        XCTAssertEqual(details, ["state=off reason=user_toggle", "state=on reason=user_toggle"])
        for detail in details {
            XCTAssertNoThrow(
                try PhoneModeTelemetry.validate(
                    event: "voice_barge_in_gate", detail: detail, rejectsUnknownFields: true
                ),
                "契约外字段 / 缺必需字段会让这条记录在指标侧被整条丢弃：\(detail)"
            )
        }
    }

    /// 冷启动补报 gate 快照——没有它，一份真机日志里「没触发语音打断」
    /// 分不清是 gate 关着还是开着但没检测到。
    func testLaunchSnapshotReportsGateState() {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        WatchDebugSettings(defaults: isolatedDefaults("launch")).logStateAtLaunch()
        XCTAssertEqual(log.details(of: "voice_barge_in_gate"), ["state=on reason=launch_snapshot"])
    }

    /// **ON 也要通知订阅者。** 只在 OFF 时回调等于「运行中打开」永远不闭环：
    /// 本轮回答已经在放，监听要拖到下一轮才起得来。
    func testGateChangeNotifiesSubscribersInBothDirections() {
        let settings = WatchDebugSettings(defaults: isolatedDefaults("fanout"))
        var observed: [Bool] = []
        settings.onVoiceBargeInChanged { observed.append($0) }

        settings.setVoiceBargeInEnabled(false)
        settings.setVoiceBargeInEnabled(false)    // 幂等：同值不重复通知
        settings.setVoiceBargeInEnabled(true)

        XCTAssertEqual(observed, [false, true])
    }

    /// gate 必须有**真实调用点**。整改前 `setVoiceBargeInEnabled` 一个调用点
    /// 都没有（ESS-667 复审阻断 2），等于这个功能只能靠改代码打开。
    /// 这里从服务图这一侧钉住分发链路确实建立了。
    func testAppServicesSubscribesToGateChanges() {
        let services = WatchAppServices.shared
        services.bootstrap(reason: "test")
        XCTAssertNotNil(
            services.voiceBargeInGateToken,
            "bootstrap 必须订阅 gate 变化，否则运行时翻开关会话层收不到"
        )
    }

    /// 运行中打开 gate → 本轮就开始监听，不必等下一轮。
    func testTurningGateOnMidAnswerStartsListeningImmediately() {
        let h = makeHarness(gate: false)
        h.driveToSpeaking()
        XCTAssertFalse(h.pushToTalk.isVoiceBargeInListening, "gate OFF 时不开麦")

        h.gateEnabled = true
        h.session.noteVoiceBargeInGateChanged(enabled: true)

        XCTAssertTrue(h.pushToTalk.isVoiceBargeInListening, "运行中打开必须当场开监听")
    }

    // MARK: - F2-3：detect_ms 的口径与 stop_ms 的测量对象

    /// `detect_ms` 是**起说 → 判定命中**（ESS-655 契约），恒等于 300ms 判据，
    /// 不是「用户在回答的第几秒插的话」。
    ///
    /// 整改前算的是 `起说 − 起播`：用户听了 5 秒才插话就会报 `detect_ms=5000`，
    /// 「检测延迟」这条指标整体失真。
    func testDetectMsMeasuresSpeechStartToHitNotPlaybackStart() throws {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        let h = makeHarness(gate: true)
        h.driveToSpeaking()

        // 先静音 2 秒（守卫窗早过），再连续说话直到命中。
        for _ in 0..<20 { h.recorder.feed(Harness.pcmFrame(rms: 0.0)) }
        for _ in 0..<5 { h.recorder.feed(Harness.pcmFrame(rms: 0.2)) }

        let detail = try XCTUnwrap(log.details(of: "session_speaking_interrupted").last)
        let fields = try PhoneModeTelemetry.validate(
            event: "session_speaking_interrupted", detail: detail, rejectsUnknownFields: true
        )
        XCTAssertEqual(fields["source"], "voice")
        XCTAssertEqual(
            fields["detect_ms"], "300",
            "detect_ms 必须是 300ms 连续判据本身，不是「插话发生在回答的第几秒」"
        )
        // 「第几秒插的话」另有其字段，不占用 detect_ms。
        let detectorDetail = try XCTUnwrap(log.details(of: "barge_in_detected").last)
        XCTAssertTrue(detectorDetail.contains("since_playback_ms=2000"), detectorDetail)
    }

    /// 停播没被播放器确认时必须留证——不许把一个测量对象错了的 `stop_ms`
    /// 悄悄当成「≤200ms 达标」。
    func testUnconfirmedStopIsLoggedAsError() {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        let h = makeHarness(gate: true)
        h.driveToSpeaking()
        h.stopConfirmationOverride = false

        h.session.interruptSpeaking(source: .orbTap)

        XCTAssertEqual(log.count(of: "session_interrupt_stop_unconfirmed"), 1)
        XCTAssertEqual(
            log.entries(of: "session_interrupt_stop_unconfirmed").first?.errorCode,
            "ERR_SESSION_STOP_UNCONFIRMED"
        )
    }

    /// 正常路径下停播是被确认的——上面那条错误事件一条都不该出现。
    func testConfirmedStopEmitsNoUnconfirmedError() {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        let h = makeHarness(gate: true)
        h.driveToSpeaking()

        h.session.interruptSpeaking(source: .orbTap)

        XCTAssertEqual(log.count(of: "session_interrupt_stop_unconfirmed"), 0)
        XCTAssertEqual(log.count(of: "playback_stop_confirmed"), 1)
    }

    // MARK: - F2-5：「零误触」需要正面证据

    /// 干净的一轮：
    /// - `session_barge_in_self_echo` **一条都不发**（「计数为 0」按 ESS-650
    ///   验收原文字面成立，也与 `PhoneModeCallMetrics` 把每条计为一次误触发
    ///   的口径一致——每轮发一条 `=0` 会把干净的 5 轮记成 5 次误触发）；
    /// - `voice_barge_in_round` **必发**，带 `frames>0` 与 `self_echo_frames=0`，
    ///   把「零」和「压根没在听」区分开（ESS-667 复审阻断 5）。
    func testCleanRoundEmitsPositiveZeroEvidenceWithoutFalseTriggerEvent() throws {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        let h = makeHarness(gate: true)
        h.driveToSpeaking()

        for _ in 0..<10 { h.recorder.feed(Harness.pcmFrame(rms: 0.0)) }
        h.finishAnswer()

        XCTAssertEqual(
            log.count(of: "session_barge_in_self_echo"), 0,
            "零误触时这条事件一条都不该出现"
        )
        let round = try XCTUnwrap(log.details(of: "voice_barge_in_round").last)
        XCTAssertTrue(round.contains("self_echo_frames=0"), round)
        XCTAssertTrue(round.contains("frames=10"), "必须证明帧真的喂进来了：\(round)")
        XCTAssertTrue(round.contains("cumulative_self_echo_frames=0"), round)
    }

    /// 守卫窗内有回声时：不打断，但要按 ESS-655 契约报出来（含 `energy_db`，
    /// 好判断离阈值还剩多少余量）。
    func testSelfEchoInGuardWindowIsReportedThroughTelemetryContract() throws {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        let h = makeHarness(gate: true)
        h.driveToSpeaking()

        // 400ms 守卫窗 = 前 4 帧（100ms/帧）。
        for _ in 0..<4 { h.recorder.feed(Harness.pcmFrame(rms: 0.2)) }
        XCTAssertEqual(h.session.turnPhase, .speaking, "守卫窗内不得打断")
        h.finishAnswer()

        let detail = try XCTUnwrap(log.details(of: "session_barge_in_self_echo").last)
        let fields = try PhoneModeTelemetry.validate(
            event: "session_barge_in_self_echo", detail: detail, rejectsUnknownFields: true
        )
        XCTAssertEqual(fields["turn_index"], "1")
        XCTAssertNotNil(Double(try XCTUnwrap(fields["energy_db"])), "energy_db 必须是可解析的十进制")
        XCTAssertTrue(
            try XCTUnwrap(log.details(of: "voice_barge_in_round").last).contains("self_echo_frames=4")
        )
    }

    /// F2-5 的「连续 5 轮」在 Watch 侧的可跑版本：五轮全静音，
    /// 累计为 0，且五轮各有一条正面证据。真机版属关卡二。
    func testFiveSilentRoundsAccumulateZeroSelfEcho() {
        let log = LogSpy(); log.install(); defer { log.uninstall() }
        let h = makeHarness(gate: true)
        h.driveToSpeaking()

        for round in 0..<5 {
            for _ in 0..<10 { h.recorder.feed(Harness.pcmFrame(rms: 0.0)) }
            h.finishAnswer()
            if round < 4 { h.driveNextAnswer() }
        }

        XCTAssertEqual(log.count(of: "session_barge_in_self_echo"), 0, "五轮累计零误触")
        let rounds = log.details(of: "voice_barge_in_round")
        XCTAssertEqual(rounds.count, 5, "每轮都要有一条正面证据")
        for detail in rounds {
            XCTAssertTrue(detail.contains("frames=10"), detail)
            XCTAssertTrue(detail.contains("self_echo_frames=0"), detail)
        }
    }

    // MARK: - 替身与测试台

    private func isolatedDefaults(_ label: String) -> UserDefaults {
        let suite = "wristagent.tests.ess650evidence.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeAudioController(
        session: FakeAudioSession, gate: Bool
    ) -> ConversationAudioController {
        let controller = ConversationAudioController(
            session: session, captureControl: FakeEngine(), playbackControl: FakeEngine()
        )
        controller.voiceBargeInEnabled = { gate }
        return controller
    }

    /// 只记 mode 的 `AVAudioSession` 替身。`rejectModes` 让指定 mode 抛错，
    /// 用来验证 ESS-61/72 的两级回落阶梯没有被简化掉。
    private final class FakeAudioSession: ConversationAudioSessionDriving {
        private(set) var modes: [AVAudioSession.Mode] = []
        var rejectModes: Set<AVAudioSession.Mode> = []

        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            policy: AVAudioSession.RouteSharingPolicy,
            options: AVAudioSession.CategoryOptions
        ) throws {
            modes.append(mode)
            if rejectModes.contains(mode) { throw NSError(domain: "FakeAudioSession", code: -50) }
        }

        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
    }

    private final class FakeEngine: ConversationAudioEngineControlling {
        private(set) var isRunning = false
        func prepare() {}
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
    }

    private final class LogSpy: @unchecked Sendable {
        struct Entry {
            let event: String
            let detail: String?
            let errorCode: String?
        }

        private let lock = NSLock()
        private var storage: [Entry] = []

        func install() {
            WatchLog.setObserver { [weak self] _, event, _, detail, code in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.storage.append(Entry(event: event, detail: detail, errorCode: code))
            }
        }

        func uninstall() { WatchLog.setObserver(nil) }

        func entries(of event: String) -> [Entry] {
            lock.lock(); defer { lock.unlock() }
            return storage.filter { $0.event == event }
        }

        func details(of event: String) -> [String] { entries(of: event).compactMap(\.detail) }
        func count(of event: String) -> Int { entries(of: event).count }
    }

    private func makeHarness(gate: Bool) -> Harness {
        let h = Harness(gate: gate)
        addTeardownBlock { @MainActor in h.tearDown() }
        return h
    }

    /// 与 `VoiceBargeInWiringTests.Harness` 同形：生产 `SessionController` +
    /// 生产 `SessionTurnWiring` + 真实 adapter/`RealtimeMediaSession`，
    /// 只替身 recorder / player / transport（无音频硬件的 CI 上真实
    /// `AVAudioEngine` 直接杀进程，ESS-498/362 家族）。
    @MainActor
    final class Harness {
        let session: SessionController
        let pushToTalk = PushToTalkController()
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let adapter: WatchRealtimeMediaAdapter

        var gateEnabled: Bool
        /// 非 nil 时覆盖停播确认，用来验证「未确认必须留证」。
        var stopConfirmationOverride: Bool?

        private(set) var startedTurns: [RealtimeMediaSession.TurnHandle] = []

        init(gate: Bool) {
            gateEnabled = gate
            session = SessionController(
                defaults: UserDefaults(suiteName: "VoiceBargeInEvidence.\(UUID().uuidString)")!
            )
            adapter = WatchRealtimeMediaAdapter(
                recorder: recorder, player: player, transport: transport,
                vadConfiguration: LocalVADConfiguration(),
                automaticallyCommitOnSpeechFinal: true
            )
            SessionTurnWiring.connect(session: session, pushToTalk: pushToTalk, interruptSelfCheck: {})
            pushToTalk.useRealtimeAdapterForTests(adapter)
            pushToTalk.attachSessionEvents(to: adapter)
            session.voiceBargeInEnabled = { [weak self] in self?.gateEnabled ?? false }
            session.scheduleDelay = { _, _ in NoopToken() }
            session.playHaptic = { _ in }
            adapter.beginConversation()
            session.onBeginChannel = { [weak self] in self?.beginTurn() }
            session.onStartTurn = { [weak self] in self?.beginTurn() }

            let productionInterrupt = session.onInterruptSpeaking
            session.onInterruptSpeaking = { [weak self] source in
                guard let self else { return false }
                let confirmed = productionInterrupt?(source) ?? false
                return self.stopConfirmationOverride ?? confirmed
            }
        }

        func tearDown() {}

        private func beginTurn() -> String? {
            let handle = adapter.beginTurn(requestId: UUIDv7.generate().uuidString.lowercased())
            startedTurns.append(handle)
            return handle.requestId
        }

        var currentRequestId: String { startedTurns.last?.requestId ?? "" }

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

        func finishAnswer() {
            session.markAnswerFinished(requestId: currentRequestId)
        }

        /// 已经回到 listening 之后，把新一轮推进到 speaking。
        func driveNextAnswer() {
            pushToTalk.onSessionTurnCommitted?(currentRequestId)
            pushToTalk.onSessionAnswerStarted?(currentRequestId)
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

    final class MockRecorder: WatchRealtimeMediaAdapter.Recorder {
        var onFrame: ((Data) -> Void)?
        var onFailure: ((Error) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start() throws { startCount += 1 }
        func stop() { stopCount += 1 }
        func feed(_ data: Data) { onFrame?(data) }
    }

    final class MockPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        /// 与真实引擎同语义——入队即出声，`bargeIn`/`stop` 即静音。
        private(set) var isRenderingDownlink = false

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {}
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
            if !playables.isEmpty { isRenderingDownlink = true }
        }
        func bargeIn(clearedBytes: Int) { isRenderingDownlink = false }
        func finish(responseId: String?) {}
        func stop(barge: Bool) { isRenderingDownlink = false }
    }

    final class MockTransport: WatchRealtimeMediaAdapter.Transport {
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
        func sendPlaybackEnded(
            handle: RealtimeMediaSession.TurnHandle, responseId: String, bytesPlayed: Int
        ) {}
        func fallbackToCompleteFile(
            handle: RealtimeMediaSession.TurnHandle, reason: RealtimeUplinkStream.FallbackReason
        ) {}
        func sendBargeInRequest(_ request: RealtimeBargeInRequest) {}
    }

    private final class NoopToken: SessionDelayToken {
        func cancel() {}
    }
}
