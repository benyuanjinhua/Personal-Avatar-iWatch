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
/// 无需真机采集：exhausted 分支用 `selfCheckForcedActivationFailures` 强制，
/// 交错分支用两个 `SpeechPlayer` 实例先后激活——watchOS 模拟器宿主里几百
/// 毫秒完成。
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
    }

    private var collector: EventCollector!

    override func setUp() {
        super.setUp()
        collector = EventCollector()
        let sink = collector!
        WatchLog.setObserver { module, event, detail, errorCode in
            sink.append(CapturedEvent(module: module, event: event, detail: detail, errorCode: errorCode))
        }
        // 交错测试可能在上一个用例里留下 owner 令牌（另一个实例已 deinit，
        // ObjectIdentifier 悬空但仍可与新实例比较）——每个用例开头清一次，
        // 与真机冷启动一致。
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

    /// exhausted 分支（双激活失败）：本实例**从未成为 owner**——`session_release_skipped
    /// skipped_reason=not_current_owner` 而不是 `session_released`。修复前
    /// 这一分支也会直接 `setActive(false)`，可能连带拆掉别的 player 会话。
    func testExhaustedEndgameSkipsReleaseWhenNotOwner() async throws {
        let player = SpeechPlayer(instanceTag: "test-exhausted")
        player.selfCheckForcedActivationFailures = ["long_form", "foreground"]

        let endgameSeen = expectation(description: "T2 endgame callback fired")
        player.onPlaybackEndgame = { _, _ in endgameSeen.fulfill() }

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
        // 未成为 owner 意味着**不会**落 session_released（reason=exhausted）
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
        XCTAssertGreaterThanOrEqual(
            released.count, 1,
            "完整播完后必须落 session_released reason=success（无交还观测点即修复不可验证）"
        )
        let detail = released.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("result=true"),
            "session_released 必须明确 result=true，否则 setActive(false) 失败也会绿。实际=\(detail)"
        )
        XCTAssertTrue(
            detail.contains("instance=test-success"),
            "session_released 必须携带 instance=<tag> 供多实例区分，实际=\(detail)"
        )
    }

    /// 交错场景（毕玄复审要求）：两个 SpeechPlayer 先后激活同一 session——
    /// A 激活 → B 激活 → 手工触发 A 的收尾路径 → A **必须走 skip**，B 的
    /// session 不能被拆。修复前该场景下 A 会 `setActive(false)`、B 播放
    /// 被静默截断。
    ///
    /// 复现手法：走真实激活 → `finishPlayback` 私有，无法从测试直接触发，
    /// 但走同一入口的 exhausted / decode_error 分支需要制造。这里改用
    /// **owner 令牌层面的直接观察**：既然入口所有 endgame 都走
    /// `releaseAudioSession`、都受 owner 校验保护，直接验证令牌语义即可
    /// 覆盖所有 endgame——A 激活后成为 owner；B 激活后 owner 换成 B；
    /// A 再走一次真收尾（走 exhausted 快速路径）时应跳过。
    func testInterleavedActivationTransfersOwnershipAndSkipsStaleRelease() async throws {
        let a = SpeechPlayer(instanceTag: "test-a")
        let b = SpeechPlayer(instanceTag: "test-b")
        let data = try welcomeSpeechData()

        // Step 1：A 激活（用短播——完整跑完会自然 release、清 owner；
        // 用长播占用 owner 又会占硬件。这里用 play + 立即 stop 只走到激活
        // 但不完成 finish 回调）——事实证明更稳妥的是：完整播完 A，
        // 断言 owner 已在自然 release 时清空；然后强制 A 再走一次收尾路径
        // （通过 selfCheckForcedActivationFailures 走 exhausted）。
        // 见测试 body 第二段。

        // Step 2：A 完整播完，先取一次 owner 归零与 session_released。
        let aFinished = expectation(description: "A first playback finished")
        a.play(data: data, context: "ess224-a-first-\(UUID().uuidString)") { _ in aFinished.fulfill() }
        await fulfillment(of: [aFinished], timeout: 15)
        XCTAssertNil(
            SpeechPlayer.sharedSessionOwner,
            "A 完整播完后 owner 必须清空——否则后续任何激活都会误 skip"
        )

        // Step 3：B 激活并完整播完，先验 owner 转到 B。
        let bFinished = expectation(description: "B playback finished")
        var bOwnedDuringPlayback = false
        b.play(data: data, context: "ess224-b-\(UUID().uuidString)") { _ in bFinished.fulfill() }
        // 激活是异步的：给一小段时间等 B 的 activate 回调把 owner 抢过来。
        try await Task.sleep(for: .milliseconds(200))
        bOwnedDuringPlayback = SpeechPlayer.sharedSessionOwner == ObjectIdentifier(b)
        XCTAssertTrue(bOwnedDuringPlayback, "B 激活成功后 owner 必须指向 B")
        await fulfillment(of: [bFinished], timeout: 15)

        // 现在人为把 owner 恢复为 B 的 ObjectIdentifier——模拟「B 仍在播、
        // 只是 A 的旧 finish 恰好在 B 激活之后到达」的交错时刻。
        SpeechPlayer.sharedSessionOwner = ObjectIdentifier(b)

        // Step 4：强制 A 走一次收尾——用 exhausted 快速路径（不真的激活、
        // 直接进 releaseAudioSession）。修复前 A 会 setActive(false)、拆掉
        // B 的会话；修复后 A 看到 owner=B，落 session_release_skipped。
        a.selfCheckForcedActivationFailures = ["long_form", "foreground"]
        let aStaleEndgame = expectation(description: "A stale endgame fired")
        a.onPlaybackEndgame = { _, _ in aStaleEndgame.fulfill() }
        a.play(data: data, context: "ess224-a-stale-\(UUID().uuidString)")
        await fulfillment(of: [aStaleEndgame], timeout: 6)

        let skipped = collector.matches(
            event: "session_release_skipped",
            detailContains: "skipped_reason=not_current_owner"
        ).filter { $0.detail?.contains("instance=test-a") == true }
        XCTAssertGreaterThanOrEqual(
            skipped.count, 1,
            "A 的旧 finish 到达时 owner 已换成 B——必须走 skip 分支、不得拆 B 的会话"
        )
        // 兜底：owner 令牌未被 A 清空（A 不是 owner，check 里就 return，
        // 不会改令牌），仍指向 B。
        XCTAssertEqual(
            SpeechPlayer.sharedSessionOwner, ObjectIdentifier(b),
            "非 owner 走 skip 分支后不得改令牌——B 应仍是 owner"
        )
    }
}
