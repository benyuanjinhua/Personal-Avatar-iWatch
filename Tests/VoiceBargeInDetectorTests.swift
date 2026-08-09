import XCTest
@testable import WristAgentCore

/// ESS-650（F2-5）：语音打断判据的边界测试。
///
/// 三条防误触参数各自能被单独推翻，所以每条都有一组「刚好不过 / 刚好过」的
/// 对照——只测中间值等于没测。时间全部由入参给定，零睡眠。
final class VoiceBargeInDetectorTests: XCTestCase {

    // MARK: - 造帧

    private static let sampleRate = 16_000
    /// 一帧 100ms = 1600 samples = 3200 bytes（与 PCMFrameRecorder 默认帧长一致）。
    private static let frameMs: Int64 = 100

    /// 造一帧给定 RMS 的 PCM16。用常量幅度方波，RMS 恰等于幅度。
    private static func frame(rms: Double, ms: Int64 = frameMs) -> Data {
        let sampleCount = Int(ms) * sampleRate / 1_000
        let amplitude = Int16(max(0, min(Double(Int16.max), rms * Double(Int16.max))))
        var data = Data(capacity: sampleCount * 2)
        for _ in 0..<sampleCount {
            withUnsafeBytes(of: amplitude.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static let loud = frame(rms: 0.20)     // 远超阈值：真人开口
    private static let quiet = frame(rms: 0.001)   // 远低于阈值：静音

    // MARK: - 阈值本身

    /// +6dB 不是写死的 0.036，而是从常态 VAD 阈值推导——常态阈值被调时
    /// 打断阈值必须跟着走，否则会静默漂移成「和常态一样灵敏」。
    func testThresholdIsSixDBAboveConversationVAD() {
        let normal = LocalVADConfiguration().speechRMS
        let bargeIn = VoiceBargeInConfiguration().speechRMS
        XCTAssertEqual(20 * log10(bargeIn / normal), 6.0, accuracy: 0.01)
    }

    func testDefaultsMatchAcceptanceCriteria() {
        let config = VoiceBargeInConfiguration()
        XCTAssertEqual(config.playbackGuardMs, 400, "F2-5 起播静默期")
        XCTAssertEqual(config.speechStartMs, 300, "F2-5 连续说话判据")
    }

    // MARK: - F2-5 ①：400ms 起播守卫

    /// 守卫窗内的大能量 = 自身回声，不触发打断，但必须被计数。
    func testGuardWindowCountsSelfEchoAndDoesNotTrigger() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        // 0–100 / 100–200 / 200–300 / 300–400：四帧整帧落在 400ms 窗内。
        for start in stride(from: Int64(0), to: 400, by: 100) {
            XCTAssertTrue(detector.processPCM16(Self.loud, frameStartedAtMs: start).isEmpty)
        }
        XCTAssertEqual(detector.roundSelfEchoFrameCount, 4)
        XCTAssertEqual(detector.selfEchoFrameCount, 4, "跨轮累计同步增长")
        XCTAssertEqual(detector.roundFrameCount, 4)
        XCTAssertGreaterThan(detector.roundPeakGuardDB, -120.0, "有回声就要报得出能量")
    }

    /// 守卫窗内的**静音**不算回声——F2-5 的「零」指的是零超阈帧，
    /// 不是零帧。这条区分「AEC 干净」与「压根没采集」。
    func testGuardWindowSilenceIsNotCountedAsSelfEcho() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        for start in stride(from: Int64(0), to: 400, by: 100) {
            _ = detector.processPCM16(Self.quiet, frameStartedAtMs: start)
        }
        XCTAssertEqual(detector.roundSelfEchoFrameCount, 0)
        XCTAssertEqual(detector.roundFrameCount, 4, "帧确实喂进来了")
        XCTAssertEqual(detector.roundPeakGuardDB, -120.0, accuracy: 0.001)
    }

    /// 跨守卫边界的那一帧归窗外处理——否则 400ms 实际会被拉长一整帧。
    func testFrameCrossingGuardBoundaryIsTreatedAsOutside() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        // 350–450：结束时刻 450 > 400，算窗外。
        let events = detector.processPCM16(Self.loud, frameStartedAtMs: 350)
        XCTAssertEqual(events, [.energySpike(atMs: 350)])
        XCTAssertEqual(detector.roundSelfEchoFrameCount, 0)
    }

    // MARK: - F2-5 ②：+6dB 能量阈值

    /// 常态 VAD 会判成语音（0.018 以上）、但没到 +6dB 的能量，不得触发打断。
    /// 这一条正是「AEC 残留回声不该被当成用户开口」的可执行表达。
    func testEnergyBetweenNormalVADAndBargeInThresholdNeverTriggers() {
        let between = LocalVADConfiguration().speechRMS * 1.5  // 0.027：过常态、不过 +6dB
        XCTAssertGreaterThan(between, LocalVADConfiguration().speechRMS)
        XCTAssertLessThan(between, VoiceBargeInConfiguration().speechRMS)

        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        let payload = Self.frame(rms: between)
        for start in stride(from: Int64(400), to: 3_000, by: 100) {
            XCTAssertTrue(
                detector.processPCM16(payload, frameStartedAtMs: start).isEmpty,
                "\(start)ms 处不该触发：能量没到 +6dB"
            )
        }
        XCTAssertEqual(detector.roundSelfEchoFrameCount, 0)
    }

    // MARK: - F2-5 ③：300ms 连续判据

    /// 200ms（两帧）不够；第三帧凑满 300ms 才触发，且两个时刻分别是
    /// 起说（400）与命中（700），detect_ms 因此是 300 而不是 0。
    func testRequiresThreeHundredMillisecondsOfContinuousSpeech() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        XCTAssertEqual(
            detector.processPCM16(Self.loud, frameStartedAtMs: 400),
            [.energySpike(atMs: 400)]
        )
        XCTAssertTrue(detector.processPCM16(Self.loud, frameStartedAtMs: 500).isEmpty, "200ms 不够")
        XCTAssertEqual(
            detector.processPCM16(Self.loud, frameStartedAtMs: 600),
            [.bargeInDetected(startedAtMs: 400, detectedAtMs: 700)],
            "300ms 达成：起说 400、命中 700，detect_ms=300"
        )
    }

    /// 断一帧就重新计时——单帧尖峰与断续噪声过不了连续判据。
    func testSilentFrameResetsContinuityCounter() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        _ = detector.processPCM16(Self.loud, frameStartedAtMs: 400)
        _ = detector.processPCM16(Self.loud, frameStartedAtMs: 500)
        _ = detector.processPCM16(Self.quiet, frameStartedAtMs: 600)   // 断了
        _ = detector.processPCM16(Self.loud, frameStartedAtMs: 700)
        XCTAssertTrue(
            detector.processPCM16(Self.loud, frameStartedAtMs: 800).isEmpty,
            "重新计时后只累计了 200ms"
        )
        XCTAssertEqual(
            detector.processPCM16(Self.loud, frameStartedAtMs: 900),
            [.bargeInDetected(startedAtMs: 700, detectedAtMs: 1_000)],
            "起说时刻应为断点之后的 700"
        )
    }

    // MARK: - 吸收态

    /// 一个 speaking 相位内只触发一次，避免一次插话被记成多次打断。
    func testFiresAtMostOncePerPlayback() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        var triggers = 0
        for start in stride(from: Int64(400), to: 3_000, by: 100) {
            triggers += detector.processPCM16(Self.loud, frameStartedAtMs: start)
                .filter { if case .bargeInDetected = $0 { return true } else { return false } }
                .count
        }
        XCTAssertEqual(triggers, 1)
    }

    /// 新一轮起播重新武装守卫窗；`selfEchoFrameCount` 由调用方按轮读取后
    /// 累加，detector 本身每轮新建（见 SessionController）。
    func testPlaybackStartedRearmsGuardWindow() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        _ = detector.processPCM16(Self.loud, frameStartedAtMs: 400)
        _ = detector.processPCM16(Self.loud, frameStartedAtMs: 500)
        _ = detector.processPCM16(Self.loud, frameStartedAtMs: 600)  // 触发

        detector.playbackStarted(atMs: 10_000)
        XCTAssertTrue(
            detector.processPCM16(Self.loud, frameStartedAtMs: 10_100).isEmpty,
            "新一轮的守卫窗必须重新生效"
        )
        XCTAssertEqual(detector.roundSelfEchoFrameCount, 1, "新一轮的单轮计数从 0 起算")
        XCTAssertEqual(detector.selfEchoFrameCount, 1, "跨轮累计同上（上一轮守卫窗是干净的）")
    }

    // MARK: - 退化输入

    func testEmptyAndSubFrameInputAreIgnored() {
        var detector = VoiceBargeInDetector()
        detector.playbackStarted(atMs: 0)
        XCTAssertTrue(detector.processPCM16(Data(), frameStartedAtMs: 500).isEmpty)
        // 8 字节 = 4 samples < 1ms，时长算成 0 → 丢弃，不得除零或误计数。
        XCTAssertTrue(detector.processPCM16(Data(count: 8), frameStartedAtMs: 500).isEmpty)
        XCTAssertEqual(detector.roundFrameCount, 0)
    }
}
