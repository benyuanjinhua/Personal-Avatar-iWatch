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

1. **committed 回合 deadline**（`agent_response_timeout_ms`，默认 12000ms，与 ESS-37 的
   `first_event_timeout_ms` 同源同值）：commit **真正发到上游 socket**那一刻起表（排队中的 commit 在
   `voice.ready` 冲刷时起表，慢握手不吃回答预算），第一帧 `audio.delta` / `audio.done` / `error` 到达即撤表。
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
| `upstream_response_timeout waited_ms≈12000 ownership_state=active` | 我们仍是 owner，上游自己不回答——问题在 qwen/provider 侧 |
| 什么都没有，客户端先断 | 断链先于超时，归「Watch 会话未保活」姊妹单 |

## 5. 遗留

- 超时后**不重放**：只失败一次（retriable），不像 ESS-37 那样重建 + 幂等重放。真机确认根因之前不加这层复杂度。
- `agent_response_timeout_ms=12000` 是沿用 ESS-37 的经验值，不是本次实测值。若真机显示客户端等待耐心短于
  12s，这个值要连同客户端耐心一起调，否则错误帧会发给一个已经走掉的客户端。
