import XCTest
@testable import WristAgentCore

/// ESS-1044：`VoiceTurnJournal.onTerminalFailure` —— 终态失败信号必须
/// **不看状态机是否接受**都发出去。
///
/// 真机 2026-08-22「今天星期几」：
/// ```
/// 14:00:00.407  session_turn_committed phase=thinking
/// 14:00:04.455  relay_status phase=failed "助手这边还没准备好"
/// 14:00:04.456  relay_terminal_failure_projected applied=false failure_stage=execution
/// 14:00:45      session_thinking_hard_timeout          ← 干等 41 秒
/// ```
/// `applied=false` 时旧路径只落一行日志、`onStateApplied` 不触发，会话层
/// 收不到任何失败通知，只能等 45s 硬超时。本套用例钉住两条路径都发信号。
@MainActor
final class Ess1044TerminalFailureSignalTests: XCTestCase {
    private let requestId = "019fbbdd-5c39-70fa-9760-dc262ee092b0"

    private func makeJournal() -> VoiceTurnJournal {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess1044-journal-\(UUID().uuidString)")
        return VoiceTurnJournal(directory: dir)
    }

    private func failedEnvelope(errorCode: String? = "ERR_VOICE_BUSY") -> VoiceStatusEnvelope {
        .status(
            requestId: requestId, state: .failed,
            detail: "助手这边还没准备好", failureStage: .execution,
            errorCode: errorCode
        )
    }

    /// 状态机接受时照常发信号，且带上已锁定的 error_code。
    func testAppliedFailureFiresSignal() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        var observed: [(String, String?, Bool)] = []
        journal.onTerminalFailure = { rid, code, applied in observed.append((rid, code, applied)) }

        XCTAssertTrue(journal.apply(failedEnvelope()))

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, requestId)
        XCTAssertEqual(observed.first?.1, "ERR_VOICE_BUSY")
        XCTAssertEqual(observed.first?.2, true)
    }

    /// 本单核心回归：回合已终态 → `apply` 返回 false、`onStateApplied` 不触发，
    /// 但 `onTerminalFailure` **必须**照发（applied=false），否则会话层无从收口。
    func testRejectedFailureStillFiresSignal() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        // 先把回合推到终态，让后到的 failed 被状态机拒绝（真机 applied=false 的成因）。
        XCTAssertTrue(journal.apply(.status(requestId: requestId, state: .cancelled)))

        var stateApplied: [VoiceTurnState] = []
        var observed: [(String, String?, Bool)] = []
        journal.onStateApplied = { _, state in stateApplied.append(state) }
        journal.onTerminalFailure = { rid, code, applied in observed.append((rid, code, applied)) }

        XCTAssertFalse(journal.apply(failedEnvelope()), "终态吸收，转移仍应被拒")

        XCTAssertTrue(stateApplied.isEmpty, "转移被拒时 onStateApplied 不该触发（既有语义不变）")
        XCTAssertEqual(observed.count, 1, "但终态失败信号必须照发")
        XCTAssertEqual(observed.first?.0, requestId)
        XCTAssertEqual(observed.first?.1, "ERR_VOICE_BUSY", "被拒路径回滚了 errorCode，只能取信封上的码")
        XCTAssertEqual(observed.first?.2, false)
    }

    /// 非失败终态（completed）不得误发失败信号。
    func testCompletedDoesNotFireSignal() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        var fired = 0
        journal.onTerminalFailure = { _, _, _ in fired += 1 }

        XCTAssertTrue(journal.apply(.status(requestId: requestId, state: .completed)))
        // 重复 completed 被拒，同样不发。
        XCTAssertFalse(journal.apply(.status(requestId: requestId, state: .completed)))

        XCTAssertEqual(fired, 0)
    }

    /// 坏信封（校验不过）不发信号——不能让一个解不开的包把会话打进 P6。
    func testInvalidEnvelopeDoesNotFireSignal() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        var fired = 0
        journal.onTerminalFailure = { _, _, _ in fired += 1 }

        let broken = VoiceStatusEnvelope.status(requestId: "", state: .failed)
        XCTAssertNotNil(broken.validate(), "空 request_id 必须校验不过")
        XCTAssertFalse(journal.apply(broken))

        XCTAssertEqual(fired, 0)
    }
}
