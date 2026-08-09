import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-519 复审加固的运行时证据（R-02.1）：
///
/// 1. `makeSilentWAV` 必须是结构合法的 16-bit mono PCM WAV——头部字段错一
///    个字节，`AVAudioPlayer(data:)` 就会初始化失败，breather 静默不启动，
///    真机上表现为「等结果时仍然锁屏退出」而日志只有一行 start_failed。
/// 2. 安全上限：回合以非播放方式终结（失败 cue / 纯文本结果）或结果永远
///    不到达时，breather 不得无限循环静音音频在背景耗电——到点必须自动停，
///    并落 `breather.stopped reason=safety_cap` 事件。
@MainActor
final class BackgroundAudioBreatherTests: XCTestCase {

    private final class LogSink: @unchecked Sendable {
        struct Entry {
            let module: String
            let event: String
            let detail: String?
        }

        private let lock = NSLock()
        private var entries: [Entry] = []

        func record(module: String, event: String, detail: String?) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(Entry(module: module, event: event, detail: detail))
        }

        func detail(module: String, event: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return entries.last { $0.module == module && $0.event == event }?.detail
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

    // MARK: - WAV 结构

    func testSilentWAVHeaderAndPayload() {
        let wav = BackgroundAudioBreather.makeSilentWAV()

        // 2s × 8000Hz × 2B = 32000B 数据 + 44B 头。
        XCTAssertEqual(wav.count, 44 + 32000)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")

        // 手工小端解析：Data 存储不保证对齐，不能直接 load(as: UInt32.self)。
        func uint32(_ o: Int) -> UInt32 {
            UInt32(wav[o]) | UInt32(wav[o + 1]) << 8 | UInt32(wav[o + 2]) << 16 | UInt32(wav[o + 3]) << 24
        }
        func uint16(_ o: Int) -> UInt16 {
            UInt16(wav[o]) | UInt16(wav[o + 1]) << 8
        }
        XCTAssertEqual(uint32(4), UInt32(36 + 32000))   // file size field
        XCTAssertEqual(uint16(20), 1)                   // PCM format tag
        XCTAssertEqual(uint16(22), 1)                   // channels (mono)
        XCTAssertEqual(uint32(24), 8000)                // sample rate
        XCTAssertEqual(uint32(28), 16000)               // byte rate
        XCTAssertEqual(uint16(32), 2)                   // block align
        XCTAssertEqual(uint16(34), 16)                  // bits per sample
        XCTAssertEqual(uint32(40), 32000)               // data size
        // 载荷必须全零（绝对静音）。
        XCTAssertTrue(wav[44...].allSatisfy { $0 == 0 })
    }

    /// 生成的 WAV 必须能被 AVAudioPlayer 真正解析——头合法但播放器拒绝时
    /// breather 在真机上会静默失效。
    func testSilentWAVIsAcceptedByAVAudioPlayer() throws {
        let player = try AVAudioPlayer(data: BackgroundAudioBreather.makeSilentWAV())
        XCTAssertEqual(player.duration, 2.0, accuracy: 0.01)
    }

    // MARK: - 安全上限

    func testSafetyCapStopsActiveBreather() async throws {
        let sink = LogSink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        let breather = BackgroundAudioBreather(maxDuration: 0.3)
        breather.start()
        // 模拟器音频会话不可用时不硬失败——cap 逻辑在真机验证（R-02.5 关卡二）。
        try XCTSkipUnless(breather.isActive, "audio session unavailable on this simulator")

        let deadline = Date().addingTimeInterval(5)
        while breather.isActive && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(breather.isActive, "safety cap must stop the breather after maxDuration")
        XCTAssertEqual(
            sink.detail(module: "breather", event: "stopped"),
            "reason=safety_cap deactivated=true",
            "safety-cap runtime evidence must retain the concrete stop reason"
        )
    }

    func testExplicitStopBeforeCapStaysStopped() async throws {
        let breather = BackgroundAudioBreather(maxDuration: 0.3)
        breather.start()
        try XCTSkipUnless(breather.isActive, "audio session unavailable on this simulator")

        breather.stop(reason: "test")
        XCTAssertFalse(breather.isActive)
        // 上限已过仍不得复活或被二次触发。
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(breather.isActive)
    }

    func testStopWhenInactiveIsNoOp() {
        let breather = BackgroundAudioBreather()
        breather.stop(reason: "test")
        XCTAssertFalse(breather.isActive)
    }

    // MARK: - Controller 接线

    /// ESS-587 接线 + ESS-604 环境无关化。
    ///
    /// 断言目标只有一件事：`submit()` 必须调到 `breather.start()`。**是否
    /// 真的激活成功**取决于宿主 App 运行态——GitHub hosted runner 上 xctest
    /// 宿主是 `.inactive`，`start()` 按 ESS-519 设计早退并落
    /// `start_skipped reason=app_not_active`（run 31299560674 的 L1 证据）。
    /// 旧版硬断言 `isActive` 把这个环境差异记成了产品缺陷，main 自
    /// `21b5f07d` 起 CI 连红。接线保护不削弱：submit 若不再调 breather，
    /// 两类事件都不会出现，用例照样失败。
    func testSubmitStartsBreatherAfterTransportDispatch() throws {
        let controller = PushToTalkController()
        let sink = LogSink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        controller.voiceStreamingEnabled = { false }
        let recording = AudioRecorder.Recording(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ess587-\(UUID().uuidString).m4a"),
            data: Data(repeating: 0x33, count: 128),
            durationMs: 1_500
        )

        controller.simulateSubmitForTests(recording: recording)
        defer { controller.breather.stop(reason: "test_cleanup") }

        let started = sink.detail(module: "breather", event: "started")
        let skipped = sink.detail(module: "breather", event: "start_skipped")
        XCTAssertTrue(
            started != nil || skipped != nil,
            "submit must invoke the production breather wiring"
        )
        if let started {
            XCTAssertEqual(
                started, "sample_rate=8000 duration_s=2 loops=-1",
                "submit must produce runtime evidence from the real breather"
            )
            XCTAssertTrue(controller.breather.isActive)
        } else {
            XCTAssertEqual(
                skipped, "reason=app_not_active state=inactive",
                "唯一可接受的未启动原因是宿主 App 非 active（ESS-519 早退）"
            )
            XCTAssertFalse(controller.breather.isActive)
        }
    }

    // MARK: - ESS-603 会话音频所有权

    /// 数窗口内**真实**的共享会话调用，用来证明「category 不被改写」
    /// 不是靠日志 scraping（R-02.1 同款口径，与
    /// ConversationAudioControllerTests.FakeSession 对齐）。
    private final class SpySession: ConversationAudioSessionDriving {
        private(set) var categories: [AVAudioSession.Category] = []
        private(set) var activations = 0
        private(set) var deactivations = 0

        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            policy: AVAudioSession.RouteSharingPolicy,
            options: AVAudioSession.CategoryOptions
        ) throws {
            categories.append(category)
        }

        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            if active { activations += 1 } else { deactivations += 1 }
        }
    }

    /// SpySession 会吞掉 breather 对**真实**共享会话的交还，而真实
    /// `AVAudioPlayer` 仍在同一个进程里播过音。用完必须手动把真实会话
    /// 交还，否则会污染同进程后续用例（本套件的实时音频用例对残留的
    /// 激活会话极敏感）。
    private func releaseRealSharedSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// AC1：会话级 owner 持有期间 submit 不得启动 breather，且共享会话的
    /// category 一次都不能被改写。
    ///
    /// 所有权判定放在 app-state 判定之前，因此本用例在 hosted CI（宿主
    /// `.inactive`）与本地模拟器（`.active`）上结论一致——不需要音频硬件。
    func testConversationOwnedSessionBlocksStartAndLeavesCategoryUntouched() {
        let sink = LogSink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        let session = SpySession()
        let breather = BackgroundAudioBreather(session: session)
        breather.isSessionOwnedExternally = { true }

        breather.start()

        XCTAssertFalse(breather.isActive, "会话级持有期间 breather 不得进入活跃态")
        XCTAssertEqual(session.categories, [], "不得改写会话级 owner 的 category")
        XCTAssertEqual(session.activations, 0)
        XCTAssertEqual(session.deactivations, 0)
        XCTAssertEqual(
            sink.detail(module: "breather", event: "start_skipped"),
            "reason=conversation_audio_owned",
            "未启动的原因必须可判定——R-02.1 靠这条事件对账"
        )
        XCTAssertNil(sink.detail(module: "breather", event: "started"))
    }

    /// AC2：breather 已在跑时 owner 接管会话（gate ON 首轮 acquire 之前
    /// 起的 breather），此后任何 stop 理由都不得 deactivate 会话级 owner。
    /// realtime 首帧 / fallback / 取消 / 回前台 / 安全上限逐条覆盖——
    /// ESS-587 只修了「首帧才停」的时序，没修「停的时候踩了别人的会话」。
    func testStopNeverDeactivatesSessionOwnedByConversation() throws {
        let reasons = [
            "realtime_playback",  // ESS-587 首帧回调
            "fallback",           // 整文件回退
            "recording_started",  // 下一轮按压
            "foreground",         // 回前台（WristAgentWatchApp）
            "safety_cap"          // 120s 上限
        ]
        for reason in reasons {
            let sink = LogSink()
            WatchLog.setObserver { module, event, detail, _ in
                sink.record(module: module, event: event, detail: detail)
            }
            defer { WatchLog.setObserver(nil) }

            var owned = false
            let session = SpySession()
            let breather = BackgroundAudioBreather(session: session)
            breather.isSessionOwnedExternally = { owned }
            breather.start()
            defer { releaseRealSharedSession() }
            try XCTSkipUnless(
                breather.isActive, "audio session unavailable on this simulator"
            )

            // owner 在 breather 活跃期间接管共享会话。
            owned = true
            breather.stop(reason: reason)

            XCTAssertFalse(breather.isActive)
            XCTAssertEqual(
                session.deactivations, 0,
                "stop(reason=\(reason)) 不得 deactivate 会话级 owner 持有的会话"
            )
            XCTAssertEqual(
                sink.detail(module: "breather", event: "stopped"),
                "reason=\(reason) deactivated=false",
                "让开会话必须留下可对账的运行时证据"
            )
        }
    }

    /// AC3：gate OFF / 普通 PTT（无会话级 owner）时 ESS-519 行为逐字不变——
    /// 仍改写为 `.playback`、仍激活、stop 仍 deactivate。
    func testUnownedSessionKeepsOriginalBreatherBehaviour() throws {
        let sink = LogSink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        let session = SpySession()
        let breather = BackgroundAudioBreather(session: session)
        // 默认 isSessionOwnedExternally == { false }，不显式设置即为 PTT 路径。
        breather.start()
        defer { releaseRealSharedSession() }
        try XCTSkipUnless(breather.isActive, "audio session unavailable on this simulator")

        XCTAssertEqual(session.categories, [.playback], "PTT 路径仍按 ESS-519 改写 category")
        XCTAssertEqual(session.activations, 1)

        breather.stop(reason: "real_playback")

        XCTAssertEqual(session.deactivations, 1, "无会话级 owner 时仍必须交还会话")
        XCTAssertEqual(
            sink.detail(module: "breather", event: "stopped"),
            "reason=real_playback deactivated=true"
        )
    }

    /// AC4：生产接线端到端——gate ON 且会话真被 acquire 后，走完整
    /// `submit()` 尾部不得产生 `breather started`；随后 realtime 首帧回调
    /// 的 `stop` 是空操作，会话仍由 owner 持有；显式退出后 breather 恢复
    /// ESS-519 原行为。
    func testAcquiredConversationSuppressesSubmitBreatherWiring() throws {
        try HostedCITestGate.skipIfHostedCI(
            "ensureRealtimeAdapter() → AVAudioEngine SetFormat -10868 in "
                + "testAcquiredConversationSuppressesSubmitBreatherWiring"
        )
        let controller = PushToTalkController()
        controller.voiceStreamingEnabled = { false }
        controller.conversationAudioEnabled = { true }
        // 生产顺序：adapter 先接上 playerNode，acquire 才能安全起播放引擎。
        _ = controller.ensureRealtimeAdapter()
        let audio = try XCTUnwrap(controller.conversationAudioController)
        do {
            try audio.beginConversation(conversationId: "ess603-submit")
        } catch {
            throw XCTSkip("模拟器会话不可用：\(error.localizedDescription)")
        }
        defer { audio.endConversation(reason: .userExit) }
        XCTAssertTrue(
            controller.breather.isSessionOwnedExternally(),
            "acquire 成功后 breather 必须看到会话级 owner"
        )

        let sink = LogSink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        controller.simulateSubmitForTests(recording: Self.stubRecording())

        XCTAssertFalse(controller.breather.isActive)
        XCTAssertNil(
            sink.detail(module: "breather", event: "started"),
            "会话持有期间不得出现 breather started"
        )
        XCTAssertEqual(
            sink.detail(module: "breather", event: "start_skipped"),
            "reason=conversation_audio_owned"
        )

        // ESS-587 的首帧回调此刻是空操作——breather 从未活跃，会话不受影响。
        controller.breather.stop(reason: "realtime_playback")
        XCTAssertTrue(audio.isAcquired, "首帧回调不得拆掉会话级 owner")
        XCTAssertNil(sink.detail(module: "breather", event: "stopped"))
    }

    /// AC5：acquire 失败（`isAcquired == false`）时不得连坐——breather 仍按
    /// ESS-519 启动，保住降级路径的后台存活。判据用 `isAcquired` 而不是
    /// feature gate，正是为了这条。
    func testGateOnButAcquireFailedKeepsBreatherWiring() throws {
        try HostedCITestGate.skipIfHostedCI(
            "ensureRealtimeAdapter() → AVAudioEngine SetFormat -10868 in "
                + "testGateOnButAcquireFailedKeepsBreatherWiring"
        )
        let controller = PushToTalkController()
        controller.voiceStreamingEnabled = { false }
        controller.conversationAudioEnabled = { true }
        _ = controller.ensureRealtimeAdapter()
        // adapter 预热建了控制器但未 acquire —— 等价于 acquire 失败后的状态。
        XCTAssertNotNil(controller.conversationAudioController)
        XCTAssertFalse(controller.conversationAudioController?.isAcquired == true)
        XCTAssertFalse(controller.breather.isSessionOwnedExternally())

        let sink = LogSink()
        WatchLog.setObserver { module, event, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        controller.simulateSubmitForTests(recording: Self.stubRecording())
        defer { controller.breather.stop(reason: "test_cleanup") }

        XCTAssertNil(
            sink.detail(module: "breather", event: "start_skipped").flatMap {
                $0 == "reason=conversation_audio_owned" ? $0 : nil
            },
            "未真正持有会话时不得按会话级路径让开"
        )
        XCTAssertTrue(
            sink.detail(module: "breather", event: "started") != nil
                || sink.detail(module: "breather", event: "start_skipped") != nil,
            "降级路径仍须走 ESS-519 接线"
        )
    }

    private static func stubRecording() -> AudioRecorder.Recording {
        AudioRecorder.Recording(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ess603-\(UUID().uuidString).m4a"),
            data: Data(repeating: 0x33, count: 128),
            durationMs: 1_500
        )
    }
}
