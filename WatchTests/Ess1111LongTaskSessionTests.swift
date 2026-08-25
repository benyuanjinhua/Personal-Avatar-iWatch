import XCTest
@testable import WristAgent_Watch_App

/// ESS-1111：长任务在会话层的**时序**行为。
///
/// 复现基线是 ESS-1109 的真机取证，一条时间线上四个事实：
///   • Codex 任务 13:46:16.730 开始，24.020s 完成；
///   • 网关从任务开始即每秒下发 `task.running`，13:46:26 起「正在整理结果」；
///   • Watch 在任务仍 running 时于 **13:46:28.837（+12.107s）** 以 1006 断开；
///   • 最终结果在断开后 11.9s 才完成，无法回传。
///
/// 本套件把这条时间线变成一个可重放的夹具：`VirtualSessionClock` 按真实秒数
/// 推进并**按到期顺序触发所有已武装的计时器**。断言因此不是「某个计时器没被
/// 武装」这种间接证据，而是「跑到第 12 秒时会话仍然活着」这个直接事实——
/// 任何未来新增的固定短超时都会被这个夹具当场抓住。
///
/// 纯逻辑那一半（展示分类、答案流去重/截断、聚合体的断线语义）在
/// `Tests/Ess1111LongTaskStreamTests.swift`，走 `swift test`。
@MainActor
final class Ess1111LongTaskSessionTests: XCTestCase {

    /// 真机取证里的任务号与耗时，原样用作夹具输入。
    private static let taskId = "work_a8f61916-3b05-4831-9122-355f613365d3"
    private static let taskDurationSeconds: TimeInterval = 24.020
    private static let incidentDisconnectSeconds: TimeInterval = 12.107

    private var controller: SessionController!
    private var clock: VirtualSessionClock!
    private var startTurnCount = 0
    private var graceExpiredCount = 0
    private var resumedCount = 0
    private var teardownCount = 0
    private var defaults: UserDefaults!
    /// 本回合的 requestId。生产链路上适配器把它作为 `handle` 捕获住，宽限到点
    /// 时用的是**它**而不是会话当时的 `activeTurnRequestId`（后者在
    /// `enterFailed` 之后已被清空）。测试接线必须照抄这一点，否则闭包会因为
    /// 拿到 nil 而提前 return，等于什么都没验。
    private var wiredTurnRequestId: String?

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess1111LongTaskSessionTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        clock = VirtualSessionClock()
        startTurnCount = 0
        graceExpiredCount = 0
        controller.playHaptic = { _ in }
        controller.scheduleDelay = { [clock] delay, fire in
            clock!.schedule(delay: delay, fire: fire)
        }
        controller.onBeginChannel = { "req-1111-turn-1" }
        controller.onTeardownChannel = { [weak self] in
            self?.teardownCount += 1
        }
        controller.onStartTurn = { [weak self] in
            self?.startTurnCount += 1
            return "req-1111-turn-2"
        }
        // ESS-1111 复审整改（阻断 1）：这里**必须接真链路**，不能只记个数。
        //
        // 上一版把本回调替换成计数器，于是
        //   onDownlinkGraceExpired → finishDeferredTransportFailure
        //   → onAnswerPlaybackFailed → onSessionAnswerFinished
        //   → markAnswerFinished(success: false)
        // 这一整段在测试里根本不存在，绿灯覆盖不到宽限到点这条**主失败路径**，
        // 真实缺陷（失败路径上开新录音）就这么漏了过去。下面照抄生产接线的
        // 最后一跳：适配器收口一定会回打一次 `markAnswerFinished(success:false)`。
        controller.onDownlinkGraceExpired = { [weak self] reason in
            guard let self else { return }
            self.graceExpiredCount += 1
            guard let requestId = self.wiredTurnRequestId else { return }
            self.controller.markAnswerFinished(
                requestId: requestId, success: false,
                reason: "transport_failed:\(reason)"
            )
        }
        controller.onDownlinkResumed = { [weak self] _ in
            self?.resumedCount += 1
        }
    }

    override func tearDown() {
        controller = nil
        clock = nil
        defaults = nil
        wiredTurnRequestId = nil
        super.tearDown()
    }

    // MARK: - 验收：复现夹具中 12s 不再断开，24s 后最终答案可播放并正确收口

    func testTwentyFourSecondTaskSurvivesTheTwelveSecondIncidentPointAndClosesOnTheLateAnswer() {
        let requestId = beginTurn()

        // t=0：任务受理。
        emit(requestId, status: "queued", seq: 1, text: "正在排队", category: "queued")

        // t=1…24：网关每秒一帧。9s 起有真实内容进展，收尾阶段换成整理结果。
        for second in 1...24 {
            clock.advance(to: TimeInterval(second))
            switch second {
            case ..<9:
                emit(requestId, status: "running", seq: second + 1, text: nil, category: nil)
            case 9..<20:
                emit(requestId, status: "running", seq: second + 1,
                     text: "正在查询相关信息", category: "search")
            default:
                emit(requestId, status: "running", seq: second + 1,
                     text: "正在整理结果", category: "finalizing")
            }

            // **事故点**：真机在这里断开。夹具跑到同一秒时会话必须还活着。
            if TimeInterval(second) >= Self.incidentDisconnectSeconds, second <= 13 {
                XCTAssertEqual(controller.state, .listening,
                               "第 \(second) 秒：任务仍在跑，会话不得退出")
                XCTAssertEqual(controller.turnPhase, .thinking,
                               "第 \(second) 秒：不得回到聆听（回聆听 = 开下一轮 = 杀掉在跑的任务）")
                XCTAssertNil(controller.failedReason, "第 \(second) 秒：不得出现失败文案")
                XCTAssertEqual(startTurnCount, 0, "第 \(second) 秒：绝不允许自动开下一轮")
            }
        }

        XCTAssertEqual(controller.turnPhase, .thinking, "24s 结束时仍在等最终答案")
        XCTAssertEqual(controller.toolProcessingText, "正在整理结果",
                       "收尾阶段的类目必须如实展示，而不是笼统的「正在思考」")

        // t=24.020：任务完成 + 最终答案音频到达并播完。
        clock.advance(to: Self.taskDurationSeconds)
        emit(requestId, status: "completed", seq: 100, text: nil, category: nil)
        controller.markAnswerStarted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .speaking, "最终答案可播放")
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(controller.turnPhase, .listening, "task terminal + 播放屏障都满足 → 收口")
        XCTAssertEqual(startTurnCount, 1, "收口之后才允许开下一轮，且只开一次")
        XCTAssertNil(controller.failedReason)
    }

    /// 「每秒状态但晚到答案」：任务本身早早 completed，答案音频晚了很久才来。
    /// 这一段里没有任何 `task.*` 可收，有界性由 45s 等回答预算承担——
    /// 但**不得**因为「没有音频」而提前退出。
    func testStatusEverySecondThenLateAnswerStillCloses() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)

        for second in 1...10 {
            clock.advance(to: TimeInterval(second))
            emit(requestId, status: "running", seq: second + 1, text: nil, category: nil)
        }
        clock.advance(to: 11)
        emit(requestId, status: "completed", seq: 20, text: nil, category: nil)

        // 任务完成之后又静了 30 秒才出音频：期间不得判失败。
        clock.advance(to: 41)
        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertNil(controller.failedReason)

        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .listening)
    }

    /// 上游真的静默 ⇒ 有界收口，且给的是**明确终态**而不是永远的「正在思考」。
    func testUpstreamSilenceIsBoundedByTheActivityBudget() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: "正在查询相关信息", category: "search")

        clock.advance(to: SessionController.taskActivityTimeoutSeconds - 1)
        XCTAssertEqual(controller.turnPhase, .thinking, "预算未到点前不得放弃")
        XCTAssertNil(controller.failedReason)

        clock.advance(to: SessionController.taskActivityTimeoutSeconds + 0.5)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertNotNil(controller.failedReason, "静默到点必须给明确终态，不能停在思考")
    }

    /// 活动**续期**：静默预算每收到一帧就整体重置。连续 3 个预算周期里各在
    /// 末尾收到一帧，会话必须一直活着 —— 这正是「固定时长退出」与
    /// 「按活动判定」的分水岭。
    func testEveryLegalFrameRenewsTheActivityBudget() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)

        var now: TimeInterval = 0
        for round in 1...3 {
            now += SessionController.taskActivityTimeoutSeconds - 2
            clock.advance(to: now)
            XCTAssertEqual(controller.turnPhase, .thinking, "第 \(round) 个周期内不得退出")
            emit(requestId, status: "running", seq: round + 1, text: nil, category: nil)
        }

        XCTAssertGreaterThan(now, SessionController.taskActivityTimeoutSeconds * 2,
                             "夹具确实跨过了多个预算周期")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertNil(controller.failedReason)
    }

    // MARK: - 进展突发

    /// 一秒内连发 6 条进展：节流不丢最后一条，也不把回合状态搅乱。
    func testProgressBurstIsThrottledWithoutLosingTheLastLine() {
        let requestId = beginTurn()

        let lines = ["正在排队", "正在查询相关信息", "正在读取相关内容",
                     "正在修改内容", "正在生成图片", "正在整理结果"]
        for (index, line) in lines.enumerated() {
            emit(requestId, status: "running", seq: index + 1, text: line, category: nil)
        }
        XCTAssertEqual(controller.toolProcessingText, lines.first,
                       "突发窗口内只画第一条，不跟着逐条闪烁")

        clock.advance(to: SessionController.progressUpdateMinIntervalSeconds + 0.01)
        XCTAssertEqual(controller.toolProcessingText, lines.last,
                       "窗口一到必须补上最后一条，丢掉它等于停在一句过期的进展上")
        XCTAssertEqual(controller.turnPhase, .thinking, "突发不改变相位")
    }

    // MARK: - 答案增量（验收 1：answer）

    func testAnswerDeltasStreamIntoTheirOwnLineAndNeverOverwriteProgress() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: "正在查询相关信息", category: "search")
        XCTAssertNil(controller.answerStreamText)

        emit(requestId, status: "running", seq: 2, text: "上海明天", category: "answer")
        emit(requestId, status: "running", seq: 3, text: "多云转晴。", category: "answer")

        XCTAssertEqual(controller.answerStreamText, "上海明天多云转晴。")
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息",
                       "答案增量绝不能把进展那一行盖掉——两条流各占一行")
    }

    func testOutOfOrderAndDuplicateAnswerDeltasDoNotCorruptTheStream() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 5, text: "第一片", category: "answer")
        emit(requestId, status: "running", seq: 6, text: "第二片", category: "answer")

        emit(requestId, status: "running", seq: 6, text: "第二片", category: "answer")
        emit(requestId, status: "running", seq: 4, text: "迟到的旧片", category: "answer")

        XCTAssertEqual(controller.answerStreamText, "第一片第二片")
    }

    func testLongAnswerIsBoundedOnScreen() {
        let requestId = beginTurn()
        for seq in 1...10 {
            emit(requestId, status: "running", seq: seq,
                 text: String(repeating: "字", count: 50), category: "answer")
        }
        let shown = controller.answerStreamText ?? ""
        XCTAssertEqual(shown.count, LongTaskAnswerTranscript.displayWindowCharacters + 1,
                       "500 字的答案在表盘上必须仍然只渲染有界的一小段")
    }

    func testAnswerStreamDoesNotLeakIntoTheNextTurn() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: "上一轮的答案", category: "answer")
        emit(requestId, status: "completed", seq: 2, text: nil, category: nil)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(startTurnCount, 1)
        XCTAssertNil(controller.answerStreamText, "新一轮不得挂着上一轮的答案")
        XCTAssertNil(controller.toolProcessingText)
    }

    // MARK: - 断线重连（实现要求 4）

    func testDisconnectRetainsTaskIdentityAndResumesOnTheNextFrame() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: "正在查询相关信息", category: "search")
        XCTAssertTrue(controller.hasLongTaskInFlight)

        clock.advance(to: Self.incidentDisconnectSeconds)
        controller.markDownlinkInterrupted(requestId: requestId, reason: "socket_1006")

        XCTAssertTrue(controller.isDownlinkInterrupted)
        XCTAssertEqual(controller.turnPhase, .thinking, "断线不得让回合收口")
        XCTAssertEqual(controller.toolTurn.outstandingTasks.count, 1,
                       "task identity 必须原样活过断线")
        XCTAssertEqual(controller.toolProcessingText, SessionController.reconnectingCopy,
                       "屏幕必须如实说正在重连，而不是停在一句「正在查询」")
        XCTAssertEqual(startTurnCount, 0)

        // 重连：宽限期内收到任何一帧合法增量即恢复，不需要新协议帧。
        clock.advance(to: Self.incidentDisconnectSeconds + 5)
        emit(requestId, status: "running", seq: 2, text: "正在整理结果", category: "finalizing")

        XCTAssertFalse(controller.isDownlinkInterrupted)
        XCTAssertEqual(controller.toolProcessingText, "正在整理结果")
        XCTAssertEqual(graceExpiredCount, 0, "恢复了就不该再收口那次被推迟的传输失败")

        // 真机时间线：断开后 11.9s 最终答案才完成 —— 现在它能播出来了。
        clock.advance(to: Self.taskDurationSeconds)
        emit(requestId, status: "completed", seq: 3, text: nil, category: nil)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(startTurnCount, 1)
    }

    func testReconnectGraceIsBoundedAndEndsInAnExplicitTerminal() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)
        controller.markDownlinkInterrupted(requestId: requestId, reason: "socket_1006")

        clock.advance(to: SessionController.downlinkReconnectGraceSeconds - 1)
        XCTAssertEqual(controller.state, .listening, "宽限内不得提前判死")

        clock.advance(to: SessionController.downlinkReconnectGraceSeconds + 0.5)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertNotNil(controller.failedReason)
        XCTAssertEqual(graceExpiredCount, 1,
                       "宽限到点必须把那次被推迟的传输失败交回适配器收口")
    }

    /// **复审阻断 1 的回归**：宽限到点走的是一条**失败**路径，它绝不能在半路
    /// 开出一轮新录音来。
    ///
    /// 这个用例之所以能抓住缺陷，全靠 `setUp` 里把 `onDownlinkGraceExpired`
    /// 接成真链路（会回打 `markAnswerFinished(success: false)`）。修复前：
    /// 闭包先通知适配器，`.downlinkClosed` 已让回合 `isClosed`，于是
    /// `markAnswerFinished` 一路落到 `startNextTurn`，`startTurnCount` 会变成
    /// 1、麦克风在失败页上继续采集。修复后：先 `enterFailed`，迟到的
    /// `answer_finished` 被 `acceptsTurnEvent` 挡掉。
    func testGraceExpiryEndsInASingleTerminalAndNeverStartsANewRecording() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: "正在查询相关信息", category: "search")
        controller.markDownlinkInterrupted(requestId: requestId, reason: "socket_1006")

        clock.advance(to: SessionController.downlinkReconnectGraceSeconds + 0.5)

        XCTAssertEqual(graceExpiredCount, 1, "适配器收口只应被通知一次")
        XCTAssertEqual(
            startTurnCount, 0,
            "宽限到点是失败路径：绝不允许在这里开一轮新录音（新 requestId / 新 generation）"
        )
        XCTAssertEqual(controller.state, .failed, "唯一终态是失败页")
        XCTAssertNotNil(controller.failedReason)
        XCTAssertEqual(
            teardownCount, 1,
            "下行已判死，通道必须真的拆掉——否则失败页上采集与传输都还挂着"
        )
        XCTAssertEqual(controller.turnPhase, .idle)
        XCTAssertNil(controller.activeTurnRequestId, "回合已收束，不留悬挂的 request")
    }

    /// 宽限到点之后**迟到**的播放失败回执同样不得复活会话。
    func testLateAnswerFailureAfterTerminalIsDropped() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)
        controller.markDownlinkInterrupted(requestId: requestId, reason: "socket_1006")
        clock.advance(to: SessionController.downlinkReconnectGraceSeconds + 0.5)
        XCTAssertEqual(controller.state, .failed)

        controller.markAnswerFinished(requestId: requestId, success: false,
                                      reason: "transport_failed:late")

        XCTAssertEqual(controller.state, .failed, "终态已落定，迟到回执不得改写")
        XCTAssertEqual(startTurnCount, 0)
    }

    /// **复审阻断 2 的回归**：恢复判据只有一个，且在会话层。会话认定恢复时
    /// 必须**恰好**通知适配器一次，让它撤销那次被推迟的收口——两层各判一次
    /// 就会分叉（音频先于首帧 task 渲染时，适配器会留下陈旧的推迟原因，
    /// 把一次已答完的回合误判成传输失败）。
    func testResumeIsDecidedOnlyBySessionAndNotifiesTheAdapterExactlyOnce() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)
        controller.markDownlinkInterrupted(requestId: requestId, reason: "socket_1006")
        XCTAssertEqual(resumedCount, 0)

        // 播放先于第一帧 task 起播——正是复审点名的那个时序。
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerInterim(requestId: requestId)
        XCTAssertEqual(resumedCount, 0, "起播本身不是恢复判据，会话没认它")

        emit(requestId, status: "running", seq: 2, text: "正在整理结果", category: "finalizing")

        XCTAssertEqual(resumedCount, 1, "会话认定恢复 ⇒ 恰好通知适配器一次")
        XCTAssertFalse(controller.isDownlinkInterrupted)

        // 再来一帧不得重复通知（恢复是一次性事件）。
        emit(requestId, status: "running", seq: 3, text: nil, category: nil)
        XCTAssertEqual(resumedCount, 1)

        // 恢复之后这一轮照常答完，不被任何陈旧的推迟收口吞掉。
        emit(requestId, status: "completed", seq: 4, text: nil, category: nil)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(graceExpiredCount, 0, "恢复了就绝不该再触发宽限收口")
        XCTAssertEqual(controller.state, .listening)
    }

    /// 断线期间**不得**因为任何单一事实（屏障早到、任务终态早到）而收口。
    func testTurnCannotCloseWhileDisconnected() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)
        controller.markDownlinkInterrupted(requestId: requestId, reason: "socket_1006")

        controller.markAnswerFinished(requestId: requestId, success: true,
                                      reason: "stale_barrier")

        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertEqual(startTurnCount, 0, "断线期间开下一轮 = 用新 generation 杀掉在跑的任务")
    }

    // MARK: - 代际隔离（实现要求 4 后半：禁止旧 generation 污染新回合）

    func testStaleGenerationFramesAreDropped() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1,
             text: "新一代的进展", category: "search", generation: 3)
        XCTAssertEqual(controller.toolProcessingText, "新一代的进展")

        // 打断之前那一代仍在跑的任务继续下发进展：requestId 相同，只有代际能挡。
        emit(requestId, status: "running", seq: 2,
             text: "上一代的进展", category: "search", generation: 2)

        clock.advance(to: SessionController.progressUpdateMinIntervalSeconds + 0.01)
        XCTAssertEqual(controller.toolProcessingText, "新一代的进展",
                       "旧 generation 的迟到帧不得盖到新一轮头上")
    }

    /// 代际缺席（老网关 / 老 iPhone 进程）时照常放行 —— 滚动升级窗口内不许
    /// 因为缺一个字段就把整帧丢掉。
    func testMissingGenerationIsAcceptedForRollingUpgrade() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: "正在查询相关信息", category: "search")
        XCTAssertEqual(controller.toolProcessingText, "正在查询相关信息")
    }

    // MARK: - 终态（实现要求 3：failed / cancelled 显示明确终态）

    func testUpstreamTaskFailureSurfacesAnExplicitTerminal() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: "正在查询相关信息", category: "search")

        emit(requestId, status: "failed", seq: 2, text: nil, category: nil)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.failedReason, ToolTaskStatus.failed.failureNoticeText)
        XCTAssertTrue(controller.failedRetryable)
        XCTAssertEqual(startTurnCount, 0, "失败不得静默收口成「正在听」")
    }

    func testUpstreamTaskCancellationSurfacesItsOwnCopy() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)

        emit(requestId, status: "cancelled", seq: 2, text: nil, category: nil)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.failedReason, ToolTaskStatus.cancelled.failureNoticeText)
        XCTAssertFalse(controller.failedRetryable, "用户/上游取消的事不该劝人重试")
    }

    /// 答案已经说出口之后才到的任务失败**不得**改写这一轮 —— 那时候报
    /// 「没能完成」是撒谎。
    func testTaskFailureAfterAudioPlayedDoesNotRewriteTheTurn() {
        let requestId = beginTurn()
        emit(requestId, status: "running", seq: 1, text: nil, category: nil)
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerInterim(requestId: requestId)

        emit(requestId, status: "failed", seq: 2, text: nil, category: nil)

        XCTAssertNotEqual(controller.state, .failed)
        XCTAssertNil(controller.failedReason)
    }

    /// 并发的第二个任务还在跑时，第一个任务失败不收口整轮。
    func testFailureOfOneTaskDoesNotCloseTheTurnWhileAnotherIsOutstanding() {
        let requestId = beginTurn()
        emit(requestId, taskId: "task-a", status: "running", seq: 1, text: nil, category: nil)
        emit(requestId, taskId: "task-b", status: "running", seq: 2, text: nil, category: nil)

        emit(requestId, taskId: "task-a", status: "failed", seq: 3, text: nil, category: nil)

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .thinking)
    }

    /// 未知状态一律按非终态（ESS-1097 的口径本单一个字不改）。
    func testUnknownTaskStatusStillHoldsTheTurnOpen() {
        let requestId = beginTurn()
        emit(requestId, status: "sandboxing", seq: 1, text: nil, category: nil)

        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertTrue(controller.hasLongTaskInFlight)
        XCTAssertEqual(controller.state, .listening)
    }

    // MARK: - helpers

    @discardableResult
    private func beginTurn() -> String {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)
        // 适配器在生产里就是这样把 handle 捏在手里的。
        wiredTurnRequestId = requestId
        return requestId
    }

    private func emit(
        _ requestId: String, taskId: String? = Ess1111LongTaskSessionTests.taskId,
        status: String, seq: Int?, text: String?, category: String?,
        generation: Int? = nil
    ) {
        controller.markTaskState(
            requestId: requestId, taskId: taskId, status: status,
            progress: AgentTaskProgress(sequence: seq, text: text, category: category),
            generation: generation
        )
    }
}

// MARK: - 虚拟时钟

/// 按真实秒数推进、按到期顺序触发的确定性时钟。
///
/// 它比「收集闭包、手动挑一个触发」强的地方正是本单需要的那一点：夹具推进到
/// 第 12 秒时，**所有**在此之前到期的计时器都已经真的跑过了。因此
/// 「12s 不再断开」这条断言覆盖的是当时武装着的每一个超时，而不只是我们
/// 记得去检查的那一个。
@MainActor
final class VirtualSessionClock {
    private final class Entry {
        let dueAt: TimeInterval
        let fire: @MainActor () -> Void
        var isCancelled = false
        var didFire = false

        init(dueAt: TimeInterval, fire: @escaping @MainActor () -> Void) {
            self.dueAt = dueAt
            self.fire = fire
        }
    }

    private(set) var now: TimeInterval = 0
    private var entries: [Entry] = []

    func schedule(delay: TimeInterval, fire: @escaping @MainActor () -> Void) -> SessionDelayToken {
        let entry = Entry(dueAt: now + delay, fire: fire)
        entries.append(entry)
        return Token(entry: entry)
    }

    /// 推进到 `time`，按到期顺序触发沿途所有仍然武装着的计时器。
    /// 触发过程中新武装的计时器若也已到期，会在同一次推进里继续处理。
    func advance(to time: TimeInterval) {
        precondition(time >= now, "时钟不倒流")
        while true {
            let due = entries
                .filter { !$0.isCancelled && !$0.didFire && $0.dueAt <= time }
                .sorted { $0.dueAt < $1.dueAt }
            guard let next = due.first else { break }
            now = max(now, next.dueAt)
            next.didFire = true
            next.fire()
        }
        now = time
    }

    private final class Token: SessionDelayToken {
        private let entry: Entry

        init(entry: Entry) {
            self.entry = entry
        }

        func cancel() {
            MainActor.assumeIsolated { entry.isCancelled = true }
        }
    }
}
