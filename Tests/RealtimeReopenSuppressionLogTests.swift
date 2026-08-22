import XCTest
@testable import WristAgentCore

/// ESS-987：终态回合被判死后，客户端仍以 ~10 条/秒反复撞闸门并逐帧打日志。
///
/// L1 事故形态（2026-08-22 10:19 真机 `request_id=01a02744-06e5`）：
/// `02:19:30.544 → 02:19:34.323` 共 40 条 `realtime_reopen_suppressed`
/// （≈10.6 条/秒），全天 236 条。ESS-960 已经保证这 40 次**不建 WSS**，
/// 本单钉住的是「不再空转 + 不再刷屏 + 重试有退避」。
///
/// `iOS/` 没有单测 target，所以 `PhoneRealtimeSession.forward` 消费的这份
/// 契约必须在 `Shared/` 这一侧被钉死——`GateDrivenUplink` 就是那条调用序列
/// 的等价复刻：admit → 放行才建 transport → 回合边界收口。
final class RealtimeReopenSuppressionLogTests: XCTestCase {
    private let rid = "01a02744-06e5-7c4c-9a1e-0f9d3c2b7a11"
    private let sid = "5C1E0A93-1B77-4E52-9E0C-2A6D1F0B4C88"

    /// `PhoneRealtimeSession.forward` → `openIfNeeded` 的等价复刻，含**状态短路**：
    /// 正在服务本回合时根本不问闸门（那条链路是健康的，问了会误伤）；只有真要
    /// （重）建通道时才走 `admit(...)`，放行才调用 `transportFactory`。
    /// `transportFactoryCalls` 因此与验收标准 1 的「transportFactory 调用次数」同口径。
    private struct GateDrivenUplink {
        var gate: RealtimeTurnGate
        private(set) var transportFactoryCalls = 0
        private(set) var logs: [RealtimeTurnGate.LogLine] = []
        /// 当前正在服务的回合 = `PhoneRealtimeSession` 的 `.connecting` / `.active`。
        private var servingTurn: RealtimeTurnGate.Turn?

        init(gate: RealtimeTurnGate = RealtimeTurnGate()) { self.gate = gate }

        mutating func forward(
            requestId: String, sessionId: String,
            trigger: RealtimeTurnGate.Trigger, at now: Double
        ) {
            let turn = RealtimeTurnGate.Turn(requestId: requestId, sessionId: sessionId)
            guard servingTurn != turn else { return }
            let verdict = gate.admit(
                requestId: requestId, sessionId: sessionId, trigger: trigger, nowSeconds: now
            )
            logs.append(contentsOf: verdict.logs)
            guard verdict.isAdmitted else { return }
            transportFactoryCalls += 1
            servingTurn = turn
        }

        /// `endTurn(reason:)` / `lifecycleInterrupted(reason:)` 的收口点。
        mutating func endTurn() {
            servingTurn = nil
            logs.append(contentsOf: gate.flushSuppressionSummaries())
        }

        /// 通道进入 `.failed`：不再服务任何回合。
        mutating func fail(
            requestId: String, sessionId: String, wasActive: Bool, at now: Double
        ) {
            servingTurn = nil
            gate.noteFailure(
                requestId: requestId, sessionId: sessionId, wasActive: wasActive, nowSeconds: now
            )
        }

        var suppressedFirstCount: Int {
            logs.filter { if case .suppressed = $0 { return true } else { return false } }.count
        }

        var summaryCount: Int {
            logs.filter { if case .suppressedSummary = $0 { return true } else { return false } }.count
        }
    }

    /// **验收标准 1**：终态回合后持续送 20 帧上行——建通道 0 次，日志 ≤ 2 条。
    func testTwentyFramesOnAClosedTurnBuildNothingAndLogTwice() {
        var uplink = GateDrivenUplink()
        uplink.forward(requestId: rid, sessionId: sid, trigger: .turnStart, at: 0)
        XCTAssertEqual(uplink.transportFactoryCalls, 1, "stream.start 必须放行")

        uplink.fail(requestId: rid, sessionId: sid, wasActive: true, at: 1)

        // 真机是 ≈184ms 一帧；这里同节奏送 20 帧。
        for index in 0..<20 {
            uplink.forward(
                requestId: rid, sessionId: sid, trigger: .uplinkFrame,
                at: 1 + 0.184 * Double(index + 1)
            )
        }
        uplink.endTurn()

        XCTAssertEqual(
            uplink.transportFactoryCalls, 1,
            "终态回合的 20 帧一次都不许建通道（ESS-960 已钉，本单不得回退）"
        )
        XCTAssertLessThanOrEqual(uplink.logs.count, 2, "首次 + 汇总，最多两条")
        XCTAssertEqual(uplink.suppressedFirstCount, 1)
        XCTAssertEqual(uplink.summaryCount, 1)
        XCTAssertEqual(
            uplink.logs.first,
            .suppressed(requestId: rid, sessionId: sid, reason: "turn_closed_terminal", closedTurns: 1)
        )
        XCTAssertEqual(
            uplink.logs.last,
            .suppressedSummary(
                requestId: rid, sessionId: sid, reason: "turn_closed_terminal", total: 20
            )
        )
    }

    /// **验收标准 2 的单测对应物**：连续 5 轮，每轮各判死一次并被继续送帧，
    /// `realtime_reopen_suppressed`（首条事件）总数 ≤ 5。
    func testFiveConsecutiveTurnsEmitAtMostFiveFirstSuppressionLines() {
        var uplink = GateDrivenUplink()
        for turn in 0..<5 {
            let turnRid = "\(rid)-\(turn)"
            let base = Double(turn) * 10
            uplink.forward(requestId: turnRid, sessionId: sid, trigger: .turnStart, at: base)
            uplink.fail(requestId: turnRid, sessionId: sid, wasActive: true, at: base + 1)
            for index in 0..<40 {
                uplink.forward(
                    requestId: turnRid, sessionId: sid, trigger: .uplinkFrame,
                    at: base + 1 + 0.094 * Double(index + 1)
                )
            }
            uplink.endTurn()
        }
        XCTAssertEqual(uplink.suppressedFirstCount, 5, "每轮恰好一条首条事件")
        XCTAssertEqual(uplink.summaryCount, 5, "每轮恰好一条汇总")
        // 事故当天同样的 5 轮 × 40 帧会打 200 条。
        XCTAssertEqual(uplink.logs.count, 10)
    }

    /// 收口后仍有迟到帧进来，不得重新打一条「首条」——刷屏不许换个频率回来。
    func testLateFramesAfterFlushDoNotReopenTheLogFaucet() {
        var uplink = GateDrivenUplink()
        uplink.forward(requestId: rid, sessionId: sid, trigger: .turnStart, at: 0)
        uplink.fail(requestId: rid, sessionId: sid, wasActive: true, at: 1)
        for index in 0..<5 {
            uplink.forward(
                requestId: rid, sessionId: sid, trigger: .uplinkFrame, at: 2 + Double(index)
            )
        }
        uplink.endTurn()
        let afterFirstFlush = uplink.logs.count

        for index in 0..<5 {
            uplink.forward(
                requestId: rid, sessionId: sid, trigger: .uplinkFrame, at: 20 + Double(index)
            )
        }
        uplink.endTurn()

        XCTAssertEqual(afterFirstFlush, 2)
        XCTAssertEqual(uplink.suppressedFirstCount, 1, "首条只许有一条")
        XCTAssertEqual(uplink.logs.count, 3, "第二段只补一条汇总")
    }

    /// 只被压制一次的回合不出汇总——首条日志已经说完了，`total=1` 是纯噪音。
    func testSingleSuppressionEmitsNoSummary() {
        var uplink = GateDrivenUplink()
        uplink.forward(requestId: rid, sessionId: sid, trigger: .turnStart, at: 0)
        uplink.fail(requestId: rid, sessionId: sid, wasActive: true, at: 1)
        uplink.forward(requestId: rid, sessionId: sid, trigger: .uplinkFrame, at: 2)
        uplink.endTurn()

        XCTAssertEqual(uplink.logs.count, 1)
        XCTAssertEqual(uplink.summaryCount, 0)
    }

    /// 下一个 `stream.start` 也是收口点：上一轮的账在这里结清，本轮解封。
    func testNextTurnStartFlushesPreviousLedgerAndUnseals() {
        var uplink = GateDrivenUplink()
        uplink.forward(requestId: rid, sessionId: sid, trigger: .turnStart, at: 0)
        uplink.fail(requestId: rid, sessionId: sid, wasActive: true, at: 1)
        for index in 0..<8 {
            uplink.forward(
                requestId: rid, sessionId: sid, trigger: .uplinkFrame, at: 2 + Double(index)
            )
        }
        // 同一 (rid, sid) 复用：新一轮必须放行，且把上一轮的汇总带出来。
        uplink.forward(requestId: rid, sessionId: sid, trigger: .turnStart, at: 30)
        uplink.forward(requestId: rid, sessionId: sid, trigger: .uplinkFrame, at: 30.2)

        XCTAssertEqual(uplink.transportFactoryCalls, 2, "两次 stream.start 各建一次；解封后的那一帧复用同一条通道")
        XCTAssertEqual(uplink.suppressedFirstCount, 1)
        XCTAssertEqual(uplink.summaryCount, 1)
        XCTAssertEqual(
            uplink.logs.last,
            .suppressedSummary(
                requestId: rid, sessionId: sid, reason: "turn_closed_terminal", total: 8
            )
        )
    }

    // MARK: - 退避（要求 3：若保留任何重试，必须有退避）

    /// ESS-960 保留的有界握手重试此前**零退避**——同样是被上行帧泵出来的。
    /// 第 1 次握手失败后，`base` 秒内的帧一律不许再试。
    func testHandshakeRetryIsBackedOff() {
        var gate = RealtimeTurnGate(handshakeBackoffBase: 0.5)
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false, nowSeconds: 10)

        // 帧节奏 ≈184ms：退避窗口内的三帧都不许触发重连。
        for offset in [0.184, 0.368, 0.492] {
            XCTAssertFalse(
                gate.admit(
                    requestId: rid, sessionId: sid, trigger: .uplinkFrame, nowSeconds: 10 + offset
                ).isAdmitted,
                "退避窗口内不许重试（offset=\(offset)）"
            )
        }
        XCTAssertTrue(
            gate.admit(
                requestId: rid, sessionId: sid, trigger: .uplinkFrame, nowSeconds: 10.5
            ).isAdmitted,
            "退避到期后允许重试——ESS-960 的『握手从未成功仍可有界重试』不得被回退"
        )
    }

    /// 退避是指数的：第 2 次失败后要等 2×base。
    func testBackoffGrowsExponentially() {
        var gate = RealtimeTurnGate(maxHandshakeAttempts: 5, handshakeBackoffBase: 0.5)
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false, nowSeconds: 0)
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false, nowSeconds: 1)
        XCTAssertFalse(
            gate.admit(requestId: rid, sessionId: sid, trigger: .uplinkFrame, nowSeconds: 1.9)
                .isAdmitted
        )
        XCTAssertTrue(
            gate.admit(requestId: rid, sessionId: sid, trigger: .uplinkFrame, nowSeconds: 2.1)
                .isAdmitted
        )
    }

    /// `audio.commit` 是一轮的最后一帧，**不受退避约束**——退避要压的是高频
    /// 空转，不是把用户这一轮的收口吃掉（那等于用户白说一遍）。
    func testCommitIsExemptFromBackoff() {
        var gate = RealtimeTurnGate(handshakeBackoffBase: 5)
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: false, nowSeconds: 0)
        XCTAssertFalse(
            gate.admit(requestId: rid, sessionId: sid, trigger: .uplinkFrame, nowSeconds: 0.1)
                .isAdmitted
        )
        XCTAssertTrue(
            gate.admit(requestId: rid, sessionId: sid, trigger: .turnCommit, nowSeconds: 0.1)
                .isAdmitted,
            "退避窗口内 commit 仍须放行"
        )
    }

    /// 但终态回合连 commit 也不放——通道已经死了，送上去也只是空转。
    func testCommitIsStillBlockedOnATerminalTurn() {
        var gate = RealtimeTurnGate()
        gate.noteFailure(requestId: rid, sessionId: sid, wasActive: true, nowSeconds: 0)
        XCTAssertFalse(
            gate.admit(requestId: rid, sessionId: sid, trigger: .turnCommit, nowSeconds: 0.1)
                .isAdmitted
        )
    }

    /// 没失败过的回合一律放行——不能因为加了退避把正常链路拦住。
    func testHealthyTurnIsAlwaysAdmitted() {
        var gate = RealtimeTurnGate()
        for trigger in [RealtimeTurnGate.Trigger.uplinkFrame, .turnCommit, .receipt] {
            XCTAssertTrue(
                gate.admit(requestId: rid, sessionId: sid, trigger: trigger, nowSeconds: 0)
                    .isAdmitted
            )
        }
        XCTAssertTrue(gate.admit(
            requestId: rid, sessionId: sid, trigger: .turnStart, nowSeconds: 0
        ).logs.isEmpty)
    }

    /// 被容量挤出去的回合仍要把欠的汇总报出来——挤出是容量决策，不是丢证据。
    func testEvictedTurnStillReportsItsSummary() {
        var gate = RealtimeTurnGate(capacity: 2)
        gate.noteFailure(requestId: "rid-a", sessionId: sid, wasActive: true, nowSeconds: 0)
        for _ in 0..<6 {
            _ = gate.admit(
                requestId: "rid-a", sessionId: sid, trigger: .uplinkFrame, nowSeconds: 1
            )
        }
        gate.noteFailure(requestId: "rid-b", sessionId: sid, wasActive: true, nowSeconds: 2)
        gate.noteFailure(requestId: "rid-c", sessionId: sid, wasActive: true, nowSeconds: 3)

        let logs = gate.flushSuppressionSummaries()
        XCTAssertEqual(
            logs,
            [.suppressedSummary(
                requestId: "rid-a", sessionId: sid, reason: "turn_closed_terminal", total: 6
            )]
        )
    }
}
