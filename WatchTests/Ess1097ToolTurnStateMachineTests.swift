import XCTest
@testable import WristAgent_Watch_App

/// ESS-1097：Watch 工具回合「思考 / 回答 / 聆听」状态机。
///
/// 本单要修的失败面（ESS-1095 真机证据）：工具任务仍在 running 时，回合被
/// 提前判成终态 → UI 回「正在听」→ 用户开口 → 新 request 把工具回合
/// supersede 掉 → 工具结果丢失。此前客户端判「这一轮完了没有」只有音频侧
/// 的两个输入（回合屏障 + 播放终局），对任务一无所知，只能依赖网关的有界
/// 空闲窗（ESS-1043 `toolCallWindowMs = 30_000`，按实测 8–16 s 工具耗时标定）
/// ——一次更慢的工具跑就把它跑穿。
///
/// 每条用例钉一条验收：
/// 1. `tool_call_pending` / task running 期间保持思考；
/// 2. 工具结果首帧起播 → 回答；
/// 3. task terminal + 回合屏障 + 播放终局都满足才回聆听；
/// 4. 取消 / 失败 / 超时是明确终态，不许卡在思考；
/// 5. 工具回合未终结时不得自动开新 generation，用户主动打断除外；
/// 6. 闸门有上界，永远解不开的任务不许把表钉死。
@MainActor
final class Ess1097ToolTurnStateMachineTests: XCTestCase {

    private var controller: SessionController!
    private var scheduled: [ScheduledDelay]!
    private var defaults: UserDefaults!
    private var startTurnCount = 0
    private var interruptCount = 0

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess1097ToolTurnTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        scheduled = []
        startTurnCount = 0
        interruptCount = 0

        controller.playHaptic = { _ in }
        // 令牌**真的**要能取消：本单的一半行为就是「哪个计时器让位给哪个」，
        // 用一个只记账不生效的假令牌去测，等于把被测行为测掉了。
        controller.scheduleDelay = { [weak self] delay, fire in
            let entry = ScheduledDelay(delay: delay, fire: fire)
            self?.scheduled.append(entry)
            return entry
        }
        controller.onBeginChannel = { "req-1" }
        controller.onTeardownChannel = {}
        controller.onCommitTurn = {}
        controller.onStartTurn = { [weak self] in
            self?.startTurnCount += 1
            return "req-next-\(self?.startTurnCount ?? 0)"
        }
        controller.onInterruptSpeaking = { [weak self] _ in
            self?.interruptCount += 1
            return true
        }
    }

    override func tearDown() {
        controller = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 验收 1/3：任务在跑时不许回聆听

    /// 核心回归：工具任务 running 时，音频侧已经收口（回合屏障 + 播完）也
    /// **不得**回聆听、不得开下一轮。这就是 ESS-1095 丢结果的那一步。
    func testTaskRunningHoldsThinkingAfterAnswerPlaybackFinished() {
        let requestId = startTurn()
        controller.markTaskState(
            requestId: requestId, taskId: "task-1", status: "running", terminal: false
        )
        controller.markAnswerStarted(requestId: requestId)   // 「我查一下」
        controller.markAnswerFinished(requestId: requestId)  // 音频侧收口

        XCTAssertEqual(controller.turnPhase, .thinking, "工具还在跑，必须保持正在思考")
        XCTAssertEqual(controller.toolTurnUIState, .thinking, "UI 由聚合驱动，与相位一致")
        XCTAssertEqual(startTurnCount, 0, "不得自动开新 generation")
        XCTAssertEqual(controller.activeTurnRequestId, requestId, "仍是同一轮")
    }

    /// 验收 3：task terminal 到达后（屏障 + 播完早已满足）才回聆听并开下一轮。
    func testTaskTerminalReleasesHeldTurnAndRelistens() {
        let requestId = startTurn()
        controller.markTaskState(
            requestId: requestId, taskId: "task-1", status: "running", terminal: false
        )
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)

        controller.markTaskState(
            requestId: requestId, taskId: "task-1", status: "completed", terminal: true
        )

        XCTAssertEqual(controller.turnPhase, .listening, "任务终结 + 音频收口 → 回聆听")
        XCTAssertEqual(startTurnCount, 1, "此时才允许开下一轮")
    }

    /// 多任务：只终结其中一个不许放行。
    func testPartialTaskTerminalKeepsTurnHeld() {
        let requestId = startTurn()
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)
        controller.markTaskState(requestId: requestId, taskId: "t2", status: "running", terminal: false)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        controller.markTaskState(requestId: requestId, taskId: "t1", status: "completed", terminal: true)
        XCTAssertEqual(controller.turnPhase, .thinking, "还有一个任务在跑")
        XCTAssertEqual(startTurnCount, 0)

        controller.markTaskState(requestId: requestId, taskId: "t2", status: "completed", terminal: true)
        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(startTurnCount, 1)
    }

    // MARK: - 验收 2：工具结果首帧起播 → 正在回答

    /// 两段音频：第一段播完退回思考（任务扣住），工具结果起播回到回答，
    /// 播完 + 任务终结才回聆听。全程同一轮。
    func testToolResultSegmentReturnsToAnsweringInSameTurn() {
        let requestId = startTurn()
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerInterim(requestId: requestId)     // 第一段播完，回合未完
        XCTAssertEqual(controller.turnPhase, .thinking)

        controller.markAnswerStarted(requestId: requestId)     // 工具结果首帧起播
        XCTAssertEqual(controller.turnPhase, .speaking, "工具结果起播 → 正在回答")
        XCTAssertEqual(controller.toolTurnUIState, .answering)
        XCTAssertEqual(controller.activeTurnRequestId, requestId, "仍是同一轮")

        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking, "任务未终结，仍不许回聆听")

        controller.markTaskState(requestId: requestId, taskId: "t1", status: "completed", terminal: true)
        XCTAssertEqual(controller.turnPhase, .listening)
    }

    /// 无任务的普通回合完全不受影响——工具闸门不得改变既有口径。
    func testPlainTurnWithoutTasksRelistensImmediately() {
        let requestId = startTurn()
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(startTurnCount, 1)
    }

    // MARK: - 验收 4：显式终态

    /// 用户挂断压过任务闸门：不许因为任务没终结就卡在思考页。
    func testUserHangupDuringHeldToolTurnLeavesThinking() {
        let requestId = startTurn()
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)

        controller.exitSession()

        XCTAssertEqual(controller.state, .hungup)
        XCTAssertEqual(controller.turnPhase, .idle, "显式终态不得停在思考")
        XCTAssertNotNil(controller.hungupSummary)
    }

    /// 服务端判本轮失败：同样压过闸门，进 P6，不等任何任务。
    func testServerTurnFailureDuringToolHoldEntersFailed() {
        let requestId = startTurn()
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)

        controller.markTurnFailed(requestId: requestId, errorCode: "ERR_X")

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.turnPhase, .idle)
    }

    /// 用户点球打断正在播的回答：不受任务闸门限制（验收 5 的例外条款）。
    func testUserInterruptDuringToolTurnStartsNextTurn() {
        let requestId = startTurn()
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)
        controller.markAnswerStarted(requestId: requestId)

        controller.interruptSpeaking()

        XCTAssertEqual(interruptCount, 1)
        XCTAssertEqual(startTurnCount, 1, "用户主动打断必须能开下一轮")
        XCTAssertEqual(controller.turnPhase, .listening)
    }

    // MARK: - 验收 6：上界（不许永久锁死）

    /// 任务永远不终结时，上界到点强制释放并收口——用户最多多等一个有界的
    /// 窗口，不会被钉死在「正在思考」直到自己退出。
    func testToolHoldDeadlineForcesRelease() {
        let requestId = startTurn()
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)

        fireLatestDelayNear(ToolTurnAggregate.maxTaskHoldSeconds)

        XCTAssertEqual(controller.turnPhase, .listening, "上界到点必须收口")
        XCTAssertEqual(startTurnCount, 1)
    }

    /// 任务在跑期间 45s 硬思考超时**让位**给任务上界：有明确证据说上游在
    /// 干活时，不该按「没有任何证据」的预算把回合判死。断言方式是真的去触发
    /// 那条 45s 闭包——它必须已经被取消，一次空转。
    func testThinkingHardTimeoutIsSupersededByToolHold() {
        let requestId = startTurn()
        let hardTimeout = latestLive(delay: SessionController.thinkingHardTimeoutSeconds)
        XCTAssertNotNil(hardTimeout, "提交后本应武装 45s 硬超时")

        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)

        XCTAssertEqual(hardTimeout?.isCancelled, true, "任务登记后 45s 硬超时必须被取消")
        XCTAssertNotNil(
            latestLive(delay: ToolTurnAggregate.maxTaskHoldSeconds),
            "并换成任务上界计时器"
        )
        // 真机上被取消的 Task 不会再跑；这里直接触发它，验证即便跑了也不改状态。
        hardTimeout?.fireIfLive()
        XCTAssertEqual(controller.state, .listening, "不得被让位掉的超时判死")
        XCTAssertEqual(controller.turnPhase, .thinking)
    }

    /// 任务终结但答案还没来：闸门解除后必须把这一轮交回 45s 硬超时，
    /// 不能留下一个没人计时的等待。
    func testTaskTerminalWithoutAnswerReArmsThinkingTimeout() {
        let requestId = startTurn()
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "running", terminal: false)
        controller.markTaskState(requestId: requestId, taskId: "t1", status: "failed", terminal: true)

        XCTAssertEqual(controller.turnPhase, .thinking, "答案还没来，仍在等")
        fireLatestDelayNear(SessionController.thinkingHardTimeoutSeconds)
        XCTAssertEqual(controller.state, .failed, "必须仍被超时捞回，不许无人计时")
    }

    // MARK: - 归属与隔离

    /// 上一轮的迟到任务事件不得影响当前回合。
    func testStaleTaskEventIsDropped() {
        let requestId = startTurn()
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)   // 开下一轮
        let nextRequestId = controller.activeTurnRequestId!
        XCTAssertNotEqual(nextRequestId, requestId)

        controller.markTaskState(
            requestId: requestId, taskId: "t-old", status: "running", terminal: false
        )
        controller.markTurnCommitted(requestId: nextRequestId)
        controller.markAnswerStarted(requestId: nextRequestId)
        controller.markAnswerFinished(requestId: nextRequestId)

        XCTAssertEqual(controller.turnPhase, .listening, "上一轮的任务不得扣住新一轮")
    }

    /// 退出会话后到达的任务事件不得复活任何东西。
    func testTaskEventAfterExitIsIgnored() {
        let requestId = startTurn()
        controller.exitSession()

        controller.markTaskState(
            requestId: requestId, taskId: "t1", status: "running", terminal: false
        )

        XCTAssertEqual(controller.turnPhase, .idle)
        XCTAssertEqual(startTurnCount, 0)
    }

    // MARK: - helpers

    /// 进入会话 → 通道就绪 → 提交，返回本轮 request_id。
    @discardableResult
    private func startTurn() -> String {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        return requestId
    }

    /// 取**最新一条未被取消**、延迟落在 `(delay - 1, delay]` 内的闭包。
    /// 上界计时器按「剩余预算」武装，会比常量少几毫秒，故用区间而非等值。
    private func latestLive(delay: TimeInterval) -> ScheduledDelay? {
        scheduled.last { !$0.isCancelled && $0.delay <= delay + 0.001 && $0.delay > delay - 1.0 }
    }

    private func fireLatestDelayNear(
        _ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let entry = latestLive(delay: delay) else {
            XCTFail(
                "没有接近 \(delay)s 的未取消闭包：\(scheduled.map(\.delay))",
                file: file, line: line
            )
            return
        }
        entry.fireIfLive()
    }
}

/// 测试用延迟令牌：记录延迟与闭包，`cancel()` 真的让它不再可触发。
@MainActor
private final class ScheduledDelay: SessionDelayToken {
    let delay: TimeInterval
    private let body: @MainActor () -> Void
    private(set) var isCancelled = false

    init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.body = fire
    }

    nonisolated func cancel() {
        MainActor.assumeIsolated { self.isCancelled = true }
    }

    func fireIfLive() {
        guard !isCancelled else { return }
        body()
    }
}
