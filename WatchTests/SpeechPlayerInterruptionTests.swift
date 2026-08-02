import AVFoundation
import XCTest
@testable import WristAgent_Watch_App

/// ESS-73 运行时复现与修复断言（watchOS 模拟器，真实 AVAudioSession +
/// 真实 SpeechPlayer 状态机，非旁路模拟）。
///
/// 事故：真机 2026-08-02 09:12 收到 interruption .began ×4 后 .ended 永远
/// 没来（watchOS 不保证投递），此后所有播放请求 playback_deferred
/// reason=interruption_active，直到重启 App——语音送达、UI「播放中」、零声音。
///
/// 修复契约：
/// 1. 中断新鲜（< interruptionTrustWindow）时 play() 仍必须 defer 且零激活
///    尝试（ESS-64/S5 契约不变）；
/// 2. .ended 永不到达时，defer 在信任窗口过期后必须自动重试激活并起播——
///    播放通道不允许永久锁死。
@MainActor
final class SpeechPlayerInterruptionTests: XCTestCase {
    /// WatchLog 观察者是全局单槽（SelfCheck 同款用法）：按事件名计数断言。
    private let signals = InterruptionTestSignals()

    override func setUp() async throws {
        // 宿主 App 启动即跑装机自检（S1 在模拟器上 ~200ms 内失败退出）并播
        // 欢迎语（~3.3s）。等它们让出音频会话与全局观察者槽，再开始断言。
        try await Task.sleep(nanoseconds: 5_000_000_000)
        WatchLog.setObserver { [signals] _, event, _, _ in
            signals.record(event)
        }
    }

    override func tearDown() async throws {
        WatchLog.setObserver(nil)
        // 清掉本测试可能残留的中断标记，不污染宿主 App 的其他实例。
        Self.postInterruption(.ended)
    }

    /// 事故复现 + 修复断言：.began 后 .ended 永不投递，新播放请求先 defer、
    /// 信任窗口过期后自动重试并真正起播。全程零 .ended。
    func testStaleInterruptionRecoversWithoutEnded() async throws {
        let player = SpeechPlayer()
        let data = try speechAsset()

        Self.postInterruption(.began)
        // 通知处理经 Task 跳一拍主线程。
        try await Task.sleep(nanoseconds: 200_000_000)

        var finishedResult: Bool?
        player.play(data: data, context: "ess73-stale") { finishedResult = $0 }

        // 契约 1（S5 不变）：新鲜中断内必须 defer，零激活尝试、零起播。
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThan(signals.count("playback_deferred"), 0, "新鲜中断内必须 defer")
        XCTAssertEqual(signals.count("session_activation_requested"), 0, "新鲜中断内不得尝试激活")
        XCTAssertEqual(signals.count("play_started"), 0, "新鲜中断内不得起播")

        // 契约 2（本单修复）：不发 .ended，等信任窗口过期 + 重试余量。
        let recovered = await waitUntil(timeout: AudioSessionPolicy.interruptionTrustWindow + 4) {
            [signals] in signals.count("play_started") > 0
        }
        XCTAssertGreaterThan(signals.count("playback_deferred_retry"), 0, "窗口过期后必须自动重试")
        XCTAssertTrue(recovered, ".ended 丢失时播放通道不得永久锁死——重试后必须起播")

        // 收尾：等播完或直接停，不影响后续测试。
        _ = await waitUntil(timeout: 6) { finishedResult != nil }
        player.stop(reason: "ess73_test_complete")
    }

    /// 回归保护：.ended 正常到达时仍走原恢复路径（defer → ended → 起播），
    /// 不受重试机制影响。
    func testEndedStillResumesPromptly() async throws {
        let player = SpeechPlayer()
        let data = try speechAsset()

        Self.postInterruption(.began)
        try await Task.sleep(nanoseconds: 200_000_000)
        player.play(data: data, context: "ess73-ended")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(signals.count("play_started"), 0)

        Self.postInterruption(.ended)
        let resumed = await waitUntil(timeout: 6) { [signals] in signals.count("play_started") > 0 }
        XCTAssertTrue(resumed, ".ended 到达后必须立即恢复播放")
        player.stop(reason: "ess73_test_complete")
    }

    // MARK: - 支撑

    private func speechAsset() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            "宿主 App 内置语音资产缺失"
        )
        return try Data(contentsOf: url)
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return predicate()
    }

    private static func postInterruption(_ type: AVAudioSession.InterruptionType) {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
    }
}

/// 观察者回调可能来自任意线程（WatchLog 契约），计数加锁。
private final class InterruptionTestSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func count(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0 == event }.count
    }
}
