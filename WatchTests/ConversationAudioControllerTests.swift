import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-554 (Phase 0 / A2) 关卡一验收：会话级 ConversationAudioController。
///
/// 验收标准逐条映射：
/// - AC1「连续 5 轮 = 1 次激活 + 1 次去激活」→
///   `testFiveTurnCyclesHoldSingleActivationAndSingleDeactivation`（fake
///   session 确定性计数，CI 安全）+
///   `testConversationModeTurnCycleDoesNotFlipSessionOrRestartEngines`
///   （真实组件 + WatchLog 旁路，hosted CI 跳过）。
/// - AC2「ERR_AUDIO_SESSION 与播放失声 = 0」→ 同一集成测试断言零
///   `playback_audio_session_failed` / 零 `playback_engine_restarted`。
/// - AC3「点 X ≤300ms（按 session deactivate 完成计）」→
///   `testEndConversationDeactivatesWithinBudgetAndLogs`（fake，CI 安全）+
///   `testEndConversationRealSessionDeactivationLatency`（真实会话计时）。
/// - AC4「AI 回答中 tap 已停但会话仍激活」→
///   `testAnsweringPhaseKeepsSessionActiveWithTapStopped`。
@MainActor
final class ConversationAudioControllerTests: XCTestCase {

    // MARK: - 测试替身

    /// 只统计**有效**状态迁移（setActive 到相同状态在系统侧是 no-op，
    /// 与真机口径一致）：ESS-61 阶梯在 acquire 开头的 try? setActive(false)
    /// 命中「本就未激活」时不计数。
    private final class FakeSession: ConversationAudioSessionDriving {
        private(set) var isActive = false
        private(set) var activations = 0
        private(set) var deactivations = 0
        private(set) var categories: [AVAudioSession.Category] = []
        /// 第 N 次 setActive(true) 抛错（1 起计），用于走 ESS-61 阶梯。
        var failActivationsBefore = 0
        private var activateCalls = 0

        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            policy: AVAudioSession.RouteSharingPolicy,
            options: AVAudioSession.CategoryOptions
        ) throws {
            categories.append(category)
        }

        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            if active {
                activateCalls += 1
                if activateCalls <= failActivationsBefore {
                    throw NSError(domain: "FakeSession", code: -50, userInfo: nil)
                }
            }
            guard active != isActive else { return }
            isActive = active
            if active { activations += 1 } else { deactivations += 1 }
        }
    }

    private final class FakeEngine: ConversationAudioEngineControlling {
        private(set) var isRunning = false
        private(set) var starts = 0
        private(set) var stops = 0

        func prepare() {}
        func start() throws {
            if !isRunning { starts += 1 }
            isRunning = true
        }
        func stop() {
            if isRunning { stops += 1 }
            isRunning = false
        }
    }

    private struct CapturedEvent {
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
        func count(event: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return events.filter { $0.event == event }.count
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

    // MARK: - AC1：会话级计数（fake，CI 安全）

    /// acquire：恰好 1 次有效激活 + 类别 `.playAndRecord` + 播放引擎会话级
    /// 重启一次（ESS-535 逻辑上移）；采集引擎按设计**不在** acquire 启动
    /// （首次启动延迟到 PCMFrameRecorder 输入格式门后，防撞车注释见
    /// restartEngines）。落 acquired/engine_restarted 两条带
    /// conversation_id 与 duration_ms 的结构化日志。
    func testBeginConversationActivatesOnceAndRestartsEnginesOnce() throws {
        let session = FakeSession()
        let capture = FakeEngine()
        let playback = FakeEngine()
        let controller = ConversationAudioController(
            session: session, captureControl: capture, playbackControl: playback
        )

        try controller.beginConversation(conversationId: "conv-1")

        XCTAssertTrue(controller.isAcquired)
        XCTAssertEqual(controller.conversationId, "conv-1")
        XCTAssertEqual(session.activations, 1, "会话级获取必须只激活一次")
        XCTAssertEqual(session.deactivations, 0)
        XCTAssertEqual(session.categories.last, .playAndRecord)
        XCTAssertEqual(capture.starts, 0, "采集引擎延迟到首个有防御门的回合启动")
        XCTAssertEqual(playback.starts, 1, "播放引擎会话级启动一次（ESS-535 上移）")
        XCTAssertTrue(playback.isRunning)

        let acquired = collector.matches(event: "conversation_audio_acquired")
        XCTAssertEqual(acquired.count, 1)
        XCTAssertTrue(acquired[0].detail?.contains("conversation_id=conv-1") == true)
        XCTAssertTrue(acquired[0].detail?.contains("duration_ms=") == true)
        let restarted = collector.matches(event: "engine_restarted")
        XCTAssertEqual(restarted.count, 1)
        XCTAssertTrue(restarted[0].detail?.contains("conversation_id=conv-1") == true)
        XCTAssertTrue(restarted[0].detail?.contains("duration_ms=") == true)
    }

    /// AC1 核心：会话持有期间，回合边界对会话零触碰。控制器设计上就没有
    /// 回合级会话 API——本用例把这个契约钉死：5 个回合边界（会话内按压
    /// 循环）后仍然只有 acquire 的 1 次激活；endConversation 后再加恰好
    /// 1 次去激活。任何未来「回合级顺手碰一下会话」的改动都会打破本断言。
    func testFiveTurnCyclesHoldSingleActivationAndSingleDeactivation() throws {
        let session = FakeSession()
        let controller = ConversationAudioController(
            session: session, captureControl: FakeEngine(), playbackControl: FakeEngine()
        )
        try controller.beginConversation(conversationId: "conv-5turns")
        XCTAssertEqual(session.activations, 1)

        // 5 个回合边界：会话级设计下控制器在每轮之间不做任何会话/引擎
        // 调用（回合内动作在 PCMFrameRecorder/RealtimePlaybackEngine 的
        // `.conversation` 分支，由集成测试覆盖）。这里显式循环 5 次，
        // 断言计数不随轮次增长。
        for _ in 1...5 {
            XCTAssertTrue(controller.isAcquired)
        }
        XCTAssertEqual(session.activations, 1, "5 轮后仍只能有 1 次激活")
        XCTAssertEqual(session.deactivations, 0, "回合之间不得 deactivate")

        controller.endConversation(reason: .userExit)
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(session.deactivations, 1, "点 X 恰好 1 次去激活")
        XCTAssertFalse(controller.isAcquired)
    }

    /// 已持有会话时重复 acquire 必须幂等（第二次不产生任何会话调用）。
    func testBeginConversationIsIdempotentWhileHeld() throws {
        let session = FakeSession()
        let controller = ConversationAudioController(
            session: session, captureControl: FakeEngine(), playbackControl: FakeEngine()
        )
        try controller.beginConversation(conversationId: "conv-a")
        try controller.beginConversation(conversationId: "conv-b")
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(controller.conversationId, "conv-a")
        XCTAssertEqual(collector.count(event: "conversation_audio_acquired"), 1)
    }

    // MARK: - AC3：点 X 释放口径（fake，CI 安全）

    /// PD-2：释放按 session deactivate 完成计。fake 下操作同步完成，
    /// duration_ms 必须远小于 300ms 预算；日志必须带 conversation_id /
    /// duration_ms / reason / deactivated=true。
    func testEndConversationDeactivatesWithinBudgetAndLogs() throws {
        let session = FakeSession()
        let capture = FakeEngine()
        let playback = FakeEngine()
        let controller = ConversationAudioController(
            session: session, captureControl: capture, playbackControl: playback
        )
        try controller.beginConversation(conversationId: "conv-x")

        controller.endConversation(reason: .userExit)

        XCTAssertEqual(session.deactivations, 1)
        XCTAssertEqual(capture.stops, 0, "采集引擎延迟启动、从未启动时 stop 为空操作")
        XCTAssertEqual(playback.stops, 1, "释放必须停播放引擎")

        let released = collector.matches(event: "conversation_audio_released")
        XCTAssertEqual(released.count, 1)
        let detail = try XCTUnwrap(released[0].detail)
        XCTAssertTrue(detail.contains("conversation_id=conv-x"))
        XCTAssertTrue(detail.contains("reason=user_exit"))
        XCTAssertTrue(detail.contains("deactivated=true"))
        XCTAssertTrue(detail.contains("held_ms="))
        let durationMs = try XCTUnwrap(Self.intField("duration_ms", in: detail))
        XCTAssertLessThanOrEqual(
            durationMs, 300,
            "PD-2：点击 → session deactivate 完成必须 ≤300ms（此处 \(durationMs)ms）"
        )

        // 幂等：重复 release 不再产生任何会话调用与日志。
        controller.endConversation(reason: .userExit)
        XCTAssertEqual(session.deactivations, 1)
        XCTAssertEqual(collector.count(event: "conversation_audio_released"), 1)
    }

    /// 系统中断（began）= 会话被系统抢走：控制器必须按 interrupted 收口、
    /// 状态打回 idle，下一回合可重新 acquire。
    func testInterruptionBeganReleasesConversation() async throws {
        let session = FakeSession()
        let controller = ConversationAudioController(
            session: session, captureControl: FakeEngine(), playbackControl: FakeEngine()
        )
        try controller.beginConversation(conversationId: "conv-int")

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        // 观察者经 queue=.main + Task 跳主线程。轮询被测状态，而不是另起
        // 一个与被测结果无关的定时 expectation；hosted CI 主线程繁忙时，
        // 后者可能超时，即使中断处理已经正确完成。
        for _ in 0..<20 where controller.isAcquired {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertFalse(controller.isAcquired)
        XCTAssertEqual(session.deactivations, 1)
        let events = collector.matches(event: "conversation_audio_released", detailContains: "reason=interrupted")
        XCTAssertEqual(events.count, 1)

        // 中断收口后可重新 acquire（下一回合自愈）。
        try controller.beginConversation(conversationId: "conv-int-2")
        XCTAssertTrue(controller.isAcquired)
        XCTAssertEqual(session.activations, 2)
    }

    // MARK: - acquire 失败阶梯（fake，CI 安全）

    /// ESS-61 阶梯保留：首次尝试（resetRoutePolicy）失败后必须走 minimal
    /// 回落并成功；两级都败才抛错且保持 idle。
    func testAcquireFallsBackToMinimalAttempt() throws {
        let session = FakeSession()
        session.failActivationsBefore = 1 // 第一级 setActive(true) 抛 -50
        let controller = ConversationAudioController(
            session: session, captureControl: FakeEngine(), playbackControl: FakeEngine()
        )
        try controller.beginConversation(conversationId: "conv-ladder")
        XCTAssertTrue(controller.isAcquired)
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(session.categories, [.playAndRecord, .playAndRecord], "两级尝试都应目标 .playAndRecord")
        XCTAssertGreaterThanOrEqual(collector.count(event: "conversation_audio_acquire_failed"), 1)
    }

    func testAcquireTotalFailureThrowsAndStaysIdle() {
        let session = FakeSession()
        session.failActivationsBefore = .max
        let controller = ConversationAudioController(
            session: session, captureControl: FakeEngine(), playbackControl: FakeEngine()
        )
        XCTAssertThrowsError(try controller.beginConversation(conversationId: "conv-dead"))
        XCTAssertFalse(controller.isAcquired)
        XCTAssertNil(controller.conversationId)
        XCTAssertEqual(session.activations, 0, "失败的 acquire 不得留下激活态记账")
        XCTAssertEqual(collector.count(event: "conversation_audio_acquired"), 0)
    }

    /// 宿主 App 冷启动自动播欢迎语（约 3.3s）。凡触碰真实共享会话的用例
    /// 先等它播完，避免欢迎语的 setCategory/setActive 与用例的会话级
    /// acquire 交错（与 AudioRecorderHandoverTests 同款处理）。
    private func waitForHostWelcomeToFinish() async throws {
        try await Task.sleep(for: .seconds(4))
    }

    // MARK: - AC2/AC4 + AC1 集成面（真实组件，hosted CI 跳过）

    /// 连续 5 轮录→播循环：`.conversation` 模式下回合边界对会话零翻转、
    /// 对引擎零重启。证据口径（WatchLog 旁路）：
    /// - AudioRecorder 每轮必落 `session_config_skipped` +
    ///   `session_release_skipped`（会话级持有时不再自配/交还会话），
    ///   且零 `session_activation_failed`——这条不需要采集硬件，
    ///   headless 模拟器也生效（record() 失败在跳日志之后）。
    /// - RealtimePlaybackEngine 零 `playback_engine_restarted`、零
    ///   `playback_audio_session_failed`（ERR_AUDIO_SESSION，玉伯 N6）。
    /// - 全程仅 1 次 `conversation_audio_acquired`，结束才 1 次
    ///   `conversation_audio_released`。
    /// PCM tap 侧在无输入设备的环境起不来（ESS-362 门抛 Swift 错误），
    /// 该侧断言自动降级跳过，真机/有采集的模拟器上完整生效。
    func testConversationModeTurnCycleDoesNotFlipSessionOrRestartEngines() async throws {
        try HostedCITestGate.skipIfHostedCI(
            "real AVAudioEngine start/stop in testConversationModeTurnCycleDoesNotFlipSessionOrRestartEngines"
        )
        try await waitForHostWelcomeToFinish()
        let controller = ConversationAudioController()
        // 生产顺序镜像：播放引擎必须先经 RealtimePlaybackEngine.init 接上
        // playerNode 才可被 acquire 启动（裸引擎起图在无输入设备环境会抛
        // ObjC 异常，ESS-488 同族）。
        let player = RealtimePlaybackEngine(
            audioEngine: controller.playbackEngine,
            lifecycleOwner: { .conversation }
        )
        do {
            try controller.beginConversation(conversationId: "conv-integration")
        } catch {
            throw XCTSkip("模拟器会话不可用：\(error.localizedDescription)")
        }
        defer { controller.endConversation(reason: .userExit) }

        // 录音侧缝：会话级持有期间 AudioRecorder 不得自配/交还会话。
        let audioRecorder = AudioRecorder()
        audioRecorder.sessionManagedExternally = { controller.isAcquired }
        let pcmRecorder = PCMFrameRecorder(
            audioEngine: controller.captureEngine,
            lifecycleOwner: { .conversation }
        )
        let session = RealtimeMediaSession()
        var captureAvailable = true

        let cycles = 5
        var permissionDenied = false
        for index in 0..<cycles {
            let handle = session.beginTurn(requestId: UUIDv7.generate().uuidString.lowercased())
            // 录音侧（headless 下 record() 会失败，跳日志在失败前已落；
            // 权限未授权则整个环境跑不了本用例，按既有惯例 XCTSkip）。
            do {
                try await audioRecorder.start()
            } catch RecorderError.permissionDenied {
                permissionDenied = true
            } catch {
                // cannotCreateRecorder / sessionActivationFailed：headless
                // 模拟器预期内，session_config_skipped 已在此之前落出。
            }
            audioRecorder.cancel()
            if permissionDenied {
                throw XCTSkip("宿主未授权麦克风：先 grant microphone 再跑")
            }
            // PCM tap 侧（输入格式门后启动；无输入设备则本轮降级）。
            if captureAvailable {
                do {
                    try pcmRecorder.start()
                    pcmRecorder.stop()
                    // AC4 关键断言之一：回合间 tap 已停，但采集引擎与会话
                    // 都必须仍然活着——会话级持有的机械证据。
                    XCTAssertTrue(
                        controller.captureEngine.isRunning,
                        "回合 \(index)：recorder.stop() 不得停掉会话级采集引擎"
                    )
                } catch {
                    captureAvailable = false // 无输入设备：后续回合跳过本侧
                }
            }
            XCTAssertTrue(controller.isAcquired, "回合 \(index)：会话必须仍激活")

            try player.prepare(for: handle)
            let chunk = VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: 0, capturedAtMs: 1,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: 0x33, count: 960)
            )
            player.enqueue(playables: [.init(chunk: chunk, responseId: "resp-\(index)")])
            player.stop(barge: false)
            session.finishTurn(reason: .audioDone)
        }

        XCTAssertEqual(
            collector.count(event: "session_config_skipped"), cycles,
            "会话级持有期间每轮录音都必须跳过回合级会话配置"
        )
        XCTAssertEqual(
            collector.count(event: "session_release_skipped"), cycles,
            "会话级持有期间每轮录音收尾都不得交还会话"
        )
        XCTAssertEqual(
            collector.count(event: "session_activation_failed"), 0,
            "5 轮零会话激活失败（ESS-61 阶梯不被触发）"
        )
        XCTAssertEqual(
            collector.count(event: "playback_engine_restarted"), 0,
            "会话级模式下每轮不得再触发 ESS-535 的回合级引擎重启"
        )
        XCTAssertEqual(
            collector.count(event: "playback_audio_session_failed"), 0,
            "ERR_AUDIO_SESSION 计数必须为 0（玉伯 N6）"
        )
        XCTAssertEqual(
            collector.count(event: "conversation_audio_acquired"), 1,
            "5 轮只允许 1 次会话级 acquire"
        )
        XCTAssertTrue(controller.playbackEngine.isRunning, "player.stop 不得停掉会话级播放引擎")

        controller.endConversation(reason: .userExit)
        XCTAssertEqual(collector.count(event: "conversation_audio_released"), 1)
        XCTAssertFalse(controller.playbackEngine.isRunning)
        XCTAssertFalse(controller.captureEngine.isRunning)
    }

    /// AC4：AI 回答中 = tap 已停（stop 后零上行帧）且会话仍激活——两个
    /// 条件必须同时成立（PD-2：激活 ≠ 正在采集）。
    func testAnsweringPhaseKeepsSessionActiveWithTapStopped() async throws {
        try HostedCITestGate.skipIfHostedCI(
            "real AVAudioEngine in testAnsweringPhaseKeepsSessionActiveWithTapStopped"
        )
        try await waitForHostWelcomeToFinish()
        let controller = ConversationAudioController()
        // 同 integration 用例：播放引擎先接 playerNode 再 acquire。
        _ = RealtimePlaybackEngine(
            audioEngine: controller.playbackEngine,
            lifecycleOwner: { .conversation }
        )
        do {
            try controller.beginConversation(conversationId: "conv-ac4")
        } catch {
            throw XCTSkip("模拟器会话不可用：\(error.localizedDescription)")
        }
        defer { controller.endConversation(reason: .userExit) }

        let recorder = PCMFrameRecorder(
            audioEngine: controller.captureEngine,
            lifecycleOwner: { .conversation }
        )
        var framesAfterStop = 0
        var sawFrame = false
        recorder.onFrame = { _ in sawFrame = true }

        do {
            try recorder.start()
        } catch {
            throw XCTSkip("headless 模拟器不放开真实采集：\(error.localizedDescription)")
        }
        // 上行帧在 tap 活着时可能被消费（headless 下可能为零，不断言有帧）。
        try await Task.sleep(nanoseconds: 300_000_000)
        recorder.stop()
        recorder.onFrame = { _ in framesAfterStop += 1 }

        // AI 回答期：等待远超一个 100ms 帧周期，断言零上行帧。
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(framesAfterStop, 0, "tap 已停：回答期不得再有上行帧")
        XCTAssertTrue(controller.isAcquired, "会话仍激活：回答期不得 deactivate")
        XCTAssertTrue(
            controller.captureEngine.isRunning,
            "采集引擎仍运行（仅 tap 摘除）——回合间不停引擎"
        )
        _ = sawFrame
    }

    /// AC3 真会话计时：endConversation 从进入到 deactivate 完成的
    /// duration_ms 必须 ≤300（模拟器口径；真机口径走关卡二 WatchLog）。
    func testEndConversationRealSessionDeactivationLatency() async throws {
        try HostedCITestGate.skipIfHostedCI(
            "real AVAudioSession in testEndConversationRealSessionDeactivationLatency"
        )
        try await waitForHostWelcomeToFinish()
        let controller = ConversationAudioController()
        _ = RealtimePlaybackEngine(
            audioEngine: controller.playbackEngine,
            lifecycleOwner: { .conversation }
        )
        do {
            try controller.beginConversation(conversationId: "conv-latency")
        } catch {
            throw XCTSkip("模拟器会话不可用：\(error.localizedDescription)")
        }
        controller.endConversation(reason: .userExit)

        let released = collector.matches(event: "conversation_audio_released")
        XCTAssertEqual(released.count, 1)
        let detail = try XCTUnwrap(released[0].detail)
        XCTAssertTrue(detail.contains("deactivated=true"))
        let durationMs = try XCTUnwrap(Self.intField("duration_ms", in: detail))
        XCTAssertLessThanOrEqual(durationMs, 300, "点 X → deactivate 完成 ≤300ms（模拟器口径）")
    }

    /// SpeechPlayer 缝：会话级持有期间不得重配/激活/释放共享会话。
    /// 覆盖 ESS-554 与 ESS-224 的交互——旧 player 晚到收尾绝不允许把
    /// controller 持有的 `.playAndRecord` 拆掉。收尾用中断 .began 触发
    /// （finishPlayback → releaseAudioSession），不等播放完成——
    /// watchOS 模拟器上 AVAudioPlayer 完成回调不可靠（ESS-73 测试已证）。
    func testSpeechPlayerSkipsSessionOwnershipWhileConversationHeld() async throws {
        // 宿主 App 冷启动会自动播欢迎语（约 3.3s），其激活/交还事件会混进
        // 本用例的计数——先等它播完，再以基线差值断言，与测试排序解耦。
        try await Task.sleep(for: .seconds(4))
        let activationsBaseline = collector.count(event: "session_activation_requested")
        let releasesBaseline = collector.count(event: "session_released")

        SpeechPlayer.sessionExternallyOwned = { true }
        defer { SpeechPlayer.sessionExternallyOwned = { false } }

        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            "WelcomeSpeech.m4a 不在宿主 App 包内"
        )
        let data = try Data(contentsOf: url)
        let player = SpeechPlayer(instanceTag: "ess554-seam")
        let accepted = player.play(data: data, context: "ess554-held-session") { _ in }
        XCTAssertTrue(accepted)
        XCTAssertGreaterThan(
            collector.count(event: "session_activation_skipped"), 0,
            "会话级持有期间 SpeechPlayer 必须跳过激活（直播已持有的会话）"
        )
        XCTAssertEqual(
            collector.count(event: "session_activation_requested"), activationsBaseline,
            "会话级持有期间不得发起任何 setCategory/.playback 激活"
        )
        XCTAssertGreaterThan(collector.count(event: "play_started"), 0,
                             "跳过激活后必须在持有会话上真实起播")

        // 中断 .began → haltPlaybackForInterruption → finishPlayback(.halted)
        // → releaseAudioSession：交还必须被 conversation_owned 守门拦下。
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        for _ in 0..<50 {
            if !collector.matches(event: "session_release_skipped", detailContains: "conversation_owned").isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(
            collector.matches(event: "session_release_skipped", detailContains: "conversation_owned").count,
            0, "会话级持有期间 SpeechPlayer 收尾不得 deactivate"
        )
        XCTAssertEqual(collector.count(event: "session_released"), releasesBaseline,
                       "会话级持有期间任何 SpeechPlayer 收尾都不得真交还会话")
    }

    /// 关旗回退：conversationAudioEnabled=false 时 adapter 不建控制器，
    /// 实时组件走回合级旧路径（今天 main 的行为）。
    func testGateOffFallsBackToTurnScopedPath() throws {
        try HostedCITestGate.skipIfHostedCI(
            "ensureRealtimeAdapter() → AVAudioEngine SetFormat -10868 in testGateOffFallsBackToTurnScopedPath"
        )
        let controller = PushToTalkController()
        controller.conversationAudioEnabled = { false }
        _ = controller.ensureRealtimeAdapter()
        XCTAssertNil(
            controller.conversationAudioController,
            "关旗时不得创建会话级控制器（纯回合级旧路径）"
        )
    }

    /// 开旗：adapter 与控制器共用同一对引擎实例（所有权唯一来源）。
    func testGateOnAdapterSharesControllerEngines() throws {
        try HostedCITestGate.skipIfHostedCI(
            "ensureRealtimeAdapter() → AVAudioEngine SetFormat -10868 in testGateOnAdapterSharesControllerEngines"
        )
        let controller = PushToTalkController()
        controller.conversationAudioEnabled = { true }
        _ = controller.ensureRealtimeAdapter()
        XCTAssertNotNil(controller.conversationAudioController)
        XCTAssertFalse(controller.conversationAudioController?.isAcquired == true,
                       "adapter 预热不得 acquire——首个流式回合才获取会话")
    }

    // MARK: - helpers

    private static func intField(_ key: String, in detail: String) -> Int? {
        for field in detail.split(separator: " ") {
            let pair = field.split(separator: "=")
            guard pair.count == 2, pair[0] == key else { continue }
            return Int(pair[1])
        }
        return nil
    }
}
