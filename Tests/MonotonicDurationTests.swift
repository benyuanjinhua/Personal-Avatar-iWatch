import XCTest
@testable import WristAgentCore

/// ESS-1028：真机 5 次 SIGTRAP 的算法边界。
///
/// 事故：`ConversationAudioController.elapsedMs` 先转后除
/// （`Int(纳秒差) / 1_000_000`），arm64_32 上 `Int` 为 32 位，纳秒差超过
/// `Int32.max` 即在 `Int(_:)` 处陷入——阈值 2.147 秒。
///
/// 这些用例跑在 64 位宿主上，**复现不了**那次收窄陷阱；它们钉的是
/// `MonotonicDuration` 的数值契约：越过 `Int32.max` 纳秒后结果仍正确、
/// 且能无损装进 32 位。真机不崩另由 R-02.5 关卡二的真机日志佐证。
final class MonotonicDurationTests: XCTestCase {
    /// arm64_32 上 `Int(_:)` 收窄陷入的纳秒阈值。
    private let int32MaxNanos = UInt64(Int32.max)  // 2_147_483_647 ns ≈ 2.147s

    func testBelowTrapThreshold() {
        XCTAssertEqual(MonotonicDuration.elapsedMs(fromUptimeNanos: 0, toUptimeNanos: 2_000_000_000), 2_000)
    }

    /// 崩溃阈值正上方：旧写法在真机上正是从这里开始陷入。
    func testJustAboveTrapThreshold() {
        let now = int32MaxNanos + 1
        XCTAssertGreaterThan(now, int32MaxNanos)
        let ms = MonotonicDuration.elapsedMs(fromUptimeNanos: 0, toUptimeNanos: now)
        XCTAssertEqual(ms, 2_147)
        // 先除后转的核心保证：毫秒结果能无损装进 32 位 Int。
        XCTAssertEqual(Int32(exactly: ms), 2_147)
    }

    /// 一场几十秒的正常会话——真机崩溃现场的实际量级（`held_ms`）。
    func testTypicalConversationHold() {
        let ms = MonotonicDuration.elapsedMs(fromUptimeNanos: 1_000_000_000, toUptimeNanos: 91_000_000_000)
        XCTAssertEqual(ms, 90_000)
        XCTAssertEqual(Int32(exactly: ms), 90_000)
    }

    /// 一整天：纳秒差远超 `Int32.max`，毫秒仍在 32 位内，不许截断。
    func testOneDayStillFitsIn32Bit() {
        let oneDayNanos: UInt64 = 86_400 * 1_000_000_000
        let ms = MonotonicDuration.elapsedMs(fromUptimeNanos: 0, toUptimeNanos: oneDayNanos)
        XCTAssertEqual(ms, 86_400_000)
        XCTAssertEqual(Int32(exactly: ms), 86_400_000)
        XCTAssertEqual(MonotonicDuration.elapsedMsClamped(fromUptimeNanos: 0, toUptimeNanos: oneDayNanos), 86_400_000)
    }

    func testZeroAndReversedSpanAreZero() {
        XCTAssertEqual(MonotonicDuration.elapsedMs(fromUptimeNanos: 42, toUptimeNanos: 42), 0)
        // now < start 只可能来自传错；必须返回 0，不能回绕成天文数字。
        XCTAssertEqual(MonotonicDuration.elapsedMs(fromUptimeNanos: 5_000_000_000, toUptimeNanos: 1), 0)
        XCTAssertEqual(MonotonicDuration.elapsedMsClamped(fromUptimeNanos: 5_000_000_000, toUptimeNanos: 1), 0)
    }

    func testSubMillisecondTruncatesToZero() {
        XCTAssertEqual(MonotonicDuration.elapsedMs(fromUptimeNanos: 0, toUptimeNanos: 999_999), 0)
    }

    /// 最大跨度也不许陷入：`Int` 装得下就原值返回，装不下截到 `Int.max`。
    /// 期望值按平台位宽写死——64 位宿主 18_446_744_073_709 毫秒放得进
    /// `Int64`，arm64_32 上放不进 `Int32` 故截断。旧写法在两种位宽下都是
    /// 陷入（64 位是 `Int(UInt64.max)` 溢出）。
    func testClampedNeverTraps() {
        let ms = MonotonicDuration.elapsedMs(fromUptimeNanos: 0, toUptimeNanos: UInt64.max)
        XCTAssertEqual(ms, 18_446_744_073_709)
        let clamped = MonotonicDuration.elapsedMsClamped(fromUptimeNanos: 0, toUptimeNanos: UInt64.max)
        XCTAssertEqual(clamped, ms > UInt64(Int.max) ? Int.max : Int(ms))
        XCTAssertGreaterThan(clamped, 0)
    }
}
