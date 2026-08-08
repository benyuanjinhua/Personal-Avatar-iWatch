import XCTest

@testable import WristAgent_Watch_App

/// ESS-538：录音中断（降腕息屏/会话中断）收尾后的呈现契约。
///
/// 中断丢弃发生在屏灭/后台时不当场弹卡——AvatarErrorPresenter 的卡片
/// 最小停留 5s 就被自动收起，屏灭时呈现等于吞掉。改为记账，回 .active
/// 由 presentInterruptedNoticeIfNeeded 补呈现。
///
/// 模拟器限制：真实采集在 headless 下不可用（口径同
/// AudioRecorderHandoverTests），本套件只覆盖不依赖采集的呈现契约与
/// 空态幂等；采集路径的真机验收归 ESS-538 复测。
@MainActor
final class InterruptedRecordingNoticeTests: XCTestCase {

    // MARK: - 空态幂等（不依赖真实采集）

    func testScreenOffHookWhileIdleIsNoOp() {
        let controller = PushToTalkController()
        controller.noteScreenOffDuringRecording(phase: "inactive")
        controller.noteScreenOffDuringRecording(phase: "background")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.errorPresenter.active)
    }

    func testPresentNoticeWithoutPendingIsNoOp() {
        let controller = PushToTalkController()
        controller.presentInterruptedNoticeIfNeeded()
        XCTAssertNil(controller.errorPresenter.active)
        XCTAssertNil(controller.errorMessage)
    }

    /// 有待呈现提示时回前台呈现一次：卡片码与文案正确、呈现后记账清零
    /// （第二次调用不再重复呈现/覆盖当前卡片）。
    func testPendingNoticePresentsInterruptCardOnce() {
        let controller = PushToTalkController()
        controller.simulateInterruptedNoticeForTests()
        controller.presentInterruptedNoticeIfNeeded()
        let card = controller.errorPresenter.active
        XCTAssertEqual(card?.entry.code, "ERR_RECORDING_INTERRUPTED")
        XCTAssertEqual(
            controller.errorMessage,
            RecorderError.recordingInterrupted.errorDescription
        )
        controller.presentInterruptedNoticeIfNeeded()
        XCTAssertEqual(controller.errorPresenter.active?.id, card?.id)
    }

    /// 打断文案与 catalog 卡片文案保持同义（一个是底部行、一个是卡片，
    /// 两者都必须说明「被打断」而非「按太短」——恢复动作都是重说）。
    func testInterruptedCopyExplainsInterruption() {
        let description = RecorderError.recordingInterrupted.errorDescription ?? ""
        XCTAssertTrue(description.contains("被打断"))
        XCTAssertFalse(description.contains("OSStatus"))
        XCTAssertEqual(
            ErrorCueCatalog.cue(for: "ERR_RECORDING_INTERRUPTED").recoveryFamily,
            .reRecord
        )
    }
}
