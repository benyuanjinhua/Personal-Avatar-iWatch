import XCTest
@testable import WristAgentCore

/// ESS-1159：**超过 12 秒 / 超过 30 秒**的委派回合，客户端全程不得关掉这条 WSS。
///
/// ESS-1139 的用例把两条真机时间线钉在 1.2s 与 11.5s；那两条尚未跨过网关
/// 「忙碌段落间隔」`agent_segment_gap_busy_ms = 12_000`（`AudioRealtimeGateway/
/// config.json`），也没跨过任何一条 30s 预算。2026-09-05 的最新真机复测把
/// 两条链路都推到了 12s 之后：
///
///   • 天气：session `watch-direct-B4C6D281-…-1`，task
///     `work_9e37b3be-6764-4840-90a6-8e1813075509`。Watch 在 **12.157s**
///     断开，Codex 在 **22.272s** 才完成；
///   • 知识库：session `watch-direct-518197E7-…-1`，task
///     `work_11ecbeaf-18ee-4be7-8a8e-6a8e8353a5c1`。Watch 在 **12.4s**
///     断开，Codex 在 **18.985s** 才完成。
///
/// 两条都是「任务还在 running，客户端先走了」，服务端随即
/// `task.stream.frame_dropped reason=socket_closed`。因此本套件断言的直接
/// 事实是：**在这两个时刻，任何一种「客户端自己的状态变了」的关闭动因都必须
/// 得到 hold**，并且回合级 `audio.done` 在任务终结前一律只算段落边界。
///
/// 时钟一律注入，秒数原样用作输入——12s / 30s 不靠真实等待。
final class Ess1159DelegatedTurnHoldTests: XCTestCase {

    /// 天气回合的真实 task id（真机日志原文）。
    private let weatherTaskId = "work_9e37b3be-6764-4840-90a6-8e1813075509"
    /// 知识库回合的真实 task id（真机日志原文）。
    private let vaultTaskId = "work_11ecbeaf-18ee-4be7-8a8e-6a8e8353a5c1"

    /// 「客户端自己的状态变了」的全部动因。它们没有资格替上游宣布任务结束。
    private let localCauses: [RealtimeSocketCloseCause] = [
        .turnSupersede, .uiStateChange, .localTimeout, .lifecycle, .uplinkFallback
    ]

    // MARK: - 新增动因

    /// ESS-1159 的根因就在这条断言里：Watch 的快速上行通道判死
    /// （`stream.fallback`）说的是 **Watch↔iPhone** 那一跳，不是这条 WSS。
    /// 它此前被当成 `.transportFailure` 用，于是压过了在飞任务。
    func testUplinkFallbackNeverOverridesInFlightUpstreamWork() {
        XCTAssertFalse(RealtimeSocketCloseCause.uplinkFallback.overridesInFlightUpstreamWork)
        XCTAssertTrue(
            RealtimeSocketCloseCause.transportFailure.overridesInFlightUpstreamWork,
            "真正的传输死亡语义不得被本单改动"
        )

        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 0)
        let decision = RealtimeSocketLifetimePolicy.decide(
            cause: .uplinkFallback, ledger: ledger, nowMs: 1_000
        )
        XCTAssertFalse(decision.isClose, "上行回退不得关掉一条上游还在干活的 WSS")
        XCTAssertTrue(decision.detail.contains("upstream_work_in_flight"), decision.detail)
    }

    // MARK: - 超过 12 秒（天气）

    /// 天气回合：任务 12.157s 时仍在 running —— 五种本地动因全部必须 hold，
    /// 直到 22.272s 任务真的 completed 才放行。
    ///
    /// 阶段播报的回合级 `audio.done`（约 2s）刻意排在中间：它是本单验收第 3 条
    /// 「状态播报结束不能被误判为整轮结束」的直接反例。
    func testWeatherDelegationBeyondTwelveSecondsHoldsSocketUntilTaskCompletes() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: nil, status: "tool_call_pending", atMs: 0)
        ledger.noteTaskState(taskId: weatherTaskId, status: "queued", atMs: 120)
        // 阶段播报：「我去查一下杭州天气」，播完发回合级 audio.done。
        ledger.noteTurnTerminal(atMs: 1_950)
        // 网关的忙碌段落间隔是 12s；任务在这段时间里持续 running。
        for second in 2...22 {
            ledger.noteTaskState(
                taskId: weatherTaskId, status: "running", atMs: Int64(second) * 1_000
            )
        }

        // 事故时刻：12.157s。真机上这一刻 socket 被关掉。
        for cause in localCauses {
            let decision = RealtimeSocketLifetimePolicy.decide(
                cause: cause, ledger: ledger, nowMs: 12_157
            )
            XCTAssertFalse(
                decision.isClose,
                "12.157s 的 \(cause.rawValue) 不得关闭 socket —— Codex 要到 22.272s 才完成"
            )
            XCTAssertTrue(decision.detail.contains("outstanding_tasks=1"), decision.detail)
        }

        // 任务真的完成之后才谈得上收口。
        ledger.noteTaskState(taskId: weatherTaskId, status: "completed", atMs: 22_272)
        for cause in localCauses {
            let decision = RealtimeSocketLifetimePolicy.decide(
                cause: cause, ledger: ledger, nowMs: 22_300
            )
            XCTAssertTrue(decision.isClose, "\(cause.rawValue) 在任务终态之后必须放行")
            XCTAssertTrue(decision.detail.contains("no_outstanding_work"), decision.detail)
        }
    }

    // MARK: - 超过 30 秒（知识库）

    /// 知识库回合：把真机的 18.985s 继续拉长到 35s（本单验收要求覆盖 30s 以上）。
    ///
    /// 关键在于**有界性按静默计、不按总时长计**：任务每秒都有一帧 `running`，
    /// 跨过 30s 的静默预算也不许放行；只有绝对上限 180s 才兜底。
    func testVaultDelegationBeyondThirtySecondsHoldsSocketWhileUpstreamKeepsTalking() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: vaultTaskId, status: "accepted", atMs: 0)
        ledger.noteTurnTerminal(atMs: 2_510)  // 阶段播报播完
        for second in 1...35 {
            ledger.noteTaskState(
                taskId: vaultTaskId, status: "running", atMs: Int64(second) * 1_000
            )
        }

        // 12.4s（真机断开时刻）与 31s（跨过静默预算）都必须 hold。
        for nowMs in [Int64(12_400), 31_000] {
            for cause in localCauses {
                let decision = RealtimeSocketLifetimePolicy.decide(
                    cause: cause, ledger: ledger, nowMs: nowMs
                )
                XCTAssertFalse(
                    decision.isClose,
                    "\(nowMs)ms 的 \(cause.rawValue) 不得关闭 socket —— 上游每秒都在说话"
                )
                XCTAssertTrue(
                    decision.detail.contains("upstream_work_in_flight"), decision.detail
                )
            }
        }

        // 35s 之后任务完成，收口照常发生。
        ledger.noteTaskState(taskId: vaultTaskId, status: "completed", atMs: 35_500)
        XCTAssertTrue(
            RealtimeSocketLifetimePolicy.decide(
                cause: .uplinkFallback, ledger: ledger, nowMs: 35_600
            ).isClose
        )
    }

    /// 同一条 35s 的时间线上，`held_ms` 必须从**第一次出现未结任务**起算，
    /// 而不是被中途的回合级终态重置——否则绝对上限就形同虚设。
    func testHeldDurationIsMeasuredFromFirstOutstandingTask() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: vaultTaskId, status: "accepted", atMs: 1_000)
        ledger.noteTurnTerminal(atMs: 2_510)
        ledger.noteTaskState(taskId: vaultTaskId, status: "running", atMs: 31_000)
        let decision = RealtimeSocketLifetimePolicy.decide(
            cause: .uiStateChange, ledger: ledger, nowMs: 31_500
        )
        XCTAssertFalse(decision.isClose)
        XCTAssertTrue(decision.detail.contains("held_ms=30500"), decision.detail)
    }

    // MARK: - 阶段播报不得被误判为整轮结束

    /// 委派回合的全时间线上，回合级 `audio.done` 恰好被分类为
    /// **一次** `turnTerminal`——阶段播报那一条必须是 `segmentBoundary`。
    ///
    /// 判据取自 iPhone 在有序 WSS 上算出的 `upstream_work_outstanding`，
    /// 这里用同一个账本推导，与 `PhoneRealtimeAgentTransport` 的口径一致。
    func testStageAnnouncementDoneIsSegmentBoundaryAndFinalDoneIsTheOnlyTurnTerminal() {
        var ledger = UpstreamWorkLedger()
        var kinds: [RealtimeTurnTerminalKind] = []

        func classifyTurnDone(atMs: Int64) {
            ledger.noteTurnTerminal(atMs: atMs)
            kinds.append(RealtimeTurnTerminalClassifier.classify(
                upstreamWorkOutstanding: ledger.hasOutstandingWork
            ))
        }

        ledger.noteTaskState(taskId: nil, status: "tool_call_pending", atMs: 0)
        ledger.noteTaskState(taskId: weatherTaskId, status: "queued", atMs: 120)
        classifyTurnDone(atMs: 1_950)                       // 阶段播报播完
        for second in 2...22 {
            ledger.noteTaskState(
                taskId: weatherTaskId, status: "running", atMs: Int64(second) * 1_000
            )
        }
        classifyTurnDone(atMs: 12_157)                      // 事故时刻的那一条
        ledger.noteTaskState(taskId: weatherTaskId, status: "completed", atMs: 22_272)
        classifyTurnDone(atMs: 22_500)                      // 最终答案播完

        XCTAssertEqual(
            kinds, [.segmentBoundary, .segmentBoundary, .turnTerminal],
            "整轮终态必须恰好一次，且只能是最终答案那一条"
        )
        XCTAssertEqual(kinds.filter { $0 == .turnTerminal }.count, 1)
    }

    /// 段落边界那一帧同时把「上游还有活」喂给回合聚合体，两个方向都权威。
    func testToolEvidenceStatusTracksTheLedgerBothWays() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: weatherTaskId, status: "running", atMs: 0)
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.toolEvidenceStatus(
                upstreamWorkOutstanding: ledger.hasOutstandingWork
            ),
            "tool_call_pending"
        )
        ledger.noteTaskState(taskId: weatherTaskId, status: "completed", atMs: 22_272)
        XCTAssertEqual(
            RealtimeTurnTerminalClassifier.toolEvidenceStatus(
                upstreamWorkOutstanding: ledger.hasOutstandingWork
            ),
            "tool_call_resolved"
        )
    }

    // MARK: - 有界性（保住 socket 不得变成永久泄漏）

    /// 上游在 12s 之后彻底静默：满 30s 静默预算即放行，socket 不会永久占着。
    func testSilentUpstreamAfterTwelveSecondsIsStillReleasedByTheSilenceBudget() {
        var ledger = UpstreamWorkLedger()
        ledger.noteTaskState(taskId: vaultTaskId, status: "running", atMs: 12_400)
        let budget = RealtimeSocketLifetimePolicy.upstreamSilenceBudgetMs

        XCTAssertFalse(
            RealtimeSocketLifetimePolicy.decide(
                cause: .uplinkFallback, ledger: ledger, nowMs: 12_400 + budget - 1
            ).isClose
        )
        let released = RealtimeSocketLifetimePolicy.decide(
            cause: .uplinkFallback, ledger: ledger, nowMs: 12_400 + budget
        )
        XCTAssertTrue(released.isClose)
        XCTAssertTrue(released.detail.contains("upstream_silent"), released.detail)
    }

    /// 上游一直在说话也有天花板：绝对上限 180s 到点必须放行。
    func testAbsoluteHoldCapReleasesEvenWhenUpstreamNeverGoesQuiet() {
        var ledger = UpstreamWorkLedger()
        let cap = RealtimeSocketLifetimePolicy.absoluteHoldCapMs
        ledger.noteTaskState(taskId: vaultTaskId, status: "running", atMs: 0)
        var atMs: Int64 = 1_000
        while atMs <= cap {
            ledger.noteTaskState(taskId: vaultTaskId, status: "running", atMs: atMs)
            atMs += 1_000
        }
        let decision = RealtimeSocketLifetimePolicy.decide(
            cause: .uplinkFallback, ledger: ledger, nowMs: cap
        )
        XCTAssertTrue(decision.isClose)
        XCTAssertTrue(decision.detail.contains("hold_cap_reached"), decision.detail)
    }
}
