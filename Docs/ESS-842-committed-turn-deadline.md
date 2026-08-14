# ESS-842：`uplink_committed` 之后的空洞——已提交回合的终止条件

日期：2026-08-14
事故：白梦林真机（request_id `019ffe80-5d6d-766a-9cab-6319089cb490`，12:20:53～12:21:13 Asia/Shanghai）
语音已完整上行并 commit（93 帧），此后没有任何 ASR final / 回答下行，客户端等到 1006 断开。

## 1. 代码事实（L2）

| 事实 | 位置 |
|---|---|
| 上行 commit 之后，Gateway 对「上游一句话都不回」**没有任何时限** | `AudioRealtimeGateway/realtime-session.mjs` `_handleAudioCommit`；`qwen-agent-transport.mjs` 的定时器只有 connect / done-settle / reorder-gap 三个 |
| `voice.ownership state=busy` 只在 `!turn.ready` 时判失败；ready 之后所有权丢失被忽略 | 修复前 `qwen-agent-transport.mjs` 第 364 行 |
| `voice.deactivated` 完全未处理 | 同上（上游有此事件，见 `MacRemoteFrontendBridge/server.mjs` 的 `RT_GATEWAY_EVENTS`） |
| 上游对**非 owner** 的 `audio.append` 静默丢弃、不回错误帧 | ESS-37 §2.1（对 qwen-audio-agent v0.9.1 源码取证） |

三条叠加的后果就是本次现象：一旦所有权在 commit 前后易主，Gateway 会把音频送进黑洞，
而**上下游都不会产生任何事件**——事故日志里 commit 之后的那段空白，不是"没记录"，是真的没有终止条件。

## 2. 判定强度（按 R-04.3）

- **已确认**：committed 回合缺终止条件（L2，见上表）；这是"客户端只能干等到 1006"的充分原因。
- **强嫌疑、未确认**：本次具体是**所有权易主**导致的静默丢弃。Bridge 在同一时间窗（12:20:53～12:21:02）
  收下了同一句话的 AAC 上行流，两条链路都指向单 owner 的 qwen 实例；时间上 `voice_uplink_stream_ended`
  比 `uplink_committed` 早约 1 秒。**但缺 qwen 侧与 Bridge `evt:"rt"` journal 的所有权证据，不能写成根因。**
  本 PR 新增的 `upstream_ownership` 日志就是为了让下一次真机复现直接给出这个答案。
- **已排除**：客户端 `request.timeoutInterval = 10s`（`Shared/AudioRealtimeAgentTransport.swift:118`，与
  10.15s 的断开间隔吻合）导致 URLSession 掐断长连接。实测反证：macOS 26 / Swift 6.3 上
  `URLSessionWebSocketTask` 以 `timeoutInterval=3` 连一个全程静默的 WSS 服务端，25 秒后连接仍然存活
  （`didOpen` 之后无 `didCompleteWithError`），说明该值不是已建立连接的空闲超时。1006 另有其因，
  与「Watch 会话未保活」姊妹单一起查。

## 3. 本 PR 的修复

1. **committed 回合 deadline**（`agent_response_timeout_ms`，默认 8000ms）：commit **真正发到上游 socket**
   那一刻起表（排队中的 commit 在 `voice.ready` 冲刷时起表，慢握手不吃回答预算），第一帧
   `audio.delta` / `audio.done` / `error` 到达即撤表。
   到期 → `ERR_UPSTREAM_NO_RESPONSE`（retriable）+ `upstream_response_timeout` 日志（带 waited_ms、
   upstream_ready、ownership_state），并关闭上游 socket——按 ESS-37 §2.1 第 4 条，关闭即释放上游所有权，
   下一回合拿到的是干净会话。
2. **所有权丢失即失败**：ready 之后收到 `voice.deactivated`，或 `voice.ownership state=busy` 且持有者不是
   自己 → `ERR_VOICE_OWNERSHIP_LOST`（retriable），错误里点名持有者。自己的所有权回播（holder 是本连接）
   不误杀。
3. **所有权取证**：每一条 ownership 事件都落 `upstream_ownership`（state / holder_label / holder_is_self /
   upstream_ready）。持有者是 client label，不是凭据，可安全入日志。

契约上这三条都落在"失败要显式"这一侧：**绝不为一个没有回答的回合伪造 `audio.done`**，客户端拿到的是
带 code 的 `error` 帧 + `close_code=1008 reason=<code>`，而不是一条永远不说话的 socket。

## 4. 下一次真机怎么读日志

commit 之后按 request_id grep 这几个事件，三选一必然命中：

| 看到 | 结论 |
|---|---|
| `upstream_ownership ... holder_is_self=false` / `state=deactivated` | 所有权被抢，§2 的强嫌疑成立 |
| `upstream_response_timeout waited_ms≈8000 ownership_state=active` | 我们仍是 owner，上游自己不回答——问题在 qwen/provider 侧 |
| 什么都没有，客户端先断 | 断链先于超时，归「Watch 会话未保活」姊妹单 |
| 客户端 `await_response_timeout` | 连 Gateway 都没说话，先查这条 WSS 本身 |

## 5. 两端等待预算的相对时序（ESS-844 阻断项 1）

deadline 只有在**错误帧还能送到一个仍在线的客户端**时才有意义。事故里唯一实测到的客户端存活窗口是
10.153s（`uplink_committed=12:21:03.156` → `peer_closed=12:21:13.309`），12s 的 deadline 落在窗口之外——
同一时序复现时客户端先走，新增的 error/1008 谁也收不到。因此两端预算按下面的顺序钉死：

```
Gateway deadline 8s  +  送达余量 1.5s  =  9.5s   <   实测客户端窗口 10.153s   ≤   客户端等待预算 15s
```

- Gateway 侧：`agent_response_timeout_ms=8000`（`AudioRealtimeGateway/config.json`），
  由 `test/ess842-response-deadline.test.mjs` 直接读出厂配置断言 `deadline + 1500ms ≤ 10153ms`。
- 客户端侧：`AudioRealtimeAgentConfig.responseWaitTimeout=15s`，commit 真正发出时起表，
  首帧 `audio.delta` / `audio.done` / `error` / `cancel.ack` 撤表；耗尽则记
  `await_response_timeout` + `ERR_CLIENT_AWAIT_RESPONSE_TIMEOUT` 并**带 reason 关闭**，
  由 `AudioRealtimeAgentSessionTests.testResponseWaitBudgetOutlastsGatewayDeadline` 钉住顺序。

**为什么客户端预算更长**：知道「为什么没有回答」的是 Gateway，客户端唯一该做的是等它说完。客户端这条
预算只在连 Gateway 都不说话时才触发，触发时也只是把裸 1006 换成一条可 grep 的明确原因。

### 5.1 下界同样要有实测依据（并入 PR #325 的取证）

上面那条只把 deadline 从**上面**卡住（不能太晚）。只有上界的话，3s 也能满足它，却会当场制造一个
把正常回答砍半的新缺陷——所以下界必须同等强度地钉住。

数据窗口：`gateway.log.20260810 / 0811 / 0812` 三个轮转；样本量 n=9（窗口内全部成功回合）；
口径：`uplink_committed` → 首个 `upstream_audio_delta`：

```
0.17  0.63  1.09  1.11  1.15  1.75  1.80  2.81  3.46   (秒)
```

最慢 3.46s，8s ≈ 2.3 倍。测试改为断言 `deadline ≥ 2 × 3460ms`，取代原先没有依据的 `≥ 5000ms`。

按 R-04.4：**n=9 是局部窗口，不是分布**，不得当成普遍规律。这正是 deadline 做成配置项
`agent_response_timeout_ms` 而不是写死常量的原因，也是 §6 要求真机 5 轮之后回看 TTFT 分布的原因。

## 6. 遗留

- 超时后**不重放**：只失败一次（retriable），不像 ESS-37 那样重建 + 幂等重放。真机确认根因之前不加这层复杂度。
- 8s / 15s 都是从**一次**事故窗口推出来的，不是分布。真机连续 5 轮跑完后应回看 TTFT 分布：若 P95 首帧
  逼近 8s，deadline 与客户端预算要一起上调，顺序不变。
