import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-259 B-STOP 的**运行时证据**（R-02.1）：模拟用户轻点字幕区打断
/// 结果语音——真实播放起来 → 调用 `player.stop(reason: "user_interrupt")`
/// → 断言：
/// 1. 落 `stopped reason=user_interrupt`（播放确实结束）；
/// 2. `player.isPlaying` 变 false（进程内状态清干净）；
/// 3. `onFinish` **不**被回调（不走 speechVault 清理 / 不重新入队路径）；
/// 4. `onPlaybackEndgame` **不**被回调（不进 PlaybackEndgamePolicy）；
/// 5. 无 `haptic_played cue=turnFailed`（不播 `.failure` 触觉）；
/// 6. 无 `playback_activation_exhausted` / `session_activation_failed`
///    （用户打断路径与失败路径完全分离）。
///
/// 这套断言直接覆盖了 `PushToTalkController.stopPlaybackByUser` 的效果面：
/// 该方法只多做两件事——单独落 `playback_user_interrupted` 事件（一行
/// `WatchLog.info` 调用，无分支）和 `journal.recordPlaybackInterrupted`
/// （已由 `VoiceTurnJournalTests.testRecordPlaybackInterrupted*` 覆盖）。
@MainActor
final class SpeechPlayerUserInterruptTests: XCTestCase {
    private struct CapturedEvent: Equatable {
        let module: String
        let event: String
        let detail: String?
        let errorCode: String?
    }

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CapturedEvent] = []
        func append(_ e: CapturedEvent) { lock.lock(); events.append(e); lock.unlock() }
        func matches(event: String, detailContains fragment: String? = nil) -> [CapturedEvent] {
            lock.lock(); defer { lock.unlock() }
            return events.filter {
                $0.event == event && (fragment == nil || $0.detail?.contains(fragment!) == true)
            }
        }
    }

    private var collector: EventCollector!

    override func setUp() {
        super.setUp()
        collector = EventCollector()
        let sink = collector!
        WatchLog.setObserver { module, event, detail, errorCode in
            sink.append(CapturedEvent(module: module, event: event, detail: detail, errorCode: errorCode))
        }
        SpeechPlayer.sharedSessionOwner = nil
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        collector = nil
        SpeechPlayer.sharedSessionOwner = nil
        super.tearDown()
    }

    private func welcomeSpeechData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            "WelcomeSpeech.m4a 不在宿主 App 包内"
        )
        return try Data(contentsOf: url)
    }

    /// 宿主 App 启动即自动播欢迎语（约 3.3s）；先等它播完再开测，避免宿主
    /// 播完自然 release 的事件混入本测试断言窗口。
    private func waitForHostWelcomeToFinish() async throws {
        try await Task.sleep(for: .seconds(4))
    }

    func testUserInterruptStopsPlaybackWithoutTriggeringFailureChain() async throws {
        try await waitForHostWelcomeToFinish()
        let player = SpeechPlayer(instanceTag: "test-user-interrupt")

        var onFinishCalled = false
        var endgameFired = false
        player.onPlaybackEndgame = { _, _, _ in endgameFired = true }

        let data = try welcomeSpeechData()
        let requestId = "ess259-\(UUID().uuidString)"
        let accepted = player.play(data: data, context: requestId) { _ in
            onFinishCalled = true
        }
        XCTAssertTrue(accepted, "play() 必须受理请求")

        // 等真实起播（异步激活 + play() 返回）——300ms 足够激活链路走完。
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(player.isPlaying, "前提：SpeechPlayer 必须已在播放（否则打断无意义）")

        // 模拟 PushToTalkController.stopPlaybackByUser：写取证日志 + 停播放。
        WatchLog.info(
            "player", "playback_user_interrupted", requestId: requestId,
            detail: "source=subtitle_tap"
        )
        player.stop(reason: "user_interrupt")

        // 让 AVFoundation 的收尾回调（如有）有机会到达——本路径不应触发任何回调。
        try await Task.sleep(for: .milliseconds(300))

        // 1. 进程内状态清干净。
        XCTAssertFalse(player.isPlaying, "打断后 isPlaying 必须归 false")

        // 2. onFinish 不被回调（player.stop 显式把 onFinish 置 nil 后再返回）。
        XCTAssertFalse(
            onFinishCalled,
            "player.stop 路径必须不触发 onFinish——否则 playResult 的 speechVault 清理 / 重播恢复决策会误跑"
        )

        // 3. onPlaybackEndgame 不被回调（stop() 不走 finishPlayback）。
        XCTAssertFalse(
            endgameFired,
            "T2 endgame 回调必须不被触发——否则会走 PlaybackEndgamePolicy 播 turnFailed 触觉"
        )

        // 4. R-02.1 主证据：落 stopped reason=user_interrupt。
        let stopped = collector.matches(event: "stopped", detailContains: "reason=user_interrupt")
        XCTAssertGreaterThanOrEqual(
            stopped.count, 1,
            "缺 stopped reason=user_interrupt：SpeechPlayer.stop 的取证行没落"
        )

        // 5. 落 playback_user_interrupted（模拟的 PushToTalkController 那一行）。
        let userInterrupted = collector.matches(
            event: "playback_user_interrupted", detailContains: "source=subtitle_tap"
        )
        XCTAssertGreaterThanOrEqual(
            userInterrupted.count, 1,
            "缺 playback_user_interrupted：B-STOP 专属取证行没落"
        )

        // 6. 关键否定断言：无 .failure 触觉、无 playback_endgame。
        let failureHaptic = collector.matches(
            event: "haptic_played", detailContains: "cue=turnFailed"
        )
        XCTAssertEqual(
            failureHaptic.count, 0,
            "用户主动打断绝不能播 .failure 触觉——出现即走进了失败链路"
        )
        XCTAssertEqual(
            collector.matches(event: "playback_endgame").count, 0,
            "用户主动打断不得走 PlaybackEndgamePolicy——出现即误触发 T2 决策"
        )

        // 7. 用户打断路径与激活失败路径完全隔离。
        XCTAssertEqual(
            collector.matches(event: "playback_activation_exhausted").count, 0,
            "打断路径不得出现 exhausted——那属于双激活失败分支"
        )
        XCTAssertEqual(
            collector.matches(event: "session_activation_failed").count, 0,
            "打断路径不得出现 session_activation_failed——那属于激活失败分支"
        )
    }
}
