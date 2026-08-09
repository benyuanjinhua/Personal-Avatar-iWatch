import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-228 Phase 1 evidence-only 断言（白梦林 2026-08-04 mandate）：
/// 只验证新增取证字段落地，**不断言任何运行时行为变化**。
/// 目的：让代码复审可以逐条核对「新字段 = 只加不改」，与 ESS-73/64 现有
/// 行为契约相互独立。
@MainActor
final class SpeechPlayerInterruptionEvidenceTests: XCTestCase {

    /// 捕获 `WatchLog` 输出的观察者，测试期间独占。
    private final class Sink: @unchecked Sendable {
        struct Entry { let module: String; let event: String; let detail: String? }
        private let lock = NSLock()
        private var entries: [Entry] = []
        func record(module: String, event: String, detail: String?, code: String?) {
            lock.lock(); defer { lock.unlock() }
            entries.append(Entry(module: module, event: event, detail: detail))
        }
        func snapshot() -> [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    override func setUp() {
        super.setUp()
        WatchLog.setObserver(nil)
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        super.tearDown()
    }

    func testInterruptionLogCarriesInstanceTagAndUserInfoFields() async throws {
        let sink = Sink()
        WatchLog.setObserver { module, event, _, detail, code in sink.record(module: module, event: event, detail: detail, code: code) }

        let a = SpeechPlayer(instanceTag: "evidence-a")
        let b = SpeechPlayer(instanceTag: "evidence-b")
        // 显式引用以防 ARC 在 post 前把两个实例回收掉（`_ = SpeechPlayer()`
        // 直接就是「构造完就析构」，观察者根本没时间收到通知）。
        defer { _ = (a, b) }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        try await Task.sleep(for: .milliseconds(300))

        let events = sink.snapshot().filter { $0.event == "session_interruption" }
        XCTAssertGreaterThanOrEqual(events.count, 2, "两个实例都应该独立记一条 began")

        // E1：每条 began 必须携带 instance=<tag>
        let aHits = events.filter { ($0.detail ?? "").contains("instance=evidence-a") }
        let bHits = events.filter { ($0.detail ?? "").contains("instance=evidence-b") }
        XCTAssertFalse(aHits.isEmpty, "evidence-a 实例必须落一条")
        XCTAssertFalse(bHits.isEmpty, "evidence-b 实例必须落一条")

        // E3：新字段必须出现（合成通知 reason/was_suspended 是 absent，should_resume 是 yes）
        let sample = try XCTUnwrap(aHits.first?.detail)
        XCTAssertTrue(sample.contains("state=began"), "旧字段保留：state=began")
        XCTAssertTrue(sample.contains("type=1"), "新字段：AVAudioSessionInterruptionTypeKey raw=1")
        XCTAssertTrue(sample.contains("reason="), "新字段：AVAudioSessionInterruptionReasonKey")
        XCTAssertTrue(sample.contains("should_resume=yes"), "新字段：Options.shouldResume 位命中即 yes")
        XCTAssertTrue(sample.contains("was_suspended="), "新字段：WasSuspendedKey（缺失也要落 absent）")

        // E4：会话状态快照字段必须出现
        XCTAssertTrue(sample.contains("category="), "E4：category")
        XCTAssertTrue(sample.contains("mode="), "E4：mode")
        XCTAssertTrue(sample.contains("route_share="), "E4：routeSharingPolicy")
        XCTAssertTrue(sample.contains("other_audio="), "E4：isOtherAudioPlaying")
        XCTAssertTrue(sample.contains("secondary_silence="), "E4：secondaryAudioShouldBeSilencedHint")
        XCTAssertTrue(sample.contains("route_out="), "E4：currentRoute outputs")
        XCTAssertTrue(sample.contains("route_in="), "E4：currentRoute inputs")

        // 行为不变的兜底：ESS-73 兜底路径的 interruption_flag_cleared 事件在
        // 「无播放请求」下不应出现——本单不动清除时机。
        let flagCleared = sink.snapshot().filter { $0.event == "interruption_flag_cleared" }
        XCTAssertTrue(flagCleared.isEmpty, "Phase 1 evidence-only：清除路径未被触发")
    }

    func testObserverLifecycleEventsFire() async throws {
        let sink = Sink()
        WatchLog.setObserver { module, event, _, detail, code in sink.record(module: module, event: event, detail: detail, code: code) }

        do {
            _ = SpeechPlayer(instanceTag: "lifecycle-x")
        }
        // 让 deinit 与内部 Task 有机会落尾。
        try await Task.sleep(for: .milliseconds(200))

        let registered = sink.snapshot().filter { $0.event == "interruption_observer_registered" }
        XCTAssertTrue(registered.contains { ($0.detail ?? "").contains("instance=lifecycle-x") }, "注册事件必须落 instance=lifecycle-x")
        XCTAssertTrue(registered.allSatisfy { ($0.detail ?? "").contains("queue=main") }, "注册时 queue 必须是 main")
    }
}
