import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-224 运行时证据（R-02.1）：`SpeechPlayer.finishPlayback` 收尾必须把
/// 共享 AVAudioSession 交还——落 `session_released result=true` 事件，与
/// `AudioRecorder.releaseSession` 对称。修复前只清进程内状态、从不
/// `setActive(false)`，Bridge 侧无从判定「会话是否真的交还」。
///
/// 无需真机采集：用 `selfCheckForcedActivationFailures` 强制走到 exhausted
/// 分支（`finishPlayback(endgame: .exhausted)`），路径与 T2 决策 / 交还
/// 逻辑同一入口，watchOS 模拟器宿主里几百毫秒完成。
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
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        collector = nil
        super.tearDown()
    }

    private func welcomeSpeechData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            "WelcomeSpeech.m4a 不在宿主 App 包内"
        )
        return try Data(contentsOf: url)
    }

    /// exhausted 分支（双激活失败）验证：`finishPlayback` 必须落一条
    /// `session_released` 事件，`module=player`、`reason=exhausted`、
    /// `instance=` 携带实例标签。修复前该分支只落 `playback_activation_exhausted`，
    /// 没有交还观测点。
    func testExhaustedEndgameEmitsSessionReleased() async throws {
        let player = SpeechPlayer(instanceTag: "test-exhausted")
        player.selfCheckForcedActivationFailures = ["long_form", "foreground"]

        let endgameSeen = expectation(description: "T2 endgame callback fired")
        player.onPlaybackEndgame = { _, _ in endgameSeen.fulfill() }

        let data = try welcomeSpeechData()
        let accepted = player.play(data: data, context: "ess224-exhausted-\(UUID().uuidString)")
        XCTAssertTrue(accepted, "play() 必须受理请求，供内部走到 exhausted 分支")

        await fulfillment(of: [endgameSeen], timeout: 6)

        let released = collector.matches(event: "session_released")
            .filter { $0.module == "player" }
        XCTAssertGreaterThanOrEqual(
            released.count, 1,
            "缺 session_released：SpeechPlayer.finishPlayback 没有归还共享 AVAudioSession"
        )
        let detail = released.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("reason=exhausted"),
            "session_released 必须携带 reason=exhausted（终局标签），实际=\(detail)"
        )
        XCTAssertTrue(
            detail.contains("instance=test-exhausted"),
            "session_released 必须携带 instance=<tag> 供多实例区分，实际=\(detail)"
        )
    }

    /// 完整播完分支：等一段真实 M4A 播完，`finishPlayback(endgame: .success)`
    /// 也必须落 `session_released reason=success`。资产约 3.3s，测试上限 15s。
    func testSuccessfulPlaybackEmitsSessionReleased() async throws {
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
    }
}
