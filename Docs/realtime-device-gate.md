# Realtime 全链路真机门禁清单（ESS-1071）

> 本文是 ESS-1071 验收第 4 条的「真机门禁清单」。CI 门禁（
> `Docs/realtime-ci-gate.md`）覆盖可机器判定的部分；本清单覆盖必须依赖真实
> 设备 / 真实上游的部分，用于「白梦林」真机验证交接（父单 ESS-1057 最终验收）。

## 1. 前置条件（必须满足才能开跑）

- [ ] 目标环境 qwen-audio-agent 运行 SHA 与 main 一致（含 ESS-1066 会话自愈、
  ESS-1067 委派路由、ESS-1069 流式投影器）。
- [ ] AudioRealtimeGateway 运行 SHA 与 main 一致；`gateway_ready` 日志带
  `git_sha` + `git_clean: true`。
- [ ] 单网关单机器（`ERR_VOICE_BUSY` / `ERR_VOICE_OWNERSHIP_LOST` 时读
  `upstream_ownership` 的 `holder_label` / `holder_instance_id` 定位）。
- [ ] Watch/iPhone 构建来自 main（含 ESS-1070 流式播放/打断改动）。

## 2. 三场景一键执行（回放或真机语音）

对每个场景记录：request_id / session_id / 起止时间 / 终端类型（done/error）/
`codex_first_chunk_ms` / `commit_to_first_tool_audio_ms`。取证命令：

```bash
# 真实上游回放（无需设备，先验服务端）：
node smoke/upstream-turn-capture.mjs --prompt "现在几点" --runs 1
node smoke/upstream-turn-capture.mjs --prompt "杭州今天天气怎么样" --runs 3
node smoke/upstream-turn-capture.mjs --prompt "我的分身知识库有哪些内容" --runs 3
```

| 场景 | 预期 | 真机证据要求 |
|---|---|---|
| 现在几点 | Qwen 直答，不创建 Codex task；`codex_first_chunk_ms == null`；单段 done | 日志 `routeDecision=direct` + 时序 |
| 杭州天气 | 委派 Codex；边生成边播（多段 `audio.segment_done`）；最终为答案或明确失败；不卡「正在查询」 | 连续 3 次，每次有真实结果或 `failed/hasError=true` |
| 我的分身知识库 | 同上 | 连续 3 次，每次有真实结果或明确失败 |

## 3. 故障注入（服务端可控注入 + 设备观察）

| 故障 | 注入方式 | 设备侧预期 |
|---|---|---|
| provider 4xx | qwen-audio-agent 注入 `invalid_id_prefix` | 自动换 session 重试一次；重试耗尽为 `failed/hasError=true`；原始错误 JSON 不进 speech / recent voice context |
| 迟完成 | 让后台 task 超过受理回合收口后完成 | 结果经后续通知送达；只消费一次；无跨会话串台 |
| TTS 失败 | 注入 TTS 错误 | 明确失败提示，不朗读原始错误 |
| WSS 断线 | 断网 10s 后恢复 | 当前 turn 有界失败；重连后新 turn 正常 |
| 队列积压 | 上游突发大流 | Gateway 有界失败（ERR_DOWNLINK_BUDGET），不无界增长 |
| barge-in | 播放中再次说话 | 300ms 内停止旧 generation；旧 chunk/audio 全部丢弃 |

三条跨组件不变量在真机上同样成立：无静默结束、无跨会话串台、无提前 done。

## 4. 真机证据回贴格式

每项证据至少包含：

```
- 场景/故障：杭州天气
- request_id / session_id / taskId：
- 终端类型：done / error(code=…) / cancelled
- 关键指标：codex_first_chunk_ms / commit_to_first_tool_audio_ms / 队列深度
- 日志定位（服务端 JSONL grep 键）：
- 结论：通过 / 不通过（原因）
```

证据统一回贴父单 ESS-1057；全部通过后才可关闭父单。

## 5. 完成判定

- [ ] 三场景各 3 次真机运行全部得到「真实结果或明确失败」。
- [ ] 六故障注入全部无静默结束、无跨会话串台、无提前 done。
- [ ] 播放中打断 300ms 内停旧 generation（ESS-1070 证据）。
- [ ] 稳定 / 临时不可达 / 后台恢复三类设备状态均有行为证据。
- [ ] 目标环境运行 SHA 与 main 一致，可回滚。
- [ ] 证据回贴父单 ESS-1057，并关闭父单。
