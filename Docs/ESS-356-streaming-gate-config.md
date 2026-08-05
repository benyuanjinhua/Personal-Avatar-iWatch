# ESS-356：Realtime 流式门禁默认值

- 状态：已实现（收窄为「编译期默认开启」；配置下发下行 gate → ESS-357）
- 日期：2026-08-05
- 父单：ESS-355

## 默认值

| 组件 | 键 | 默认值 | 说明 |
|------|-----|--------|------|
| `VoiceStreamingGate.defaultEnabled` | 编译期常量 | `true` | `Shared/VoiceStreamProtocol.swift:8` |
| `AgentConfiguration.voiceStreamingV2` | 结构体默认值 | `true` | `Shared/AgentModels.swift:93` |
| `AgentConfiguration.demo` | demo 配置 | `true` | `Shared/AgentModels.swift:130` |

全新安装 Watch 或 iPhone 时，流式门禁默认开启。

## 当前接线（ESS-356 收窄后）

下行流式门禁（`WatchStreamReceiver`）读的是本地 `WatchDebugSettings` 键，**不由 iPhone 配置控制**。iPhone `AgentConfiguration.voiceStreamingV2` 当前仅控制上行 `PushToTalkController`，配置下发覆盖下行 gate 拆到 ESS-357。

### 下行 gate 优先级（本 ESS-356 范围）

1. **`WatchDebugSettings` UserDefaults 键** `wristagent.watch.debug.downlink-streaming-enabled`  
   本地显式 Toggle，持久化；有值时直接读取。

2. **编译期默认 `VoiceStreamingGate.defaultEnabled`**（ESS-356 后为 `true`）  
   无 UserDefaults key 时的兜底。

### 上行 gate 读取点

```swift
// WatchAppDelegate.swift:32-33
pushToTalk.voiceStreamingEnabled = { [weak settings] in
    settings?.configuration.voiceStreamingV2 ?? VoiceStreamingGate.defaultEnabled
}
```

上行同时受 iPhone `AgentConfiguration.voiceStreamingV2` 控制（`configuration` 通过 `WCSession.applicationContext` 从 iPhone 下发）。iPhone 伴侣 App 默认 `voiceStreamingV2: true`。

### 升级兼容性

`AgentConfiguration` 的自定义 `init(from decoder:)` 在反序列化缺少 `voiceStreamingV2` 键的旧配置时，回退为 `false`（`Shared/AgentModels.swift:120`）。已安装设备升级后不会因为结构体默认值变更而静默开启流式。

旧配置需通过 iPhone 伴侣 App 显式同步一次才会生效新的默认值。全新安装不受影响（直接使用结构体默认值 `true`）。

## Watch 本机 Debug 覆盖

`WatchDebugSettings` 是 Watch 本机的开发者/调试开关：

- 不进入 iPhone 同步 (`applicationContext`)
- 不进入 iPhone Relay 载荷
- 仅落 Watch 本机 `UserDefaults`

初始化逻辑（`Watch/WatchDebugSettings.swift:36-44`）：
- 有 UserDefaults key → 读取存储值
- 无 key（全新安装）→ 跟随 `VoiceStreamingGate.defaultEnabled`（ESS-356 后为 `true`）

## 读取点汇总

| 位置 | 读取方式 | 方向 |
|------|---------|------|
| `PushToTalkController.voiceStreamingEnabled` | `configuration.voiceStreamingV2 ?? VoiceStreamingGate.defaultEnabled` | 上行 |
| `WatchDebugSettings.isStreamingActive` | `streamingEnabled`（本地 UserDefaults 键） | 下行 |
| `WatchStreamReceiver.gateOpen` | `debugSettings.isStreamingActive` | 下行 |

## 待办：ESS-357

配置下发覆盖下行 gate（打通 `WCSession → apply → WatchDebugSettings` 接线并补真实链路测试）拆到 ESS-357。
