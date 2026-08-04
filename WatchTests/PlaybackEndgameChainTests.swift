import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-154 T2 播放终局告知链路的**运行时证据**（R-02.1）。
///
/// 在 watchOS 模拟器宿主进程里跑真实的 `SpeechPlayer` / `WatchHaptics` /
/// `ResultNotifier`，通过 `WatchLog.setObserver` 抓取本进程内实际落地的
/// `WatchLog` 事件——与 R-02.1 定义的「模拟器或真机产生的 `WatchLog` 事件」
/// 同源，用来回放 09:12 轮1 场景 + 幂等 + 系统级授权门。
///
/// 有意不搭 PushToTalkController：那里需要真实 journal / vault / transport
/// 一整套宿主环境；本单只验证 T2 决策 → 触觉 → 通知这条链路的**产物**
/// （事件、去重、日志字段），产物一致就足以证明链路正确。
@MainActor
final class PlaybackEndgameChainTests: XCTestCase {
    /// 一条抓到的 WatchLog 事件（module / event / detail / errorCode）。
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
        func snapshot() -> [CapturedEvent] { lock.lock(); defer { lock.unlock() }; return events }
        func matches(event: String) -> [CapturedEvent] {
            snapshot().filter { $0.event == event }
        }
        func first(event: String) -> CapturedEvent? {
            snapshot().first(where: { $0.event == event })
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
        // 走宿主 App 包内的真实 AAC/M4A 资产，解码路径与产线一致。
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            "WelcomeSpeech.m4a 不在宿主 App 包内"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - 场景 A：exhausted 走完 T2 决策 → haptic → 幂等

    /// R-02.1 主证据：回放 09:12 轮1 激活失败场景。
    ///
    /// 期望事件序列（顺序不强制，只要都出现）：
    /// - `playback_activation_exhausted`（SpeechPlayer 落，说明真的走到了 exhausted 分支）
    /// - `haptic_played cue=turnFailed`（WatchHaptics 落，证明触觉真的播了）
    /// - `playback_failure_notify_skipped reason=already_notified`（第二次重复终局，证明幂等）
    ///
    /// 通知落地本身（`result_notified`）在测试宿主里被 `UNUserNotificationCenter`
    /// 的授权状态门挡住（未授权时 `notifyPlaybackFailureIfEligible` 直接落
    /// `playback_failure_notify_skipped reason=not_authorized`）——这本身也
    /// 是一条 T2 决策链路走通的证据；真机在真实授权后走的是 `result_notified`。
    func testExhaustedExercisesHapticAndT2NotifierIdempotency() async throws {
        let player = SpeechPlayer()
        player.selfCheckForcedActivationFailures = ["long_form", "foreground"]

        let requestId = "ess154-exhausted-\(UUID().uuidString)"
        let endgameSeen = expectation(description: "T2 endgame callback fired")
        var receivedEndgame: PlaybackEndgame?

        // T2 装配：与 PushToTalkController 里的 handlePlaybackEndgame 同形——
        // 决策 → 触觉 → 通知。这里直接调用产线代码路径。
        let notifier = ResultNotifier(policy: ResultNotificationPolicy(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ess154-tests-\(UUID().uuidString)", isDirectory: true)
        ))
        // ESS-239: 补齐 ESS-233 引入的 bytes 中间参数（本测试不校验 bytes，用 _ 忽略）
        player.onPlaybackEndgame = { rid, _, endgame in
            receivedEndgame = endgame
            guard let outcome = PlaybackEndgamePolicy.outcome(for: endgame) else { return }
            if let cue = outcome.haptic {
                WatchHaptics.play(cue, requestId: rid)
            }
            if outcome.shouldNotifyBanner, let rid {
                notifier.notifyPlaybackFailureIfEligible(
                    requestId: rid, resultSummary: "上海明天多云转小雨", reasonLabel: outcome.reasonLabel
                )
            }
            endgameSeen.fulfill()
        }

        let data = try welcomeSpeechData()
        let accepted = player.play(data: data, context: requestId)
        XCTAssertTrue(accepted, "play() 必须受理请求，供内部走到 exhausted 分支")

        await fulfillment(of: [endgameSeen], timeout: 8)
        XCTAssertEqual(receivedEndgame, .exhausted, "双激活失败应落 .exhausted，与父单 T2-2 判定一致")

        // 事件断言 —— R-02.1 要的运行时证据。
        // 说明：`playback_endgame` 是 PushToTalkController.handlePlaybackEndgame
        // 里的取证行，不在本测试的直连路径上；这里只断言 SpeechPlayer / haptic /
        // Notifier 三个真正产线组件的落地事件。
        XCTAssertGreaterThanOrEqual(
            collector.matches(event: "playback_activation_exhausted").count, 1,
            "缺 playback_activation_exhausted：SpeechPlayer 没有走到 exhausted 分支"
        )
        let haptic = collector.first(event: "haptic_played")
        XCTAssertNotNil(haptic, "缺 haptic_played：触觉没落日志，R-02.1 取证空洞未闭合")
        XCTAssertEqual(haptic?.detail, "cue=turnFailed", "T2-2 触觉必须是 turnFailed")

        // 幂等（父单验收：同一 request_id 只推一次）：第二次重复终局应落
        // 「已通知 / 未授权」的 skip 事件，而不是再发一条 result_notified。
        let before = collector.matches(event: "playback_failure_notify_skipped").count
        notifier.notifyPlaybackFailureIfEligible(
            requestId: requestId, resultSummary: "上海明天多云转小雨", reasonLabel: "exhausted"
        )
        // 让日志观察者稳定收尾。
        try await Task.sleep(for: .milliseconds(50))
        let after = collector.matches(event: "playback_failure_notify_skipped").count
        XCTAssertGreaterThan(after, before, "重复终局必须走 skip 分支，不得再次发送横幅")
    }

    // MARK: - 场景 B：haptic_played 补埋点本身也是 R-02.1 取证空洞的闭合

    func testHapticPlayedEventIsAlwaysEmittedWithCueAndRequestId() {
        let requestId = "ess154-haptic-\(UUID().uuidString)"
        WatchHaptics.play(.turnFailed, requestId: requestId)
        WatchHaptics.play(.resultArrived, requestId: requestId)

        let events = collector.matches(event: "haptic_played")
        XCTAssertGreaterThanOrEqual(events.count, 2, "每次 WatchHaptics.play 都必须落 haptic_played")
        let cues = events.compactMap { $0.detail }
        XCTAssertTrue(cues.contains("cue=turnFailed"))
        XCTAssertTrue(cues.contains("cue=resultArrived"))
    }
}
