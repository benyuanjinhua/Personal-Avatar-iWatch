import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-137 会话让出屏障（S1→S2 / S3→S3R）的 watchOS 宿主运行时证据（R-02.1）。
///
/// 真机事故链：录音刚结束（`recorder.finish()` 里的 `setActive(false,
/// .notifyOthersOnDeactivation)` 只是提交请求），紧随其后的
/// `SpeechPlayer.activateSession` 立即两级 !res(561145203) 并落
/// `playback_activation_exhausted`——`SelfCheckRunner` 里 S2 就此判 fail。
/// 修复：在 record→play 步骤之间跑 `yieldRecordSessionForPlayback` 屏障，
/// 轮询 `setCategory(.playback, .longFormAudio)` 直到通过或探测序列耗尽。
///
/// 模拟器限制：headless 环境下 mic 不放行，`SelfCheckRunner` 无法从 S1 起跑；
/// 但屏障本身只碰共享 AVAudioSession 与 WatchLog，无需 mic 采集——本测
/// 直接把会话手动置成 `.playAndRecord`（事故前置态），再触发屏障，断言
/// `selfcheck_session_yield` 事件已落 + 会话已切到 `.playback`。
@MainActor
final class SelfCheckYieldBarrierTests: XCTestCase {

    /// WatchLog 观察者旁路：与 SelfCheckRunner / AudioRecorderHandoverTests 同机制。
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(event: String, detail: String?, code: String?)] = []
        func record(event: String, detail: String?, code: String?) {
            lock.lock(); defer { lock.unlock() }
            entries.append((event, detail, code))
        }
        func matches(event: String, detailContains fragment: String? = nil) -> [(String?, String?)] {
            lock.lock(); defer { lock.unlock() }
            return entries.compactMap {
                guard $0.event == event else { return nil }
                if let fragment, !($0.detail?.contains(fragment) ?? false) { return nil }
                return ($0.detail, $0.code)
            }
        }
    }

    /// 宿主 App 启动即自动播欢迎语（约 3.3s），会占据播放通道——先等它播完再开测。
    private func waitForHostWelcomeToFinish() async throws {
        try await Task.sleep(for: .seconds(4))
    }

    /// R-02.1 运行时证据：屏障必须把 .playAndRecord 归还到 .playback 可用，
    /// 且落下可判定的 selfcheck_session_yield 事件。
    func testYieldBarrierRestoresPlaybackCategoryAndLogsEvent() async throws {
        try await waitForHostWelcomeToFinish()
        let session = AVAudioSession.sharedInstance()
        // 事故前置态：AudioRecorder.start() 里的等价配置。用 minimal 分支（无
        // options）以兼容 watchOS 10——.allowBluetooth 只在 watchOS 11+ 可用。
        try session.setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
        try session.setActive(true)
        XCTAssertEqual(session.category, .playAndRecord, "前置态：会话应为 .playAndRecord")

        let events = EventLog()
        WatchLog.setObserver { _, event, detail, code in events.record(event: event, detail: detail, code: code) }
        defer { WatchLog.setObserver(nil) }

        let runner = SelfCheckRunner()
        await runner.yieldRecordSessionForPlayback(prevStep: .record, nextStep: .playback)

        // 屏障通过：会话应能起播（category=.playback 是 .longFormAudio 的
        // 前置——setCategory 通过即证明硬件已归还）。
        XCTAssertEqual(
            session.category, .playback,
            "屏障退出后会话必须切到 .playback（.playAndRecord 已归还）"
        )
        let matches = events.matches(event: "selfcheck_session_yield")
        XCTAssertGreaterThan(matches.count, 0, "屏障必须落 selfcheck_session_yield 取证事件")
        let (detail, code) = try XCTUnwrap(matches.last)
        let text = try XCTUnwrap(detail)
        XCTAssertTrue(text.contains("from=S1"), "detail 需带 from=<prev>")
        XCTAssertTrue(text.contains("to=S2"), "detail 需带 to=<next>")
        XCTAssertTrue(text.contains("result=ready"), "模拟器上屏障应立即 ready；实际 detail=\(text)")
        XCTAssertTrue(text.contains("probes="), "detail 需带探测次数")
        XCTAssertTrue(text.contains("elapsed_ms="), "detail 需带耗时")
        XCTAssertNil(code, "屏障通过时 error_code 必须为空")

        // 收尾：把会话切回默认，避免污染后续用例。
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 契约：屏障使用的探测等待序列固定为 [0, 100, 200, 400] ms。
    /// 序列变化会直接影响真机上 S1→S2 的最大可承受硬件释放延迟；
    /// 该常量既是运行时行为，也是被 G9 门禁 / 复现事故时对账的锚点。
    func testYieldWaitScheduleIsStable() {
        XCTAssertEqual(SelfCheckRunner.sessionYieldWaitsMs, [0, 100, 200, 400])
    }
}
