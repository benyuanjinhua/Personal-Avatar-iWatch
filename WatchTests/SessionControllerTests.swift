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

    /// 就绪后到达单轮上限 → 视同说完，提交本轮（VAD 落地前的上限兜底）。
    func testTurnCapCommitsAfterReady() {
        controller.enterSession()
        controller.markChannelReady()
        fireDelay(SessionController.turnCapSeconds)
        XCTAssertEqual(commitCount, 1)
    }

    /// 上限计时只在聆听中有效——退出后不得再触发提交。
    func testTurnCapCancelledOnExit() {
        controller.enterSession()
        controller.markChannelReady()
        controller.exitSession()
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

    // MARK: - ESS-686 持续会话入口与旧 PTT 时长守卫分流

    /// 持续会话入口只看 touch-down 采集是否已建立；短按与长按松手都认领
    /// 同一在飞回合，不存在通向 hold_too_long 或 PTT submit 的分支。
    func testReleaseEntersRegardlessOfPressDurationSemantics() {
        XCTAssertEqual(SessionController.orbReleaseAction(isCapturing: true), .enter)
    }

    /// AC-9 第 2 条：点一下（且 touch-down 那轮确实在采集）→ 进电话，
    /// 认领在飞的那一轮（`enterSession` 的 onBeginChannel 不重起）。
    func testShortTapEntersAndClaimsInFlightTurn() {
        XCTAssertEqual(
            SessionController.orbReleaseAction(isCapturing: true),
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
            SessionController.orbReleaseAction(isCapturing: false),
            .reject(.captureUnavailable)
        )
    }

    /// 采集不可用的拒绝必须真的落一条 `session_enter_rejected`——按 R-02.1，「逻辑上应该会记」
    /// 不算数，这里用 `WatchLog` 观察者钉住实际写出去的那一行。
    func testCaptureUnavailableRejectEmitsRuntimeEvidence() {
        var captured: [(event: String, detail: String?)] = []
        WatchLog.setObserver { _, event, _, detail, _ in
            if event == "session_enter_rejected" { captured.append((event, detail)) }
        }
        defer { WatchLog.setObserver(nil) }

        controller.noteEnterRejected(reason: .captureUnavailable)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.detail, "reason=capture_unavailable")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isInSession)
    }

    // MARK: - helpers

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
