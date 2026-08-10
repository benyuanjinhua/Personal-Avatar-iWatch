import Combine
import Foundation

/// ESS-280 灰度存储（R1 生效后：显式设置页可见开关，非 debug 长按）：
/// 仅在 Watch 本机生效的开关，用于同机对比轨道 A（完整 m4a / transferFile
/// 旧链路）与轨道 B（ESS-279 下行首包即播；R4 上行流式化）。R4 单开关
/// 兼管上下行 —— 需要二选一再拆键，本单先合一。
///
/// 与 `AgentConfiguration` / `WatchSettingsStore` 的边界：**不进** iPhone
/// 同步的用户配置对象。本类只落 Watch 本机 UserDefaults，切勿并入
/// `applicationContext` 或 iPhone Relay 载荷，避免最终用户被开发者态污染。
///
/// 门禁契约：`isStreamingActive` 是 ESS-279 / R4 wire-up 的唯一读点。
/// 编译期默认（`VoiceStreamingGate.defaultEnabled`，ESS-356 后为 ON）—— 
/// 关掉后必须**立即**触发已注册的回退回调，让在途流式回合丢弃分片、
/// 清序号/计时器，下一回合走旧链路。
@MainActor
final class WatchDebugSettings: ObservableObject {
    /// 本机存储 key，不与 `AgentConfiguration` 共享 namespace。
    /// 键名保留 `downlink-streaming` 前缀是 R4「一个开关兼管上下行」的
    /// 迁移策略：ESS-279 下行先接入，上行接入时复用同一键，不改写既有
    /// 磁盘状态；未来若要拆二键再另迁移。
    static let streamingEnabledDefaultsKey = "wristagent.watch.debug.downlink-streaming-enabled"
    static let vadEndpointSilenceMsDefaultsKey = "wristagent.watch.debug.vad-endpoint-silence-ms"
    static let defaultVADEndpointSilenceMs = 700

    /// ESS-711：语音打断功能开关。未设置时默认 ON；用户显式关闭后仍持久化
    /// 为 OFF。开启后 `.voiceChat` 替代 `.spokenAudio` 以获取 AEC，
    /// speaking 期间进行 VAD-only 采集检测语音打断。
    static let voiceBargeInEnabledDefaultsKey = "wristagent.watch.debug.voice-barge-in-enabled"

    /// 观察值：SwiftUI Toggle 直接绑定。写入即持久化 + 落日志 + 触发回退回调。
    @Published private(set) var streamingEnabled: Bool
    @Published private(set) var vadEndpointSilenceMs: Int
    /// ESS-711：语音打断开关（未设置时默认 ON）。
    @Published private(set) var voiceBargeInEnabled: Bool

    /// 单调递增的「流式代」计数：每次从 ON → OFF 加 1。
    /// 未来 wire-up 的流式回合在开始时快照本值，投递前发现不一致即知
    /// 自己所属的 session 已被关掉，应停止投递并走一次旧链路兜底。
    @Published private(set) var streamingGeneration: Int = 0

    private let defaults: UserDefaults
    private var disableHandlers: [UUID: () -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.streamingEnabledDefaultsKey) != nil {
            self.streamingEnabled = defaults.bool(forKey: Self.streamingEnabledDefaultsKey)
        } else {
            // 缺 key → 与编译期 gate 对齐：默认跟随 VoiceStreamingGate.defaultEnabled。
            self.streamingEnabled = VoiceStreamingGate.defaultEnabled
        }
        let storedEndpointMs = defaults.object(forKey: Self.vadEndpointSilenceMsDefaultsKey) as? Int
        self.vadEndpointSilenceMs = Self.sanitizeVADEndpointSilenceMs(
            storedEndpointMs ?? Self.defaultVADEndpointSilenceMs
        )
        // ESS-711：正常对话默认支持语音打断。必须区分「缺 key」与用户显式
        // 写入 false；直接调用 bool(forKey:) 会把两者都折叠成 false，导致新装
        // 和历史从未操作过开关的设备继续默认关闭。
        if defaults.object(forKey: Self.voiceBargeInEnabledDefaultsKey) != nil {
            self.voiceBargeInEnabled = defaults.bool(forKey: Self.voiceBargeInEnabledDefaultsKey)
        } else {
            self.voiceBargeInEnabled = true
        }
    }

    // MARK: - 门禁

    /// ESS-279 / R4 wire-up 的唯一读点：`if debugSettings.isStreamingActive { streamPath() } else { legacyPath() }`。
    ///
    /// 保留一层间接是为了让编译期 gate 能在未来提高优先级（例如加入 L2
    /// 真机三态门禁）而无需散点修改调用侧。当前语义等价于 debug 开关本身。
    var isStreamingActive: Bool {
        // 编译期默认跟随 VoiceStreamingGate.defaultEnabled（ESS-356 后为 ON）；
        // 本 debug 开关可覆盖此默认。之后若加入真机三态硬门禁，把它 AND 在这里即可。
        streamingEnabled
    }

    // MARK: - 写入

    /// 设置流式开关。副作用（顺序不可换）：
    /// 1. 落 UserDefaults
    /// 2. 发观测事件 `settings.streaming_toggled from=<> to=<> source=user`
    /// 3. OFF 分支：`streamingGeneration &+= 1` + 触发已注册回退回调
    ///
    /// `source` 目前恒为 `user`（Toggle 是用户操作触发的唯一路径），预留字段
    /// 以便未来加入 iPhone remote-config / 定时回退等自动化路径时能区分。
    func setStreamingEnabled(_ newValue: Bool, source: String = "user") {
        let previous = streamingEnabled
        guard previous != newValue else { return }
        streamingEnabled = newValue
        defaults.set(newValue, forKey: Self.streamingEnabledDefaultsKey)
        WatchLog.info(
            "settings", "streaming_toggled",
            detail: "from=\(previous) to=\(newValue) source=\(source)"
        )
        if !newValue {
            streamingGeneration &+= 1
            // 拷贝一份再遍历，防止回调内部反注册 mutating 迭代中的集合。
            let handlers = Array(disableHandlers.values)
            for handler in handlers { handler() }
        }
    }

    func setVADEndpointSilenceMs(_ milliseconds: Int, source: String = "user") {
        let sanitized = Self.sanitizeVADEndpointSilenceMs(milliseconds)
        guard sanitized != vadEndpointSilenceMs else { return }
        let previous = vadEndpointSilenceMs
        vadEndpointSilenceMs = sanitized
        defaults.set(sanitized, forKey: Self.vadEndpointSilenceMsDefaultsKey)
        WatchLog.info(
            "settings", "vad_endpoint_toggled",
            detail: "from_ms=\(previous) to_ms=\(sanitized) source=\(source)"
        )
    }

    static func sanitizeVADEndpointSilenceMs(_ milliseconds: Int) -> Int {
        min(2_000, max(300, milliseconds))
    }

    // MARK: - 观测：冷启动补报当前值（PM 明确要求「排障时得知道他当时开没开」）

    /// App 冷启动路径调用一次，把当前开关状态补落一条运行时事件，供 Bridge
    /// 按 build 反向对账。事件独立于 toggle 事件，方便日志 grep 定位。
    func logStateAtLaunch() {
        WatchLog.info(
            "settings", "streaming_state_at_launch",
            detail: "value=\(streamingEnabled) vad_endpoint_ms=\(vadEndpointSilenceMs) voice_barge_in=\(voiceBargeInEnabled)"
        )
        // ESS-650：gate 的冷启动快照，走 ESS-655 契约事件。没有它，一份真机
        // 日志里「没触发语音打断」分不清是 gate 关着还是开着但没检测到。
        WatchLog.record(PhoneModeTelemetry.voiceBargeInGate(
            state: voiceBargeInEnabled ? .on : .off, reason: .launchSnapshot
        ))
    }

    // MARK: - ESS-650 语音打断

    /// 设置语音打断开关。副作用（顺序不可换）：
    /// 1. 落 UserDefaults（重启后保持）
    /// 2. 发 ESS-655 契约事件 `voice_barge_in_gate state=on|off reason=…`
    /// 3. 通知**全部**订阅者新值
    ///
    /// ESS-650 两处修正：
    /// - 事件改走 `PhoneModeTelemetry.voiceBargeInGate`。手拼的
    ///   `state=… previous=… source=user` 过不了 `PhoneModeTelemetry.validate`
    ///   （`source` 不是契约字段、`reason` 缺失且 `user` 不是合法取值），
    ///   `PhoneModeCallMetrics` 会把它整条丢进 `rejected`——发了等于没发。
    /// - ON 也要通知。只在 OFF 时回调，等于「运行中打开」永远不闭环：
    ///   本轮回答已经在放，监听要到下一轮才起得来。
    func setVoiceBargeInEnabled(
        _ newValue: Bool,
        reason: PhoneModeTelemetry.GateReason = .userToggle
    ) {
        guard voiceBargeInEnabled != newValue else { return }
        voiceBargeInEnabled = newValue
        defaults.set(newValue, forKey: Self.voiceBargeInEnabledDefaultsKey)
        WatchLog.record(PhoneModeTelemetry.voiceBargeInGate(
            state: newValue ? .on : .off, reason: reason
        ))
        // 拷贝一份再遍历，防止回调内部反注册 mutating 迭代中的集合。
        for handler in Array(bargeInGateHandlers.values) { handler(newValue) }
    }

    private var bargeInGateHandlers: [UUID: (Bool) -> Void] = [:]

    /// 订阅 gate 变化（ON / OFF 都通知）。返回 token；调用方负责在生命周期
    /// 终结前反注册。
    @discardableResult
    func onVoiceBargeInChanged(_ handler: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        bargeInGateHandlers[token] = handler
        return token
    }

    func removeVoiceBargeInHandler(_ token: UUID) {
        bargeInGateHandlers.removeValue(forKey: token)
    }

    // MARK: - 回退回调注册（ESS-279 / R4 wire-up 用）

    /// 注册「开关翻到 OFF 瞬间」触发的回调，用于清理 L1 分片缓冲、序号计数、
    /// per-request timer 等流式态。返回 token；调用方持有 token 用于反注册，
    /// 生命周期终结前应 `removeDisableHandler` 释放（否则回调持有闭包捕获环）。
    @discardableResult
    func onStreamingDisabled(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        disableHandlers[token] = handler
        return token
    }

    func removeDisableHandler(_ token: UUID) {
        disableHandlers.removeValue(forKey: token)
    }
}
