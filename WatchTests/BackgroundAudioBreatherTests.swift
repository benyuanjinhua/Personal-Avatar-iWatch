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
            "reason=safety_cap",
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

    func testSubmitStartsBreatherAfterTransportDispatch() {
        let controller = PushToTalkController()
        var startCount = 0
        controller.voiceStreamingEnabled = { false }
        controller.startBreatherAfterSubmit = { startCount += 1 }
        let recording = AudioRecorder.Recording(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ess587-\(UUID().uuidString).m4a"),
            data: Data(repeating: 0x33, count: 128),
            durationMs: 1_500
        )

        controller.simulateSubmitForTests(recording: recording)

        XCTAssertEqual(startCount, 1, "submit must start the background breather exactly once")
    }
}
