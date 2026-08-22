import XCTest
@testable import WristAgentCore

/// ESS-1047：同一 request_id 已 `completed` 之后到达的迟到 `failed`。
///
/// 状态机会吸收掉它（`apply` 返回 false），ESS-1044 的终态失败信号仍然照发，
/// 于是订阅方**必须**能分辨「是谁吸收的」——被 `.completed` 吸收说明这一轮
/// 其实成功了，会话层不得据此判失败。本套用例钉住 journal 侧的分类依据：
/// 信号带出的 `currentState` 就是吸收方终态。
///
/// 会话侧「不进 P6」的生产接线回归在
/// `WatchTests/Ess1047CompletedWinsLateFailureTests`（Watch target）。
@MainActor
final class Ess1047CompletedWinsLateFailureTests: XCTestCase {
    private let requestId = "019fbbdd-5c39-70fa-9760-dc262ee092b1"

    private func makeJournal() -> VoiceTurnJournal {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess1047-journal-\(UUID().uuidString)")
        return VoiceTurnJournal(directory: dir)
    }

    private func lateFailure() -> VoiceStatusEnvelope {
        .status(
            requestId: requestId, state: .failed,
            detail: "助手这边还没准备好", failureStage: .execution,
            errorCode: "ERR_VOICE_BUSY"
        )
    }

    /// completed 吸收的迟到 failed：信号仍发，但 `currentState == .completed`
    /// ——这是订阅方判 success-wins 的唯一依据，丢了它就只能误杀成功回合。
    func testLateFailureAfterCompletedCarriesCompletedAsCurrentState() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        XCTAssertTrue(journal.apply(.status(requestId: requestId, state: .completed)))

        var observed: [(Bool, VoiceTurnState)] = []
        journal.onTerminalFailure = { _, _, applied, state in observed.append((applied, state)) }

        XCTAssertFalse(journal.apply(lateFailure()), "completed 之后 failed 必被吸收")

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, false)
        XCTAssertEqual(observed.first?.1, .completed,
                       "必须是 completed —— 订阅方据此保成功回合不被收口")
    }

    /// 成功回合的终态与载荷不得被迟到 failed 改写（回滚路径的既有语义）。
    func testLateFailureDoesNotDegradeCompletedTurn() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        XCTAssertTrue(journal.apply(
            .status(requestId: requestId, state: .completed,
                    result: VoiceResultPayload(
                        summary: "今天是星期五", isTruncated: false,
                        speechSha256: nil, speechDurationMs: nil
                    ))
        ))

        XCTAssertFalse(journal.apply(lateFailure()))

        let turn = journal.turn(withId: requestId)
        XCTAssertEqual(turn?.currentState, .completed)
        XCTAssertNil(turn?.errorCode, "被拒的 failed 不得把成功回合染成有错误码")
        XCTAssertEqual(turn?.result?.summary, "今天是星期五")
    }
}
