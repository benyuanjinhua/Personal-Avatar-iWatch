import XCTest
@testable import WristAgentCore

/// ESS-1139：客户端不得在上游任务终结前关掉这条 WSS。
///
/// 夹具直接照抄 2026-09-05 真机取证的两条时间线，秒数原样用作输入：
///   • 天气：任务启动 → **+1.2s 客户端关闭 WSS** → 首答案要到 +10s；
///   • 知识库：任务启动 → 首答案 +4.75s → **+11.5s 客户端关闭 WSS**。
/// 两条线上的关闭动因都不是用户，而是「客户端自己的状态变了」——因此断言的
/// 直接事实是「在那个时刻 `decide` 必须给 hold」，而不是某个计时器有没有武装。
final class Ess1139SocketLifetimeTests: XCTestCase {

    private let weatherTaskId = "work_a8f61916-3b05-4831-9122-355f613365d3"
    private let vaultTaskId = "work_c1d40bc7-bd25-4aad-aada-32e7ebf01139"

    // MARK: - 动因分类

    /// 分类是本单的判定核心：只有用户显式动作与传输真死压得过在飞任务。
    func testOnlyUserAndTransportFailureOverrideInFlightWork() {
        XCTAssertTrue(RealtimeSocketCloseCause.userExit.overridesInFlightUpstreamWork)
        XCTAssertTrue(RealtimeSocketCloseCause.bargeIn.overridesInFlightUpstreamWork)
        XCTAssertTrue(RealtimeSocketCloseCause.transportFailure.overridesInFlightUpstreamWork)
        XCTAssertFalse(RealtimeSocketCloseCause.turnSupersede.overridesInFlightUpstreamWork)
        XCTAssertFalse(RealtimeSocketCloseCause.uiStateChange.overridesInFlightUpstreamWork)
        XCTAssertFalse(RealtimeSocketCloseCause.localTimeout.overridesInFlightUpstreamWork)
        XCTAssertFalse(RealtimeSocketCloseCause.lifecycle.overridesInFlightUpstreamWork)
    }

    // MARK: - 事故复现

    /// 天气用例：任务启动 1.2s 后的一次 supersede 必须被拦下。
    ///
    /// 这正是真机上那次关闭：阶段播报播完 → 会话回到聆听 → 新一轮 request_id
    /// → `openIfNeeded` supersede → WSS 关闭 → 网关对上游 `mute` → 后续帧
    /// 全部 `socket_closed`。
    func testWeatherIncidentSupersedeAtOnePointTwoSecondsIsHeld() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: nil, status: "tool_call_pending", atMs: 0)
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 200)
        // 阶段播报的回合级 audio.done —— 它**不**代表任务结束。
        ledger.noteTurnTerminal(atMs: 1_000)
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 1_100)

        let decision = RealtimeSocketLifetimePolicy.decide(
            cause: .turnSupersede, ledger: ledger, nowMs: 1_200
        )
        XCTAssertFalse(decision.isClose, "任务仍在跑，1.2s 的 supersede 不得关闭 socket")
        XCTAssertTrue(decision.detail.contains("upstream_work_in_flight"), decision.detail)
        XCTAssertTrue(decision.detail.contains("outstanding_tasks=1"), decision.detail)
    }

    /// 回合级 `audio.done` 到达也不放行——它是阶段播报的收口，不是任务终态。
    func testTurnTerminalAloneDoesNotReleaseTheSocket() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 0)
        ledger.noteTurnTerminal(atMs: 900)
        XCTAssertTrue(ledger.sawTurnTerminal)
        XCTAssertTrue(ledger.hasOutstandingWork)
        for cause in [RealtimeSocketCloseCause.turnSupersede, .uiStateChange, .localTimeout, .lifecycle] {
            XCTAssertFalse(
                RealtimeSocketLifetimePolicy.decide(cause: cause, ledger: ledger, nowMs: 1_000).isClose,
                "\(cause.rawValue) 不得因为播报播完就关掉在跑任务的 socket"
            )
        }
    }

    /// 知识库用例：11.5s 的关闭同样被拦；任务真正 completed 之后才放行。
    func testVaultIncidentHeldUntilTaskCompletes() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: vaultTaskId, status: "queued", atMs: 0)
        for second in 1...11 {
            ledger.noteTaskState(taskId: vaultTaskId, status: "running", atMs: Int64(second) * 1_000)
        }
        XCTAssertFalse(
            RealtimeSocketLifetimePolicy.decide(
                cause: .turnSupersede, ledger: ledger, nowMs: 11_500
            ).isClose
        )
        ledger.noteTaskState(taskId: vaultTaskId, status: "completed", atMs: 12_000)
        let after = RealtimeSocketLifetimePolicy.decide(
            cause: .turnSupersede, ledger: ledger, nowMs: 12_100
        )
        XCTAssertTrue(after.isClose)
        XCTAssertTrue(after.detail.contains("no_outstanding_work"), after.detail)
    }

    // MARK: - 用户与失败路径不受影响

    /// 用户显式退出 / 打断在任何时刻都关得掉——保住 socket 不能变成劫持用户。
    func testUserExitAndBargeInCloseEvenWithWorkInFlight() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 0)
        for cause in [RealtimeSocketCloseCause.userExit, .bargeIn, .transportFailure] {
            let decision = RealtimeSocketLifetimePolicy.decide(
                cause: cause, ledger: ledger, nowMs: 500
            )
            XCTAssertTrue(decision.isClose, "\(cause.rawValue) 必须立刻关闭")
            XCTAssertTrue(decision.detail.contains("cause_overrides"), decision.detail)
        }
    }

    /// 没有任何在飞工作时行为与本单之前逐字相同：该关就关，不加一毫秒。
    func testPlainTurnWithoutUpstreamWorkClosesImmediately() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTurnTerminal(atMs: 3_000)
        let decision = RealtimeSocketLifetimePolicy.decide(
            cause: .turnSupersede, ledger: ledger, nowMs: 3_001
        )
        XCTAssertTrue(decision.isClose)
        XCTAssertTrue(decision.detail.contains("no_outstanding_work"), decision.detail)
    }

    // MARK: - 有界性

    /// 上游静默超预算：即使账本上还挂着任务也放行，socket 不会永久泄漏。
    func testUpstreamSilenceBudgetReleasesTheSocket() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 1_000)
        let justBefore = RealtimeSocketLifetimePolicy.decide(
            cause: .turnSupersede, ledger: ledger,
            nowMs: 1_000 + RealtimeSocketLifetimePolicy.upstreamSilenceBudgetMs - 1
        )
        XCTAssertFalse(justBefore.isClose)
        let atBudget = RealtimeSocketLifetimePolicy.decide(
            cause: .turnSupersede, ledger: ledger,
            nowMs: 1_000 + RealtimeSocketLifetimePolicy.upstreamSilenceBudgetMs
        )
        XCTAssertTrue(atBudget.isClose)
        XCTAssertTrue(atBudget.detail.contains("upstream_silent"), atBudget.detail)
    }

    /// 绝对上限：上游一直每秒喂 `running`，也不能把 socket 无限保住。
    func testAbsoluteHoldCapReleasesEvenWithContinuousActivity() {
        var ledger = UpstreamWorkLedger()
        var t: Int64 = 0
        while t <= RealtimeSocketLifetimePolicy.absoluteHoldCapMs {
            ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: t)
            t += 1_000
        }
        let decision = RealtimeSocketLifetimePolicy.decide(
            cause: .turnSupersede, ledger: ledger,
            nowMs: RealtimeSocketLifetimePolicy.absoluteHoldCapMs + 1_000
        )
        XCTAssertTrue(decision.isClose)
        XCTAssertTrue(decision.detail.contains("hold_cap_reached"), decision.detail)
    }

    // MARK: - 账本语义

    /// 未知状态一律按非终态：把没见过的状态当终态正是本单要修的 bug。
    func testUnknownStatusIsTreatedAsNonTerminal() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: weatherTaskId, status: "reticulating_splines", atMs: 0)
        XCTAssertTrue(ledger.hasOutstandingWork)
    }

    /// 同一个 taskId 的重复 `running` 不累加，一次终态就减得回 0。
    func testRepeatedRunningIsIdempotent() {
        var ledger = UpstreamWorkLedger()
        for second in 0..<24 {
            ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: Int64(second) * 1_000)
        }
        XCTAssertEqual(ledger.outstandingTasks.count, 1)
        ledger.noteTaskState(taskId: weatherTaskId, status: "completed", atMs: 24_000)
        XCTAssertFalse(ledger.hasOutstandingWork)
        XCTAssertEqual(ledger.seenTasks.count, 1, "取证集合不因终态而丢失 task 身份")
    }

    /// 任务号一出现即解除 `tool_call_pending` 闩锁（与 ESS-1098 同口径）。
    func testTaskIdClearsToolCallPendingLatch() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: nil, status: "tool_call_pending", atMs: 0)
        XCTAssertTrue(ledger.toolCallPending)
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 100)
        XCTAssertFalse(ledger.toolCallPending)
        ledger.noteTaskState(taskId: weatherTaskId, status: "completed", atMs: 200)
        XCTAssertFalse(ledger.hasOutstandingWork, "闩锁没被清干净会让 socket 永远关不掉")
    }

    /// 只有闩锁、从未产生任务号的工具回合也算在飞工作。
    func testToolCallPendingAloneHoldsTheSocket() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: nil, status: "tool_call_pending", atMs: 0)
        XCTAssertFalse(
            RealtimeSocketLifetimePolicy.decide(cause: .turnSupersede, ledger: ledger, nowMs: 500).isClose
        )
        ledger.noteTaskState(taskId: nil, status: "tool_call_resolved", atMs: 600)
        XCTAssertTrue(
            RealtimeSocketLifetimePolicy.decide(cause: .turnSupersede, ledger: ledger, nowMs: 700).isClose
        )
    }

    /// 上游明确判死后账本清空，socket 立刻可关。
    func testUpstreamSettledClearsTheLedger() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 0)
        ledger.noteUpstreamSettled(atMs: 1_000)
        XCTAssertFalse(ledger.hasOutstandingWork)
        XCTAssertTrue(
            RealtimeSocketLifetimePolicy.decide(cause: .lifecycle, ledger: ledger, nowMs: 1_001).isClose
        )
    }
}

/// ESS-1139：回合终态分类 + 线格向前兼容。
///
/// 判据由 iPhone 在**有序的** WSS 上产出并随帧下发，Watch 只消费。逻辑放在
/// `Shared/` 的理由与 `RealtimeTurnGate` 相同：它的消费点在
/// `Watch/WatchSettingsStore` 的 WCSession 委托里，那里没有单测接缝。
final class Ess1139TurnTerminalClassifierTests: XCTestCase {

    /// 上游还有活 ⇒ 这条终态只是段落边界，回合必须继续等。
    func testOutstandingWorkMakesTheTerminalASegmentBoundary() {
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.classify(upstreamWorkOutstanding: true),
            .segmentBoundary
        )
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.toolEvidenceStatus(upstreamWorkOutstanding: true),
            "tool_call_pending"
        )
    }

    /// 上游没活了 ⇒ 真终态，且必须**解除**闩锁。
    ///
    /// 少了后面这一半，一个从未收到真实 `task.state` 的回合会被自己挂到
    /// 180s 绝对上限判失败——把一个丢答案的 bug 换成一个卡死的 bug。
    func testNoOutstandingWorkIsATrueTerminalAndResolvesTheLatch() {
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.classify(upstreamWorkOutstanding: false),
            .turnTerminal
        )
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.toolEvidenceStatus(upstreamWorkOutstanding: false),
            "tool_call_resolved"
        )
    }

    /// 字段缺席（滚动升级窗口内的老 iPhone 进程）：按终态处理、不喂任何证据，
    /// 行为与本单之前逐字相同。
    func testAbsentFlagFallsBackToLegacyTerminal() {
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.classify(upstreamWorkOutstanding: nil),
            .turnTerminal
        )
        XCTAssertNil(
            RealtimeTurnTerminalClassifier.toolEvidenceStatus(upstreamWorkOutstanding: nil)
        )
    }

    /// 分类结论与账本是同一个事实的两种表达，任何时候都不得分叉。
    func testClassificationAgreesWithTheLedger() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: "work_1", status: "running", atMs: 0)
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.classify(
                upstreamWorkOutstanding: ledger.hasOutstandingWork
            ),
            .segmentBoundary
        )
        ledger.noteTaskState(taskId: "work_1", status: "completed", atMs: 1_000)
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.classify(
                upstreamWorkOutstanding: ledger.hasOutstandingWork
            ),
            .turnTerminal
        )
    }

    // MARK: - 线格

    /// 新字段随 `audio.done` 往返，键名与网关/日志口径一致。
    func testAudioDoneCarriesTheFlagOverTheWire() throws {
        let envelope = RealtimeDownlinkEnvelope.audioDone(
            requestId: "req-1139", sessionId: "sess-1139",
            responseId: "resp-1", generation: 1, finalSequence: 7,
            upstreamWorkOutstanding: true
        )
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["upstream_work_outstanding"] as? Bool, true)

        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)
        XCTAssertEqual(decoded.upstreamWorkOutstanding, true)
        XCTAssertEqual(decoded.finalSequence, 7)
        XCTAssertEqual(decoded, envelope)
    }

    /// **向前兼容**：不带新字段的老帧照常解码，其余字段一个不丢。
    /// 缺一个字段就让整条终态报废，等于把一个 bug 换成另一个。
    func testLegacyAudioDoneWithoutTheFlagStillDecodes() throws {
        let legacy: [String: Any] = [
            "protocol_version": RealtimeWireVersion.downlink,
            "kind": "audio.done",
            "request_id": "req-1139",
            "session_id": "sess-1139",
            "final_sequence": 3,
            "generation": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)
        XCTAssertNil(decoded.upstreamWorkOutstanding, "缺席就是缺席，不许猜成 false 以外的东西")
        XCTAssertEqual(decoded.finalSequence, 3)
        XCTAssertEqual(decoded.generation, 1)
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.classify(
                upstreamWorkOutstanding: decoded.upstreamWorkOutstanding
            ),
            .turnTerminal
        )
    }
}
