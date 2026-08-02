import XCTest
@testable import WristAgentCore

/// ESS-55 追加验收（白梦林拍板）：超长任务本地通知的决策与幂等。
final class ResultNotificationPolicyTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-policy-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func newRequestId() -> String {
        UUIDv7.generate().uuidString.lowercased()
    }

    private func skip(
        _ policy: ResultNotificationPolicy,
        requestId: String,
        elapsed: TimeInterval,
        appActive: Bool = false,
        authorized: Bool = true
    ) -> ResultNotificationPolicy.SkipReason? {
        let created = Date(timeIntervalSince1970: 1_753_920_000)
        return policy.skipReason(
            requestId: requestId,
            turnCreatedAt: created,
            completedAt: created.addingTimeInterval(elapsed),
            isAppActive: appActive,
            isAuthorized: authorized
        )
    }

    func testThresholdIsSixtySecondsAndTestable() {
        // 验收：「超长任务」阈值写死并可测——60 秒内完成的短任务不通知。
        XCTAssertEqual(ResultNotificationPolicy.longTaskThresholdSeconds, 60)
        let policy = ResultNotificationPolicy(directory: directory)
        XCTAssertEqual(skip(policy, requestId: newRequestId(), elapsed: 59.9), .shortTask)
        XCTAssertNil(skip(policy, requestId: newRequestId(), elapsed: 60))
    }

    func testAppActiveAndUnauthorizedAreSkippedWithDistinctReasons() {
        // 前台不发通知（走触觉 + 界面）；未授权降级为触觉 + 未读——原因可日志区分。
        let policy = ResultNotificationPolicy(directory: directory)
        XCTAssertEqual(skip(policy, requestId: newRequestId(), elapsed: 120, appActive: true), .appActive)
        XCTAssertEqual(skip(policy, requestId: newRequestId(), elapsed: 120, authorized: false), .notAuthorized)
    }

    func testNotifyIsIdempotentPerRequestIdAcrossRelaunch() {
        // 验收：同一 request_id 因补投/重连多次到达只通知一次；重开 App 也不重复。
        let requestId = newRequestId()
        let policy = ResultNotificationPolicy(directory: directory)
        XCTAssertNil(skip(policy, requestId: requestId, elapsed: 120))
        policy.markNotified(requestId: requestId)
        XCTAssertEqual(skip(policy, requestId: requestId, elapsed: 120), .alreadyNotified)

        let relaunched = ResultNotificationPolicy(directory: directory)
        XCTAssertEqual(skip(relaunched, requestId: requestId, elapsed: 120), .alreadyNotified)
        XCTAssertTrue(relaunched.hasNotified(requestId: requestId))
    }

    func testLedgerEvictsOldestBeyondCap() {
        let policy = ResultNotificationPolicy(directory: directory)
        let first = newRequestId()
        policy.markNotified(requestId: first)
        for _ in 0..<55 { policy.markNotified(requestId: newRequestId()) }
        XCTAssertFalse(policy.hasNotified(requestId: first), "超出上限最旧的记账被滚出")
    }

    func testProvisionalFiresAfterExtendedRuntimeCap() {
        // 兜底预约必须晚于 ExtendedRuntimeSession 上限（~600s）——上限内 App 还在，
        // 结果到达走精确通知，预约早了就是误报。
        XCTAssertGreaterThan(ResultNotificationPolicy.provisionalFallbackSeconds, 600)
    }

    func testNotificationContentTruncatesAndNeverEmpty() {
        let long = String(repeating: "结", count: 80)
        let content = ResultNotificationPolicy.notificationContent(resultSummary: long)
        XCTAssertTrue(content.body.hasSuffix("…"))
        XCTAssertLessThanOrEqual(content.body.count, 61)

        let empty = ResultNotificationPolicy.notificationContent(resultSummary: "  ")
        XCTAssertFalse(empty.body.isEmpty, "空摘要也要有可读正文")
        XCTAssertFalse(content.title.isEmpty)

        let provisional = ResultNotificationPolicy.provisionalContent()
        XCTAssertFalse(provisional.title.contains("结果来了"), "兜底文案不得谎称已有结果")
    }
}
