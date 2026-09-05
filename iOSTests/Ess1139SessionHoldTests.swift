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

    // MARK: - 夹具

    private struct Harness {
        let session: PhoneRealtimeSession
        let transport: FakeTransport
        private let box: Box

        final class Box {
            var delivered: [RealtimeDownlinkEnvelope] = []
            var consumerTakesDelivery = true
            var pendingRetries: [@MainActor () -> Void] = []
        }

        init(session: PhoneRealtimeSession, transport: FakeTransport, box: Box) {
            self.session = session
            self.transport = transport
            self.box = box
        }

        var delivered: [RealtimeDownlinkEnvelope] { box.delivered }
        var pendingRetries: [@MainActor () -> Void] { box.pendingRetries }
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
        let session = PhoneRealtimeSession(transportFactory: { _, _ in transport })
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
