import XCTest

@testable import WristAgent_Watch_App

/// ESS-280：设置页流式开关的**回退契约**运行时断言（R1 生效版）。
///
/// 与验收标准的对齐：
/// 1. 默认 OFF —— 首次实例化、无历史 key 的情况下 `isStreamingActive`
///    必须为 false，保证不装机默认走旧链路；
/// 2. 打开开关 → 门禁 API 返回 true，供未来 ESS-279 / R4 wire-up 分支进入流式；
/// 3. 关掉开关 → 门禁 API 立刻返回 false，且**同步**触发已注册的回退回调，
///    以及 `streamingGeneration` 单调递增（在途流式回合据此发现自己已过期）；
/// 4. 每条用例使用独立 UserDefaults suite，避免残留污染。
///
/// 未覆盖但已在运行时验证：`logStateAtLaunch()` 冷启动补报（PM 明确要求）
/// 与 `streaming_toggled ... source=user` 观测事件 —— 两条都只写 os_log +
/// ClientLogStore，不经受测断言能覆盖到的返回路径；由 `Scripts/verify.sh`
/// 上跑的真机模拟器日志（`[settings] streaming_state_at_launch value=<>`
/// / `[settings] streaming_toggled from=<> to=<> source=user`）承担 R-02.1
/// 运行时证据。
@MainActor
final class WatchDebugSettingsTests: XCTestCase {

    private func makeIsolatedDefaults(_ label: String) -> UserDefaults {
        let suite = "wristagent.tests.ess280.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - 默认 OFF

    func testDefaultsToOffWhenNoStoredValue() {
        let settings = WatchDebugSettings(defaults: makeIsolatedDefaults("default_off"))
        XCTAssertFalse(settings.streamingEnabled, "无历史 key 时必须默认 OFF")
        XCTAssertFalse(settings.isStreamingActive, "门禁 API 默认返回 false")
        XCTAssertEqual(settings.streamingGeneration, 0, "无翻转时 generation 保持 0")
    }

    func testRestoresPersistedTrueFromDefaults() {
        let defaults = makeIsolatedDefaults("restore_true")
        defaults.set(true, forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        let settings = WatchDebugSettings(defaults: defaults)
        XCTAssertTrue(settings.streamingEnabled, "开关 ON 状态必须跨进程恢复")
        XCTAssertTrue(settings.isStreamingActive, "恢复后门禁 API 也应 true")
    }

    func testRestoresPersistedFalseFromDefaults() {
        let defaults = makeIsolatedDefaults("restore_false")
        defaults.set(false, forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        let settings = WatchDebugSettings(defaults: defaults)
        XCTAssertFalse(settings.streamingEnabled)
    }

    // MARK: - 门禁 API

    func testGateFollowsRuntimeToggleAndPersists() {
        let defaults = makeIsolatedDefaults("gate_follows_toggle")
        let settings = WatchDebugSettings(defaults: defaults)

        settings.setStreamingEnabled(true)
        XCTAssertTrue(settings.isStreamingActive, "开关 ON → 门禁走流式分支")
        XCTAssertTrue(
            defaults.bool(forKey: WatchDebugSettings.streamingEnabledDefaultsKey),
            "开关翻转必须同步持久化，避免重启后失忆"
        )

        settings.setStreamingEnabled(false)
        XCTAssertFalse(settings.isStreamingActive, "关掉后门禁必须立刻返回 false（下一回合走旧链路）")
        XCTAssertFalse(
            defaults.bool(forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        )
    }

    // MARK: - 回退契约

    func testTogglingOffFiresDisableHandlersSynchronously() {
        let settings = WatchDebugSettings(defaults: makeIsolatedDefaults("rollback_handlers"))

        var handlerFired = 0
        settings.onStreamingDisabled { handlerFired += 1 }

        settings.setStreamingEnabled(true)
        XCTAssertEqual(handlerFired, 0, "开启开关不触发回退")

        settings.setStreamingEnabled(false)
        XCTAssertEqual(handlerFired, 1, "关掉开关必须同步触发回退（清 L1 分片缓冲、序号、计时器）")

        // 幂等：重复关闭不重复触发（避免下游清理逻辑被重复调用）。
        settings.setStreamingEnabled(false)
        XCTAssertEqual(handlerFired, 1, "已 OFF 再设置 OFF 不重复触发回退")
    }

    func testStreamingGenerationIncrementsOnDisableOnly() {
        let settings = WatchDebugSettings(defaults: makeIsolatedDefaults("generation_bump"))

        settings.setStreamingEnabled(true)
        XCTAssertEqual(settings.streamingGeneration, 0, "开启不递增 generation")

        settings.setStreamingEnabled(false)
        XCTAssertEqual(settings.streamingGeneration, 1, "关掉必须递增 generation，让在途流式回合发现自己过期")

        settings.setStreamingEnabled(true)
        settings.setStreamingEnabled(false)
        XCTAssertEqual(settings.streamingGeneration, 2, "每一次 ON→OFF 都递增")
    }

    func testRemoveDisableHandlerStopsCallbacks() {
        let settings = WatchDebugSettings(defaults: makeIsolatedDefaults("remove_handler"))

        var handlerFired = 0
        let token = settings.onStreamingDisabled { handlerFired += 1 }

        settings.setStreamingEnabled(true)
        settings.setStreamingEnabled(false)
        XCTAssertEqual(handlerFired, 1)

        settings.removeDisableHandler(token)
        settings.setStreamingEnabled(true)
        settings.setStreamingEnabled(false)
        XCTAssertEqual(handlerFired, 1, "反注册后回调不再触发（防生命周期结束后的悬挂调用）")
    }

    func testMultipleDisableHandlersAllFire() {
        let settings = WatchDebugSettings(defaults: makeIsolatedDefaults("multi_handlers"))

        var counters = [0, 0, 0]
        settings.onStreamingDisabled { counters[0] += 1 }
        settings.onStreamingDisabled { counters[1] += 1 }
        settings.onStreamingDisabled { counters[2] += 1 }

        settings.setStreamingEnabled(true)
        settings.setStreamingEnabled(false)

        XCTAssertEqual(counters, [1, 1, 1], "所有已注册回退回调必须都触发（buffer/counter/timer 常常在不同持有者里）")
    }

    // MARK: - 无隐藏 session 残留

    /// 关掉开关的**下一个** gate 查询必须返回 legacy，不允许门禁短暂残留 true。
    /// 这一条锁住「下一回合走旧链路，没有隐藏的 session 状态残留」验收项——
    /// 未来 wire-up 在读 gate 之前不会先读某个缓存字段，导致关掉后仍走流式一回合。
    func testGateReturnsLegacyImmediatelyAfterDisable() {
        let settings = WatchDebugSettings(defaults: makeIsolatedDefaults("no_residual"))
        settings.setStreamingEnabled(true)
        XCTAssertTrue(settings.isStreamingActive)
        settings.setStreamingEnabled(false)
        XCTAssertFalse(
            settings.isStreamingActive,
            "OFF 之后门禁必须立即为 false，下一回合直接走旧链路"
        )
    }
}
