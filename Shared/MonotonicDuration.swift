import Foundation

/// ESS-1028：单调时钟纳秒差 → 毫秒的唯一算法出口。
///
/// 事故背景：`ConversationAudioController.elapsedMs` 写成
/// `Int(now &- start) / 1_000_000`——**先转后除**。watchOS 真机目标架构是
/// arm64_32，`Int` 只有 32 位（`Int.max == 2_147_483_647`），纳秒差一旦
/// 超过 `Int32.max` 就在 `Int(_:)` 收窄处触发 Swift runtime failure
/// （EXC_BREAKPOINT / SIGTRAP）。阈值仅 **2.147 秒**，而该调用点度量的是
/// 整场会话的音频持有时长，播完几条播报必然越界——真机 5 次崩溃同址。
/// `&-` 只保证减法回绕不陷入，救不了后面的窄化。
///
/// 因此本类型全程用 `UInt64` 运算、**先除后转**，并在最后一步按当前平台
/// `Int` 上限收敛，任何位宽下都不会陷入。
///
/// 注意（不要误读测试的强度）：`swift test` 跑在 64 位宿主上，`Int` 是 64 位，
/// **无法复现 arm64_32 的收窄陷阱**。Tests 钉住的是本类型的数值契约与
/// 「不做无保护窄化」的结构，真机不崩仍须真机日志佐证（R-02.1 / R-02.5）。
enum MonotonicDuration {
    /// 纯函数核心：纳秒差 → 毫秒，全程 `UInt64`，不做任何位宽收窄。
    ///
    /// `now < start` 只可能来自调用方传错（`DispatchTime.uptimeNanoseconds`
    /// 单调不减），此时返回 0 而不是回绕出的天文数字。
    static func elapsedMs(fromUptimeNanos start: UInt64, toUptimeNanos now: UInt64) -> UInt64 {
        guard now > start else { return 0 }
        return (now - start) / 1_000_000
    }

    /// 日志/度量用的 `Int` 版本：先除后转，超出平台 `Int` 上限时截到 `Int.max`。
    /// 截断意味着「时长离谱到不可能是真实会话」，落日志比崩进程好。
    static func elapsedMsClamped(fromUptimeNanos start: UInt64, toUptimeNanos now: UInt64) -> Int {
        let ms = elapsedMs(fromUptimeNanos: start, toUptimeNanos: now)
        return ms > UInt64(Int.max) ? Int.max : Int(ms)
    }
}
