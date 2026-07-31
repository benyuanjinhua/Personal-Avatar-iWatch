# ESS-37 取证报告：Bridge→qwen-audio-agent Realtime WS 停摆（event_count=0）

日期：2026-07-31（UTC 时间戳；本地 = UTC+8）
取证对象：真机事故（白梦林 iPhone → Mac Bridge → qwen-audio-agent v0.9.1 @ 127.0.0.1:3101）

## 1. 事故时间线（bridge.log + state/turn-ledger.json 重建）

| UTC | 事件 |
|---|---|
| 09:07:47 | Bridge 重启（当日第 3 次），监听 127.0.0.1 / 100.80.229.218:8443 |
| 09:08:34 | iPhone 配对成功后一次性 flush 积压 outbox：**6 条 turn 同时受理**（24–42KB 音频），全部进入 supervisor 串行注入队列，且 6 条的 300s work deadline **同时起表** |
| 09:08:36→09:10:36 | 队头 turn 注入后**零事件**，烧满 120s turn 超时 → `ERR_REALTIME_TIMEOUT`，F2 watchdog 回收重建 WS |
| 09:10:36→09:12:37 | 第二条注入（重建后的新会话）**仍零事件**，再烧 120s → `ERR_REALTIME_TIMEOUT` |
| 09:13:34–09:13:40 | 剩余 4 条尚未轮到注入即 300s work deadline 到期 → 批量 `ERR_WORK_TIMEOUT`（头部阻塞拖死整队） |
| 09:13:43 | 第 7 条（019fb773…，52,206 B）受理；队列已排空 + 会话已再次重建 |
| 09:15:50 | 第 7 条 **completed**（127s，直答路径）。账本 `event_count=0` 但实际有事件流——见 §3 取证缺口 |

注：issue 描述中「最新请求仍卡住」对应的 019fb773 实际在 09:15:50 达到 completed 终态；用户感知卡住的窗口正是前 6 条批量超时 + 本条 127s 长尾。

## 2. 根因

### 2.1 直接根因证据（本轮实测，17:52 本地）

对真网关以独立 deviceId 连接，网关回播：

```
voice.ownership state=busy
holder={type:"cli", label:"watch-bridge", instanceId:"bridge_6cc181c0-…"}
```

语音所有权被**另一个 watch-bridge 实例的连接**占有。结合网关 v0.9.1 源码（`server/src/voice/realtime-gateway.mjs`）：

1. **非 owner 的 `audio.append` 被静默丢弃**（L1269-1272：`if (!inputEnabled || !activeVoiceClients.isActive(...)) return`）——不回错误帧、不回任何事件。这是「注入后零事件」的黑洞机理。
2. **非 owner 连接拿不到 `voice.ready`**（L1232：仅 `inputEnabled||outputEnabled` 才 `ensureFrontend()`）。
3. **provider（DashScope）侧可恢复性错误被吞掉**（L1141：`isRecoverableRealtimeInactivityError` 为真时不下发 error 帧），provider 静默重连期间到达的音频被 `pendingAudio` 截尾——客户端完全无感。
4. **网关在客户端 WS close 时同步销毁上游 DashScope frontend 并释放所有权**（L1333-1351）——这是「销毁重建 WS = 全新上游会话」自愈路径成立的依据。

### 2.2 停摆为何不自愈（Bridge 侧缺陷）

- 停摆唯一的检测手段是 120s turn 超时（F2 watchdog），检测太慢；
- 6 条积压的 300s deadline 在**受理时**同时起表，串行队列每条烧 120s → 头部阻塞批量超时；
- `voice.deactivated`（被其他前台/残留实例夺走所有权）后旧实现不清 `voiceReady`，后续 turn 继续盲注黑洞（该项与并行 ESS-36 修复互补，见 §5）；
- supervisor 的 journal（ws close code、error 帧、事件摘要）**不落 bridge.log**，账本 `event_count` 只统计后台 SSE 事件、从不统计 Realtime 事件——真机停摆后无据可查（本次取证只能靠复现）。

## 3. 修复（本 PR）

| 要求 | 实现 |
|---|---|
| 1. 注入前健康预检 | `probeSession()`：`unmute` → 等 `voice.ownership` 回播（网关对 unmute 必回播，幂等、不触发模型调用）。预检失败 → 先重建再检，仍失败 → 快速失败 `ERR_REALTIME_STALLED`，**绝不盲注** |
| 2. 零事件 watchdog | 注入开始后 `first_event_timeout_ms`（默认 12s）内零网关事件 → 判停摆，销毁重建 WS 并以**同一幂等键**重放当前 turn（`max_turn_attempts`，默认 2 次），不等 120s/300s |
| 3. 队列排空 | 停摆/断链快速失败 + 重放上限 → 单条 turn 最坏 ~30s 内出终态；实测 3 条积压对全停摆网关 1.9s 内全部终态（旧行为 ≥3×120s） |
| 4. 根因取证 | supervisor journal 全量落 bridge.log（`evt:"rt"`，含 ws close code/reason、error 帧、probe/stall/rebuild；audio.delta 只计数）；账本 `event_count` 现在统计 Realtime 事件；本报告 |
| 5. 断链自愈 | WS 中途断链（掐线）→ 立即失败当前 turn（可重放）→ 重建后重放，终态恰一次；`voice.deactivated`（真实用户抢占）不重放 |

新增配置键（均有代码默认值，旧 config.json 不需改）：`probe_timeout_ms=3000`、`first_event_timeout_ms=12000`、`max_turn_attempts=2`。
新增错误码：`ERR_REALTIME_STALLED`（重放仍失败 / 重建后会话仍无响应）。

## 4. 验证

- **协议级回归** `test/selfheal.test.mjs`（4 项）：零事件停摆→重建→重放成功；死会话预检重建、坏会话零注入；持续停摆快速失败+积压 1.9s 排空；中途掐线→重放→终态恰一次（close code 1006 入日志）。
- **全量回归**：Bridge 22/22（含既有 D1/F2/ESS-34 用例），projection 12/12，Swift 66 XCTest + 5 Swift Testing 全过。
- **真网关验证** `test/ess37-live.mjs`：连续 ≥5 轮 turn（第 3 轮故意掐 WS）。首轮运行即取证到 §2.1 的 ownership busy 证据（当时并行 ESS-36 验证进程持有所有权，属预期互斥）。

## 5. 与 ESS-36 的关系

ESS-36（同日并行修复）覆盖所有权维度的根因：watch-bridge 残留实例自动 takeover（否则 Bridge 重启后死锁 busy）、`voice.deactivated` 清 `voiceReady`、announcement 与 turn 隔离。本 PR 覆盖会话活性维度：预检、零事件 watchdog、幂等重放、队列排空、取证落盘。两者互补，合并时以 supervisor.mjs 为冲突点逐段取并集。

## 6. 遗留

- 网关侧（qwen-audio-agent）对非 owner append 静默丢弃、吞掉 provider 可恢复错误——属上游行为，Bridge 已按「不可信上游」防御；如可改上游，建议非 owner append 回错误帧。
- 300s work deadline 在受理时起表（而非轮到注入时）：大批积压时尾部条目可用时间被队头挤占。本轮通过快速失败缓解；如需彻底解决，deadline 应改为出队时起表（行为变更，需产品口径确认）。
