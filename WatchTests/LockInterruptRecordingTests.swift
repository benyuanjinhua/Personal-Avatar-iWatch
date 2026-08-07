import XCTest

@testable import WristAgent_Watch_App

/// ESS-538：录音进行中锁屏 —— 息屏后音频采集立即死亡，但 AVAudioRecorder
/// 仍在走；松手才 finish 会把 316ms 残片当正常录音提交（真机 2026-08-07
/// 17:06 bridge.log：wall_clock=5926ms asset=316ms，回合失败「没听清」）。
///
/// 修复：锁屏瞬间主动收尾——采到 ≥ 最短门的抢救提交（结果走通知链路），
/// 太短的丢弃并在抬腕回前台时呈现「锁屏打断了录音」（ERR_RECORDING_INTERRUPTED）。
///
/// 模拟器限制：真实采集在 headless 下不可用（同 AudioRecorderHandoverTests
/// 的口径），本套件覆盖不依赖采集的部分：catalog 映射、文案、空态幂等。
/// 采集路径的真机验收归 ESS-538 的复测。
@MainActor
final class LockInterruptRecordingTests: XCTestCase {

    // MARK: - catalog 映射

    func testCueCatalogMapsRecordingInterrupted() {
        let entry = ErrorCueCatalog.cue(for: "ERR_RECORDING_INTERRUPTED")
        XCTAssertEqual(entry.code, "ERR_RECORDING_INTERRUPTED")
        // 族 A（重说）：残片已丢弃，无缓存可重发，绝不允许出现「重试」按钮。
        XCTAssertEqual(entry.recoveryFamily, .reRecord)
        XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry)
        XCTAssertFalse(entry.text.isEmpty)
        XCTAssertTrue(entry.text.contains("再说一次"))
        // 无预置语音：走「文字 + 触觉」降级路径，不允许静默。
        XCTAssertNil(entry.clip)
    }

    func testInterruptedCopyMatchesCatalog() {
        XCTAssertEqual(
            RecorderError.recordingInterruptedDescription,
            ErrorCueCatalog.cue(for: "ERR_RECORDING_INTERRUPTED").text
        )
        XCTAssertFalse(RecorderError.recordingInterruptedDescription.contains("OSStatus"))
    }

    // MARK: - 控制器空态幂等（不依赖真实采集）

    func testInterruptWhileIdleIsNoOp() {
        let controller = PushToTalkController()
        controller.recordingInterruptedByLock(phase: "inactive")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.errorPresenter.active)
    }

    func testPresentNoticeWithoutPendingIsNoOp() {
        let controller = PushToTalkController()
        controller.presentLockInterruptNoticeIfNeeded()
        XCTAssertNil(controller.errorPresenter.active)
        XCTAssertNil(controller.errorMessage)
    }

    /// 有待呈现提示时抬腕呈现一次：卡片码正确、呈现后记账清零
    /// （第二次调用不再重复呈现）。
    func testPendingNoticePresentsInterruptCardOnce() {
        let controller = PushToTalkController()
        controller.simulateLockInterruptNoticeForTests()
        controller.presentLockInterruptNoticeIfNeeded()
        let card = controller.errorPresenter.active
        XCTAssertEqual(card?.entry.code, "ERR_RECORDING_INTERRUPTED")
        XCTAssertEqual(controller.errorMessage, RecorderError.recordingInterruptedDescription)
        // 第二次调用：记账已清，不再覆盖当前卡片。
        controller.presentLockInterruptNoticeIfNeeded()
        XCTAssertEqual(controller.errorPresenter.active?.id, card?.id)
    }
}
