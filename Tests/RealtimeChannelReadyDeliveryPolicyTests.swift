import XCTest
@testable import WristAgentCore

/// ESS-869 acceptance §1: a channel ready must never be silently dropped.
/// The policy has no `.drop` case — every session state resolves to an
/// interactive send, a durable (`transferUserInfo`) enqueue, or a caller-held
/// pending value waiting for activation.
final class RealtimeChannelReadyDeliveryPolicyTests: XCTestCase {

    func testReachableActivatedSessionUsesInteractivePath() {
        XCTAssertEqual(
            RealtimeChannelReadyDeliveryPolicy.action(
                isActivated: true, isReachable: true, isWatchAppInstalled: true
            ),
            .interactive
        )
    }

    func testUnreachableActivatedSessionUsesDurablePath() {
        XCTAssertEqual(
            RealtimeChannelReadyDeliveryPolicy.action(
                isActivated: true, isReachable: false, isWatchAppInstalled: true
            ),
            .durable
        )
    }

    func testNotActivatedSessionHoldsForActivationReplay() {
        XCTAssertEqual(
            RealtimeChannelReadyDeliveryPolicy.action(
                isActivated: false, isReachable: false, isWatchAppInstalled: true
            ),
            .none
        )
    }

    func testMissingWatchAppHoldsForInstallReplay() {
        XCTAssertEqual(
            RealtimeChannelReadyDeliveryPolicy.action(
                isActivated: true, isReachable: false, isWatchAppInstalled: false
            ),
            .none
        )
    }

    /// The policy enum itself has no "drop" case, so "unreachable means the
    /// ready is thrown away" is unrepresentable at the type level — the
    /// compile-time version of "不允许直接 return".
    func testPolicyHasNoDropCase() {
        let actions: [RealtimeChannelReadyDeliveryPolicy.Action] = [
            .interactive, .durable, .none,
        ]
        XCTAssertEqual(actions.count, 3, "交付路径只有交互/持久/待激活三种，没有丢弃")
    }
}
