import XCTest
@testable import WristAgentCore

final class VoiceTurnStateTests: XCTestCase {
    // 验收：全部状态在 UI 有明确、可理解的展示。
    func testEveryStateHasReadableDisplay() {
        for state in VoiceTurnState.allCases {
            XCTAssertFalse(state.displayTitle.isEmpty, "\(state.rawValue) 缺少标题")
            XCTAssertFalse(state.displaySymbol.isEmpty, "\(state.rawValue) 缺少图标")
            let phase = state.phase()
            XCTAssertFalse(phase.title.isEmpty, "\(state.rawValue) 的投影缺少标题")
            XCTAssertFalse(phase.subtitle.isEmpty, "\(state.rawValue) 的投影缺少说明")
        }
    }

    func testRawValuesMatchProtocolContract() {
        XCTAssertEqual(VoiceTurnState.waitingForPhone.rawValue, "waiting_for_phone")
        XCTAssertEqual(VoiceTurnState.waitingForMac.rawValue, "waiting_for_mac")
        XCTAssertEqual(VoiceTurnState.realtimeProcessing.rawValue, "realtime_processing")
        XCTAssertEqual(VoiceTurnState.backgroundAccepted.rawValue, "background_accepted")
        XCTAssertEqual(VoiceTurnState.backgroundProcessing.rawValue, "background_processing")
        XCTAssertEqual(VoiceTurnState.permissionRequired.rawValue, "permission_required")
    }

    func testForwardTransitionsAllowed() {
        XCTAssertTrue(VoiceTurnState.recorded.canTransition(to: .waitingForPhone))
        XCTAssertTrue(VoiceTurnState.recorded.canTransition(to: .accepted), "跳过中间等待态应被允许")
        XCTAssertTrue(VoiceTurnState.accepted.canTransition(to: .realtimeProcessing))
        XCTAssertTrue(VoiceTurnState.realtimeProcessing.canTransition(to: .backgroundAccepted))
        XCTAssertTrue(VoiceTurnState.backgroundProcessing.canTransition(to: .permissionRequired))
        XCTAssertTrue(VoiceTurnState.backgroundProcessing.canTransition(to: .completed))
    }

    func testPermissionRequiredCanResumeBackgroundProcessing() {
        XCTAssertTrue(VoiceTurnState.permissionRequired.canTransition(to: .backgroundProcessing))
    }

    func testBackwardAndDuplicateTransitionsRejected() {
        XCTAssertFalse(VoiceTurnState.accepted.canTransition(to: .waitingForPhone))
        XCTAssertFalse(VoiceTurnState.backgroundProcessing.canTransition(to: .accepted))
        XCTAssertFalse(VoiceTurnState.accepted.canTransition(to: .accepted))
    }

    func testTerminalStatesAbsorb() {
        for terminal in [VoiceTurnState.completed, .failed, .cancelled] {
            XCTAssertTrue(terminal.isTerminal)
            for next in VoiceTurnState.allCases {
                XCTAssertFalse(terminal.canTransition(to: next), "\(terminal) 不应再转移到 \(next)")
            }
        }
    }

    func testAnyActiveStateCanFailOrCancel() {
        for state in VoiceTurnState.allCases where !state.isTerminal {
            XCTAssertTrue(state.canTransition(to: .failed))
            XCTAssertTrue(state.canTransition(to: .cancelled))
        }
    }

    // 验收：失败原因可区分（等待手机 / 等待 Mac / 执行失败）。
    func testFailureStagesAreDistinguishable() {
        let titles = Set([
            VoiceTurnPhase.failed(.phoneUnreachable).title,
            VoiceTurnPhase.failed(.macUnreachable).title,
            VoiceTurnPhase.failed(.execution).title
        ])
        XCTAssertEqual(titles.count, 3, "三种失败原因的文案必须互不相同")
    }

    func testFailureStageInference() {
        XCTAssertEqual(VoiceFailureStage.inferred(from: .waitingForPhone), .phoneUnreachable)
        XCTAssertEqual(VoiceFailureStage.inferred(from: .recorded), .phoneUnreachable)
        XCTAssertEqual(VoiceFailureStage.inferred(from: .waitingForMac), .macUnreachable)
        XCTAssertEqual(VoiceFailureStage.inferred(from: .backgroundProcessing), .execution)
    }

    func testPhaseProjectionCoversContract() {
        XCTAssertEqual(VoiceTurnState.accepted.phase(), .delivered)
        XCTAssertEqual(VoiceTurnState.realtimeProcessing.phase(), .processing(background: false))
        XCTAssertEqual(VoiceTurnState.backgroundProcessing.phase(), .processing(background: true))
        XCTAssertEqual(VoiceTurnState.permissionRequired.phase(), .needsConfirmation)
        XCTAssertEqual(VoiceTurnState.completed.phase(), .completed)
        XCTAssertEqual(VoiceTurnState.failed.phase(failureStage: .macUnreachable), .failed(.macUnreachable))
        XCTAssertEqual(VoiceTurnState.failed.phase(), .failed(.execution), "缺省失败阶段应回退到执行失败")
    }
}
