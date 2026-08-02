import XCTest
@testable import WristAgentCore

/// ESS-55 触觉 cue 策略：状态族映射 + 同回合去重。
final class VoiceInteractionCueTests: XCTestCase {
    private let requestId = UUIDv7.generate().uuidString.lowercased()

    func testAcceptedFamilyFiresOnceEvenAcrossStates() {
        // 受理允许跳过 accepted 直达 processing；同一回合「受理」只震一次。
        var policy = VoiceCuePolicy()
        XCTAssertEqual(policy.cue(for: .accepted, requestId: requestId), .taskAccepted)
        XCTAssertNil(policy.cue(for: .realtimeProcessing, requestId: requestId))
        XCTAssertNil(policy.cue(for: .backgroundProcessing, requestId: requestId))
    }

    func testSkippingAcceptedStillFiresOnProcessing() {
        var policy = VoiceCuePolicy()
        XCTAssertEqual(policy.cue(for: .backgroundProcessing, requestId: requestId), .taskAccepted)
    }

    func testCompletedAndFailedMapToTerminalCues() {
        var policy = VoiceCuePolicy()
        XCTAssertEqual(policy.cue(for: .completed, requestId: requestId), .resultArrived)
        let other = UUIDv7.generate().uuidString.lowercased()
        XCTAssertEqual(policy.cue(for: .failed, requestId: other), .turnFailed)
    }

    func testWaitingStatesProduceNoCue() {
        // 等待态靠屏幕文案表达，触觉留给关键节点，避免震动疲劳。
        var policy = VoiceCuePolicy()
        for state: VoiceTurnState in [.recorded, .waitingForPhone, .waitingForMac, .permissionRequired, .cancelled] {
            XCTAssertNil(policy.cue(for: state, requestId: requestId), "\(state) 不应触发触觉")
        }
    }

    func testIndependentRequestsDoNotShareDedup() {
        var policy = VoiceCuePolicy()
        let a = UUIDv7.generate().uuidString.lowercased()
        let b = UUIDv7.generate().uuidString.lowercased()
        XCTAssertEqual(policy.cue(for: .accepted, requestId: a), .taskAccepted)
        XCTAssertEqual(policy.cue(for: .accepted, requestId: b), .taskAccepted)
    }
}
