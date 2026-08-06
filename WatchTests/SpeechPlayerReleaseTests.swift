import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-224 运行时证据（R-02.1）：`SpeechPlayer.finishPlayback` 收尾必须把
/// 共享 AVAudioSession 交还——落 `session_released result=true` 事件（当且
/// 仅当本实例仍是当前 owner），与 `AudioRecorder.releaseSession` 对称。
/// 修复前只清进程内状态、从不 `setActive(false)`，Bridge 侧无从判定「会话
/// 是否真的交还」；复审补丁再补：owner 令牌 + category 兜底，防止旧 player
/// 晚到的收尾把新 player 刚激活的会话拆掉。
///
/// 毕玄 2026-08-04 复审要点：交错测试必须**真的有活跃的 B/Recorder**，
/// 不能只靠手工写 owner 证明 guard 会 return。本套件用两个真实
/// `SpeechPlayer`（`testStaleFinishSkipsWhenNewerPlayerActivelyOwnsSession`）
/// 与真实 `AudioRecorder`（`testPlayerReleaseSkipsWhenRecorderTookOverCategory`）
/// 覆盖：**A/Recorder 仍活跃时 A 的晚到 finish 必须走 skip，且 session
/// 未被 deactivate；三向流程零 !res / 零 playback_activation_exhausted**。
@MainActor
final class SpeechPlayerReleaseTests: XCTestCase {
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
        func snapshot() -> [CapturedEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
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
        // 不再在此处清 sharedSessionOwner：all tests in this class call
        // waitForHostWelcomeToFinish() before creating their own players,
        // and the host welcome's releaseAudioSession will naturally clear the
        // owner when it finishes.  Clearing prematurely orphans the welcome's
        // active session and causes crashes in subsequent tests (ESS-277).
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
    /// 播完自然 release 的 session_released 与本测试的事件混淆。
    private func waitForHostWelcomeToFinish() async throws {
        try await Task.sleep(for: .seconds(4))
    }

    // MARK: - 单实例基线

    /// exhausted 分支（双激活失败）：本实例**从未成为 owner**——`session_release_skipped
    /// skipped_reason=not_current_owner` 而不是 `session_released`。修复前
    /// 这一分支也会直接 `setActive(false)`，可能连带拆掉别的 player 会话。
    func testExhaustedEndgameSkipsReleaseWhenNotOwner() async throws {
        try await waitForHostWelcomeToFinish()
        let player = SpeechPlayer(instanceTag: "test-exhausted")
        player.selfCheckForcedActivationFailures = ["long_form", "foreground"]

        let endgameSeen = expectation(description: "T2 endgame callback fired")
        player.onPlaybackEndgame = { _, _, _ in endgameSeen.fulfill() }

        let data = try welcomeSpeechData()
        let accepted = player.play(data: data, context: "ess224-exhausted-\(UUID().uuidString)")
        XCTAssertTrue(accepted, "play() 必须受理请求，供内部走到 exhausted 分支")

        await fulfillment(of: [endgameSeen], timeout: 6)

        let skipped = collector.matches(
            event: "session_release_skipped",
            detailContains: "skipped_reason=not_current_owner"
        ).filter { $0.detail?.contains("reason=exhausted") == true }
        XCTAssertGreaterThanOrEqual(
            skipped.count, 1,
            "exhausted 分支从未激活成功、不是 owner，必须走 skip 分支——否则会误 deactivate 别人的会话"
        )
        XCTAssertEqual(
            collector.matches(event: "session_released",
                              detailContains: "reason=exhausted").count, 0,
            "exhausted 分支不得走真 release：本实例根本没拿到 owner 令牌"
        )
    }

    /// 完整播完分支：等一段真实 M4A 播完，`finishPlayback(endgame: .success)`
    /// 必须落 `session_released reason=success result=true`——**明确断言
    /// `result=true`**（毕玄复审要求）。资产约 3.3s，测试上限 15s。
    func testSuccessfulPlaybackEmitsSessionReleasedWithResultTrue() async throws {
        try await waitForHostWelcomeToFinish()
        let player = SpeechPlayer(instanceTag: "test-success")
        let data = try welcomeSpeechData()

        let finished = expectation(description: "playback finished")
        var playedToEnd = false
        let accepted = player.play(data: data, context: "ess224-success-\(UUID().uuidString)") { ok in
            playedToEnd = ok
            finished.fulfill()
        }
        XCTAssertTrue(accepted, "play() 必须受理请求")
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertTrue(playedToEnd, "M4A 资产必须完整播完；否则本用例前提不成立")

        let released = collector.matches(event: "session_released")
            .filter { $0.module == "player" && $0.detail?.contains("reason=success") == true }
            .filter { $0.detail?.contains("instance=test-success") == true }
        XCTAssertGreaterThanOrEqual(
            released.count, 1,
            "完整播完后必须落 session_released reason=success（无交还观测点即修复不可验证）"
        )
        let detail = released.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("result=true"),
            "session_released 必须明确 result=true，否则 setActive(false) 失败也会绿。实际=\(detail)"
        )
    }

    // MARK: - 真实交错场景

    /// **毕玄要求的真交错**：两个 SpeechPlayer 同时活跃——A 先激活并起播，
    /// 100ms 后 B 起播使 owner 转到 B。A 的音频较早结束（因为它先起播），
    /// A 的 `audioPlayerDidFinishPlaying → finishPlayback` 在 B **仍在播** 时
    /// 到达。修复后 A 检查 owner 发现是 B、走 skip 分支不 deactivate；B
    /// 继续正常播完并落自己的 `session_released result=true`。
    ///
    /// 关键断言：
    /// 1. A 的 finishPlayback 落 `session_release_skipped skipped_reason=not_current_owner`
    ///    ——证明真交错时 guard 生效，不是仅在人工写令牌时才 return
    /// 2. A 没有落 `session_released`（即 A 没执行 setActive(false)）
    /// 3. B 落 `session_released result=true instance=test-b`——证明 B 的
    ///    session 没被 A 拆
    /// 4. 全流程零 `playback_activation_exhausted`、零激活 `!res`
    ///    ——即三向 WatchLog 中「播 vs 播」这一向无 activation exhaustion
    func testStaleFinishSkipsWhenNewerPlayerActivelyOwnsSession() async throws {
        try await waitForHostWelcomeToFinish()
        let a = SpeechPlayer(instanceTag: "test-a")
        let b = SpeechPlayer(instanceTag: "test-b")
        let data = try welcomeSpeechData()

        // A 起播（真激活、真播 3.3s 音频）。
        let aFinished = expectation(description: "A playback finished")
        let bFinished = expectation(description: "B playback finished")
        a.play(data: data, context: "ess224-a-active-\(UUID().uuidString)") { _ in aFinished.fulfill() }

        // 给 A 一小段时间完成异步激活并起播，然后 B 起播——B 激活成功后
        // owner 转到 B，此后 A 的 finish 到达时 A 已不是 owner。
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            SpeechPlayer.sharedSessionOwner, ObjectIdentifier(a),
            "前提：A 激活后必须是当前 owner"
        )

        b.play(data: data, context: "ess224-b-active-\(UUID().uuidString)") { _ in bFinished.fulfill() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(
            SpeechPlayer.sharedSessionOwner, ObjectIdentifier(b),
            "前提：B 激活后 owner 必须转到 B（真交错的关键）"
        )

        // 等待两条播放都自然收尾（A 先，B 后）；A 的 finishPlayback 在 B
        // 仍活跃时到达，走 skip 是本用例的核心断言。
        await fulfillment(of: [aFinished, bFinished], timeout: 20)

        // 断言 1：A 落 skipped_reason=not_current_owner。
        let aSkips = collector.matches(
            event: "session_release_skipped",
            detailContains: "skipped_reason=not_current_owner"
        ).filter { $0.detail?.contains("instance=test-a") == true }
        XCTAssertGreaterThanOrEqual(
            aSkips.count, 1,
            "真交错场景：A 的 finishPlayback 到达时 owner 已是 B，必须落 skipped_reason=not_current_owner。缺失即 guard 未生效或事件契约漂移"
        )

        // 断言 2：A 没有走真 release——它不该拆 B 的会话。
        let aRelease = collector.matches(event: "session_released")
            .filter { $0.detail?.contains("instance=test-a") == true }
        XCTAssertEqual(
            aRelease.count, 0,
            "A 不是 owner 时不得落 session_released——落了就说明 setActive(false) 被调用、B 的 session 被拆"
        )

        // 断言 3：B 走完真 release，result=true。
        let bRelease = collector.matches(event: "session_released")
            .filter { $0.detail?.contains("instance=test-b") == true }
            .filter { $0.detail?.contains("result=true") == true }
        XCTAssertGreaterThanOrEqual(
            bRelease.count, 1,
            "B 是最终 owner，必须落 session_released result=true——否则 setActive(false) 出错也会绿"
        )

        // 断言 4：三向流程零 activation exhaustion（这一向是「播 vs 播」交接）。
        XCTAssertEqual(
            collector.matches(event: "playback_activation_exhausted").count, 0,
            "两 player 交接必须零 activation exhausted——出现即 !res 复现"
        )
        XCTAssertEqual(
            collector.matches(event: "session_activation_failed").count, 0,
            "两 player 交接必须零 session_activation_failed——出现即两级激活链坏"
        )
    }

    /// **毕玄要求的三向 WatchLog 之「播 → 录」交接**：真实 `AudioRecorder`
    /// 半路把共享 session 切成 `.playAndRecord` + 激活（等价 PTT 用户抢麦
    /// 场景）；player 的 finishPlayback 在 recorder 已接管时到达，category
    /// 兜底必须挡住——落 `session_release_skipped skipped_reason=category_taken_over`
    /// 而不是把 recorder 的 `.playAndRecord` session 拆掉。
    ///
    /// Headless 模拟器采集不可用，`recorder.start()` 会抛 cannotCreateRecorder，
    /// **但会话状态已被改成 `.playAndRecord`**——正是事故的危险态，走本单
    /// category 兜底逻辑与真机路径完全一致。
    func testPlayerReleaseSkipsWhenRecorderTookOverCategory() async throws {
        // ESS-498: same `recorder.start()` hang family — skip on hosted CI only.
        try HostedCITestGate.skipIfHostedCI("recorder.start() hangs in testPlayerReleaseSkipsWhenRecorderTookOverCategory")
        try await waitForHostWelcomeToFinish()
        let player = SpeechPlayer(instanceTag: "test-player-vs-recorder")
        let recorder = AudioRecorder()
        let data = try welcomeSpeechData()

        // Player 起播（真激活 .playback + 播 3.3s 音频）。
        let playerFinished = expectation(description: "player playback finished")
        player.play(data: data, context: "ess224-p-\(UUID().uuidString)") { _ in playerFinished.fulfill() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            SpeechPlayer.sharedSessionOwner, ObjectIdentifier(player),
            "前提：player 激活后是当前 owner"
        )

        // Recorder 接管：把 session 切到 .playAndRecord 并激活——这是
        // ESS-72 场景。headless 环境 start() 可能抛 cannotCreateRecorder，
        // 但 session category 已经被改。
        do {
            try await recorder.start()
        } catch RecorderError.permissionDenied {
            throw XCTSkip("宿主未授权麦克风：xcrun simctl privacy <sim> grant microphone")
        } catch RecorderError.cannotCreateRecorder {
            // 无采集也没关系，本用例只要 category 已被切到 .playAndRecord。
        }
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(
            session.category, .playAndRecord,
            "前提：AudioRecorder.start() 必须把 category 切到 .playAndRecord（事故的危险态）"
        )

        // 等 player 收尾：category 兜底应触发，player 不得 deactivate recorder 的会话。
        await fulfillment(of: [playerFinished], timeout: 20)

        // 断言 1：player 落 skipped_reason=category_taken_over。
        let categorySkips = collector.matches(
            event: "session_release_skipped",
            detailContains: "skipped_reason=category_taken_over"
        ).filter { $0.detail?.contains("instance=test-player-vs-recorder") == true }
        XCTAssertGreaterThanOrEqual(
            categorySkips.count, 1,
            "录音接管后 player 的 finishPlayback 必须落 skipped_reason=category_taken_over——修复前会直接 setActive(false) 拆掉 recorder 会话"
        )

        // 断言 2：player 没有落真 release（reason=success 或 halted）。
        let playerRelease = collector.matches(event: "session_released")
            .filter { $0.detail?.contains("instance=test-player-vs-recorder") == true }
        XCTAssertEqual(
            playerRelease.count, 0,
            "recorder 已接管 category，player 不得走真 release——落了即拆了 recorder 会话"
        )

        // 断言 3：三向流程零 activation exhaustion（这一向是「播 → 录」交接）。
        XCTAssertEqual(
            collector.matches(event: "playback_activation_exhausted").count, 0,
            "「播 → 录」交接必须零 activation exhausted——出现即 !res 复现"
        )

        // 收尾：让 recorder 交还，避免影响后续测试。
        recorder.cancel()
    }
}
