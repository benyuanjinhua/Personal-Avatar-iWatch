import XCTest
@testable import WristAgentCore

/// ESS-1100：回合级进展叙述的全部判定规则。
///
/// 这些用例覆盖本单验收 1 点名的失败面里、属于**纯逻辑**的那几条：
/// 多条进展、重复、乱序、空文本、小屏截断。跨回合污染与「idle 早到」是
/// 会话层的事实，钉在 `WatchTests/Ess1100ThinkingProgressTests.swift`。
final class ToolProgressNarrationTests: XCTestCase {

    // MARK: - 载荷

    func testProgressPayloadRequiresText() {
        XCTAssertNil(AgentTaskProgress(sequence: 1, text: nil, category: "search"))
        XCTAssertNil(AgentTaskProgress(sequence: 1, text: "", category: "search"))
        XCTAssertNil(AgentTaskProgress(sequence: 1, text: "   \n ", category: "search"))
        XCTAssertNotNil(AgentTaskProgress(sequence: 1, text: "正在查询相关信息", category: "search"))
    }

    func testProgressPayloadNormalisesEmptyCategoryToNil() {
        let progress = AgentTaskProgress(sequence: 1, text: "正在查询相关信息", category: "")
        XCTAssertNil(progress?.category)
    }

    // MARK: - 多条进展依次更新

    func testConsecutiveProgressReplacesPreviousLine() {
        var narration = ToolProgressNarration()

        XCTAssertEqual(narration.apply(sequence: 1, text: "正在查询相关信息", category: "search"), .applied)
        XCTAssertEqual(narration.text, "正在查询相关信息")
        XCTAssertEqual(narration.apply(sequence: 2, text: "正在读取相关内容", category: "read"), .applied)
        XCTAssertEqual(narration.text, "正在读取相关内容")
        XCTAssertEqual(narration.category, "read")
        XCTAssertEqual(narration.latestSequence, 2)
        XCTAssertEqual(narration.appliedCount, 2)
        XCTAssertEqual(narration.droppedCount, 0)
    }

    /// 首条进展不需要等最终回答——收到就显示，这正是本单要消灭的「只有笼统
    /// 的正在思考」那个体验。
    func testFirstProgressIsVisibleImmediately() {
        var narration = ToolProgressNarration()
        XCTAssertFalse(narration.hasProgress)

        narration.apply(sequence: 1, text: "正在查询相关信息", category: "search")

        XCTAssertTrue(narration.hasProgress)
    }

    // MARK: - 重复 / 乱序

    func testDuplicateSequenceIsDropped() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 7, text: "正在查询相关信息", category: "search")

        XCTAssertEqual(narration.apply(sequence: 7, text: "正在修改内容", category: "write"), .duplicate)
        XCTAssertEqual(narration.text, "正在查询相关信息", "重复序号不得改写已显示的进展")
        XCTAssertEqual(narration.droppedCount, 1)
    }

    func testOutOfOrderProgressNeverOverwritesNewerLine() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 5, text: "正在读取相关内容", category: "read")

        XCTAssertEqual(narration.apply(sequence: 4, text: "正在查询相关信息", category: "search"), .outOfOrder)
        XCTAssertEqual(narration.text, "正在读取相关内容", "迟到帧不得把新进展盖回旧的")
        XCTAssertEqual(narration.latestSequence, 5)
    }

    /// 序号可以跳号（网关按会话计数，中间可能有别的回合消耗了号）。
    /// 只要严格更新就必须采纳——把跳号当异常会让进展在真机上时有时无。
    func testSequenceGapIsAccepted() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 1, text: "正在查询相关信息", category: "search")

        XCTAssertEqual(narration.apply(sequence: 9, text: "正在修改内容", category: "write"), .applied)
        XCTAssertEqual(narration.latestSequence, 9)
    }

    /// 老网关不带 `progress_seq`：照常显示，否则升级窗口内进展功能整个消失。
    func testMissingSequenceStillDisplays() {
        var narration = ToolProgressNarration()

        XCTAssertEqual(narration.apply(sequence: nil, text: "正在查询相关信息", category: "search"), .applied)
        XCTAssertEqual(narration.text, "正在查询相关信息")
        XCTAssertNil(narration.latestSequence)
        XCTAssertEqual(narration.apply(sequence: nil, text: "正在读取相关内容", category: "read"), .applied)
        XCTAssertEqual(narration.text, "正在读取相关内容")
    }

    // MARK: - 去抖

    func testIdenticalTextReportsUnchangedSoUIDoesNotRepaint() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 1, text: "正在查询相关信息", category: "search")

        let outcome = narration.apply(sequence: 2, text: "正在查询相关信息", category: "search")

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertFalse(outcome.changesDisplay)
        XCTAssertEqual(narration.latestSequence, 2, "序号照收——它是排序真相")
    }

    func testEmptyTextIsDroppedAndKeepsPreviousLine() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 1, text: "正在查询相关信息", category: "search")

        XCTAssertEqual(narration.apply(sequence: 2, text: "  ", category: "search"), .empty)
        XCTAssertEqual(narration.text, "正在查询相关信息")
        XCTAssertEqual(narration.latestSequence, 1, "空帧不推进序号")
    }

    // MARK: - 小屏适配

    func testLongTextIsTruncatedToWatchBudget() {
        var narration = ToolProgressNarration()
        let long = String(repeating: "查", count: ToolProgressNarration.maxDisplayCharacters * 3)

        narration.apply(sequence: 1, text: long, category: "plan")

        let text = try? XCTUnwrap(narration.text)
        XCTAssertEqual(text?.count, ToolProgressNarration.maxDisplayCharacters + 1, "截断后补一个省略号")
        XCTAssertTrue(text?.hasSuffix("…") ?? false)
    }

    func testNewlinesAreCollapsedSoTheSingleLineLayoutSurvives() {
        var narration = ToolProgressNarration()

        narration.apply(sequence: 1, text: "正在查询\n相关信息", category: "search")

        XCTAssertEqual(narration.text, "正在查询 相关信息")
    }

    func testTextExactlyAtBudgetIsNotTruncated() {
        var narration = ToolProgressNarration()
        let exact = String(repeating: "查", count: ToolProgressNarration.maxDisplayCharacters)

        narration.apply(sequence: 1, text: exact, category: "plan")

        XCTAssertEqual(narration.text, exact)
    }

    // MARK: - 生命周期

    func testClearDropsTheLineButKeepsTheSequenceGate() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 3, text: "正在查询相关信息", category: "search")

        narration.clear()

        XCTAssertNil(narration.text)
        XCTAssertFalse(narration.hasProgress)
        XCTAssertEqual(narration.latestSequence, 3, "清显示不等于放弃排序——迟到帧仍须被挡")
        XCTAssertEqual(narration.apply(sequence: 2, text: "正在修改内容", category: "write"), .outOfOrder)
    }

    func testFreshNarrationCarriesNothingFromAPriorTurn() {
        var previous = ToolProgressNarration()
        previous.apply(sequence: 12, text: "正在查询相关信息", category: "search")

        let fresh = ToolProgressNarration()

        XCTAssertNil(fresh.text)
        XCTAssertNil(fresh.latestSequence)
        XCTAssertEqual(fresh.appliedCount, 0)
    }

    func testLogDetailCarriesTheFieldsARealDeviceReplayNeeds() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 4, text: "正在查询相关信息", category: "search")
        narration.apply(sequence: 4, text: "正在修改内容", category: "write")

        let detail = narration.logDetail

        XCTAssertTrue(detail.contains("progress_seq=4"), detail)
        XCTAssertTrue(detail.contains("progress_category=search"), detail)
        XCTAssertTrue(detail.contains("progress_applied=1"), detail)
        XCTAssertTrue(detail.contains("progress_dropped=1"), detail)
    }

    /// 进展文本本身**不得**出现在日志摘要里：它是上游自由文本，可能带用户内容。
    func testLogDetailNeverLeaksTheProgressText() {
        var narration = ToolProgressNarration()
        narration.apply(sequence: 1, text: "正在查询张三的体检报告", category: "search")

        XCTAssertFalse(narration.logDetail.contains("张三"), narration.logDetail)
    }
}
