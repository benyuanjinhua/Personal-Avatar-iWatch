# Realtime 全链路 CI 门禁清单（ESS-1071）

> 本文是 ESS-1071 验收第 4 条的「合入 main 前的 CI 门禁清单」。目标是让
> Watch → iPhone → AudioRealtimeGateway → qwen-audio-agent → Codex →
> 流式语音返回这条链路在每次 PR 上都被机器可判定地验证，而不是靠真机手测。

## 1. 门禁总览

| 行 | 门禁 | 位置 | 命令 | 判定 |
|---|---|---|---|---|
| 1 | AudioRealtimeGateway 单元/契约测试 | `AudioRealtimeGateway` | `npm test` | 全绿（0 fail） |
| 2 | Gateway 三场景 + 六故障 E2E 门禁 | `AudioRealtimeGateway` | `npm run test:e2e` | `ALL PASS`，退出码 0 |
| 3 | 统一可观测性契约测试 | `AudioRealtimeGateway/test/observability-*.test.mjs` | 随 `npm test` | 全绿 |
| 4 | qwen-audio-agent 服务端测试 | `qwen-audio-agent` | `npm test` | 全绿（531 passed 基线） |
| 5 | Swift 全量单测 | 仓库根 | `swift test` | 全绿 |
| 6 | iOS + watchOS 双 target 构建 | 仓库根 | `xcodebuild build` | 0 error |
| 7 | Watch 模拟器 xctest | 仓库根 | `xcodebuild test` | 0 failure + `** TEST FAILED **` 未出现 |
| 8 | Bridge 测试 | `MacRemoteFrontendBridge` | `npm test` + `projection/test/mock-tests.mjs` | 全绿 |
| 9 | `xcodegen generate` 无 pbxproj 漂移 | 仓库根 | `git diff --exit-code` | 无 diff |
| 10 | `git diff --check` | 仓库根 | `git diff --check origin/main...HEAD` | 无 whitespace / merge marker |

行 1–3 是本次 ESS-1071 新增/接管的门禁；行 4–10 沿用既有 R-02.5 关卡一。

## 2. 一命令 E2E 门禁（行 2）的断言

`node smoke/realtime-e2e-gate.mjs --faults` 在**无外部依赖**（scripted 上游）
下驱动真实 Gateway 表面（HTTP 铸 token → WSS upgrade → session.start →
audio.append → audio.commit → 下行帧），输出每个场景的端到端时序 + 断言：

### 2.1 三个固定场景

| 场景 | 必须断言 |
|---|---|
| `time`（现在几点） | 直答不进入 Codex（`codex_first_chunk_ms == null`）；单段 `audio.done` 终态；无静默结束。 |
| `weather`（杭州天气） | 跨段流式（`audio.segment_done` ≥ 1 后仍有 `audio.done`）；最终答案帧数 > 1（不是只播「正在查询」）；进入 Codex；`commit_to_first_tool_audio_ms` 可测。 |
| `knowledge`（我的分身知识库） | 同 `weather`。 |

### 2.2 六个故障注入

| 故障 | 必须断言 |
|---|---|
| provider 4xx | 显式 `error` 帧；无 `audio.done`；无静默结束。 |
| 迟完成 | 受理回合正常 `audio.done` 收口；迟到帧被丢弃（`stale_generation_dropped > 0`）。 |
| TTS 失败 | 显式 `error` 帧。 |
| WSS 断线 | 客户端断连不是上游错误（无 `error` 帧）；无静默结束。 |
| 队列积压 | 预算溢出显式失败（`ERR_DOWNLINK_BUDGET` / `ERR_UPSTREAM_BUDGET_EXCEEDED`）。 |
| barge-in | `cancel.ack` 送达；旧代迟到帧被丢弃。 |

所有故障注入统一满足三条跨组件不变量（由
`observability/collector.mjs` 的 `ChainCollector` 强制执行）：

1. **无静默结束** —— 已 commit 的回合收口时必须带终态（done/error/cancel），
   客户端主动断连（1000/1001/1006）除外。
2. **无跨会话串台** —— 同一 `task_id` 只能属于一个 `session_id`。
3. **无提前 done** —— `audio.done` 前所有已 flush 的段都必须已排出首个音频帧。

## 3. 统一可观测性契约（行 3）

`AudioRealtimeGateway/observability/` 是本次新增的单一契约源：

- `correlation.mjs` —— 规范关联字段（`request_id`/`session_id`/
  `response_id`/`generation`/`sequence`/`task_id`），把 Gateway 词汇
  （`request_id` 即 turn id）与 qwen-audio-agent 词汇（`turnId`/`taskId`/
  `turnGeneration`）归一化，并把两边事件名映射到同一套规范事件名。
- `metrics.mjs` —— 四个延迟指标 + 四个计数器的定义与累加器：
  `codex_first_chunk_ms`、`chunk_to_segment_ms`、`segment_to_first_audio_ms`、
  `commit_to_first_tool_audio_ms`；`max_queue_depth`、`merged_segments`、
  `duplicate_sequences`、`stale_generation_dropped`。
- `collector.mjs` —— 摄入整条链路的结构化日志，做时序对齐后计算指标并输出
  三条不变量违规。

**Stage-3 流式投影器（ESS-1069）的接入契约**：qwen-audio-agent 的
CodexStreamProjector 必须发出 `codex.first_chunk` / `codex.chunk` /
`segment.flush` / `tts.first_audio` / `tool.started` / `tool.result` 这些事件名
并携带上述关联字段；名字已在本仓库 `correlation.mjs` 的 `AGENT_EVENT_MAP`
里预先钉死，投影器照此落地即可被同一 collector 计算指标，无需二次协商。

## 4. 合入前清单（PR author 必须逐项勾选）

- [ ] `AudioRealtimeGateway`: `npm run test:gate` 全绿。
- [ ] 若改了 `realtime-session.mjs` / `server.mjs`：`npm test` 覆盖新增/受影响路径。
- [ ] 若新增/修改事件名或关联字段：同步更新 `observability/correlation.mjs` 与对应测试。
- [ ] 三个场景 + 六故障的 `--json` 报告已附在 PR 描述中（`node smoke/realtime-e2e-gate.mjs --faults --json`）。
- [ ] 真机门禁清单（`Docs/realtime-device-gate.md`）已交真机责任人，等待回贴证据。
- [ ] 非作者复审通过；集成责任人明确（毕玄-cx）。

## 5. 尚未自动化的项（已知缺口）

| 缺口 | 原因 | 归属 |
|---|---|---|
| `--live` 模式未纳入 CI | 需要真实 qwen-audio-agent + DashScope + Codex ACP，CI 环境无凭据 | 真机/目标环境门禁（见真机清单） |
| 流式四指标在 live 模式尚未产出 | 依赖 Stage-3 CodexStreamProjector（ESS-1069）发出事件 | 毕玄-cx |
| 真机播放 300ms 打断 | 需要硬件音频回路，CI 无法复现 | 真机门禁（ESS-1070） |
