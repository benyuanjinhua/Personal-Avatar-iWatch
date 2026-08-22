import XCTest
@testable import WristAgentCore

/// ESS-1004 —— 客户端等待预算与 Gateway 回合终态之间的排序不变量。
///
/// 事故（真机 2026-08-22，包 `d5763b6`，`request_id=01a02909-23dc`）：
/// 多段回答两段都出声、末段播完（`play_finished bytes_played=1805000`），
/// 但回合终态从未下发（`downlink_done` 4/4 回合为 0 次）。客户端在
/// `markAnswerInterim` 处重新武装 45 s，10:35:47.740 到点报
/// `session_thinking_hard_timeout` →「回答超时」→ 10:36:03 自动挂断，
/// 下一问落进一个正在重启的 App。
///
/// Gateway 侧 `agent_turn_idle_backstop_ms` 当时同样是 45 s ——
/// 两个截止时间数值完全相同，谁先触发只看调度顺序。本文件把「客户端必须
/// 输掉这场比赛，而且要输得足够多」钉成可复核的不变量。
///
/// 对侧的同一组约束由 `AudioRealtimeGateway/test/ess1004-turn-terminal-budget.test.mjs`
/// 从 `config.json` 一侧钉住；两边共用同一组常量名与数值。
final class Ess1004TurnTerminalBudgetTests: XCTestCase {

    /// 核心不变量：客户端硬超时必须显著晚于 Gateway 的回合终态 + 送达余量。
    func testClientHardTimeoutOutlastsGatewayTurnTerminal() {
        let gatewayTerminal = AudioRealtimeAgentConfig.gatewayTurnIdleBackstop
        let margin = AudioRealtimeAgentConfig.turnTerminalDeliveryMargin
        let separation = AudioRealtimeAgentConfig.turnTerminalRequiredSeparation
        let clientTimeout = AudioRealtimeAgentConfig.clientThinkingHardTimeout

        XCTAssertGreaterThanOrEqual(
            clientTimeout,
            gatewayTerminal + margin + separation,
            """
            客户端硬超时(\(clientTimeout)s) 必须 ≥ Gateway 回合终态(\(gatewayTerminal)s)
            + 送达余量(\(margin)s) + 必需间隔(\(separation)s)。
            不满足时客户端会先到点，把一个正在正常收口的回合判成「回答超时」并挂断。
            """
        )
    }

    /// ESS-1004 点名的竞态本身：两个 45 s。相等即不合格，与哪个数无关。
    func testClientHardTimeoutIsNotEqualToGatewayTurnTerminal() {
        XCTAssertNotEqual(
            AudioRealtimeAgentConfig.clientThinkingHardTimeout,
            AudioRealtimeAgentConfig.gatewayTurnIdleBackstop,
            "两个截止时间相等时谁先触发全看调度顺序 —— 真机上客户端每次都先到"
        )
    }

    /// 间隔必须是正的、且不是一个装饰性的小数。8 s 的依据见常量注释。
    func testRequiredSeparationIsMeaningful() {
        XCTAssertGreaterThanOrEqual(
            AudioRealtimeAgentConfig.turnTerminalRequiredSeparation, 5.0,
            "间隔小于一次 WAN 往返 + 调度抖动时，等于没有间隔"
        )
        XCTAssertGreaterThan(AudioRealtimeAgentConfig.turnTerminalDeliveryMargin, 0)
    }

    /// Gateway 终态不得被调到「段落之间的正常停顿」以下 —— 那会把还在
    /// 继续说话的回合砍掉，正是 ESS-969 存在的理由。
    ///
    /// 实测下界（`AudioRealtimeGateway/logs/gateway.log`，2026-08-22，n=4，
    /// 该窗口全部多段回合）：`upstream_segment_closed` → 下一段
    /// `upstream_response_started` = 15.054 / 15.157 / 14.954 / 0.363 s。
    func testGatewayTurnTerminalStaysAboveObservedSegmentGap() {
        let observedSlowestSegmentGap: TimeInterval = 15.157
        XCTAssertGreaterThanOrEqual(
            AudioRealtimeAgentConfig.gatewayTurnIdleBackstop,
            2 * observedSlowestSegmentGap,
            "回合终态必须 ≥ 实测最慢段间隔的 2 倍，否则会在上游还要说下一段时提前收口"
        )
    }
}
