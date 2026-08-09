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

    private final class LogSink: @unchecked Sendable {
        struct Entry { let event: String; let detail: String? }
        private let lock = NSLock()
        private var entries: [Entry] = []

        func record(event: String, detail: String?) {
            lock.lock(); defer { lock.unlock() }
            entries.append(Entry(event: event, detail: detail))
        }

        func snapshot() -> [Entry] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    override func setUp() {
        super.setUp()
        WatchLog.setObserver(nil)
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        super.tearDown()
    }

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
    /// 不得被 defer——必须直接激活并进入 play_started。音频完成回调不属于
    /// 本用例契约：watchOS 26.5 模拟器可能持续保持 AVAudioPlayer playing，
    /// 即使运行时已经明确落出 play_started，等待完成会在 20 秒后杀测试宿主。
    func testNewPlaybackProceedsDespiteStaleInterruptionFlag() async throws {
        let sink = LogSink()
        WatchLog.setObserver { _, event, _, detail, _ in
            sink.record(event: event, detail: detail)
        }
        let player = SpeechPlayer()
        try await postInterruption(.began)
        // 不投 .ended —— 复现真机上通知丢失的残留状态。

        let data = try welcomeSpeechData()
        let accepted = player.play(data: data, context: "ess73-stale-flag")
        XCTAssertTrue(accepted, "play() 必须受理请求")

        // 异步 activate 回调通常在几十毫秒内到；轮询日志而非固定等完整音频，
        // 既验证真实起播路径，又避免模拟器 completion 回调的不稳定性。
        for _ in 0..<50 {
            let events = sink.snapshot().map(\.event)
            if events.contains("interruption_flag_cleared"), events.contains("play_started") {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let events = sink.snapshot()
        XCTAssertTrue(
            events.contains { $0.event == "interruption_flag_cleared" &&
                ($0.detail ?? "").contains("reason=activation_succeeded") },
            "激活成功必须清除陈旧 interruption flag"
        )
        XCTAssertTrue(events.contains { $0.event == "play_started" },
                      "残留中断标志下新 play() 必须进入真实起播路径，而非被 defer")
        XCTAssertFalse(events.contains { $0.event == "playback_deferred" },
                       "陈旧 interruption flag 不得 defer 新播放")

        player.stop(reason: "test_cleanup")
        XCTAssertFalse(player.isPlaying, "测试清理后应离开播放态")
    }

    /// 验收标准 3（.began 分支）：播放中收到 .began，必须立即离开
    /// 「播放中」态并按未播完收尾（retainForReplay 入口由上层渲染）。
    func testInterruptionBeganHaltsPlaybackAsUnfinished() async throws {
        let sink = LogSink()
        WatchLog.setObserver { _, event, _, detail, _ in
            sink.record(event: event, detail: detail)
        }
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
        let priorStarts = sink.snapshot().filter { $0.event == "play_started" }.count
        XCTAssertTrue(player.play(data: data, context: "ess73-replay-after-began"),
                      "中断后的第二轮播放必须受理")
        for _ in 0..<50 {
            if sink.snapshot().filter({ $0.event == "play_started" }).count > priorStarts {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(
            sink.snapshot().filter { $0.event == "play_started" }.count,
            priorStarts,
            "中断留痕不得影响下一轮真实起播"
        )
        player.stop(reason: "test_cleanup")
    }
}
