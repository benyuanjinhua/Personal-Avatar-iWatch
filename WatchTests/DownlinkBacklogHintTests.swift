import XCTest
@testable import WristAgent_Watch_App

/// ESS-307 (D5 Gap-7)：下行队列积压可见性单元测试。
///
/// 覆盖验收标准：
/// - Given 队列有 N 条积压、当前无处理中回合 → 提示显示
/// - Given 队列有积压、当前有处理中回合 → 提示不显示（处理中优先）
/// - Given 队列清空 → 提示不显示
/// - Given 队列有 0 条积压 → 提示不显示（边界）
@MainActor
final class DownlinkBacklogHintTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)

    // MARK: - 辅助：构造 VoiceTurnRecord

    private func turn(requestId: String, terminal: Bool = false) -> VoiceTurnRecord {
        var events: [VoiceTurnEvent] = [VoiceTurnEvent(state: .recorded, at: start)]
        if terminal {
            events.append(VoiceTurnEvent(state: .completed, at: start.addingTimeInterval(1)))
        }
        return VoiceTurnRecord(requestId: requestId, createdAt: start, events: events)
    }

    // MARK: - 0 条积压：不显示

    func testHiddenWhenZeroBacklogNoActiveTurn() {
        XCTAssertFalse(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 0, activeTurn: nil
            ),
            "积压 0 时无论有无活跃回合都不显示"
        )
    }

    func testHiddenWhenZeroBacklogWithActiveTurn() {
        XCTAssertFalse(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 0, activeTurn: turn(requestId: "req_1")
            ),
            "积压 0 + 有活跃回合也不显示（不抢位但数量为 0 时不应有任何提示）"
        )
    }

    // MARK: - 1 条积压：无活跃回合时显示

    func testShownWhen1BacklogNoActiveTurn() {
        XCTAssertTrue(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 1, activeTurn: nil
            ),
            "有 1 条积压且无活跃回合时显示提示"
        )
    }

    // MARK: - N 条积压：无活跃回合时显示

    func testShownWhenNBacklogNoActiveTurn() {
        XCTAssertTrue(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 5, activeTurn: nil
            ),
            "有 5 条积压且无活跃回合时显示提示"
        )
    }

    // MARK: - 处理中优先级：活跃回合隐藏积压提示

    func testHiddenWhenActiveTurnProcessingEvenWithBacklog() {
        XCTAssertFalse(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 3, activeTurn: turn(requestId: "req_active")
            ),
            "正在处理回合时优先显示处理中状态，积压提示不抢位"
        )
    }

    // MARK: - 终态回合：积压可见（回合已终态，不算「处理中」）

    func testShownWhenActiveTurnTerminalWithBacklog() {
        XCTAssertTrue(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 2, activeTurn: turn(requestId: "req_done", terminal: true)
            ),
            "回合进终态后视为「无处理中回合」，积压提示可见"
        )
    }

    // MARK: - 清空后消失：count 归零立即不显示

    func testDisappearsWhenBacklogCleared() {
        // 先有积压显示，清空后消失
        XCTAssertTrue(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 2, activeTurn: nil
            ),
            "有积压时显示"
        )
        XCTAssertFalse(
            WatchContentView.shouldShowDownlinkBacklogHint(
                backlogCount: 0, activeTurn: nil
            ),
            "积压清空（最后一条投递完成）后提示立即消失，不残留"
        )
    }
}
