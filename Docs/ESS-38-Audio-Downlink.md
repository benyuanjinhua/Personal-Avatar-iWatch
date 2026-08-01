# ESS-38：Qwen Audio Realtime 文字 + 人物口气语音下行到 Apple Watch

> 真机证据（2026-07-31，request `019fbbdd-5c39-70fa-9760-dc262ee092b0`）：上行与中段
> 已通（Watch → iPhone → Bridge → Realtime → Codex → 文本），但终态
> `source=task_presentation` 且 `audio_base64=null`——Realtime 的
> `origin=announcement` 播报音频被观测到却未绑定回 request_id，也未下发。
> 本次修复把下行链路补齐为「文字先行 + Qwen 原声语音随后」。

## 根因（两处断裂）

1. **Mac Bridge**：supervisor 对 announcement 只做隔离与播放回执（ESS-36 语义），
   聚合的 24kHz PCM 直接丢弃；`taskId` 从未与账本 `task_id` 关联，业务归属丢失。
2. **iPhone Relay**：WSS 事件处理解码的是 Bridge **从未发送**的旧事件形状
   （`{event:"result", …}`），而 Bridge 实际发 `{type:"turn.state", turn:{…}}` /
   `{type:"snapshot", turns:[…]}` ——下行在解码层即断裂；Watch 的 ESS-29 时间线
   （`VoiceStatusEnvelope` / `VoiceSpeechMessage` 信封）也从未被 iPhone 投喂。

## 修复设计

### Mac Bridge（Node）

- **归属**（supervisor.mjs）：`response.started(origin=announcement)` 携带 `taskId`，
  按 `responseId` 聚合 PCM delta + assistant transcript；`audio.done` / 播报窗口
  idle / 30s 兜底定时器交付聚合。上限 `max_announcement_pcm_bytes`（默认 5.76MB
  ≈ 120s），超限截断不丢弃。
- **绑定**（server.mjs）：`taskId → ledger.byTaskId → request_id`。到达次序无关：
  task 先终态 → 文本先投影，语音到后补挂并二次投影 `turn.state`；语音先到 → 暂存
  （10min TTL），completed 投影时立即携带。归属不了的播报只留取证日志。
- **媒体**：PCM → AudioPipe AAC/M4A，元数据 `{sha256, codec, duration_ms,
  size_bytes}` 进 `result.audio`；≤2MB 同时内联 `audio_base64`；文件落
  `state/result-audio/<request_id>.m4a`（0600，保留期 24h 清扫）。
- **取回**：新端点 `GET /v1/voice/turns/{id}/audio`——同套 HMAC 签名 + 设备归属
  校验，`Range` 断点续传（206/416），`x-audio-sha256` 头；下发前重验落盘文件与
  账本 sha 一致。日志全程只记字节数，不落 PCM/base64。

### iPhone（Swift）

- `Shared/BridgeTurnProjection.swift`：钉死 Bridge 真实 WSS 契约的解码 +
  `status/detail → VoiceTurnState` 映射 + `VoiceStatusEnvelope` 构造（含权限、
  失败码、结果载荷）。
- `WristAgentPhoneRelay`：终态**先发文本信封**（`VoiceStatusMessage`，
  sendMessage/transferUserInfo，Watch 离线不丢）；语音优先用内联 base64，缺席则
  凭元数据走 `/audio` 断点续传下载（`.partial` 保留断点，3 次退避重试），
  **sha256 校验通过才** `transferFile`（`VoiceSpeechMessage` 信封）；
  `requestId|sha` 去重，快照重放/补挂事件不重复下发；transferFile 完成即删本地
  临时文件。下载失败/无音频 → 文本降级，状态可见。

### Watch（无改动）

ESS-29 链路本就完备，此前只是从未被投喂：`WatchSettingsStore.storeSpeech`
sha 校验 → 加密仓 → `VoiceTurnJournal.attachSpeech` → `PushToTalkView` 在同一
request 的 completed 卡片展示文本 + 自动播放/手动播放；页面退出重进由持久化
journal 恢复；音频缺席时文本卡片照常（降级）。

## 全链追踪

同一 `request_id` 贯穿：Watch 信封 → iPhone outbox → Bridge `turn_accepted` →
supervisor journal（`request_id=label`）→ `announcement_bound`（携 `task_id` /
`response_id`）→ `result_audio_attached` → `turn.state` 投影 → Watch journal。

## 回归结果（2026-08-01，本仓库）

| 套件 | 结果 |
|---|---|
| Bridge `npm test`（bridge/watchdog/ess36-realtime/**ess38-downlink**） | 32/32 通过 |
| ess38-downlink 新增 6 项：迟到播报补挂、先到播报即时携带、无归属不乱挂、鉴权/404、Range 断点续传拼接一致、截断上限、direct 路径元数据 | 全部通过 |
| Projection mock 测试 | 通过 |
| Swift `swift test`（含新增 BridgeTurnProjectionTests 7 项） | 73/73 通过 |
| iOS 模拟器构建（WristAgent + Watch App 嵌入） | BUILD SUCCEEDED |
| watchOS 模拟器构建（WristAgent Watch App） | BUILD SUCCEEDED |

## 待真机验收（需人工）

- 连续 5 条中文语音请求，5/5 Watch 收到文字并播放 Qwen Audio Realtime 原声。
- Mac 端播放与 Watch 端播放内容、音色、韵律人工对比一致。
- projection live-test（需 127.0.0.1:3101 真网关）在部署机复跑。

## 非目标（保持）

- D1 只读边界不变（写权限清扫器未触碰）。
- 未引入第二套 TTS：Watch 播放的就是 Qwen Audio Realtime 生成的 announcement
  原声（Bridge 仅转码封装）。
