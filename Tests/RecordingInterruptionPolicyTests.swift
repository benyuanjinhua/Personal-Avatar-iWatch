import XCTest
@testable import WristAgentCore

/// ESS-538：录音断流（降腕息屏/会话中断）收尾裁决的单测。
/// 样本锚点：2026-08-07 真机 bridge.log —— asset_ms=316 / wall_clock_ms=5926
/// / bytes=25630 的残片旧路径被提交、整回合失败「没听清，请重说」。
final class RecordingInterruptionPolicyTests: XCTestCase {

    // MARK: - ESS-538 真机样本

    func testRealDeviceFragmentIsDiscarded() {
        // 真机样本：按住 5.9s，第 3s 息屏，容器内只剩 316ms。
        XCTAssertTrue(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: 316, wallClockMs: 5_926, wasInterrupted: true
            ),
            "ESS-538 实测样本必须判为残片丢弃"
        )
    }

    func testTruncationSignatureAloneSufficesWithoutInterruptionMark() {
        // 中断通知不保证投递（真机取证 began 可无 ended）——
        // wall ≫ asset 的截断签名本身就是断流证据。
        XCTAssertTrue(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: 316, wallClockMs: 5_926, wasInterrupted: false
            )
        )
    }

    // MARK: - 不误伤正常路径

    func testGenuineShortPressKeepsTooShortUx() {
        // 真实短按：wall ≈ asset，无截断无中断——不归本策略管，
        // 仍走 controller 的 ERR_AUDIO_TOO_SHORT「按住时间太短」提示。
        XCTAssertFalse(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: 250, wallClockMs: 300, wasInterrupted: false
            )
        )
    }

    func testCompleteUtteranceBeforeScreenOffIsSubmitted() {
        // 说完 4s 才息屏、又按了 3s 才松手：音频完整可用，照常提交
        // （本 issue 验收的 fallback 语义——已录片段安全收尾）。
        XCTAssertFalse(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: 4_000, wallClockMs: 7_000, wasInterrupted: true
            )
        )
    }

    func testUsableAudioNeverDiscardedEvenWhenTruncated() {
        // 截断签名命中但音频 ≥ 下限：残片不残，放行提交。
        XCTAssertFalse(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: 2_000, wallClockMs: 6_000, wasInterrupted: true
            )
        )
    }

    func testUninterruptedNormalRecordingPasses() {
        XCTAssertFalse(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: 4_318, wallClockMs: 4_500, wasInterrupted: false
            )
        )
    }

    // MARK: - 边界

    func testDiscardFloorBoundary() {
        // 下限本身放行（≥ 1000ms 的音频有可用信息量）。
        XCTAssertFalse(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: RecordingInterruptionPolicy.interruptedDiscardFloorMs,
                wallClockMs: 6_000, wasInterrupted: true
            )
        )
        XCTAssertTrue(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: RecordingInterruptionPolicy.interruptedDiscardFloorMs - 1,
                wallClockMs: 6_000, wasInterrupted: true
            )
        )
    }

    func testTruncationGapBoundary() {
        // 差值恰好 1.5s 且 asset ≤ wall/2 → 截断；差 1499ms → 不截断。
        XCTAssertTrue(RecordingInterruptionPolicy.isTruncated(assetMs: 1_000, wallClockMs: 2_500))
        XCTAssertFalse(RecordingInterruptionPolicy.isTruncated(assetMs: 1_001, wallClockMs: 2_500))
    }

    func testTruncationHalfBoundary() {
        // asset 恰好为 wall 一半 → 截断；超过一半 → 不截断（说完晚松手）。
        XCTAssertTrue(RecordingInterruptionPolicy.isTruncated(assetMs: 2_000, wallClockMs: 4_000))
        XCTAssertFalse(RecordingInterruptionPolicy.isTruncated(assetMs: 2_001, wallClockMs: 4_000))
    }

    func testNilAssetFallsBackToWallClock() {
        // asset 读不出：用 wall-clock 估可用性；无法判截断，只有明确
        // 观测到断流且时长本身低于下限才丢弃（保守，不误伤）。
        XCTAssertFalse(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: nil, wallClockMs: 5_000, wasInterrupted: true
            )
        )
        XCTAssertTrue(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: nil, wallClockMs: 500, wasInterrupted: true
            )
        )
        XCTAssertFalse(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: nil, wallClockMs: 500, wasInterrupted: false
            )
        )
    }

    func testInterruptionMarkWithSubFloorAssetIsDiscarded() {
        // 观测到断流（息屏标记）且容器音频低于下限，即使截断签名不命中
        // （如中断恢复后尾部又录到一点）也按残片丢弃。
        XCTAssertTrue(
            RecordingInterruptionPolicy.shouldDiscardAsFragment(
                assetMs: 800, wallClockMs: 2_000, wasInterrupted: true
            )
        )
    }
}
