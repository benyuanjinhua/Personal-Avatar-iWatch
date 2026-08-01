# Remote Frontend Bridge（ESS-26 · P1 完整实现，ESS-30 入库，ESS-36 双向链路修复）

ESS-36 修复说明（真机 0 事件超时的根因与对策）：qwen-audio-agent 对**非语音
所有权持有者**的 `audio.append` 是**静默丢弃**——所有权是注入的前置条件。
supervisor 现在：① 连接遇 busy 且持有者是另一个 watch-bridge 实例（上一进程
残留）时自动 takeover，Bridge 重启不再死锁；持有者是其他前台时按
`takeover_from_frontends` 决定抢占或快速失败 `ERR_VOICE_BUSY`；② 会话中被
takeover（`voice.deactivated`）立即失效 ready 标志并快速失败当前 turn；
③ 注入完成后 `inject_ack_timeout_ms` 内 0 事件 → 回收会话重试一次
（`ERR_REALTIME_NO_EVENTS`）；④ `transcript.discard`（ASR 判定无效语音）
立即失败 `ERR_TRANSCRIPT_DISCARDED`，不再白等 120s；⑤ origin=announcement
的后台播报与 turn 结果隔离（音频/转写不混入），但播放回执照常发送（否则
网关播报窗口阻塞）；origin=agent 是后端 Agent 对本 turn 的应答本体，计入
结果；⑥ work deadline 在 turn 真正开始注入时重挂，串行积压不再团灭；
⑦ supervisor journal 全量落 Bridge 结构化日志并携带 request_id，
`accepted → realtime events → completed` 可按同一 request_id 串起。
turn 间强制 `turn_gap_ms` 间隔、尾部静音加长到 `trailing_silence_ms`（连续
注入无停顿会让网关合并相邻 turn、VAD 收不到停止判定 → 60s 后 discard）。

ESS-30 入库说明：本模块由 ESS-23（鉴权/幂等骨架）→ ESS-25（伪前端 WS 注入 + AudioPipe）
→ ESS-26（完整 Bridge）逐步合并而来，`projection/` 为 ESS-27 QwenTaskProjection。
ESS-30 追加：F2 turn 超时 watchdog（supervisor 强制重建 WS）、D1 写动作总开关
`write_actions_enabled`（默认 false：上游权限请求一律自动 reject，含针对上游
authorization 挂错 task 缺陷的清扫器 `deny_sweep_interval_ms`）。ESS-34 归属化：
**主路径是会话内 in-band 拒绝**——网关只把 `task.sessionId` 等于本连接会话的
权限事件下发到本 Realtime WS（网关源码契约），事件到达即归属证明，与宿主
task 挂对挂错无关（真机实测错挂宿主可为 `GET /api/tasks` 之外的幽灵任务）。
list 清扫器降为二道防线，只 reject **可证明归属**的 authorization——task_id 或
delegation/backendRef session 命中在途 turn；宿主 task 的状态不是归属证据（终态
孤儿规则已按四眼复审删除：它会连带拒掉无关会话遗留在终态任务上的 pending
授权）。无关任务/会话的 pending 权限一律保持不动，归属不了的自身写请求由 turn
硬超时 fail closed。拒写 turn 以 completed + 可读文案（「只读模式：写操作已被
拒绝」）收尾，不露裸错误码。

Mac mini 上的 tailnet 窄入口：鉴权、幂等、生命周期、北向 API 的完整实现。
依据《技术架构设计 v2.1》§4.1 / §6 / §7 / §10 P1，在 ESS-23（鉴权/幂等骨架）与
ESS-25（伪前端 WS 注入 + 音频管线）之上合并扩展。

```
iPhone Relay ──HTTPS/WSS(HMAC 签名)──▶ server.mjs（北向 API）
                                        ├─ auth.mjs       配对 + 签名/nonce/防重放
                                        ├─ ledger.mjs     幂等账本（request_id 唯一，持久化）
                                        ├─ audio.mjs      audiopipe 受控转码（无 Shell 拼接）
                                        ├─ supervisor.mjs 常驻伪前端 WS /api/realtime（ESS-25）
                                        ├─ taskwatch.mjs  Task SSE/REST 投影 + 300s 硬超时
                                        └─ gateway.mjs    防御性 REST/SSE 客户端
                                              │ loopback only
                                              ▼
                                   qwen-audio-agent v0.9.1 (127.0.0.1:3101)
```

## 北向 API（iPhone → Mac，全部走应用层签名 + Tailscale ACL）

| Method | Path | 说明 |
|---|---|---|
| POST | `/v1/pair` | 一次性配对码 → 设备 token（服务端只存哈希） |
| POST | `/v1/voice/turns` | 幂等创建；立即返回 202 受理回执 |
| GET | `/v1/voice/turns/{id}` | 稳定状态投影 + 短结果 |
| POST | `/v1/voice/turns/{id}/cancel` | 取消（后台任务映射到 `DELETE /api/tasks/:id`） |
| POST | `/v1/voice/turns/{id}/permission` | `{permission_id, decision: allow\|deny}` |
| GET | `/v1/voice/turns/{id}/audio` | 结果语音（AAC/M4A）有界取回；支持 `Range` 断点续传，`x-audio-sha256` 响应头供校验（ESS-38） |
| WSS | `/v1/voice/events` | `turn.state` 事件推送；连接即回放非终态 snapshot |
| GET | `/v1/health` | 健康检查（无鉴权，仅源 IP 门禁） |

状态投影：`accepted → processing → (permission_required) → completed | failed | cancelled`，
`detail` 携带子状态（`realtime_processing` / `background_accepted` / `background_running`…）。

结果结构（completed）：`result.text`（任务/直答文本）、`result.speech_text`（Qwen Audio
Realtime 播报转写，后台路径）、`result.audio_base64`（≤ `max_result_audio_bytes` 时内联）、
`result.audio = {sha256, codec, duration_ms, size_bytes}`（语音文件元数据，内联被裁时仍在，
客户端凭它走 `/audio` 端点下载）。

## Realtime 语音下行（ESS-38）

后台任务的结果语音以 `origin=announcement` 经 Realtime WS 到达（Qwen 生成的人物
状态/口气播报，Bridge 不做二次 TTS）。supervisor 按 `responseId` 聚合 24kHz PCM
delta 与 assistant transcript（`response.started` 携带 `taskId`），聚合上限
`max_announcement_pcm_bytes`（超限截断）；聚合完成后按 `taskId → task_id →
request_id` 绑定回原请求，转码 AAC/M4A 落 `state/result-audio/`（保留期
`result_audio_retention_ms`），并把元数据补挂到账本结果。到达次序与 task 终态
无关：文本先投影（终态不等语音），语音随后以第二条 `turn.state` 补上。归属不了
的播报（Mac 本机任务等）只留日志、绝不乱挂。

## 关键机制

- **幂等账本**（`state/turn-ledger.json`，原子写入）：`request_id → sessionId → task_id
  → codex_session` 映射持久化；同 `request_id` 同 body 重试返回既有映射（`idempotent_replay:
  true`，绝不二次执行）；同 id 不同 body → `409 ERR_IDEMPOTENCY_CONFLICT`。
- **300 秒硬超时**：受理即计时。实时阶段超时中止注入；后台阶段超时先 `DELETE
  /api/tasks/:id` 再投影 `failed / ERR_WORK_TIMEOUT`。绝无无期限等待。
- **上限**：单请求 SSE/task 事件数（`max_turn_events`，ESS-41 起只统计 SSE/task
  生命周期事件，Realtime 观测计数单独分账；超预算降级为收敛投影 + 降采样日志，
  绝不取消健康任务，最终兜底是 300s 硬超时）、结果文本（`max_result_chars`）、结果音频
  （`max_result_audio_bytes`，超限丢音频保文本摘要）。
- **空音频快速失败**（ESS-41）：解码后不足 `min_audio_ms`（默认 300ms）或 RMS 低于
  `min_audio_rms` 的空/误触音频直接 `ERR_AUDIO_TOO_SHORT`（Watch 提示「没听清，请重
  说」），不进 Realtime 注入与停摆重放机器。
- **防御性校验**：所有网关响应先验 HTTP 状态 + Content-Type + 最小 Schema。真实网关对
  未知 `/api/*` 路由返回 HTML（web UI 兜底路由），绝不被当 JSON 解析。
- **断线恢复**：重启后仅恢复可安全查询的状态——有 `task_id` 的 turn 重挂 SSE/REST
  监视；注入结果未知的 turn 标记 `failed / ERR_RESULT_UNKNOWN`（转人工确认），不自动重跑。
- **红线**：不调用 Codex CLI；北向不接收任何命令行参数/工作目录/环境变量；不暴露
  Gateway 管理 API；网关仅 loopback 访问。

## 运行

```bash
npm install                     # 仅 ws 一个依赖（Node ≥ 22）
# TLS：生产用 tailscale cert 签发（见 ESS-23 README），测试可自签
tailscale cert --cert-file certs/bridge.crt --key-file certs/bridge.key <magicdns-name>
# audiopipe：ESS-25 AudioPipe 构建产物
(cd ../AudioPipe && swift build -c release) && cp ../AudioPipe/.build/release/audiopipe ./audiopipe
node server.mjs                 # 配对码写入 state/pairing-code.txt（0600，10 分钟 TTL）
```

配置见 `config.json`（绑定 loopback + Tailscale IP，从不绑 0.0.0.0；`allowed_peer_ips`
为应用层第二道准入）。

## 测试

```bash
npm test                        # 26 项验收测试（mock 网关，含所有权仲裁/回执 watchdog/announcement 隔离）
node test/e2e-real.mjs <direct.m4a> [task.m4a]   # 真网关全链路（127.0.0.1:3101）
node test/ess36-live.mjs q1.m4a q2.m4a q3.m4a q4.m4a q5.m4a  # ESS-36 连续 5 turn 真网关验收
```

## 已知边界

- 后台任务结果目前只回传文本（`task.result` / `presentation.speech|inline`）；后台结果的
  语音合成/聚合属 ESS-27（QwenTaskProjection）范围，接口已留（`ledger.setResult` 的
  `audioBase64`）。
- 音频仍为 JSON + base64 内嵌（与 ESS-23 RelayClient wire 协议兼容；5MB 音频 ≈ 6.8MB
  body < 8MB 上限）。二进制上传是后续优化，不阻塞 P1。
- 权限链路对真网关的实测依赖 Codex 写操作场景，归 ESS-30 真机测试矩阵；本仓已按网关
  源码契约（`POST /api/permissions/:id`，`decision: always|reject`）实现并 mock 全覆盖。
