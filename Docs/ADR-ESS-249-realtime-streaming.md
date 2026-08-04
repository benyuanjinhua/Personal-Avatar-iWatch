# ADR ESS-249：Realtime 语音流式交互

- 状态：提议（等待毕玄、多隆、Jackson、白梦林评审）
- 日期：2026-08-04
- 决策范围：Watch ↔ iPhone ↔ Bridge ↔ Realtime 的语音首音时延

## 目标与验收

核心目标是缩短“用户松手到 Watch 实际开始出声”的 TTFT，同时保留现有可靠文件链路作为回滚路径。进入实现前必须在同一 Watch、iPhone、网络和话术集上取得直答、长任务回执、长任务最终结果各不少于 20 个有效样本，并报告数据窗口、样本量、P50/P95 和分段耗时。

建议目标 `<800 ms / <1.5 s / <1.5 s` 仍是待外部对标与基线验证的假说，不是承诺。

非目标：本 ADR 不改变模型选择、任务语义、历史存储和 ESS-235 的 events WS、自愈、ACK 幂等职责；不一次性替换现有链路。

## 已确认现状

1. Watch 录音完成后才进入 `send(...)`，音频先落完整 m4a，再调用 `WCSession.transferFile`（`Watch/WatchVoiceTransport.swift:154-166,375-403`）。因此录音与上送不能重叠。
2. iPhone 只在 `didReceive file` 后读取完整文件并进入 inbox/relay（`iOS/PhoneConnectivity.swift:220-233`）；Relay 从 outbox 读完整 Data 后执行 HTTP upload（`iOS/WristAgentPhoneRelay.swift:217-235`）。
3. Bridge 已逐个收到 Realtime `audio.delta`，但当前 turn 只聚合处理；客户端播放开始回执并不等于 Watch 已出声（`MacRemoteFrontendBridge/supervisor.mjs:394-406`）。
4. 下行结果仍通过完整文件传到 Watch；Watch 读取全文件、校验 sha、原子写盘后才暴露结果（`Watch/WatchVoiceTransport.swift:114-151`）。
5. events WS、ping、重连和 snapshot/ACK 幂等已经存在（`iOS/WristAgentPhoneRelay.swift:299-380`），属于 ESS-235 边界，本轨道只复用，不重复实现。

以上代码事实证明当前链路存在整段门槛；它们不能替代真机 TTFT 基线，也不足以断言五段各自的占比。

## 候选方案

| 方案 | 上行 | 下行 | 收益 | 代价与风险 | 回退 |
|---|---|---|---|---|---|
| A. 有界优化 | 保持完整 m4a/transferFile | 保持完整 m4a/transferFile；优化转码与调度 | 改动最小、可靠性最高 | 录音与整段生成仍在关键路径，无法移除架构门槛 | 当前链路本身 |
| B. iPhone 分片中继（推荐 MVP） | Watch 每 20–40 ms 产 PCM/AAC chunk；可达时用 `sendMessageData` 分片到 iPhone，iPhone 立即用流式 HTTP/WS 转发 Bridge；不可达则整段文件降级 | Bridge 将 `audio.delta` 封装为有序 chunk，经已有 events WS 到 iPhone，再用 `sendMessageData` 到 Watch；Watch 以 jitter buffer 连续播放 | ASR 可与录音重叠；首个可播片到达即可播放；最大程度复用现有 iPhone/Bridge 连接 | `sendMessageData` 只适合 reachable 快路径，不是可靠队列；Watch 后台/可达性、乱序、背压需要真机验证 | 每回合按 feature flag 降级 A；未播成功则投完整 m4a |
| C. Watch 直连 Bridge/Realtime | Watch 直接双向 WS | 同一 WS 流式返回 | 跳过 iPhone 中继，理论跳数最少 | Watch 网络、认证、耗电、后台保活和密钥边界变化大；与现有可靠性组件重复，替换成本最高 | 切回 A/B |

不选 `updateApplicationContext` 承载音频：它表达“最新状态”，会覆盖旧值，不适合有序媒体流。不选 `transferUserInfo` 作实时媒体主通道：它面向系统托管可靠交付而非低延迟连续数据。`transferFile` 继续作为可靠整段降级通道。

## 决策

采用 B 作为受控 MVP，但必须先过两个技术探针：

1. 上行探针：同设备连续发送 20–40 ms chunk，记录 chunk 产生、Watch 发出、iPhone 收到、Bridge 收到四个时间戳；前台与抬腕/熄屏分别测丢包、乱序、P95 间隔和可持续时长。
2. 下行探针：固定 PCM 流经 Bridge → iPhone → Watch，记录首 chunk、buffer ready、`play_started`，验证 120–240 ms 初始缓冲下无爆音，并在中断时执行明确降级。

任一探针在目标场景不可稳定维持，则不进入 B 的生产实现，先交付 A，并保留重新评估 C 的退出路径。

## MVP 协议与边界

优先复用现有 events WS 与 request_id。媒体帧是版本化信封：

`protocol_version, request_id, stream_id, direction, sequence, captured_at_ms, codec, sample_rate, payload, payload_sha256, end_of_stream`

外部输入必须校验版本、UUID、序号窗口、大小、codec/rate 和摘要。每个 stream 有固定内存上限、最大时长和空闲超时。sequence 提供排序与去重；累计 ACK 只用于流控，不把每片持久化。最终完整音频继续走现有 sha + 文件 ACK，作为审计与失败补投路径。

职责边界：

- 本轨道：媒体 chunk、jitter buffer、首音指标、按回合灰度开关、流转整段降级。
- ESS-235：events WS 生命周期、心跳/重连、统一 request_id 与阶段时间戳、终态补投及 ACK 幂等。
- G9：为流式与降级两条链路增加回归门禁，并保留播放×录音等双向/并发冒烟。

## 缓冲、背压与播放

- 起播水位初值 180 ms，允许灰度配置 120–240 ms；只在连续 sequence 达到水位后发 `play_started`。
- 缺片等待最多 80 ms；超时先播放已连续部分，再进入一次降级。禁止把后续片直接拼到缺口后制造爆音。
- iPhone/Watch 队列达到上限时拒绝新片并记录 `stream_backpressure`，Bridge 停止该流并生成完整文件降级。
- `play_started` 的 TTFT 以 Watch 音频引擎确认的运行时事件为终点，不使用 Bridge 的 `playback.started` 代替。

## 新增失败模式与用户行为

| 失败模式 | 系统行为 | 用户可感知行为 |
|---|---|---|
| 首片后断流 | 等待 80 ms，停止半句，清空 buffer，切整段补投 | 短暂停顿后从完整回应重新播放；不静默结束 |
| 乱序/重复 | 窗口内重排、按 sequence 去重；越窗降级 | 最多一次短暂停顿，不重复句子 |
| Watch 不可达/进入后台 | 不启动或立即终止快路径，保留完整文件 | 显示等待手机/稍后播放，恢复后完整播报 |
| 录音中结果到达 | 结果入队，不抢占录音会话；录音结束后播放 | 录音不中断，随后听到结果 |
| 灰度协议不兼容 | 协商失败，按回合选择 v1 文件链路 | 无额外提示，功能保持可用 |
| 分片摘要/大小非法 | fail closed，记录 request_id 与错误码，完整链路重试 | 显示可重试错误或播放完整降级结果 |

这些用户行为需与轨道 A/D1 的统一错误卡和半句处理文案对齐。

## 灰度、迁移和回滚

1. 默认 `voice_streaming_v2=false`；Bridge 只向声明 capability 的同版本 iPhone/Watch 开启。
2. 灰度单位为 device_id + request_id，单回合不可在未知状态下混用两条主链路。
3. 顺序：只观测影子上行 → 1% 内部设备上行 → 下行探针 → 1% 双向 → 10% → 50% → 100%。每级比较 TTFT P50/P95、完成率、降级率、音频中断率。
4. 自动熔断：窗口内完成率或音频中断率越过评审确定阈值，停止新流；在途流落完整 m4a 后补投。
5. 回滚只需关闭服务端 flag；v1 文件协议、outbox、ACK 和播放器在完整灰度期内不删除。

## 基线测量契约

数据窗口必须覆盖一次明确 build 与设备组合。每个场景至少 20 个有效 request_id，固定话术轮换，记录网络类型与信号条件。原始表每行一个 request_id：

`scenario, build, watch_model, watchos, iphone_model, ios, network, request_id, record_start_ms, record_end_ms, watch_send_ms, phone_receive_ms, bridge_accept_ms, realtime_first_event_ms, realtime_first_audio_delta_ms, transcode_done_ms, phone_downlink_enqueue_ms, watch_audio_stored_ms, watch_play_started_ms, outcome, exclusion_reason`

核心 TTFT：`watch_play_started_ms - record_end_ms`。同时单独报告“从开始说话到首音”，但不得混称 TTFT。分段为：Watch→Phone、Phone→Bridge、Bridge→首 audio delta、首 delta→下行入队、下行入队→Watch 起播。当前整段链路另报录音时长和完整生成/转码耗时，避免互相重叠重复计数。

只排除缺失 request_id、明确用户取消、设备日志时钟异常的样本；必须同时报告排除数和原因。P50/P95 使用 nearest-rank，并附原始 CSV，不只贴聚合数。

## 实施门禁

- 基线三场景均达到 n≥20，原始数据可复核；
- WatchConnectivity 双向流式探针有真机运行时日志；
- ADR 四方确认并确定目标值及熔断阈值；
- 新旧链路及降级路径进入 G9；
- 才能开始业务实现。
