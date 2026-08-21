import XCTest
@testable import WristAgent_Watch_App

/// ESS-960（Watch 侧，缺陷 3 与缺陷 4）。
///
/// 缺陷 3：整轮没听到人说话时，`session_turn_cap_skipped` 只落一条日志就走人。
/// 真机 L1：`audio_too_short pcm_bytes=1916800 duration_ms=59900 rms=5` ——
/// 录满 59.9 秒、rms=5（≈ VAD 门限的 1/50），50s 时会话层已经知道「没听到人
/// 说话」，用户却在随后的 60s 自停 → 整文件回退 → Bridge 判太短 → 失败回投
/// 全过程得不到任何提示。
///
/// 缺陷 4：iPhone 侧通道终态在 `PhoneConnectivity.onStateChange` 里被整条丢掉
/// （那个闭包只认 `.active`），Watch 因此永远等不到「通道死了」。
@MainActor
final class Ess960SessionRecoveryTests: XCTestCase {

    private var controller: SessionController!
    private var haptics: [SessionController.Haptic]!
    private var scheduled: [(delay: TimeInterval, fire: @MainActor () -> Void)]!
    private var commitCount = 0
    private var teardownCount = 0
    private var discardCount = 0
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess960SessionRecoveryTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        haptics = []
        scheduled = []
        commitCount = 0
        teardownCount = 0
        discardCount = 0
        controller.playHaptic = { [weak self] in self?.haptics.append($0) }
        controller.scheduleDelay = { [weak self] delay, fire in
            self?.scheduled.append((delay, fire))
            return Ess960FakeDelayToken()
        }
        var began = 0
        controller.onBeginChannel = { began += 1; return "req-\(began)" }
        controller.onCommitTurn = { [weak self] in self?.commitCount += 1 }
        controller.onTeardownChannel = { [weak self] in self?.teardownCount += 1 }
        controller.onDiscardTurn = { [weak self] in self?.discardCount += 1 }
        var turns = 0
        controller.onStartTurn = { turns += 1; return "turn-\(turns)" }
    }

    override func tearDown() {
        controller = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 缺陷 3

    /// 到达单轮上限、整轮没听到人说话：**回合必须真正终结**——丢弃这轮死采集、
    /// 相位回 `.idle`，并给出一行可行动提示 + 失败触觉。修复前这里只落一条
    /// 日志就 return，notice 为 nil、相位不动、采集不收。
    func testTurnCapWithoutSpeechTerminatesTurnAndNotifiesUser() {
        controller.enterSession()
        controller.markChannelReady()
        XCTAssertEqual(controller.turnPhase, .listening)

        fireDelay(matching: SessionController.turnCapSeconds)

        // 用户可见：一行可行动文案 + 失败触觉。
        XCTAssertEqual(controller.failureNotice, SessionController.noSpeechNoticeCopy)
        XCTAssertTrue(haptics.contains(.failure))
        // 回合真正收口：死采集被丢弃（不是被提交，也不是被放着继续录）。
        XCTAssertEqual(discardCount, 1)
        // ESS-865 的不变量：静音一律**不提交**。
        XCTAssertEqual(commitCount, 0)
        // 会话本身还活着，用户随时可以继续说。
        XCTAssertEqual(controller.state, .listening)
    }

    /// 收口之后当场回到可用态：新一轮采集起来了，麦克风不留死态。
    ///
    /// 刻意**同一个 tick 内**完成，不借 `markTurnAborted` 的 1.5s 退避——
    /// 相位只要在退避窗里落到 `.idle`，`armSilenceTimer` 三级治理的
    /// `turnPhase == .listening` 前置就会被打断（ESS-865 复审阻断 2）。
    func testSilentTurnRecycleImmediatelyRestartsCapture() {
        controller.enterSession()
        controller.markChannelReady()
        let firstTurnIndex = controller.turnIndex
        let firstRequestId = controller.activeTurnRequestId

        fireDelay(matching: SessionController.turnCapSeconds)

        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(controller.turnIndex, firstTurnIndex + 1)
        XCTAssertNotNil(controller.activeTurnRequestId)
        XCTAssertNotEqual(controller.activeTurnRequestId, firstRequestId)
        XCTAssertFalse(controller.didDetectSpeechThisTurn)
    }

    /// ESS-865 复审阻断 2 的回归护栏：静音回收**不得**重置静默治理。
    ///
    /// 重开一轮时若走默认的 `armSilenceTimer()`，30/75/120s 三级治理会被每轮
    /// 刷新，用户放下手走开后会话永远不自收——正是 ESS-865 拦下的那个回归。
    /// 判据：回收+重开之后，新排的延迟里不得出现 30s 这一档（静默治理的
    /// 第一级），只应有单轮上限 50s。
    func testSilentTurnRecycleDoesNotRearmSilenceGovernance() {
        controller.enterSession()
        controller.markChannelReady()

        let scheduledBeforeRecycle = scheduled.count
        fireDelay(matching: SessionController.turnCapSeconds)

        let afterRelisten = scheduled[scheduledBeforeRecycle...].map(\.delay)
        XCTAssertFalse(
            afterRelisten.contains { abs($0 - SessionController.silenceHint1Seconds) < 0.001 },
            "静音回收重开不得重新起算静默治理（ESS-865）"
        )
        XCTAssertTrue(
            afterRelisten.contains { abs($0 - SessionController.turnCapSeconds) < 0.001 },
            "新一轮仍须有单轮上限兜底"
        )
    }

    /// 说过话的正常换轮**必须**重置静默治理——本修复只收窄静音那一条路径。
    func testNormalRelistenStillRearmsSilenceGovernance() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markSpeechDetected(requestId: "req-1")
        controller.markTurnCommitted(requestId: "req-1")
        controller.markAnswerStarted(requestId: "req-1")
        let before = scheduled.count
        controller.markAnswerFinished(requestId: "req-1")

        let afterFinish = scheduled[before...].map(\.delay)
        XCTAssertTrue(
            afterFinish.contains { abs($0 - SessionController.silenceHint1Seconds) < 0.001 },
            "正常换轮仍须重新起算静默治理（ESS-652）"
        )
    }

    /// 提示文案是「怎么办」，不含错误码、不解释内部状态（PRD 异常链文案纪律）。
    func testNoSpeechNoticeCopyCarriesNoErrorCode() {
        let copy = SessionController.noSpeechNoticeCopy
        XCTAssertFalse(copy.isEmpty)
        XCTAssertFalse(copy.contains("ERR_"))
        XCTAssertFalse(copy.lowercased().contains("error"))
        XCTAssertFalse(copy.contains("VAD"))
        XCTAssertFalse(copy.contains("rms"))
    }

    /// 说过话的回合到点仍按原样提交——本修复不得改动主干路径。
    func testTurnCapWithSpeechStillCommits() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markSpeechDetected(requestId: "req-1")
        XCTAssertTrue(controller.didDetectSpeechThisTurn)

        fireDelay(matching: SessionController.turnCapSeconds)

        XCTAssertEqual(commitCount, 1)
        XCTAssertNil(controller.failureNotice)
    }

    // MARK: - 缺陷 4

    /// 通道终态必须驱动失败链：P6 失败态 + 一行可行动文案 + 失败触觉 + 拆链。
    func testChannelFailureDrivesFailedStateWithActionableCopy() {
        controller.enterSession()
        controller.markChannelReady()

        controller.markChannelFailed(.channelEvent)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.failedReason, "连接断了，本轮对话已结束")
        XCTAssertFalse(controller.failedReason?.contains("ERR_") ?? true)
        XCTAssertTrue(controller.failedRetryable)
        XCTAssertTrue(haptics.contains(.failure))
        XCTAssertEqual(teardownCount, 1)
    }

    /// 适配器收到 iPhone 的通道终态 → 触发 `onChannelFailed`。
    /// 这是缺陷 4 新增的那一跳；接线的另一端（→ `markChannelFailed`）在
    /// `PushToTalkController.attachSessionEvents` 里，由生产路径独占。
    func testAdapterForwardsChannelFailedForCurrentTurn() {
        let adapter = Self.makeAdapter()
        var failures: [(String, String)] = []
        adapter.onChannelFailed = { failures.append(($0, $1)) }

        let requestId = "01a017b1-3cdd-72e1-9137-94cc6b9a836c"
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.receiveChannelFailed(RealtimeChannelFailed(
            requestId: requestId, sessionId: handle.sessionId,
            reason: "gateway_error_ERR_STREAM_SEQUENCE"
        ))

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.0, requestId)
        XCTAssertEqual(failures.first?.1, "gateway_error_ERR_STREAM_SEQUENCE")
    }

    /// 上一轮的迟到失败态不得污染当前这一轮（同 `stale_channel_ready_dropped`）。
    func testAdapterDropsStaleChannelFailed() {
        let adapter = Self.makeAdapter()
        var failures: [(String, String)] = []
        adapter.onChannelFailed = { failures.append(($0, $1)) }

        let handle = adapter.beginTurn(requestId: "01a017b1-3cdd-72e1-9137-94cc6b9a836c")
        adapter.receiveChannelFailed(RealtimeChannelFailed(
            requestId: "01a017b0-0000-7000-8000-000000000000",
            sessionId: handle.sessionId, reason: "gateway_error_ERR_STREAM_SEQUENCE"
        ))

        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - Helpers

    private func fireDelay(matching delay: TimeInterval) {
        guard let entry = scheduled.last(where: { abs($0.delay - delay) < 0.001 }) else {
            return XCTFail("no scheduled delay matching \(delay)s")
        }
        entry.fire()
    }

    private static func makeAdapter() -> WatchRealtimeMediaAdapter {
        WatchRealtimeMediaAdapter(
            recorder: NoopRecorder(),
            player: NoopPlayer(),
            transport: NoopTransport(),
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: false
        )
    }

    private final class NoopRecorder: WatchRealtimeMediaAdapter.Recorder {
        var onFrame: ((Data) -> Void)?
        var onFailure: ((Error) -> Void)?
        func start() throws {}
        func stop() {}
    }

    private final class NoopPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        var isRenderingDownlink: Bool { false }
        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {}
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {}
        func bargeIn(clearedBytes: Int) {}
        func finish(responseId: String?) {}
        func stop(barge: Bool) {}
    }

    private final class NoopTransport: WatchRealtimeMediaAdapter.Transport {
        func sendStreamStart(_ start: RealtimeStreamStart, conversationId: String?, turnId: String?) {}
        func sendAudioAppend(_ chunk: VoiceStreamChunk, conversationId: String?, turnId: String?) {}
        func sendAudioCommit(_ commit: RealtimeStreamCommit, conversationId: String?, turnId: String?) {}
        func sendPlaybackStarted(handle: RealtimeMediaSession.TurnHandle, responseId: String) {}
        func sendPlaybackEnded(
            handle: RealtimeMediaSession.TurnHandle, responseId: String, bytesPlayed: Int
        ) {}
        func fallbackToCompleteFile(
            handle: RealtimeMediaSession.TurnHandle,
            reason: RealtimeUplinkStream.FallbackReason
        ) {}
        func sendBargeInRequest(_ request: RealtimeBargeInRequest) {}
    }
}

/// 测试用延迟令牌：只记录取消，不真正调度。
private final class Ess960FakeDelayToken: SessionDelayToken {
    func cancel() {}
}
