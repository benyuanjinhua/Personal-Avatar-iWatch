import UserNotifications
import XCTest

@testable import WristAgent_Watch_App

/// ESS-754 / ESS-788 复审 R-02.1：用 mock NotificationSubmitter 驱动
/// `deliverNotification` 的投递/重试/耗尽全链路，通过 WatchLog observer
/// 断言运行时事件序列。
///
/// 覆盖路径：
/// - 首发失败 → retry_scheduled(delay=2s) → 重试成功 → notified（两条 source 各一次）
/// - 连续失败 3 次 → exhausted
/// - 首次成功 → notified（不产生 retry 事件）
@MainActor
final class ResultNotifierDeliveryTests: XCTestCase {
    /// 一条抓到的 WatchLog 事件。
    private struct CapturedEvent: Equatable {
        let module: String
        let event: String
        let detail: String?
    }

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CapturedEvent] = []
        func append(_ e: CapturedEvent) { lock.lock(); events.append(e); lock.unlock() }
        func snapshot() -> [CapturedEvent] { lock.lock(); defer { lock.unlock() }; return events }
        func matches(event: String) -> [CapturedEvent] {
            snapshot().filter { $0.event == event }
        }
        func first(event: String) -> CapturedEvent? {
            snapshot().first(where: { $0.event == event })
        }
    }

    private var collector: EventCollector!

    override func setUp() {
        super.setUp()
        collector = EventCollector()
        let sink = collector!
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.append(CapturedEvent(module: module, event: event, detail: detail))
        }
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        collector = nil
        super.tearDown()
    }

    /// Mock：可编程控制 submit 成功/失败，并记录提交次数。
    private final class MockSubmitter: NotificationSubmitter, @unchecked Sendable {
        private let lock = NSLock()
        private var _submitCount = 0
        private var _shouldSucceedAfter: Int  // 第 N 次开始成功，0 = 永远失败
        private var delay: Duration = .zero
        private var errorToReturn: Error = NSError(domain: "test", code: -1)

        var submitCount: Int { lock.lock(); defer { lock.unlock() }; return _submitCount }
        var didSubmit: Bool { submitCount > 0 }

        /// - Parameter shouldSucceedAfter: 第 N 次（1-based）起返回成功；0 = 永远失败。
        init(shouldSucceedAfter: Int) {
            _shouldSucceedAfter = shouldSucceedAfter
        }

        func submit(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
            lock.lock()
            _submitCount += 1
            let succeed = _submitCount >= _shouldSucceedAfter && _shouldSucceedAfter > 0
            lock.unlock()
            if succeed {
                completion(nil)
            } else {
                completion(errorToReturn)
            }
        }
    }

    /// 构造 UNMutableNotificationContent（与产线 `notifyResultIfEligible` 一致）。
    private func resultContent(requestId: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = "任务完成，结果来了"
        c.body = "上海明天多云转小雨"
        c.sound = .default
        c.userInfo = ["request_id": requestId]
        return c
    }

    // MARK: - 首发成功

    func testFirstAttemptSuccessEmitsNotifiedAndMarksLedger() {
        let requestId = "ess754-success-\(UUID().uuidString)"
        let submitter = MockSubmitter(shouldSucceedAfter: 1)
        let policy = ResultNotificationPolicy(directory: tempDir())

        let notifier = ResultNotifier(policy: policy, submitter: submitter)
        notifier.deliverNotification(
            requestId: requestId, content: resultContent(requestId: requestId),
            sourceLabel: "result"
        )

        // 等 async callback 落地
        let e = expectation(description: "notified")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { e.fulfill() }
        wait(for: [e], timeout: 2)

        XCTAssertEqual(submitter.submitCount, 1, "成功时只提交一次")
        XCTAssertTrue(policy.hasNotified(requestId: requestId), "成功后应记账")

        let notifiedEvents = collector.matches(event: "result_notified")
        XCTAssertGreaterThanOrEqual(notifiedEvents.count, 1, "应落 result_notified")
        XCTAssertTrue(
            notifiedEvents.contains(where: { $0.detail?.contains("source=result") == true }),
            "result_notified 应带 source=result"
        )
        // 成功路径不应产生 retry_scheduled
        XCTAssertEqual(
            collector.matches(event: "result_notify_retry_scheduled").count, 0,
            "首发成功不应有 retry_scheduled"
        )
    }

    // MARK: - 首发失败 → 重试成功

    func testFailureThenRetrySuccessPipeline() {
        let requestId = "ess754-retry-ok-\(UUID().uuidString)"
        // 第 2 次提交成功（第 1 次失败 → 重试 → 成功）
        let submitter = MockSubmitter(shouldSucceedAfter: 2)
        let policy = ResultNotificationPolicy(directory: tempDir())

        let notifier = ResultNotifier(policy: policy, submitter: submitter)
        notifier.deliverNotification(
            requestId: requestId, content: resultContent(requestId: requestId),
            sourceLabel: "playback_failure", logDetail: "playback_reason=exhausted"
        )

        // 首发失败 + 2s 退避后的重试需要等
        let e = expectation(description: "retry delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { e.fulfill() }
        wait(for: [e], timeout: 4)

        XCTAssertEqual(submitter.submitCount, 2, "首发失败后应重试一次")
        XCTAssertTrue(policy.hasNotified(requestId: requestId), "重试成功后应记账")

        // 日志证据
        let failedEvents = collector.matches(event: "result_notify_failed")
        XCTAssertGreaterThanOrEqual(failedEvents.count, 1, "首发失败应落 result_notify_failed")
        XCTAssertTrue(
            failedEvents.contains(where: { $0.detail?.contains("playback_reason=exhausted") == true }),
            "失败日志应保留 playback_reason"
        )

        let retryEvents = collector.matches(event: "result_notify_retry_scheduled")
        XCTAssertGreaterThanOrEqual(retryEvents.count, 1, "应落 retry_scheduled")
        XCTAssertTrue(
            retryEvents.contains(where: { ($0.detail ?? "").contains("delay=2s") }),
            "首次退避应为 2s"
        )

        let notifiedEvents = collector.matches(event: "result_notified")
        XCTAssertGreaterThanOrEqual(notifiedEvents.count, 1, "重试成功应落 result_notified")
        XCTAssertTrue(
            notifiedEvents.contains(where: { $0.detail?.contains("source=playback_failure") == true }),
            "result_notified 应带 source=playback_failure"
        )
    }

    // MARK: - 连续失败 → exhausted

    func testThreeFailuresExhaustsRetry() {
        let requestId = "ess754-exhausted-\(UUID().uuidString)"
        let submitter = MockSubmitter(shouldSucceedAfter: 0)  // 永远失败
        let policy = ResultNotificationPolicy(directory: tempDir())

        let notifier = ResultNotifier(policy: policy, submitter: submitter)
        notifier.deliverNotification(
            requestId: requestId, content: resultContent(requestId: requestId),
            sourceLabel: "result"
        )

        // 等满 3 次提交（首发 + 2 次重试，退避 2s + 4s = 最多 6s）
        let e = expectation(description: "exhausted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { e.fulfill() }
        wait(for: [e], timeout: 8)

        XCTAssertEqual(submitter.submitCount, 3, "应提交 3 次（首发 + 2 次重试）")
        XCTAssertFalse(policy.hasNotified(requestId: requestId), "exhausted 不应记账")

        let scheduledEvents = collector.matches(event: "result_notify_retry_scheduled")
        XCTAssertGreaterThanOrEqual(scheduledEvents.count, 2, "应有 2 次 retry_scheduled")
        XCTAssertTrue(
            scheduledEvents.contains(where: { ($0.detail ?? "").contains("delay=2s") }),
            "第一次重试应退避 2s"
        )
        XCTAssertTrue(
            scheduledEvents.contains(where: { ($0.detail ?? "").contains("delay=4s") }),
            "第二次重试应退避 4s"
        )

        let exhaustedEvents = collector.matches(event: "result_notify_retry_exhausted")
        XCTAssertGreaterThanOrEqual(exhaustedEvents.count, 1, "应落 retry_exhausted")
    }

    // MARK: - playback_failure 路径日志字段完整

    func testPlaybackFailurePathPreservesReasonLabel() {
        let requestId = "ess754-pb-\(UUID().uuidString)"
        let submitter = MockSubmitter(shouldSucceedAfter: 1)
        let policy = ResultNotificationPolicy(directory: tempDir())

        let notifier = ResultNotifier(policy: policy, submitter: submitter)
        notifier.deliverNotification(
            requestId: requestId, content: resultContent(requestId: requestId),
            sourceLabel: "playback_failure", logDetail: "playback_reason=activation_failed"
        )

        let e = expectation(description: "notified")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { e.fulfill() }
        wait(for: [e], timeout: 2)

        let notified = collector.first(event: "result_notified")
        XCTAssertNotNil(notified, "应落 result_notified")
        // P1 回归验证：playback_reason 不得被 retry_attempt=0 挤掉
        XCTAssertTrue(
            notified?.detail?.contains("playback_reason=activation_failed") == true,
            "playback_reason 应在成功路径保留，不应被 retry_attempt=0 替代"
        )
        XCTAssertFalse(
            notified?.detail?.contains("retry_attempt=0") == true,
            "成功路径不应输出误导性的 retry_attempt=0"
        )
    }

    // MARK: - helpers

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ess754-delivery-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
