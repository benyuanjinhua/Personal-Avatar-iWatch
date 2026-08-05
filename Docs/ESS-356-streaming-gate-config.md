# ESS-356：Realtime 流式门禁默认值及配置下发

- 状态：已实现
- 日期：2026-08-05
- 父单：ESS-355

## 默认值

| 组件 | 键 | 默认值 | 说明 |
|------|-----|--------|------|
| `VoiceStreamingGate.defaultEnabled` | 编译期常量 | `true` | `Shared/VoiceStreamProtocol.swift:8` |
| `AgentConfiguration.voiceStreamingV2` | 结构体默认值 | `true` | `Shared/AgentModels.swift:93` |
| `AgentConfiguration.demo` | demo 配置 | `true` | `Shared/AgentModels.swift:130` |

全新安装 Watch 或 iPhone 时，流式门禁默认开启，用户无需手动打开。

## 下发优先级（高 → 低）

1. **Watch 本机 Debug 开关** (`WatchDebugSettings`)  
   Watch 设置页的显式 Toggle，持久化在 `UserDefaults` 中。用户手动关闭后，下一回合回退到旧链路（完整 m4a / `transferFile`）。  
   键：`wristagent.watch.debug.downlink-streaming-enabled`

2. **iPhone 下发 `AgentConfiguration.voiceStreamingV2`**  
   iPhone 伴侣 App 的配置通过 `WCSession.applicationContext` 下发到 Watch。  
   Watch 端 `WatchSettingsStore` 解码后更新 `configuration.voiceStreamingV2`。  
   读取点：`WatchAppDelegate.swift:32-33`

   ```swift
   pushToTalk.voiceStreamingEnabled = { [weak settings] in
       settings?.configuration.voiceStreamingV2 ?? VoiceStreamingGate.defaultEnabled
   }
   ```

3. **编译期默认 `VoiceStreamingGate.defaultEnabled`**  
   当以上两层均无显式值时的兜底默认。ESS-356 后为 `true`。

### 升级兼容性

`AgentConfiguration` 的自定义 `init(from decoder:)` 在反序列化缺少 `voiceStreamingV2` 键的旧配置时，回退为 `false`（`Shared/AgentModels.swift:120`）。这确保已安装设备升级后不会因为结构体默认值变更而静默开启流式。

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

| 位置 | 读取方式 | 说明 |
|------|---------|------|
| `PushToTalkController.voiceStreamingEnabled` | `configuration.voiceStreamingV2 ?? VoiceStreamingGate.defaultEnabled` | 上行录制前判断是否走流式 |
| `WatchDebugSettings.isStreamingActive` | `streamingEnabled` | 下行流式 chunk 接收器的门禁 |
| `WatchStreamReceiver.receive(chunk:)` | `debugSettings.isStreamingActive` | 门禁关闭时静默丢弃 chunk |
