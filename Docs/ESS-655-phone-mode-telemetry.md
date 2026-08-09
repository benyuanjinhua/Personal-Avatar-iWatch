# ESS-655 · Watch 电话模式埋点契约（F6）

设计口径正本：ESS-634 交互设计稿 v2.0 §10。本文只讲**怎么接线**，
口径分歧以设计稿为准，schema 分歧以 `Shared/PhoneModeTelemetry.swift` 为准
（它有测试，设计稿没有）。

## 一、怎么写一条事件

不要再手拼 `detail` 字符串。走类型化工厂 + `WatchLog.record`：

```swift
WatchLog.record(
    PhoneModeTelemetry.enterRejected(holdMs: elapsedMs),
    requestId: nil                       // 待机屏还没有回合
)

WatchLog.record(
    PhoneModeTelemetry.failedNoticeShown(
        reason: .readyTimeout, fromPhase: .connecting, copyID: .cannotConnect
    ),
    requestId: activeTurnRequestId
)
```

工厂在 `Shared/PhoneModeTelemetry.swift`，一个事件一个函数，参数即必带字段。
拼不出错字段名、漏不掉必需字段、写不出非法枚举值——这是这层存在的全部理由。

**绕过它直接 `WatchLog.info("session", "session_xxx", detail: "...")` 等于放弃校验**，
复审请直接打回。

## 二、12 个事件与接线归属

| 事件 | 必带字段 | 触发点 | 归属 issue |
|---|---|---|---|
| `session_failed_notice_shown` | `reason` `from_phase` `copy_id` | 进入 P6 | ESS-652 (F3-1/F3-2) |
| `session_failed_retry_tapped` | `reason` `dwell_ms` | P6 点重试 | ESS-652 (F3-3) |
| `session_failed_auto_hangup` | `reason` | P6 停留 15s | ESS-652 (F3-3) |
| `session_thinking_slow` | `turn_index` | 思考 25s 软提示 | ESS-652 (F3-5) |
| `session_idle_hint` | `level` | 静默 30s / 75s | ESS-652 (F3-6) |
| `session_idle_hangup` | `turns` | 静默 120s 挂断 | ESS-652 (F3-6) |
| `session_background_cap` | `duration_ms` | 后台上限 | ESS-652 (F3-7) |
| `session_call_summary` | `turns` `duration_ms` `end_reason` `conversation_id` | 进入 P7 | ESS-652 (F3-4) |
| `session_enter_rejected` | `reason` `hold_ms` | 待机屏长按松手被拒 | ESS-653 (F1-1) / ESS-651 (F5) |
| `session_speaking_interrupted` | `source` `detect_ms` `stop_ms` | 打断命中 | **已接**（点球）/ ESS-650（语音） |
| `session_barge_in_self_echo` | `turn_index` `energy_db` | 判定为自身回声 | ESS-650 (F2-5) |
| `voice_barge_in_gate` | `state` `reason` | gate 快照/变化 | ESS-650 (F2-4) |

契约里还有若干**可选**字段（`dwell_ms` / `elapsed_ms` / `silent_ms` / `turn_index`），
带上更好，不带不算违约，带了会被校验。

### 已经接好的那一条

`SessionController.interruptSpeaking(source:detectMs:)` 已按新 schema 落事件：
点球恒 `source=orb_tap` / `detect_ms=0`，`stop_ms` 是本地停播动作的实测耗时。

**F2 的语音打断请复用这同一个入口**（传 `source: .voice` 和 VAD 判定耗时），
不要另开一条打断路径——两条路径落到不同事件或不同状态机，误触发率就永远算不出来。

## 三、加字段 / 加事件怎么办

1. 改 `PhoneModeTelemetry`（加 case 或加 `FieldSpec`）；
2. `Tests/PhoneModeTelemetryTests.swift` 顶部的 `contract` 表同步改——
   它是设计稿 §10.2 的逐条副本，改了 schema 不改它会当场红；
3. 回 ESS-634 让聆澜同步设计稿，别让两份口径分叉。

新增失败 `reason` / 结束 `end_reason` / 文案 `copy_id` 同理：**不加 case 就过不了校验**。
这是刻意的——一个没登记的取值会让指标静默漏算，比报错难查得多。

## 四、指标怎么算

`Shared/PhoneModeCallMetrics.swift`，输入是事件流，输出是设计稿 §10.3 的四条指标：

| 指标 | 字段 | 目标（【假设】，未实测） |
|---|---|---|
| 无提示消失率 | `silentDisappearanceRate` | 0% |
| 轮转成功率 | `relistenSuccessRate`（`answer_finished → next_listening ≤ 400ms`） | ≥ 99% |
| 每通额外按键数 | `extraTapsPerCall`（长按被拒 + P6 重试；**打断除外**） | 0 |
| 语音打断误触发率 | `voiceBargeInFalseTriggerRate` | 0，且 `isEligibleForDefaultOnGate` 才允许 gate 默认 ON |

三条口径上的硬规定，别绕开：

- **分母为 0 返回 `nil`，不返回 0。** 「没有样本」不许被读成「达标」。
  `isEligibleForDefaultOnGate` 因此在**没跑过语音打断**时返回 false ——
  这正是 ESS-650「F2-5 未通过不得默认 ON」的意思。
- **校验不过的记录进 `rejected`，不进分子分母。** 算不出来和算成 0 是两回事。
- **报数必须带样本量与数据窗口**（R-04.4）。`calls` / `closedCalls` /
  `relistenOpportunities` 就是给这个用的，别只贴百分比。

从真机 / 模拟器落盘日志算：

```swift
let samples = entries.compactMap(PhoneModeCallTrace.Sample.init(entry:))
let metrics = PhoneModeCallMetrics.compute(samples)
```

## 五、已知的设计稿内部不一致（不改代码，待聆澜收口）

设计稿 §10.2 表里 `session_idle_hint` 写「20s/60s」、`session_idle_hangup` 写「90s」，
与白梦林决策 4 及同稿异常链 E11–E13 的 **30s / 75s / 120s** 不一致。
schema 只定义字段不定义阈值，两者都能编码，**实现按 30/75/120**（ESS-652 已按此拆单）。
已在 ESS-655 回帖点名，请勿各自按各自的数字实现。
