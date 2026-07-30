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

## Agent 侧必须保证

1. 每个请求有独立 `turn_id`，工具调用可追溯。
2. 高风险操作由服务端再次校验，不只依赖 Watch UI。
3. 原始语音默认不落盘，日志遮盖 Token 和敏感字段。
4. 同一 `confirmation_id` 只能成功执行一次，防止重试造成重复发送。
5. 超过 8 秒的任务返回 `running + task_id`，不要让 Watch 请求一直阻塞。
