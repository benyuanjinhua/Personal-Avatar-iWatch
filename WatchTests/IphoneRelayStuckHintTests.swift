import XCTest
@testable import WristAgent_Watch_App

/// ESS-258 / Gap-2：15s 无 iPhone 回执时的屏幕提示（D3 铁律 1）。
/// 覆盖 WatchContentView.stuckRequestIdToShow 的展示决策：只有回合仍活跃
/// 且 requestId 落进 stuck 集合时才亮，回执到达（→ cancelIphoneRelayWatchdog
/// 移出集合）后立刻撤下，且不残留。终态回合不再亮，避免与失败终态并置。
@MainActor
final class IphoneRelayStuckHintTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)

    private func turn(requestId: String, terminal: Bool = false) -> VoiceTurnRecord {
        var events: [VoiceTurnEvent] = [VoiceTurnEvent(state: .recorded, at: start)]
        if terminal {
            events.append(VoiceTurnEvent(state: .completed, at: start.addingTimeInterval(1)))
        }
        return VoiceTurnRecord(requestId: requestId, createdAt: start, events: events)
    }

    func testHiddenWhenNoActiveTurn() {
        XCTAssertNil(WatchContentView.stuckRequestIdToShow(
            activeTurn: nil, stuckRequestIds: ["req_x"]
        ))
    }

    func testHiddenWhenStuckSetEmpty() {
        XCTAssertNil(WatchContentView.stuckRequestIdToShow(
            activeTurn: turn(requestId: "req_1"), stuckRequestIds: []
        ))
    }

    func testShownWhenActiveTurnStuck() {
        XCTAssertEqual(
            WatchContentView.stuckRequestIdToShow(
                activeTurn: turn(requestId: "req_1"), stuckRequestIds: ["req_1"]
            ),
            "req_1",
            "D3 铁律 1：15s 无回执触觉响时屏幕必须有对应格子"
        )
    }

    func testHiddenWhenStuckSetHasOtherRequest() {
        XCTAssertNil(WatchContentView.stuckRequestIdToShow(
            activeTurn: turn(requestId: "req_1"), stuckRequestIds: ["req_other"]
        ), "提示与活跃回合绑定，别的历史回合不能借用格子")
    }

    func testHiddenWhenActiveTurnAlreadyTerminal() {
        XCTAssertNil(WatchContentView.stuckRequestIdToShow(
            activeTurn: turn(requestId: "req_done", terminal: true),
            stuckRequestIds: ["req_done"]
        ), "回合进终态后失败卡片已接管，非终态提示不再重叠")
    }

    /// R-02.1 运行时证据：banner 挂载即通过 WatchLog 落一条
    /// `ui/iphone_relay_stuck_shown`。它与 transport 侧的 `iphone_relay_stuck`
    /// 及 `haptic/haptic_played`（.turnFailed）成对出现，证明「触觉 + 屏幕
    /// 格子」同回合同时到位（D3 铁律 1）。日志字段变了会打断 log-shipper 解析口径，
    /// 本用例把 event/detail 都钉死，任何改动都要显式过用例。
    func testStuckHintLogEventMatchesShipperContract() {
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [(module: String, event: String, detail: String?)] = []
            func record(module: String, event: String, detail: String?) {
                lock.lock(); defer { lock.unlock() }
                events.append((module, event, detail))
            }
            func snapshot() -> [(module: String, event: String, detail: String?)] {
                lock.lock(); defer { lock.unlock() }
                return events
            }
        }
        let sink = Sink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        defer { WatchLog.setObserver(nil) }

        WatchContentView.logIphoneRelayStuckShown(requestId: "req_r02_evidence")

        let hit = sink.snapshot().first { $0.module == "ui" && $0.event == "iphone_relay_stuck_shown" }
        XCTAssertNotNil(hit, "R-02.1：屏幕格子挂载必须落一条 iphone_relay_stuck_shown")
        XCTAssertEqual(hit?.detail, "surface=main_screen",
                       "detail 变了会打断 log-shipper 解析口径，改前请更新脚本")
    }

    func testClearingStuckSetHidesHintImmediately() {
        // 模拟 cancelIphoneRelayWatchdog 收到回执后清空集合的动作。
        let activeTurn = turn(requestId: "req_2")
        var stuckIds: Set<String> = ["req_2"]
        XCTAssertEqual(
            WatchContentView.stuckRequestIdToShow(activeTurn: activeTurn, stuckRequestIds: stuckIds),
            "req_2"
        )
        stuckIds.remove("req_2")
        XCTAssertNil(
            WatchContentView.stuckRequestIdToShow(activeTurn: activeTurn, stuckRequestIds: stuckIds),
            "回执到达后 SwiftUI 依赖 @Published 集合变化自动撤下 banner，无残留"
        )
    }
}
