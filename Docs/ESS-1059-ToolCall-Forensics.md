# ESS-1059 取证报告：qwen-audio-agent → Codex CLI 工具调用链路

取证对象：真机批次 2026-08-22 15:42:20Z–15:44:01Z（白梦林，Watch 直连）——「现在几点」成功，
「杭州天气」只播「正在查询」，「我的分身知识库」无最终结果。

本文是 ESS-1061 架构复审「结论可信但缺可复跑证据」的整改：每条结论都给出数据源、过滤口径和
可重跑命令。所有取证都是只读的。

## 0. 环境

| 项 | 值 |
| --- | --- |
| 本仓库部署版本 | `git_sha=bdd38b496872cd20267ab537ded3961d0f82a3a5`（= main，clean） |
| 上游 | qwen-audio-agent v0.9.1，loopback `127.0.0.1:3101` |
| 上游进程 | pid 2482（15:35:15Z 起） |
| Codex 后端 | ACP over stdio，`codex:user_personal:backend` |

## 1. 一条命令复跑全部结论

```
node Scripts/ess1059-forensics.mjs
```

只读脚本，不写文件、不连网、不启服务；缺任何一份数据源都降级成 `E?: UNAVAILABLE`。
默认脱敏——不打印任何用户语音文本，只打印结构化标识与计数；`--reveal-text` 才打印
`final_asr`，仅供本机运维，输出不要贴进 issue。凭据字段（API key / token / `authorizationId`）
任何模式下都不读取。窗口可用 `--from` / `--to` 覆盖。

数据源（全部只读）：

| 编号 | 路径 |
| --- | --- |
| E1 / E5 | `~/Services/Personal-Avatar-iWatch/AudioRealtimeGateway/logs/gateway.log` |
| E2 / E5 | `~/.config/qwaudio/logs/gateway.log` |
| E3 | `~/.config/qwaudio/tasks.json` |
| E4 / E6 | `~/.config/qwaudio/state/acp-sessions.json` → `~/.codex/sessions/**/rollout-*-<sessionId>.jsonl` |

退出码 0 = 各口径下与本文结论一致；非 0 = 打印 `MISMATCH` 并指出哪条对不上。
2026-08-22 16:0x 在真机数据上运行：退出码 0，`数据源读到: 6 份`。

## 2. 会话账本（E1）

| # | session | 工具调用 | Codex 任务 | 回合终态 | `done_emitted` |
| --- | --- | --- | --- | --- | --- |
| 1 | `CD469E3F` | 是（`get_current_time`） | 无 | `tool_result_done` @15:42:29.868Z，`outstanding_tasks=0` | `true` |
| 2 | `B34F094F` | 是（`spawn_thinking`） | `work_d6395cff-…` | `tool_result_done` @15:42:43.814Z，**`outstanding_tasks=1`** | `true` |
| 3 | `D950BFBD` | 否 | 无 | 无终态 | `false` |
| 4 | `7FAC0BC3` | 否 | 无 | 无终态 | `false` |
| 5 | `96707647` | 否 | 无 | `ERR_COMMIT_DEADLINE_TIMEOUT` | `false` |

问题↔会话映射的证据强度：#2 是**直接证据**（§5 可反查出 `final_asr`）；#1 是强相关（函数调用在
260 ms 内由 agent 段就地解决且未建任何 task，工具集中只有 `get_current_time` 符合）；
**#3/#4 属推定**——服务端没有任何一层落盘 ASR（§5），不能当已确认。

## 3. 根因：Codex ACP 会话被复用且被污染（E3 + E4）

```
E3  status=completed 的任务总数: 26
    末尾连续「completed 但 result 是 error」条数: 15
    最后一次真正成功: 2026-08-22T11:57:16.071Z work_c429304f-…
    失败任务数: 15，不同错误正文数: 1
    唯一错误指向的条目 id: msg_11d73d7b-6811-4f40-9c0d-9b91fe86dbad

E4  sessionId=019fb5bc-3570-7bc1-81e4-06785845f347
    cwd=/Users/jacksonmac/Documents/code/Personal-Avatar-iWatch
    rollout 大小=4794719 字节  行数=2302
    invalid_id_prefix 400 的 task_complete: 15
    首次 400: 2026-08-22T13:09:50.420Z   最近一次: 2026-08-22T15:42:51.000Z
    被点名的条目是否就在这份复用历史中: true
```

统计口径（这是「连续 15 次零成功」的定义）：样本 = `tasks.json` 中 `status='completed'` 的任务按
`createdAt` 升序；**判失败不看 status**（F2 说的正是 status 撒谎），而看 `result` 能否解析成
`type === 'error'` 的 JSON；「连续零成功」= 最后一个非失败任务之后到最新一条的长度。

错误正文（15 条字节级完全一致）：

```
[ApiIdParam] [input[25].id] [invalid_id_prefix] Invalid 'input[25].id':
'msg_11d73d7b-6811-4f40-9c0d-9b91fe86dbad'. Expected an ID that begins with 'rs'.  (status 400)
```

**已确认**：`acp-sessions.json` 把 codex 后端钉死在同一个 sessionId，每个任务都 resume 这份
7 月 31 日以来的 4.79 MB / 2302 行历史；400 点名的那条 `reasoning` 条目确实躺在这份历史里；
上游在 13:01:41Z 重启（E2 `pid=46099`），重启后第一个任务 13:09:50Z 起 15 连败、零自愈。

**推定（不要当已确认）**：为什么偏偏是 `input[25]`、为什么重启前同一份历史还能跑通。脚本同时
查出这份 rollout 里 **`id` 不以 `rs_` 开头的 `reasoning` 条目共 240 条**，即坏 id 是这个会话的
普遍形态而非某次 compaction 的产物；变的是 resume 后哪些条目被重新送进 input 数组。定位到
「重启 → resume → 送进坏条目」这一步足以支撑修复，再往下的索引级机制未验证。

## 4. 交付协议正本：异步受理 + 后续通知（复审阻断项 1 的回答）

上游源码已经把协议写死，不需要另立正本：

- `server/src/agent/coordinator.mjs:202-206` — 每个委派请求信封里 `delivery.completion` 恒为
  `'automatic'`（无分支），即后台**不在本回合内交付**。
- `server/src/voice/realtime-gateway.mjs:657` `announcements.completed(task)` — 完成结果进播报
  队列；`server/src/voice/announcement/announcement-manager.mjs` 做批量（`batchMs=120`,
  `maxBatchItems=8`）、ack 门禁（`ackTimeoutMs=120000`）与重投（`maxRetries=8`），未确认就在
  后续会话反复重投。

结论：**同一语音 turn 不等待后台 task 终态**。因此
「`tool_result_done` 在 `outstanding_tasks>0` 时收口」**不是缺陷**，把
`outstandingTasks.size === 0` 当回合终结硬门禁也是错的——按 ESS-990 的实测
（`task.accepted` 晚于首段 `audio.done` 795–8689 ms，任务在末段后仍可持续 30–70 s），
那样会把正常异步委派拖到客户端 45 s 硬超时。

真正的缺陷在接收端：**这条通知在本网关没有接收者**。

## 5. 结果回送通道被整段丢弃（E5 + E6）

```
E5  15:43:12.137Z resp_SShIFwgEVfVPiAjskmJO9 taskIds=[…,work_d6395cff-…]
        本网关丢弃: 71帧/1815148字节
    15:43:32.472Z resp_aRuqIizcXPchOrAfFkIoQ taskIds=[…,work_d6395cff-…]
        本网关丢弃: 71帧/1815148字节
```

上游把完成结果作为 `origin='announcement'` 的响应投递，`taskIds` 就是本次要交付的任务；本网关
按 ESS-849 把 announcement 的 audio / transcript / `response.done` **全部丢弃**，且没有任何替代
转发（无通知事件、无文本通道）。

**以当前部署，任何委派给 Codex CLI 的结果都不存在一条能到达用户的路径——即使 Codex 完全健康。**
ESS-849 的隔离口径本身没错（防串台），缺的是「结果能归属回本会话发起的 taskId 时应当放行」这一半。

归属键的现状：`announcement-manager.mjs` 的 `completed()` 载荷带 `turnId`，但实测 `tasks.json` 里
`turnId=null`、请求信封里 `turn_id=""`——turn 级归属当前是空的，所以放行判据只能先用 `taskId`
（`response.started` 的 `taskIds` 里有），或先把 `turnId` 填上。

## 6. 可观测性缺口（E6）

```
E6  可反查回合数: 1（其余回合服务端无 ASR 落盘）
```

只有走了 `spawn_thinking` 的回合，其请求信封才会落进 Codex rollout，才有 `final_asr` 可查。不走
委派的回合在服务端任何一层都查不到用户说了什么——这正是 §2 里 #3/#4 只能停在「推定」的原因。

## 7. 已确认失败面与后续动作

| ID | 判定 | 归属 |
| --- | --- | --- |
| F1 ACP 会话污染导致 15 连败 | 已确认（根因） | 运行环境 + qwen-audio-agent |
| F2 失败被标成 `completed`，错误 JSON 进 `presentation.speech` 与 `recent_voice_context` | 已确认 | qwen-audio-agent |
| F3 `tool_result_done` 在 `outstanding_tasks>0` 收口 | **撤回**——按 §4 协议这是正确行为 | — |
| F4 结果回送通道无接收者 | 已确认（唯一阻断交付的链路缺陷） | AudioRealtimeGateway + 上游 |
| F5 知识库问题未走委派 | 待验证（缺 ASR） | qwen-audio-agent instruction |
| F6 ASR 全链路不落盘 | 已确认 | qwen-audio-agent |
| F7 直答回合不发 `done`（`turnBusy` 单向锁存） | 已确认 | AudioRealtimeGateway |

回归场景与整改项见 ESS-1059 issue 评论；本文只负责证据可复核。

## 8. 自动化回归基线

```
cd AudioRealtimeGateway && npm ci && npm test
```

2026-08-22 16:00 运行结果：`tests 184 / pass 184 / fail 0`，`duration_ms 9263.787`。
（ESS-1061 复审当时因 checkout 未装依赖报 `ERR_MODULE_NOT_FOUND: ws`，`npm ci` 后即可运行。）
这是改动前的基线，用于后续 F4/F7 修复的对照。
