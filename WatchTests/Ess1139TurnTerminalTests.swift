import XCTest
@testable import WristAgent_Watch_App

/// ESS-1139：**阶段播报的回合级 `audio.done` 不得把一个还在跑的委派任务
/// 收口**。
///
/// 复现基线是 2026-09-05 的真机取证，三条用例同一个形态：
///   • 天气：任务正常进入 Codex，约 10s 出首答案；客户端在**任务启动后
///     1.2s** 关闭 WSS，其后所有帧被上游按 `socket_closed` 丢弃；
///   • 知识库：任务 4.75s 就有首答案，客户端 11.5s 关闭 WSS；
///   • 两条链路都在阶段播报之后出现 `mute` / `socket_closed`。
///
/// 客户端这一侧的因果链是确定的：阶段播报的回合级 `audio.done` 到达 →
/// 播放屏障释放 → `markAnswerFinished` → ESS-1097 的工具闸门此刻**还没拿到
/// 任何 `task.state`**（WCSession 这一跳不保证跨消息顺序）→ 判本轮已答完 →
/// 开下一轮 → 新 request_id 让 iPhone `openIfNeeded` supersede → 关掉一条
/// 上游任务还在跑的 WSS。
///
/// 修法不是加等待，而是**把判据搬到顺序有保证的那一侧**：iPhone 在有序 WSS
/// 上就地判定「这条终态到达时上游还有没有活」，随帧下发
/// (`upstream_work_outstanding`)。本套件钉住 Watch 侧消费这条判据之后的
/// 行为——终态被判为段落时回合必须继续等，判为真终态时必须一秒不多等地收口。
///
/// socket 侧那一半（关闭动因分类、上游工作账本、有界性）在
/// `Tests/Ess1139SocketLifetimeTests.swift`，走 `swift test`。
@MainActor
final class Ess1139TurnTerminalTests: XCTestCase {

    private static let taskId = "work_a8f61916-3b05-4831-9122-355f613365d3"
    /// 真机上客户端关闭 WSS 的时刻，相对任务启动。
    private static let weatherCloseSeconds: TimeInterval = 1.2
    private static let vaultCloseSeconds: TimeInterval = 11.5

    private var controller: SessionController!
    private var clock: VirtualSessionClock!
    private var defaults: UserDefaults!
    private var startTurnCount = 0
    private var teardownCount = 0

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess1139TurnTerminalTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        clock = VirtualSessionClock()
        startTurnCount = 0
        teardownCount = 0
        controller.playHaptic = { _ in }
        controller.scheduleDelay = { [clock] delay, fire in clock!.schedule(delay: delay, fire: fire) }
        controller.onBeginChannel = { "req-1139-turn-1" }
        controller.onStartTurn = { [weak self] in
            self?.startTurnCount += 1
            return "req-1139-turn-2"
        }
        controller.onTeardownChannel = { [weak self] in self?.teardownCount += 1 }
    }

    override func tearDown() {
        controller = nil
        clock = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 事故复现

    /// 天气用例，**零 `task.state` 版本**——这是本单最强的一条断言。
    ///
    /// 整段时间线里 Watch 一帧 `task.state` 都没收到（真机上它们被 WCSession
    /// 排在了终态后面）。旧路径在阶段播报播完那一瞬间就开下一轮；现在唯一的
    /// 判据是 iPhone 随终态下发的 `upstream_work_outstanding`，会话必须一路
    /// 活过 1.2s 事故点，直到真终态到达才收口。
    func testAnnouncementTerminalWithUpstreamWorkNeverOpensTheNextTurn() {
        let requestId = beginTurn()

        // 阶段播报起播。
        controller.markAnswerStarted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .speaking)

        // iPhone 在有序 WSS 上判定：这条终态到达时上游还有活在跑。
        deliverTurnTerminal(requestId, upstreamWorkOutstanding: true)
        XCTAssertEqual(controller.turnPhase, .thinking, "段落播完退回等待态，不是收口")
        XCTAssertEqual(startTurnCount, 0, "上游还有活 ⇒ 绝不允许开下一轮")

        // 推到真机关闭 WSS 的那一刻，再推到首答案产出的 10s：都不许动。
        clock.advance(to: Self.weatherCloseSeconds)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .thinking)
        XCTAssertEqual(startTurnCount, 0, "任务仍在跑，绝不允许开下一轮")
        XCTAssertEqual(teardownCount, 0, "更不允许拆通道")

        clock.advance(to: 10)
        XCTAssertEqual(startTurnCount, 0, "10s 首答案之前一轮都不许开")
        XCTAssertNil(controller.failedReason, "既不许开轮，也不许判失败")

        // 真正的答案到达并播完，终态这次带着「上游没活了」。
        controller.markAnswerStarted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .speaking)
        deliverTurnTerminal(requestId, upstreamWorkOutstanding: false)

        XCTAssertEqual(controller.turnPhase, .listening, "真终态 ⇒ 收口")
        XCTAssertEqual(startTurnCount, 1, "收口之后开且只开一轮")
        XCTAssertNil(controller.failedReason)
    }

    /// 知识库用例：首答案 4.75s，真机在 11.5s 关闭。会话必须跨过那个点。
    func testVaultIncidentSessionSurvivesTheElevenPointFiveSecondClosePoint() {
        let requestId = beginTurn()
        controller.markAnswerStarted(requestId: requestId)
        deliverTurnTerminal(requestId, upstreamWorkOutstanding: true)

        for second in 1...12 {
            clock.advance(to: TimeInterval(second))
            XCTAssertEqual(controller.state, .listening, "第 \(second) 秒：会话不得退出")
            XCTAssertEqual(controller.turnPhase, .thinking, "第 \(second) 秒：不得回到聆听")
            XCTAssertEqual(startTurnCount, 0, "第 \(second) 秒：不得开下一轮")
            XCTAssertNil(controller.failedReason, "第 \(second) 秒：不得判失败")
        }
        XCTAssertGreaterThan(TimeInterval(12), Self.vaultCloseSeconds, "夹具确实跨过了事故点")
    }

    /// 同一条终态若同时带着真实 `task.state`，两条证据必须收敛到同一结论，
    /// 不得互相抵消（任务终结之后才允许收口）。
    func testTaskStateAndTerminalFlagAgree() {
        let requestId = beginTurn()
        emit(requestId, status: "running")
        controller.markAnswerStarted(requestId: requestId)
        deliverTurnTerminal(requestId, upstreamWorkOutstanding: true)
        XCTAssertEqual(startTurnCount, 0)

        emit(requestId, status: "completed")
        XCTAssertEqual(startTurnCount, 0, "任务终结了，但回合屏障还没落定")

        controller.markAnswerStarted(requestId: requestId)
        deliverTurnTerminal(requestId, upstreamWorkOutstanding: false)
        XCTAssertEqual(startTurnCount, 1)
    }

    /// 上游真的静默：必须有界收口成**明确终态**，不得永远停在「正在思考」。
    func testHeldTurnIsStillBounded() {
        let requestId = beginTurn()
        controller.markAnswerStarted(requestId: requestId)
        deliverTurnTerminal(requestId, upstreamWorkOutstanding: true)

        clock.advance(to: SessionController.taskActivityTimeoutSeconds - 1)
        XCTAssertNil(controller.failedReason, "预算未到点前不得放弃")

        clock.advance(to: SessionController.taskActivityTimeoutSeconds + 0.5)
        XCTAssertEqual(controller.state, .failed, "静默到点必须给明确终态")
        XCTAssertNotNil(controller.failedReason)
        XCTAssertEqual(startTurnCount, 0, "失败路径上绝不允许悄悄开麦")
    }

    // MARK: - 不伤害主链路

    /// 普通回合（终态明确说明上游没活了）：**同步**收口并开下一轮，不多等
    /// 一毫秒。ESS-600 / ESS-652 的自动重新聆听契约一个字都不能改。
    func testPlainTurnStillRelistensSynchronously() {
        let requestId = beginTurn()
        controller.markAnswerStarted(requestId: requestId)
        deliverTurnTerminal(requestId, upstreamWorkOutstanding: false)

        XCTAssertEqual(startTurnCount, 1, "播完必须当场自动开下一轮")
        XCTAssertEqual(controller.turnPhase, .listening)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertNil(controller.failedReason)
    }

    /// 字段缺席（滚动升级窗口内的老 iPhone 进程）：行为与本单之前逐字相同。
    /// 缺一个字段不得让会话卡住——那是把一个 bug 换成另一个。
    func testMissingFlagFallsBackToLegacyBehaviour() {
        let requestId = beginTurn()
        controller.markAnswerStarted(requestId: requestId)
        controller.markAnswerFinished(requestId: requestId)

        XCTAssertEqual(startTurnCount, 1, "没有分类字段时按老路径当场开下一轮")
        XCTAssertEqual(controller.turnPhase, .listening)
    }

    // MARK: - 夹具

    private func beginTurn() -> String {
        controller.enterSession()
        controller.markChannelReady()
        let requestId = controller.activeTurnRequestId!
        controller.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(controller.turnPhase, .thinking)
        return requestId
    }

    /// 照抄 `WatchSettingsStore.applyRealtimeDownlink` 的 `.audioDone` 分支在
    /// 会话层留下的**两跳**：先落工具证据、再落屏障/播放收口。
    ///
    /// 顺序就是生产顺序，且它本身是被断言的一部分——反过来的话屏障释放那一瞬间
    /// 聚合体还看不到工具工作，`markAnswerFinished` 又会开下一轮。
    private func deliverTurnTerminal(_ requestId: String, upstreamWorkOutstanding: Bool) {
        controller.markTaskState(
            requestId: requestId, taskId: nil,
            status: upstreamWorkOutstanding ? "tool_call_pending" : "tool_call_resolved"
        )
        if upstreamWorkOutstanding {
            controller.markAnswerInterim(requestId: requestId)
        } else {
            controller.markAnswerFinished(requestId: requestId)
        }
    }

    private func emit(_ requestId: String, status: String) {
        controller.markTaskState(requestId: requestId, taskId: Self.taskId, status: status)
    }
}
