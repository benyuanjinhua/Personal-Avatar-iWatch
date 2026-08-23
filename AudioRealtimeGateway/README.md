# Audio Realtime Agent Gateway (ESS-403)

Secure WSS entry that lets iPhone (and, transitively, Watch) speak realtime
audio directly with the upstream Agent, without routing media through the Mac
Remote Frontend Bridge. This is the server-side half of the ESS-388 direct
link: Bridge persists complete-file fallback jobs and submits them through the
Gateway's loopback HMAC API; it never opens a second qwen voice owner.

Fallback recovery is **at-least-once with `request_id + audio_sha256`
idempotent acceptance**. A queued job survives restart. If the Gateway crashes
after upstream execution starts but before the terminal result is persisted,
the `executing` record is requeued and automatically replayed with the same
request id. This prioritizes not losing the answer; because qwen-audio-agent
has no result lookup/transaction API, the narrow crash window may produce a
duplicate answer and is not claimed as exactly-once.

The queue resets the queue-wait budget when an interrupted `executing` record
is recovered, so a production-length restart cannot immediately time it out.
`failed` and `timed_out` records may be resubmitted with the same request/audio
hash; they retain their attempt count and re-enter the queue. Successful,
cancelled, and completed-turn rejection records remain terminal/idempotent.

## Red lines (from ESS-388 v_final / ESS-403)

- Clients (iPhone/Watch) never hold long-lived Agent or provider keys. Only
  device credentials pinned in Keychain and short-lived, single-use tokens
  minted by this Gateway ever leave the server side.
- Every media event carries `session_id`, `request_id` (a.k.a. `turn_id`),
  `response_id`, `generation`, and a monotonic `sequence`. `audio.done`
  carries `final_sequence`. Old-generation frames are dropped and counted as
  `stale_generation`.
- Server-authoritative cancel: on `cancel`, the current generation stops
  emitting deltas immediately, the client gets `cancel.ack`, and any late
  agent frames for that generation are discarded server-side.
- Every handshake, first-uplink, first-downlink, done, cancel, and disconnect
  is emitted as a structured log record with `request_id` + `session_id` so
  a single turn can be reconstructed end-to-end.
- No provider key or ephemeral token is ever written to logs.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/v1/health` | none (source-gated) | Liveness / build metadata |
| POST | `/v1/realtime/session-token` | HMAC device signature | Mint an ephemeral session token bound to a specific `device_id`, `session_id`, `request_id`, `generation`. |
| POST | `/v1/realtime/session-token/revoke` | HMAC device signature | Revoke a previously issued token before use (safety valve). |
| WSS | `/api/realtime` | Bearer <token> | Realtime bidirectional media plane. Token is single-use (single upgrade). |

The service listens over TLS (`wss://`) and honours an IP allowlist
(loopback + Tailnet CIDRs). Development-only `ws://` mode requires the
explicit config flag `dev_allow_plain_ws: true` and refuses to start on any
public address. Production defaults reject plain WS.

### Ephemeral session tokens

`POST /v1/realtime/session-token`

Request body (HMAC-signed with per-device shared secret, see `## Auth`):

```json
{
  "protocol_version": 1,
  "device_id": "jackson-iphone",
  "session_id": "session_...",
  "request_id": "req_...",
  "generation": 1,
  "ttl_ms": 30000
}
```

Response (201):

```json
{
  "token": "rtk_<opaque>",
  "expires_at": 1723145678901,
  "ttl_ms": 30000,
  "scope": {
    "device_id": "jackson-iphone",
    "session_id": "session_...",
    "request_id": "req_...",
    "generation": 1
  }
}
```

Semantics:

- The token is a random 32-byte opaque string; only its SHA-256 is stored
  server-side. It authorises **one** WSS upgrade whose query string /
  `Sec-WebSocket-Protocol` payload matches the pinned scope exactly.
- `ttl_ms` is clamped to `[1_000, max_token_ttl_ms]` (default 90 s per
  ESS-388 A1). Tokens are burned on first upgrade attempt (success or fail).
- Generation is monotonic per (device_id, session_id): the issuer refuses to
  step backwards. Barge-in sends `generation + 1`.
- Failure returns a structured JSON envelope with a stable `code` and never
  echoes the token or provider key.

`POST /v1/realtime/session-token/revoke` accepts the token id (SHA-256
prefix, 8 hex chars) and burns any matching unused token.

### WSS `/api/realtime`

Client sends the token in `Authorization: Bearer rtk_...` and pins scope in
query string (`?device_id=...&session_id=...&request_id=...&generation=...`).
All four fields are required; the server reads them verbatim from the URL and
rejects the upgrade with `ERR_TOKEN_INVALID` if any of the four disagrees with
the token's pinned scope (see `server.mjs` `presentedScope`).

Server verifies token scope matches the URL, burns the token, then upgrades.

#### Framing

All frames are JSON text messages. Binary frames are rejected with
`ERR_UNSUPPORTED_BINARY`.

Every non-`ping`/`pong` frame includes these five fields:

- `session_id` (string)
- `request_id` (string)  — the turn id
- `response_id` (string, optional until first server-produced response)
- `generation` (integer, monotonic per session)
- `sequence` (integer, monotonic within a generation for `audio.*`)

Additional per-type fields are described below. Fields not listed are
rejected as `ERR_UNKNOWN_FIELD` (strict schema — the contract must be
verifiable).

#### Client → Server events

| type | Body | Notes |
|---|---|---|
| `session.start` | scope + `protocol_version` | Must be first message. Establishes the session. Server replies `ready` on success. |
| `audio.append` | `sequence`, `audio` (base64 PCM16LE 16 kHz mono), `codec?` (must be `"pcm_s16le"` if present), `sample_rate?` (must be `16000` if present) | Sequences must be monotone and dense (no gaps within a turn). `codec` and `sample_rate` are optional — omitting them selects the same defaults. A different literal is rejected with `ERR_UNSUPPORTED_CODEC` / `ERR_UNSUPPORTED_SAMPLE_RATE`. |
| `audio.commit` | `sequence` (last accepted) | Ends the uplink for the current turn. |
| `cancel` | `reason?` | Cancels the current `generation`. Server responds with `cancel.ack` and stops emitting deltas for the cancelled generation. |
| `playback.started` | `response_id` | Client reports first sample rendered. |
| `playback.ended` | `response_id` | Client reports last sample consumed. |
| `ping` | `nonce` | Heartbeat probe. Server replies `pong`. |
| `close` | `reason?` | Graceful close. |

#### Server → Client events

| type | Body | Notes |
|---|---|---|
| `ready` | echoes scope, adds `heartbeat_interval_ms` | Sent once after `session.start` is accepted. |
| `audio.delta` | `sequence`, `sample_rate`, `codec`, `audio` (base64 PCM16LE 24 kHz) | Sequences are monotone and dense per `response_id`. |
| `audio.segment_done` | `segment_index`, `final_sequence` | **本段结束，回合未结束**（ESS-969）。同一屏障语义，但客户端应保持本轮打开、退回等待态（Watch：`SessionController.markAnswerInterim`），不得开下一轮。未实现的老客户端忽略该帧即可——后续 `audio.delta` 与最终的 `audio.done` 不受影响。 |
| `audio.done` | `final_sequence` | Barrier — client waits until it has seen every `0..final_sequence` before signalling playback complete. **回合终态**：一个回合有且只有一帧。 |
| `cancel.ack` | echoes scope + `cancelled_response_id?` | Response to a `cancel` message. |
| `error` | `code`, `retriable`, `detail?` | Structured failure; connection is closed with WebSocket code 1008 unless `retriable: true`. |
| `pong` | echoes `nonce` | Heartbeat reply. |

Server-initiated `ping` frames from `ws.ping()` are honoured but the
protocol also supports the JSON `ping`/`pong` pair for platforms that can't
inspect control frames.

#### Ordering / dedup guarantees

- Duplicated `sequence` values (same `generation`, same direction) are
  silently dropped and logged as `duplicate_sequence`.
- Out-of-order client uplink is rejected with `ERR_STREAM_SEQUENCE` (the
  client is expected to reserialise before send).
- Server downlink is emitted in strict monotone order per `response_id`; the
  client is allowed to reorder a small window (implementation-specific).
- `audio.done` carries a `final_sequence` value. **Server guarantee:**
  the emitted `final_sequence` equals the largest `N` such that every
  `0..N` delta has already been sent — the client can therefore treat
  `final_sequence` as an unconditional completion barrier without
  auditing density itself. If the upstream reports a `final_sequence`
  higher than the emitted-so-far dense prefix (because a delta was lost
  or the tail delta never arrived), the server clamps the emitted
  `final_sequence` down to the dense prefix and logs
  `done_barrier_clamped` with `reason` in {`gap_before_final_sequence`,
  `final_sequence_not_yet_emitted`}. A response that produced zero
  contiguous deltas ends with `final_sequence == -1`.

#### 多段回合（ESS-969）

一个回合可以承载多段回答：工具调用回合先说「我正在查询…」，跑工具，再说
真正的答案。上游的 `audio.done` 是**段落**边界，不是回合终态。

- **上游没有回合终态信号**（ESS-990 取证）。`voice.state {state:'idle'}` 曾被
  当作终态（ESS-969 / PR #365），实测推翻：真实上游在**每一段** `audio.done`
  之后 0.14–0.54 ms 内就发 idle，10/10 的工具调用回合在首条 idle 之后又开了
  新段。L2 也一致——上游 `server/src/voice/realtime-gateway.mjs` 在
  `finishPlayback` / `cancelPlayback` 每段播完发 idle，`shared/realtime-events.mjs`
  的 `GatewayServerEvent` 只有 `turn.started`，没有任何 turn 终态事件。
  取证脚本：`smoke/upstream-turn-capture.mjs`。
- 因此回合终态只能用**段落收口后的有界空闲窗口**（启发式，R-04.4）：段落
  `audio.done` settle 之后挂起，窗口内没有新的 `response.started` / 音频就收口
  （`upstream_turn_terminal reason=segment_gap`）。socket 关闭 / 错误 / supersede
  仍然立即收口。
- 下游序号在整个回合内单调稠密，跨段连续，所以稠密前缀屏障对段落边界与
  回合终态同样成立。
- `agent_multi_segment_mode`：`auto`（默认）只对**已证明上游会发 `voice.state`**
  的回合启用新语义（把 idle 当方言指纹用，不当终态用）；没有该信号的回合
  逐字节保持 ESS-969 之前的行为。`always` / `off` 强制两侧。每个回合落一条
  `upstream_turn_terminal_mode` 日志，直接说明本次走了哪条分支。
- `agent_segment_gap_ms`（默认 2500）/ `agent_segment_gap_busy_ms`（默认 12000）：
  空闲窗口的基础档与延长档。标定样本 = 2026-08-22 真实上游 10 个工具调用回合、
  n=17 个回合内段落间隔：min 326.6 / p50 1171.2 / p90 4143.4 / max 7332.5 ms；
  其中所有 > 1194.7 ms 的间隔都伴有「声道忙」的显式证据（后台播报在途或
  未终结 task），所以有证据时才用延长档。
  取样口径要连着结论一起读：取证脚本按 Bridge 的方言回了 `playback.started` /
  `playback.ended`，而本网关**不回回执**，上游据此决定何时开下一段，所以真机
  Watch 链路上的间隔分布可能与这 17 个样本不同；n=17 也仍是薄样本（R-04.4）。
  两个值因此都是配置项，并继续用 `upstream_turn_terminal` 的
  `gap_ms` / `window_ms` / `outstanding_tasks` 累积样本。
  与客户端预算的关系（**不是**「两个 45 s 相等所以客户端总是抢先」——那条因果
  已在 ESS-1004 复审中被推翻并撤回）：本窗口在**段落收口**时起表，Watch 的
  `SessionController.thinkingHardTimeoutSeconds = 45` 要等收到 interim 才起表，
  因此本窗口天然早于客户端，12 s 距客户端预算仍有充足余量。
  旧的 `agent_turn_idle_backstop_ms = 45000` 是 ESS-969 的未标定占位值，
  已由上面两个标定值替换（删除的理由是「没标定 + 判据换了」，不是时序竞争）。
- `agent_tool_call_window_ms`（默认 30000，ESS-1043）：工具调用窗口。上游 qwen
  `response.done` 携带 `hasFunctionCall`；为 true 时模型已决定调用工具，真正的
  答案段要在工具执行（实测 8–16 s，远超上面两档）之后才到。此时挂起的段落改用
  本窗口，而不是用普通空闲窗口把回合提前收口。工具结果段的 `response.done`
  （`hasFunctionCall=false`）一到，回合在其音频 settle 后立即收口
  （`upstream_turn_terminal reason=tool_result_done`）。30 s ≈ 1.9x 实测上限，
  仍早于 Watch 的 45 s 硬思考超时，工具结果丢失时也有界兜底（按 segment_gap
  收口），不会把回合永远挂住。
- **task 生命周期只延长窗口，不否决收口**：`task.accepted` 实测比第一段
  `audio.done` 晚 795–8689 ms（n=10），护不住第一段；而 task 常比回合多活
  30–70 s，「有未终结 task 就不收口」会把每个工具回合挂到客户端硬超时。
- **播报结果归属与投递（ESS-1068）**：`origin=announcement` 的后台播报不再
  一律隔离。以 `taskId` 为首期归属键、按 task 的 session/device 与当前 turn
  对齐（播报自带的 `task.sessionId` 优先，其次 `task.*` 事件建立的 taskId→
  身份表）——归属明确的播报音频/文本作为新段落下发，并按 taskId 去重只消费
  一次；无归属或跨 session 的播报继续隔离（ESS-849 安全默认）。task 身份与
  已投递去重按 conversation（device+session）跨 turn 持久化，前一轮受理后
  关闭、后台任务 30–70 s 后才终结的结果，仍能在下一轮归属并只消费一次。
  播报/task 结束后清除 busy 使直答回合回落到 `agent_segment_gap_ms` 基础
  窗口，不再被锁在忙档。

#### Barge-in

Client sends `cancel` for the current `generation`, then immediately opens a
new WSS handshake with a fresh token for `generation + 1`. Old-generation
late frames arriving on the previous connection are dropped (`stale_generation`).

#### Heartbeat / timeouts

- Server sends WS-level `ping` every `heartbeat_interval_ms` (default
  `15000`).
- No traffic for `idle_disconnect_ms` (default `60000`) → server closes with
  code `1001` and `ERR_IDLE_TIMEOUT`.
- Rate limits: max frames per second (`max_events_per_second`, default 200)
  and max bytes per frame (`max_frame_bytes`, default 64 KiB). Excess → close
  with `ERR_RATE_LIMIT`.

#### Downlink budget and backpressure (ESS-746)

The server→client path is bounded at every hop, so neither a misbehaving
upstream nor a Watch that stopped draining can grow the process without limit.

- **Upstream frame validation.** An `audio.delta` whose payload is not base64,
  or is larger than `max_downlink_frame_bytes`, fails the turn immediately
  (`ERR_UPSTREAM_FRAME_INVALID` / `ERR_UPSTREAM_FRAME_SIZE`, both retriable)
  rather than being forwarded or dropped into a hole the done barrier could
  only resolve by timing out.
- **Per-turn / per-session budget.** More than `max_downlink_frames` frames or
  `max_downlink_bytes` bytes in one response ends it
  (`ERR_UPSTREAM_BUDGET_EXCEEDED` upstream-side, `ERR_DOWNLINK_BUDGET`
  session-side, non-retriable). `max_downlink_frames` doubles as the sequence
  window — a `sequence` or an upstream-claimed `final_sequence` at or beyond it
  can never complete a legal dense prefix, so it is refused on arrival instead
  of after the 30 s barrier gap. This window is what bounds the per-session
  dedup set of seen sequences.
- **Slow consumer.** Before each downlink frame the socket's `bufferedAmount`
  **plus the frame about to be queued** is checked, so the cap is hard rather
  than exceeded by one frame: crossing `downlink_backpressure_warn_bytes` logs
  one `downlink_backpressure_warning`; crossing `max_downlink_buffered_bytes`
  logs `downlink_backpressure_disconnect` and closes with WS code `1013`
  (reason `ERR_SLOW_CONSUMER`), dropping every later frame. Because `close()`
  queues behind the same backlog, `terminate()` follows after
  `downlink_close_grace_ms`. Clients reconnect per turn, so a cut socket costs
  one turn.

#### Error codes (stable)

| code | HTTP / WS close | Meaning |
|---|---|---|
| `ERR_TOKEN_INVALID` | 401 / 1008 | Token unknown, mangled, or scope mismatch. |
| `ERR_TOKEN_EXPIRED` | 401 / 1008 | Token past `expires_at`. |
| `ERR_TOKEN_CONSUMED` | 401 / 1008 | Token already used for an upgrade. |
| `ERR_SCOPE_MISMATCH` | 400 / 1008 | URL scope / event scope disagrees with token. |
| `ERR_STREAM_SEQUENCE` | — / 1008 | Client uplink sequence gap or reversal. |
| `ERR_STREAM_FRAME_SIZE` | — / 1009 | Frame exceeds `max_frame_bytes`. |
| `ERR_UNSUPPORTED_CODEC` | — / 1008 | `audio.append.codec` present and not equal to `"pcm_s16le"`. |
| `ERR_UNSUPPORTED_SAMPLE_RATE` | — / 1008 | `audio.append.sample_rate` present and not equal to `16000`. |
| `ERR_RATE_LIMIT` | — / 1008 | Event-per-second / bytes-per-second cap tripped. |
| `ERR_IDLE_TIMEOUT` | — / 1001 | No traffic within `idle_disconnect_ms`. |
| `ERR_GENERATION_STALE` | — / 1008 | Event tagged with a generation the server no longer accepts. |
| `ERR_UNKNOWN_FIELD` | — / 1008 | Strict schema rejection. |
| `ERR_UNSUPPORTED_BINARY` | — / 1008 | Binary WS frame received. |
| `ERR_UPSTREAM_UNAVAILABLE` | — / 1011 | Agent transport failed. |
| `ERR_UPSTREAM_FRAME_SIZE` | — / 1008 | Upstream `audio.delta` exceeds `max_downlink_frame_bytes` (retriable). |
| `ERR_UPSTREAM_FRAME_INVALID` | — / 1008 | Upstream `audio.delta` payload is not base64 (retriable). |
| `ERR_UPSTREAM_BUDGET_EXCEEDED` | — / 1008 | Upstream exceeded the per-turn downlink frame/byte budget. |
| `ERR_DOWNLINK_BUDGET` | — / 1008 | Session downlink budget or sequence window exhausted (not retriable). |
| `ERR_UPSTREAM_NO_RESPONSE` | — / 1008 | ESS-842: no upstream response frame within `agent_response_timeout_ms` of `audio.commit` (retriable). |
| `ERR_VOICE_OWNERSHIP_LOST` | — / 1008 | ESS-842: upstream voice ownership was taken by another client mid-turn, so our audio is being discarded (retriable). The `upstream_ownership` log now carries the thief's `holder_label` and `holder_instance_id` (ESS-978). |
| `ERR_VOICE_BUSY` | — / 1008 | ESS-978: the upstream single voice slot is held by another client at connect time and the holder is not eligible for takeover — a foreign gateway instance, or a frontend while `agent_takeover_voice` is off (retriable). |
| `ERR_SLOW_CONSUMER` | — / 1013 | Client stopped draining; `bufferedAmount` passed `max_downlink_buffered_bytes`. Close reason only — no `error` frame, the socket is already backlogged. |

## Auth

`session-token` calls carry the same HMAC-SHA256 signature scheme the Mac
Bridge already uses (see `MacRemoteFrontendBridge/auth.mjs`), namely
`x-device-id`, `x-request-timestamp`, `x-nonce`, `x-body-sha256`,
`x-signature`. Each device's shared secret is stored server-side hashed;
device registration happens out of band (bootstrap import from Bridge
`devices.json` for local dev, per-device provisioning API for prod).

The WSS upgrade never accepts the device HMAC directly — clients trade an
HMAC-signed request for a scope-bound ephemeral token first, then present
that token on the socket. This keeps the WSS surface stateless w.r.t.
long-lived secrets: a WSS handler compromise cannot leak provider keys or
device secrets.

The Gateway itself holds the **provider** key (upstream Agent auth) in its
own environment (env var / secrets store); the key is never sent to clients
and never logged.

## Structured logs

Every log line is a single JSON object with `ts`, `evt`, and, when
applicable, `request_id`, `session_id`, `response_id`, `generation`,
`sequence`. Reserved secret fields (`token`, `token_sha`, `signature`,
`provider_key`) are redacted by the logger.

Key events (stable names):

- `token_issued`, `token_rejected`, `token_consumed`, `token_expired`,
  `token_revoked`
- `ws_upgrade`, `ws_upgrade_rejected`, `ws_close`
- `session_ready`, `session_ended`
- `uplink_first_frame`, `uplink_committed`
- `downlink_first_frame`, `downlink_done`
- `cancel_received`, `cancel_ack_sent`, `stale_generation_dropped`
- `heartbeat_timeout`, `rate_limit_tripped`, `agent_upstream_error`

Grepping a single `request_id` yields the whole turn:
`token_issued → ws_upgrade → session_ready → uplink_first_frame → uplink_committed → downlink_first_frame → downlink_done → session_ended`.

## Configuration

`config.json` (all values overridable via `createGateway({...})` and env):

| key | default | notes |
|---|---|---|
| `port` | `8444` | TLS bind port |
| `bind` | `127.0.0.1` | Bind address |
| `tls_cert` / `tls_key` | `./certs/gateway.crt` / `.key` | PEM paths, resolved against the module directory (see below) |
| `state_dir` | `./state` | Device registrations + nonce store, resolved against the module directory |
| `allowed_peer_ips` | `[]` | Extra allowlist entries (Tailnet CIDRs) |
| `dev_allow_plain_ws` | `false` | Only for local integration |
| `max_token_ttl_ms` | `90000` | ESS-388 A1 ceiling |
| `default_token_ttl_ms` | `30000` | Applied when client omits `ttl_ms` |
| `token_sweep_interval_ms` | `30000` | Issuer sweep cadence; started on listen, stopped on close. `0` disables (tests only). |
| `generation_ttl_ms` | `3600000` | Idle retention of the per-session monotone-generation guard |
| `max_tokens` | `4096` | Global live-token ceiling; oldest evicted past it |
| `max_tokens_per_device` | `64` | Per-device live-token ceiling — hits before the global one, so one device evicts only its own |
| `max_generation_devices` | `64` | Devices tracked by the generation guard. Fail-closed: a new device past it gets `ERR_DEVICE_CAPACITY` (429) |
| `max_generation_sessions_per_device` | `256` | Sessions tracked per device. Fail-closed: a new `session_id` past it gets `ERR_SESSION_CAPACITY` (429) |

The two generation ceilings refuse rather than evict. Evicting the coldest
entry would bound memory equally well but would reset that session's highest
generation to `0`, letting a superseded generation be re-opened inside the TTL
window (ESS-794). Refusals only ever apply to a *new* `session_id` — a device
sitting at its ceiling keeps minting for the sessions it already owns — and
clear as soon as the held entries go idle past `generation_ttl_ms`. The token
ceilings do evict, because a dropped token entry can only cause a rejection.
| `heartbeat_interval_ms` | `15000` | WS-level ping cadence |
| `idle_disconnect_ms` | `60000` | Kill idle sockets |
| `max_frame_bytes` | `65536` | Per-frame hard cap |
| `max_events_per_second` | `200` | Per-connection rate limit |
| `max_uplink_bytes_per_second` | `524288` | 512 KiB/s uplink cap |
| `max_downlink_frame_bytes` | `131072` | Largest single upstream `audio.delta` payload accepted (base64 chars) |
| `max_downlink_frames` | `4096` | Downlink sequence window + per-turn / per-session frame budget |
| `max_downlink_bytes` | `33554432` | Per-turn / per-session downlink byte budget (base64 chars) |
| `max_downlink_buffered_bytes` | `4194304` | Socket `bufferedAmount` at which a slow consumer is disconnected |
| `downlink_backpressure_warn_bytes` | `1048576` | `bufferedAmount` that logs one `downlink_backpressure_warning` |
| `downlink_close_grace_ms` | `5000` | Grace before `terminate()` when `close()` cannot drain |
| `agent_transport` | `agent` | `agent` connects the production qwen-audio-agent loopback WSS; `mock` is test-only. |
| `agent_gateway_url` | `ws://127.0.0.1:3101/api/realtime` | Existing qwen-audio-agent endpoint. Keep loopback-only. **Never run a second copy of this gateway against this default — it will silently take over the real-device voice channel (see the deployment warning below).** |
| `agent_connect_timeout_ms` | `10000` | Fail the northbound turn with a structured upstream timeout. |
| `agent_max_pending_bytes` | `2097152` | Hard cap while waiting for upstream `voice.ready`. |
| `agent_response_timeout_ms` | `8000` | ESS-842: how long a committed turn waits for the first upstream response frame before failing closed with `ERR_UPSTREAM_NO_RESPONSE`. Must stay below the client's post-commit wait budget (`AudioRealtimeAgentConfig.responseWaitTimeout`, 15 s) and inside the incident's measured 10.153 s client window — pinned by `test/ess842-response-deadline.test.mjs`. `0` disables the deadline. |
| `agent_takeover_voice` | `true` | Explicit Watch speech takes ownership from a stale/local frontend. ESS-978: takeover is two-step — the gateway first connects **without** takeover and only steals the voice slot when the current holder is its own prior connection (same process, same `clientLabel`) or an allowed frontend; a second gateway instance on the same machine is never stolen from and fails with `ERR_VOICE_BUSY`. |
| `fallback_bind` / `fallback_port` | `127.0.0.1` / `8445` | Dedicated loopback-only HTTP listener for Bridge fallback jobs; never exposed on the public TLS listener. |
| `fallback_hmac_secret_file` | `./state/fallback-hmac-secret` | Mode-0600 service credential generated by `scripts/install-launchd.sh`; the configured environment variable takes precedence. |
| `fallback_turn_state_max_entries` | `2048` | Maximum durable realtime completion tombstones retained. Persistence is asynchronously serialized and atomically renamed, rather than synchronously rewriting the table on each realtime frame. |
| `provider_key_env` | `AUDIO_REALTIME_PROVIDER_KEY` | Legacy readiness metadata only; the qwen service owns the provider credential. |

Relative paths in `tls_cert` / `tls_key` / `state_dir` are all resolved
against the **module directory** (`AudioRealtimeGateway/`, i.e. the directory
containing `server.mjs`), never against `process.cwd()`. Launching the server
from any working directory — e.g. `node /abs/path/AudioRealtimeGateway/server.mjs`
under launchd / systemd / a deploy script — behaves identically to `npm start`
(ESS-428). Absolute paths in `config.json` are honored as-is.

## Deployment (quickstart)

> **ESS-978 — single-gateway-per-machine rule.** The default `agent_gateway_url`
> is `ws://127.0.0.1:3101/api/realtime`. Anyone who starts an *unchanged*
> copy of this module on the production Mac mini — a fresh `npm test`, a
> scratch checkout, a stray dev process — used to connect with `takeover:
> true` and silently steal the real-device voice channel mid-sentence.
> Since ESS-978 the gateway only takes over a holder it can prove is its own
> prior connection (same process) or an allowed frontend, and it identifies
> itself as `watch-direct-gateway:<pid>`, so a second copy now fails with
> `ERR_VOICE_BUSY` instead of killing the live turn. Still: keep exactly one
> gateway process per machine, and when triaging `ERR_VOICE_BUSY` /
> `ERR_VOICE_OWNERSHIP_LOST`, read `holder_label` + `holder_instance_id` in
> `upstream_ownership` to name the offending process.

Target host for ESS-447 dev cluster:
**`jackson-macmac-mini.magic.workspace.beer:8444`** — Jackson's Mac mini,
Tailnet-only (accessible from any device on the same Multica magic
workspace). `config.json` binds `0.0.0.0` and pins `public_host`; the
source allowlist accepts loopback (for the smoke) plus Tailnet CGNAT
(`100.64.0.0/10`) so real devices on the same magic workspace can connect.

1. Provision a **trusted** TLS cert + key. On the Multica magic-workspace
   (Tailnet) the Tailscale daemon fronts Let's Encrypt for tailnet hostnames,
   so a browser-trusted cert is a single command; iOS `URLSession` picks it
   up without any client-side trust-store change. Run on the Mac mini:

   ```bash
   cd AudioRealtimeGateway
   mkdir -p certs
   tailscale cert \
     --cert-file=certs/gateway.crt \
     --key-file=certs/gateway.key \
     jackson-macmac-mini.magic.workspace.beer
   chmod 600 certs/gateway.key
   ```

   The issued cert's SAN is `DNS:jackson-macmac-mini.magic.workspace.beer`;
   the issuer is `Let's Encrypt` (intermediate `YE2`). Self-signed with a
   matching SAN would also work at the protocol layer but only if every
   client trusts the CA — Tailscale-issued certs skip that entirely.

   **Renewal.** Let's Encrypt certs are valid ~90 days; re-run the exact
   `tailscale cert` command above to refresh. A launchd job that fires
   every ~60 days keeps the cert well within the validity window
   (persistent-service wrapper is ESS-458).

   Since ESS-506, `smoke/deploy-smoke.mjs` writes its self-signed cert to
   a per-run `mktemp -d` and points the spawned server.mjs at it via the
   smoke config's `tls_cert` / `tls_key`, so running the smoke on the
   deployment host no longer clobbers this trusted cert. The smoke also
   gates on `S0-safety`, which fails if `certs/gateway.crt|key` change
   during the run.
2. Populate `state/devices.json` from Mac Bridge (or via a provisioning
   API); the two share the HMAC device format.
3. Confirm qwen-audio-agent is healthy on `127.0.0.1:3101` with voice
   configured. Its launchd service owns the provider key; do **not** copy that
   key into this Gateway or `config.json`.
4. `npm start`. The service logs `gateway_ready` when TLS + WSS + issuer
   are up; the log carries `bind`, `port`, and `public_host` so operators
   can grep the deployment address without reading config.
5. Confirm from the target host **without `-k`** — this proves the trust
   chain, not just that TLS is up:
   `curl https://jackson-macmac-mini.magic.workspace.beer:8444/v1/health`
   returns `{"ok": true, "service": "audio-realtime-gateway", "protocol_version": 1}`.
6. Confirm from a real device (e.g. iPhone on the same Tailnet):
   `curl https://jackson-macmac-mini.magic.workspace.beer:8444/v1/health`
   returns the same body without `-k` — that proves both DNS routing and
   the TLS trust chain end-to-end.
7. Enable the client-side `audio_realtime_agent_direct_enabled` flag on
   iPhone; set `audio_realtime_agent_gateway_url` to
   `wss://jackson-macmac-mini.magic.workspace.beer:8444/api/realtime`
   (matches `AudioRealtimeAgentFeatureFlag.devDefaultGatewayURLString`).
   The legacy Bridge-owned realtime media route is disabled in production;
   both direct Watch realtime and complete-file fallback are Gateway-owned.

For a persistent deployment on the Mac mini, use the launchd assets
under `scripts/launchd/` (ESS-458):

- `beer.workspace.wristagent.gateway.plist` — Gateway itself.
  `RunAtLoad: true`, `KeepAlive: true`, `ThrottleInterval: 5`. Stdout and
  stderr both go to `logs/gateway.log` (the structured JSONL stream —
  see `## Structured logs`).
- `beer.workspace.wristagent.gateway.rotator.plist` — hourly rotator.
  Invokes `scripts/rotate-log.sh`, which copy-truncates `gateway.log`
  (preserving the inode so the running server's stdout FD keeps
  writing), gzips the copy as `gateway.log.YYYYMMDD-HHMMSS.gz`,
  rotates at ≥ 20 MiB or once per day, retains 14 days of compressed
  rotations, and emits `rotator_rotated` / `rotator_purged` events to
  `logs/rotator.log`.
- `scripts/install-launchd.sh` — installs both plists into
  `~/Library/LaunchAgents/`, bootstraps them into the user's gui
  domain, and runs a loopback health probe. Assumes the module has
  been rsync'd to `/Users/jacksonmac/Services/Personal-Avatar-iWatch/AudioRealtimeGateway/`,
  `npm install` has run, and `certs/` is populated.

Diagnostic commands:

```
launchctl list beer.workspace.wristagent.gateway
launchctl print gui/$(id -u)/beer.workspace.wristagent.gateway
tail -f /Users/jacksonmac/Services/Personal-Avatar-iWatch/AudioRealtimeGateway/logs/gateway.log
```

`KeepAlive: true` means launchd auto-restarts the process on any exit
(SIGKILL included); the 5-second `ThrottleInterval` is the minimum time
between successive relaunches — a healthy relaunch after `kill -9`
lands in under a second in practice, followed by a fresh
`gateway_ready` line in `logs/gateway.log`.

## Fallback and rollback

The production Bridge does not expose its legacy owner path unless both
`realtime_media_v1` and the explicit test/legacy gate
`legacy_bridge_media_owner_enabled` are enabled. Complete-file fallback uses
the Gateway's loopback HMAC queue. Disable `fallback_jobs_enabled` to close new
job admission while retaining the persisted Bridge/Gateway ledgers.

## Tests

`npm test` runs the Node `--test` suites under `test/`:

- `token-issuer.test.mjs` — success, expiry, replay/reuse, scope mismatch,
  revocation, unknown device.
- `realtime-session.test.mjs` — happy path handshake, delta sequences,
  duplicates dropped, gaps rejected, `audio.done` barrier with
  `final_sequence`.
- `cancel-generation.test.mjs` — server-authoritative cancel stops delta
  emission, `stale_generation` frames dropped, new generation is clean.
- `heartbeat-rate-limit.test.mjs` — idle disconnect, ping/pong, per-second
  cap, frame-size cap.
- `structured-logs.test.mjs` — every stage of a turn produces the expected
  log entries with `request_id` / `session_id` and no secret material.
- `observability-*.test.mjs` — ESS-1071: the unified correlation contract,
  the four latency metrics + counters, and the three cross-component
  invariants (no silent end / no cross-session mixing / no premature done).

The one-command E2E gate lives at `smoke/realtime-e2e-gate.mjs` (ESS-1071):
`node smoke/realtime-e2e-gate.mjs --faults` runs the three fixed scenarios
（现在几点 / 杭州天气 / 我的分身知识库）plus six fault injections through the
real Gateway surface with a scripted upstream — no live dependencies. See
`Docs/realtime-ci-gate.md` and `Docs/realtime-device-gate.md` for the CI and
real-device checklists.

Integration with real device auth and real Agent upstream is deliberately
out of scope of ESS-403 (integration lives in ESS-401 and downstream
stages).
