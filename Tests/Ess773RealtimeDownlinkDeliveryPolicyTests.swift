import XCTest
@testable import WristAgentCore

final class Ess773RealtimeDownlinkDeliveryPolicyTests: XCTestCase {
    func testReachableSessionUsesExactlyOneInteractivePath() {
        XCTAssertEqual(
            RealtimeDownlinkDeliveryPolicy.route(isActivated: true, isReachable: true),
            .interactiveOnly
        )
    }

    func testInactiveOrUnreachableSessionUsesDurablePath() {
        XCTAssertEqual(
            RealtimeDownlinkDeliveryPolicy.route(isActivated: false, isReachable: true),
            .durableOnly
        )
        XCTAssertEqual(
            RealtimeDownlinkDeliveryPolicy.route(isActivated: true, isReachable: false),
            .durableOnly
        )
    }

    func testRealtimeDurableFallbackDoesNotAddSecondInteractiveCopy() {
        XCTAssertFalse(
            RealtimeDownlinkDeliveryPolicy.shouldAddInteractiveCopyToDurable(
                messageKey: RealtimeMediaMessage.downlinkEnvelopeKey
            )
        )
        XCTAssertTrue(
            RealtimeDownlinkDeliveryPolicy.shouldAddInteractiveCopyToDurable(
                messageKey: "idempotent.status"
            )
        )
    }
}
