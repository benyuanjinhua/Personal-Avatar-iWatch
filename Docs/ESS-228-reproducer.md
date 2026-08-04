# ESS-228 Phase 1 (E5) 稳定复现 · Runbook

> 白梦林 2026-08-04 拍板 Phase 1 mandate 的 E5：给出可重复的操作序列，让
> `began` 置位后 `.ended` 不来的现象稳定触发；Phase 2 才有基线可对照。
>
> 本 runbook 不改任何代码；仅列出操作步骤 + 观察指标，操作对象是真机 +
> 蓝牙/裸手表两组情境。跑一轮前先确认取证字段已生效（见 §0）。

## 0 · 前置

- 装的是本 PR 之后的 build（`Scripts/preflight.mjs` G8 应给出 `built_after=<本 PR 合并时间>`）；
- Bridge 已连接：`MacRemoteFrontendBridge/logs/bridge.log` 在实时写入；
- 每步操作后至少 5 秒不动手，让所有异步 Task 落尾；
- Phase 1 只观察、只补字段——**不动 App 状态，也不重启进程**（进程重启会把 observer 归零，掩盖真实生命周期）。

## 1 · 情境 A · 裸手表（Speaker 路由）

目的：ESS-217 里 `Speaker(扬声器) → 20/20 activation failed` 的对照组，
配合本 PR 后的新字段还原 `began` 究竟来自哪个 observer。

1. 蓝牙耳机不连、手表处于 `active` 前景态；
2. 打开 App → 等自检跑完（约 10s）→ 记 `t0`；
3. 向 App 发一次语音提问（触发结果语音下发路径）；
4. 记 `t1`；等 30s；
5. 用手指划走 App（不杀进程）→ 等 20s → 抬腕回前台；
6. 记 `t2`；再发一次相同提问；
7. 手表锁屏 30s → 解锁；
8. 记 `t3`；关闭 App（划走）；
9. 抓取 `bridge.log` `[t0, t3]` 窗口，跑：
   ```
   node Scripts/interruption-dedup.mjs --log <bridge.log> --window <t0>~<t3>
   ```

**预期观察**（新字段落地后可核对）：
- `per_instance.ptt / error_speech / welcome / selfcheck` 各有多少条；
- `per_reason` 中 `default` / `app_was_suspended` / `built_in_mic_muted` 的分布；
- `per_state.began ≫ per_state.ended`（现有假说：ended = 0）；
- `dedup_ratio` 是否 = 每次系统事件里存活的 observer 数（不是恒定 4，本 PR 的 E1 数据表明真实值约 2–3）。

## 2 · 情境 B · 蓝牙耳机（AirPods）

对照组：ESS-217 里 `Bluetooth → 4/4 activated`。同 §1 的 1–9 步，唯一差别是**保持耳机连接**。

**预期观察**：
- `session_activated` 频率显著高于 Speaker 组；
- `session_interruption began` 数量 vs Speaker 组的差异（若显著更少，说明 `!res` 与中断风暴同源）；
- `route_out` 字段全程为 `BluetoothA2DPOutput(...)`（新 E4 字段）。

## 3 · 情境 C · 主动触发 `.appWasSuspended` 假说

目的：**验证或排除**「.ended 从不投递」的最强系统侧解释。

1. 蓝牙耳机连接；App 在前台成功播过一段（保证会话已激活）；
2. 划走 App 让它进 background；
3. 立即（≤ 3s 内）在 iPhone 上启动 Siri（这会抢占系统音频会话）；
4. 等 30s；
5. 关掉 Siri（说「取消」或按数字表冠回主页）；
6. 抬腕回到手表 App，让 scene 转 `active`；
7. 立即抓 `bridge.log` 里最近一条 `session_interruption` 的 `reason=` 字段。

**判定**：
- 若 `reason=app_was_suspended` 命中：确认 `began` 是 App 被挂起时补发，`.ended 从不来`的路径就有系统合同层面的解释——**这就是 Phase 2 要绕过的机制**；
- 若一直是 `reason=default`：`app_was_suspended` 假说被排除，Phase 2 要走另一路（比如 route change 观测而非 interruption）。

## 4 · 情境 D · 录音↔播放交替（会话相容性）

目的：把 ESS-137/ESS-72 修的「录音会话未交还导致播放 `!res`」与「began 风暴」拆开——两者常在同一时段发生。

1. 裸手表；从冷启动开始（关掉 App 后重开）；
2. 长按录音 2s → 松手 → 立即等结果语音；
3. 结果语音一到，立刻再长按录音 2s → 松手 → 等结果语音；
4. 重复 5 轮；
5. 抓 `bridge.log` `[cold_start, +5min]` 窗口。

**预期观察**：
- 每次「录音结束 → 播放请求」窗口内的 `session_interruption began` 数量；
- 是否伴随 `session_activation_failed policy=long_form ... route=Speaker ... other_audio=no`（新 E4 字段能证明「不是别人在播」）；
- `per_instance.ptt`（对应 `PushToTalkController.player`）是否为 began 主要来源。

## 5 · 结论字段

复现完成后按 E1~E5 在本单落一条 comment：

- **E1**：每个 instance 的 observer 生命周期（注册/移除 时间戳）
- **E2**：dedup 结果（raw_lines / deduped_events / dedup_ratio）
- **E3**：`per_reason` 分布，`app_was_suspended` 是否命中
- **E4**：会话状态快照 & 抢占方是否可识别（预期 watchOS 不提供，写「平台不提供」+ 依据）
- **E5**：本 runbook 走完的时间戳，供他人重跑

Phase 2 由 PM 放行才启动，且 [ESS-224](mention://issue/5def426f-0225-4f52-bb56-4cea5011ce36) 一并设计。
