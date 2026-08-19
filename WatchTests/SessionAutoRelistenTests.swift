import XCTest
@testable import WristAgent_Watch_App

/// ESS-600（Wave 1 / F5）：一次进入、连续多轮的自动重新聆听闭环。
///
/// 本套件针对第一次复审的三条阻断逐条取证，测试形态是刻意选的：
///
/// **阻断 1（realtime 是默认播放路径，却没接到状态机）** —— 本套件不复制
/// 接线，而是调用生产接线本体：`PushToTalkController.attachAnswerPlayback(to:)`
/// 与 `SessionTurnWiring.connect(...)`。把接线抄进测试只能证明副本是对的，
/// 证明不了生产路径接上了——那正是上一版被打回的原因。
///
/// **阻断 2（事件语义不真实）** —— `.started` 只在播放引擎首帧真实渲染时
/// 发出、`.ended` 只在最后一个排队 buffer 渲染完毕时发出，两者都由
/// `RealtimePlaybackEngine.PlaybackEvent` 的真实语义承载；失败终局单独
/// 断言不得推进到下一轮。
///
/// **阻断 3（缺连续五轮的关联证据）** —— `testFiveContinuousTurns...` 在
/// watchOS 模拟器进程内跑满五轮，用 `WatchLog.setObserver` 抓真实运行时
/// 事件流，逐轮断言 conversation_id 不变、turn_id 严格递增、事件顺序正确、
/// 旧回合迟到音频零补播，并把关联日志打进测试输出作为 R-02.1 证据。
///
/// 覆盖边界（如实声明，不夸大）：模拟器里没有 iPhone / Bridge / Gateway，
/// 因此本套件证明的是 **Watch 侧回合闭环**；跨设备真实链路属 R-02.5 关卡二，
/// 合入后随装机真机复测。唯一被替身顶掉的生产环节是「起轮时真正打开麦克风」
/// （`AudioRecorder` 在无音频硬件的 CI 上会挂，见 ESS-498/HostedCITestGate），
/// 替身直接调用 `adapter.beginTurn(requestId:)`——与 `pressBegan` 内部
/// 调的是同一个方法。
@MainActor
final class SessionAutoRelistenTests: XCTestCase {

    // MARK: - 接线断言（阻断 1 的结构性防线）

    /// 生产接线跑完之后，会话状态机的每一个真实事件入口都必须是接上的。
    /// 上一版实现之所以能「全绿但闭环不成立」，就是因为没有任何一条断言
    /// 盯着这些出入口是否为 nil。
    func testProductionWiringConnectsEveryTurnEventSeam() {
        let session = SessionController(defaults: freshDefaults())
        let pushToTalk = PushToTalkController()

        SessionTurnWiring.connect(session: session, pushToTalk: pushToTalk, interruptSelfCheck: {})

        XCTAssertNotNil(session.onBeginChannel, "进入会话必须能发起第一轮")
        XCTAssertNotNil(session.onStartTurn, "自动重新聆听的起轮出口未接 = 闭环不成立")
        XCTAssertNotNil(session.onInterruptSpeaking, "speaking 中的手动打断入口未接")
        XCTAssertNotNil(session.onSalvageTurn, "ready 超时的语音抢救出口未接")
        XCTAssertNotNil(session.onTeardownChannel)
        XCTAssertNotNil(session.onCommitTurn)
        XCTAssertNotNil(pushToTalk.onRealtimeChannelReady, "通道就绪未接 → 永远进不了会话")
        XCTAssertNotNil(pushToTalk.onRealtimeChannelFailed)
        XCTAssertNotNil(pushToTalk.onSessionTurnCommitted, "提交事件未接 → 永远进不了 thinking")
        XCTAssertNotNil(pushToTalk.onSessionAnswerStarted, "起播事件未接 → 永远进不了 speaking")
        XCTAssertNotNil(pushToTalk.onSessionAnswerFinished, "播完事件未接 → 永远回不到 listening")
        XCTAssertNotNil(pushToTalk.onSessionTurnAborted, "零提交回合未接 → 会话停在死麦克风上")
        XCTAssertNotNil(pushToTalk.onSessionAnswerInterim, "interim 未接 → interim 会被当成本轮答完")
        XCTAssertNotNil(pushToTalk.onLocalCaptureChanged)
    }

    /// 阻断 1 正面取证：realtime 播放引擎发出的**真实** `.started/.ended`
    /// 必须一路走到会话状态机。链路全部是生产代码：
    /// player → adapter → `attachAnswerPlayback` → `SessionTurnWiring` → session。
    func testRealtimePlaybackEventsDriveTurnPhaseThroughProductionWiring() {
        let h = makeHarness()

        h.startFirstTurn()
        XCTAssertEqual(h.session.turnPhase, .listening)

        h.commitCurrentTurn()
        XCTAssertEqual(h.session.turnPhase, .thinking, "上行提交后应进入思考")

        h.emitPlaybackStarted()
        XCTAssertEqual(h.session.turnPhase, .speaking, "realtime 首帧渲染后应进入回答")

        h.emitPlaybackEnded()
        XCTAssertEqual(h.session.turnPhase, .listening, "realtime 播完后应自动回到聆听")
        XCTAssertEqual(h.startedTurns.count, 2, "播完必须自动开下一轮，无需再次按键")
    }

    // MARK: - 阻断 2：事件语义必须真实

    /// realtime 播放失败不得记成播完。会话仍要恢复到可说话，但事件必须
    /// 如实标注失败——「失败播放也开启下一轮」和「把失败记成成功」是两件事，
    /// 前者是必要的恢复，后者是伪造。
    func testRealtimePlaybackFailureIsNotRecordedAsFinished() {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()
        h.emitPlaybackStarted()

        h.emitPlaybackFailed(code: "ERR_RENDER")

        XCTAssertEqual(h.session.turnPhase, .listening, "失败也要恢复到可说话，不能卡死")
        XCTAssertEqual(h.log.count(of: "session_answer_finished"), 0, "失败绝不能记成播完")
        XCTAssertEqual(h.log.count(of: "session_answer_failed"), 1)
        XCTAssertTrue(
            h.log.last(of: "session_answer_failed")?.detail?.contains("ERR_RENDER") == true,
            "失败原因必须落在日志里可复核"
        )
    }

    /// 完整文件回退路径：`SpeechPlayer.play()` 返回 false = 一个字都没出，
    /// 不得上报「回答开始了」。
    func testCompleteFilePlayRejectedDoesNotEnterSpeaking() {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()

        // 生产里 playResult 在 started == false 时走的就是这一条。
        h.pushToTalk.onSessionAnswerFinished?(h.currentRequestId, false, "play_rejected")

        XCTAssertNotEqual(h.session.turnPhase, .speaking)
        XCTAssertEqual(h.log.count(of: "session_answer_started"), 0)
        XCTAssertEqual(h.log.count(of: "session_answer_failed"), 1)
    }

    /// 完整文件回退路径的终局分流：只有 `.success` 记成播完。
    func testCompleteFileNonSuccessEndgamesReportFailure() {
        for endgame in ["endgame_exhausted", "endgame_play_rejected", "endgame_deferred_timeout"] {
            let h = makeHarness()
            h.startFirstTurn()
            h.commitCurrentTurn()
            h.pushToTalk.onSessionAnswerStarted?(h.currentRequestId)
            XCTAssertEqual(h.session.turnPhase, .speaking)

            h.pushToTalk.onSessionAnswerFinished?(h.currentRequestId, false, endgame)

            XCTAssertEqual(h.log.count(of: "session_answer_finished"), 0, "\(endgame) 不是播完")
            XCTAssertEqual(h.log.count(of: "session_answer_failed"), 1, "\(endgame) 必须记为失败")
        }
    }

    // MARK: - 二轮复审阻断 A：开 conversation 不得打死 touch-down 已起的首轮

    /// 短按进会话：录音与实时回合在 touch-down 就起来了，`enterSession` 随后
    /// 才开 conversation 边界。`RealtimeMediaSession.beginConversation` 开头是
    /// `finishTurn(reason: .interrupted)`——若无条件调用，它会把**正在飞的首轮**
    /// 打死，而 `pressBegan()` 因 state 已是 .recording 又把同一个 request_id
    /// 交回会话层认领：会话盯着一个已被 interrupt 的回合，首轮永远等不到
    /// play_started/finished。
    ///
    /// ESS-642 收紧后口径：可复用的前提是这一轮**确实由本次 touch-down 的
    /// `pressBegan` 起的**（边界闸门为真且 request_id 一致），所以本用例必须
    /// 经生产入口 `pressBegan()` 建立前置，而不是直接戳会话层——直接戳出来的
    /// 回合与「上一会话遗留」不可区分，正是 ESS-642 那次事故。
    func testBeginSessionConversationDoesNotKillInFlightFirstTurn() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        guard let requestId = simulateTouchDown(on: controller) else {
            return XCTFail("pressBegan 未返回 request_id")
        }
        XCTAssertTrue(controller.didStartTurnSinceConversationBoundary)
        // touch-down 的实时回合就位（只动会话层，不碰录音硬件——CI 无音频设备）。
        let inFlight = adapter.beginTurn(requestId: requestId)
        XCTAssertNotNil(adapter.session.activeTurn)

        controller.beginSessionConversation()

        XCTAssertEqual(
            adapter.session.activeTurn?.requestId, requestId,
            "在飞首轮不得被 beginConversation 的 finishTurn 打死"
        )
        XCTAssertEqual(
            adapter.session.activeConversationId, inFlight.conversationId,
            "首轮隐式开的 conversation 就是这段会话的 conversation，不得被换掉"
        )
        controller.pressCancelled()
    }

    /// 反向：没有在飞回合时（长按松手后进会话等路径）仍必须真正开边界，
    /// 否则 conversation_id 无从铸造。
    func testBeginSessionConversationOpensBoundaryWhenNoTurnInFlight() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        XCTAssertNil(adapter.session.activeTurn)

        controller.beginSessionConversation()

        XCTAssertNotNil(adapter.session.activeConversationId, "无在飞回合时必须真开 conversation")
    }

    // MARK: - ESS-642：会话边界——旧 conversation 的回合绝不可被新会话复用

    /// 真机事故（ESS-642）：进入电话模式后 `session_next_listening` 认领了
    /// **上一会话**的 request_id，紧接着 `play_started` 用同一个旧 id 播出上一轮
    /// 答案。根因是 ESS-600 阻断 A 引入的复用只判「有没有 activeTurn」，区分不了
    /// 「本次 touch-down 新起的首轮」与「上一会话遗留的回合」。
    func testEntryDoesNotReuseTurnLeftOverFromPreviousConversation() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        // 上一会话：起过一轮，并且退出时没能清干净（真机上的失败/异常退出路径）。
        let staleRequestId = UUIDv7.generate().uuidString.lowercased()
        _ = adapter.beginTurn(requestId: staleRequestId)
        let staleConversationId = adapter.session.activeConversationId
        XCTAssertNotNil(adapter.session.activeTurn)
        // 会话边界已关闭 = 这一轮属于上一段 conversation。
        controller.endSessionConversation()

        // 新一次进入电话模式。
        controller.beginSessionConversation()

        XCTAssertNil(
            adapter.session.activeTurn,
            "旧回合必须在开新边界前被清掉，不得留给新会话认领"
        )
        XCTAssertNotNil(adapter.session.activeConversationId)
        XCTAssertNotEqual(
            adapter.session.activeConversationId, staleConversationId,
            "新会话必须是新的 conversation 边界"
        )
    }

    /// 更贴近事故的形态：上一会话的回合**还没结束**（边界未关，录音已停），
    /// 此时进入新会话仍不得复用——闸门看的是「本次边界之后是否新起过一轮」。
    func testEntryDiscardsInFlightTurnNotStartedAfterBoundary() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        let staleRequestId = UUIDv7.generate().uuidString.lowercased()
        _ = adapter.beginTurn(requestId: staleRequestId)
        XCTAssertFalse(
            controller.didStartTurnSinceConversationBoundary,
            "该回合不是经 pressBegan 起的，闸门必须为假"
        )

        controller.beginSessionConversation()

        XCTAssertNil(adapter.session.activeTurn, "边界之外的回合必须被丢弃")
    }

    /// 验收：连续进入/退出 5 次，每次都必须是新的 conversation 边界，
    /// 且退出后不留 activeTurn——旧音频没有任何可依附的回合。
    func testFiveEnterExitCyclesNeverLeakTurnAcrossBoundaries() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        var conversationIds: [String] = []

        for round in 1...5 {
            controller.beginSessionConversation()
            guard let conversationId = adapter.session.activeConversationId else {
                return XCTFail("第 \(round) 次进入未开出 conversation")
            }
            conversationIds.append(conversationId)
            // 本次会话里真的起一轮，退出时它必须被清掉。
            _ = adapter.beginTurn(requestId: UUIDv7.generate().uuidString.lowercased())
            XCTAssertNotNil(adapter.session.activeTurn)

            controller.endSessionConversation()
            XCTAssertNil(adapter.session.activeTurn, "第 \(round) 次退出后不得留下 activeTurn")
            XCTAssertNil(adapter.session.activeConversationId, "第 \(round) 次退出后边界必须关闭")
            XCTAssertFalse(controller.didStartTurnSinceConversationBoundary)
        }

        XCTAssertEqual(Set(conversationIds).count, 5, "5 次进入必须是 5 段不同的 conversation")
    }

    // MARK: - ESS-648：短按的异步 activeTurn 窗口不得取消本次首轮

    /// 生产时序回归。`pressBegan()` 同步段只置 `.recording` 与 `streamRequestId`；
    /// `adapter.beginTurn` 要等异步 `recorder.start()` 返回后才执行（ESS-362 的
    /// 顺序约束）。短按松手常常比它快，入口看到的是「闸门为真 + activeTurn 仍为 nil」。
    /// 上面两个 ESS-642 用例都手工提前 `adapter.beginTurn` 建立前置，**盖不住这个
    /// 窗口**——所以本用例刻意不建回合，直接进 conversation。
    func testEntryDuringAsyncTurnStartWindowKeepsRecordingAndRequestId() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        guard let requestId = simulateTouchDown(on: controller) else {
            return XCTFail("pressBegan 未返回 request_id")
        }
        XCTAssertEqual(controller.state, .recording)
        XCTAssertNil(adapter.session.activeTurn, "前置：异步窗口内 activeTurn 尚未建立")

        controller.beginSessionConversation()

        XCTAssertEqual(controller.state, .recording, "本次 touch-down 的合法首轮不得被取消")
        XCTAssertEqual(
            controller.pressBegan(), requestId,
            "紧随其后的 pressBegan 必须交回同一个 request_id，不得更换"
        )
        guard let conversationId = adapter.session.activeConversationId else {
            return XCTFail("窗口内仍必须开出本次会话的 conversation 边界")
        }

        // 异步 recorder.start() 落地：回合此刻才建立。
        let turn = adapter.beginTurn(requestId: requestId)

        XCTAssertEqual(turn.conversationId, conversationId, "异步落地的首轮必须归属本次新 conversation")
        XCTAssertEqual(adapter.session.activeTurn?.requestId, requestId)
        controller.pressCancelled()
    }

    /// 同一窗口，走**生产接线**（`SessionTurnWiring` → `onBeginChannel` =
    /// `beginSessionConversation()` + `pressBegan()`）：会话认领的 request_id
    /// 必须是本次 touch-down 那一个。ESS-642 真机事故里它是上一会话的旧值。
    func testSessionEntryDuringAsyncWindowClaimsTouchDownRequestId() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        let session = SessionController(defaults: freshDefaults())
        session.scheduleDelay = { _, _ in NoopDelayToken() }
        session.playHaptic = { _ in }
        SessionTurnWiring.connect(session: session, pushToTalk: controller, interruptSelfCheck: {})
        guard let requestId = simulateTouchDown(on: controller) else {
            return XCTFail("pressBegan 未返回 request_id")
        }
        XCTAssertNil(adapter.session.activeTurn)

        session.enterSession()

        XCTAssertEqual(controller.state, .recording, "点球进会话不得打断已在录的首轮")
        XCTAssertEqual(
            session.activeTurnRequestId, requestId,
            "会话必须认领本次 touch-down 的 request_id"
        )
        XCTAssertTrue(session.isCapturingLocally, "录音未中断，本地采集应保持为真")
        controller.pressCancelled()
    }

    /// 反向护栏：新开的窗口分支只认「本次边界之后起的」录音。上一会话退出时
    /// 闸门已落，即便录音状态还残留（异常退出路径），入口仍必须走清理分支，
    /// 不得因为 activeTurn 为 nil 就把它当成本次的异步窗口放过去。
    func testEntryStillDiscardsRecordingLeftFromPreviousConversation() {
        let (controller, adapter) = makeControllerWithMockAdapter()
        simulateTouchDown(on: controller)
        XCTAssertEqual(controller.state, .recording)
        // 上一会话退出：闸门落下，录音状态残留。
        controller.endSessionConversation()
        XCTAssertFalse(controller.didStartTurnSinceConversationBoundary)

        controller.beginSessionConversation()

        XCTAssertEqual(controller.state, .idle, "上一会话遗留的录音必须在开新边界前停掉")
        XCTAssertNil(adapter.session.activeTurn)
        XCTAssertNotNil(adapter.session.activeConversationId, "清理后仍必须开出新边界")
    }

    // MARK: - 二轮复审阻断 B：interim 播完不是本轮答完

    /// 完整文件路径的 interim 与最终回答**共用同一个 request_id**。回合尚未
    /// 达终态时播完的是 interim，此刻开下一轮，最终回答会落进下一轮——
    /// 跨轮 + 顺序错乱。相位必须退回 thinking 继续等最终回答。
    func testInterimPlaybackDoesNotAdvanceToNextTurn() {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()
        h.pushToTalk.onSessionAnswerStarted?(h.currentRequestId)
        XCTAssertEqual(h.session.turnPhase, .speaking)
        let turnsBefore = h.startedTurns.count

        // 生产里 handlePlaybackEndgame 在 `turn.currentState.isTerminal == false`
        // 时走的就是这一条。
        h.pushToTalk.onSessionAnswerInterim?(h.currentRequestId)

        XCTAssertEqual(h.session.turnPhase, .thinking, "interim 播完应回到等待最终回答")
        XCTAssertEqual(h.startedTurns.count, turnsBefore, "interim 绝不能开下一轮")
        XCTAssertEqual(h.log.count(of: "session_next_listening"), 1, "只有进会话那一次")
        XCTAssertEqual(h.log.count(of: "session_answer_finished"), 0)
        XCTAssertEqual(h.log.count(of: "session_answer_interim"), 1)

        // 最终回答随后到达，仍在同一轮内正常收口。
        h.pushToTalk.onSessionAnswerFinished?(h.currentRequestId, true, "endgame_success")
        XCTAssertEqual(h.session.turnPhase, .listening)
        XCTAssertEqual(h.startedTurns.count, turnsBefore + 1, "最终回答播完才开下一轮")
    }

    /// interim 之后最终回答永不到达时不许挂死：thinking 的有界超时必须被
    /// 重新武装，到点把会话捞回聆听。
    /// ESS-652: interim think timeout now uses thinkingHardTimeoutSeconds → P6.
    func testInterimReArmsThinkingTimeout() {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()
        h.pushToTalk.onSessionAnswerStarted?(h.currentRequestId)
        h.pushToTalk.onSessionAnswerInterim?(h.currentRequestId)
        XCTAssertEqual(h.session.turnPhase, .thinking)

        h.fireScheduled(withDelay: SessionController.thinkingHardTimeoutSeconds)

        XCTAssertEqual(h.log.count(of: "session_thinking_hard_timeout"), 1)
        XCTAssertEqual(h.session.state, .failed)
    }

    // MARK: - 阻断 3：连续五轮的运行时关联证据

    /// R-02.1 运行时证据：watchOS 模拟器进程内连续跑满五轮，抓真实
    /// `WatchLog` 事件流断言全部验收口径，并把关联日志打进测试输出。
    func testFiveContinuousTurnsKeepConversationAndAdvanceTurnIds() throws {
        let h = makeHarness()
        let rounds = 5

        h.startFirstTurn()
        for round in 1...rounds {
            XCTAssertEqual(h.session.turnPhase, .listening, "第 \(round) 轮开始时应在聆听")
            // 真实 VAD 断句：喂 PCM，让 endpointer 自己判定说完并自动 commit。
            h.speakUntilVADFinal()
            XCTAssertEqual(
                h.transport.commitEvents.count, round,
                "第 \(round) 轮：VAD 断句应产生且仅产生一次上行 commit"
            )
            h.commitCurrentTurn()
            XCTAssertEqual(h.session.turnPhase, .thinking)

            h.emitPlaybackStarted(responseId: "resp-\(round)")
            XCTAssertEqual(h.session.turnPhase, .speaking)

            h.emitPlaybackEnded(responseId: "resp-\(round)")
            // 最后一轮播完后同样自动回到聆听——这正是「不再每轮按键」。
            XCTAssertEqual(h.session.turnPhase, .listening, "第 \(round) 轮播完后应自动回到聆听")
        }

        // ── 验收 1：conversation_id 五轮不变 ──
        let conversationIds = Set(h.startedTurns.prefix(rounds).map(\.conversationId))
        XCTAssertEqual(conversationIds.count, 1, "连续多轮的 conversation_id 必须不变：\(conversationIds)")
        XCTAssertNotNil(conversationIds.first ?? nil)

        // ── 验收 2：turn_id 逐轮新铸、互不相同、时间戳不倒退 ──
        //
        // 口径说明（不夸大断言强度）：`Shared/UUIDv7.swift:6-12` 的实现在
        // **同一毫秒内没有单调计数器**（低位是纯随机），因此同毫秒铸造的两个
        // turn_id 之间不存在可断言的字典序大小关系。可断言且真正有意义的是：
        // 每轮新铸（互不相同）、时间戳分量不倒退、会话回合序号严格递增。
        // 同毫秒内的字典序单调需要给 UUIDv7 加序列计数器，超出本单范围，
        // 按 R-01.2 另行提单，不在这里顺手改。
        let turnIds = h.startedTurns.prefix(rounds).map(\.turnId)
        XCTAssertEqual(Set(turnIds).count, rounds, "每轮必须新铸 turn_id，不得复用：\(turnIds)")
        let stamps = turnIds.compactMap { UUID(uuidString: $0).map(UUIDv7.timestampMs(of:)) }
        XCTAssertEqual(stamps.count, rounds, "turn_id 必须是合法 UUID")
        XCTAssertEqual(stamps, stamps.sorted(), "turn_id 的时间戳分量不得倒退：\(stamps)")
        XCTAssertEqual(h.session.turnIndex, rounds + 1, "会话回合序号应递增到第 \(rounds + 1) 轮")

        // ── 验收 3：每轮事件顺序 100% 正确、每轮恰好一次 ──
        let chain = h.log.events(matching: [
            "speech_final", "session_turn_committed", "play_started", "play_finished",
            "session_answer_started", "session_answer_finished", "session_next_listening",
        ])
        XCTAssertEqual(h.log.count(of: "speech_final"), rounds, "每轮恰好一次 VAD 断句")
        XCTAssertEqual(h.log.count(of: "play_started"), rounds, "每轮恰好一次真实起播")
        XCTAssertEqual(h.log.count(of: "play_finished"), rounds, "每轮恰好一次真实播完")
        XCTAssertEqual(h.log.count(of: "session_turn_committed"), rounds)
        XCTAssertEqual(h.log.count(of: "session_answer_started"), rounds)
        XCTAssertEqual(h.log.count(of: "session_answer_finished"), rounds)
        XCTAssertEqual(
            h.log.count(of: "session_next_listening"), rounds + 1,
            "首轮就绪 1 次 + 每轮播完自动回聆听 \(rounds) 次"
        )
        assertOrderedPerTurn(h: h, rounds: rounds)

        // ── 验收 4：旧音频零补播 ──
        XCTAssertEqual(h.log.count(of: "stale_playback_dropped"), 0, "正常五轮不应出现迟到播放事件")
        XCTAssertEqual(h.log.count(of: "session_stale_turn_event"), 0)

        // R-02.1 证据落盘：把关联事件流打进测试输出，便于收口时贴原文。
        print("=== ESS-600 五轮关联事件流（watchOS 模拟器运行时）===")
        print("conversation_id=\(conversationIds.first.flatMap { $0 } ?? "nil")")
        for line in chain { print(line) }
        print("=== 事件流结束（共 \(chain.count) 条）===")
    }

    /// 每轮内部顺序，全部按 request_id 归属该轮：
    /// VAD 断句 → 上行提交 → 真实起播 → 进入回答 → 真实播完 → 回答结束。
    /// 「真实起播必须早于进入回答相位」正是阻断 2 要钉的口径——相位不得
    /// 跑在真实播放事件前面。
    private static let expectedTurnChain = [
        "speech_final", "session_turn_committed",
        "play_started", "session_answer_started",
        "play_finished", "session_answer_finished",
    ]

    private func assertOrderedPerTurn(h: Harness, rounds: Int) {
        for (index, turn) in h.startedTurns.prefix(rounds).enumerated() {
            let ordered = h.log.entries
                .filter { $0.requestId == turn.requestId }
                .map(\.event)
                .filter { Self.expectedTurnChain.contains($0) }
            XCTAssertEqual(
                ordered, Self.expectedTurnChain,
                "第 \(index + 1) 轮（request_id=\(turn.requestId)）事件顺序错乱：\(ordered)"
            )
        }
    }

    /// 旧回合的迟到 `.ended` 绝不能推进下一轮——否则用户还没开口，会话就
    /// 已经「替他说完了」，正是「旧音频零补播」这条验收要挡的事故。
    func testLatePlaybackEventFromPreviousTurnIsDropped() {
        let h = makeHarness()
        h.startFirstTurn()
        let staleTurn = h.startedTurns[0]

        h.commitCurrentTurn()
        h.emitPlaybackStarted()
        h.emitPlaybackEnded()          // 第 1 轮正常收尾 → 已经进入第 2 轮
        XCTAssertEqual(h.startedTurns.count, 2)
        let turnsBefore = h.startedTurns.count

        // 第 1 轮的迟到 `.ended` 现在才到。
        h.player.emit(.ended(
            requestId: staleTurn.requestId, sessionId: staleTurn.sessionId,
            responseId: "late", bytesPlayed: 4_096
        ))

        XCTAssertEqual(h.startedTurns.count, turnsBefore, "迟到事件不得开启新一轮")
        XCTAssertEqual(h.session.turnPhase, .listening, "第 2 轮仍应停在聆听等用户开口")
        XCTAssertEqual(h.log.count(of: "stale_playback_dropped"), 1, "迟到事件必须留证")
    }

    /// 一个回合可携带多个 response。被更新 response 顶掉的旧 response 也会
    /// 发 `.ended`（`RealtimePlaybackReceiptTracker` 的 superseded 分支）——
    /// 拿它开下一轮，用户还没听到新回答就被重新开麦了。
    func testSupersededResponseEndedDoesNotAdvanceTurn() {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()
        h.ingestDownlink(responseId: "resp-1")
        h.emitPlaybackStarted(responseId: "resp-1")
        // 新 response 接棒，旧 response 随后才把尾巴播完。
        h.ingestDownlink(responseId: "resp-2")

        h.emitPlaybackEnded(responseId: "resp-1")

        XCTAssertEqual(h.session.turnPhase, .speaking, "旧 response 播完不代表本轮答完")
        XCTAssertEqual(h.startedTurns.count, 1, "不得据此开下一轮")
        XCTAssertEqual(h.log.count(of: "superseded_response_ended"), 1)

        // 当前 response 播完才算答完。
        h.emitPlaybackEnded(responseId: "resp-2")
        XCTAssertEqual(h.session.turnPhase, .listening)
        XCTAssertEqual(h.startedTurns.count, 2)
    }

    // MARK: - 手动打断（F4）

    func testOrbTapDuringSpeakingStopsPlaybackAndRelistens() throws {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()
        h.emitPlaybackStarted()
        XCTAssertEqual(h.session.turnPhase, .speaking)

        h.session.interruptSpeaking()

        XCTAssertEqual(h.interruptCount, 1, "打断必须真的停播")
        XCTAssertEqual(h.session.turnPhase, .listening)
        XCTAssertEqual(h.startedTurns.count, 2, "打断后直接开下一轮")
        XCTAssertEqual(h.log.count(of: "session_speaking_interrupted"), 1)

        // ESS-655（F6）：打断事件必须带 source / detect_ms / stop_ms，且
        // 这条**真实运行时事件**要能过 schema 校验——语音打断（F2）接进来后
        // 误触发率就靠 source 分流，字段漂了当场就该红。
        let interrupted = h.log.last(of: "session_speaking_interrupted")
        let fields = try XCTUnwrap(
            try? PhoneModeTelemetry.validate(
                event: "session_speaking_interrupted", detail: interrupted?.detail
            )
        )
        XCTAssertEqual(fields["source"], "orb_tap")
        XCTAssertEqual(fields["detect_ms"], "0", "点球没有检测过程")
        XCTAssertNotNil(fields["stop_ms"].flatMap(Int.init), "停播耗时必须是可统计的整数毫秒")
        XCTAssertEqual(
            interrupted?.requestId, h.startedTurns.first?.requestId,
            "打断记在**被打断的那一轮**头上，不是打断后新开的那轮"
        )
    }

    /// 非 speaking 相位点球无语义——不许把「正在听」误打断成新一轮，
    /// 那会把用户说到一半的话丢掉。
    func testOrbTapOutsideSpeakingIsIgnored() {
        let h = makeHarness()
        h.startFirstTurn()
        h.session.interruptSpeaking()
        XCTAssertEqual(h.interruptCount, 0)
        XCTAssertEqual(h.startedTurns.count, 1)

        h.commitCurrentTurn()          // thinking
        h.session.interruptSpeaking()
        XCTAssertEqual(h.interruptCount, 0)
        XCTAssertEqual(h.session.turnPhase, .thinking)
    }

    // MARK: - 零提交回合与超时兜底

    /// 说得太短 → 本轮零提交。会话必须退避后重开采集，不能停在死麦克风上。
    func testAbortedTurnRelistensAfterBackoff() {
        let h = makeHarness()
        h.startFirstTurn()

        h.pushToTalk.onSessionTurnAborted?(h.currentRequestId, "too_short")

        XCTAssertEqual(h.session.turnPhase, .idle, "退避窗口内不假装在听")
        XCTAssertEqual(h.startedTurns.count, 1, "退避未到不得开轮（Watch 无 AEC，会自激）")
        XCTAssertEqual(h.log.count(of: "session_turn_aborted"), 1)

        h.fireScheduled(withDelay: SessionController.abortedTurnRelistenDelaySeconds)

        XCTAssertEqual(h.session.turnPhase, .listening)
        XCTAssertEqual(h.startedTurns.count, 2)
    }

    /// 回答永不到达时不许无限等：到点如实报错、回到聆听，让用户能再说一遍。
    /// ESS-652: thinking timeout now enters P6 failed, not back to listening.
    func testThinkingTimeoutEntersFailed() {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()
        XCTAssertEqual(h.session.turnPhase, .thinking)

        h.fireScheduled(withDelay: SessionController.thinkingHardTimeoutSeconds)

        XCTAssertEqual(h.session.state, .failed)
        XCTAssertEqual(h.log.count(of: "session_thinking_hard_timeout"), 1)
    }

    // MARK: - ready 超时不丢已录语音

    /// 用户已经对着表说了 5 秒，realtime 快通道没通不等于话没法送达——
    /// 超时必须先把已录音频经可靠通道抢救出去，再报失败退出。
    func testReadyTimeoutSalvagesCapturedSpeechBeforeFailing() {
        let h = makeHarness()
        var salvaged = 0
        h.session.onSalvageTurn = { salvaged += 1 }

        h.session.enterSession()
        h.session.markLocalCapture(active: true)   // 采集真的起来了
        h.fireScheduled(withDelay: SessionController.readyTimeoutSeconds)

        XCTAssertEqual(salvaged, 1, "已录语音必须被抢救提交，不能无反馈丢弃")
        XCTAssertEqual(h.log.count(of: "session_ready_timeout_salvage"), 1)
        // ESS-869：就绪超时升格为缺陷信号——出现即计数并标红（error 级 + 错误码）。
        XCTAssertEqual(h.session.readyTimeoutSalvageCount, 1, "缺陷必须计数")
        let salvage = h.log.last(of: "session_ready_timeout_salvage")
        XCTAssertTrue(
            salvage?.detail?.contains("salvage_count=1") == true,
            "salvage 事件必须带计数，否则无法按会话聚合"
        )
        XCTAssertEqual(salvage?.errorCode, "ERR_SESSION_READY_TIMEOUT", "缺陷信号必须有稳定错误码")
        // ESS-652: after salvage, enters P6 failed, not idle.
        XCTAssertEqual(h.session.state, .failed)
        XCTAssertNotNil(h.session.failedReason)
    }

    /// ESS-869 acceptance §4：挂断小结必须把就绪超时降级次数汇总进会话日志，
    /// 让「实时链路降级」成为可 grep、可聚合的缺陷信号，而不是静默兜底。
    func testCallSummarySurfacesReadyTimeoutSalvageCount() {
        let h = makeHarness()
        h.session.onSalvageTurn = {}

        h.session.enterSession()
        h.session.markLocalCapture(active: true)
        h.fireScheduled(withDelay: SessionController.readyTimeoutSeconds)
        XCTAssertEqual(h.session.readyTimeoutSalvageCount, 1)

        // P6 挂断 → P7 小结。
        h.session.hangupFromFailed()

        let summary = h.log.last(of: "session_call_summary")
        XCTAssertTrue(
            summary?.detail?.contains("ready_timeout_salvage_count=1") == true,
            "挂断小结必须带 ready_timeout_salvage_count，否则缺陷被当正常兜底"
        )
        XCTAssertTrue(
            h.session.hungupSummary?.contains("实时链路降级 1 次") == true,
            "有降级时挂断摘要必须如实告知用户"
        )
    }

    /// 干净会话（实时链路正常建立）不得误报降级：计数为 0、小结不带降级文案。
    func testCleanSessionDoesNotCountSalvage() {
        let h = makeHarness()
        h.startFirstTurn()   // 通道真实就绪，不会触发 ready 超时

        h.session.exitSession()

        XCTAssertEqual(h.session.readyTimeoutSalvageCount, 0)
        let summary = h.log.last(of: "session_call_summary")
        XCTAssertTrue(
            summary?.detail?.contains("ready_timeout_salvage_count=0") == true,
            "干净会话也必须带 ready_timeout_salvage_count=0，才能区分「无缺陷」与「没记录」"
        )
        XCTAssertFalse(
            h.session.hungupSummary?.contains("实时链路降级") == true,
            "干净会话不得出现降级文案"
        )
    }

    /// 本地采集态与网络 ready 独立呈现：建立中就能如实显示「表在听」。
    func testLocalCaptureStateIsIndependentOfChannelReady() {
        let h = makeHarness()
        h.session.enterSession()
        XCTAssertEqual(h.session.state, .connecting)

        h.session.markLocalCapture(active: true)
        XCTAssertTrue(h.session.isCapturingLocally, "网络没就绪不代表麦克风没在采")
        XCTAssertEqual(h.session.state, .connecting, "本地采集态不得反过来伪造网络就绪")
    }

    // MARK: - 退出

    func testExitClosesConversationAndResetsTurnState() {
        let h = makeHarness()
        h.startFirstTurn()
        h.commitCurrentTurn()

        h.session.exitSession()

        // ESS-652: exitSession → P7 hungup, not idle.
        XCTAssertEqual(h.session.state, .hungup)
        XCTAssertEqual(h.session.turnPhase, .idle)
        XCTAssertNil(h.session.activeTurnRequestId)
        XCTAssertEqual(h.session.turnIndex, 0)
        XCTAssertFalse(h.session.isCapturingLocally)
    }

    /// 退出后旧回合的迟到播放事件不得复活会话。
    func testEventsAfterExitAreIgnored() {
        let h = makeHarness()
        h.startFirstTurn()
        let turn = h.startedTurns[0]
        h.commitCurrentTurn()
        h.session.exitSession()
        let turnsBefore = h.startedTurns.count

        h.pushToTalk.onSessionAnswerStarted?(turn.requestId)
        h.pushToTalk.onSessionAnswerFinished?(turn.requestId, true, "late")

        XCTAssertEqual(h.session.turnPhase, .idle)
        XCTAssertEqual(h.startedTurns.count, turnsBefore, "退出后不得再开轮")
    }

    // MARK: - Harness

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SessionAutoRelistenTests.\(UUID().uuidString)")!
    }

    /// 装了替身 adapter 的真实 `PushToTalkController`。不能用
    /// `ensureRealtimeAdapter()`：它会构造真实 `RealtimePlaybackEngine`，
    /// 其 `AVAudioEngine.SetFormat` 在无音频硬件的 hosted CI 上直接 -10868
    /// （ESS-498 家族，本单二轮 CI 实证）。经 `useRealtimeAdapterForTests`
    /// 注入后，`beginSessionConversation()` 走的仍是**生产那一段代码**。
    /// 模拟一次 touch-down：走生产入口 `pressBegan()` 置起 ESS-642 的边界闸门
    /// 与 `streamRequestId`（两者都在 `pressBegan` 同步段完成）。
    ///
    /// 期间**临时关掉流式开关**：`pressBegan` 的异步 Task 在 streaming 为真时会
    /// `ensureConversationAudioAcquired()` → 真实 `AVAudioEngine.start()`，无音频
    /// 设备的环境下这会抛不可捕获的 ObjC 异常直接杀进程
    /// （`AVAudioEngineGraph.mm:Initialize: (inputNode != nullptr || outputNode != nullptr)`，
    /// ESS-362/488 家族——本单第一版就是这样把整个 xctest 宿主跑挂的）。
    /// 关掉后该分支整段跳过，同步段的两个前置照常建立。
    @discardableResult
    private func simulateTouchDown(on controller: PushToTalkController) -> String? {
        controller.voiceStreamingEnabled = { false }
        defer { controller.voiceStreamingEnabled = { true } }
        return controller.pressBegan()
    }

    private func makeControllerWithMockAdapter() -> (PushToTalkController, WatchRealtimeMediaAdapter) {
        let controller = PushToTalkController()
        controller.voiceStreamingEnabled = { true }
        // 无音频硬件环境下不得触发会话级引擎起停（同上，ESS-362/488 家族）。
        controller.conversationAudioEnabled = { false }
        let adapter = WatchRealtimeMediaAdapter(
            recorder: MockRecorder(), player: MockPlayer(), transport: MockTransport(),
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: true
        )
        controller.useRealtimeAdapterForTests(adapter)
        return (controller, adapter)
    }

    private func makeHarness() -> Harness {
        let harness = Harness(defaults: freshDefaults())
        addTeardownBlock { @MainActor in harness.tearDown() }
        return harness
    }

    /// 会话闭环测试台。生产成分：`SessionController`、`WatchRealtimeMediaAdapter`、
    /// `RealtimeMediaSession`（conversation/turn id 的唯一铸造点）、
    /// `PushToTalkController` 的两段接线本体。替身只有 recorder/player/transport
    /// 三个 adapter 已有的注入缝，以及「起轮时真正开麦」那一步。
    @MainActor
    final class Harness {
        let session: SessionController
        let pushToTalk = PushToTalkController()
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let adapter: WatchRealtimeMediaAdapter
        let log = LogCapture()

        private(set) var startedTurns: [RealtimeMediaSession.TurnHandle] = []
        private(set) var interruptCount = 0
        private var scheduled: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []

        var currentRequestId: String { startedTurns.last?.requestId ?? "" }

        init(defaults: UserDefaults) {
            session = SessionController(defaults: defaults)
            adapter = WatchRealtimeMediaAdapter(
                recorder: recorder,
                player: player,
                transport: transport,
                vadConfiguration: LocalVADConfiguration(),
                automaticallyCommitOnSpeechFinal: true
            )
            log.install()

            // 生产接线本体（不是副本）。
            SessionTurnWiring.connect(session: session, pushToTalk: pushToTalk, interruptSelfCheck: {})
            pushToTalk.attachSessionEvents(to: adapter)

            // 计时器接缝：零睡眠、手动触发。
            session.scheduleDelay = { [weak self] delay, fire in
                self?.scheduled.append((delay, fire))
                return NoopDelayToken()
            }
            session.playHaptic = { _ in }
            // 起轮替身：真开麦在无音频硬件的 CI 上会挂（ESS-498），这里直接
            // 调 `pressBegan` 内部调的同一个方法。这是本测试台唯一的替身环节。
            adapter.beginConversation()
            session.onBeginChannel = { [weak self] in self?.beginTurn() }
            session.onStartTurn = { [weak self] in self?.beginTurn() }
            session.onInterruptSpeaking = { [weak self] _ in
                guard let self else { return false }
                self.interruptCount += 1
                self.adapter.bargeIn()
                // ESS-650：停播确认与生产同源——读播放器的真实渲染状态。
                return !self.adapter.isRenderingDownlink
            }
            session.onTeardownChannel = { [weak self] in self?.adapter.closeConversation() }
        }

        func tearDown() {
            log.uninstall()
        }

        private func beginTurn() -> String? {
            let requestId = UUIDv7.generate().uuidString.lowercased()
            let handle = adapter.beginTurn(requestId: requestId)
            startedTurns.append(handle)
            return handle.requestId
        }

        /// 进入会话并让通道**真实**就绪：喂 PCM → adapter 真的发出 audio.append →
        /// 对端 ack 那一个真实 chunk。就绪不能靠伪造 ack——`acknowledge` 会校验
        /// sequence 与字节数是否对得上真正发出去的帧，对不上直接拒收。
        func startFirstTurn() {
            session.enterSession()
            guard let handle = startedTurns.last else { return XCTFail("第一轮未起") }
            for _ in 0..<8 { recorder.feed(Self.pcmFrame(rms: 0)) }
            guard let chunk = transport.appendEvents.last else {
                return XCTFail("上行未产生任何 audio.append，无法构造真实 ack")
            }
            adapter.receiveUplinkAck(RealtimeUplinkAck(
                requestId: handle.requestId, sessionId: handle.sessionId,
                sequence: chunk.sequence, byteCount: chunk.payload.count
            ))
            XCTAssertEqual(session.state, .listening, "首个真实 ack 后应就绪")
        }

        /// 生产里由 `submit(recording:)` 末尾发出的同一个回调。
        func commitCurrentTurn() {
            pushToTalk.onSessionTurnCommitted?(currentRequestId)
        }

        /// 走真实下行入口，让 adapter 记住当前 response_id。
        func ingestDownlink(responseId: String) {
            guard let handle = startedTurns.last else { return }
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: 0,
                    capturedAtMs: 0, codec: "pcm16", sampleRate: 16_000,
                    payload: Data(count: 320), endOfStream: false
                ),
                responseId: responseId
            )
        }

        func emitPlaybackStarted(responseId: String = "resp") {
            guard let handle = startedTurns.last else { return }
            player.emit(.started(
                requestId: handle.requestId, sessionId: handle.sessionId, responseId: responseId
            ))
        }

        func emitPlaybackEnded(responseId: String = "resp", bytesPlayed: Int = 32_000) {
            guard let handle = startedTurns.last else { return }
            player.emit(.ended(
                requestId: handle.requestId, sessionId: handle.sessionId,
                responseId: responseId, bytesPlayed: bytesPlayed
            ))
        }

        func emitPlaybackFailed(code: String) {
            guard let handle = startedTurns.last else { return }
            player.emit(.failed(
                requestId: handle.requestId, sessionId: handle.sessionId,
                responseId: nil, code: code
            ))
        }

        /// 喂真实 PCM 走真实 VAD：先补足回答播完后的静默守卫窗（Watch 无 AEC，
        /// 守卫跨回合保留），再说话，再静默到断句。
        func speakUntilVADFinal() {
            for _ in 0..<5 { recorder.feed(Self.pcmFrame(rms: 0)) }        // 守卫窗
            for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0.08)) }     // 说话
            for _ in 0..<9 { recorder.feed(Self.pcmFrame(rms: 0)) }        // 静默断句
        }

        /// 触发某个已排期的延迟闭包（按 delay 匹配最新的一个）。
        func fireScheduled(withDelay delay: TimeInterval) {
            guard let index = scheduled.lastIndex(where: { abs($0.delay - delay) < 0.001 }) else {
                return XCTFail("没有排期为 \(delay)s 的延迟任务；已排期：\(scheduled.map(\.delay))")
            }
            let fire = scheduled[index].fire
            scheduled.remove(at: index)
            fire()
        }

        /// 100ms / 帧（16kHz PCM16，1600 样本）。
        static func pcmFrame(rms: Double) -> Data {
            var sample = Int16((rms * Double(Int16.max)).rounded()).littleEndian
            let bytes = withUnsafeBytes(of: &sample) { Data($0) }
            var data = Data(capacity: 3_200)
            for _ in 0..<1_600 { data.append(bytes) }
            return data
        }
    }

    // MARK: - 运行时日志抓取（R-02.1 证据来源）

    /// `WatchLog.setObserver` 抓的是**真实**运行时事件——生产代码调
    /// `WatchLog.info/error` 时同步回调，不是测试自己拼的字符串。
    final class LogCapture: @unchecked Sendable {
        struct Entry {
            let module: String
            let event: String
            let requestId: String?
            let detail: String?
            let errorCode: String?
        }

        private let lock = NSLock()
        private var storage: [Entry] = []

        var entries: [Entry] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func install() {
            WatchLog.setObserver { [weak self] module, event, requestId, detail, code in
                self?.append(Entry(
                    module: module, event: event, requestId: requestId,
                    detail: detail, errorCode: code
                ))
            }
        }

        func uninstall() { WatchLog.setObserver(nil) }

        private func append(_ entry: Entry) {
            lock.lock(); defer { lock.unlock() }
            storage.append(entry)
        }

        func count(of event: String) -> Int {
            entries.filter { $0.event == event }.count
        }

        func last(of event: String) -> Entry? {
            entries.last { $0.event == event }
        }

        func events(matching names: [String]) -> [String] {
            entries
                .filter { names.contains($0.event) }
                .map { "\($0.module)/\($0.event) | \($0.detail ?? "-")" }
        }
    }

    // MARK: - Adapter 注入缝替身

    final class MockRecorder: WatchRealtimeMediaAdapter.Recorder {
        var onFrame: ((Data) -> Void)?
        var onFailure: ((Error) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start() throws { startCount += 1 }
        func stop() { stopCount += 1 }
        func feed(_ data: Data) { onFrame?(data) }
    }

    final class MockPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        private(set) var preparedTurns: [RealtimeMediaSession.TurnHandle] = []
        private(set) var stoppedCount = 0
        private(set) var bargedInBytes: [Int] = []
        /// ESS-650：与真实引擎同语义——入队即出声，`bargeIn`/`stop` 即静音。
        private(set) var isRenderingDownlink = false

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws { preparedTurns.append(turn) }
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
            if !playables.isEmpty { isRenderingDownlink = true }
        }
        func bargeIn(clearedBytes: Int) {
            bargedInBytes.append(clearedBytes)
            isRenderingDownlink = false
        }
        func finish(responseId: String?) {}
        func stop(barge: Bool) {
            stoppedCount += 1
            isRenderingDownlink = false
        }

        /// 播放引擎发出真实事件。语义与 `RealtimePlaybackEngine` 一致：
        /// `.started` = 首帧已渲染；`.ended` = 最后一个排队 buffer 已渲染。
        func emit(_ event: RealtimePlaybackEngine.PlaybackEvent) { onPlaybackEvent?(event) }
    }

    final class MockTransport: WatchRealtimeMediaAdapter.Transport {
        private(set) var startEvents: [RealtimeStreamStart] = []
        private(set) var appendEvents: [VoiceStreamChunk] = []
        private(set) var commitEvents: [RealtimeStreamCommit] = []
        private(set) var playbackStarted: [(RealtimeMediaSession.TurnHandle, String)] = []
        private(set) var playbackEnded: [(RealtimeMediaSession.TurnHandle, String, Int)] = []
        private(set) var bargeInRequests: [RealtimeBargeInRequest] = []

        func sendStreamStart(_ start: RealtimeStreamStart, conversationId: String?, turnId: String?) {
            startEvents.append(start)
        }
        func sendAudioAppend(_ chunk: VoiceStreamChunk, conversationId: String?, turnId: String?) {
            appendEvents.append(chunk)
        }
        func sendAudioCommit(_ commit: RealtimeStreamCommit, conversationId: String?, turnId: String?) {
            commitEvents.append(commit)
        }
        func sendPlaybackStarted(handle: RealtimeMediaSession.TurnHandle, responseId: String) {
            playbackStarted.append((handle, responseId))
        }
        func sendPlaybackEnded(handle: RealtimeMediaSession.TurnHandle, responseId: String, bytesPlayed: Int) {
            playbackEnded.append((handle, responseId, bytesPlayed))
        }
        func fallbackToCompleteFile(handle: RealtimeMediaSession.TurnHandle,
                                    reason: RealtimeUplinkStream.FallbackReason) {}
        func sendBargeInRequest(_ request: RealtimeBargeInRequest) {
            bargeInRequests.append(request)
        }
    }

    private final class NoopDelayToken: SessionDelayToken {
        func cancel() {}
    }
}
