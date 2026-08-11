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

    // MARK: - 提交失败重试（上限 + 退避，evaluateDelivery 纯函数可测全链路）

    private struct FakeError: Error {}

    func testEvaluateDeliverySuccessReturnsMarkNotified() {
        let policy = ResultNotificationPolicy(directory: directory)
        let requestId = newRequestId()
        XCTAssertEqual(policy.evaluateDelivery(requestId: requestId, error: nil), .markNotified)
        XCTAssertEqual(policy.retryAttemptCount(requestId: requestId), 0)
    }

    func testEvaluateDeliveryFailureThenSuccessPipeline() {
        // 模拟 completion error 链路：首次失败 → retry，二次成功 → markNotified。
        let policy = ResultNotificationPolicy(directory: directory)
        let requestId = newRequestId()

        // 第 1 次 add 失败：返回 retry(2s)
        let r1 = policy.evaluateDelivery(requestId: requestId, error: FakeError())
        XCTAssertEqual(r1, .retry(after: 2.0))
        XCTAssertEqual(policy.retryAttemptCount(requestId: requestId), 1)
        // 失败不记账
        XCTAssertFalse(policy.hasNotified(requestId: requestId))

        // 第 2 次 add 成功：返回 markNotified
        let r2 = policy.evaluateDelivery(requestId: requestId, error: nil)
        XCTAssertEqual(r2, .markNotified)
        // 此时调用方应执行 markNotified
        policy.markNotified(requestId: requestId)
        XCTAssertTrue(policy.hasNotified(requestId: requestId))
    }

    func testEvaluateDeliveryExhaustsAfterMaxRetries() {
        let policy = ResultNotificationPolicy(directory: directory)
        let requestId = newRequestId()

        // 第 1 次失败：retry(2s)
        XCTAssertEqual(policy.evaluateDelivery(requestId: requestId, error: FakeError()), .retry(after: 2.0))
        XCTAssertEqual(policy.retryAttemptCount(requestId: requestId), 1)

        // 第 2 次失败：retry(4s)
        XCTAssertEqual(policy.evaluateDelivery(requestId: requestId, error: FakeError()), .retry(after: 4.0))
        XCTAssertEqual(policy.retryAttemptCount(requestId: requestId), 2)

        // 第 3 次失败（即第 4 次 add 调用，attemptCount=3=maxRetryAttempts）：exhausted
        XCTAssertEqual(policy.evaluateDelivery(requestId: requestId, error: FakeError()), .exhausted)
        XCTAssertEqual(policy.retryAttemptCount(requestId: requestId), 3)

        // exhausted 后不再记录为已通知
        XCTAssertFalse(policy.hasNotified(requestId: requestId))
    }

    func testEvaluateDeliverySuccessClearsRetryState() {
        let policy = ResultNotificationPolicy(directory: directory)
        let requestId = newRequestId()

        _ = policy.evaluateDelivery(requestId: requestId, error: FakeError())
        XCTAssertEqual(policy.retryAttemptCount(requestId: requestId), 1)

        // 成功后状态清除
        _ = policy.evaluateDelivery(requestId: requestId, error: nil)
        XCTAssertEqual(policy.retryAttemptCount(requestId: requestId), 0)
    }

    func testRetryStateIsNotPersistedAcrossRelaunch() {
        // ESS-788 决策：重试依赖 DispatchQueue.asyncAfter，进程退出后调度丢失，
        // 持久化重试状态无恢复路径；改为仅存活进程内有效。
        let requestId = newRequestId()
        let policy1 = ResultNotificationPolicy(directory: directory)
        _ = policy1.evaluateDelivery(requestId: requestId, error: FakeError())
        XCTAssertEqual(policy1.retryAttemptCount(requestId: requestId), 1)

        // 模拟杀进程重开：重试状态不持久化，新实例从零开始
        let policy2 = ResultNotificationPolicy(directory: directory)
        XCTAssertEqual(policy2.retryAttemptCount(requestId: requestId), 0)
    }

    func testEvaluateDeliveryDoesNotAffectNotifiedLedger() {
        // 重试状态与已通知账本是独立的：失败不应将 requestId 标记为已通知。
        let policy = ResultNotificationPolicy(directory: directory)
        let requestId = newRequestId()

        _ = policy.evaluateDelivery(requestId: requestId, error: FakeError())
        XCTAssertFalse(policy.hasNotified(requestId: requestId))

        // 确认 skipReason 不会因失败而跳过
        let created = Date(timeIntervalSince1970: 1_753_920_000)
        XCTAssertNil(policy.skipReason(
            requestId: requestId,
            turnCreatedAt: created,
            completedAt: created.addingTimeInterval(120),
            isAppActive: false,
            isAuthorized: true
        ))
    }
}
