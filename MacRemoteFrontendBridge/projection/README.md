# ESS-27 — QwenTaskProjection：SSE/REST 事件投影与结果回传

后台 Work（`spawn_thinking` → Codex）的事件投影模块，对应
《技术架构设计 v2.1》§4.1 / §7 / §9（QwenTaskProjection）。零 npm 依赖
（Node ≥ 22 内置 fetch/WebSocket）。

## 目录

```
projection/task-projection.mjs   核心模块：QwenTaskProjection + respondPermission
projection/projection-ledger.mjs 投影恢复账本（重启/重开页面找回未终结投影）
test/mock-tests.mjs              12 个确定性 mock 网关场景（边界与错误路径）
test/live-test.mjs               真网关验收（recover / restart / cancel / perm）
results/                         真机运行报告与日志
```

## 运行

```bash
node test/mock-tests.mjs                 # 全部离线，~5s
node test/live-test.mjs recover          # 真网关（127.0.0.1:3101），创建真实 Codex Work
node test/live-test.mjs restart
node test/live-test.mjs cancel
node test/live-test.mjs perm             # 只打权限 REST 契约，不产生任务
```

## 北向事件契约（Bridge → iPhone，ESS-26 集成点）

每个事件：`{ type:'turn.background', request_id, task_id, seq, at, transport, state, … }`

| state | 附加字段 |
|---|---|
| `background_accepted` | — |
| `background_processing` | `status`（网关原始状态）、`progress`（≤200 字） |
| `permission_required` | `authorization: { id, summary }` — **按 authorization.id 回传决定** |
| `completed` | `result: { speech(≤600), inline: { title(≤120), content(≤2000), truncated } }` |
| `failed` | `error: { code, message }`，code ∈ `work_failed / work_timeout / task_lost / task_not_found` |
| `cancelled` | `error: { code:'cancelled', … }` |

保证：同一 `request_id` 终态**恰好交付一次**（SSE/REST 竞争安全）；
非终态事件受限流（默认 ≥2s 间隔）与总量上限（默认 200）约束，终态永远放行。

## ESS-26 集成注意（真网关实测结论）

1. **SSE 无 Last-Event-ID**：`GET /api/tasks/:id/events` 首条即 `task.snapshot`
   全量快照，事件均携带完整 task —— 断线恢复无需续传游标，重连/REST 快照即无损。
2. **REST 轮询退避**：SSE 中断后 REST 不重置退避（实测 0.5s→1s→2s→8s→…→30s 封顶），
   仅 SSE 真正重连成功才归零 —— 避免降级模式下轰击网关。
3. **权限链路**：对未知 authorization id，上游抛通用错误 → **500 + HTML**（仅当
   ACP 明确报 404 才有 JSON 404）。必须靠 Content-Type 防御兜为稳定错误码；
   权限一律按 `authorization.id` 关联（ESS-24 已证 taskId 会挂错）。
4. **catch-all**：网关对未知 GET 路径返回 200 + HTML（SPA index），所有 REST
   读取必须校验 `application/json`，SSE 必须校验 `text/event-stream`。
5. **硬超时**：到期先 `DELETE /api/tasks/:id` 再交付稳定错误 `work_timeout`
   （无论网关侧终态最终是 cancelled 还是别的）。
6. **任务状态丢失**（见过任务后 404，如网关重启丢 store）：交付
   `task_lost` + “结果未知，请人工确认” —— 结果未知的非幂等操作不自动重跑。
7. **账本边界**：`ProjectionLedger` 只做投影层最小恢复；Bridge 的完整幂等账本
   （request_id → sessionId → task_id → Codex Session）在 ESS-26，集成时可替换，
   保留 upsert / markSettled / unsettled 语义即可。
8. **结果音频**：后台结果以文本（speech/inline）投影交付，不依赖 Realtime
   安全播报窗口；若 Bridge 的 Realtime 会话恰好在线收到播报音频，可作为补充
   事件按同一 request_id 附加（转码走 ESS-25 MacAudioCodecPipeline），但交付
   永不等待播报。
