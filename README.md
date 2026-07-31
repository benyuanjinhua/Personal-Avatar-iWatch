# 腕语 WristAgent

Apple Watch 上的语音 Agent 遥控器。Watch 负责录音、状态反馈、TTS 和风险确认；ASR、Agent 与业务工具运行在服务端。公司内网场景采用 iPhone Companion Relay，经 iPhone 上的 Tailscale 访问 Agent。

当前工程包含：

- 原生 SwiftUI iPhone 配套 App。
- 原生 SwiftUI 单 Target watchOS App，最低 watchOS 10。
- WatchConnectivity 设置同步。
- 麦克风录音、云端请求、系统 TTS、触感反馈。
- 只读 / 可撤回 / 必须确认三级风险模型。
- 长任务轮询和取消。
- App Intent / Siri 快捷入口。
- 无服务器也能体验的三轮 Demo Agent。
- 可运行的本地 Mock Gateway 和接口测试。
- 可在浏览器中运行全链路 testcase 的 Web iWatch Mock。

## 目录

```text
WristAgent/
├── Shared/                  # iOS 与 watchOS 共用模型、Keychain
├── iOS/                     # iPhone 设置与 WatchConnectivity
├── Watch/                   # 录音、Agent、TTS、风险确认、Watch UI
├── Docs/PRD.md              # 产品需求与 iPhone Relay 网络架构
├── Docs/API.md              # 云端 Agent Gateway 协议
├── Docs/WATCH_INSTALL_TROUBLESHOOTING.md # Watch 真机安装排障
├── Tools/mock-gateway.mjs   # 本地联调服务
├── Brand/AppIcon.svg        # iPhone/Watch 共用图标母版
├── project.yml              # XcodeGen 工程定义
└── Package.swift            # 共享模型测试入口
```

## 必需环境

1. macOS。
2. 完整版 Xcode 16 或更新版本，包含 iOS 与 watchOS SDK。
3. XcodeGen：`brew install xcodegen`。
4. 真机安装需要 Apple ID；免费 Personal Team 可用于自己的设备，持续分发需 Apple Developer Program。

本仓库生成时所在的 Mac 只有 Command Line Tools，没有完整 Xcode。因此源码与独立测试已验证，watchOS 编译、签名和真机部署需要在安装 Xcode 后执行。

## 生成 Xcode 工程

```bash
cd WristAgent
./Scripts/bootstrap.sh
open WristAgent.xcodeproj
```

Bundle ID 可以通过环境变量覆盖，不需要修改工程：

```bash
export WRISTAGENT_BUNDLE_ID=com.yourname.WristAgent
```

工程会自动把 Watch Bundle ID 设为 `${WRISTAGENT_BUNDLE_ID}.watchkitapp`，并同步 Companion ID。

## 第一次安装到 Apple Watch

1. 在 iPhone 上确认目标 Apple Watch 已配对，并更新到 watchOS 10 或更高版本。
2. 用数据线或无线调试把 iPhone 连接到 Mac。
3. Xcode 打开 `WristAgent.xcodeproj`。
4. 在两个 Target 的 `Signing & Capabilities` 中选择同一个 Team。
5. Scheme 选择 `WristAgent`，运行设备选择已配对 iPhone。
6. 点击 Run。Xcode 会安装 iPhone App，并把 Watch App 嵌入后安装到手表。
7. 如果没有自动安装，在 iPhone 的 Watch App →“可用 App”里安装“Jackson Avatar”。
8. 首次打开 Watch App 时允许麦克风权限。

遇到开发者模式、DDI、签名、Tunnel 或“无法安装”问题时，按
[Watch 真机安装 Troubleshooting](Docs/WATCH_INSTALL_TROUBLESHOOTING.md)
逐项排查。

也可以用脚本完成签名、构建和 iPhone 安装：

```bash
export APPLE_TEAM_ID=你的TeamID
export IPHONE_UDID=已配对iPhone的UDID
export WRISTAGENT_BUNDLE_ID=com.yourname.WristAgent
./Scripts/install-device.sh
```

未设置 `IPHONE_UDID` 时，脚本会列出 Xcode 当前识别到的设备。

默认运行在“离线演示”模式。每录一段语音会依次体验：

1. 只读日程查询。
2. 长任务执行与结果回传。
3. 创建提醒与撤回。
4. 发送消息前的高风险确认。

Demo 模式不会把录音发送到任何服务器。

## 接入真实云端 Agent

目标企业网络架构见 [产品需求文档](Docs/PRD.md)：Watch 通过
`WatchConnectivity` 把请求交给 iPhone Companion，由 iPhone 经 Tailscale
访问公司内网 Agent。公司模式不允许 Watch 直接访问 Gateway。

> 当前 MVP 的 `CloudAgentService` 仍由 Watch 直接请求 Gateway。完成 PRD
> 第 10 节的 iPhone Relay 改造前，只能用于公网或局域网联调，不能作为公司
> Tailscale 场景的正式链路。

1. 按 [Docs/API.md](Docs/API.md) 实现 Gateway。
2. 完成 [Docs/PRD.md](Docs/PRD.md) 中的 iPhone Relay 改造。
3. 在 iPhone“腕语”中选择“云端 Agent”。
4. 输入公司内网 HTTPS Endpoint 和 Bearer Token。
5. iPhone 验证 Tailscale 与 Gateway 可用后启用公司模式。
6. Watch 后续请求只经 iPhone Relay 转发。

当前直连联调版会把 Token 同步到 Watch Keychain；完成 iPhone Relay 改造后，公司
Gateway Token 只保存在 iPhone Keychain，不再下发到 Watch。UserDefaults 只保存
脱敏配置。

### 局域网联调

Debug 构建允许连接私有局域网内的 HTTP 地址：

```bash
node Tools/mock-gateway.mjs
```

启动后访问 [http://localhost:8787](http://localhost:8787)，可以直接在 Web iWatch
Mock 中依次验证四条核心链路：

1. 只读日程查询。
2. 长任务启动、轮询和完成。
3. 可撤回提醒及撤回请求。
4. 高风险发送操作及确认请求。

点击“运行全链路 testcase”可自动跑完整场景，右侧会显示每条用例状态和真实
HTTP 请求事件。此入口与 Watch 联调共用同一个 Mock Gateway 协议，不需要复制
一套测试数据。

每轮请求带全链路 `trace_id`（可在右侧输入框自定义，如 `223lkjl`，配合
自定义输入“杭州天气咋样”）。网关按模块写 JSONL 日志到
`logs/trace/{h5-mock,main-agent,codex-cli}.log`，每行都含 `trace_id`；
`grep 223lkjl logs/trace/*.log` 或页面上点“查询链路”（`GET
/v1/trace/223lkjl`）即可确认该输入在主 Agent、Codex CLI 阶段是否成功。
约定见 [Docs/API.md](Docs/API.md) 第 6 节。

查出 Mac 的局域网 IP，在 iPhone App 中填写：

```text
http://192.168.x.x:8787
```

Release 构建只接受 HTTPS。

首次连接局域网 Gateway 时，Watch 可能请求“本地网络”权限；这是 Debug 联调所需。云端生产模式不需要该权限。

## 验证命令

不依赖 Xcode：

```bash
./Scripts/audit-source.sh
```

安装 Xcode 后：

```bash
./Scripts/verify.sh
```

验证脚本会生成工程、运行共享模型测试，并分别构建 iOS Simulator 与 watchOS Simulator Target。

## 当前 MVP 边界

- 不实现第三方常驻唤醒词；入口是 App、表盘复杂功能或 Siri/App Intent。
- Watch 前台轮询长任务。生产版的“完成后提醒”需要 Gateway 接入 APNs。
- 云端 TTS 可通过 `tts_audio_base64` 返回；不返回时使用 Watch 系统中文 TTS。
- 语音以 16kHz、单声道 AAC/M4A 上传，最长 30 秒。
- 真正执行发送、删除、付款等高风险动作前，Gateway 必须再次验证确认 ID，不能只相信客户端。
