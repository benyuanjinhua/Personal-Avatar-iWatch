import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-1097：工具回合聚合状态机测试。
///
/// 每条用例对应验收 1 里点名的一种时序，且**都是真机上真的会发生的顺序**，
/// 不是为了凑覆盖率造出来的组合：
///
/// - `idle 乱序`：ESS-990 已经用真机取证证明 `voice.state idle` 是段落级
///   播放状态、不是回合终态（每段 `audio.done` 后 0.14–0.54 ms 到达，10/10
///   回合其后又开新段）。本聚合的对应断言是**它根本不是输入**——没有任何
///   一个入口接收它，也没有任何一条路径能让它改变 `uiState`。
/// - `两段音频`：先「我查一下」再工具结果，中间不得回聆听。
/// - `task terminal 晚于 audio.done`：音频先收口、任务后终结，回聆听必须
///   等到两者都齐。
/// - `播放晚于连接关闭`：屏障先到、播放后完，同上。
/// - `取消 / 失败 / 超时`：显式终态压过一切，不许卡在思考。
final class ToolTurnGateTests: XCTestCase {

    private let t0: Int64 = 1_000

    // MARK: - 基线

    func testFreshTurnIsListeningAndMayStartNextTurn() {
        let aggregate = ToolTurnAggregate()
        XCTAssertEqual(aggregate.uiState, .listening)
        XCTAssertTrue(aggregate.mayAutoStartNextTurn)
        XCTAssertFalse(aggregate.isHoldingForTask)
    }

    func testCommittedTurnIsThinkingUntilAudioStarts() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        XCTAssertEqual(aggregate.uiState, .thinking)
        XCTAssertFalse(aggregate.mayAutoStartNextTurn, "提交后没答完就不许自动开下一轮")

        aggregate.noteAnswerAudioStarted()
        XCTAssertEqual(aggregate.uiState, .answering)
    }

    /// 无工具的普通回合：屏障 + 播完 → 回聆听。行为与 ESS-1097 之前完全一致，
    /// 这条用例存在的意义就是钉死「工具闸门不得改变普通回合的口径」。
    func testPlainTurnReleasesOnBarrierAndPlaybackEnd() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteAnswerAudioStarted()
        aggregate.noteTurnBarrierDone()
        aggregate.notePlaybackEnded()

        XCTAssertEqual(aggregate.uiState, .listening)
        XCTAssertTrue(aggregate.mayAutoStartNextTurn)
    }

    // MARK: - 工具任务闸门

    /// 验收 1/2：工具任务在跑时保持「正在思考」，且不许自动开下一轮——
    /// 这正是 ESS-1095 里丢掉工具结果的那一步。
    func testOutstandingTaskHoldsThinkingEvenAfterAudioSettled() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteTask(id: "task-1", terminal: false, atMs: t0)
        aggregate.noteAnswerAudioStarted()          // 「我查一下」
        aggregate.noteTurnBarrierDone()
        aggregate.notePlaybackEnded()

        XCTAssertTrue(aggregate.isHoldingForTask)
        XCTAssertEqual(aggregate.uiState, .thinking, "工具还在跑，不许显示正在听")
        XCTAssertFalse(aggregate.mayAutoStartNextTurn, "不许自动开新 generation")
    }

    /// 验收 3：task terminal **晚于** audio.done —— 两者都齐才回聆听。
    func testTaskTerminalAfterBarrierReleasesTurn() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteTask(id: "task-1", terminal: false, atMs: t0)
        aggregate.noteAnswerAudioStarted()
        aggregate.noteTurnBarrierDone()
        aggregate.notePlaybackEnded()
        XCTAssertEqual(aggregate.uiState, .thinking)

        aggregate.noteTask(id: "task-1", terminal: true, atMs: t0 + 8_000)

        XCTAssertFalse(aggregate.isHoldingForTask)
        XCTAssertEqual(aggregate.uiState, .listening)
        XCTAssertTrue(aggregate.mayAutoStartNextTurn)
    }

    /// 播放晚于屏障（连接早关、缓冲还在放）：屏障先到不足以回聆听。
    func testBarrierWithoutPlaybackEndDoesNotRelease() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteAnswerAudioStarted()
        aggregate.noteTurnBarrierDone()

        XCTAssertEqual(aggregate.uiState, .answering, "还在出声就还是正在回答")
        XCTAssertFalse(aggregate.mayAutoStartNextTurn)

        aggregate.notePlaybackEnded()
        XCTAssertEqual(aggregate.uiState, .listening)
    }

    /// 两段音频：第一段播完退回思考，第二段（工具结果）起播回到回答，
    /// 全程同一轮，中间一次都不许出现 `.listening`。
    func testTwoSegmentToolTurnNeverShowsListeningInTheMiddle() {
        var aggregate = ToolTurnAggregate()
        var observed: [ToolTurnUIState] = []
        func record() { observed.append(aggregate.uiState) }

        aggregate.noteCommitted(); record()
        aggregate.noteTask(id: "task-1", terminal: false, atMs: t0); record()
        aggregate.noteAnswerAudioStarted(); record()         // 第一段起播
        aggregate.notePlaybackEnded(); record()              // 第一段播完（段落屏障，非回合屏障）
        aggregate.noteAnswerAudioStarted(); record()         // 第二段（工具结果）起播
        aggregate.noteTurnBarrierDone(); record()
        aggregate.notePlaybackEnded(); record()

        XCTAssertFalse(
            observed.dropLast().contains(.listening),
            "工具回合中途出现『正在听』就是 ESS-1095 的失败面本身：\(observed)"
        )
        XCTAssertEqual(observed.last, .thinking, "任务未终结前，末态仍是思考")

        aggregate.noteTask(id: "task-1", terminal: true, atMs: t0 + 12_000)
        XCTAssertEqual(aggregate.uiState, .listening)
    }

    /// 多任务：任一任务未终结就继续扣住。真机上一次工具回合可以并发起多个
    /// 后台任务（查询 + 写日程），只放掉其中一个就回聆听是同一个 bug。
    func testMultipleTasksAllMustTerminate() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteTask(id: "task-1", terminal: false, atMs: t0)
        aggregate.noteTask(id: "task-2", terminal: false, atMs: t0 + 10)
        aggregate.noteTurnBarrierDone()
        aggregate.notePlaybackEnded()

        aggregate.noteTask(id: "task-1", terminal: true, atMs: t0 + 5_000)
        XCTAssertTrue(aggregate.isHoldingForTask, "还有一个任务在跑")
        XCTAssertEqual(aggregate.uiState, .thinking)

        aggregate.noteTask(id: "task-2", terminal: true, atMs: t0 + 6_000)
        XCTAssertEqual(aggregate.uiState, .listening)
    }

    /// 乱序 / 重复：终态先于登记到达、同一 id 重复登记，都不得让计数漂移。
    func testTaskEventsAreIdempotentAndOrderTolerant() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()

        XCTAssertFalse(
            aggregate.noteTask(id: "task-1", terminal: true, atMs: t0),
            "没登记过的任务直接报终态：无事发生，不得变成负计数"
        )
        XCTAssertFalse(aggregate.isHoldingForTask)

        XCTAssertTrue(aggregate.noteTask(id: "task-1", terminal: false, atMs: t0))
        XCTAssertFalse(
            aggregate.noteTask(id: "task-1", terminal: false, atMs: t0 + 1),
            "同一 id 重复登记不得再加一次"
        )
        XCTAssertEqual(aggregate.outstandingTaskIds, ["task-1"])

        XCTAssertTrue(aggregate.noteTask(id: "task-1", terminal: true, atMs: t0 + 2))
        XCTAssertFalse(
            aggregate.noteTask(id: "task-1", terminal: true, atMs: t0 + 3),
            "重复终态是幂等的"
        )
        XCTAssertTrue(aggregate.outstandingTaskIds.isEmpty)
    }

    func testEmptyTaskIdIsIgnored() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        XCTAssertFalse(aggregate.noteTask(id: "", terminal: false, atMs: t0))
        XCTAssertFalse(aggregate.isHoldingForTask)
    }

    // MARK: - 显式终态（不许卡在思考）

    func testCancelBeatsOutstandingTask() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteTask(id: "task-1", terminal: false, atMs: t0)

        aggregate.noteTerminal(.cancelled)

        XCTAssertEqual(aggregate.uiState, .terminal)
        XCTAssertFalse(aggregate.isHoldingForTask, "显式终态清空任务闸门")
        XCTAssertTrue(aggregate.mayAutoStartNextTurn, "取消后允许开下一轮")
    }

    func testFailureAndTimeoutAreTerminalAndFirstOneWins() {
        for kind in [ToolTurnTerminal.failed, .timedOut] {
            var aggregate = ToolTurnAggregate()
            aggregate.noteCommitted()
            aggregate.noteTask(id: "task-1", terminal: false, atMs: t0)
            XCTAssertTrue(aggregate.noteTerminal(kind))
            XCTAssertEqual(aggregate.uiState, .terminal)
            XCTAssertEqual(aggregate.terminal, kind)

            XCTAssertFalse(aggregate.noteTerminal(.cancelled), "先到的终态胜出")
            XCTAssertEqual(aggregate.terminal, kind)
        }
    }

    func testTerminalTurnIgnoresLateTaskEvents() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteTerminal(.failed)

        XCTAssertFalse(
            aggregate.noteTask(id: "task-late", terminal: false, atMs: t0),
            "已终态的回合不得被迟到的任务事件重新扣住"
        )
        XCTAssertEqual(aggregate.uiState, .terminal)
    }

    // MARK: - 上界（不许永久锁死）

    func testForcedReleaseUnblocksTurnAndLeavesEvidence() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        aggregate.noteTask(id: "task-1", terminal: false, atMs: t0)
        aggregate.noteTurnBarrierDone()
        aggregate.notePlaybackEnded()
        XCTAssertFalse(aggregate.mayAutoStartNextTurn)

        XCTAssertTrue(aggregate.forceReleaseTasks(reason: "tool_hold_deadline"))

        XCTAssertTrue(aggregate.mayAutoStartNextTurn)
        XCTAssertEqual(aggregate.uiState, .listening)
        XCTAssertTrue(
            aggregate.evidence.contains("forced_release=tool_hold_deadline"),
            "强制释放必须留证，否则真机上分不清『任务真的完了』与『我们等腻了』"
        )
        XCTAssertFalse(aggregate.forceReleaseTasks(reason: "again"), "没有任务可释放时是 no-op")
    }

    func testTaskHoldElapsedMeasuresFromFirstTask() {
        var aggregate = ToolTurnAggregate()
        aggregate.noteCommitted()
        XCTAssertNil(aggregate.taskHoldElapsedMs(nowMs: t0), "没有任务证据就没有计时起点")

        aggregate.noteTask(id: "task-1", terminal: false, atMs: t0)
        aggregate.noteTask(id: "task-2", terminal: false, atMs: t0 + 5_000)

        XCTAssertEqual(
            aggregate.taskHoldElapsedMs(nowMs: t0 + 9_000), 9_000,
            "起点是**第一个**任务，不是最后一个——否则任务串行到来即可无限续期"
        )
    }

    /// 上界必须大于网关的工具窗（ESS-1043 `toolCallWindowMs = 30_000`）：
    /// 客户端这条闸门只在网关窗口已经放过、而任务仍在跑时才起作用，取值
    /// 小于等于 30 s 就等于没有。
    func testHoldBudgetExceedsGatewayToolWindow() {
        XCTAssertGreaterThan(ToolTurnAggregate.maxTaskHoldSeconds, 30)
        XCTAssertLessThanOrEqual(
            ToolTurnAggregate.maxTaskHoldSeconds, 120,
            "上界也不能大到让用户觉得表死了"
        )
    }
}
