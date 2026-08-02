import XCTest
@testable import WristAgentCore

/// ESS-154 T2 播放终局决策：把「播放死了」反馈回告知链路的纯逻辑。
/// 决策放在 Shared/ 可 macOS 单测，Watch 层只做 UNNotificationCenter/haptic
/// 拼装——真机取证（R-02.1）在集成层由 09:12 场景回放贴 WatchLog 事件序列。
final class PlaybackEndgamePolicyTests: XCTestCase {
    // MARK: - 决策表（对应本单验收标准）

    func testSuccessProducesNoAdditionalAction() {
        // 唯一「用户已听见」终局；T1 已在结果入账时判过，T2 不追加。
        XCTAssertNil(PlaybackEndgamePolicy.outcome(for: .success))
    }

    func testExhaustedRequiresHapticAndBanner() {
        // T2-2：激活穷尽（long-form + foreground 双失败）。横幅必须无视 T1 的
        // short_task / app_active（覆写口径在 Watch 层的 notifyPlaybackFailureIfEligible）。
        let outcome = PlaybackEndgamePolicy.outcome(for: .exhausted)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.haptic, .turnFailed)
        XCTAssertEqual(outcome?.shouldNotifyBanner, true)
        XCTAssertEqual(outcome?.reasonLabel, "exhausted")
    }

    func testHaltedRequiresHapticButNoBanner() {
        // T2-3：中断截断。结果卡片已有「未播完 · 重播」入口（unfinishedPlaybackIds），
        // 再发横幅会形成骚扰；触觉仍要震（熄屏用户靠这一下感知）。
        let outcome = PlaybackEndgamePolicy.outcome(for: .halted)
        XCTAssertEqual(outcome?.haptic, .turnFailed)
        XCTAssertEqual(outcome?.shouldNotifyBanner, false)
        XCTAssertEqual(outcome?.reasonLabel, "halted")
    }

    func testDeferredTimeoutBehavesLikeExhausted() {
        // T2-4：起播 30s 无 play_started（session.activate 回调丢失/挂起）。
        // 落地成失败终局，告知形态与 exhausted 一致。
        let outcome = PlaybackEndgamePolicy.outcome(for: .deferredTimeout)
        XCTAssertEqual(outcome?.haptic, .turnFailed)
        XCTAssertEqual(outcome?.shouldNotifyBanner, true)
        XCTAssertEqual(outcome?.reasonLabel, "deferred_timeout")
    }

    func testPlayRejectedAndResumeFailedAlsoNotify() {
        // 起播失败（player.play() 返回 false）与续播失败（前台 resume 失败）
        // 用户角度同 exhausted——什么也没听到，必须告知。
        for endgame: PlaybackEndgame in [.playRejected, .resumeFailed] {
            let outcome = PlaybackEndgamePolicy.outcome(for: endgame)
            XCTAssertEqual(outcome?.haptic, .turnFailed, "\(endgame) 应播失败触觉")
            XCTAssertEqual(outcome?.shouldNotifyBanner, true, "\(endgame) 应尝试发横幅")
        }
    }

    // MARK: - 阈值 & 文案

    func testDeferredTimeoutThresholdIsThirtySeconds() {
        // 30s 覆盖真机取证观测的两级激活最坏握手时间（<< 数秒），
        // 再等下去用户已离开界面，告知反而无意义。
        XCTAssertEqual(PlaybackEndgamePolicy.deferredTimeoutSeconds, 30)
    }

    func testFailureNotificationBodyIncludesSummaryAndOpensTranscriptHint() {
        // 摘要放正文前段（锁屏可见），后接「点开看文字」——诚实告知没能播出。
        let text = PlaybackEndgamePolicy.failureNotificationContent(
            resultSummary: "上海明天多云转小雨，最高 24 度"
        )
        XCTAssertEqual(text.title, "语音没能播出")
        XCTAssertTrue(text.body.contains("上海明天多云转小雨"))
        XCTAssertTrue(text.body.contains("点开看文字"))
    }

    func testFailureNotificationTruncatesLongSummaryAndNeverEmpty() {
        let long = String(repeating: "很", count: 80)
        let long_text = PlaybackEndgamePolicy.failureNotificationContent(resultSummary: long)
        XCTAssertTrue(long_text.body.contains("…"), "超长摘要必须截断加省略号")

        let empty = PlaybackEndgamePolicy.failureNotificationContent(resultSummary: "  ")
        XCTAssertFalse(empty.body.isEmpty, "空摘要也要有可读正文，禁止空 body")
        XCTAssertFalse(empty.title.isEmpty)
    }

    func testFailureNotificationNeverPretendsResultWasPlayed() {
        // 反向断言：不能让文案暗示语音已播出（防止后续误改）。
        let text = PlaybackEndgamePolicy.failureNotificationContent(resultSummary: "结果")
        XCTAssertFalse(text.title.contains("完成"), "T2 横幅不得复用「任务完成」文案")
        XCTAssertFalse(text.title.contains("结果来了"), "T2 横幅不得声称结果已到达用户")
    }
}
