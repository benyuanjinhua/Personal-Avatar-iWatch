import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-73 复现测试（watch 模拟器宿主进程运行，R-02 运行时证据）：
/// 真机取证显示 interruption .began 后 .ended 可能永远不投递（全库 grep
/// 6 条 began 0 条 ended），旧实现以 .ended 为唯一清除路径，导致后续所有
/// play() 被无限 defer（playback_deferred reason=interruption_active），
/// 播放通道直到 App 重启才恢复。修复后：新 play() 视为用户意图直接激活，
/// 激活结果说话；残留标志在激活成功时就地清除。
@MainActor
final class SpeechPlayerInterruptionTests: XCTestCase {

    private func welcomeSpeechData() throws -> Data {
        // 宿主 App 包内的真实 AAC/M4A 资产（3.3s），走与产线一致的解码路径。
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            "WelcomeSpeech.m4a 不在宿主 App 包内"
        )
        return try Data(contentsOf: url)
    }

    /// 向 SpeechPlayer 的观察者投递一条系统中断通知（观察者 object 为 nil，
    /// 进程内 post 与系统投递走同一路径）。
    private func postInterruption(_ type: AVAudioSession.InterruptionType) async throws {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
        // 观察者回调在 main queue 上再 hop 一次 MainActor Task，等两拍。
        try await Task.sleep(for: .milliseconds(200))
    }

    /// 验收标准 2：interruption=active 残留状态下发起全新一轮播放，
    /// 不得被 defer——必须直接激活并出声（play_started…play_finished）。
    func testNewPlaybackProceedsDespiteStaleInterruptionFlag() async throws {
        let player = SpeechPlayer()
        try await postInterruption(.began)
        // 不投 .ended —— 复现真机上通知丢失的残留状态。

        let data = try welcomeSpeechData()
        let finished = expectation(description: "playback finished")
        var playedToEnd = false
        let accepted = player.play(data: data, context: "ess73-stale-flag") { ok in
            playedToEnd = ok
            finished.fulfill()
        }
        XCTAssertTrue(accepted, "play() 必须受理请求")

        await fulfillment(of: [finished], timeout: 20)
        XCTAssertTrue(playedToEnd, "残留中断标志下新 play() 必须完整出声，而非被无限 defer")
        XCTAssertFalse(player.isPlaying, "播完后应离开播放态")
    }

    /// 验收标准 3（.began 分支）：播放中收到 .began，必须立即离开
    /// 「播放中」态并按未播完收尾（retainForReplay 入口由上层渲染）。
    func testInterruptionBeganHaltsPlaybackAsUnfinished() async throws {
        let player = SpeechPlayer()
        let data = try welcomeSpeechData()

        let finished = expectation(description: "halt callback")
        var playedToEnd = true
        player.play(data: data, context: "ess73-began-halt") { ok in
            playedToEnd = ok
            finished.fulfill()
        }
        // 等激活完成、进入真实播放，再打断。
        try await Task.sleep(for: .seconds(1))
        try await postInterruption(.began)

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(playedToEnd, ".began 打断的播放必须按未播完收尾（可重播）")
        XCTAssertFalse(player.isPlaying, ".began 后 UI 不得停留在「播放中」")

        // 回归：中断后的下一轮播放仍能正常出声（激活结果说话）。
        let second = expectation(description: "second playback finished")
        var secondOk = false
        player.play(data: data, context: "ess73-replay-after-began") { ok in
            secondOk = ok
            second.fulfill()
        }
        await fulfillment(of: [second], timeout: 20)
        XCTAssertTrue(secondOk, "中断留痕不得影响下一轮播放")
    }
}
