# WristAgent Gateway API

腕语 Watch App 不直接绑定某一家 ASR、TTS 或 Agent。服务端只要实现下面 4 个 JSON 接口，即可接入现有云端 Agent。

生产环境必须使用 HTTPS。`Authorization: Bearer <token>` 会在用户配置 Token 后自动发送。

## 1. 提交一轮语音

`POST /v1/turns`

```json
{
  "audio_base64": "<M4A AAC BASE64>",
  "audio_format": "m4a",
  "locale": "zh-CN",
  "client": "watchos",
  "concise_reply": true
}
```

直接完成：

```json
{
  "turn_id": "turn_123",
  "transcript": "我下午还有什么会",
  "reply": "下午两场会，最近一场是两点半的产品评审。",
  "risk": "read_only",
  "state": "completed",
  "task_id": null,
  "confirmation": null,
  "undo": null,
  "tts_audio_base64": null
}
```

需要确认：

```json
{
  "turn_id": "turn_124",
  "transcript": "把总结发给项目群",
  "reply": "发送前请确认",
  "risk": "confirmation_required",
  "state": "running",
  "task_id": null,
  "confirmation": {
    "id": "confirm_123",
    "title": "发送项目总结",
    "target": "飞船项目群 · 18 人",
    "impact": "群成员会立即收到 3 个决定和 4 个待办。",
    "actionLabel": "确认发送"
  },
  "undo": null,
  "tts_audio_base64": null
}
```

`risk` 只能是：

- `read_only`：查询，可直接执行。
- `reversible`：可撤回的写操作。
- `confirmation_required`：发送、删除、付款、改权限等，必须返回 `confirmation`。

`tts_audio_base64` 可返回完整音频；为空时 Watch 使用系统中文 TTS。

可撤回操作在完成响应中返回：

```json
{
  "risk": "reversible",
  "state": "completed",
  "undo": {
    "id": "undo_123",
    "label": "撤回提醒",
    "expires_at": "2026-07-28T10:30:00Z"
  }
}
```

## 2. 撤回操作

`POST /v1/undo/{undo_id}`

成功时返回完整 `AgentTurnResponse`，其中 `state` 为 `cancelled`、`undo` 为空。

## 3. 确认或拒绝

`POST /v1/confirmations/{confirmation_id}`

```json
{
  "confirmation_id": "confirm_123",
  "approved": true
}
```

响应与 `/v1/turns` 相同。服务端不得在收到 `approved: true` 之前执行高风险工具。

## 4. 查询长任务

`GET /v1/tasks/{task_id}`

```json
{
  "task_id": "task_123",
  "state": "completed",
  "reply": "整理完成：三个决定和四个待办。"
}
```

`state` 为 `running`、`completed`、`failed` 或 `cancelled`。

## 5. 取消长任务

`POST /v1/tasks/{task_id}/cancel`

成功时返回任务对象；已经进入不可撤销工具调用时，服务端应返回明确错误。

## 6. 链路追踪（trace_id）

全链路共用一个 `trace_id`，用于确认一次输入在每个模块是否成功执行。

- 客户端可通过请求体 `trace_id` 字段或 `X-Trace-Id` 头指定（格式
  `[A-Za-z0-9_-]{1,64}`，例如 `223lkjl`）；缺省时网关生成 `trc-xxxxxxxx`。
- 所有响应回显 `trace_id` 字段和 `X-Trace-Id` 头；同一轮的后续请求
  （轮询、撤回、确认）应携带同一 `X-Trace-Id`。
- 每个模块写独立 JSONL 日志：`logs/trace/h5-mock.log`、
  `logs/trace/main-agent.log`、`logs/trace/codex-cli.log`（目录可用
  `WRIST_AGENT_TRACE_DIR` 覆盖），每行都含 `trace_id`、`module`、
  `event`、`status`。

`GET /v1/trace/{trace_id}` 返回该链路经过的模块及各模块是否全部成功：

```json
{
  "trace_id": "223lkjl",
  "found": true,
  "modules": {
    "h5-mock": { "events": 1, "ok": true },
    "main-agent": { "events": 3, "ok": true },
    "codex-cli": { "events": 2, "ok": true }
  },
  "entries": []
}
```

> Mock 网关中 `main-agent` 与 `codex-cli` 是模拟阶段；接入真实主 Agent 和
> Codex CLI 时沿用同一约定：透传 `X-Trace-Id`，日志行携带 `trace_id`。

## Agent 侧必须保证

1. 每个请求有独立 `turn_id`，工具调用可追溯。
2. 高风险操作由服务端再次校验，不只依赖 Watch UI。
3. 原始语音默认不落盘，日志遮盖 Token 和敏感字段。
4. 同一 `confirmation_id` 只能成功执行一次，防止重试造成重复发送。
5. 超过 8 秒的任务返回 `running + task_id`，不要让 Watch 请求一直阻塞。
