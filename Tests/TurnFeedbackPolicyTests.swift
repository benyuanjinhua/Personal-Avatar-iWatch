import XCTest
@testable import WristAgentCore

final class TurnFeedbackPolicyTests: XCTestCase {
    // 冷启动静默 seed：重开 App 恢复的存量回合（含终态）不补发触觉。
    func testFirstSnapshotSeedsSilently() {
        var policy = TurnFeedbackPolicy()
        let events = policy.observe(turns: [("a", .completed), ("b", .waitingForMac)])
        XCTAssertTrue(events.isEmpty, "首次快照不应产生任何反馈事件")
    }

    // 主链路：录音 → 送达手机 → 受理 → 处理 → 完成，每个提示节点只触发一次。
    func testHappyPathEmitsEachEventOnce() {
        var policy = TurnFeedbackPolicy()
        _ = policy.observe(turns: [])

        XCTAssertEqual(policy.observe(turns: [("t1", .recorded)]), [], "录音落账不打扰")
        XCTAssertEqual(policy.observe(turns: [("t1", .waitingForMac)]), [.deliveredToPhone])
        XCTAssertEqual(policy.observe(turns: [("t1", .waitingForMac)]), [], "重复快照不重复提示")
        XCTAssertEqual(policy.observe(turns: [("t1", .accepted)]), [.accepted])
        XCTAssertEqual(policy.observe(turns: [("t1", .realtimeProcessing)]), [], "处理中不打扰")
        XCTAssertEqual(policy.observe(turns: [("t1", .completed)]), [.completed])
        XCTAssertEqual(policy.observe(turns: [("t1", .completed)]), [], "终态吸收后不再提示")
    }

    // 快照可能合并多步变迁（如 recorded 直接跳 completed）：只对最新状态提示一次。
    func testCoalescedTransitionEmitsLatestOnly() {
        var policy = TurnFeedbackPolicy()
        _ = policy.observe(turns: [])
        _ = policy.observe(turns: [("t1", .recorded)])
        XCTAssertEqual(policy.observe(turns: [("t1", .completed)]), [.completed])
    }

    func testFailureAndConfirmationEvents() {
        var policy = TurnFeedbackPolicy()
        _ = policy.observe(turns: [])
        _ = policy.observe(turns: [("t1", .recorded)])
        XCTAssertEqual(policy.observe(turns: [("t1", .permissionRequired)]), [.needsConfirmation])
        XCTAssertEqual(policy.observe(turns: [("t1", .failed)]), [.failed])
    }

    // 多回合并存：各自独立去重，事件按快照顺序返回。
    func testMultipleTurnsTrackedIndependently() {
        var policy = TurnFeedbackPolicy()
        _ = policy.observe(turns: [])
        _ = policy.observe(turns: [("t1", .waitingForMac), ("t2", .recorded)])
        // 第二次观察：t1 无变化，t2 完成。
        var events = policy.observe(turns: [("t1", .waitingForMac), ("t2", .completed)])
        XCTAssertEqual(events, [.completed])
        // 第三次：t1 失败。
        events = policy.observe(turns: [("t1", .failed), ("t2", .completed)])
        XCTAssertEqual(events, [.failed])
    }

    // 回合被裁剪出 journal 后不残留状态（不影响后续判断）。
    func testPrunedTurnsForgotten() {
        var policy = TurnFeedbackPolicy()
        _ = policy.observe(turns: [])
        _ = policy.observe(turns: [("t1", .waitingForMac)])
        _ = policy.observe(turns: [])
        // t1 重新出现（理论上不会发生，防御性）：视为新回合，按当前状态提示。
        XCTAssertEqual(policy.observe(turns: [("t1", .completed)]), [.completed])
    }

    // 验收：每种失败环节都有差异化、非空的恢复提示（ESS-53 §5）。
    func testFailureStagesHaveDistinctRecoveryHints() {
        let stages: [VoiceFailureStage] = [.phoneUnreachable, .macUnreachable, .execution]
        let hints = stages.map(\.recoveryHint)
        for hint in hints {
            XCTAssertFalse(hint.isEmpty)
        }
        XCTAssertEqual(Set(hints).count, stages.count, "恢复提示必须按失败环节可区分")
    }

    // failed 投影的副标题应直接给出恢复提示，而不是笼统文案。
    func testFailedPhaseSubtitleUsesRecoveryHint() {
        let phase = VoiceTurnState.failed.phase(failureStage: .phoneUnreachable)
        XCTAssertEqual(phase.subtitle, VoiceFailureStage.phoneUnreachable.recoveryHint)
    }
}
