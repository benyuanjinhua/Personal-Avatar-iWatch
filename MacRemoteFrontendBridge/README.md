# Remote Frontend Bridge（ESS-26 · P1 完整实现，ESS-30 入库）

ESS-30 入库说明：本模块由 ESS-23（鉴权/幂等骨架）→ ESS-25（伪前端 WS 注入 + AudioPipe）
→ ESS-26（完整 Bridge）逐步合并而来，`projection/` 为 ESS-27 QwenTaskProjection。
ESS-30 追加：F2 turn 超时 watchdog（supervisor 强制重建 WS）、D1 写动作总开关
`write_actions_enabled`（默认 false：上游权限请求一律自动 reject，含针对上游
authorization 挂错 task 缺陷的清扫器 `deny_sweep_interval_ms`）。ESS-34 收窄：
清扫器只 reject 能归属到本 Bridge 在途 turn 的 authorization（task_id 或
delegation session 命中），无关任务/会话的 pending 权限保持不动；归属不了的
自身写请求由 turn 硬超时 fail closed。

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
| WSS | `/v1/voice/events` | `turn.state` 事件推送；连接即回放非终态 snapshot |
| GET | `/v1/health` | 健康检查（无鉴权，仅源 IP 门禁） |

状态投影：`accepted → processing → (permission_required) → completed | failed | cancelled`，
`detail` 携带子状态（`realtime_processing` / `background_accepted` / `background_running`…）。

## 关键机制

- **幂等账本**（`state/turn-ledger.json`，原子写入）：`request_id → sessionId → task_id
  → codex_session` 映射持久化；同 `request_id` 同 body 重试返回既有映射（`idempotent_replay:
  true`，绝不二次执行）；同 id 不同 body → `409 ERR_IDEMPOTENCY_CONFLICT`。
- **300 秒硬超时**：受理即计时。实时阶段超时中止注入；后台阶段超时先 `DELETE
  /api/tasks/:id` 再投影 `failed / ERR_WORK_TIMEOUT`。绝无无期限等待。
- **上限**：单请求事件数（`max_turn_events`）、结果文本（`max_result_chars`）、结果音频
  （`max_result_audio_bytes`，超限丢音频保文本摘要）。
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
npm test                        # 13 项验收测试（mock 网关，含重启恢复/超时/权限/幂等）
node test/e2e-real.mjs <direct.m4a> [task.m4a]   # 真网关全链路（127.0.0.1:3101）
```

## 已知边界

- 后台任务结果目前只回传文本（`task.result` / `presentation.speech|inline`）；后台结果的
  语音合成/聚合属 ESS-27（QwenTaskProjection）范围，接口已留（`ledger.setResult` 的
  `audioBase64`）。
- 音频仍为 JSON + base64 内嵌（与 ESS-23 RelayClient wire 协议兼容；5MB 音频 ≈ 6.8MB
  body < 8MB 上限）。二进制上传是后续优化，不阻塞 P1。
- 权限链路对真网关的实测依赖 Codex 写操作场景，归 ESS-30 真机测试矩阵；本仓已按网关
  源码契约（`POST /api/permissions/:id`，`decision: always|reject`）实现并 mock 全覆盖。
