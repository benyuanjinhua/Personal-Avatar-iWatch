import XCTest

@testable import WristAgent_Watch_App

/// D4 Gap-3 (ESS-305)：处理中 >10s 必须有进展变化。
/// 覆盖 processingTitle / processingSubtitle 的 0/10/30/60 四档文案，
/// 以及所有文案不含秒级数字的硬约束。
final class ProcessingCopyThresholdTests: XCTestCase {

    // MARK: - 0 second (baseline) texts

    func testZeroSecondsWaitingForMacTitle() {
        let title = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 0)
        XCTAssertEqual(title, "已到手机，等待 Mac")
    }

    func testZeroSecondsDeliveredTitle() {
        let title = WatchContentView.processingTitle(for: .delivered, elapsed: 0)
        XCTAssertEqual(title, "Mac 已受理")
    }

    func testZeroSecondsProcessingForegroundTitle() {
        let title = WatchContentView.processingTitle(for: .processing(background: false), elapsed: 0)
        XCTAssertEqual(title, "分身正在思考…")
    }

    func testZeroSecondsProcessingBackgroundTitle() {
        let title = WatchContentView.processingTitle(for: .processing(background: true), elapsed: 0)
        XCTAssertEqual(title, "分身正在处理…")
    }

    // MARK: - 10-second threshold (no new events)

    func testTenSecondsWaitingForMacTitleChanges() {
        let title = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 10)
        XCTAssertEqual(title, "Mac 尚未响应")
    }

    func testTenSecondsDeliveredTitleChanges() {
        let title = WatchContentView.processingTitle(for: .delivered, elapsed: 10)
        XCTAssertEqual(title, "仍在等待 Mac 处理")
    }

    func testTenSecondsProcessingForegroundTitleChanges() {
        let title = WatchContentView.processingTitle(for: .processing(background: false), elapsed: 10)
        XCTAssertEqual(title, "仍在思考，请稍候")
    }

    func testTenSecondsProcessingBackgroundTitleChanges() {
        let title = WatchContentView.processingTitle(for: .processing(background: true), elapsed: 10)
        XCTAssertEqual(title, "仍在后台运行…")
    }

    func testTenSecondsSubtitleChanges() {
        let subtitle = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 10)
        XCTAssertEqual(subtitle, "暂无新进展，可放下手腕等待")
    }

    // MARK: - 30-second threshold

    func testThirtySecondsWaitingForMacTitle() {
        let title = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 30)
        XCTAssertEqual(title, "分身还在联系 Mac…")
    }

    func testThirtySecondsDeliveredTitle() {
        let title = WatchContentView.processingTitle(for: .delivered, elapsed: 30)
        XCTAssertEqual(title, "分身正在准备执行…")
    }

    func testThirtySecondsProcessingForegroundTitle() {
        let title = WatchContentView.processingTitle(for: .processing(background: false), elapsed: 30)
        XCTAssertEqual(title, "分身还在想…")
    }

    func testThirtySecondsProcessingBackgroundTitle() {
        let title = WatchContentView.processingTitle(for: .processing(background: true), elapsed: 30)
        XCTAssertEqual(title, "分身还在跑…")
    }

    func testThirtySecondsSubtitleChanges() {
        let subtitle = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 30)
        XCTAssertEqual(subtitle, "仍在等待，可继续使用手表")
    }

    // MARK: - 60-second threshold

    func testSixtySecondsTitleIsSlowTaskHint() {
        let title = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 60)
        XCTAssertEqual(title, "任务较慢，可继续等待或取消")
    }

    func testSixtySecondsSubtitleIsBackgroundHint() {
        let subtitle = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 60)
        XCTAssertEqual(subtitle, "分身仍在运行，可以先放下手腕")
    }

    // MARK: - Four states are all distinct (acceptance criteria: ≥3 changes, all unique)

    func testAllFourTitleStatesAreDistinctForWaitingForMac() {
        let t0 = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 0)
        let t10 = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 10)
        let t30 = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 30)
        let t60 = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 60)
        let set = Set([t0, t10, t30, t60])
        XCTAssertEqual(set.count, 4, "0/10/30/60 秒四档标题必须互不重复")
    }

    func testAllFourSubtitleStatesAreDistinct() {
        // Use a generic processing phase; phase doesn't matter for subtitle default branch.
        let s0 = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 0)
        let s10 = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 10)
        let s30 = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 30)
        let s60 = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 60)
        let set = Set([s0, s10, s30, s60])
        XCTAssertEqual(set.count, 4, "0/10/30/60 秒四档副标题必须互不重复")
    }

    // MARK: - No digits (seconds timer) in any text

    func testNoDigitInAnyTitleText() {
        let phases: [VoiceTurnPhase] = [
            .waitingForMac, .delivered, .processing(background: false), .processing(background: true)
        ]
        let elapsedValues: [TimeInterval] = [0, 5, 9, 10, 15, 29, 30, 45, 59, 60, 120]

        for phase in phases {
            for elapsed in elapsedValues {
                let title = WatchContentView.processingTitle(for: phase, elapsed: elapsed)
                let hasDigit = title.rangeOfCharacter(from: .decimalDigits) != nil
                XCTAssertFalse(hasDigit, "标题「\(title)」包含数字，违反 D4 硬约束 (phase=\(phase), elapsed=\(elapsed))")
            }
        }
    }

    func testNoDigitInAnySubtitleText() {
        let phases: [VoiceTurnPhase] = [
            .waitingForMac, .delivered, .processing(background: false), .processing(background: true)
        ]
        let elapsedValues: [TimeInterval] = [0, 5, 9, 10, 15, 29, 30, 45, 59, 60, 120]

        for phase in phases {
            for elapsed in elapsedValues {
                let subtitle = WatchContentView.processingSubtitle(for: phase, elapsed: elapsed)
                let hasDigit = subtitle.rangeOfCharacter(from: .decimalDigits) != nil
                XCTAssertFalse(hasDigit, "副标题「\(subtitle)」包含数字，违反 D4 硬约束 (phase=\(phase), elapsed=\(elapsed))")
            }
        }
    }

    // MARK: - Event suppression: 10s threshold is NOT triggered below 10s

    func testTenSecondThresholdNotTriggeredBelowTen() {
        // At 9 seconds, we should still be in the 0s bucket
        let t9 = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 9)
        let t0 = WatchContentView.processingTitle(for: .waitingForMac, elapsed: 0)
        XCTAssertEqual(t9, t0, "9 秒时文案应与 0 秒一致，10 秒阈值不可提前触发")

        let s9 = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 9)
        let s0 = WatchContentView.processingSubtitle(for: .waitingForMac, elapsed: 0)
        XCTAssertEqual(s9, s0, "副标题同理")
    }

    // MARK: - Completed / failed / cancelled phases are pass-through

    func testTerminalPhasesReturnPhaseTitleIgnoringElapsed() {
        XCTAssertEqual(
            WatchContentView.processingTitle(for: .completed, elapsed: 120),
            "已完成"
        )
        XCTAssertEqual(
            WatchContentView.processingTitle(for: .cancelled, elapsed: 120),
            "已取消"
        )
    }

    // MARK: - Sending and waitingForPhone are phase-only

    func testSendingAndWaitingForPhoneAreElapsedInsensitive() {
        XCTAssertEqual(
            WatchContentView.processingTitle(for: .sending, elapsed: 60),
            "正在送出"
        )
        XCTAssertEqual(
            WatchContentView.processingTitle(for: .waitingForPhone, elapsed: 60),
            "等待手机连接"
        )
    }

    // MARK: - needsConfirmation subtitle is phase-only

    func testNeedsConfirmationSubtitleIsElapsedInsensitive() {
        let s = WatchContentView.processingSubtitle(for: .needsConfirmation, elapsed: 60)
        XCTAssertEqual(s, "未确认前不会执行")
    }

    func testWaitingForPhoneSubtitleIsElapsedInsensitive() {
        let s = WatchContentView.processingSubtitle(for: .waitingForPhone, elapsed: 60)
        XCTAssertEqual(s, "手机连上后自动送出")
    }
}
