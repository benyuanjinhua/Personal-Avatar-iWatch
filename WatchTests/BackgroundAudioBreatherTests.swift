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
///
/// ESS-603 追加的**两套契约**（gate 决定哪一套成立，两套都必须被覆盖）：
/// - **gate OFF / 普通 PTT**（无会话级 owner）：提交后 breather 必须启动，
///   stop 时必须真的 `setActive(false)`——ESS-519 原契约逐字不变。
/// - **gate ON（`ConversationAudioController.isAcquired`）**：提交后
///   breather **不得**启动（落 `start_skipped reason=conversation_session_owned`），
///   且任何 stop 路径（含 realtime 首帧回调）**不得**去激活会话级 owner
///   （`stopped ... deactivated=false`，owner 侧 deactivations 恒为 0）。
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

        func count(module: String, event: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return entries.filter { $0.module == module && $0.event == event }.count
        }
    }

    /// ESS-603：会话级 owner 的确定性替身——CI 无音频硬件，`deactivations`
    /// 必须可数，不能靠日志 scraping 判定「有没有替 owner 退会话」。
    private final class FakeSession: ConversationAudioSessionDriving {
        private(set) var isActive = false
        private(set) var activations = 0
        private(set) var deactivations = 0

        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            policy: AVAudioSession.RouteSharingPolicy,
            options: AVAudioSession.CategoryOptions
        ) throws {}

        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            guard active != isActive else { return }
            isActive = active
            if active { activations += 1 } else { deactivations += 1 }
        }
    }

    private final class FakeEngine: ConversationAudioEngineControlling {
        private(set) var isRunning = false
        func prepare() {}
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
    }

    private func makeRecording() -> AudioRecorder.Recording {
        AudioRecorder.Recording(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ess603-\(UUID().uuidString).m4a"),
            data: Data(repeating: 0x33, count: 128),
            durationMs: 1_500
        )
    }

    /// gate ON 的生产接线：注入 fake 会话/引擎的控制器，并真正进入
    /// conversation（`isAcquired == true`），随后一切按生产路径走。
    private func makeControllerHoldingConversation() throws
        -> (PushToTalkController, FakeSession)
    {
        let controller = PushToTalkController()
        let session = FakeSession()
        let engine = FakeEngine()
        controller.makeConversationAudioController = {
            ConversationAudioController(
                session: session, captureControl: engine, playbackControl: engine
            )
        }
        controller.voiceStreamingEnabled = { true }
        controller.conversationAudioEnabled = { true }
        let audio = controller.ensureConversationAudioController()
        try audio.beginConversation(conversationId: "ess603-\(UUID().uuidString)")
        XCTAssertTrue(audio.isAcquired, "gate ON 前置：会话级 owner 必须已持有")
        XCTAssertEqual(session.deactivations, 0)
        return (controller, session)
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
        WatchLog.setObserver { module, event, _, detail, _ in
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
            "safety-cap runtime evidence must retain the concrete stop reason；"
                + "无 owner 时必须真的去激活（ESS-603 gate OFF 契约）"
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

    // MARK: - 契约 A：gate OFF / 普通 PTT（无会话级 owner，ESS-519 原样）

    /// ESS-604：本用例的断言目标只有一件事——`submit()` 必须调到
    /// `breather.start()`，且**不得**走 ESS-603 的 owner 跳过分支。
    ///
    /// 「是否真的激活成功」不属于本用例：它取决于宿主 App 运行态。GitHub
    /// hosted runner 上 xctest 宿主是 `.inactive`，`start()` 按 ESS-519
    /// 设计早退并落 `start_skipped reason=app_not_active`（run 31301694820
    /// 的 L1 证据）。硬断言 `isActive` 把这个环境差异记成了产品缺陷——
    /// main 自 `21b5f07d`（PR #253）起 CI 连红即由此而来，同套件的兄弟用例
    /// 一律用 `XCTSkipUnless` 让开，唯独这条没有。
    ///
    /// 接线保护不削弱：submit 若不再调 breather，`started` 与
    /// `start_skipped` 都不会出现，用例照样失败；owner 误判同样被
    /// `conversation_session_owned` 断言挡住。激活成功的环境（本地 mac /
    /// 真机模拟器）仍走完整的 started → stop → `deactivated=true` 断言链。
    func testSubmitStartsBreatherAfterTransportDispatch() throws {
        let controller = PushToTalkController()
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        controller.voiceStreamingEnabled = { false }
        // ESS-601: gate-OFF 测试必须显式关闭 conversation audio 路径。
        // ConversationAudioGate.defaultEnabled = true，不关闭时
        // PushToTalkController.init 会走 conversation-scoped 适配器，
        // 干扰 breather 的 gate-OFF 启动路径。
        controller.conversationAudioEnabled = { false }

        controller.simulateSubmitForTests(recording: makeRecording())

        let started = sink.detail(module: "breather", event: "started")
        let skipped = sink.detail(module: "breather", event: "start_skipped")
        XCTAssertTrue(
            started != nil || skipped != nil,
            "submit must invoke the production breather wiring"
        )
        XCTAssertNotEqual(
            skipped, "reason=conversation_session_owned",
            "无 owner 时不得走 ESS-603 的跳过分支"
        )

        guard let started else {
            XCTAssertEqual(
                skipped, "reason=app_not_active state=inactive",
                "唯一可接受的未启动原因是宿主 App 非 active（ESS-519 早退）"
            )
            XCTAssertFalse(controller.breather.isActive)
            return
        }

        XCTAssertTrue(
            controller.breather.isActive,
            "submit must invoke the production breather wiring"
        )
        XCTAssertEqual(
            started, "sample_rate=8000 duration_s=2 loops=-1",
            "submit must produce runtime evidence from the real breather"
        )
        controller.breather.stop(reason: "test_cleanup")
        XCTAssertEqual(
            sink.detail(module: "breather", event: "stopped"),
            "reason=test_cleanup deactivated=true",
            "gate OFF：会话是 breather 自己激活的，stop 必须真的去激活"
        )
    }

    /// gate OFF 的 realtime 首帧路径（ESS-587 接线）：owner 不在场时，
    /// 首帧 stop 仍必须去激活，`.playback` 会话不能留给真实播放。
    func testRealtimeFirstFrameStopDeactivatesWhenNoOwner() throws {
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        let breather = BackgroundAudioBreather()
        breather.start()
        try XCTSkipUnless(breather.isActive, "audio session unavailable on this simulator")

        breather.stop(reason: "realtime_playback")

        XCTAssertFalse(breather.isActive)
        XCTAssertEqual(
            sink.detail(module: "breather", event: "stopped"),
            "reason=realtime_playback deactivated=true"
        )
    }

    // MARK: - 契约 B：gate ON（ConversationAudioController 持有会话）

    /// AC1：`isAcquired == true` 时提交不得启动 breather——启动即改写
    /// owner 的 `.playAndRecord` 类别，回复音频当场失声。
    func testSubmitDoesNotStartBreatherWhileConversationOwnsSession() throws {
        let sink = LogSink()
        let (controller, session) = try makeControllerHoldingConversation()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }

        controller.simulateSubmitForTests(recording: makeRecording())

        XCTAssertFalse(
            controller.breather.isActive,
            "会话级持有期间 breather 不得启动（ESS-603 AC1）"
        )
        XCTAssertEqual(
            sink.count(module: "breather", event: "started"), 0,
            "持有期间不得出现 breather started"
        )
        XCTAssertEqual(
            sink.detail(module: "breather", event: "start_skipped"),
            "reason=conversation_session_owned",
            "跳过必须留下可复核的运行时证据"
        )
        XCTAssertEqual(session.deactivations, 0, "owner 的会话不得被去激活")
    }

    /// AC2：realtime 首帧回调（`adapter.onRealtimePlaybackStarted` →
    /// `breather.stop(reason: "realtime_playback")`）在 owner 在场时
    /// 必须是彻底的空操作——这正是真机上「首帧到了却没声」的那一步。
    func testRealtimeFirstFrameStopDoesNotDeactivateConversationOwner() throws {
        let sink = LogSink()
        let (controller, session) = try makeControllerHoldingConversation()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }

        controller.simulateSubmitForTests(recording: makeRecording())
        controller.breather.stop(reason: "realtime_playback")
        controller.breather.stop(reason: "real_playback")

        XCTAssertEqual(session.deactivations, 0, "首帧/真实播放回调都不得替 owner 退会话")
        XCTAssertEqual(
            sink.count(module: "breather", event: "stopped"), 0,
            "从未启动 → 无 stopped 事件；owner 的会话完全未被触碰"
        )
    }

    /// 竞态兜底：breather 先启动、owner 随后接管（先普通 PTT 再进会话）。
    /// 此时仍要停掉静音循环，但 `setActive(false)` 归 owner 所有，
    /// 证据落在 `stopped ... deactivated=false`。
    func testStopDoesNotDeactivateWhenOwnerAppearsAfterStart() throws {
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        let breather = BackgroundAudioBreather()
        breather.start()
        try XCTSkipUnless(breather.isActive, "audio session unavailable on this simulator")

        // owner 在 breather 活跃之后接管共享会话。
        breather.isSessionOwnedExternally = { true }
        breather.stop(reason: "realtime_playback")

        XCTAssertFalse(breather.isActive, "静音循环仍必须停止")
        XCTAssertEqual(
            sink.detail(module: "breather", event: "stopped"),
            "reason=realtime_playback deactivated=false",
            "owner 在场时只停播放器、不去激活会话"
        )
    }

    /// gate 开关是 breather 行为的唯一分水岭：同一个实例，谓词翻转即换契约。
    func testOwnershipPredicateIsTheOnlyGate() {
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.record(module: module, event: event, detail: detail)
        }
        let breather = BackgroundAudioBreather()
        breather.isSessionOwnedExternally = { true }

        breather.start()

        XCTAssertFalse(breather.isActive)
        XCTAssertEqual(
            sink.detail(module: "breather", event: "start_skipped"),
            "reason=conversation_session_owned"
        )
        XCTAssertEqual(sink.count(module: "breather", event: "started"), 0)
    }
}
