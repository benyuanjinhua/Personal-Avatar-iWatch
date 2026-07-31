# ESS-30 端到端集成验收与真机测试矩阵报告

- 日期：2026-07-31
- 执行人：多隆（Agent）
- 依据：《Jackson'Avatar for Apple Watch 技术架构设计 v2.1》§10 P1 验收 / §11 / §12
- 环境：Mac（jacksonmac，Darwin 25.4.0）；qwen-audio-agent v0.9.1（loopback `127.0.0.1:3101`，LaunchAgent `com.qwen-audio-agent.gateway`）；Codex 后端（`codex-acp@1.1.7`，ACP over stdio，`QWEN_AUDIO_AGENT_BACKEND_PERMISSION_MODE=native`，工作目录白名单 `~/Documents/code/Personal-Avatar-iWatch`）；Node 26.4.0；Xcode 26.6；watchOS/iOS 模拟器。
- 被测代码：ESS-23/25/26/27 附件交付物（Bridge、Supervisor、AudioPipe、TaskProjection）+ 仓库分支 ESS-22/28/29 合并出的集成分支 `agent/duolong/ess-30-e2e-acceptance`（本报告随分支归档）。

## 0. 结论摘要

全链路 `Watch(模拟客户端) → Bridge → Qwen Realtime → spawn_thinking → ACP → Codex → SSE/REST → 原路返回` 在真实网关上打通，幂等、SSE 恢复、异步交付、凭据隔离全部通过。**两项 P1 验收未达标**：

1. **权限确认链路失效（安全缺口，P1 阻断项）**：Codex 工作目录内的写操作**不弹权限确认直接执行**；工作目录外的写操作被沙箱拦住但**同样不产生权限请求**，任务无限挂起（实测 8.9 分钟无终态，靠手工 DELETE 收尾；北向唯一兜底是 Bridge 的 300s 硬超时）。
2. **直答完成延迟 P95 ≈ 9.5s**（标准要求 P95 < 3s）；受理回执 P95 < 20ms 达标。

另发现一项可靠性风险（连续多 turn 后 Realtime 会话停摆）与一组仓库集成缺陷（已在集成分支修复）。详见 §3。

## 1. §10 P1 验收逐项结果

| 验收标准 | 结果 | 证据 |
|---|---|---|
| Watch → iPhone → Mac → Qwen → Codex → Watch 全链路 | ✅（Mac 侧真网关；Watch/iPhone 硬件段见 §4） | e2e-real：真实 AAC 语音「统计仓库文件」→ `spawn_thinking` → Codex 后台任务 `work_43b20046…` → SSE 投影 accepted→background_running→completed → 文本结果回传，52s 完成 |
| Watch 退出页面后任务继续、重开可恢复 | ✅ | ESS-27 live-restart：投影进程销毁后任务在网关继续，从恢复账本重建投影续接终态，只读续接不重放创建 |
| **Codex 写操作一定触发权限确认** | ❌ **未达标** | 见 §3 发现 F1：工作目录内写操作零确认直接落盘；目录外写操作无权限请求且任务挂死 |
| 直答响应 P95 < 3s | ❌ 未达标（P50 ≈ 3.1s，P95 ≈ 9.5s） | 7 次真网关直答：成功 5 次（2.05 / 2.83 / 3.08 / 9.45 / 9.47s，含答案语音合成与注入），失败 2 次（见 F2） |
| 后台受理回执 P95 < 3s | ✅ | 全部 9 次受理回执 5–17ms |
| 后台 300s 内完成/失败/取消 | ✅ | 实测后台任务 44–52s 完成；300s 硬超时两阶段（实时中止注入 / 后台先 DELETE 再投影 `ERR_WORK_TIMEOUT`）mock 验证通过（缩短时长），ESS-26 真网关已实测 |
| SSE 中断经 REST 恢复，不丢结果、不重复 Work | ✅ | ESS-27 live-recover 本轮复跑：掐断 SSE → 重连成功 → 永久禁用 SSE → REST 指数退避轮询交付终态，terminalCount=1，session 任务数不变 |
| Watch 先收「已受理」、离线后仍收到结果 | ✅（Mac 侧） | ESS-27 live：受理后立即断开 Realtime WS（模拟用户离线），结果仍按同一 `request_id` 交付，不依赖安全播报窗口 |
| 同一 `request_id` 重试不产生第二次执行 | ✅ | e2e-real 直答与后台两条路径均 `idempotent_replay: true`；mock 覆盖同 id 不同 body → `409 ERR_IDEMPOTENCY_CONFLICT`、跨重启幂等 |

## 2. 本轮执行的测试

| 套件 | 范围 | 结果 |
|---|---|---|
| ESS-26 Bridge mock 验收（`npm test`） | 鉴权（篡改签名/重放 nonce/未知设备/未签名 WSS）、幂等、生命周期、300s 超时、权限、取消、WSS 事件、防御性解析（HTML 不当 JSON）、重启恢复 | **13/13 通过** |
| ESS-26 `test/e2e-real.mjs`（真网关） | 直答 + 后台全链路、幂等重放、WS 状态序列、结果音频转码（79KB m4a 回传） | 通过 |
| ESS-30 latency 采样（新增 `test/ess30-live.mjs`，真网关） | 7 次直答（TTS 生成的 22.05kHz AAC 中文语音，经 audiopipe 抗混叠重采样 16k 注入） | 5 成功 / 2 次 `ERR_REALTIME_TIMEOUT`（F2） |
| ESS-30 权限实测（真网关，真实 Codex 写操作） | 工作目录内写 / 目录外写 × allow/deny | **暴露 F1 缺口** |
| ESS-27 mock 12 场景 | SSE 断流/恢复/HTML 兜底/硬超时/取消竞态/权限链/结果裁剪/进度限流/task_lost/账本 | **12/12 通过** |
| ESS-27 live-recover（真网关，本轮复跑） | SSE 杀死→重连→REST-only 恢复 | 通过 |
| Swift 单元测试（集成分支） | WristAgentCore 全部共享模型/outbox/journal/vault | **66 XCTest + 5 swift-testing 全通过** |
| 模拟器构建 | `WristAgent Watch App`（watchOS Sim）、`WristAgent`（iOS Sim） | 均 BUILD SUCCEEDED |
| 安全扫描 | 网关日志/Bridge 运行日志中 DashScope Key 与 AUTH_SECRET 命中数；Watch/iOS/Shared 代码硬编码凭据扫描 | 全部 0 命中 |

ASR 质量佐证：本轮 22.05kHz AAC TTS 样本经管线转 16k PCM 后，问题与写指令均被正确识别并执行（文件名中英混读仅丢首字母，属 ASR 正常误差）；ESS-25 已有 44.1/48kHz 与 16k PCM 基线对比结论（不明显劣于基线）。

## 3. 关键发现

### F1（阻断，安全）：Codex 写操作权限确认链路实际不生效

- **现象 A**：语音指令「在仓库根目录创建文件」→ `spawn_thinking` → Codex 直接创建文件并返回「写入成功」，全程无 `permission_required` 投影（`work_4983ab6e…`，40s 完成；文件实际落盘，测后已删）。
- **现象 B**：语音指令「在桌面创建文件」（工作目录外）→ Codex 卡在 `printf … > ~/Desktop/….txt` 工具调用 `in_progress`，沙箱拦截但**不升级为 ACP 权限请求**，任务 8.9 分钟无终态、无 authorization，直到手工 `DELETE /api/tasks/:id`。桌面文件未创建。
- **判定**：网关→Bridge→北向的权限投影与应答链路本身是通的（ESS-24 曾闭环、ESS-26/27 mock 全覆盖），缺口在 **codex-acp 与 Codex 的审批策略**：默认沙箱对工作目录内写自动放行（不问）、对目录外写只拦不问。`native` 权限模式 ≠ 每次写都确认。
- **影响**：§10「Codex 写操作一定触发权限确认」不成立；Watch 端 PermissionRequestView 在真实写场景永远不会出现。
- **建议**：投产前必须把 Codex 启动参数改为「写操作走 ACP 审批」（例如 sandbox read-only + approval on-request，具体以 codex-acp 支持为准）并重测两种路径；在修复前，不应向真实用户开放写操作任务。同时建议网关为 `running` 任务加服务端超时（目前仅靠客户端取消，Bridge 300s 是唯一兜底）。

### F2（高，可靠性）：常驻会话连续多 turn 后 Realtime 停摆

- 同一常驻 WS 会话连续注入 2–3 个 turn 后，后续注入不再收到任何 Realtime 响应，Bridge 在 `turn_timeout_ms=120s` 处以稳定错误 `ERR_REALTIME_TIMEOUT` 失败（不挂死、不误报成功）。7 次直答中 2 次命中，且一旦停摆连续 turn 均失败。
- Supervisor 仅靠应用层 ping 识别僵尸连接后重连；**turn 超时不触发强制重建连接**，停摆状态不会自愈。
- **建议**：turn 超时即回收并重建 Realtime WS（含新 sessionId 的退避重连），并把「连续 N 次 turn 超时」计为会话不健康信号。

### F3（中，性能）：直答完成延迟未达 P95 < 3s

- 受理回执 5–17ms，远优于 3s。直答完成（含 Qwen 生成答案语音、24k 聚合、audiopipe 转码回传）成功样本 2.05–9.47s，P95 ≈ 9.5s。长答案（如概念解释）显著拖尾。
- **建议**：如需达标，可先回传文本（受理即答）再补语音，或对直答限制答案长度/语速合成并行化；或与产品侧确认把 P95<3s 的口径改为「首个可感知响应」。

### F4（中，集成/仓库）：Stage-2 两分支从未真正集成，存在编译级冲突

- ESS-28（`review-pr3`）与 ESS-29（`agent/duolong/ess-29-watch-voice-ui`）各自基于 ESS-22 开发：`WCSession` delegate 三个回调冲突；`Shared` 层重复定义 `VoiceTurnPhase` / `VoiceTurnEvent` / `VoiceResultPayload`（两套语义不同的同名类型），合并即编译失败。
- 已在集成分支解决：delegate 回调按 key 分流同时服务两条链路（relay 回执 + 状态信封）；relay 侧 wire 类型更名为 `VoiceRelayPhase` / `VoiceRelayEvent` / `VoiceRelayResultPayload`；`project.pbxproj` 由 XcodeGen 重新生成。66+5 测试全通过，双端模拟器构建成功。
- 另：GitHub 远端 `Repository not found`（与 ESS-23/25/26 相同 blocker），PR #2/#3/#5 元数据指向不可达远端；集成分支与本报告仅能本地归档，远端恢复后需推送。

## 4. 真机测试矩阵（§12 实施门槛逐项）

「真机」指物理 Apple Watch + iPhone + Tailscale 组网段。本轮无物理设备可用，Mac 侧可测项已全部实测；硬件段待人工执行（步骤见各 PoC README 与 ESS-22 验收标准）。

| §12 门槛 | Mac 侧证据 | 真机段状态 |
|---|---|---|
| WatchConnectivity 音频交付延迟 | —（纯硬件段） | ⏳ 待真机：10s 音频连续 20 次（ESS-22 验收），`transferFile` 队列延迟采样 |
| iPhone 后台限制/挂起 | Outbox 持久化与幂等重试单测通过（VoiceOutboxTests） | ⏳ 待真机：后台挂起→恢复补投、本地通知提醒 |
| 压缩音频 → PCM 的 ASR 质量 | ✅ ESS-25 44.1/48k AAC vs 16k PCM 基线 + 本轮 22.05k AAC 全部正确识别 | ⏳ 真机麦克风样本复核（预期低风险） |
| 常驻 WS 恢复 | ✅ 断线退避重连、僵尸检测（ESS-25/26）；⚠️ F2：turn 超时不触发重建 | 不涉及 |
| 语音所有权冲突 | ✅ ESS-25 三 Bridge 互斥实测：独占、僵尸才 takeover、不周期抢占 | ⏳ Mac 本机语音 UI 并用时的真机复核 |
| Task SSE 恢复 | ✅ 本轮 live-recover 复跑通过 | 不涉及 |
| Codex ACP 兼容性（setup/权限/取消/固定 Session） | setup ✅、取消 ✅（含 409 竞态）、固定 Session 复用 ✅；**权限 ❌ = F1** | 不涉及 |
| Watch 离线异步交付 | ✅ Mac 侧（受理后断开 Realtime 仍交付） | ⏳ 待真机：Watch 熄屏/出网后经 iPhone 补投 |

## 5. 幂等与恢复验收

| 场景 | 结果 |
|---|---|
| 重复 `request_id`（同 body） | ✅ 真网关重放既有结果，不二次执行；跨重启由持久账本保证 |
| 重复 `request_id`（不同 body） | ✅ `409 ERR_IDEMPOTENCY_CONFLICT` |
| Bridge 重启恢复 | ✅ 有 `task_id` 的 turn 重挂 SSE/REST；注入结果未知的 turn → `ERR_RESULT_UNKNOWN` 转人工，不自动重跑 |
| SSE 中断 | ✅ 重连 + REST 退避兜底，终态恰好一次 |
| WS 断线/僵尸 | ✅ 退避重连、ping 检测；⚠️ F2 例外见上 |
| iPhone/Mac 离线恢复 | Mac 侧 ✅（幂等重试）；iPhone outbox 硬件段待真机 |

## 6. 安全验收

| 项 | 结果 |
|---|---|
| Watch/iPhone 不保存 DashScope/Codex/Vault 凭据 | ✅ 代码扫描 0 命中；Bridge 设备 token 存 Keychain（设计内） |
| 网关仅 loopback | ✅ `lsof`：3101 仅绑 `127.0.0.1`；Bridge 绑 loopback+Tailscale IP，从不 0.0.0.0 |
| 签名/nonce/防重放 | ✅ 篡改签名、重放 nonce、未知设备、未签名 WSS 均被稳定错误码拒绝（mock 13 项含全部负例） |
| Tailscale ACL 外不可达 | ⏳ 需 tailnet 内外真机验证（ESS-23 已配 ACL 仅允许 iPhone 节点访问 8443） |
| 日志无 Token/DashScope Key/原始权限载荷/完整私密笔记 | ✅ 网关日志与全部本轮运行日志对 Key 前缀与 AUTH_SECRET 检索 0 命中 |
| DashScope Key 存放 | ✅ `~/.config/qwaudio/config.env`（0600、目录 0700，符合「受限配置文件」口径），不入仓库/Vault |
| Codex 权限 native 不自动 full | ✅ 配置为 native 且未回退 full；⚠️ 但 native 实际语义见 F1 |
| Bridge 红线（不直调 Codex CLI / 不透传命令行/目录/环境变量 / 不暴露网关管理 API） | ✅ 代码与测试确认 |

## 7. §11 风险表逐项状态

| §11 风险 | 状态 |
|---|---|
| WatchConnectivity 延迟不适合实时流 | 按半双工设计规避；真机延迟采样待执行（§4） |
| 系统不保证蓝牙传输 | 产品口径已定为「配对 iPhone 链路」，无需测试动作 |
| Qwen 无 watchOS 前端 → 窄 Bridge | ✅ Bridge 完整落地并通过验收 |
| v0.9.1 无任务提交 REST → 伪前端注入 | ✅ 注入路径稳定；⚠️ F2 连续 turn 停摆为新增已知问题 |
| Watch 文件与 PCM 流错配 | ✅ Codec Pipeline 验收通过（含本轮 22.05k 样本） |
| 语音所有权冲突 | ✅ Mac 侧互斥规则实测通过；真机并用复核待执行 |
| 上游 WS 无心跳 | ✅ Bridge 应用层 ping/超时/重连兜底；建议叠加 F2 修复 |
| Task 等待无总时长上限 | ✅ Bridge 300s 硬超时生效；⚠️ 网关侧无服务端超时（F1 现象 B 实证），建议上游加固 |
| Codex ACP 兼容性风险 | ⚠️ **部分成立**：setup/取消/固定 Session 通过；权限链路在真实写场景失效（F1），需按退出方案调整审批策略或受控 Adapter |
| DashScope 云端依赖 | 数据边界已明示；断网排队/报错路径 mock 覆盖，真机断网场景随 §4 执行 |
| iPhone 后台执行受限 | outbox 设计与单测就绪；真机挂起场景待执行 |

## 8. 遗留事项（建议后续 issue）

1. **修复 F1**：调整 codex-acp 审批策略使写操作必经 ACP 权限请求，真网关重测目录内/外 × allow/deny 四象限（阻断投产）。
2. 修复 F2：turn 超时触发 Realtime WS 强制重建。
3. 直答延迟策略决策（F3）：文本先行或口径修订。
4. GitHub 远端恢复后推送 `agent/duolong/ess-30-e2e-acceptance` 集成分支并补 PR；ESS-23/25/26/27 附件交付物按 ESS-26 README 规划入库为 `MacRemoteFrontendBridge` 等模块。
5. 真机矩阵硬件段（§4 ⏳ 项）由持有物理设备的人工执行。

## 附：测试产物

- 集成分支：`agent/duolong/ess-30-e2e-acceptance`（含本报告、合并修复、集成后的 pbxproj）
- 运行数据：latency 报告 JSON、权限实测日志、live-recover 输出（随验收评论附件归档）
