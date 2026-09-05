import XCTest
@testable import WristAgent

/// ESS-1139 复审整改（毕玄 2026-09-05 阻断）：**hold 必须是原子的**。
///
/// 阻断原文指的是 `PhoneRealtimeSession.endTurn`：`closeCurrentTransport` 因
/// 上游任务仍在飞而返回 hold 之后，旧代码仍无条件 `transition(to: .cancelled)`
/// 并清空 `currentTransport` 与 `pendingDownlink`。socket 物理上没关，会话层
/// 却已经把它丢了——后续回调被两道身份闸门（`currentTransport === transport`
/// 与 `case .active`）双双拒掉，结果比直接关掉更糟：socket 还占着，答案一样
/// 送不到。
///
/// 这个缺陷在 `Shared/` 的纯策略用例里**结构上看不见**：策略给出的裁决是对的，
/// 错的是会话层怎么用它。因此本套件不是又一条策略用例，而是 iOS 侧第一个
/// 单测 target 里的**会话级**回归——直接驱动 `PhoneRealtimeSession` 本体，
/// 断言 hold 之后 transport 引用、会话状态与下行能力三者原样保留。
@MainActor
final class Ess1139SessionHoldTests: XCTestCase {

    private static let requestId = "01a0392b-c9ea-7c1a-a265-4688ba0cd894"
    private static let sessionId = "78829197-723E-4253-A84F-C1B7E3267A21"
    private static let taskId = "work_a8f61916-3b05-4831-9122-355f613365d3"
    private static let nextRequestId = "01a0392b-c9ea-7c1a-a265-000000000002"
    private static let nextSessionId = "78829197-723E-4253-A84F-000000000002"

    // MARK: - 阻断复现

    /// **阻断正面复现**：在飞任务 + lifecycle interruption 之后，
    /// 迟到的 `task.state`（终态）与 `audio.done` 必须**仍然送得到 Watch**。
    ///
    /// 整改前这里会全军覆没：`endTurn` 清了 `currentTransport`，
    /// `receiveAgentDownlink` 第一道闸门就判 `superseded_transport`。
    func testLifecycleInterruptionWithTaskInFlightStillDeliversTerminalAndAudioDone() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { 1_000 }

        h.session.lifecycleInterrupted(reason: "background")

        // hold 的三条不变量，缺一条这次修复就不成立。
        XCTAssertTrue(h.transport.closeReasons.isEmpty, "上游还有活在跑，socket 不得被关")
        XCTAssertEqual(h.session.state,
                       .active(requestId: Self.requestId, sessionId: Self.sessionId),
                       "会话状态必须原样保留——转成 .cancelled 等于第二道闸门自杀")
        XCTAssertTrue(h.session.hasCurrentTransportForTesting,
                      "transport 引用必须原样保留——丢了它第一道闸门就拒掉所有回调")

        // 上游继续干活：任务终态先到，最终答案的 audio.done 随后到。
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: 9_000
        )
        h.session.nowMs = { 9_000 }
        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "completed"),
            from: h.transport
        )
        XCTAssertEqual(h.delivered.count, 1, "任务终态必须送达")
        XCTAssertEqual(h.delivered.last?.kind, .taskState)
        XCTAssertTrue(h.transport.closeReasons.isEmpty,
                      "任务终态与最终答案之间**不得**收口——那正好把答案切掉")

        h.transport.upstreamWorkLedger.noteTurnTerminal(atMs: 10_000)
        h.session.nowMs = { 10_000 }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 7, upstreamWorkOutstanding: false),
            from: h.transport
        )
        XCTAssertEqual(h.delivered.count, 2, "回合终态必须送达")
        XCTAssertEqual(h.delivered.last?.kind, .audioDone)

        // 上游真的说完了，被推迟的那次关闭这才兑现。
        XCTAssertEqual(h.transport.closeReasons, ["lifecycle_background"],
                       "终态之后必须补上那次被推迟的关闭，且只关一次")
        XCTAssertEqual(h.session.state, .cancelled)
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    /// hold 期间**下行缓冲不得被清空**。
    ///
    /// 整改前 `pendingDownlink.discardAll()` 同样是无条件执行的：WCSession 在
    /// 背景态本来就常常接不住，这一清等于把等着重放的帧直接丢了。
    func testHoldKeepsPendingDownlinkBufferIntact() {
        let h = makeActiveSession()
        h.consumerTakesDelivery = false  // 模拟 WCSession 接不住 → 进断连缓冲
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { 1_000 }

        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "running"),
            from: h.transport
        )
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 1, "夹具前提：这一帧确实进了缓冲")

        h.session.lifecycleInterrupted(reason: "unreachable")

        XCTAssertEqual(h.session.pendingDownlinkStats.count, 1,
                       "hold 时缓冲必须原样保留——清掉等于把待重放的帧丢了")

        // 恢复后照常重放，恰好一次。
        h.consumerTakesDelivery = true
        XCTAssertEqual(h.session.replayPendingDownlink(trigger: "test_reachable"), 1)
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 0)
    }

    /// **第三轮阻断正面复现**：consumer 全程不可达 ⇒ 最终 task / answer /
    /// `audio.done` 三帧全部入缓冲；被推迟的关闭在 `audio.done` 那一刻兑现，
    /// **但绝不能把刚存进去的那三帧一起抹掉**；恢复后按序恰好重放一次。
    ///
    /// 整改前 `endTurn` 收口时无条件 `pendingDownlink.discardAll()`，而
    /// `audio.done` 正是触发 `retryDeferredClose` 的那一帧——账本此刻已无未结
    /// 任务、关闭获准，紧接着那一行就把最终答案全部删掉。等的就是这三帧，
    /// 收口的动作却顺手删了它们：一次确定性的数据丢失。
    func testConsumerUnavailableThroughoutStillReplaysFinalAnswerExactlyOnceInOrder() {
        let h = makeActiveSession()
        h.consumerTakesDelivery = false  // WCSession 全程接不住
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { 1_000 }
        h.session.lifecycleInterrupted(reason: "background")
        XCTAssertTrue(h.transport.closeReasons.isEmpty, "任务在飞 ⇒ 收口被推迟")

        // 上游把这一轮跑完：任务终态 → 答案增量 → 回合终态，三帧全部入缓冲。
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: 9_000
        )
        h.session.nowMs = { 9_000 }
        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "completed"),
            from: h.transport
        )
        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "completed",
                       answer: AgentTaskAnswerDelta(sequence: 1, delta: "杭州今天晴")),
            from: h.transport
        )
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 2, "夹具前提：两帧确实入了缓冲")

        h.transport.upstreamWorkLedger.noteTurnTerminal(atMs: 10_000)
        h.session.nowMs = { 10_000 }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 7, upstreamWorkOutstanding: false),
            from: h.transport
        )

        // 收口确实发生了（上游说完了，socket 该关）……
        XCTAssertEqual(h.transport.closeReasons, ["lifecycle_background"],
                       "上游终态之后必须补上那次被推迟的关闭")
        XCTAssertEqual(h.session.state, .cancelled)
        // ……但缓冲里的三帧一帧都不许少。
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 3,
                       "收口不得清掉待重放的最终答案——这正是本轮阻断")
        XCTAssertTrue(h.delivered.isEmpty, "consumer 全程不可达 ⇒ 此刻一帧都还没送出去")

        // WCSession 恢复：按序、恰好一次。
        h.consumerTakesDelivery = true
        XCTAssertEqual(h.session.replayPendingDownlink(trigger: "test_reachable"), 3)
        XCTAssertEqual(h.delivered.map(\.kind), [.taskState, .taskState, .audioDone],
                       "重放必须保序")
        XCTAssertEqual(h.delivered.last?.finalSequence, 7, "最终答案的屏障值不得丢失")
        XCTAssertEqual(h.delivered[1].answerDelta, "杭州今天晴", "答案增量原文不得丢失")
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 0)

        // 恰好一次：再重放一遍不得重复投递。
        XCTAssertEqual(h.session.replayPendingDownlink(trigger: "test_again"), 0)
        XCTAssertEqual(h.delivered.count, 3, "重放必须恰好一次，不得重复")
    }

    // MARK: - 主链路不受影响

    /// **无在飞任务的正常收口**：行为与本单之前逐字相同——当场关闭、清引用、
    /// 清缓冲、状态转 `.cancelled`。保住 socket 不能变成谁都收不了口。
    func testNormalTeardownWithoutUpstreamWorkClosesImmediately() {
        let h = makeActiveSession()
        h.session.nowMs = { 1_000 }

        let closed = h.session.endTurn(reason: "user_exit")

        XCTAssertTrue(closed)
        XCTAssertEqual(h.transport.closeReasons, ["user_exit"])
        XCTAssertEqual(h.session.state, .cancelled)
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 0)
    }

    /// 用户显式退出**压过**在飞任务：保住 socket 不能变成劫持用户。
    func testUserExitClosesEvenWithTaskInFlight() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { 1_000 }

        XCTAssertTrue(h.session.endTurn(reason: "user_exit", cause: .userExit))
        XCTAssertEqual(h.transport.closeReasons, ["user_exit"])
        XCTAssertEqual(h.session.state, .cancelled)
    }

    // MARK: - 有界性

    /// 上游在 lifecycle hold 之后**彻底静默**：重试计时器到点必须真的收口。
    ///
    /// 没有这条，一次 hold 就是一条永远关不掉的 socket——背景态下不会再有第二次
    /// `lifecycleInterrupted` 来重问策略。
    func testSilentUpstreamIsReleasedByTheRetryTimer() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { 1_000 }
        h.session.lifecycleInterrupted(reason: "background")
        XCTAssertTrue(h.transport.closeReasons.isEmpty)
        XCTAssertEqual(h.pendingRetries.count, 1, "hold 必须武装一支重试计时器")

        // 计时器到点时上游已静默满预算 ⇒ 策略放行。
        h.session.nowMs = { 1_000 + RealtimeSocketLifetimePolicy.upstreamSilenceBudgetMs }
        h.firePendingRetries()

        XCTAssertEqual(h.transport.closeReasons, ["lifecycle_background"])
        XCTAssertEqual(h.session.state, .cancelled)
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    /// 上游仍在持续下发时，计时器到点继续 hold 并**重新武装**；
    /// 任何时刻至多一支计时器在跑（否则每帧一支就是 Task 泄漏）。
    func testRetryTimerRearmsWhileUpstreamStaysBusyAndNeverStacks() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { 1_000 }
        h.session.lifecycleInterrupted(reason: "background")
        XCTAssertEqual(h.pendingRetries.count, 1)

        // 上游一直在说话：每次到点都续上活动时间，策略继续 hold。
        for round in 1...3 {
            let atMs = Int64(round) * 5_000
            h.transport.upstreamWorkLedger.noteTaskState(
                taskId: Self.taskId, status: "running", atMs: atMs
            )
            h.session.nowMs = { atMs + 1 }
            h.firePendingRetries()
            XCTAssertTrue(h.transport.closeReasons.isEmpty, "第 \(round) 轮：仍在跑，不得收口")
            XCTAssertEqual(h.pendingRetries.count, 1, "第 \(round) 轮：至多一支计时器在跑")
        }

        // 多次被拦下的下行帧也不许把计时器叠起来。
        for _ in 0..<20 {
            h.session.receiveAgentDownlink(
                .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                           finalSequence: 3, upstreamWorkOutstanding: true),
                from: h.transport
            )
        }
        XCTAssertEqual(h.pendingRetries.count, 1, "逐帧重试不得堆积计时器")
    }

    // MARK: - supersede 主链路（第二轮复审阻断）

    /// **第二轮阻断正面复现**：旧任务在飞 + `pendingDownlink` 非空 + 新 request
    /// 的 `stream.start`。
    ///
    /// 整改前 `.streamStart` 分支在 `openIfNeeded` **之前**就无条件
    /// `pendingDownlink.discardAll()`：随后 supersede 被任务感知策略正确判成
    /// hold，socket 与 state 都保住了，**可答案缓冲已经没了**。保住一条空转的
    /// socket 不叫保住答案。
    func testSupersedeHeldByInFlightTaskKeepsTransportStateAndBuffer() {
        let h = makeActiveSession()
        h.consumerTakesDelivery = false  // WCSession 暂时接不住 → 进断连缓冲
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { 1_000 }

        // 旧任务的答案已经压在缓冲里等重放。
        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "running"),
            from: h.transport
        )
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 1, "夹具前提：缓冲里确实有待重放的帧")

        // Watch 开了新一轮：新 request_id 的 stream.start 到达。
        var opened = true
        h.session.forward(.start(RealtimeStreamStart(
            requestId: Self.nextRequestId, sessionId: Self.nextSessionId,
            format: .uplinkPCM16, capturedAtMs: 0
        ))) { opened = $0 }

        XCTAssertFalse(opened, "上游还有活在跑 ⇒ 这一轮必须被拒")
        XCTAssertTrue(h.transport.closeReasons.isEmpty, "旧 socket 不得被关")
        XCTAssertEqual(h.session.state,
                       .active(requestId: Self.requestId, sessionId: Self.sessionId),
                       "会话状态必须仍指向旧回合")
        XCTAssertTrue(h.session.hasCurrentTransportForTesting, "旧 transport 引用必须保留")
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 1,
                       "hold 时旧缓冲不得被新一轮清掉——这正是本次阻断")
        XCTAssertTrue(h.transportRequests.isEmpty, "被拒的一轮不得建新 transport")

        // 三者都还在 ⇒ 旧回合仍然能继续收、能恢复重放。
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: 9_000
        )
        h.session.nowMs = { 9_000 }
        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "completed"),
            from: h.transport
        )
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 2)

        h.consumerTakesDelivery = true
        XCTAssertEqual(h.session.replayPendingDownlink(trigger: "test_reachable"), 2,
                       "保留下来的缓冲必须真的能恢复重放")
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 0)
    }

    /// **主链路不受影响**：没有在飞任务时，正常 supersede 仍然清旧缓冲、
    /// 关旧 socket、建新 transport ——ESS-539 的语义一个字未改。
    func testNormalSupersedeStillDiscardsStaleBufferAndOpensNewTransport() {
        let h = makeActiveSession()
        h.consumerTakesDelivery = false
        h.session.nowMs = { 1_000 }

        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "running"),
            from: h.transport
        )
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 1, "夹具前提：缓冲里有上一轮的帧")

        // 账本为空 = 上游没有在飞工作。
        var opened = false
        h.session.forward(.start(RealtimeStreamStart(
            requestId: Self.nextRequestId, sessionId: Self.nextSessionId,
            format: .uplinkPCM16, capturedAtMs: 0
        ))) { opened = $0 }

        XCTAssertTrue(opened, "没有在飞任务 ⇒ 照常开新一轮")
        XCTAssertEqual(h.transport.closeReasons, ["supersede"], "旧 socket 照常关闭")
        XCTAssertEqual(h.transportRequests, [Self.nextRequestId], "必须建起新 transport")
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 0,
                       "新一轮真的建起来了 ⇒ 上一轮的缓冲照常作废")
        XCTAssertEqual(h.session.state,
                       .connecting(requestId: Self.nextRequestId, sessionId: Self.nextSessionId))
    }

    /// 把清理挪进 `openIfNeeded` 顺带修掉的一条：**同一轮重发的 `stream.start`
    /// 不得清掉自己的缓冲**。
    ///
    /// 旧代码的清理跑在方法开头，连「同一轮的重发」都一起清——而
    /// `openIfNeeded` 对同一轮是直接短路返回的，根本没有「新一轮」可言。
    func testDuplicateStreamStartForSameTurnKeepsItsOwnBuffer() {
        let h = makeActiveSession()
        h.consumerTakesDelivery = false
        h.session.nowMs = { 1_000 }
        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "running"),
            from: h.transport
        )
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 1)

        // 同一 request/session 重发 stream.start（幂等重试）。
        var opened = false
        h.session.forward(.start(RealtimeStreamStart(
            requestId: Self.requestId, sessionId: Self.sessionId,
            format: .uplinkPCM16, capturedAtMs: 0
        ))) { opened = $0 }

        XCTAssertTrue(opened)
        XCTAssertEqual(h.session.pendingDownlinkStats.count, 1,
                       "同一轮的重发不得清掉本轮自己的待重放帧")
        XCTAssertTrue(h.transport.closeReasons.isEmpty)
        XCTAssertTrue(h.transportRequests.isEmpty, "同一轮不得重建 transport")
    }

    // MARK: - 夹具

    private struct Harness {
        let session: PhoneRealtimeSession
        let transport: FakeTransport
        private let box: Box

        final class Box {
            var delivered: [RealtimeDownlinkEnvelope] = []
            var consumerTakesDelivery = true
            var pendingRetries: [@MainActor () -> Void] = []
            /// 工厂被问过哪些 request_id。「被拒的一轮不得建新 transport」
            /// 只有盯着工厂才断言得了。
            var transportRequests: [String] = []
        }

        init(session: PhoneRealtimeSession, transport: FakeTransport, box: Box) {
            self.session = session
            self.transport = transport
            self.box = box
        }

        var delivered: [RealtimeDownlinkEnvelope] { box.delivered }
        var pendingRetries: [@MainActor () -> Void] { box.pendingRetries }
        var transportRequests: [String] { box.transportRequests }
        var consumerTakesDelivery: Bool {
            get { box.consumerTakesDelivery }
            nonmutating set { box.consumerTakesDelivery = newValue }
        }

        /// 触发当前武装着的全部重试计时器（触发过程中新武装的留到下一次）。
        @MainActor
        func firePendingRetries() {
            let due = box.pendingRetries
            box.pendingRetries.removeAll()
            for fire in due { fire() }
        }
    }

    private func makeActiveSession() -> Harness {
        let transport = FakeTransport()
        let box = Harness.Box()
        let session = PhoneRealtimeSession(transportFactory: { requestId, _ in
            // 首轮交出夹具持有的那一个（后续断言都盯着它）；此后每次工厂被
            // 调用都记一笔并给一个新的替身，供「被拒的一轮不得建新 transport」
            // 断言。
            guard requestId != Self.requestId else { return transport }
            box.transportRequests.append(requestId)
            return FakeTransport()
        })
        session.isAgentTransport = true
        session.onDownlink = { envelope in
            guard box.consumerTakesDelivery else { return .deferred }
            box.delivered.append(envelope)
            return .handled
        }
        session.scheduleDeferredCloseRetry = { _, fire in box.pendingRetries.append(fire) }

        // 真实开轮路径：上行 stream.start 建通道，Agent transport 报 .active。
        session.forward(.start(RealtimeStreamStart(
            requestId: Self.requestId, sessionId: Self.sessionId,
            format: .uplinkPCM16, capturedAtMs: 0
        )))
        session.agentTransportDidChangeState(
            .active(requestId: Self.requestId, sessionId: Self.sessionId), from: transport
        )
        XCTAssertEqual(session.state,
                       .active(requestId: Self.requestId, sessionId: Self.sessionId),
                       "夹具前提：会话已经在服务这一轮")
        return Harness(session: session, transport: transport, box: box)
    }
}

/// 会话层测试替身。只做两件事：如实记账本、如实记 close 调用。
@MainActor
private final class FakeTransport: PhoneRealtimeSession.Transport {
    var upstreamWorkLedger = UpstreamWorkLedger()
    private(set) var closeReasons: [String] = []

    func send(_ envelope: RealtimeUplinkEnvelope, completion: @escaping @MainActor (Error?) -> Void) {
        completion(nil)
    }

    func receive(handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void) {}

    func close(reason: String) {
        closeReasons.append(reason)
    }
}
