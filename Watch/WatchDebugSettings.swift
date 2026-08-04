import Combine
import Foundation

/// ESS-280 Debug 灰度存储：仅在 Watch 本机生效的开发者开关，用于同机对比
/// 轨道 A（完整 m4a / transferFile 旧链路）与轨道 B（ESS-279 下行首包即播）。
///
/// 与 `AgentConfiguration` / `WatchSettingsStore` 的边界：**不进** iPhone
/// 同步的用户配置对象。本类只落 Watch 本机 UserDefaults，切勿并入
/// `applicationContext` 或 iPhone Relay 载荷，避免最终用户被开发者态污染。
///
/// 门禁契约：`isDownlinkStreamingActive` 是 ESS-279 wire-up 的唯一读点。
/// 编译期默认（`VoiceStreamingGate.defaultEnabled`）保持 OFF —— 只有开发者
/// 在 Debug 面板显式打开本开关才会走流式；关掉后必须**立即**触发已注册的
/// 回退回调，让在途流式回合丢弃分片、清序号/计时器，下一回合走旧链路。
@MainActor
final class WatchDebugSettings: ObservableObject {
    /// 本机存储 key，不与 `AgentConfiguration` 共享 namespace。
    static let downlinkStreamingDefaultsKey = "wristagent.watch.debug.downlink-streaming-enabled"

    /// 观察值：SwiftUI Toggle 直接绑定。写入即持久化 + 落日志 + 触发回退回调。
    @Published private(set) var downlinkStreamingEnabled: Bool

    /// 单调递增的「流式代」计数：每次从 ON → OFF 加 1。
    /// 未来 wire-up 的流式回合在开始时快照本值，投递前发现不一致即知
    /// 自己所属的 session 已被关掉，应停止投递并走一次旧链路兜底。
    @Published private(set) var streamingGeneration: Int = 0

    private let defaults: UserDefaults
    private var disableHandlers: [UUID: () -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.downlinkStreamingDefaultsKey) != nil {
            self.downlinkStreamingEnabled = defaults.bool(forKey: Self.downlinkStreamingDefaultsKey)
        } else {
            // 缺 key → 与编译期 gate 对齐：默认 OFF。
            self.downlinkStreamingEnabled = false
        }
    }

    // MARK: - 门禁

    /// ESS-279 wire-up 的唯一读点：`if debugSettings.isDownlinkStreamingActive { streamPath() } else { legacyPath() }`。
    ///
    /// 保留一层间接是为了让编译期 gate 能在未来提高优先级（例如加入 L2
    /// 真机三态门禁）而无需散点修改调用侧。当前语义等价于 debug 开关本身。
    var isDownlinkStreamingActive: Bool {
        // 编译期默认仍是 OFF；本 debug 开关是唯一的运行时提升路径。
        // 之后若加入真机三态硬门禁，把它 AND 在这里即可，wire-up 点无需改。
        downlinkStreamingEnabled
    }

    // MARK: - 写入

    /// 设置 debug 开关。副作用（顺序不可换）：
    /// 1. 落 UserDefaults
    /// 2. 发观测事件 `settings.downlink_streaming_toggled from=<> to=<>`
    /// 3. OFF 分支：`streamingGeneration &+= 1` + 触发已注册回退回调
    func setDownlinkStreamingEnabled(_ newValue: Bool) {
        let previous = downlinkStreamingEnabled
        guard previous != newValue else { return }
        downlinkStreamingEnabled = newValue
        defaults.set(newValue, forKey: Self.downlinkStreamingDefaultsKey)
        WatchLog.info(
            "settings", "downlink_streaming_toggled",
            detail: "from=\(previous) to=\(newValue)"
        )
        if !newValue {
            streamingGeneration &+= 1
            // 拷贝一份再遍历，防止回调内部反注册 mutating 迭代中的集合。
            let handlers = Array(disableHandlers.values)
            for handler in handlers { handler() }
        }
    }

    // MARK: - 回退回调注册（ESS-279 wire-up 用）

    /// 注册「开关翻到 OFF 瞬间」触发的回调，用于清理 L1 分片缓冲、序号计数、
    /// per-request timer 等流式态。返回 token；调用方持有 token 用于反注册，
    /// 生命周期终结前应 `removeDisableHandler` 释放（否则回调持有闭包捕获环）。
    @discardableResult
    func onDownlinkStreamingDisabled(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        disableHandlers[token] = handler
        return token
    }

    func removeDisableHandler(_ token: UUID) {
        disableHandlers.removeValue(forKey: token)
    }
}
