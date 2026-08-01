# WristAgent 模块划分与演进设计

## 1. 目标

在保持现有 iPhone + Apple Watch Demo 可运行的前提下，把代码按职责和依赖方向划分，
为下一阶段的 iPhone Relay、真实 Gateway 接入和自动化测试提供清晰边界。

本设计只引入当前主链路需要的模块，不提前拆分独立服务或多个 Swift Package。

## 2. 核心链路

```text
Watch UI
  → ConversationUseCase
  → AgentGateway（协议）
  → DemoAgentGateway / WatchDirectGateway（现有联调）
  → Agent Gateway API

iPhone Settings
  → ConfigurationStore
  → WatchConnectivity
  → Watch ConfigurationStore

下一阶段公司模式：
Watch UI → ConversationUseCase → Watch Relay Client
  → WatchConnectivity → iPhone Relay → 内网 Agent Gateway
```

模块依赖必须从界面和基础设施指向领域层，领域层不反向依赖 SwiftUI、
WatchConnectivity、URLSession、Keychain 或 UserDefaults。

## 3. 目标模块

| 模块 | 职责 | 主要现有代码 | 允许依赖 |
| --- | --- | --- | --- |
| `WristAgentDomain` | Agent 请求/响应、风险、任务、配置等纯领域模型；Gateway 和存储协议 | `Shared/AgentModels.swift` | `Foundation` |
| `WristAgentPersistence` | 配置、Token、对话历史的本地持久化实现 | `Shared/SecureTokenStore.swift`、`Shared/ConversationHistory.swift` 中的 Store | `WristAgentDomain`、系统存储框架 |
| `WristAgentTransport` | Gateway HTTP 编解码、鉴权、端点校验、错误映射 | `Watch/AgentService.swift` 中的 `CloudAgentService` | `WristAgentDomain`、`Foundation` |
| `WristAgentDemo` | 离线 Demo 场景与固定响应 | `Watch/DemoAgentService.swift` | `WristAgentDomain` |
| `WristAgentWatchConnectivity` | iPhone/Watch 消息信封、配置和历史同步、后续 Relay 通道 | `iOS/PhoneConnectivity.swift`、`Watch/WatchSettingsStore.swift` | `WristAgentDomain`、`WatchConnectivity` |
| `WristAgentConversation` | 录音提交、确认、撤回、轮询、取消及历史写入的用例编排 | `Watch/ConversationViewModel.swift` | `WristAgentDomain` |
| `WristAgentAudio` | Watch 录音和语音播放的系统适配 | `Watch/AudioRecorder.swift`、`Watch/SpeechPlayer.swift` | 系统音频框架 |
| `WristAgentWatchUI` | Watch App 入口、会话和历史界面、App Intent | 其余 `Watch/*.swift` | Conversation、Audio、Domain |
| `WristAgentPhoneUI` | iPhone App 入口、设置和历史界面 | `iOS/*.swift` 中的 UI 和设置组合 | Domain、Persistence、WatchConnectivity |

## 4. 建议目录

MVP 阶段继续使用两个 Xcode Application Target，通过目录边界和协议解耦；当核心逻辑
稳定后，再把前三个纯逻辑模块提升为 Swift Package Target。

```text
Sources/
├── Domain/
│   ├── Models/
│   └── Ports/                 # AgentGateway、HistoryRepository 等协议
├── Persistence/
│   ├── ConfigurationStore.swift
│   ├── ConversationHistoryStore.swift
│   └── SecureTokenStore.swift
├── Transport/
│   └── HTTPAgentGateway.swift
├── Demo/
│   └── DemoAgentGateway.swift
├── Connectivity/
│   ├── Messages/
│   ├── PhoneConnectivity.swift
│   └── WatchConnectivity.swift
├── Conversation/
│   └── ConversationUseCase.swift
└── Audio/
    ├── AudioRecorder.swift
    └── SpeechPlayer.swift
iOS/
└── UI/
Watch/
├── App/
├── Intents/
└── UI/
Tests/
├── DomainTests/
├── TransportTests/
├── PersistenceTests/
└── ConversationTests/
```

在完成实体迁移前，现有 `Shared/`、`iOS/`、`Watch/` 仍是唯一有效源码位置，
上面的 `Sources/` 是目标结构，不应同时复制同一类型。

## 5. 边界与接口

领域层定义端口，基础设施层实现端口。现有 `AgentServing` 应移动到 Domain 并改名为
`AgentGateway`；`CloudAgentService` 和 `DemoAgentService` 分别成为实现。

建议的最小端口：

```swift
protocol AgentGateway {
    func submit(audio: Data, conciseReply: Bool) async throws -> AgentTurnResponse
    func confirm(id: String, approved: Bool) async throws -> AgentTurnResponse
    func task(id: String) async throws -> AgentTaskResponse
    func undo(id: String) async throws -> AgentTurnResponse
    func cancel(taskID: String) async
}

protocol ConversationHistoryRepository {
    func load() -> [ConversationHistoryEntry]
    func save(_ entries: [ConversationHistoryEntry]) throws
}
```

网络 DTO 与领域模型当前字段完全一致，可暂时复用；协议出现版本差异时再增加
`Transport/DTO` 和显式映射，避免无收益的重复类型。

## 6. 依赖规则

1. `Domain` 不得导入 UI、连接、网络和持久化框架。
2. `Conversation` 只依赖领域协议，不直接创建 `URLSession`、`WCSession` 或具体 Store。
3. UI 只触发用例并渲染状态，不包含 HTTP 路径、轮询策略和 Keychain 逻辑。
4. iPhone Relay 与 Watch 直连实现同一个 `AgentGateway`，通过组合根选择实现。
5. Token 在公司模式只由 iPhone `Persistence` 持有；Relay 消息不得包含 Token。
6. 跨设备消息使用显式 `Codable` 信封并带 `protocolVersion`、`requestID`，不传任意字典。
7. 每个模块只公开调用方需要的类型，默认保持 `internal`。

## 7. 迁移顺序

### 阶段 1：建立可测试的领域边界

- 从 `AgentModels.swift` 拆出 Domain 模型和协议。
- 把历史数据实体与 `UserDefaults` Store 分开。
- 为 Gateway 端点校验、历史裁剪和状态转换补单元测试。
- 保持现有 Target 和运行行为不变。

验收：`swift test` 通过，两个 App Target 的源码审计通过。

### 阶段 2：拆分基础设施和会话编排

- 将 HTTP、Demo、Persistence、Audio 按目标目录迁移。
- 将 `ConversationViewModel` 中的业务流程下沉为可注入 `AgentGateway` 的用例。
- ViewModel 仅保留可观察 UI 状态。

验收：Demo 的提交、长任务、确认、撤回四条链路都有自动化测试。

### 阶段 3：实现 iPhone Relay

- 定义版本化 Relay 请求/响应和取消消息。
- Watch 使用 Relay Client；iPhone 使用 Relay Handler 调用内网 Gateway。
- 移除公司模式下 Token 向 Watch 的同步。
- Watch 直连实现只保留 Debug 联调用途。

验收：公司模式不存在 Watch → Gateway 直连，Token 不进入 Watch 配置或日志。

### 阶段 4：按收益提升为 Swift Package

- 将 `Domain`、`Transport`、`Conversation` 提升为独立 Package Target。
- `Persistence`、`Connectivity`、`Audio` 保持平台适配 Target。
- 仅在增量构建、复用或测试隔离有明确收益时继续细拆。

## 8. 非目标

- 不为当前单一 App 引入微服务、依赖注入框架或事件总线。
- 不在 Relay 完成前移除可工作的 Demo 和 Debug 直连。
- 不把 SwiftUI 页面按每个 View 建成独立模块。
- 不在 API 版本分歧出现前复制一套网络 DTO。

## 9. 风险与退出方案

- **Xcode Target 文件归属易出错**：每阶段只迁移一个边界，运行 XcodeGen 后同时构建
  iOS 与 watchOS；失败时可按目录级提交回退。
- **跨平台 API 污染共享模块**：Domain 使用 `Foundation` 子集，平台能力留在 Adapter。
- **Relay 消息演进不兼容**：使用版本字段；不支持的版本返回可展示错误，不静默降级。
- **过度模块化增加构建成本**：阶段 1–3 先使用目录和协议，Package 化作为最后一步。

## 10. 完成定义

- 每个现有源码文件都有唯一的目标模块归属。
- 模块依赖符合单向规则，无 UI/基础设施反向渗透 Domain。
- Demo 主链路保持可运行。
- `swift test`、源码审计以及可用环境中的 iOS/watchOS 构建全部通过。
- Relay 上线后，公司模式 Token 仅存在 iPhone Keychain。
