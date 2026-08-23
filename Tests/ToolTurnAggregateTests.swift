import XCTest
@testable import WristAgentCore

/// ESS-1097 验收 1：状态机测试覆盖 idle 乱序、两段音频、task terminal 晚于
/// audio.done、播放晚于连接关闭、取消/失败/超时。
///
/// 每个用例都以「用户看到什么」为断言对象（`phase`），而不是内部字段——
/// 本 issue 的故障现象就是 UI 相位说了谎，断言必须落在同一个面上。
final class ToolTurnAggregateTests: XCTestCase {

    // MARK: - 主链路：工具回合全过程

    /// 个人文章查询这类工具回合的完整时间线。
    /// 提交 → 「我正在查询…」这一段 → 工具跑 → 工具结果音频 → 回合终态。
    /// 全程 UI 不得提前回到「正在听」。
    func testToolTurnStaysThinkingUntilTaskAndPlaybackBothSettle() {
        var agg = ToolTurnAggregate()
        XCTAssertEqual(agg.phase, .thinking, "刚提交就应该是思考态")

        // 模型先说「我正在查询…」。
        agg.apply(.playbackStarted)
        XCTAssertEqual(agg.phase, .answering)
        agg.apply(.playbackSegmentEnded)
        XCTAssertEqual(agg.phase, .thinking, "段落播完不是回合结束，必须回到思考")

        // 工具调用挂起 + 任务真的跑起来。
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .accepted))
        agg.apply(.taskState(taskId: "t1", status: .running))
        XCTAssertEqual(agg.phase, .thinking)
        XCTAssertFalse(agg.isClosed)
        XCTAssertTrue(agg.holdReasons.contains(.taskOutstanding))

        // 工具结果音频到达并起播 → 正在回答。
        agg.apply(.toolCallResolved)
        agg.apply(.playbackStarted)
        XCTAssertEqual(agg.phase, .answering, "工具结果首帧起播 = 正在回答")
        XCTAssertFalse(agg.isClosed, "任务还没终结，回合不许收口")

        // 任务终态 + 回合屏障 + 播放结束，三面齐了才回聆听。
        agg.apply(.taskState(taskId: "t1", status: .completed))
        XCTAssertEqual(agg.phase, .answering, "还在播，先别喊听")
        agg.apply(.audioDoneBarrier)
        XCTAssertEqual(agg.phase, .answering)
        XCTAssertFalse(agg.allowsAutomaticNextTurn)
        agg.apply(.playbackEnded)
        XCTAssertEqual(agg.phase, .listening)
        XCTAssertTrue(agg.allowsAutomaticNextTurn)
        XCTAssertTrue(agg.holdReasons.isEmpty)
    }

    // MARK: - idle 乱序（本 issue 的直接故障面）

    /// 上游在 `tool_call_pending` 之后就发 `voice.state=idle`，网关据此把回合
    /// 屏障提前落定。客户端**不得**因此回「正在听」——这正是 ESS-1095 观测到的
    /// 「误判系统停止思考 + 新会话覆盖工具回合」的入口。
    func testAudioDoneBeforeTaskTerminalDoesNotCloseTurn() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "task-01a02e3e", status: .running))

        // 上游 idle → 网关下发回合屏障（乱序：早于任务终态）。
        agg.apply(.audioDoneBarrier)

        XCTAssertEqual(agg.phase, .thinking, "任务仍在 running，屏障先到不算答完")
        XCTAssertFalse(agg.isClosed)
        XCTAssertTrue(agg.hasToolEvidence)
        XCTAssertTrue(agg.blocksAutomaticNextTurn, "禁止自动开新 generation")
        XCTAssertFalse(agg.allowsAutomaticNextTurn)
        // ESS-1098 整改后：任务号已经出现，闩锁交棒给任务集合，
        // 把关的是 `task_outstanding` 这一条——门禁强度不变。
        XCTAssertFalse(agg.toolCallPending)
        XCTAssertEqual(agg.holdReasons, [.taskOutstanding])
    }

    /// task terminal **晚于** audio.done：终态一到，回合当场收口。
    func testTaskTerminalAfterAudioDoneClosesTurn() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.audioDoneBarrier)
        agg.apply(.toolCallResolved)
        XCTAssertEqual(agg.phase, .thinking)

        agg.apply(.taskState(taskId: "t1", status: .completed))
        XCTAssertEqual(agg.phase, .listening)
        XCTAssertTrue(agg.allowsAutomaticNextTurn)
    }

    /// 反向乱序：任务先终结，屏障后到。同样只有两面都齐才收口。
    func testTaskTerminalBeforeAudioDoneStillWaitsForBarrier() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.taskState(taskId: "t1", status: .completed))
        XCTAssertEqual(agg.phase, .thinking)
        XCTAssertEqual(agg.holdReasons, [.awaitingAudioDone])

        agg.apply(.audioDoneBarrier)
        XCTAssertEqual(agg.phase, .listening)
    }

    /// 同一 taskId 的重复非终态事件不得累加——否则一次终态减不回 0。
    func testDuplicateRunningEventsAreIdempotent() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: .queued))
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.taskState(taskId: "t1", status: .running))
        XCTAssertEqual(agg.outstandingTasks.count, 1)

        agg.apply(.taskState(taskId: "t1", status: .completed))
        agg.apply(.audioDoneBarrier)
        XCTAssertTrue(agg.outstandingTasks.isEmpty)
        XCTAssertEqual(agg.phase, .listening)
    }

    /// 多任务：任一任务未终结都继续思考。
    func testMultipleTasksAllMustTerminate() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "a", status: .running))
        agg.apply(.taskState(taskId: "b", status: .queued))
        agg.apply(.audioDoneBarrier)
        agg.apply(.taskState(taskId: "a", status: .completed))
        XCTAssertEqual(agg.phase, .thinking, "b 还没终结")

        agg.apply(.taskState(taskId: "b", status: .failed))
        XCTAssertEqual(agg.phase, .listening, "任务失败也是终态，回合可以收口")
        XCTAssertEqual(agg.seenTasks, ["a", "b"])
    }

    /// 不认识的 task 状态一律按非终态处理——把没见过的状态当终态，
    /// 等于回到本 issue 要修的 bug。
    func testUnknownTaskStatusIsTreatedAsNonTerminal() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: ToolTaskStatus(rawValue: "reticulating_splines")))
        agg.apply(.audioDoneBarrier)
        XCTAssertEqual(agg.phase, .thinking)
        XCTAssertEqual(agg.holdReasons, [.taskOutstanding])
    }

    func testTaskStatusParsingCoversUpstreamSpellings() {
        XCTAssertEqual(ToolTaskStatus(rawValue: "RUNNING"), .running)
        XCTAssertEqual(ToolTaskStatus(rawValue: "in_progress"), .running)
        XCTAssertEqual(ToolTaskStatus(rawValue: "succeeded"), .completed)
        XCTAssertEqual(ToolTaskStatus(rawValue: "canceled"), .cancelled)
        XCTAssertEqual(ToolTaskStatus(rawValue: "timed_out"), .timedOut)
        XCTAssertFalse(ToolTaskStatus(rawValue: "queued").isTerminal)
        XCTAssertTrue(ToolTaskStatus(rawValue: "failed").isTerminal)
    }

    // MARK: - ESS-1098 复审阻断 1：闩锁解除契约

    /// **回归钉**：`pending → running → completed → audio.done → 播完` 是工具回合
    /// 最常见的**成功**时间线。ESS-1098 复审发现闩锁在这条路上永远解不开，
    /// 一个答对了的回合会一路挂到 180s 绝对上限被报成超时。
    func testPendingLatchIsReleasedByTaskIdSoSuccessfulToolTurnCloses() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        XCTAssertEqual(agg.holdReasons, [.toolCallPending, .awaitingAudioDone])

        // 任务号一出现，闩锁完成使命，裁决权交给任务集合。
        agg.apply(.taskState(taskId: "t1", status: .running))
        XCTAssertFalse(agg.toolCallPending, "任务号出现后闩锁必须解除")
        XCTAssertEqual(agg.holdReasons, [.taskOutstanding, .awaitingAudioDone])

        agg.apply(.taskState(taskId: "t1", status: .completed))
        agg.apply(.audioDoneBarrier)
        agg.apply(.playbackEnded)
        XCTAssertEqual(agg.phase, .listening, "成功的工具回合必须收口，不能挂到超时")
        XCTAssertTrue(agg.allowsAutomaticNextTurn)
    }

    /// 同一组合的另一种乱序：屏障与播放先落定，任务生命周期后到。
    func testPendingLatchReleaseIsOrderIndependent() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.audioDoneBarrier)
        agg.apply(.playbackStarted)
        agg.apply(.playbackEnded)
        XCTAssertEqual(agg.phase, .thinking, "闩锁还在，音频落定不算答完")
        XCTAssertEqual(agg.holdReasons, [.toolCallPending])

        agg.apply(.taskState(taskId: "t1", status: .running))
        XCTAssertEqual(agg.holdReasons, [.taskOutstanding], "闩锁解除，改由任务把关")
        agg.apply(.taskState(taskId: "t1", status: .completed))
        XCTAssertEqual(agg.phase, .listening)
    }

    /// 闩锁解除**不得**顺手把 `hasToolEvidence` 一起抹掉——门禁靠它区分
    /// 工具回合与普通回合。`seenTasks` 是证据的持久记账。
    func testEvidenceSurvivesLatchRelease() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .running))
        XCTAssertFalse(agg.toolCallPending)
        XCTAssertTrue(agg.hasToolEvidence, "闩锁解了，但这仍然是一个工具回合")
        XCTAssertTrue(agg.blocksAutomaticNextTurn)
    }

    /// 「只有闩锁、从未出现任务号」的回合，在 `tool_call_resolved` 之后**仍然**
    /// 是工具回合。证据读 `toolCallPending` 会在这里归 false，于是收口路径不再
    /// 认领这一轮，UI 停在「正在思考」等超时——所以证据必须是历史事实。
    func testEvidenceSurvivesResolvedWithoutAnyTask() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.toolCallResolved)
        XCTAssertFalse(agg.toolCallPending)
        XCTAssertTrue(agg.didObserveToolCall)
        XCTAssertTrue(agg.hasToolEvidence, "解除的是闩锁，不是「这是工具回合」这个事实")
        XCTAssertTrue(agg.seenTasks.isEmpty)
    }

    /// 同一回合内的第二次工具调用：闩锁可以再次落下，并再次被新任务号解除。
    func testSecondToolCallInSameTurnRelatchesAndReleases() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.taskState(taskId: "t1", status: .completed))
        XCTAssertEqual(agg.holdReasons, [.awaitingAudioDone])

        agg.apply(.toolCallPending)
        XCTAssertEqual(agg.holdReasons, [.toolCallPending, .awaitingAudioDone], "第二次工具调用重新落闩")
        agg.apply(.taskState(taskId: "t2", status: .running))
        XCTAssertFalse(agg.toolCallPending)
        agg.apply(.taskState(taskId: "t2", status: .completed))
        agg.apply(.audioDoneBarrier)
        XCTAssertEqual(agg.phase, .listening)
    }

    /// 残余情形：宣告了工具调用却**从未**产生任务号。显式 resolved 帧是唯一
    /// 解除途径（网关侧已有 `upstream_tool_call_resolved` 判定）。
    func testLatchWithoutAnyTaskIsOnlyReleasedByExplicitResolved() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.audioDoneBarrier)
        agg.apply(.playbackEnded)
        XCTAssertEqual(agg.phase, .thinking)

        agg.apply(.toolCallResolved)
        XCTAssertEqual(agg.phase, .listening)
    }

    /// **反向钉子**：绝不允许「音频落定即解除闩锁」这条逃生门——那正是
    /// ESS-1095 的故障形态（pending 之后上游发 idle、任务帧尚未到达）。
    /// 此时收口就会开新 generation 把在跑的工具 supersede 掉。
    func testAudioSettlementAloneNeverReleasesTheLatch() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.playbackStarted)
        agg.apply(.playbackSegmentEnded)
        agg.apply(.audioDoneBarrier)
        agg.apply(.playbackEnded)

        XCTAssertTrue(agg.toolCallPending, "音频落定不是闩锁的解除依据")
        XCTAssertEqual(agg.phase, .thinking)
        XCTAssertTrue(agg.blocksAutomaticNextTurn, "任务帧还没到，此刻收口就是 ESS-1095 复发")
    }

    // MARK: - 两段音频

    /// 两段音频（「我正在查询…」+ 真答案）之间必须回到思考态，
    /// 且中途绝不允许收口开下一轮。
    func testTwoSegmentAnswerNeverClosesBetweenSegments() {
        var agg = ToolTurnAggregate()

        // 段 0。
        agg.apply(.playbackStarted)
        agg.apply(.playbackSegmentEnded)
        XCTAssertEqual(agg.phase, .thinking)
        XCTAssertFalse(agg.isClosed, "回合屏障还没到，段落之间不算答完")
        // 无工具证据的普通多段回合不走闸门——那条路由 `markAnswerInterim`
        // 承担（ESS-971 已验证），本聚合体不重复接管。
        XCTAssertFalse(agg.hasToolEvidence)

        // 段 1（真答案）+ 回合屏障。
        agg.apply(.playbackStarted)
        XCTAssertEqual(agg.phase, .answering)
        agg.apply(.audioDoneBarrier)
        agg.apply(.playbackEnded)
        XCTAssertEqual(agg.phase, .listening)
        XCTAssertTrue(agg.didPlayAnyAudio)
    }

    /// 零音频回合（`final_sequence = -1`）：没有起播也没有播完，
    /// 屏障落定即收口，不能挂在「等播完」上。
    func testZeroAudioTurnClosesOnBarrierAlone() {
        var agg = ToolTurnAggregate()
        agg.apply(.audioDoneBarrier)
        XCTAssertEqual(agg.phase, .listening)
        XCTAssertFalse(agg.didPlayAnyAudio)
    }

    // MARK: - 播放晚于连接关闭

    /// 下行通道先死、音频还在播：先把音频放完，再回聆听。
    /// 通道死了就不会再有 `audio.done` / `task.*` 终态，继续等 = 永久卡死。
    func testPlaybackOutlivingClosedDownlinkStillFinishesBeforeListening() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.playbackStarted)

        agg.apply(.downlinkClosed(reason: "transport_failed"))
        XCTAssertEqual(agg.phase, .answering, "音频还在播，先放完")
        XCTAssertFalse(agg.isClosed)
        XCTAssertEqual(agg.holdReasons, [.playbackInFlight])

        agg.apply(.playbackEnded)
        XCTAssertEqual(agg.phase, .listening)
        XCTAssertEqual(agg.downlinkClosedReason, "transport_failed")
    }

    /// 通道关闭且没有在播音频 → 立刻收口，不得卡在「正在思考」。
    func testClosedDownlinkWithNoPlaybackClosesImmediately() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.downlinkClosed(reason: "wss_closed"))
        XCTAssertEqual(agg.phase, .listening)
        XCTAssertTrue(agg.outstandingTasks.isEmpty)
    }

    // MARK: - 取消 / 失败 / 超时

    func testUserCancelIsImmediateTerminalEvenWithRunningTask() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.playbackStarted)

        agg.apply(.userCancelled(reason: "orb_tap"))
        XCTAssertEqual(agg.phase, .cancelled(reason: "orb_tap"))
        XCTAssertTrue(agg.phase.isTerminalFailure)
        XCTAssertTrue(agg.isClosed, "用户主动打断是明确终态，允许开下一轮")
        XCTAssertTrue(agg.allowsAutomaticNextTurn)
    }

    func testTurnFailedIsImmediateTerminal() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.turnFailed(code: "ERR_SESSION_TURN_FAILED"))
        XCTAssertEqual(agg.phase, .failed(code: "ERR_SESSION_TURN_FAILED"))
        XCTAssertTrue(agg.isClosed)
    }

    func testTimeoutIsImmediateTerminalAndNeverStaysThinking() {
        var agg = ToolTurnAggregate()
        agg.apply(.toolCallPending)
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.timedOut(reason: "tool_task_timeout"))
        XCTAssertEqual(agg.phase, .timedOut(reason: "tool_task_timeout"))
        XCTAssertTrue(agg.isClosed)
        XCTAssertTrue(agg.holdReasons.isEmpty)
    }

    /// 终态吸收：判死之后迟到的上游事件不得复活回合。
    func testTerminalAbsorbsLateEvents() {
        var agg = ToolTurnAggregate()
        agg.apply(.turnFailed(code: "ERR_X"))
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.audioDoneBarrier)
        agg.apply(.playbackStarted)
        XCTAssertEqual(agg.phase, .failed(code: "ERR_X"), "终态吸收，一切迟到事件只留证")
    }

    /// 取消后迟到的 `.ended` 必须把播放记账清干净——否则复用同一聚合体时
    /// `playbackInFlight` 会永远留成 true。
    func testLatePlaybackEndAfterCancelClearsPlaybackBookkeeping() {
        var agg = ToolTurnAggregate()
        agg.apply(.playbackStarted)
        agg.apply(.userCancelled(reason: "session_exit"))
        agg.apply(.playbackEnded)
        XCTAssertFalse(agg.playbackInFlight)
    }

    // MARK: - 取证

    func testLogDetailCarriesEveryDecisionInput() {
        // 闩锁态（还没有任务号）：`tool_call_pending` 必须在日志里可判定，
        // 否则真机上「为什么还在思考」查不出来。
        var latched = ToolTurnAggregate()
        latched.apply(.toolCallPending)
        let latchedDetail = latched.logDetail
        XCTAssertTrue(latchedDetail.contains("phase=thinking"), latchedDetail)
        XCTAssertTrue(latchedDetail.contains("closed=false"), latchedDetail)
        XCTAssertTrue(latchedDetail.contains("hold=tool_call_pending|awaiting_audio_done"), latchedDetail)
        XCTAssertTrue(latchedDetail.contains("tool_call_pending=true"), latchedDetail)

        // 任务态（闩锁已交棒）：把关原因换成 task_outstanding，同样可判定。
        var running = latched
        running.apply(.taskState(taskId: "t1", status: .running))
        let runningDetail = running.logDetail
        XCTAssertTrue(runningDetail.contains("hold=task_outstanding|awaiting_audio_done"), runningDetail)
        XCTAssertTrue(runningDetail.contains("outstanding_tasks=1"), runningDetail)
        XCTAssertTrue(runningDetail.contains("seen_tasks=1"), runningDetail)
        XCTAssertTrue(runningDetail.contains("tool_call_pending=false"), runningDetail)
    }

    /// `apply` 的返回值是「相位变了没有」——会话层只在变化时落日志，
    /// 不能被高频 `task.progress` 刷屏。
    func testApplyReportsPhaseChangeOnly() {
        var agg = ToolTurnAggregate()
        XCTAssertFalse(agg.apply(.taskState(taskId: "t1", status: .running)), "仍是 thinking，无变化")
        XCTAssertTrue(agg.apply(.playbackStarted), "thinking → answering")
        XCTAssertFalse(agg.apply(.taskState(taskId: "t2", status: .running)), "仍是 answering")
        XCTAssertTrue(agg.apply(.playbackSegmentEnded), "answering → thinking")
    }
}
