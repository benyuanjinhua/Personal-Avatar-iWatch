import XCTest
@testable import WristAgent_Watch_App

/// ESS-1111：Codex 长任务的**答案增量**在会话层的展示规则。
///
/// 体验基线（ESS-1109 真机取证）：任务 13:46:16.730 开始、24.020 s 完成，
/// 首个有内容的进展在 9.48 s；Watch 在任务仍 running 时断开，最终答案完全
/// 无法回传。上游 ESS-1110 之后，答案 token 一产生就以 `task.state` 的
/// `answer_delta` / `answer_seq` 流下来——本套件钉的是：它必须**立刻**显示，
/// 按序号去重保序，回合级隔离，且不改变任何相位与闸门判定。
///
/// 纯逻辑那部分（装配、上限、两跳线格）在 `Tests/Ess1111AnswerStreamTests.swift`。
/// 计时器经 `scheduleDelay` 接缝替换为手动触发，零睡眠。
@MainActor
final class Ess1111AnswerStreamDisplayTests: XCTestCase {

    private var controller: SessionController!
    private var scheduled: [AnswerScheduledDelay]!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess1111AnswerStreamTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        scheduled = []
        controller.playHaptic = { _ in }
        controller.scheduleDelay = { [weak self] delay, fire in
            let entry = AnswerScheduledDelay(delay: delay, fire: fire)
            self?.scheduled.append(entry)
            return AnswerCancellingToken(entry: entry)
        }
        controller.onBeginChannel = { "req-answer-1" }
        controller.onTeardownChannel = {}
        controller.onStartTurn = { "req-next" }
    }

    override func tearDown() {
        controller = nil
        defaults = nil
        super.tearDown()
    }

    /// 首个增量到达即显示——不等整段答案聚合，也不等音频起播。
    func testFirstAnswerDeltaIsShownImmediately() {
        let requestId = beginTurn()
        XCTAssertNil(controller.streamingAnswerText)

        emitAnswer(requestId, seq: 1, delta: "杭州")

        XCTAssertEqual(controller.streamingAnswerText, "杭州")
        XCTAssertEqual(controller.turnPhase, .thinking, "答案增量不改变相位")
    }

    /// 连续增量按序追加，且**不经节流**：进展是覆盖同一行，答案是逐段追加，
    /// 压掉一帧就是少一段话。
    func testSubsequentDeltasAppendWithoutThrottling() {
        let requestId = beginTurn()
        emitAnswer(requestId, seq: 1, delta: "杭州")
        emitAnswer(requestId, seq: 2, delta: "今天")
        emitAnswer(requestId, seq: 3, delta: "晴")
        XCTAssertEqual(controller.streamingAnswerText, "杭州今天晴")
    }

    /// 重复与乱序都必须被丢掉——WCSession 那一跳不保证顺序。
    func testDuplicateAndOutOfOrderDeltasAreDropped() {
        let requestId = beginTurn()
        emitAnswer(requestId, seq: 1, delta: "杭州")
        emitAnswer(requestId, seq: 2, delta: "今天")
        emitAnswer(requestId, seq: 2, delta: "今天")   // 重复
        emitAnswer(requestId, seq: 1, delta: "杭州")   // 迟到
        emitAnswer(requestId, seq: 3, delta: "晴")
        XCTAssertEqual(controller.streamingAnswerText, "杭州今天晴")
        XCTAssertEqual(controller.answerStream.droppedCount, 2)
    }

    /// 上一轮的答案不得挂到新一轮头上（旧 generation 不污染新回合）。
    func testAnswerIsResetOnNewTurn() {
        let requestId = beginTurn()
        emitAnswer(requestId, seq: 1, delta: "杭州今天晴")
        XCTAssertNotNil(controller.streamingAnswerText)

        controller.markAnswerFinished(requestId: requestId, success: true, reason: "test")
        fireRelistenDelays()

        XCTAssertNil(controller.streamingAnswerText, "换回合必须清空上一轮的答案")
        XCTAssertNil(controller.answerStream.latestSequence)
    }

    /// 别的回合的迟到帧根本走不进来（归属闸门在 `acceptsTurnEvent`）。
    func testStaleRequestAnswerIsRejected() {
        let requestId = beginTurn()
        emitAnswer(requestId, seq: 1, delta: "杭州")
        emitAnswer("req-someone-else", seq: 2, delta: "深圳")
        XCTAssertEqual(controller.streamingAnswerText, "杭州")
    }

    /// 答案增量与进展文字互不干扰：一个是「系统在做什么」，一个是答案本身。
    func testAnswerAndProgressAreIndependentSurfaces() {
        let requestId = beginTurn()
        controller.markTaskState(
            requestId: requestId, taskId: "work_codex", status: "running",
            progress: AgentTaskProgress(sequence: 1, text: "正在查询相关信息", category: "search")
        )
        emitAnswer(requestId, seq: 1, delta: "杭州")

        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
        XCTAssertEqual(controller.streamingAnswerText, "杭州")
    }

    /// 同一帧同时带进展与答案时两条都被采纳——上游允许合并投递。
    func testSingleFrameCarryingBothIsFullyApplied() {
        let requestId = beginTurn()
        controller.markTaskState(
            requestId: requestId, taskId: "work_codex", status: "running",
            progress: AgentTaskProgress(sequence: 1, text: "正在整理结果", category: "text"),
            answer: AgentTaskAnswerDelta(sequence: 1, delta: "杭州")
        )
        XCTAssertEqual(controller.toolProcessingText, "正在整理结果")
        XCTAssertEqual(controller.streamingAnswerText, "杭州")
    }

    /// 24 s 长任务的完整形状：进展持续跳动、答案随后流出、任务终态到达，
    /// 期间相位一直是 thinking，绝不提前回到聆听。
    func testLongTaskKeepsThinkingUntilTerminal() {
        let requestId = beginTurn()
        for seq in 1...12 {
            controller.markTaskState(
                requestId: requestId, taskId: "work_codex", status: "running",
                progress: AgentTaskProgress(sequence: seq, text: "正在查询相关信息", category: "search")
            )
            fireThrottleWindowIfArmed()
        }
        XCTAssertEqual(controller.turnPhase, .thinking)

        for seq in 1...4 {
            emitAnswer(requestId, seq: seq, delta: "段\(seq)")
        }
        XCTAssertEqual(controller.streamingAnswerText, "段1段2段3段4")
        XCTAssertEqual(controller.turnPhase, .thinking,
                       "答案文本到达 ≠ 回合结束：终态仍由 task terminal + 播放 barrier 裁决")

        controller.markTaskState(requestId: requestId, taskId: "work_codex", status: "completed")
        XCTAssertEqual(controller.turnPhase, .thinking, "任务完成后仍要等回答播完")
    }

    // MARK: - helpers

    private func beginTurn() -> String {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)
        return requestId
    }

    private func emitAnswer(_ requestId: String, seq: Int?, delta: String) {
        controller.markTaskState(
            requestId: requestId, taskId: "work_codex", status: "running",
            answer: AgentTaskAnswerDelta(sequence: seq, delta: delta)
        )
    }

    private func armedDelays(_ delay: TimeInterval) -> [AnswerScheduledDelay] {
        scheduled.filter { abs($0.delay - delay) < 0.001 && !$0.isCancelled }
    }

    private func fireThrottleWindowIfArmed() {
        armedDelays(SessionController.progressUpdateMinIntervalSeconds).last?.fire()
    }

    /// 回答播完后回到聆听所需的那些延迟，逐个触发到换出新回合为止。
    private func fireRelistenDelays() {
        for entry in scheduled where !entry.isCancelled {
            entry.fire()
        }
    }
}

@MainActor
private final class AnswerScheduledDelay {
    let delay: TimeInterval
    let fire: @MainActor () -> Void
    var isCancelled = false

    init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.fire = fire
    }
}

private final class AnswerCancellingToken: SessionDelayToken {
    private let entry: AnswerScheduledDelay

    init(entry: AnswerScheduledDelay) {
        self.entry = entry
    }

    func cancel() {
        MainActor.assumeIsolated { entry.isCancelled = true }
    }
}
