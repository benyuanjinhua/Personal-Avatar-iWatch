import XCTest
@testable import WristAgentCore

/// ESS-61 / ESS-226：会话切换决策单测——复现 R4 开测即挂的两个缺陷分支：
/// A) long_form 播放后录音 -50，配置必须先复位路由策略、失败有回落；
/// B) activate 回调 activated=false 却被当成功，88 秒音频静默。
/// ESS-226 后播放侧改单阶段激活（默认 `.default` 路由，opt-in `.longFormAudio`），
/// 「long_form → foreground」的状态机不再存在——只保留激活成功判据（F2）
/// 与录音会话复位序列（F1，覆盖 opt-in 后的 .longFormAudio 前置态）。
final class AudioSessionPolicyTests: XCTestCase {
    // MARK: 缺陷 B 复现（F2）：activated=false 不是成功

    func testActivationFalseWithoutErrorIsFailure() {
        // 真机取证 04:50:09：error=nil、activated=false 走了成功分支，
        // play() 返回 false，88 秒静默。该组合必须判失败。
        XCTAssertFalse(AudioSessionPolicy.playbackActivationSucceeded(activated: false, hasError: false))
    }

    func testActivationErrorIsFailure() {
        XCTAssertFalse(AudioSessionPolicy.playbackActivationSucceeded(activated: false, hasError: true))
        XCTAssertFalse(AudioSessionPolicy.playbackActivationSucceeded(activated: true, hasError: true))
    }

    func testActivationTrueWithoutErrorSucceeds() {
        XCTAssertTrue(AudioSessionPolicy.playbackActivationSucceeded(activated: true, hasError: false))
    }

    // MARK: 缺陷 A 复现（F1）：录音配置尝试序列

    func testFirstRecordingAttemptResetsRoutePolicy() {
        // 上一次播放可能留下 .longFormAudio，第一次尝试必须是显式复位。
        XCTAssertEqual(AudioSessionPolicy.nextRecordingAttempt(after: nil), .resetRoutePolicy)
    }

    func testResetFailureFallsBackToMinimal() {
        XCTAssertEqual(AudioSessionPolicy.nextRecordingAttempt(after: .resetRoutePolicy), .minimal)
    }

    func testMinimalFailureGivesUp() {
        // 两次都失败才报错给用户（且不得直出 OSStatus 原文）。
        XCTAssertNil(AudioSessionPolicy.nextRecordingAttempt(after: .minimal))
    }
}
