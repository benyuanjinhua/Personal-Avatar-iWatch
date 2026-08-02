import XCTest
@testable import WristAgentCore

/// ESS-61：会话切换决策单测——复现 R4 开测即挂的两个缺陷分支：
/// A) long_form 播放后录音 -50，配置必须先复位路由策略、失败有回落；
/// B) activate 回调 activated=false 却被当成功，88 秒音频静默。
final class AudioSessionPolicyTests: XCTestCase {
    // MARK: ESS-64 播放激活状态机

    func testPlaybackWaitsWhileInterruptionIsActive() {
        XCTAssertEqual(
            AudioSessionPolicy.nextPlaybackActivationAction(
                interrupted: true, longFormSucceeded: nil, foregroundSucceeded: nil
            ),
            .waitForInterruptionEnd
        )
    }

    func testPlaybackActivatesAfterInterruptionEnds() {
        XCTAssertEqual(
            AudioSessionPolicy.nextPlaybackActivationAction(
                interrupted: false, longFormSucceeded: nil, foregroundSucceeded: nil
            ),
            .activateLongForm
        )
        XCTAssertEqual(
            AudioSessionPolicy.nextPlaybackActivationAction(
                interrupted: false, longFormSucceeded: true, foregroundSucceeded: nil
            ),
            .play
        )
    }

    func testPlaybackIsRetainedWhenBothActivationsFail() {
        XCTAssertEqual(
            AudioSessionPolicy.nextPlaybackActivationAction(
                interrupted: false, longFormSucceeded: false, foregroundSucceeded: false
            ),
            .retainForReplay
        )
    }

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

    // MARK: ESS-73 复现：interruption .ended 不保证投递，闸门不得永久生效

    func testInterruptionGateEngagedWithinTrustWindow() {
        // S5 契约（ESS-64/65）：合成 .began 后 ~400ms 内请求播放必须被 defer，
        // 信任窗口必须覆盖这个区间。
        let began = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            AudioSessionPolicy.interruptionGateEngaged(
                beganAt: began, now: began.addingTimeInterval(0.4)
            )
        )
    }

    func testInterruptionGateDisengagesAfterTrustWindow() {
        // 真机取证 2026-08-02 09:12：.began ×4 后全库 0 条 .ended，7.5s 后
        // 语音到达仍被 defer 且永不恢复。窗口过期后闸门必须失效，
        // 播放请求改为直接尝试激活，由激活结果说话。
        let began = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(
            AudioSessionPolicy.interruptionGateEngaged(
                beganAt: began, now: began.addingTimeInterval(7.5)
            )
        )
    }

    func testInterruptionGateDisengagedWithoutBegan() {
        XCTAssertFalse(
            AudioSessionPolicy.interruptionGateEngaged(beganAt: nil, now: Date(timeIntervalSince1970: 1_000))
        )
    }

    func testInterruptionGateClearedByEndedIsDisengaged() {
        // .ended 正常到达的路径等价于 beganAt 被清空。
        XCTAssertFalse(AudioSessionPolicy.interruptionGateEngaged(beganAt: nil, now: .distantFuture))
    }

    func testDeferredRetryDelayWaitsForWindowExpiry() {
        // defer 后的重试要等信任窗口过期，且必须小于窗口本身（不许无限等）。
        let began = Date(timeIntervalSince1970: 1_000)
        let delay = AudioSessionPolicy.deferredRetryDelay(beganAt: began, now: began.addingTimeInterval(1))
        XCTAssertEqual(delay, AudioSessionPolicy.interruptionTrustWindow - 1, accuracy: 0.001)
    }

    func testDeferredRetryDelayClampedWhenWindowAlreadyExpired() {
        let began = Date(timeIntervalSince1970: 1_000)
        let delay = AudioSessionPolicy.deferredRetryDelay(beganAt: began, now: began.addingTimeInterval(60))
        XCTAssertGreaterThan(delay, 0)
        XCTAssertLessThanOrEqual(delay, 0.1)
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
