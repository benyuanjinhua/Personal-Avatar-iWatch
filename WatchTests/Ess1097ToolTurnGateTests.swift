import XCTest
@testable import WristAgent_Watch_App

/// ESS-1097：会话层的工具回合门禁。
///
/// 真机故障（ESS-1095，`request_id=01a02e3e-3225-7da8-a6ca-7b40e4695b09`）：
/// `tool_call_pending` 之后上游发 `voice.state=idle`，网关据此收回合，客户端把
/// 回合终态当成「答完了」→ 回「正在听」→ 自动开下一轮 → 新 generation 把仍在
/// `running` 的工具任务 supersede 掉，工具答案永远送不到用户耳朵里。
///
/// 本套件钉住的是修好之后的行为，全部落在**用户能看到的那一面**
/// （`turnPhase`）和**会不会开新 generation**（`onStartTurn` 调用次数）上。
///
/// 计时器经 `scheduleDelay` 接缝替换为手动触发，零睡眠。
@MainActor
final class Ess1097ToolTurnGateTests: XCTestCase {

    private var controller: SessionController!
    /// 已排入的延迟闭包。**必须如实模拟取消**——本套件要断言的正是「工具在跑时
    /// 45s 硬超时被撤掉了」，一个只记账不响应 cancel 的假令牌根本区分不了
    /// 「还挂着」与「已撤掉」，那样的断言等于没测。
    private var scheduled: [ScheduledDelay]!
    private var startTurnCount = 0
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess1097ToolTurnGateTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        scheduled = []
        startTurnCount = 0
        controller.playHaptic = { _ in }
        controller.scheduleDelay = { [weak self] delay, fire in
            let entry = ScheduledDelay(delay: delay, fire: fire)
            self?.scheduled.append(entry)
            return CancellingDelayToken(entry: entry)
        }
        controller.onBeginChannel = { "req-tool-1" }
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

    // MARK: - 验收 2：等待工具结果时不得提前跳回「正在听」

    /// 工具任务在跑时，回合屏障 + 播放结束一起到达也**不许**回聆听。
    /// 这一条就是真机上「个人文章查询 / 飞书日程创建」等待期间的行为契约。
    func testAnswerFinishedWhileTaskRunningDoesNotRelisten() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: nil, status: "tool_call_pending")
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markAnswerStarted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .speaking, "「我正在查询…」这一段在播")

        // 上游 idle → 网关收回合 → 客户端收到「答完了」。
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .thinking, "任务还在跑，必须留在思考态")
        XCTAssertEqual(startTurnCount, 0, "禁止自动开新 generation")
        XCTAssertEqual(controller.activeTurnRequestId, requestId, "仍是同一轮")
        XCTAssertFalse(controller.toolTurn.isClosed)
        XCTAssertTrue(controller.toolTurn.blocksAutomaticNextTurn)
    }

    /// 验收 3：任务终态 + 回合屏障 + 播放结束都满足后才恢复聆听。
    func testRelistensOnlyAfterTaskTerminalAndPlaybackEnd() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(startTurnCount, 0)

        // 工具跑完，真答案这一段来了。
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "completed")
        XCTAssertEqual(controller.turnPhase, .thinking, "任务终态本身不是回答")
        XCTAssertEqual(startTurnCount, 0, "答案还没播完，仍不许开下一轮")

        controller.markAnswerStarted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .speaking)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .listening, "三面齐了才回聆听")
        XCTAssertEqual(startTurnCount, 1)
    }

    /// 任务终态**晚于**回合屏障到达（真机观测到的乱序）。
    func testTaskTerminalArrivingAfterTurnCloseStillGatesThenReleases() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "queued")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(startTurnCount, 0)

        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "completed")
        // 任务终态到达时回合已经答完过一次：屏障与播放都已入账，聚合体收口。
        XCTAssertTrue(controller.toolTurn.isClosed)
        XCTAssertFalse(controller.toolTurn.blocksAutomaticNextTurn)
    }

    /// 未知任务状态按非终态处理——猜成终态就等于把 bug 装回去。
    func testUnknownTaskStatusKeepsTheGateClosed() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "reticulating")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertEqual(startTurnCount, 0)
    }

    // MARK: - ESS-1098 复审阻断 1：pending + task 组合的端到端契约

    /// **回归钉**：真实工具回合的完整成功链
    /// `pending → running → audio.done/播完 → completed`。
    /// ESS-1098 复审指出原实现里闩锁永不解除，这条链会一路挂到 180s 判失败。
    func testPendingThenRunningThenAudioSettledThenTerminalRelistens() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: nil, status: "tool_call_pending")
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(startTurnCount, 0, "任务还在跑，仍不许开下一轮")
        XCTAssertFalse(controller.toolTurn.toolCallPending, "任务号出现后闩锁必须已解除")

        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "completed")

        XCTAssertTrue(controller.toolTurn.isClosed, "成功的工具回合必须收口，不能挂到超时")
        XCTAssertFalse(controller.toolTurn.blocksAutomaticNextTurn)
    }

    /// 另一种乱序：`pending → running → completed → audio.done/播完`。
    /// 任务先全部终结，音频后落定，同样必须恢复聆听并开下一轮。
    func testPendingThenFullTaskLifecycleThenAudioSettledRelistens() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: nil, status: "tool_call_pending")
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "completed")
        XCTAssertEqual(controller.turnPhase, .thinking, "答案还没播，先别喊听")

        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .listening, "三面齐了才回聆听")
        XCTAssertEqual(startTurnCount, 1)
    }

    /// 闩锁**独自**存在（从未出现任务号）时不得被音频落定解除——
    /// 那正是 ESS-1095 的故障形态。只有显式 resolved 帧能解。
    func testLatchWithoutTaskIsOnlyReleasedByExplicitResolvedFrame() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: nil, status: "tool_call_pending")
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking, "任务帧还没到，此刻收口就是 ESS-1095 复发")
        XCTAssertEqual(startTurnCount, 0)

        controller.markTaskState(requestId: requestId, taskId: nil, status: "tool_call_resolved")

        XCTAssertTrue(controller.toolTurn.isClosed)
        XCTAssertFalse(controller.toolTurn.blocksAutomaticNextTurn)
    }

    // MARK: - 无工具信号的普通回合：行为与本单之前**逐字节相同**

    func testPlainTurnWithoutToolEvidenceRelistensAsBefore() {
        let requestId = beginTurn()
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(startTurnCount, 1, "普通回合照旧自动开下一轮")
        XCTAssertFalse(controller.toolTurn.hasToolEvidence)
    }

    // MARK: - 用户主动打断是唯一豁免

    func testUserBargeInStillOpensNextTurnWhileTaskRuns() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markAnswerStarted(requestId: requestId)
        controller.onInterruptSpeaking = { _ in true }

        controller.interruptSpeaking()

        XCTAssertEqual(startTurnCount, 1, "用户主动打断是明确终态，门禁让路")
        XCTAssertEqual(controller.turnPhase, .listening)
    }

    // MARK: - 有界性：不得永久锁死在「正在思考」

    /// 工具在跑时 45s 硬超时让位（否则正常的长工具回合会被误杀），
    /// 但绝对上限照样到点收口。
    func testToolWorkDefersThe45sHardTimeoutButKeepsAnAbsoluteCap() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")

        XCTAssertTrue(
            armedDelays(SessionController.thinkingHardTimeoutSeconds).isEmpty,
            "工具在跑时 45s 硬超时必须已被撤掉，否则正常的长工具回合会被误杀"
        )
        XCTAssertEqual(
            armedDelays(SessionController.toolTurnHardTimeoutSeconds).count, 1,
            "改由绝对上限承担有界性"
        )
        fireDelay(SessionController.toolTurnHardTimeoutSeconds)

        XCTAssertEqual(controller.state, .failed, "绝对上限到点必须给明确终态")
        XCTAssertNotNil(controller.failedReason)
        XCTAssertTrue(controller.failedRetryable)
    }

    /// 绝对上限**一轮只武装一次**：`task.progress` 刷新不得顺延，
    /// 否则「不能永久锁死」就是空话。
    func testToolDeadlineIsArmedOnlyOncePerTurn() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markTaskState(requestId: requestId, taskId: "task-78", status: "queued")

        let armings = scheduled.filter { abs($0.delay - SessionController.toolTurnHardTimeoutSeconds) < 0.001 }
        XCTAssertEqual(armings.count, 1, "绝对上限只武装一次，task.progress 不得顺延")
    }

    /// 工具活干完、答案还没播：45s「等回答」预算重新接上，同样有界。
    func testHardTimeoutIsRestoredOnceToolWorkTerminates() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "completed")

        fireLatestDelay(SessionController.thinkingHardTimeoutSeconds)
        XCTAssertEqual(controller.state, .failed, "工具结束后仍需有界等待")
    }

    // MARK: - 通道失败：放弃等待，但不得卡死

    func testChannelFailureReleasesTheGateInsteadOfHangingInThinking() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")

        controller.markChannelFailed(.channelEvent)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.toolTurn.outstandingTasks.isEmpty,
                      "通道死了就不会再有任务终态，继续等 = 永久卡死")
    }

    // MARK: - 归属闸门

    /// 上一轮的迟到 `task.state` 不得把当前回合按在思考态上。
    func testStaleTaskStateFromPriorTurnIsRejected() {
        let requestId = beginTurn()
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(startTurnCount, 1)
        let nextRequestId = controller.activeTurnRequestId

        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "running")

        XCTAssertEqual(controller.activeTurnRequestId, nextRequestId)
        XCTAssertFalse(controller.toolTurn.hasToolEvidence, "迟到事件不得入账当前轮")
    }

    /// 聚合体是回合级的：新一轮开始必须清零。
    func testAggregateResetsPerTurn() {
        let requestId = beginTurn()
        controller.markTaskState(requestId: requestId, taskId: "task-77", status: "completed")
        XCTAssertTrue(controller.toolTurn.hasToolEvidence)

        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(startTurnCount, 1)
        XCTAssertFalse(controller.toolTurn.hasToolEvidence, "新一轮不背上一轮的账")
        XCTAssertTrue(controller.toolTurn.seenTasks.isEmpty)
    }

    // MARK: - helpers

    /// 进会话 → 通道就绪 → 本轮已提交（thinking）。返回本轮 request_id。
    @discardableResult
    private func beginTurn() -> String {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)
        return requestId
    }

    /// 仍然武装着（未被取消）的同延迟闭包。
    private func armedDelays(_ delay: TimeInterval) -> [ScheduledDelay] {
        scheduled.filter { abs($0.delay - delay) < 0.001 && !$0.isCancelled }
    }

    /// 触发**仍然武装着**的最早一条。已取消的闭包在生产里根本不会响，
    /// 测试里也不许响。
    private func fireDelay(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = armedDelays(delay).first else {
            XCTFail("没有仍然武装着、延迟为 \(delay)s 的闭包", file: file, line: line)
            return
        }
        entry.fire()
    }

    private func fireLatestDelay(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = armedDelays(delay).last else {
            XCTFail("没有仍然武装着、延迟为 \(delay)s 的闭包", file: file, line: line)
            return
        }
        entry.fire()
    }
}

/// 一条被排入的延迟闭包及其取消状态。
@MainActor
private final class ScheduledDelay {
    let delay: TimeInterval
    let fire: @MainActor () -> Void
    var isCancelled = false

    init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.fire = fire
    }
}

/// 如实响应 `cancel()` 的测试令牌。
///
/// `SessionDelayToken.cancel()` 是非隔离的，而被取消的记账体是 `@MainActor`
/// 的——生产路径上取消**只发生在主 actor**（SessionController 通体
/// `@MainActor`），所以这里用 `assumeIsolated` 把这条事实说清楚，而不是把
/// 记账体降级成 `nonisolated(unsafe)` 把并发问题藏起来。
private final class CancellingDelayToken: SessionDelayToken {
    private let entry: ScheduledDelay

    init(entry: ScheduledDelay) {
        self.entry = entry
    }

    func cancel() {
        MainActor.assumeIsolated { entry.isCancelled = true }
    }
}
