import XCTest
@testable import WristAgentCore

/// ESS-58：播放连续性决策单测——模拟锁屏收回会话/App 挂起后的各分支，
/// 断言播放不被静默截断：要么继续（后台音频在响）、要么原位续播、
/// 要么保留「未播完」可重播状态。
final class PlaybackRecoveryPolicyTests: XCTestCase {
    // MARK: 回前台处置

    func testForegroundResumesWhenPlaybackWasSuspended() {
        // 锁屏挂起截断：播放标记还在、播放器已停 → 必须原位续播，不许静默。
        XCTAssertEqual(
            PlaybackRecoveryPolicy.onForeground(hasActivePlayback: true, playerReportsPlaying: false),
            .resume
        )
    }

    func testForegroundLeavesBackgroundAudioAlone() {
        // 后台音频路径正常：锁屏期间声音一直在响，回前台不得重复触发。
        XCTAssertEqual(
            PlaybackRecoveryPolicy.onForeground(hasActivePlayback: true, playerReportsPlaying: true),
            .none
        )
    }

    func testForegroundNoopWithoutActivePlayback() {
        XCTAssertEqual(
            PlaybackRecoveryPolicy.onForeground(hasActivePlayback: false, playerReportsPlaying: false),
            .none
        )
        XCTAssertEqual(
            PlaybackRecoveryPolicy.onForeground(hasActivePlayback: false, playerReportsPlaying: true),
            .none
        )
    }

    // MARK: 播放收尾

    func testTruncatedPlaybackIsRetainedForReplay() {
        // 未播完（截断/解码失败/续播失败）：不删语音、不发交付 ACK，
        // 无论回合是否终态——中断只允许可见，不允许丢。
        XCTAssertEqual(
            PlaybackRecoveryPolicy.finishOutcome(finishedSuccessfully: false, turnIsTerminal: true),
            .retainForReplay
        )
        XCTAssertEqual(
            PlaybackRecoveryPolicy.finishOutcome(finishedSuccessfully: false, turnIsTerminal: false),
            .retainForReplay
        )
    }

    func testFinishedTerminalPlaybackDelivers() {
        XCTAssertEqual(
            PlaybackRecoveryPolicy.finishOutcome(finishedSuccessfully: true, turnIsTerminal: true),
            .deliverFinal
        )
    }

    func testFinishedInterimPlaybackDoesNotCountAsDelivery() {
        // ESS-45×ESS-46：interim 播完不算交付，终态结果的 grace 持有不被跳过。
        XCTAssertEqual(
            PlaybackRecoveryPolicy.finishOutcome(finishedSuccessfully: true, turnIsTerminal: false),
            .deliverInterim
        )
    }
}
