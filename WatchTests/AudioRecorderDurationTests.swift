import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-219 复现测试：真机 2026-08-03 16:30/16:35 两次出现
/// `record_finished duration_ms=51,129,344`（≈14.2h）、字节量却只有 4.3~4.8 万——
/// 与同窗内正常样本（`duration_ms=4318 bytes=42887`）字节量相当，时长差 4 个数量级，
/// 形态贴近把 `deviceCurrentTime`/系统 uptime 当成时长差。
///
/// 修复：`AudioRecorder.finish()` 不再用 `AVAudioRecorder.currentTime`，
/// 改用 `DispatchTime.now()` 与 `start()` 里落下的单调时钟戳计算差值，
/// 并对超出 `maxDuration` 的量级落 `record_duration_out_of_range` 并截断。
@MainActor
final class AudioRecorderDurationTests: XCTestCase {

    /// AC #2：`duration_ms` 超过录音上限时视为计算错误并留痕。
    /// 直接喂事故里观测到的 51,129,344ms 到 sanitize 函数——必须截断到 60,000ms，
    /// 并落 `record_duration_out_of_range` 事件（可 grep 的取证锚点）。
    func testSanitizeClampsOverflowAndLogs() {
        let events = EventLog()
        WatchLog.setObserver { module, event, detail, code in
            events.record(module: module, event: event, detail: detail, code: code)
        }
        defer { WatchLog.setObserver(nil) }

        let observed = 51_129_344 // ESS-217 现场取证值
        let clamped = AudioRecorder.sanitizeDurationMs(rawMs: observed)

        XCTAssertEqual(clamped, 60_000, "raw_ms=\(observed) 必须截断到 max=60,000ms")
        XCTAssertEqual(
            events.count(module: "recorder", event: "record_duration_out_of_range", detailContains: "raw_ms=\(observed)"),
            1,
            "溢出必须留 record_duration_out_of_range 取证事件，含原始 raw_ms"
        )
    }

    /// AC #1（正常路径）：任意一次不超过 60s 的原始值，sanitize 后原样透出，
    /// 不越出上限、不生成误报事件。
    func testSanitizePassesNormalDurations() {
        let events = EventLog()
        WatchLog.setObserver { module, event, detail, code in
            events.record(module: module, event: event, detail: detail, code: code)
        }
        defer { WatchLog.setObserver(nil) }

        for raw in [0, 31, 4318, 5566, 59_999, 60_000] {
            let clamped = AudioRecorder.sanitizeDurationMs(rawMs: raw)
            XCTAssertEqual(clamped, raw, "\(raw)ms 在上限内不应被改写")
        }
        XCTAssertEqual(
            events.count(module: "recorder", event: "record_duration_out_of_range"),
            0,
            "上限内不应触发溢出事件"
        )
    }

    /// AC #1（端到端）：走真实的 `start()`/`finish()` 释放路径——短暂等待后收尾，
    /// `record_finished` 日志与 `Recording.durationMs` 都必须是量级自洽的小值（<< 60s）。
    /// headless 模拟器起录失败时走 cancel 分支，仍然验证 duration=0（不再从 currentTime 取值）。
    func testFinishedDurationIsBoundedAndSelfConsistent() async throws {
        try await Task.sleep(for: .seconds(4)) // 让宿主欢迎语播完，避免抢会话
        let events = EventLog()
        WatchLog.setObserver { module, event, detail, code in
            events.record(module: module, event: event, detail: detail, code: code)
        }
        defer { WatchLog.setObserver(nil) }

        let recorder = AudioRecorder()
        var captured = false
        do {
            try await recorder.start()
            captured = true
        } catch RecorderError.permissionDenied {
            throw XCTSkip("宿主未授权麦克风：先 xcrun simctl privacy <sim> grant microphone 再跑")
        } catch RecorderError.cannotCreateRecorder {
            // 模拟器 headless 限制：起录失败。start() 里 recordingStartUptime 未落，
            // 走 cancel 分支验证 sanitize 逻辑不至于把未初始化状态放大成天文数字。
        }

        if captured {
            try await Task.sleep(for: .milliseconds(500))
            let recording = try recorder.finish()
            try? FileManager.default.removeItem(at: recording.fileURL)

            XCTAssertGreaterThan(recording.durationMs, 0, "非空录音的时长必须 > 0")
            XCTAssertLessThanOrEqual(
                recording.durationMs, 60_000,
                "duration_ms 绝不允许超过 max=60s（ESS-219 事故复现值 51,129,344ms 必须永久绝迹）"
            )
            XCTAssertLessThan(
                recording.durationMs, 5_000,
                "500ms 等待后 duration_ms 应 << 5s；数量级失真即视为回归到 currentTime 混淆缺陷"
            )
        } else {
            recorder.cancel()
        }

        XCTAssertEqual(
            events.count(module: "recorder", event: "record_duration_out_of_range"),
            0,
            "正常路径不应触发溢出事件；触发意味着单调时钟自身失控（不是本单可接受的失败）"
        )
    }

    // MARK: - ESS-225 AC #5：duration_ms 与 bytes 不自洽的防御门

    /// 真机 (2026-08-03 16:20~16:40) 观测到的三类样本一并喂给 `durationBytesMismatch`：
    /// - 正常段（43KB / 4318ms，47KB / 5566ms，43KB / 4514ms）—— 必须放行
    /// - 溢出段（43KB / 51,129,344ms、47KB / 51,707,905ms）—— 必须触发
    /// - 近零段（24KB / 31ms）—— 必须触发（毕玄 PR #66 复审指出 sanitize 只
    ///   拦上限，不覆盖此反向异常；本门是 PR #66 上的增量）
    func testMismatchGateOnRealDeviceSamples() {
        // 正常样本：不出门
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 4_318, bytes: 42_887))
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 5_566, bytes: 47_872))
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 4_514, bytes: 43_986))

        // 上限异常样本：出门
        let overflow1 = AudioRecorder.durationBytesMismatch(durationMs: 51_129_344, bytes: 43_296)
        XCTAssertNotNil(overflow1, "43KB / 51,129,344ms 必须被判为不自洽")
        XCTAssertTrue(overflow1?.contains("expected_ms≈") == true)

        let overflow2 = AudioRecorder.durationBytesMismatch(durationMs: 51_707_905, bytes: 47_436)
        XCTAssertNotNil(overflow2, "47KB / 51,707,905ms 必须被判为不自洽")

        // 下限异常样本：ESS-225 待确认项——`duration_ms=31 bytes=24588` 与
        // 两条溢出同源（均是 currentTime 未定义），本门确保未来同类漂移可见。
        let nearZero = AudioRecorder.durationBytesMismatch(durationMs: 31, bytes: 24_588)
        XCTAssertNotNil(nearZero, "24KB / 31ms 必须被判为不自洽（PR #66 sanitize 未覆盖）")
    }

    /// 微小容器样本（<4KB）走 too_short 判定，不进本门以避免噪声告警。
    func testMismatchGateSkipsUnderMinimumBytes() {
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 0, bytes: 512))
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 100, bytes: 1_500))
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 999_999, bytes: 100))
    }

    /// 3× 冗余边界：40KB 的 expected_ms = 10_000，允许区间 [3_333, 30_000]。
    /// 靠近但仍在门内不告警；越界一步就告警。
    func testMismatchGateThreeXBoundary() {
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 3_500, bytes: 40_000))
        XCTAssertNil(AudioRecorder.durationBytesMismatch(durationMs: 29_000, bytes: 40_000))
        XCTAssertNotNil(AudioRecorder.durationBytesMismatch(durationMs: 3_000, bytes: 40_000))
        XCTAssertNotNil(AudioRecorder.durationBytesMismatch(durationMs: 31_000, bytes: 40_000))
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(module: String, event: String, detail: String?, code: String?)] = []
        func record(module: String, event: String, detail: String?, code: String?) {
            lock.lock(); defer { lock.unlock() }
            entries.append((module, event, detail, code))
        }
        func count(module: String, event: String, detailContains fragment: String? = nil) -> Int {
            lock.lock(); defer { lock.unlock() }
            return entries.filter {
                $0.module == module && $0.event == event
                    && (fragment == nil || $0.detail?.contains(fragment!) == true)
            }.count
        }
    }
}
