import XCTest
@testable import WristAgent_Watch_App

/// ESS-573（Wave 1 / F1）：SessionController 生命周期 + 手势冲突决策的
/// 专项测试。复审硬约束的钉死点：
///
/// 1. **无同步 ready**：enterSession 后状态必须停在 connecting，只有
///    `markChannelReady`（真实 uplink ack 事件）能推进到 listening。
/// 2. **失败只由真实事件驱动**：录音启动失败 / 上行发送失败 / 回退 /
///    就绪超时，全部走向「告知 + 回 idle」，不静默卡在建立中。
/// 3. **退出即释放**：任意会话态点 X / 下滑 → 拆链 + 回 idle。
/// 4. **手势冲突**：会话中②③屏不渲染（无页可切）；下滑拦截只认垂直
///    为主的下滑；点/长按分界钉在 0.2s。
///
/// 计时器全部经 `scheduleDelay` 接缝替换为手动触发，测试零睡眠、确定性。
@MainActor
final class SessionControllerTests: XCTestCase {

    private var controller: SessionController!
    private var haptics: [SessionController.Haptic]!
    private var scheduled: [(delay: TimeInterval, fire: @MainActor () -> Void)]!
    private var cancelCount: Int = 0
    private var beginCount = 0
    private var teardownCount = 0
    private var commitCount = 0
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionControllerTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        haptics = []
        scheduled = []
        cancelCount = 0
        beginCount = 0
        teardownCount = 0
        commitCount = 0

        controller.playHaptic = { [weak self] in self?.haptics.append($0) }
        controller.scheduleDelay = { [weak self] delay, fire in
            self?.scheduled.append((delay, fire))
            return FakeDelayToken { self?.cancelCount += 1 }
        }
        // ESS-600：`onBeginChannel` 现在返回**已在飞那一轮**的 request_id
        // （点球进会话时录音在 touch-down 就开始了），会话据此认领第 1 轮。
        controller.onBeginChannel = { [weak self] in
            self?.beginCount += 1
            return "req-\(self?.beginCount ?? 0)"
        }
        controller.onTeardownChannel = { [weak self] in self?.teardownCount += 1 }
        controller.onCommitTurn = { [weak self] in self?.commitCount += 1 }
    }

    override func tearDown() {
        controller = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 进入

    /// 复审核心：enterSession 只发起通道，状态停在 connecting——
    /// 绝不同步宣告 ready。
    func testEnterStaysConnectingUntilRealReadyEvent() {
        controller.enterSession()
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertTrue(controller.isInSession)
        XCTAssertEqual(beginCount, 1)
        // 建立初期不显示三点（>800ms 才显示）。
        XCTAssertFalse(controller.showConnectingDots)
        // 无任何触觉由 SessionController 播放（进入 .start 由 pressBegan 链兑现）。
        XCTAssertTrue(haptics.isEmpty)
    }

    /// 会话中/建立中重复点球一律忽略——不会重复发起通道。
    func testEnterRejectedWhenNotIdle() {
        controller.enterSession()
        controller.enterSession()
        XCTAssertEqual(beginCount, 1)
        controller.markChannelReady()
        controller.enterSession()
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    /// 建立超过 800ms 未就绪 → 三点提示出现（PRD §3.5.1 第 3 步）。
    func testConnectingDotsAppearAfterDelay() {
        controller.enterSession()
        fireDelay(SessionController.connectingDotsDelaySeconds)
        XCTAssertTrue(controller.showConnectingDots)
        XCTAssertEqual(controller.state, .connecting)
    }

    // MARK: - 就绪（真实事件驱动）

    func testRealReadyEventDrivesListening() {
        controller.enterSession()
        controller.markChannelReady()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(haptics, [.ready])
        // 就绪后三点提示不再悬着。
        XCTAssertFalse(controller.showConnectingDots)
    }

    /// ESS-944：VAD 自动断句把首轮提交提前到建立窗口内，submit 先于首个
    /// uplink ack 到达（真机 L1：uplink_committed 02:48:01.4 先于首个 ack）。
    /// 此时 markTurnCommitted 不得被静默丢弃——connecting 期间直接进入
    /// thinking，就绪后不得把它写回 listening。
    func testTurnCommittedBeforeChannelReadyEntersThinking() {
        controller.enterSession()
        let requestId = controller.activeTurnRequestId!
        var startTurnCount = 0
        controller.onStartTurn = {
            startTurnCount += 1
            return "req-next"
        }

        // 提交先于就绪：直接推进到 thinking，不丢事件。
        controller.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertEqual(controller.turnPhase, .thinking, "提交先到 → 直接进入 thinking")

        controller.markChannelReady()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .thinking, "就绪不得覆盖已推进的 thinking 相位")

        // 相位对了，realtime 播放事件才能一路走到自动重新聆听。
        controller.markAnswerStarted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .speaking)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(startTurnCount, 1, "播完必须自动开下一轮")
    }

    /// ESS-944：提交先于就绪只对「本会话认领的那一轮」生效；陈旧回合的
    /// 提交（request_id 对不上）照旧丢弃留证，不得污染下一轮。
    func testStaleTurnCommittedBeforeChannelReadyIsDropped() {
        controller.enterSession()
        controller.markTurnCommitted(requestId: "req-stale")
        XCTAssertEqual(controller.state, .connecting)

        controller.markChannelReady()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .listening, "陈旧回合不得被认领")
    }

    /// 迟到的 ready（退出后才到的 ack）不得把会话拉回 listening。
    func testLateReadyAfterExitIsIgnored() {
        controller.enterSession()
        controller.exitSession()
        // ESS-652: exitSession now goes through P7 hungup, not idle.
        XCTAssertEqual(controller.state, .hungup)
        controller.markChannelReady()
        // hungup dismisses to idle after 1.2s
        XCTAssertNotEqual(controller.state, .listening)
        // 退出那一次 .exit 之后不得再有 .ready。
        XCTAssertEqual(haptics, [.exit])
    }

    /// 就绪后 PTT 屏那个「再点 enter」的口径不变：listening 里再来
    /// ready 事件（同回合后续 ack）不改变状态、不重复触觉。
    func testDuplicateReadyWhileListeningIsIgnored() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markChannelReady()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(haptics, [.ready])
    }

    /// ESS-695：30 秒是持续会话稳定性验收窗口，不是设备等待动作。
    /// 即使触发首段静默提示，只要会话仍有输入能力，页面必须继续停留。
    func testConversationRemainsVisibleAfterThirtySeconds() {
        controller.enterSession()
        controller.markChannelReady()

        fireDelay(SessionController.silenceHint1Seconds)

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isInSession)
        XCTAssertEqual(teardownCount, 0)
    }

    /// 流式回答进行中超过 30 秒也不得被静默治理误判并退回表盘。
    func testStreamingAnswerRemainsVisibleAfterThirtySeconds() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        controller.markAnswerStarted(requestId: requestId)

        fireDelay(SessionController.silenceHint1Seconds)

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .speaking)
        XCTAssertTrue(controller.isInSession)
        XCTAssertEqual(teardownCount, 0)
    }

    // MARK: - ESS-891 低音量提示

    private func enterListeningAndSpeaking() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        controller.markAnswerStarted(requestId: requestId)
    }

    /// 阈值钉住：低于 0.6 提示，等于/高于 0.6 不提示。
    func testLowVolumeHintPolicyThreshold() {
        XCTAssertTrue(SessionController.shouldSurfaceLowVolumeHint(outputVolume: 0.0))
        XCTAssertTrue(SessionController.shouldSurfaceLowVolumeHint(outputVolume: 0.5))
        XCTAssertTrue(SessionController.shouldSurfaceLowVolumeHint(outputVolume: 0.599))
        XCTAssertFalse(SessionController.shouldSurfaceLowVolumeHint(outputVolume: 0.6))
        XCTAssertFalse(SessionController.shouldSurfaceLowVolumeHint(outputVolume: 1.0))
    }

    /// 真机取证口径：`output_volume=0.500` 时应提示调高音量。
    func testAnswerStartedAtLowVolumeRaisesHint() {
        controller.readOutputVolume = { 0.5 }
        enterListeningAndSpeaking()
        XCTAssertTrue(controller.lowVolumeHint)
    }

    /// 音量满格时不打扰。
    func testAnswerStartedAtFullVolumeDoesNotRaiseHint() {
        controller.readOutputVolume = { 1.0 }
        enterListeningAndSpeaking()
        XCTAssertFalse(controller.lowVolumeHint)
    }

    /// 提示只在 speaking 期间有效，回答播完即清除。
    func testLowVolumeHintClearsWhenAnswerFinishes() {
        controller.readOutputVolume = { 0.5 }
        enterListeningAndSpeaking()
        XCTAssertTrue(controller.lowVolumeHint)
        controller.markAnswerFinished(requestId: controller.activeTurnRequestId!, success: true)
        XCTAssertFalse(controller.lowVolumeHint)
    }

    /// 会话退出（点 X）后提示不得残留。
    func testLowVolumeHintClearsOnSessionExit() {
        controller.readOutputVolume = { 0.5 }
        enterListeningAndSpeaking()
        XCTAssertTrue(controller.lowVolumeHint)
        controller.exitSession()
        XCTAssertFalse(controller.lowVolumeHint)
    }

    // MARK: - ESS-960 无人说话的回合到上限后不得留下死麦克风

    /// 事故形态（2026-08-21 真机 `request_id=01a02531-03e5`）：本轮录到
    /// 59.9 秒、rms=5（≈ -76 dBFS，近乎静音），VAD 阈值约 0.00785
    /// （int16 ≈ 257）差了 50 倍，永远不可能断句，于是永远不 commit。
    ///
    /// `AudioRecorder.maxDuration = 60s`，而 `turnCapSeconds = maxDuration - 10`。
    /// 旧实现在 turnCap 到点时只落一条 `session_turn_cap_skipped` 就 return：
    /// 10 秒后录音器自己到顶停录，**而会话仍认为自己在 listening，直到 120s
    /// 静默挂断**。中间这 60 秒麦克风是死的，用户说什么都没人接。
    ///
    /// 正是 `armTurnCap` 自己的注释要避免的「聆听悬在已停录的死麦克风上」，
    /// 只不过当时只为说过话的回合兑现了。
    func testTurnCapWithoutSpeechRestartsCaptureWithoutCommitting() {
        controller.enterSession()
        controller.markChannelReady()
        var startTurnCount = 0
        controller.onStartTurn = {
            startTurnCount += 1
            return "req-restarted"
        }
        let commitsBefore = commitCount
        let turnIndexBefore = controller.turnIndex

        fireDelay(SessionController.turnCapSeconds)

        XCTAssertEqual(commitCount, commitsBefore,
                       "ESS-865 阻断 2：无人说话不得把静音提交上去")
        XCTAssertEqual(startTurnCount, 1,
                       "麦克风必须重开——否则录音器 10s 后到顶停录，会话却还在 listening")
        XCTAssertEqual(controller.turnIndex, turnIndexBefore + 1)
        XCTAssertEqual(controller.turnPhase, .listening,
                       "ESS-865 阻断 2：必须留在聆听相位，静默治理才接得上")
        XCTAssertFalse(controller.didDetectSpeechThisTurn, "新一轮重新计「有没有人说话」")
    }

    /// 重开采集**不得**重置静默治理时钟：用户放下手走开时，30s/75s/120s
    /// 的收场策略必须照原计划走完，不能被换麦克风这件事无限推迟。
    func testTurnCapRestartDoesNotResetSilenceGovernance() {
        controller.enterSession()
        controller.markChannelReady()
        controller.onStartTurn = { "req-restarted" }

        let silenceArmsBefore = scheduled.filter {
            abs($0.delay - SessionController.silenceHint1Seconds) < 0.001
        }.count

        fireDelay(SessionController.turnCapSeconds)

        let silenceArmsAfter = scheduled.filter {
            abs($0.delay - SessionController.silenceHint1Seconds) < 0.001
        }.count
        XCTAssertEqual(silenceArmsAfter, silenceArmsBefore,
                       "静默时钟被重新武装 → 静默挂断永远到不了")
    }

    /// 重开采集失败时**不得**把会话推出聆听态：静默治理以 listening 为前提，
    /// 打断它比留一个死麦克风更糟（用户走开后再也等不到自动挂断）。
    func testTurnCapRestartFailureKeepsSessionListening() {
        controller.enterSession()
        controller.markChannelReady()
        controller.onStartTurn = { nil }

        fireDelay(SessionController.turnCapSeconds)

        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(controller.state, .listening)
    }

    /// 对照：听到过人说话时，到上限走的仍是提交（既有行为不变）。
    func testTurnCapWithSpeechStillCommits() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markSpeechDetected(requestId: controller.activeTurnRequestId!)
        let commitsBefore = commitCount

        fireDelay(SessionController.turnCapSeconds)

        XCTAssertEqual(commitCount, commitsBefore + 1, "听到过说话就该按 60s 上限提交")
    }

    // MARK: - ESS-971 段落屏障：本段完了，回合没完

    /// 2026-08-22 真机（`request_id=01a02783-7e78`）：网关侧 ESS-969 已经在发
    /// `audio.segment_done`，Watch 只落了一条 `downlink_decode_unrecognised`——
    /// 协议上线、客户端没接，于是回合既收不到「这段完了」也收不到「这轮完了」，
    /// 一直挂到用户关掉 App。
    ///
    /// 这条钉住接线后的行为：退回 `.thinking` 等下一段，**绝不开下一轮**。
    /// 开下一轮的话，第二段（真正的答案）会落进下一轮——正是 ESS-600 复审
    /// 阻断 B 钉住的跨轮错乱。
    func testSegmentDoneReturnsToThinkingWithoutStartingNextTurn() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        var startTurnCount = 0
        controller.onStartTurn = { startTurnCount += 1; return "req-next" }
        controller.markTurnCommitted(requestId: requestId)
        controller.markAnswerStarted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .speaking)
        let turnIndexBefore = controller.turnIndex

        // 段落屏障：本段播完，但回合没完。
        controller.markAnswerInterim(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .thinking, "必须退回等待态")
        XCTAssertEqual(startTurnCount, 0, "绝不能开下一轮——第二段会落进下一轮")
        XCTAssertEqual(controller.turnIndex, turnIndexBefore, "回合序号不变")
        XCTAssertEqual(controller.activeTurnRequestId, requestId, "仍是同一轮")
    }

    /// 第二段到达后正常起播，且**仍是同一轮**。
    func testSecondSegmentPlaysBackInSameTurn() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        var startTurnCount = 0
        controller.onStartTurn = { startTurnCount += 1; return "req-next" }
        controller.markTurnCommitted(requestId: requestId)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerInterim(requestId: requestId)

        // 工具跑完，第二段来了。
        controller.markAnswerStarted(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .speaking, "第二段应正常起播")
        XCTAssertEqual(controller.activeTurnRequestId, requestId)
        XCTAssertEqual(startTurnCount, 0)
    }

    /// 段落屏障后必须**重新武装**思考超时：第二段若永不到达，
    /// 会话要能被超时捞回，而不是永久挂死（真机上就是挂到用户关 App）。
    func testSegmentDoneRearmsThinkingTimeout() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.onStartTurn = { "req-next" }
        controller.markTurnCommitted(requestId: requestId)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerInterim(requestId: requestId)

        fireDelay(SessionController.thinkingHardTimeoutSeconds)

        XCTAssertEqual(controller.state, .failed, "第二段不来时必须被超时捞回")
    }

    // MARK: - 失败路径

    /// 就绪超时：5s 无真实 ack → 进入 P6 failed 态（不退回 idle）。
    /// ESS-652: markChannelFailed 现在进入 .failed 而非 .idle。
    func testReadyTimeoutEntersFailedState() {
        controller.enterSession()
        fireDelay(SessionController.readyTimeoutSeconds)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertNotNil(controller.failedReason)
        XCTAssertTrue(controller.failedRetryable)
        XCTAssertEqual(teardownCount, 1)
        XCTAssertTrue(controller.isInSession)
    }

    /// ESS-652: recorderStart 失败现在也进入 P6，不复用旧 failureNotice。
    func testRecorderStartFailureEntersFailedState() {
        controller.enterSession()
        controller.markChannelFailed(.recorderStart)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertNotNil(controller.failedReason)
        XCTAssertFalse(controller.failedRetryable)
        XCTAssertTrue(teardownCount >= 1)
    }

    /// ESS-652: 会话中通道断开进入 P6 failed，非 idle。
    func testMidSessionChannelDropEntersFailed() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markChannelFailed(.channelEvent)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.isInSession)
        XCTAssertEqual(teardownCount, 1)
    }

    /// ESS-652: failedReason replaces failureNotice; P6 auto-hangup at 15s.
    func testFailedReasonNotAutoDismissed() {
        controller.enterSession()
        controller.markChannelFailed(.channelEvent)
        XCTAssertNotNil(controller.failedReason)
        // P6 uses 15s auto-hangup timer, not 2s failure notice dismiss.
        fireDelay(SessionController.failedAutoHangupSeconds)
        // After auto-hangup, transitions to hungup.
        XCTAssertEqual(controller.state, .hungup)
    }

    /// 失败文案纪律：说清「怎么办」，不出现错误码（PRD 异常链 A）。
    func testFailureCopyIsActionableAndCodeFree() {
        XCTAssertEqual(SessionController.failureCopy(forState: .connecting),
                       "连不上，检查一下 iPhone 是否在身边")
        XCTAssertEqual(SessionController.failureCopy(forState: .listening),
                       "连接断了，本轮对话已结束")
        for state in [SessionController.State.connecting, .listening] {
            let copy = SessionController.failureCopy(forState: state)
            XCTAssertFalse(copy.contains("ERR"), "文案不得出现错误码: \(copy)")
        }
    }

    /// 非会话态收到失败事件（PTT 路径的上行失败）一律忽略。
    func testFailureEventsIgnoredWhenIdle() {
        controller.markChannelFailed(.channelEvent)
        controller.markChannelFailed(.recorderStart)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.failureNotice)
        XCTAssertTrue(haptics.isEmpty)
        XCTAssertEqual(teardownCount, 0)
    }

    // MARK: - 退出

    /// 聆听中点 X → .stop 触觉 + 拆链 + 回 idle（PRD F1：立即结束）。
    /// ESS-652: exitSession → P7 hungup, not idle.
    func testExitFromListeningGoesToHungup() {
        controller.enterSession()
        controller.markChannelReady()
        controller.exitSession()
        XCTAssertEqual(controller.state, .hungup)
        XCTAssertEqual(haptics, [.ready, .exit])
        XCTAssertEqual(teardownCount, 1)
    }

    /// ESS-652: exit from connecting → P7 hungup.
    func testExitFromConnectingGoesToHungup() {
        controller.enterSession()
        controller.exitSession()
        XCTAssertEqual(controller.state, .hungup)
        XCTAssertEqual(haptics, [.exit])
        XCTAssertEqual(teardownCount, 1)
    }

    /// 待机时点 X（不应发生，但防御）→ 完全无操作。
    func testExitWhenIdleIsNoOp() {
        controller.exitSession()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(haptics.isEmpty)
        XCTAssertEqual(teardownCount, 0)
    }

    /// ESS-652: exitSession → .hungup, timeout afterwards doesn't double-fail.
    func testPendingTimeoutAfterExitDoesNotRefail() {
        controller.enterSession()
        controller.exitSession()
        XCTAssertEqual(controller.state, .hungup)
        fireDelay(SessionController.readyTimeoutSeconds)
        XCTAssertEqual(controller.state, .hungup)
        XCTAssertEqual(haptics, [.exit])
        XCTAssertEqual(teardownCount, 1)
    }

    // MARK: - 单轮上限（PRD F2 异常的 Wave 1 兜底）

    /// 就绪 + 本地 VAD 确实听到人说话后到达单轮上限 → 视同说完，提交本轮。
    func testTurnCapCommitsAfterReady() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markSpeechDetected(requestId: controller.activeTurnRequestId!)
        fireDelay(SessionController.turnCapSeconds)
        XCTAssertEqual(commitCount, 1)
    }

    /// 上限计时只在聆听中有效——退出后不得再触发提交。
    func testTurnCapCancelledOnExit() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markSpeechDetected(requestId: controller.activeTurnRequestId!)
        controller.exitSession()
        fireDelay(SessionController.turnCapSeconds)
        XCTAssertEqual(commitCount, 0)
    }

    // MARK: - ESS-865 复审阻断 2：纯静音不得被上限提交掉

    /// 从未听到人说话的回合，单轮上限到点**不提交**。
    /// 一旦提交，回合离开 listening，静默治理的 75s/120s guard 全部失效。
    func testTurnCapDoesNotCommitWhenNoSpeechWasEverDetected() {
        controller.enterSession()
        controller.markChannelReady()

        fireDelay(SessionController.turnCapSeconds)

        XCTAssertEqual(commitCount, 0, "纯静音不得被伪造成一次提交")
        XCTAssertEqual(controller.turnPhase, .listening, "必须继续留在聆听相位，交给静默治理")
        XCTAssertFalse(controller.didDetectSpeechThisTurn)
    }

    /// 完整静默治理链路在「一句话都没说」时必须可达：
    /// 50s 上限不提交 → 30s 提示 → 75s 提示 + 触觉 → 120s 挂断。
    func testSilenceGovernanceReachesHangupWhenNothingWasSaid() {
        controller.enterSession()
        controller.markChannelReady()

        fireDelay(SessionController.turnCapSeconds)
        XCTAssertEqual(commitCount, 0)

        // 30s 软提示：会话继续，不退回表盘。
        fireDelay(SessionController.silenceHint1Seconds)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(teardownCount, 0)

        // 75s 提示（相对上一级 45s），带一次 .failure 触觉。
        let secondStage = SessionController.silenceHint2Seconds - SessionController.silenceHint1Seconds
        fireLatestDelay(secondStage)
        XCTAssertTrue(haptics.contains(.failure), "75s 提示必须有触觉，实际 \(haptics!)")
        XCTAssertEqual(controller.state, .listening)

        // 120s 挂断（相对上一级 45s）。
        let hangupStage = SessionController.silenceHangupSeconds - SessionController.silenceHint2Seconds
        fireLatestDelay(hangupStage)
        XCTAssertEqual(controller.state, .hungup, "120s 静默必须按策略挂断")
    }

    /// 单轮上限必须早于 AudioRecorder 的 60s 系统硬顶——否则提交发生在
    /// AVAudioRecorder 自停之后，本地 AAC 收尾会走进「从未起录」误判（ESS-865）。
    func testTurnCapFiresBeforeRecorderHardStop() {
        XCTAssertLessThan(SessionController.turnCapSeconds, AudioRecorder.maxDuration)
    }

    /// 不属于当前轮的 `speech_detected` 不得解锁上限提交。
    func testStaleSpeechDetectedDoesNotUnlockTurnCap() {
        controller.enterSession()
        controller.markChannelReady()

        controller.markSpeechDetected(requestId: "req-stale")

        XCTAssertFalse(controller.didDetectSpeechThisTurn)
        fireDelay(SessionController.turnCapSeconds)
        XCTAssertEqual(commitCount, 0)
    }

    // MARK: - 首次引导（PRD §3.5.7）

    /// 首次进入且通道就绪 → 引导出现，3 秒后淡出。
    func testFirstRunGuideShowsOnceAndFades() {
        controller.enterSession()
        controller.markChannelReady()
        XCTAssertTrue(controller.showFirstRunGuide)
        fireDelay(SessionController.firstRunGuideSeconds)
        XCTAssertFalse(controller.showFirstRunGuide)
    }

    /// 第二次会话不再出现引导（UserDefaults 持久化）。
    func testFirstRunGuideDoesNotRepeat() {
        controller.enterSession()
        controller.markChannelReady()
        fireDelay(SessionController.firstRunGuideSeconds)
        controller.exitSession()

        controller.enterSession()
        controller.markChannelReady()
        XCTAssertFalse(controller.showFirstRunGuide)
    }

    // MARK: - 后台

    /// ESS-598：会话级音频仍持有时，scenePhase 变化不得被误当用户退出。
    func testBackgroundDuringSessionPreservesChannel() {
        controller.enterSession()
        controller.markChannelReady()
        controller.noteEnteredBackground()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertNil(controller.failureNotice)
        XCTAssertEqual(haptics, [.ready])
        XCTAssertEqual(teardownCount, 0)
        XCTAssertTrue(controller.isInSession)
    }

    /// ESS-695: scenePhase may change while still connecting (wrist-down or
    /// system overlay). It must not dismiss or tear down the conversation.
    func testBackgroundWhileConnectingPreservesChannel() {
        controller.enterSession()
        controller.noteEnteredBackground()
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertEqual(teardownCount, 0)
        XCTAssertTrue(controller.isInSession)
    }

    /// 待机时进后台 → 无操作。
    func testBackgroundWhenIdleIsNoOp() {
        controller.noteEnteredBackground()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(haptics.isEmpty)
        XCTAssertEqual(teardownCount, 0)
    }

    // MARK: - 手势冲突决策（PRD §3.5.6）

    /// 会话中②③屏不渲染 = 左右滑无页可切。
    func testAuxiliaryTabsHiddenDuringSession() {
        XCTAssertTrue(SessionController.showsAuxiliaryTabs(inSession: false))
        XCTAssertFalse(SessionController.showsAuxiliaryTabs(inSession: true))
    }

    /// 下滑拦截：只认垂直为主、位移足够的下滑。
    func testVerticalDismissDecision() {
        // 标准下滑 → 拦截（等同点 X）
        XCTAssertTrue(SessionController.isVerticalDismiss(translation: CGSize(width: 0, height: 60)))
        XCTAssertTrue(SessionController.isVerticalDismiss(translation: CGSize(width: 20, height: 50)))
        // 位移太小 → 不触发（防误触）
        XCTAssertFalse(SessionController.isVerticalDismiss(translation: CGSize(width: 0, height: 30)))
        // 水平为主 → 不触发
        XCTAssertFalse(SessionController.isVerticalDismiss(translation: CGSize(width: 80, height: 45)))
        // 上滑 → 不触发
        XCTAssertFalse(SessionController.isVerticalDismiss(translation: CGSize(width: 0, height: -80)))
    }

    // MARK: - ESS-686 持续对话入口与旧 PTT 门槛分流

    /// 短按、旧阈值边界和长按都只进入持续对话，不再因按住时长
    /// 取消采集或退出页面。
    func testHoldDurationDoesNotGatePersistentConversationEntry() {
        XCTAssertEqual(
            SessionController.orbReleaseAction(holdSeconds: 1.0, isCapturing: true),
            .enter
        )
        XCTAssertEqual(
            SessionController.orbReleaseAction(holdSeconds: 0.2, isCapturing: true),
            .enter
        )
        XCTAssertEqual(
            SessionController.orbReleaseAction(holdSeconds: 3.0, isCapturing: true),
            .enter
        )
    }

    /// AC-9 第 2 条：点一下（且 touch-down 那轮确实在采集）→ 进电话，
    /// 认领在飞的那一轮（`enterSession` 的 onBeginChannel 不重起）。
    func testShortTapEntersAndClaimsInFlightTurn() {
        XCTAssertEqual(
            SessionController.orbReleaseAction(holdSeconds: 0.05, isCapturing: true),
            .enter
        )
        controller.enterSession()
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(controller.activeTurnRequestId, "req-1")
        XCTAssertEqual(controller.turnIndex, 1)
    }

    /// touch-down 没能起采（上一轮还在收尾 / 录音启动失败）时不进电话——
    /// 没有在飞的一轮可认领，进去就是空转。
    func testTapWithoutCaptureIsRejected() {
        XCTAssertEqual(
            SessionController.orbReleaseAction(holdSeconds: 0.05, isCapturing: false),
            .reject(.captureUnavailable)
        )
    }

    /// AC-1 的证据面：拒绝必须真的落一条 `session_enter_rejected`，且
    /// detail 同时带 `reason` 与 `hold_ms`——按 R-02.1，「逻辑上应该会记」
    /// 不算数，这里用 `WatchLog` 观察者钉住实际写出去的那一行。
    func testRejectEmitsRuntimeEvidenceWithReasonAndHoldMs() {
        var captured: [(event: String, detail: String?)] = []
        WatchLog.setObserver { _, event, _, detail, _ in
            if event == "session_enter_rejected" { captured.append((event, detail)) }
        }
        defer { WatchLog.setObserver(nil) }

        controller.noteEnterRejected(reason: .captureUnavailable, holdSeconds: 1.0)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.detail, "reason=capture_unavailable hold_ms=1000")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isInSession)
    }

    /// 起采失败且 touch-down 时刻缺失时仍安全拒绝，留证不得因
    /// `Int(.infinity)` 而 trap（直接 `Int()` 会当场崩）。
    func testMissingTouchDownWithoutCaptureIsRejectedWithoutTrapping() {
        var captured: String?
        WatchLog.setObserver { _, event, _, detail, _ in
            if event == "session_enter_rejected" { captured = detail }
        }
        defer { WatchLog.setObserver(nil) }

        XCTAssertEqual(
            SessionController.orbReleaseAction(holdSeconds: .infinity, isCapturing: false),
            .reject(.captureUnavailable)
        )
        controller.noteEnterRejected(reason: .captureUnavailable, holdSeconds: .infinity)

        XCTAssertEqual(captured, "reason=capture_unavailable hold_ms=-1")
    }

    // MARK: - ESS-843 退出原因码（验收标准 4）

    func testExitReasonCodeMapping() {
        XCTAssertEqual(SessionController.exitReasonCode(for: "用户挂断"), .userExit)
        XCTAssertEqual(SessionController.exitReasonCode(for: "静默超时"), .silencePolicy)
        XCTAssertEqual(SessionController.exitReasonCode(for: "auto"), .failedAutoHangup)
        XCTAssertEqual(SessionController.exitReasonCode(for: "user"), .userExit)
        XCTAssertEqual(SessionController.exitReasonCode(for: "未知"), .userExit)
    }

    func testExitSessionRecordsUserExitReason() {
        controller.enterSession()
        controller.markChannelReady()
        controller.exitSession()
        XCTAssertEqual(controller.lastExitReasonCode, .userExit)
    }

    func testSilenceHangupRecordsSilencePolicyReason() {
        controller.enterSession()
        controller.markChannelReady()
        controller.enterHungup(rounds: 1, reason: "静默超时")
        XCTAssertEqual(controller.lastExitReasonCode, .silencePolicy)
    }

    func testEnterSessionResetsExitReasonToUserExit() {
        controller.enterSession()
        controller.markChannelReady()
        controller.enterHungup(rounds: 1, reason: "静默超时")
        XCTAssertEqual(controller.lastExitReasonCode, .silencePolicy)
        fireDelay(SessionController.hungupDismissSeconds)
        XCTAssertEqual(controller.state, .idle)
        controller.enterSession()
        XCTAssertEqual(controller.lastExitReasonCode, .userExit)
    }

    // MARK: - ESS-1044 relay 终态失败收口

    /// 本单核心：relay 判本轮失败后，会话必须**立刻**转出 thinking 进 P6，
    /// 而不是干等 45s 硬超时（真机 14:00:04 失败 → 14:00:45 才被捞回）。
    func testRelayFailureLeavesThinkingImmediately() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        var startTurnCount = 0
        controller.onStartTurn = { startTurnCount += 1; return "req-next" }
        controller.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)

        controller.markTurnFailed(requestId: requestId, errorCode: "ERR_VOICE_BUSY")

        XCTAssertEqual(controller.state, .failed, "必须进 P6，不再卡在 thinking")
        XCTAssertEqual(controller.turnPhase, .idle)
        XCTAssertEqual(controller.failedReason, SessionController.turnFailureCopy)
        XCTAssertTrue(controller.failedRetryable, "执行失败可重试")
        XCTAssertEqual(startTurnCount, 0, "失败不自动开下一轮")
    }

    /// 收口后 45s 硬超时不得再触发——计时器必须被 enterFailed 取消掉，
    /// 否则用户在 P6 上停留时会被第二次「回答超时」文案盖掉。
    func testRelayFailureCancelsThinkingHardTimeout() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.onStartTurn = { "req-next" }
        controller.markTurnCommitted(requestId: requestId)

        controller.markTurnFailed(requestId: requestId)
        XCTAssertEqual(controller.failedReason, SessionController.turnFailureCopy)

        // 计时器已取消；即便调度器把闭包漏出来触发，也不该改写 P6 文案。
        fireDelay(SessionController.thinkingHardTimeoutSeconds)
        XCTAssertEqual(controller.failedReason, SessionController.turnFailureCopy,
                       "硬超时不得二次覆盖失败文案")
    }

    /// 幂等：同一次失败经 iPhone 回执与 Bridge WSS 各来一次，第二次必须被丢弃，
    /// 不得把 P6 的 15s 自动挂断计时器重新武装（等于永远挂不断）。
    func testRepeatedRelayFailureIsIdempotent() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.onStartTurn = { "req-next" }
        controller.markTurnCommitted(requestId: requestId)

        controller.markTurnFailed(requestId: requestId)
        let scheduledAfterFirst = scheduled.count
        controller.markTurnFailed(requestId: requestId)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(scheduled.count, scheduledAfterFirst, "第二次失败不得再排任何计时器")
    }

    /// 陈旧回合的迟到失败不许杀掉当前会话（ESS-642 事故面）。
    func testStaleRequestFailureIsIgnored() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.onStartTurn = { "req-next" }
        controller.markTurnCommitted(requestId: requestId)

        controller.markTurnFailed(requestId: "req-from-a-previous-call")

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .thinking, "别人的失败不动本轮")
    }

    /// 回答已经在放了才收到失败（乱序 / 重复投递）：答案是真实的，
    /// 不得把正在出声的这一轮打进 P6。
    func testFailureDuringSpeakingIsDropped() {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.onStartTurn = { "req-next" }
        controller.markTurnCommitted(requestId: requestId)
        controller.markAnswerStarted(requestId: requestId)

        controller.markTurnFailed(requestId: requestId)

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .speaking)
    }

    /// 不在会话里（PTT 模式）的失败与本控制器无关，不得凭空造出一个 P6。
    func testFailureOutsideSessionIsIgnored() {
        controller.markTurnFailed(requestId: "req-1")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.failedReason)
    }

    // MARK: - helpers

    /// 静默治理是嵌套调度，两级的相对延迟都是 45s。`fireDelay` 取的是**最早**
    /// 那条，会把已经触发过的那一级重复触发；这里取**最新**排入的一条。
    private func fireLatestDelay(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = scheduled.last(where: { abs($0.delay - delay) < 0.001 }) else {
            XCTFail("没有延迟为 \(delay)s 的待触发闭包", file: file, line: line)
            return
        }
        entry.fire()
    }

    private func fireDelay(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = scheduled.first(where: { abs($0.delay - delay) < 0.001 }) else {
            XCTFail("没有延迟为 \(delay)s 的待触发闭包", file: file, line: line)
            return
        }
        entry.fire()
    }
}

/// 测试用延迟令牌：只记录取消，不真正调度。
private final class FakeDelayToken: SessionDelayToken {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}
