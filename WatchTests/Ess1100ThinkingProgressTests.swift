import XCTest
@testable import WristAgent_Watch_App

/// ESS-1100：长任务 thinking 进展文字在会话层的展示规则。
///
/// 体验基线（qwen-audio-agent H5，本单附的两张截图）：长任务执行期间页面不会
/// 只停在笼统的「正在思考」，而是持续换成阶段性文字（「正在查询相关信息」），
/// 用户因此知道任务在推进。本套件钉住的是这条规则在手表上的**可判定形态**：
/// 显示什么、什么时候不显示、以及哪些帧必须被挡在外面。
///
/// 覆盖面对齐本单验收 1 的清单：多条进展、重复/乱序、跨任务污染、idle 早到、
/// 完成/失败/取消/超时。纯逻辑那部分（截断、去抖、序号闸门）在
/// `Tests/ToolProgressNarrationTests.swift`。
///
/// 计时器经 `scheduleDelay` 接缝替换为手动触发，零睡眠。
@MainActor
final class Ess1100ThinkingProgressTests: XCTestCase {

    private var controller: SessionController!
    private var scheduled: [ProgressScheduledDelay]!
    private var startTurnCount = 0
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess1100ThinkingProgressTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        scheduled = []
        startTurnCount = 0
        controller.playHaptic = { _ in }
        controller.scheduleDelay = { [weak self] delay, fire in
            let entry = ProgressScheduledDelay(delay: delay, fire: fire)
            self?.scheduled.append(entry)
            return ProgressCancellingToken(entry: entry)
        }
        controller.onBeginChannel = { "req-progress-1" }
        controller.onTeardownChannel = {}
        controller.onStartTurn = { [weak self] in
            self?.startTurnCount += 1
            return "req-next"
        }
    }

    override func tearDown() {
        controller = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 验收 2：至少两条真实中间进展依次展示

    func testTwoConsecutiveProgressLinesAreShownInOrder() {
        let requestId = beginTurn()

        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")

        // 第二条落在节流窗口内 → 先合并，窗口一到必须补上（不许丢最后一条）。
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 2, text: "正在读取相关内容", category: "read")
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息", "窗口内不重画")

        fireThrottleWindow()

        XCTAssertEqual(controller.toolProcessingText, "正在读取相关内容")
        XCTAssertEqual(controller.turnPhase, .thinking, "进展不改变相位")
    }

    /// 首条进展**不等最终回答**就要反馈——这正是本单要消灭的那个体验。
    func testFirstProgressReplacesTheGenericThinkingCopyImmediately() {
        let requestId = beginTurn()
        XCTAssertNil(controller.toolProcessingText, "还没有任何工具证据")

        controller.markTaskState(requestId: requestId, taskId: nil, status: "tool_call_pending")
        XCTAssertEqual(controller.toolProcessingText, ToolProgressNarration.fallbackText,
                       "有工具证据但还没进展文字 → 稳定兜底")

        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")

        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
    }

    /// 首个回答音频到达 → 切回答态，处理中文案让位。
    func testAnswerAudioTakesOverFromProgressCopy() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")

        controller.markAnswerStarted(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .speaking)
        XCTAssertNil(controller.toolProcessingText, "回答态不显示处理中文案")
    }

    /// 段落播完退回 thinking（工具回合的常态）→ 上一条进展仍然成立，重新显示。
    /// 退回时闪一下兜底文案再跳回原句，是本单点名要避免的抖动。
    func testProgressReturnsAfterInterimSegment() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")
        controller.markAnswerStarted(requestId: requestId)

        controller.markAnswerInterim(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
    }

    // MARK: - 验收 3：普通直接回答不产生多余的处理中跳转

    func testPlainTurnKeepsTheLegacyThinkingCopy() {
        let requestId = beginTurn()

        XCTAssertNil(controller.toolProcessingText,
                     "没有任何工具信号 → 视图沿用逐字相同的「正在思考…」")

        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(startTurnCount, 1, "普通回合照常自动开下一轮")
        XCTAssertNil(controller.toolProcessingText)
    }

    // MARK: - 重复 / 乱序

    func testDuplicateProgressDoesNotRepaint() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")

        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在修改内容", category: "write")

        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
        XCTAssertEqual(controller.toolProgress.droppedCount, 1)
    }

    func testOutOfOrderProgressNeverOverwritesTheNewerLine() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 2, text: "正在读取相关内容", category: "read")
        fireThrottleWindow()
        XCTAssertEqual(controller.toolProcessingText, "正在读取相关内容")

        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")
        fireThrottleWindowIfArmed()

        XCTAssertEqual(controller.toolProcessingText, "正在读取相关内容", "迟到帧不得把新进展盖回旧的")
    }

    // MARK: - 跨任务 / 跨回合污染

    /// 上一轮的迟到进展不得挂到新一轮头上。
    ///
    /// 上一轮必须真的收口才会开下一轮（ESS-1097 闸门），所以这里用**终态**
    /// 任务帧带进展——工具活干完、回答播完，才有「新一轮」可言。
    func testStaleProgressFromPriorTurnIsRejected() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "completed",
                     seq: 1, text: "正在查询相关信息", category: "search")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(startTurnCount, 1)
        let nextRequestId = controller.activeTurnRequestId

        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 2, text: "正在读取相关内容", category: "read")

        XCTAssertEqual(controller.activeTurnRequestId, nextRequestId)
        XCTAssertNil(controller.toolProcessingText, "新一轮不背上一轮的进展")
        XCTAssertNil(controller.toolProgress.text)
    }

    /// 新一轮开始时叙述整体重建——序号闸门也一并清零，否则新会话的第 1 条
    /// 进展会被上一轮的高序号当成「迟到」挡掉，表现为进展永远不出现。
    func testNarrationIsRebuiltPerTurn() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "completed",
                     seq: 42, text: "正在查询相关信息", category: "search")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(startTurnCount, 1, "上一轮已收口才谈得上新一轮")

        let nextRequestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: nextRequestId)
        emitProgress(nextRequestId, taskId: "task-90", status: "running",
                     seq: 1, text: "正在读取相关内容", category: "read")

        XCTAssertEqual(controller.toolProcessingText, "正在读取相关内容",
                       "新一轮的第 1 条不得被上一轮的序号挡掉")
    }

    // MARK: - idle 早到（本单 §4）

    /// 上游 idle → 网关收回合 → 客户端收到「答完了」，而任务仍在 running：
    /// 必须保持处理中状态**和最后一条有效进展**，不得回聆听。
    func testIdleBeforeTaskTerminalKeepsProcessingCopyAndLastProgress() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: nil, status: "tool_call_pending")
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")
        controller.markAnswerStarted(requestId: requestId)

        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .thinking, "任务还在跑，必须留在处理中")
        XCTAssertEqual(startTurnCount, 0, "禁止自动开新 generation")
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息",
                       "最后一条有效进展必须保留，不得退回笼统文案")
    }

    /// 任务终态到了但回答还没播：仍在 thinking，进展保留到回答接手为止。
    func testProgressSurvivesUntilTheAnswerTakesOver() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")

        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "completed")

        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
    }

    // MARK: - 终态：失败 / 取消 / 超时

    func testTurnFailureClearsTheProgressCopy() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")

        controller.markTurnFailed(requestId: requestId, errorCode: "ERR_UPSTREAM")

        XCTAssertNil(controller.toolProcessingText, "明确终态不得停在一句「正在查询」上")
    }

    func testUserCancelClearsTheProgressCopy() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")
        controller.markAnswerStarted(requestId: requestId)
        controller.onInterruptSpeaking = { _ in true }

        controller.interruptSpeaking()

        XCTAssertNil(controller.toolProcessingText)
    }

    func testToolTurnHardTimeoutClearsTheProgressCopy() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")

        fireDelay(SessionController.toolTurnHardTimeoutSeconds)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertNil(controller.toolProcessingText, "超时是明确终态，不得留在处理中文案上")
    }

    func testSessionExitClearsTheProgressCopy() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")

        controller.exitSession()

        XCTAssertNil(controller.toolProcessingText)
    }

    // MARK: - 无进展文本时的稳定兜底（§5）

    func testTaskWithoutProgressTextFallsBackToStableCopy() {
        let requestId = beginTurn()

        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")

        XCTAssertEqual(controller.toolProcessingText, ToolProgressNarration.fallbackText)
        XCTAssertNotEqual(controller.toolProcessingText, "正在思考…")
    }

    /// 一条空文本的进展不得把已显示的那句抹掉——那会造成「有字 → 没字 → 有字」
    /// 的闪烁，比一直显示旧句更糟。
    func testEmptyProgressTextKeepsThePreviousLine() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "task-77", status: "running",
                     seq: 1, text: "正在查询相关信息", category: "search")

        controller.markTaskState(
            requestId: requestId, taskId: "task-77", status: "running",
            progress: AgentTaskProgress(sequence: 2, text: "", category: "search")
        )

        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
    }

    // MARK: - 防闪烁（§5）

    /// 窗口内连发多条只重画一次，且窗口一到显示的是**最后**那条。
    func testBurstOfProgressRepaintsOnceAndLandsOnTheLatest() {
        let requestId = beginTurn()

        emitProgress(requestId, taskId: "t", status: "running", seq: 1, text: "正在排队", category: "queued")
        emitProgress(requestId, taskId: "t", status: "running", seq: 2, text: "正在查询相关信息", category: "search")
        emitProgress(requestId, taskId: "t", status: "running", seq: 3, text: "正在读取相关内容", category: "read")
        emitProgress(requestId, taskId: "t", status: "running", seq: 4, text: "正在修改内容", category: "write")

        XCTAssertEqual(controller.toolProcessingText, "正在排队", "窗口内只认第一条")

        fireThrottleWindow()

        XCTAssertEqual(controller.toolProcessingText, "正在修改内容", "窗口一到补上最后一条，中间的不逐条闪")
    }

    /// 同一句话反复下发（上游 activity 高频刷新的常态）不得触发任何重画，
    /// 也不该白白开一个节流窗口。
    func testRepeatedIdenticalTextDoesNotArmTheThrottle() {
        let requestId = beginTurn()
        emitProgress(requestId, taskId: "t", status: "running", seq: 1, text: "正在查询相关信息", category: "search")
        fireThrottleWindow()
        let windowsBefore = armedDelays(SessionController.progressUpdateMinIntervalSeconds).count

        emitProgress(requestId, taskId: "t", status: "running", seq: 2, text: "正在查询相关信息", category: "search")
        emitProgress(requestId, taskId: "t", status: "running", seq: 3, text: "正在查询相关信息", category: "search")

        XCTAssertEqual(armedDelays(SessionController.progressUpdateMinIntervalSeconds).count, windowsBefore)
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
    }

    // MARK: - 老网关兼容

    /// 网关没实现 `progress_seq` 时进展照常显示——把没带号的帧一律丢掉，
    /// 等于让滚动升级窗口内这个功能整个消失。
    func testProgressWithoutSequenceStillDisplays() {
        let requestId = beginTurn()

        controller.markTaskState(
            requestId: requestId, taskId: "task-77", status: "running",
            progress: AgentTaskProgress(sequence: nil, text: "正在查询相关信息", category: "search")
        )

        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
    }

    /// 完全不带进展的 `task.state`（ESS-1097 老网关）行为不变：闸门照常工作。
    func testLegacyTaskStateWithoutProgressKeepsTheGateIntact() {
        let requestId = beginTurn()

        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertEqual(startTurnCount, 0)
        XCTAssertEqual(controller.toolProcessingText, ToolProgressNarration.fallbackText)
    }

    // MARK: - helpers

    @discardableResult
    private func beginTurn() -> String {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)
        return requestId
    }

    private func emitProgress(
        _ requestId: String, taskId: String?, status: String,
        seq: Int?, text: String, category: String?
    ) {
        controller.markTaskState(
            requestId: requestId, taskId: taskId, status: status,
            progress: AgentTaskProgress(sequence: seq, text: text, category: category)
        )
    }

    private func armedDelays(_ delay: TimeInterval) -> [ProgressScheduledDelay] {
        scheduled.filter { abs($0.delay - delay) < 0.001 && !$0.isCancelled }
    }

    private func fireDelay(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = armedDelays(delay).first else {
            XCTFail("没有仍然武装着、延迟为 \(delay)s 的闭包", file: file, line: line)
            return
        }
        entry.fire()
    }

    /// 触发最新武装的节流窗口。
    private func fireThrottleWindow(file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = armedDelays(SessionController.progressUpdateMinIntervalSeconds).last else {
            XCTFail("节流窗口没有被武装", file: file, line: line)
            return
        }
        entry.fire()
    }

    private func fireThrottleWindowIfArmed() {
        armedDelays(SessionController.progressUpdateMinIntervalSeconds).last?.fire()
    }
}

@MainActor
private final class ProgressScheduledDelay {
    let delay: TimeInterval
    let fire: @MainActor () -> Void
    var isCancelled = false

    init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.fire = fire
    }
}

private final class ProgressCancellingToken: SessionDelayToken {
    private let entry: ProgressScheduledDelay

    init(entry: ProgressScheduledDelay) {
        self.entry = entry
    }

    func cancel() {
        MainActor.assumeIsolated { entry.isCancelled = true }
    }
}
