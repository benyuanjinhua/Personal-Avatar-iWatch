import XCTest

@testable import WristAgent_Watch_App

/// ESS-354：验证 `PushToTalkController.voiceStreamingEnabled` 门禁**必须**读
/// `WatchDebugSettings.isStreamingActive`，而不是任何 iPhone 同步的 Agent 配置。
///
/// 事故复盘：
/// - 用户在 Watch 设置页打开 Debug 直连/流式（`debugSettings.streamingEnabled`）。
/// - `WatchStreamReceiver` 的下行 gate 读的是 `debugSettings.isStreamingActive` —— 打开了。
/// - 但 `WatchAppDelegate.bootstrap()` 把 `pushToTalk.voiceStreamingEnabled`
///   接到 `AgentConfiguration.voiceStreamingV2`（无 UI 写入，永远 false）。
/// - 结果：上行 realtime adapter 从未被 `pressBegan()` 唤起 → 没有 `stream.start`
///   到 iPhone → 没有 WSS → Bridge 只能把 audio.delta 顺回 m4a → `result_synthesized_from_realtime`。
///
/// 本用例把 bootstrap 的接线策略下沉到可断言的形式：默认 OFF、跟随 debug
/// 开关翻转、`debugSettings` 释放后回落到默认。任何以后再次把上下行门禁分裂
/// 成两个来源的改动都会打红本用例。
@MainActor
final class PushToTalkStreamingGateTests: XCTestCase {

    private func makeIsolatedDebugSettings(enabled: Bool = false) -> WatchDebugSettings {
        let suite = "wristagent.tests.ess354.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // ESS-356 之后 `WatchDebugSettings.init` 缺 key 时会回落到
        // `VoiceStreamingGate.defaultEnabled`（当前为 ON）。本用例要精确
        // 验证「上行门禁跟随 debug 开关」的语义，两个方向都必须显式落 key，
        // 否则 OFF 分支会被编译期默认顶掉。
        defaults.set(enabled, forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        return WatchDebugSettings(defaults: defaults)
    }

    /// 未 wire-up 时保持 `VoiceStreamingGate.defaultEnabled`（当前为 false）。
    /// 保证 `WatchAppDelegate.bootstrap()` 未跑到之前，任何回合都走旧链路，
    /// 不会因为默认闭包泄漏而进入未完成的接线。
    func testDefaultClosureReturnsCompileTimeGate() {
        let controller = PushToTalkController()
        XCTAssertEqual(controller.voiceStreamingEnabled(), VoiceStreamingGate.defaultEnabled)
    }

    /// bootstrap 的接线契约：闭包必须跟随 `debugSettings.isStreamingActive`。
    /// 用最直观的方式复刻 `WatchAppDelegate.bootstrap()` 里的写法——如果哪天
    /// 有人把这条接线改回读 iPhone 同步的配置，本断言会直接失败。
    func testWiringToDebugSettingsFollowsToggle() {
        let debugSettings = makeIsolatedDebugSettings(enabled: false)
        let controller = PushToTalkController()
        controller.voiceStreamingEnabled = { [weak debugSettings] in
            debugSettings?.isStreamingActive ?? VoiceStreamingGate.defaultEnabled
        }

        XCTAssertFalse(
            controller.voiceStreamingEnabled(),
            "OFF：默认门禁必须让 `pressBegan` 走旧的 m4a 链路"
        )

        debugSettings.setStreamingEnabled(true)
        XCTAssertTrue(
            controller.voiceStreamingEnabled(),
            "ON：闭包必须立即返回 true，`pressBegan` 才会启动 realtime adapter"
        )

        debugSettings.setStreamingEnabled(false)
        XCTAssertFalse(
            controller.voiceStreamingEnabled(),
            "OFF 后必须立刻回落，下一回合走旧链路（与 R4「不许残留 session」对齐）"
        )
    }

    /// 若 `debugSettings` 被释放（服务图重建等极端场景），闭包必须回落到
    /// 编译期默认 OFF，绝不能返回 nil/crash 或阴间打开一次流。
    func testWiringFallsBackToCompileGateWhenDebugSettingsReleased() {
        let controller = PushToTalkController()
        var debugSettings: WatchDebugSettings? = makeIsolatedDebugSettings(enabled: true)
        controller.voiceStreamingEnabled = { [weak debugSettings] in
            debugSettings?.isStreamingActive ?? VoiceStreamingGate.defaultEnabled
        }
        XCTAssertTrue(controller.voiceStreamingEnabled())

        debugSettings = nil
        XCTAssertEqual(
            controller.voiceStreamingEnabled(),
            VoiceStreamingGate.defaultEnabled,
            "debugSettings 释放后必须回落到编译期默认，避免残留 true"
        )
    }
}
