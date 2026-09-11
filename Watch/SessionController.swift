import AVFoundation
import Combine
import Foundation

/// ESS-573（Wave 1 / F1）：会话态主屏的进入/退出生命周期控制器。
///
/// PRD（ESS-540 §二/§3.5）的会话态模型在 Wave 1 只落地 F1 主干：
/// 点球进入、真实通道事件驱动 `connecting → listening / idle`、点 X 或
/// 下滑退出并真正释放麦克风、手势冲突处理（会话中禁用左右切屏、下滑
/// 拦截等同点 X）、首次引导。VAD 断句（F2）、打断（F4）、多轮连续（F5）
/// 在后续 Wave 实现，本控制器预留 `markTurnCommitted` / `markAnswerStarted`
/// 事件口但不自建第二套回合真相——聆听/思考/回答的球体投影由视图层
/// 从 `PushToTalkController` / `VoiceTurnJournal` / `SpeechPlayer` 的既有
/// 可观察量计算（与 PTT 屏 `orbMode` 同一口径），避免双真相源。
///
/// 复审硬约束（ESS-573 blocked 复审 2026-08-08）：
/// 「通道就绪」必须由**真实 realtime channel 事件**确认——本控制器只在
/// 收到 `markChannelReady`（首个被 iPhone 接受的 uplink ack，证明
/// Watch→iPhone→Bridge 全链路已通）后才进入 `listening`；绝不在
/// 发起录音后同步宣告 ready。失败同样只由真实事件驱动：
/// 录音启动失败 / 上行发送失败（WCSession 不可达或 sendMessage 报错）/
/// 适配器回退 / 就绪超时。
///
/// 触觉口径（PRD §3.5.5，与 ESS-180「同一次失败只震一下」一致）：
/// - 进入会话 `.start`：由 `PushToTalkController.pressBegan()` 既有的
///   `.recordingStarted`（同一 `WKHapticType.start`）兑现，本控制器不重复播；
/// - 通道就绪 `.click`、退出 `.stop`、通道类失败 `.failure`：本控制器持有；
/// - 录音启动失败：分身错误卡片（AvatarErrorPresenter）已播 `.failure`，
///   本控制器只回 idle，不再播、不再叠加文案。
@MainActor
final class SessionController: ObservableObject {

    // MARK: - 状态与投影

    /// F1 生命周期态。`listening` 涵盖 PRD 的聆听/思考/回答——会话**是否
    /// 存续**是本级真相。
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case failed
        case hungup
        case disconnecting
    }

    /// ESS-600（F5）：会话存续期内的回合相位。会话是否存续由 `state` 承担，
    /// 「这一轮走到哪」由本枚举承担——两者正交，不是同一个真相的两份拷贝。
    ///
    /// 本相位只由**真实链路事件**推进，没有任何一条边是本控制器自己想当然
    /// 走过去的：
    /// - `.listening → .thinking`：本轮上行真正提交（`submit` 完成）；
    /// - `.thinking → .speaking`：回答音频**真实起播**（realtime 首帧已渲染 /
    ///   SpeechPlayer `play()` 返回 true），收到 delta 不算；
    /// - `.speaking → .listening`：回答**真实播完**（realtime 最后一个 buffer
    ///   渲染完毕 / SpeechPlayer `.success` 终局），随即自动开下一轮采集。
    enum TurnPhase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    /// 会话级触觉（不含 enter——enter 由 pressBegan 既有触觉兑现）。
    enum Haptic: Equatable {
        case ready      // .click —— 「现在可以开口」的唯一信号，PRD 称为最重要的一次
        case exit       // .stop
        case failure    // .failure
    }

    /// 通道失败来源。`.recorderStart` 的触觉与卡片由既有错误链承担；
    /// 其余所有真实通道事件（上行发送失败 / 适配器回退 / 就绪超时）统一
    /// 走 `.channelEvent`——文案按失败时所处的会话态区分（建立中 vs
    /// 会话中），见 `failureCopy(forState:)`。
    enum ChannelFailure: Equatable {
        /// 录音/引擎启动失败（PushToTalkController 已呈现分身卡片 + 触觉）。
        case recorderStart
        /// 通道类失败：上行发送失败（WCSession 未激活/不可达或 sendMessage
        /// 报错）、快速通道中途死亡（适配器单发回退）、就绪超时。
        case channelEvent
    }

    @Published private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onSessionStateChange?(state)
        }
    }
    /// ESS-600：当前回合相位。`state != .listening` 时恒为 `.idle`。
    @Published private(set) var turnPhase: TurnPhase = .idle {
        didSet {
            // ESS-1100：处理中文案只在 thinking 相位可见。相位是它的唯一
            // 门闩，挂在 didSet 上是为了不漏掉任何一条相位边——漏一条就意味着
            // 一句「正在查询相关信息」挂在回答态上不走。
            guard turnPhase != oldValue else { return }
            refreshToolProcessingText()
        }
    }
    /// ESS-600：本地采集是否真的在跑。与「网络通道是否 ready」**独立呈现**——
    /// 建立期就已经在录音，用户必须能看到「表在听」，而不是只有一个
    /// 分不清死活的建立中动画（ESS-598 的「说话完全无反馈」正是这一条缺失）。
    @Published private(set) var isCapturingLocally = false
    /// 建立超过 800ms 未就绪 → 球下方三点渐显（PRD §3.5.1 第 3 步，
    /// 唯一允许的非文字提示）。
    @Published private(set) var showConnectingDots = false
    /// 通道类失败的一行短文案（PRD 异常链 A/B：全 PRD 唯一允许状态文字处），
    /// 2 秒后自动消失；文案说清「怎么办」而非「什么错了」。
    @Published private(set) var failureNotice: String?
    /// 首次进入引导「说话就行，说完停一下」（PRD §3.5.7）——只出现一次，
    /// 3 秒淡出；持久化在 UserDefaults，重装前不再出现。
    @Published private(set) var showFirstRunGuide = false
    /// ESS-652: P6 失败原因文案，由 `enterFailed(reason:)` 设置，
    /// P6 视图据此显示一行说明。nil 时 P6 不可见。
    @Published private(set) var failedReason: String?
    /// ESS-652: P6 是否可重试。就绪超时类失败可选重试，后台/系统中断不可重试。
    @Published private(set) var failedRetryable = false
    /// ESS-652: P7 挂断摘要，由 `enterHungup(rounds:reason:)` 设置。
    /// nil 时 P7 不可见。
    @Published private(set) var hungupSummary: String?
    /// ESS-652: 思考慢提示（25s 无回答），球下方文字。
    @Published private(set) var thinkingSlowHint = false
    /// ESS-891：回答真实起播时系统输出音量过低 → 提示用户调高音量。应用
    /// 无法编程式改系统音量（`AVAudioSession.outputVolume` 只读），这是唯一
    /// 可行动的应用侧手段。仅 speaking 期间有效，离开 speaking 即清除。
    @Published private(set) var lowVolumeHint = false
    /// ESS-1100：**工具回合**思考期该显示的那一行处理中文案。
    ///
    /// - `nil` = 本回合没有任何工具证据（普通直接回答）。视图沿用既有的
    ///   「正在思考…」，一个字都不变——这是验收 3「普通直接回答不产生多余的
    ///   处理中跳转」的结构性保证：没有工具信号就走不进这条分支。
    /// - 有工具证据但还没收到进展文字 → 稳定兜底「正在处理」（ESS-1100 §5）。
    /// - 收到真实进展 → 上游那句话（如「正在查询相关信息」）。
    ///
    /// 值本身由 `refreshToolProcessingText()` 从
    /// `turnPhase` + `toolTurn.hasToolEvidence` + 节流后的进展文本推导，
    /// 不是第二个真相源。
    @Published private(set) var toolProcessingText: String?

    /// ESS-1111：本回合**正在流出的答案文本**（`nil` = 本回合还没有任何答案
    /// 增量）。它与 `toolProcessingText` 是两件事，刻意分开：前者说的是「系统
    /// 在做什么」，后者是「答案本身」。把答案挤进那一行状态字，等于用一行 14
    /// 字的预算去装一段回答。视图只读不写；音频播放不依赖它，它也不阻塞音频线程。
    ///
    /// **屏幕上只有这一处答案**，但喂它的上游有两条，合并 #412 / #413 时按
    /// 下面的优先级收敛（`refreshStreamingAnswerText`）：
    ///
    /// 1. `answerStream`（`AnswerStreamAssembly`，按 `answer_seq`）——网关
    ///    升级后真正的答案流，未经截断，是**权威**来源；
    /// 2. `answerTranscript`（`LongTaskAnswerTranscript`，按 `progress_seq`
    ///    且 `progress_category == "answer"`）——网关尚未升级时的兼容入口。
    ///
    /// 两条**各自独立的序号空间**，因此各留一套闸门：把 `answer_seq` 与
    /// `progress_seq` 塞进同一个单调闸门，会让交替到达的两条流互判「乱序」
    /// 而彼此丢弃。一旦权威流出过内容，本回合此后只认它——`progress_text`
    /// 在网关侧已按 24 字截断，让一段截断文本去覆盖完整答案是纯粹的退化。
    @Published private(set) var streamingAnswerText: String?

    /// 会话是否存续（连接中/聆听中）。视图据此切换双模 UI 与手势集。
    var isInSession: Bool {
        switch state {
        case .connecting, .listening, .failed: return true
        case .idle, .hungup, .disconnecting: return false
        }
    }

    // MARK: - 可注入接缝（测试确定性）

    /// 触觉播放接缝：生产由 WatchAppServices 接到 WatchHaptics；测试记调用。
    var playHaptic: (Haptic) -> Void = { _ in }
    /// ESS-891：系统输出音量读取接缝。生产默认读真实 AVAudioSession；
    /// 测试注入固定值做 0.5/1.0 对照（真机对照的确定性镜像）。
    var readOutputVolume: () -> Float = { AVAudioSession.sharedInstance().outputVolume }
    /// 延迟执行接缝：生产用 Task.sleep；测试收集闭包手动触发，零睡眠。
    /// 返回取消令牌；已取消的闭包不得再触发语义（由本控制器用令牌失效兜底）。
    var scheduleDelay: (TimeInterval, @escaping @MainActor () -> Void) -> SessionDelayToken =
        { seconds, fire in SessionTaskDelayToken(seconds: seconds, fire: fire) }

    // MARK: - 动作出口（由 WatchAppServices 接到 PushToTalkController）

    /// 进入会话时发起通道：生产接 `PushToTalkController.pressBegan()`
    /// （与 PTT 同一录音/实时上行链；`.start` 触觉在该链内部兑现）。
    /// 返回本轮的 `request_id`——点球进会话时录音已在 touch-down 开始，
    /// 该返回值就是那一轮已在飞的 id，本控制器据此把它认领为第 1 轮，
    /// 绝不重复发起（重复发起会当场把用户正在说的话打断）。
    var onBeginChannel: (() -> String?)?
    /// ESS-540 F6: fired on every state transition so external keep-alive
    /// (e.g. HKWorkoutSession) can start/stop in sync with the session.
    var onSessionStateChange: ((State) -> Void)?
    /// ESS-600：自动开启下一轮采集。生产接
    /// `PushToTalkController.beginSessionTurn()`（程序化 pressBegan）。
    /// 返回新一轮的 `request_id`；nil = 启动失败，本控制器如实记账并停在
    /// 空相位，等真实失败事件（`markChannelFailed`）收口，不假装还在听。
    var onStartTurn: (() -> String?)?
    /// 退出会话时拆链：生产接 `PushToTalkController.endSessionChannel()`
    /// （停采集、取消未提交实时回合、取消进行中回合、deactivate 会话级音频）。
    var onTeardownChannel: (() -> Void)?
    /// 单轮时长到上限：生产接 `PushToTalkController.endSessionTurn()`
    /// （视同松手提交本轮；PRD F2 的 60s 单轮上限，VAD 自动断句为常态路径，
    /// 本入口退居上限兜底）。
    var onCommitTurn: (() -> Void)?
    /// ESS-600（F4 手动打断）：speaking 中点球 → 立刻停播。生产接
    /// `PushToTalkController.interruptAnswerPlayback()`（realtime 走
    /// barge-in 请求换代，m4a 走 player.stop），停播后本控制器直接开下一轮。
    /// ESS-650（F2-3）：入参是触发源（只影响停播日志——两种打断共用同一条
    /// 停播路径，不另起第二条）；返回值 = **停播确认**（两个播放器都不再
    /// 出声）。`stop_ms` 量到这个返回为止才是停播延迟。
    var onInterruptSpeaking: ((PhoneModeTelemetry.InterruptSource) -> Bool)?
    /// ESS-650（F2-2）：进入 speaking 时开启「只听不传」的打断监听。
    /// 生产接 `PushToTalkController.beginVoiceBargeInListening()`。
    ///
    /// ESS-673：本组接缝由 PR #281 落地、被 PR #270 的冲突解决整段删掉，
    /// 此处恢复。删掉之后 `WatchAppDelegate` 与 `VoiceBargeInWiringTests`
    /// 的调用方失去被调方，main 连编译都过不去。
    var onBeginBargeInListening: (() -> Void)?
    /// ESS-650：结束打断监听。`reason` 区分 `answer_finished` / `interrupted` /
    /// `gate_off` / `session_exit`，让「gate 动态关闭即时停采」在日志里可判定。
    /// - Returns: 本轮对账单（帧数 / 自身回声帧数 / 峰值能量），会话层据此落
    ///   F2-5 的两条证据（见 `stopBargeInListening`）；nil = 本来就没在监听。
    var onEndBargeInListening: ((_ reason: String) -> WatchRealtimeMediaAdapter.BargeInRoundSummary?)?    /// ESS-650（F2-4）：语音打断开关，**默认 OFF**。生产接
    /// `WatchDebugSettings.voiceBargeInEnabled`；F2-5 未通过不得默认 ON。
    var voiceBargeInEnabled: () -> Bool = { false }
    /// ESS-1111：重连宽限到点。会话层不直接持有适配器，由本回调把「不用再等了」
    /// 交回给推迟着传输失败的那一层。
    var onDownlinkGraceExpired: ((_ reason: String) -> Void)?
    /// ESS-1111 复审整改（阻断 2）：下行**恢复**的唯一裁决点在会话层，
    /// 经本回调通知适配器撤销那次被推迟的收口。适配器不再自己判一次。
    var onDownlinkResumed: ((_ reason: String) -> Void)?
    /// ESS-600：就绪超时的**抢救**出口——把已经录到的语音经可靠通道
    /// （完整文件 / WCSession transferFile）提交，而不是连人带话一起丢。
    /// 生产接 `PushToTalkController.endSessionTurn()`。
    var onSalvageTurn: (() -> Void)?

    // MARK: - 参数（PRD 数值，【待调】项需真机体感定稿）

    /// 建立中超过该时长未就绪 → 显示三点提示。PRD §3.5.1：800ms。
    static let connectingDotsDelaySeconds: TimeInterval = 0.8
    /// 就绪硬超时：首个真实 ack 未到即判失败。【待调】初值 5s——
    /// 经验值：WCSession 投递 + iPhone WSS 首发确认正常 < 2s；
    /// 15s（iphone_relay_stuck）对本场景过长，用户在建立中干等不可接受。
    static let readyTimeoutSeconds: TimeInterval = 5.0
    /// 失败文案停留时长。PRD 异常链 A/B：2 秒后自动回待机。
    static let failureNoticeSeconds: TimeInterval = 2.0
    /// 首次引导停留时长。PRD §3.5.7：3 秒淡出。
    static let firstRunGuideSeconds: TimeInterval = 3.0
    /// 单轮时长上限（PRD F2 异常：单轮 60 秒强制结束）。抢在 AudioRecorder
    /// 的 60s 系统硬顶之前走正常 finishRecording 提交。
    ///
    /// ESS-865：58s 是**不够**的——本计时器从 `session_channel_ready` 起算，
    /// 而 60s 硬顶从 `record_started` 起算，两者之间隔着一整个建立窗口
    /// （真机 `establish_ms=1650`）。真机 L1：cap 到点时录音已跑 61.9s
    /// （`raw_ms=61912`），AVAudioRecorder 早已自停。留 10s 余量覆盖建立窗口
    /// 抖动；正常路径由 VAD 断句提交，本条只是上限兜底。
    static let turnCapSeconds: TimeInterval = AudioRecorder.maxDuration - 10.0
    /// ESS-600：`thinking` 的有界执行上限。回答永远不来（Bridge 静默 /
    /// `done` 零音频 / 下行整段丢）时，没有这条兜底会话就永久卡在思考态，
    /// 麦克风关着、球在转，用户只能杀 App——比报错更糟。到点如实记
    /// `session_thinking_timeout` 并回到聆听，让用户能再说一遍。
    /// 120s【待调】：长任务走 `backgroundAccepted` 通知链，不靠这条兜底。
    static let thinkingTimeoutSeconds: TimeInterval = 120.0
    /// ESS-1097：**工具回合**的绝对等待上限，从「首次观测到工具工作」起算，
    /// 一轮之内**只武装一次**，绝不因为 `task.progress` 刷新而顺延——
    /// 顺延就等于把「不能永久锁死」这条验收写成了空话。
    ///
    /// 为什么不能沿用 45s（`thinkingHardTimeoutSeconds`）：ESS-1095 真机取证里
    /// `task.progress` 到 42.5s 仍在跳，个人文章查询 / 飞书日程创建都可能更久。
    /// 45s 到点判失败会把**正常**的工具回合杀掉，正是本单验收 2 要求消除的
    /// 「UI 提前放弃」。180s【待调】≈ 观测到的最长工具回合的三倍余量；
    /// 到点仍走与 45s 完全同构的 `enterFailed` 收口路径，不新造终态。
    static let toolTurnHardTimeoutSeconds: TimeInterval = 180.0
    /// ESS-1111：长任务的**静默**预算 —— 从最后一帧合法任务活动
    /// （`task.state` / 进展 / 答案增量）起算，到点仍无任何上游音讯即判失败。
    ///
    /// **它替代的是什么**：ESS-1109 真机取证里，任务在跑、网关每秒都在下发
    /// `task.running`，客户端却在 12.107s 断了连接。任何以「固定时长」或
    /// 「没有音频」为判据的退出，在长任务上都必然误杀——上游正在说话，只是
    /// 说的不是音频。本预算的判据换成了唯一正确的那一个：**上游有没有在说话**。
    /// 收到任何合法帧即整体重置。
    ///
    /// **它与 `toolTurnHardTimeoutSeconds` 的分工**（ESS-1097 的一次只武装、
    /// 绝不顺延的绝对上限**原样保留**，本单一个字没动）：绝对上限保证「不会
    /// 永久锁死」，本预算保证「上游真死了的时候不用干等到绝对上限」。两条都
    /// 有界，且本预算恒紧于绝对上限，因此加它只会让失败**更快**被判定，不会
    /// 让任何一个还在推进的任务被提前杀掉。
    ///
    /// 60s【待调】：真机观测到的帧间隔是**每秒一帧**，60s 因此是它的六十倍
    /// 余量，足以吸收上游一次长工具调用期间的下发空档。
    ///
    /// 取值刻意**避开 45s**（`thinkingHardTimeoutSeconds`）：两条语义不同的
    /// 预算共用同一个数字，日志里的「45s 到点」与测试里的「45s 被武装」就
    /// 再也分不出是哪一条，可判定性当场消失。
    static let taskActivityTimeoutSeconds: TimeInterval = 60.0
    /// ESS-1111：下行断开后等待**重连并继续接收同一 task** 的有界宽限。
    ///
    /// 断线不等于任务结束（真机：客户端 12s 断开时任务还要再跑 11.9s 才出
    /// 答案）。宽限期内 task identity 原样保留、回合不收口、不开下一轮；
    /// 到点仍未恢复才按明确终态收口。20s 与
    /// `WatchRealtimeMediaAdapter.transportFailureDrainDeadlineSeconds` 同阶，
    /// 两者共同覆盖「音频还在放」与「任务还在跑」两种断线形态。
    static let downlinkReconnectGraceSeconds: TimeInterval = 20.0
    /// ESS-1100：两次进展文字刷新之间的最小间隔（防高频闪烁，§5）。
    ///
    /// 上游 `task.progress` 是按 `backend.activity` 逐条发的，一次工具密集的
    /// 回合能在一秒内连发好几条。手表那一行字如果跟着逐条重画，读到的是闪烁
    /// 而不是信息。0.8s【待调】≈ 一眼读完一句四到八字短语的时间。
    ///
    /// 节流**不丢最后一条**：窗口内到达的新文本存为 pending，窗口一到就补上。
    /// 丢掉最后一条等于让手表停在一句过期的进展上，比闪烁更糟。
    static let progressUpdateMinIntervalSeconds: TimeInterval = 0.8
    /// ESS-600：一轮没产生任何提交（说得太短 / 收尾抛错）后重开采集的
    /// 退避。Watch 无 AEC，错误提示语音正在外放时立刻开麦会被自己的
    /// 声音再次触发 VAD，形成「太短 → 报错 → 又太短」的自激循环。
    /// 1.5s【待调】≈ 一句错误提示语音的长度。
    static let abortedTurnRelistenDelaySeconds: TimeInterval = 1.5
    /// ESS-891：系统输出音量（0.0–1.0）低于此值时提示调高音量。
    /// 【暂定阈值 · 单点外推】依据仅一次真机观测 `output_volume=0.500` 不可听，
    /// 取 0.6 留余量；未做 50%/100% 同场对照与多设备采样（R-04.4），0.55 等
    /// 临界用户可能听得清却被反复提示——待真机对照校准后再定稿。
    static let lowVolumeHintThreshold: Float = 0.6
    // MARK: ESS-652 超时与静默治理
    /// 思考慢提示：提交后无回答 > 此值显示慢提示。
    static let thinkingSlowHintSeconds: TimeInterval = 25.0
    /// 思考硬超时：进入 P6。
    static let thinkingHardTimeoutSeconds: TimeInterval = 45.0
    /// 静默 1 级提示。
    static let silenceHint1Seconds: TimeInterval = 30.0
    /// 静默 2 级提示 + 触觉。
    static let silenceHint2Seconds: TimeInterval = 75.0
    /// 静默挂断。
    static let silenceHangupSeconds: TimeInterval = 120.0
    /// P6 无操作自动挂断。
    static let failedAutoHangupSeconds: TimeInterval = 15.0
    /// P7 挂断页停留后回 idle。
    static let hungupDismissSeconds: TimeInterval = 1.2
    /// ESS-600【待调】：每轮自动回到聆听时是否复播 `.ready` 的 click。
    /// 打开的理由——ESS-598 真机反馈是「说话完全无反馈」，回答播完后麦克风
    /// 何时重开在无声无字的会话态里不可感知；复用用户在进会话时已经学会的
    /// 同一个「现在可以开口」信号，比新造一个提示更省认知。
    /// 若真机体感认为每轮都震过于聒噪，把这里改成 false 即可，无其它耦合。
    static let hapticOnAutoRelisten = true
    /// 首次引导的 UserDefaults 键。
    static let firstRunGuideShownKey = "ess573_first_run_guide_shown_v1"

    private let defaults: UserDefaults
    private var enteredAt: Date?
    private var dotsToken: SessionDelayToken?
    private var timeoutToken: SessionDelayToken?
    private var noticeToken: SessionDelayToken?
    private var guideToken: SessionDelayToken?
    private var turnCapToken: SessionDelayToken?
    private var thinkingToken: SessionDelayToken?
    private var relistenToken: SessionDelayToken?
    /// ESS-652: 思考慢提示 / 硬超时 / 静默 / P6 自动挂断计时器。
    private var thinkingSlowToken: SessionDelayToken?
    private var thinkingHardToken: SessionDelayToken?
    /// ESS-1097：工具回合的绝对上限计时器。每轮至多武装一次。
    private var toolTurnHardToken: SessionDelayToken?
    /// ESS-1111：长任务静默预算计时器。与绝对上限相反，它**每收到一帧合法
    /// 活动就整体重置**。
    private var taskActivityToken: SessionDelayToken?
    /// ESS-1111：断线后等待重连的宽限计时器。
    private var downlinkResumeToken: SessionDelayToken?
    private var silenceToken: SessionDelayToken?
    private var failedAutoToken: SessionDelayToken?
    private var hungupDismissToken: SessionDelayToken?
    /// ESS-652: 会话内轮数。
    private var completedRounds = 0
    /// ESS-869：就绪超时降级为整段上传的**缺陷计数**。每发生一次
    /// `session_ready_timeout_salvage` 就 +1；它不是正常兜底，出现即说明实时
    /// 链路没能建立。计数随 `session_ready_timeout_salvage` 事件落进日志，并在
    /// 挂断小结（`session_call_summary`）里汇总，供按会话聚合判缺陷。
    private(set) var readyTimeoutSalvageCount = 0

    /// ESS-600：当前**被认领**的回合 request_id。所有回合事件都必须携带
    /// request_id 并与它相等才被受理——这是「旧 request / 旧 generation 的
    /// 迟到音频不得进入下一轮」在会话层的闸门。上一轮的迟到 `.ended` 到达时
    /// 这里已经换成新 id，事件被丢弃并留证（`session_stale_turn_event`）。
    private(set) var activeTurnRequestId: String?
    /// ESS-1139：上一轮的 request_id。**只用于取证**。
    ///
    /// 确认这一点在真机上曾经发生过，是本单最需要的一条证据：我们在一个
    /// 还在跑的任务上开了新一轮，而 iPhone 侧那条 WSS 正是被这一步 supersede
    /// 掉的。这类迟到帧会被 `acceptsTurnEvent` 按陈旧事件丢掉，那条 info 级
    /// 日志和「上一轮的迟到 `.ended`」混在一起，看不出这件事。留下这个 id，
    /// 就能把它单独打成一条可 grep 的 error。
    private var previousTurnRequestId: String?
    /// ESS-600：会话内回合序号，从 1 开始严格递增。conversation 级的
    /// `conversation_id` / `turn_id` 真相在 `RealtimeMediaSession.ConversationHandle`
    /// （唯一铸造点），本序号只是会话层日志的可读游标，不另铸 id。
    private(set) var turnIndex = 0
    /// ESS-1097：当前回合的**本地聚合状态**。UI 相位与「能否自动开下一轮」都
    /// 由它裁决，而不是任何单一上游信号（这正是本单要修的那条错误映射）。
    /// 每轮换 `activeTurnRequestId` 时重置——聚合体是回合级的，不是会话级的。
    private(set) var toolTurn = ToolTurnAggregate()
    /// 本轮是否已经为工具工作武装过绝对上限。只武装一次（见
    /// `toolTurnHardTimeoutSeconds` 的注释）。
    private var toolTurnDeadlineArmed = false
    /// ESS-1100：当前回合的进展叙述。**回合级**——与 `toolTurn` 同生共死，
    /// 换 `activeTurnRequestId` 时整体重建，上一轮的「正在查询」不得挂到新一轮。
    private(set) var toolProgress = ToolProgressNarration()
    /// 节流后**真正显示**的那句进展。与 `toolProgress.text`（最新被接受的那句）
    /// 刻意分开：前者是 UI 事实，后者是协议事实，混成一个就没法既防闪烁又不丢帧。
    private(set) var visibleProgressText: String?
    /// ESS-1111：当前回合的答案增量装配。**回合级**——与 `toolTurn` /
    /// `toolProgress` 同生共死，换 `activeTurnRequestId` 时整体重建，
    /// 上一轮的半句答案不得挂到新一轮。
    private(set) var answerStream = AnswerStreamAssembly()
    /// 节流窗口内到达、等着窗口一到就补显的那句。
    private var pendingProgressText: String?
    private var progressThrottleToken: SessionDelayToken?
    /// ESS-1111：本回合的答案增量累积器。**回合级**，与 `toolTurn` 同生共死。
    private(set) var answerTranscript = LongTaskAnswerTranscript()
    /// ESS-1111：最近一帧增量的展示类目。决定「没有文字时那一行说什么」——
    /// queued 说「正在排队」、result 说「正在整理结果」、其余退到通用兜底。
    private(set) var latestActivityKind: LongTaskActivityKind?
    /// ESS-1111：本回合已观测到的最高 generation。**旧 generation 的迟到帧
    /// 一律丢弃**——打断之后上一代任务的进展绝不能盖到新一轮头上。
    private(set) var latestTaskGeneration: Int?
    /// ESS-1111：下行是否正处在「断了但任务还在」的宽限期。
    private(set) var isDownlinkInterrupted = false

    /// ESS-1111：本回合是否有仍在上游跑着的长任务。适配器据此决定断线要不要
    /// 当场收口。唯一真相源是回合聚合体，不另存投影。
    var hasLongTaskInFlight: Bool {
        isInSession && toolTurn.terminal == nil && toolTurn.hasOutstandingWork
    }

    /// ESS-843：最近一次会话结束的原因码（默认 user_exit）。keep-alive 层
    /// （WorkoutSessionKeeper）据此在释放 owner 时落明确 reason。
    private(set) var lastExitReasonCode: ExitReasonCode = .userExit

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 进入

    /// 点球进入实时对话。只在 idle 受理；重复点/会话中点球一律忽略
    /// （会话中点球在 Wave 1 无语义，F4 的手动打断降级在后续 Wave 决定）。
    func enterSession() {
        guard state == .idle else { return }
        lastExitReasonCode = .userExit
        state = .connecting
        enteredAt = Date()
        showConnectingDots = false
        failureNotice = nil
        WatchLog.info("session", "session_enter_requested", detail: "source=orb_tap")
        // 800ms 未就绪 → 三点提示；readyTimeout 无 ack → 判失败。
        // 两个计时器都注入可替换，测试手动触发。
        dotsToken = scheduleDelay(Self.connectingDotsDelaySeconds) { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.showConnectingDots = true
        }
        timeoutToken = scheduleDelay(Self.readyTimeoutSeconds) { [weak self] in
            guard let self, self.state == .connecting else { return }
            // ESS-600：超时**不许无反馈丢弃已录语音**。用户已经对着表说了
            // 5 秒，realtime 快通道没通不等于话没法送达——先把已录音频经
            // 可靠通道（完整文件 / transferFile）抢救出去，再报失败退出。
            // ESS-869：这一事件**升格为缺陷信号**——出现即计数并在会话日志里
            // 以 error 级标红，不再当作正常兜底；计数随事件与挂断小结落盘。
            self.readyTimeoutSalvageCount += 1
            WatchLog.error(
                "session", "session_ready_timeout_salvage",
                requestId: self.activeTurnRequestId,
                detail: "timeout_s=\(Int(Self.readyTimeoutSeconds)) capturing=\(self.isCapturingLocally) salvage_count=\(self.readyTimeoutSalvageCount)",
                code: "ERR_SESSION_READY_TIMEOUT"
            )
            if self.isCapturingLocally { self.onSalvageTurn?() }
            self.markChannelFailed(.channelEvent)
        }
        // 注意：不在此处同步宣告 ready。`onBeginChannel` 只是发起——
        // listening 只能由 markChannelReady（首个真实 uplink ack）进入。
        // ESS-600：返回值是**已经在飞**的第 1 轮 request_id（点球进会话时
        // 录音在 touch-down 就开始了），认领它而不是再起一轮。
        turnIndex = 1
        activeTurnRequestId = onBeginChannel?() ?? nil
        turnPhase = .idle
        resetToolTurn(reason: "session_enter")
    }

    /// ESS-600：本地采集真的开始/停止了（AudioRecorder 层事实）。与网络
    /// ready 独立——建立期就能如实显示「表在听」。
    func markLocalCapture(active: Bool) {
        guard isCapturingLocally != active else { return }
        isCapturingLocally = active
    }

    // MARK: - 真实通道事件（唯一的就绪/失败驱动源）

    /// 首个被对端确认的 uplink ack 到达（Watch→iPhone→Bridge 全链路已通）。
    /// 由 PushToTalkController 从 WatchRealtimeMediaAdapter 转发。
    func markChannelReady() {
        guard state == .connecting else { return }
        cancelConnectingTimers()
        state = .listening
        let establishMs = enteredAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        WatchLog.info(
            "session", "session_channel_ready",
            detail: "establish_ms=\(establishMs)"
        )
        // PRD §3.5.5：「通道就绪、可以说话」的 .click 是最重要的一次触觉——
        // 它是「现在可以开口」的唯一信号。
        playHaptic(.ready)
        presentFirstRunGuideIfNeeded()
        // ESS-600：通道就绪 = 第 1 轮正式进入聆听相位。这一轮的采集早在
        // 点球 touch-down 就起来了，此处只是认领，不重新发起。
        // ESS-944：提交可能先于就绪（VAD 自动断句 + WSS 建立延迟），此时
        // turnPhase 已被 markTurnCommitted 推进到 thinking——就绪只补
        // state 转换与触觉，绝不把「正在等回答」的回合改写回 listening。
        if turnPhase != .idle {
            WatchLog.info(
                "session", "session_channel_ready_phase_preserved", requestId: activeTurnRequestId,
                detail: "turn_index=\(turnIndex) phase=\(turnPhase.logName) reason=turn_already_advanced"
            )
            return
        }
        turnPhase = .listening
        didDetectSpeechThisTurn = false
        WatchLog.info(
            "session", "session_next_listening", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) reason=channel_ready"
        )
        armTurnCap()
        // ESS-652: start silence governance on first entry to listening.
        armSilenceTimer()
    }

    /// ESS-865 复审整改：本轮本地 VAD 是否真的听到过人说话。
    /// 每轮聆听开始时清零，`speech_started` 到达时置位。
    private(set) var didDetectSpeechThisTurn = false

    /// 本地 VAD 起判（由 `PushToTalkController` 从 adapter 转发）。
    func markSpeechDetected(requestId: String) {
        guard state == .listening, turnPhase == .listening else { return }
        guard let active = activeTurnRequestId, active == requestId else {
            WatchLog.info(
                "session", "session_stale_turn_event", requestId: requestId,
                detail: "event=speech_detected active_request_id=\(activeTurnRequestId ?? "nil") turn_index=\(turnIndex)"
            )
            return
        }
        guard !didDetectSpeechThisTurn else { return }
        didDetectSpeechThisTurn = true
        WatchLog.info(
            "session", "session_speech_detected", requestId: requestId,
            detail: "turn_index=\(turnIndex)"
        )
    }

    /// 单轮上限兜底：**说过话的**回合到点视同说完提交本轮，不让「聆听」悬在
    /// 已停录的死麦克风上（VAD 断句是常态路径，本条只是上限）。
    ///
    /// ESS-865 复审阻断 2：从未听到人说话的回合到点**不提交**。提交等于把一段
    /// 静音送上去，回合随即离开 listening，`armSilenceTimer` 的 75s 提示与 120s
    /// 挂断都以 `turnPhase == .listening` 为前提，从此永远到不了——用户放下手
    /// 走开，会话会一直挂着而不是按策略自己收。静音的归属是静默治理。
    private func armTurnCap() {
        turnCapToken?.cancel()
        turnCapToken = scheduleDelay(Self.turnCapSeconds) { [weak self] in
            guard let self, self.state == .listening, self.turnPhase == .listening else { return }
            guard self.didDetectSpeechThisTurn else {
                // ESS-960：不提交（ESS-865 阻断 2 的口径不变），但**必须重开采集**。
                // 录音器 10s 后就到 `AudioRecorder.maxDuration` 自己停录，而
                // 会话要到 120s 静默挂断才收场——中间这一整段麦克风是死的，
                // 用户说什么都没人接（2026-08-21 真机：59.9s / rms=5 的静音
                // 录音走完全文件回退后 `audio_too_short` 失败，用户端全程无感）。
                // 这正是本方法注释里要避免的「聆听悬在已停录的死麦克风上」，
                // 当时只为说过话的回合兑现了。
                //
                // 换麦克风但**不动相位、不重置静默时钟**——细节见
                // `restartCaptureAfterSilentTurnCap`。
                self.restartCaptureAfterSilentTurnCap()
                return
            }
            WatchLog.info("session", "session_turn_cap_reached",
                          requestId: self.activeTurnRequestId,
                          detail: "cap_s=\(Int(Self.turnCapSeconds))")
            self.onCommitTurn?()
        }
    }

    // MARK: - ESS-600 回合状态机（listening → thinking → speaking → listening）

    /// 事件闸门：会话必须存续，且事件必须属于**当前被认领的那一轮**。
    /// 不匹配一律丢弃并留证——这是迟到音频/迟到播放事件不得污染下一轮的
    /// 会话层防线（realtime 侧还有 currentTurn/generation 两道，各司其职）。
    private func acceptsTurnEvent(_ requestId: String, event: String) -> Bool {
        guard state == .listening else {
            WatchLog.info(
                "session", "session_turn_event_dropped", requestId: requestId,
                detail: "event=\(event) state=\(state.logName) phase=\(turnPhase.logName) reason=not_listening turn_index=\(turnIndex)"
            )
            return false
        }
        guard let active = activeTurnRequestId, active == requestId else {
            WatchLog.info(
                "session", "session_stale_turn_event", requestId: requestId,
                detail: "event=\(event) active_request_id=\(activeTurnRequestId ?? "nil") turn_index=\(turnIndex)"
            )
            return false
        }
        return true
    }

    /// 本轮上行**真正提交**（`submit` 走完，realtime commit 或完整文件二选一）。
    /// listening → thinking。
    ///
    /// ESS-944：先校验 request_id 归属（陈旧回合照旧丢弃留证），再分状态。
    /// 提交可能先于就绪（VAD 自动断句 + WSS 建立延迟）：connecting 期间
    /// turnPhase 还是 .idle，但「已提交」是事实，直接推进到 thinking；
    /// markChannelReady 据此不覆盖已推进的相位。
    func markTurnCommitted(requestId: String) {
        guard let active = activeTurnRequestId, active == requestId else {
            WatchLog.info(
                "session", "session_stale_turn_event", requestId: requestId,
                detail: "event=turn_committed active_request_id=\(activeTurnRequestId ?? "nil") turn_index=\(turnIndex)"
            )
            return
        }
        let phaseReady: Bool
        switch state {
        case .listening: phaseReady = turnPhase == .listening
        case .connecting: phaseReady = turnPhase == .idle
        default: phaseReady = false
        }
        guard phaseReady else {
            WatchLog.info(
                "session", "session_turn_event_dropped", requestId: requestId,
                detail: "event=turn_committed state=\(state.logName) phase=\(turnPhase.logName) reason=phase_not_ready turn_index=\(turnIndex)"
            )
            return
        }
        turnCapToken?.cancel(); turnCapToken = nil
        turnPhase = .thinking
        WatchLog.info(
            "session", "session_turn_committed", requestId: requestId,
            detail: "turn_index=\(turnIndex) phase=thinking"
        )
        armThinkingTimeout()
    }

    /// ESS-652: 提交后启动思考超时计时器。25s 软提示 + 45s 硬超时进入 P6。
    ///
    /// ESS-673：PR #270 的冲突解决把本方法留了两份（`thinkingToken` 版与
    /// `thinkingSlowToken` 版），Swift 直接判 invalid redeclaration，main 打不出包。
    /// 这里按 ESS-671 的口径取并集留一份：**计时器用 ESS-652 的
    /// `thinkingSlowToken`/`thinkingHardToken`**（拆链与失败路径只认这一对，
    /// 见 cancelTurnTimers），**日志字段用带 `turn_index` 的这版**——
    /// `session_thinking_slow` 的 `turn_index` 是 ESS-655 契约的必带字段，
    /// 另一版没带，落进日志就过不了 `PhoneModeTelemetry.validate`。
    private func armThinkingTimeout() {
        thinkingSlowToken?.cancel()
        thinkingSlowHint = false
        thinkingSlowToken = scheduleDelay(Self.thinkingSlowHintSeconds) { [weak self] in
            guard let self, self.state == .listening, self.turnPhase == .thinking else { return }
            self.thinkingSlowHint = true
            WatchLog.info("session", "session_thinking_slow", requestId: self.activeTurnRequestId,
                          detail: "turn_index=\(self.turnIndex)")
        }
        thinkingHardToken?.cancel()
        thinkingHardToken = nil
        // ESS-1097：工具在跑的时候 45s 硬超时必须让位——它量的是「上游没答」，
        // 而工具回合恰恰是**答案还在做**。此时改由 `toolTurnHardToken` 的绝对
        // 上限承担有界性（一轮只武装一次），两者永远只有一个在跑。
        guard !toolTurn.hasOutstandingWork else {
            WatchLog.info(
                "session", "session_thinking_hard_timeout_deferred",
                requestId: activeTurnRequestId,
                detail: "turn_index=\(turnIndex) \(toolTurn.logDetail)"
            )
            return
        }
        thinkingHardToken = scheduleDelay(Self.thinkingHardTimeoutSeconds) { [weak self] in
            guard let self, self.isInSession, self.turnPhase == .thinking else { return }
            WatchLog.info("session", "session_thinking_hard_timeout", requestId: self.activeTurnRequestId)
            self.toolTurn.apply(.timedOut(reason: "thinking_hard_timeout"))
            self.refreshToolProcessingText()
            self.enterFailed(reason: "回答超时，要再试一次吗？", retryable: true)
        }
    }

    // MARK: - ESS-1097 工具回合门禁

    /// 上游任务生命周期到达（`task.state`）。
    ///
    /// `taskId == nil` 表示 `tool_call_pending` 那一类「工具要开跑但还没有任务号」
    /// 的信号；`status` 原样来自上游，解释权在 `ToolTaskStatus`——**未知状态一律
    /// 按非终态处理**，把没见过的状态当终态正是本单要修的 bug。
    func markTaskState(
        requestId: String, taskId: String?, status: String,
        progress: AgentTaskProgress? = nil,
        answer: AgentTaskAnswerDelta? = nil,
        generation: Int? = nil
    ) {
        // ESS-1139：**先取证，后闸门**。这一帧若属于刚刚被换掉的那一轮且带着
        // 未终结的任务，说明「阶段播报的终态没被正确分类」这条边漏了——
        // 上游任务还在跑，而我们已经开了新一轮。这是真机复盘唯一能把
        // 「客户端为什么关了 WSS」一句话钉死的证据。
        if requestId != activeTurnRequestId, requestId == previousTurnRequestId,
           taskId != nil, !ToolTaskStatus(rawValue: status).isTerminal {
            WatchLog.error(
                "session", "session_task_state_after_relisten", requestId: requestId,
                detail: "turn_index=\(turnIndex) task_id=\(taskId ?? "nil") status=\(status) "
                    + "active_request_id=\(activeTurnRequestId ?? "nil")",
                code: "ERR_SESSION_TASK_STATE_AFTER_RELISTEN"
            )
        }
        guard acceptsTurnEvent(requestId, event: "task_state") else { return }
        // ESS-1111：代际闸门。打断（barge-in）之后上一代仍在跑的任务会继续
        // 下发进展；requestId 相同的情况下 `acceptsTurnEvent` 拦不住它们，
        // 只有 generation 能。缺席（老网关 / 老 iPhone 进程）时不猜、不丢——
        // 按「本帧没有代际信息」处理，退回 ESS-1097 之前逐字相同的行为。
        guard acceptsTaskGeneration(generation, requestId: requestId) else { return }
        // ESS-1111：断线宽限期内收到任何合法帧 = 这一跳已经恢复。
        // 「重连后可继续接收」在客户端就是这一行：不需要新协议帧，收到就算。
        if isDownlinkInterrupted {
            markDownlinkResumed(requestId: requestId, reason: "task_state")
        }
        let kind = LongTaskActivityKind(category: progress?.category, status: status)
        latestActivityKind = kind
        let event: ToolTurnAggregate.Event
        if let taskId {
            event = .taskState(taskId: taskId, status: ToolTaskStatus(rawValue: status))
        } else {
            // 无任务号 = 工具调用闩锁。只有明确的「已解除」才落 resolved，
            // 其余（含未知取值）都按「还在挂起」处理。
            switch status.lowercased() {
            case "resolved", "tool_call_resolved", "completed", "done":
                event = .toolCallResolved
            default:
                event = .toolCallPending
            }
        }
        let hadOutstandingWork = toolTurn.hasOutstandingWork
        let phaseChanged = toolTurn.apply(event)
        // ESS-1100 / ESS-1111：同一帧的展示面。**先记闸门、后记展示**是有意的
        // 顺序——展示不参与任何裁决，它读的是闸门已经落定的事实。
        // 三条流各走各的闸门：进展行（覆盖）、兼容答案（追加，按 progress_seq）、
        // 权威答案流（追加，按 answer_seq）。
        let displayOutcome = applyActivityDisplay(progress, kind: kind, requestId: requestId)
        let answerOutcome = applyAnswerDelta(answer, requestId: requestId)
        refreshStreamingAnswerText()
        WatchLog.info(
            "session", "session_task_state", requestId: requestId,
            detail: "turn_index=\(turnIndex) task_id=\(taskId ?? "nil") status=\(status) "
                + "generation=\(generation?.description ?? "nil") kind=\(kind.logName) "
                + "phase_changed=\(phaseChanged) progress=\(displayOutcome) "
                + "answer=\(answerOutcome?.logName ?? "absent") "
                + "\(toolTurn.logDetail) \(toolProgress.logDetail) "
                + "\(answerTranscript.logDetail) \(answerStream.logDetail)"
        )
        refreshToolProcessingText()
        if !hadOutstandingWork, toolTurn.hasOutstandingWork {
            // 首次观测到工具工作：撤掉 45s 硬超时，改挂一次性的绝对上限。
            armToolTurnDeadlineIfNeeded()
            thinkingHardToken?.cancel(); thinkingHardToken = nil
        } else if resumeListeningIfToolTurnClosed(reason: "task_state:\(status)") {
            // 已经收口并开了下一轮，不必再武装「等回答」的预算。
        } else if hadOutstandingWork, !toolTurn.hasOutstandingWork, turnPhase == .thinking {
            // 工具活干完了、答案还没播：把 45s 的「等回答」预算重新接上。
            // 绝对上限仍然挂着，两条都有界。
            armThinkingTimeout()
        }
        // ESS-1111：**任何**合法帧都刷新静默预算——这条必须在闸门分支之外、
        // 无条件执行。放进分支里就等于「只有状态变化才算活动」，而真机上
        // 24s 长任务的绝大多数帧是同一个 running 的重复下发。
        renewTaskActivityDeadline(reason: "task_state")
        // ESS-1111：上游明确判失败/取消/超时 ⇒ 再也不会有答案。此时静默收口
        // 回「正在听」，用户得到的是一次无法解释的沉默（比报错更糟，
        // ESS-600 的同一条教训）。给明确终态。
        surfaceTaskFailureTerminalIfNeeded(
            taskId: taskId, status: status, requestId: requestId
        )
    }

    /// 聚合体收口后，把**用户看到的那一面**也真正带回聆听。
    ///
    /// 复审阻断（毕玄 2026-08-23）：`markAnswerFinished` 被闸门拦下时相位停在
    /// `.thinking`，此后清掉最后一个 hold reason 的是 `task.state`（任务终态或
    /// `tool_call_resolved`）。没有这条路径时那里只重新武装 45s 预算——聚合体
    /// 已经 `isClosed`，而 UI 继续显示「正在思考」、麦克风一直关着，直到超时
    /// 判失败。答案明明已经播完了，用户看到的却是转圈然后报错。
    ///
    /// 三重闸门，缺一不可：
    /// - `state == .listening` + `turnPhase == .thinking`：只有「被拦在等待态」
    ///   才有恢复可言。speaking 说明还在播（此时聚合体也不会收口）；
    /// - `hasToolEvidence`：无工具证据的回合走原路径，本方法一步都不插手——
    ///   尤其是 ESS-971 的普通多段 interim，那条边**必须**停在 thinking；
    /// - `isClosed`：全部 hold reason 都清了才动（含 ESS-1111 的
    ///   `awaitingReconnect`——断线期间绝不收口）。
    ///
    /// **不补计轮次**：成功播完那一次已由 `markAnswerFinished` 记过
    /// （`markRoundCompleted`），这里再记一次会让通话摘要凭空多出几轮。
    ///
    /// - Returns: 是否真的收口并开了下一轮。
    @discardableResult
    private func resumeListeningIfToolTurnClosed(reason: String) -> Bool {
        guard state == .listening, turnPhase == .thinking else { return false }
        guard toolTurn.hasToolEvidence, toolTurn.isClosed else { return false }
        WatchLog.info(
            "session", "session_tool_turn_settled", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) reason=\(reason) \(toolTurn.logDetail)"
        )
        startNextTurn(reason: "tool_turn_settled:\(reason)")
        return true
    }

    /// ESS-1111：代际闸门。返回 false = 本帧属于更老的一代，丢弃并留证。
    private func acceptsTaskGeneration(_ generation: Int?, requestId: String) -> Bool {
        guard let generation else { return true }
        if let latest = latestTaskGeneration, generation < latest {
            WatchLog.info(
                "session", "session_task_state_stale_generation", requestId: requestId,
                detail: "turn_index=\(turnIndex) incoming_generation=\(generation) "
                    + "active_generation=\(latest)"
            )
            return false
        }
        latestTaskGeneration = generation
        return true
    }

    /// ESS-1111：上游任务的失败类终态 ⇒ 明确终态收口。
    ///
    /// 三条前置都必要：
    /// - 只在**没有任何未结任务**时收口，否则并发的第二个任务还在跑；
    /// - 只在**本回合没播出过任何音频**时收口——答案已经说出口之后再报
    ///   「没能完成」是撒谎，那种情况按正常回合屏障收口；
    /// - 只在回合还没有终态时收口（终态吸收，不重复判死）。
    private func surfaceTaskFailureTerminalIfNeeded(
        taskId: String?, status: String, requestId: String
    ) {
        guard taskId != nil else { return }
        let parsed = ToolTaskStatus(rawValue: status)
        guard parsed.isFailureTerminal,
              let notice = parsed.failureNoticeText,
              toolTurn.terminal == nil,
              !toolTurn.hasOutstandingWork,
              !toolTurn.didPlayAnyAudio else { return }
        WatchLog.error(
            "session", "session_task_failed_terminal", requestId: requestId,
            detail: "turn_index=\(turnIndex) task_id=\(taskId ?? "nil") status=\(status) "
                + toolTurn.logDetail,
            code: "ERR_SESSION_TASK_TERMINAL_\(parsed.rawValue.uppercased())"
        )
        toolTurn.apply(.turnFailed(code: "task_\(parsed.rawValue)"))
        refreshToolProcessingText()
        enterFailed(reason: notice, retryable: parsed != .cancelled)
    }

    // MARK: - ESS-1111 答案文本增量

    /// 把一帧答案增量喂给回合级装配。返回处置结果（`nil` = 本帧没带答案）。
    ///
    /// 与进展文字**不共用节流**：进展是同一行字被反复覆盖，抖动才需要压；
    /// 答案是逐段追加，压掉一帧就是少一段话。装配本身是纯字符串拼接，
    /// 没有 I/O，也不触碰播放管线。
    @discardableResult
    private func applyAnswerDelta(
        _ answer: AgentTaskAnswerDelta?, requestId: String
    ) -> AnswerStreamAssembly.Outcome? {
        guard let answer else { return nil }
        let outcome = answerStream.apply(sequence: answer.sequence, delta: answer.delta)
        if outcome.changesDisplay {
            // 只更新装配体；屏幕上那一处由 `refreshStreamingAnswerText` 统一推导。
            refreshStreamingAnswerText()
        } else if outcome == .duplicate || outcome == .outOfOrder {
            // 迟到与重复必须可判定：真机上「答案为什么少了一段 / 串了一段」
            // 只能靠这条。答案原文不入日志（用户内容），只记序号与计数。
            WatchLog.info(
                "session", "session_answer_delta_dropped", requestId: requestId,
                detail: "turn_index=\(turnIndex) reason=\(outcome.logName) "
                    + "incoming_seq=\(answer.sequence?.description ?? "nil") "
                    + "\(answerStream.logDetail)"
            )
        }
        return outcome
    }

    /// ESS-1111（#412 / #413 合并收口）：屏幕上那一处答案文本的**唯一推导点**。
    ///
    /// 优先级见 `streamingAnswerText` 的注释：权威答案流（`answer_seq`）一旦
    /// 出过内容，本回合此后只认它；否则退到兼容入口（`progress_category ==
    /// "answer"`）。两条来源各自保留独立的序号闸门，这里只做选择、不做装配。
    private func refreshStreamingAnswerText() {
        let next = answerStream.hasAnswer
            ? answerStream.text
            : answerTranscript.displayText
        guard next != streamingAnswerText else { return }
        streamingAnswerText = next
    }

    // MARK: - ESS-1100 进展文字

    /// ESS-1111：一帧增量的展示分流。答案正文走累积器（追加 + 尾窗滚动），
    /// 其余类目走进展行（覆盖 + 节流）。返回处置结果的日志名。
    ///
    /// 两条流各有**独立的序号闸门**：网关的 `progress_seq` 在会话内单调，
    /// 因此按类目切出来的两条子序列各自也单调；合用一个闸门则会让交替到达的
    /// 答案与进展互相判成「乱序」而彼此丢弃。
    private func applyActivityDisplay(
        _ progress: AgentTaskProgress?, kind: LongTaskActivityKind, requestId: String
    ) -> String {
        guard let progress else { return "absent" }
        guard kind.isAnswerStream else {
            return applyProgressNarration(progress, requestId: requestId)?.logName ?? "absent"
        }
        let outcome = answerTranscript.apply(sequence: progress.sequence, delta: progress.text)
        if outcome.changesDisplay {
            // 只搬运一个已经有界的字符串（`displayText` 恒 ≤ 尾窗 + 1）。
            // 没有解码、没有 I/O、没有锁——本单「不阻塞音频线程」的要求在
            // 这里是结构性的，而不是靠调度承诺。
            refreshStreamingAnswerText()
        } else if outcome == .duplicate || outcome == .outOfOrder {
            WatchLog.info(
                "session", "session_answer_delta_dropped", requestId: requestId,
                detail: "turn_index=\(turnIndex) reason=\(outcome.logName) "
                    + "incoming_seq=\(progress.sequence?.description ?? "nil") "
                    + answerTranscript.logDetail
            )
        }
        return outcome.logName
    }

    /// 把一帧进展喂给回合级叙述。返回处置结果（`nil` = 本帧没带进展）。
    ///
    /// 回合归属已经由 `acceptsTurnEvent` 挡过一层（跨回合的迟到帧根本走不到
    /// 这里）；本方法只负责回合**内**的排序与去重，不重复第二套归属真相。
    @discardableResult
    private func applyProgressNarration(
        _ progress: AgentTaskProgress?, requestId: String
    ) -> ToolProgressNarration.Outcome? {
        guard let progress else { return nil }
        let outcome = toolProgress.apply(
            sequence: progress.sequence, text: progress.text, category: progress.category
        )
        if outcome.changesDisplay, let text = toolProgress.text {
            scheduleProgressDisplay(text, requestId: requestId)
        } else if outcome == .duplicate || outcome == .outOfOrder {
            // 迟到与重复必须可判定：真机上「为什么那句进展没出现」只能靠这条。
            WatchLog.info(
                "session", "session_progress_dropped", requestId: requestId,
                detail: "turn_index=\(turnIndex) reason=\(outcome.logName) "
                    + "incoming_seq=\(progress.sequence?.description ?? "nil") "
                    + "\(toolProgress.logDetail)"
            )
        }
        return outcome
    }

    /// 节流发布：窗口空闲就立刻显示并开窗；窗口内则存为 pending，窗口一到补显。
    private func scheduleProgressDisplay(_ text: String, requestId: String) {
        guard progressThrottleToken == nil else {
            pendingProgressText = text
            WatchLog.info(
                "session", "session_progress_coalesced", requestId: requestId,
                detail: "turn_index=\(turnIndex) \(toolProgress.logDetail)"
            )
            return
        }
        publishProgressDisplay(text, requestId: requestId)
    }

    private func publishProgressDisplay(_ text: String, requestId: String) {
        visibleProgressText = text
        pendingProgressText = nil
        refreshToolProcessingText()
        WatchLog.info(
            "session", "session_progress_shown", requestId: requestId,
            detail: "turn_index=\(turnIndex) \(toolProgress.logDetail)"
        )
        progressThrottleToken = scheduleDelay(Self.progressUpdateMinIntervalSeconds) { [weak self] in
            guard let self else { return }
            self.progressThrottleToken = nil
            guard let pending = self.pendingProgressText else { return }
            self.pendingProgressText = nil
            guard pending != self.visibleProgressText else { return }
            self.publishProgressDisplay(pending, requestId: self.activeTurnRequestId ?? requestId)
        }
    }

    /// 从「相位 + 是否工具回合 + 已显示的进展」推导那一行文案。
    ///
    /// 唯一的推导点。普通回合（无任何工具证据）恒为 `nil`——视图据此原样沿用
    /// 「正在思考…」，不产生任何多余跳转。
    private func refreshToolProcessingText() {
        let shouldShow = turnPhase == .thinking
            && toolTurn.hasToolEvidence
            && toolTurn.terminal == nil
        guard shouldShow else {
            if toolProcessingText != nil { toolProcessingText = nil }
            return
        }
        // ESS-1111：断线宽限期压过一切进展文字。此刻屏幕上停着一句「正在查询
        // 相关信息」会让用户以为一切正常，而事实是这一跳断了、正在等重连。
        if isDownlinkInterrupted {
            if toolProcessingText != Self.reconnectingCopy { toolProcessingText = Self.reconnectingCopy }
            return
        }
        // ESS-1111：没有真实进展文字时，兜底那句由**类目**决定：排队说「正在
        // 排队」、收尾说「正在整理结果」，其余（含 reasoning / tool）一律退到
        // 通用的「正在处理」——手表不知道模型在想什么、也不知道调的哪个工具，
        // 替它编一句就是伪造。
        let fallback = latestActivityKind?.statusFallbackText ?? ToolProgressNarration.fallbackText
        let next = visibleProgressText ?? fallback
        guard next != toolProcessingText else { return }
        toolProcessingText = next
    }

    /// ESS-1111：断线宽限期的那一行。与失败文案刻意不同——它不是终态，
    /// 任务还在上游跑着。
    static let reconnectingCopy = "连接断开了，正在重连…"

    /// 一轮之内只武装一次的工具绝对上限。到点走与 45s 硬超时完全同构的收口。
    private func armToolTurnDeadlineIfNeeded() {
        guard !toolTurnDeadlineArmed else { return }
        toolTurnDeadlineArmed = true
        WatchLog.info(
            "session", "session_tool_turn_deadline_armed", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) timeout_s=\(Int(Self.toolTurnHardTimeoutSeconds))"
        )
        toolTurnHardToken?.cancel()
        toolTurnHardToken = scheduleDelay(Self.toolTurnHardTimeoutSeconds) { [weak self] in
            guard let self, self.isInSession else { return }
            guard self.turnPhase == .thinking || self.turnPhase == .speaking else { return }
            WatchLog.error(
                "session", "session_tool_turn_timeout", requestId: self.activeTurnRequestId,
                detail: "turn_index=\(self.turnIndex) timeout_s=\(Int(Self.toolTurnHardTimeoutSeconds)) "
                    + self.toolTurn.logDetail,
                code: "ERR_SESSION_TOOL_TURN_TIMEOUT"
            )
            self.toolTurn.apply(.timedOut(reason: "tool_turn_timeout"))
            self.refreshToolProcessingText()
            self.enterFailed(reason: "这件事做得有点久，要再试一次吗？", retryable: true)
        }
    }

    // MARK: - ESS-1111 活动续期与断线重连

    /// 收到一帧合法活动 ⇒ 整体重置静默预算。
    ///
    /// 「合法」的口径就是 `acceptsTurnEvent` + 代际闸门放行过的那些帧，一个
    /// 不多一个不少。**刻意不看有没有音频**：长任务的绝大多数时间里上游一个
    /// 字节音频都不会发，拿「无音频」当退出判据正是本单要消灭的那条规则。
    private func renewTaskActivityDeadline(reason: String) {
        guard isInSession, turnPhase == .thinking else { return }
        // 没有任何在跑的工作时不武装：普通回合的有界性归 45s
        // `thinkingHardTimeoutSeconds`，两条预算永远只有一条在跑。
        guard toolTurn.hasOutstandingWork || toolTurn.awaitingReconnect else {
            taskActivityToken?.cancel(); taskActivityToken = nil
            return
        }
        taskActivityToken?.cancel()
        taskActivityToken = scheduleDelay(Self.taskActivityTimeoutSeconds) { [weak self] in
            guard let self, self.isInSession, self.turnPhase == .thinking else { return }
            guard self.toolTurn.terminal == nil else { return }
            WatchLog.error(
                "session", "session_task_activity_timeout", requestId: self.activeTurnRequestId,
                detail: "turn_index=\(self.turnIndex) "
                    + "silence_s=\(Int(Self.taskActivityTimeoutSeconds)) " + self.toolTurn.logDetail,
                code: "ERR_SESSION_TASK_ACTIVITY_TIMEOUT"
            )
            self.toolTurn.apply(.timedOut(reason: "task_activity_timeout"))
            self.refreshToolProcessingText()
            self.enterFailed(reason: "那件事没有新消息了，要再试一次吗？", retryable: true)
        }
        WatchLog.info(
            "session", "session_task_activity_renewed", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) reason=\(reason) "
                + "budget_s=\(Int(Self.taskActivityTimeoutSeconds)) " + toolTurn.logDetail
        )
    }

    /// 下行断了，但任务仍在上游跑着。
    ///
    /// 这是本单与既有 `markChannelFailed` 的分界：那条说的是「通道死了、不会
    /// 再有上游事实」，本条说的是「这一跳断了、任务还在」。真机取证里两者被
    /// 混为一谈，代价是一个已经跑到 12s 的任务连同它 11.9s 后产出的答案一起
    /// 被丢掉。断线期间：task identity 原样保留、回合不收口、不开下一轮，
    /// 屏幕如实显示正在重连；宽限到点仍未恢复才按明确终态收场。
    func markDownlinkInterrupted(requestId: String, reason: String) {
        guard acceptsTurnEvent(requestId, event: "downlink_interrupted") else { return }
        guard !isDownlinkInterrupted else { return }
        isDownlinkInterrupted = true
        toolTurn.apply(.downlinkInterrupted(reason: reason))
        // 断线期间不再有帧可收，静默预算失去意义，改由宽限计时器承担有界性。
        taskActivityToken?.cancel(); taskActivityToken = nil
        refreshToolProcessingText()
        WatchLog.info(
            "session", "session_downlink_interrupted", requestId: requestId,
            detail: "turn_index=\(turnIndex) reason=\(reason) "
                + "grace_s=\(Int(Self.downlinkReconnectGraceSeconds)) " + toolTurn.logDetail
        )
        downlinkResumeToken?.cancel()
        downlinkResumeToken = scheduleDelay(Self.downlinkReconnectGraceSeconds) { [weak self] in
            guard let self, self.isInSession, self.isDownlinkInterrupted else { return }
            WatchLog.error(
                "session", "session_downlink_resume_timeout", requestId: self.activeTurnRequestId,
                detail: "turn_index=\(self.turnIndex) reason=\(reason) "
                    + "grace_s=\(Int(Self.downlinkReconnectGraceSeconds)) " + self.toolTurn.logDetail,
                code: "ERR_SESSION_DOWNLINK_RESUME_TIMEOUT"
            )
            self.isDownlinkInterrupted = false
            self.toolTurn.apply(.downlinkClosed(reason: "resume_timeout:\(reason)"))
            self.refreshToolProcessingText()
            // ESS-1111 复审整改（阻断 1）——**顺序是这条路径的正确性本身**。
            //
            // 之前的顺序是「先通知适配器、后 enterFailed」，那条链是：
            //   onDownlinkGraceExpired → finishDeferredTransportFailure
            //   → onAnswerPlaybackFailed → markAnswerFinished(success: false)
            // 而上一行的 `.downlinkClosed` 已经让聚合体 `isClosed == true`，
            // 于是 `blocksAutomaticNextTurn == false`，`markAnswerFinished`
            // 一路落到 `startNextTurn` —— 在一条**失败**路径上真实开了一轮新
            // 录音（新 requestId / 新 generation / `recorder.start()`），随后
            // 才被 `enterFailed` 打到 `.failed`：失败页面上麦克风还在采集，
            // 且 `resetToolTurn("next_turn")` 把断线现场的取证一起清掉了。
            //
            // 先落会话终态即可结构性地关掉这条边：`state == .failed` 之后
            // `acceptsTurnEvent` 会挡掉迟到的 `answer_finished`，
            // `finishTransportFailure` 只剩 `markDownlinkBridgeFallback()`
            // 这条应有的清理。
            self.enterFailed(reason: "连接没能恢复，要再试一次吗？", retryable: true)
            self.onDownlinkGraceExpired?(reason)
            // 下行已判死，通道要真的拆掉——与 `markChannelFailed` 同一口径。
            // `enterFailed` 只收束回合状态，不拆通道；少了这一行，失败页上
            // 采集与传输都还挂着。
            self.onTeardownChannel?()
        }
    }

    /// 下行恢复。**不需要新协议帧**：宽限期内收到任何一帧合法增量即视为恢复
    /// （见 `markTaskState`），这也是「重连后可继续接收」在客户端的全部含义。
    func markDownlinkResumed(requestId: String, reason: String) {
        guard isDownlinkInterrupted else { return }
        guard let active = activeTurnRequestId, active == requestId else {
            WatchLog.info(
                "session", "session_stale_turn_event", requestId: requestId,
                detail: "event=downlink_resumed active_request_id=\(activeTurnRequestId ?? "nil") "
                    + "turn_index=\(turnIndex)"
            )
            return
        }
        isDownlinkInterrupted = false
        downlinkResumeToken?.cancel(); downlinkResumeToken = nil
        toolTurn.apply(.downlinkResumed)
        refreshToolProcessingText()
        WatchLog.info(
            "session", "session_downlink_resumed", requestId: requestId,
            detail: "turn_index=\(turnIndex) reason=\(reason) " + toolTurn.logDetail
        )
        // 单一判据：会话认定恢复 ⇒ 适配器撤销推迟中的收口。
        onDownlinkResumed?(reason)
        renewTaskActivityDeadline(reason: "downlink_resumed")
    }

    /// 每轮开始时重置聚合体。聚合体是**回合级**的：跨轮复用会把上一轮的
    /// 未结任务按在新一轮头上（另一种形式的卡死）。
    private func resetToolTurn(reason: String) {
        toolTurn = ToolTurnAggregate()
        toolTurnDeadlineArmed = false
        toolTurnHardToken?.cancel(); toolTurnHardToken = nil
        // ESS-1100：进展叙述与闸门同生共死。留着上一轮的「正在查询相关信息」
        // 挂到新一轮头上，就是本单点名禁止的「旧任务污染新会话」。
        toolProgress = ToolProgressNarration()
        visibleProgressText = nil
        pendingProgressText = nil
        // ESS-1111：答案装配同生共死。上一轮的半句答案留在屏幕上，
        // 比不显示更糟——用户会把它当成这一轮的回答。
        answerStream.clear()
        progressThrottleToken?.cancel(); progressThrottleToken = nil
        // ESS-1111：答案流、类目、代际游标与断线宽限同样是**回合级**的。
        // 任何一样留到下一轮，就是本单点名禁止的「旧 generation 污染新回合」。
        answerTranscript = LongTaskAnswerTranscript()
        streamingAnswerText = nil
        latestActivityKind = nil
        latestTaskGeneration = nil
        isDownlinkInterrupted = false
        taskActivityToken?.cancel(); taskActivityToken = nil
        downlinkResumeToken?.cancel(); downlinkResumeToken = nil
        refreshToolProcessingText()
        WatchLog.info(
            "session", "session_tool_turn_reset", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) reason=\(reason)"
        )
    }

    /// ESS-600 复审阻断 B：完整文件路径的 **interim** 语音播完。
    ///
    /// interim 与最终回答**共用同一个 request_id**（`VoiceTurnJournal` 的回合
    /// 尚未达终态），所以它播完绝不等于「这一轮答完了」——若在此开下一轮，
    /// 最终回答到达时会落进下一轮，正是复审指出的跨轮与顺序错乱。
    /// 相位退回 `.thinking` 并重新武装有界超时：最终回答到了就正常走
    /// `answer_started → answer_finished`；永不到达则由超时把会话捞回聆听。
    func markAnswerInterim(requestId: String) {
        guard acceptsTurnEvent(requestId, event: "answer_interim") else { return }
        guard turnPhase == .speaking || turnPhase == .thinking else {
            WatchLog.info(
                "session", "session_turn_event_dropped", requestId: requestId,
                detail: "event=answer_interim state=\(state.logName) phase=\(turnPhase.logName) reason=phase_not_speaking_or_thinking turn_index=\(turnIndex)"
            )
            return
        }
        let fromPhase = turnPhase
        turnPhase = .thinking
        lowVolumeHint = false
        // ESS-1097：段落播完 ≠ 回合屏障落定。只清播放面，屏障状态一个字不动。
        toolTurn.apply(.playbackSegmentEnded)
        // ESS-650：interim 播完退回等待态，已不在 speaking，停采。
        stopBargeInListening(reason: "answer_interim")
        WatchLog.info(
            "session", "session_answer_interim", requestId: requestId,
            detail: "turn_index=\(turnIndex) from=\(fromPhase.logName) phase=thinking \(toolTurn.logDetail)"
        )
        // 段落播完清掉的是播放面。若它恰好是**最后一个** hold reason（工具早已
        // 终结、回合屏障也早已落定），本轮就此收口，同样要真的回到聆听——
        // 与 `markTaskState` 共用同一条收口路径，不另立第二套判定。
        guard !resumeListeningIfToolTurnClosed(reason: "answer_interim") else { return }
        armThinkingTimeout()
        // ESS-1111：段落播完退回等待态 ⇒ 静默预算重新接管。
        renewTaskActivityDeadline(reason: "answer_interim")
    }

    /// 回答音频**真实起播**（realtime 首帧已渲染 / SpeechPlayer 起播成功）。
    /// thinking → speaking。收到 delta、入队、落盘都不算起播。
    func markAnswerStarted(requestId: String) {
        guard acceptsTurnEvent(requestId, event: "answer_started") else { return }
        guard turnPhase == .thinking else {
            WatchLog.info(
                "session", "session_turn_event_dropped", requestId: requestId,
                detail: "event=answer_started state=\(state.logName) phase=\(turnPhase.logName) reason=phase_not_thinking turn_index=\(turnIndex)"
            )
            return
        }
        thinkingToken?.cancel(); thinkingToken = nil
        turnPhase = .speaking
        // ESS-1097：首帧真实起播 = 「正在回答」。它**不**让回合收口——
        // 工具结果的第一段可能只是「我正在查询…」。
        toolTurn.apply(.playbackStarted)
        // ESS-1111：音频真实在放 = 有界性由播放面承担，静默预算让位。
        // 播放中断/段落结束退回 thinking 时会重新武装（见 markAnswerInterim）。
        taskActivityToken?.cancel(); taskActivityToken = nil
        WatchLog.info(
            "session", "session_answer_started", requestId: requestId,
            detail: "turn_index=\(turnIndex) phase=speaking \(toolTurn.logDetail)"
        )
        // ESS-891：回答真实起播时读一次系统输出音量。应用无法编程式调高
        // 系统音量，过低时给一行可行动提示（用户旋转表冠调高）。
        let volume = readOutputVolume()
        lowVolumeHint = Self.shouldSurfaceLowVolumeHint(outputVolume: volume)
        if lowVolumeHint {
            WatchLog.info(
                "session", "session_low_volume_hint", requestId: requestId,
                detail: "output_volume=\(Self.volumeText(volume)) "
                    + "threshold=\(Self.volumeText(Self.lowVolumeHintThreshold)) "
                    + "turn_index=\(turnIndex)"
            )
        }
        // ESS-650 F2-2：gate ON 时 speaking 期间常开采集（只进 VAD、零上行）。
        // gate OFF 时**根本不开麦**——「回答时也在听」是要给用户明确承诺的，
        // 开关关着却在采集属于隐私违背，不是省事。
        startBargeInListeningIfEnabled()
    }

    // MARK: - ESS-650（F2）语音打断

    /// 进入/离开 speaking 的打断监听闸门。gate 判定只在这一处，采集侧不再
    /// 自己读一遍开关——两处各判一次必然分叉。
    private func startBargeInListeningIfEnabled() {
        guard turnPhase == .speaking, voiceBargeInEnabled() else { return }
        onBeginBargeInListening?()
    }

    /// 停本轮监听并**结账**。幂等（没在监听时 `onEndBargeInListening` 返回
    /// nil，不产生假账）。
    ///
    /// 两条事件，职责刻意分开（ESS-667 复审阻断 5 的处理口径）：
    ///
    /// - `voice_barge_in_round`：**每轮必发**，带 `frames`（本轮真的喂进了
    ///   多少帧）与 `self_echo_frames=0`。它是「监听确实跑过而且干净」的正面
    ///   证据——F2-5 要的那个「零」必须能与「压根没在听」区分开，而「事件
    ///   缺席」区分不了这两者。
    /// - `session_barge_in_self_echo`：**只在真的有自身回声时发**。
    ///   `Shared/PhoneModeCallMetrics.swift` 把它的每次出现计为一次误触发
    ///   （`selfEchoFalseTriggers` → `isEligibleForDefaultOnGate`）。每轮都发
    ///   一条 `=0` 会把 5 轮干净跑成 5 次误触发，直接把 F2-5 门禁反转；所以
    ///   「计数为 0」按 ESS-650 验收原文字面成立：这条事件一条都不出现。
    private func stopBargeInListening(reason: String) {
        guard let summary = onEndBargeInListening?(reason) else { return }
        WatchLog.info(
            "session", "voice_barge_in_round", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) reason=\(reason) "
                + "frames=\(summary.frames) "
                + "self_echo_frames=\(summary.selfEchoFrames) "
                + "cumulative_self_echo_frames=\(summary.cumulativeSelfEchoFrames) "
                + "peak_guard_db=\(String(format: "%.1f", summary.peakGuardDB))"
        )
        guard summary.selfEchoFrames > 0 else { return }
        WatchLog.record(
            PhoneModeTelemetry.bargeInSelfEcho(
                turnIndex: turnIndex, energyDB: summary.peakGuardDB
            ),
            requestId: activeTurnRequestId
        )
    }

    /// ESS-650 F2-3：语音打断命中。走与点球**同一个** `interruptSpeaking`
    /// 入口，只是 `source` 与 `detectMs` 不同——两条打断路径落到不同事件或
    /// 不同状态机，误触发率就永远算不出来（ESS-655 口径 3）。
    /// gate 在命中瞬间已被关掉时一律丢弃：用户刚关掉开关不该再被打断一次。
    func handleVoiceBargeIn(detectMs: Int) {
        guard voiceBargeInEnabled() else {
            WatchLog.info(
                "session", "voice_barge_in_ignored", requestId: activeTurnRequestId,
                detail: "reason=gate_off detect_ms=\(detectMs)"
            )
            return
        }
        guard state == .listening, turnPhase == .speaking else { return }
        interruptSpeaking(source: .voice, detectMs: detectMs)
    }

    /// ESS-650 F2-4：gate 被动态切换。关掉时必须**即时停止采集**——不能等
    /// 本轮回答播完，否则开关关了麦克风还开着。打开时若本轮正在回答，立刻
    /// 开始监听（守卫窗按此刻重新起算：已经放过去的部分没被监听过）。
    func noteVoiceBargeInGateChanged(enabled: Bool) {
        if enabled {
            startBargeInListeningIfEnabled()
        } else {
            stopBargeInListening(reason: "gate_off")
        }    }

    /// 回答**真实播完**。speaking → listening，并自动开下一轮采集。
    ///
    /// `success == false` 时同样回到聆听，但事件名与 reason 如实标注失败——
    /// 复审阻断 2 的口径：失败播放**不许**记成完成，但也不许把会话丢在
    /// 一个既不听也不说的死态里（那正是「每轮按一次」都不如的体验）。
    func markAnswerFinished(requestId: String, success: Bool = true, reason: String = "playback_finished") {
        guard acceptsTurnEvent(requestId, event: "answer_finished") else { return }
        guard turnPhase == .speaking || turnPhase == .thinking else {
            WatchLog.info(
                "session", "session_turn_event_dropped", requestId: requestId,
                detail: "event=answer_finished state=\(state.logName) phase=\(turnPhase.logName) reason=phase_not_speaking_or_thinking turn_index=\(turnIndex)"
            )
            return
        }
        let fromPhase = turnPhase
        // ESS-1097：`onAnswerPlaybackFinished` 的成功终局同时蕴含两件事——
        // 回合级 `audio.done` 屏障已释放**且**最后一段音频渲染完毕。两者分别
        // 入账，聚合体才能在乱序（屏障早到 / 任务晚到）下给出正确判定。
        // 失败终局只清播放面：播放失败不代表上游发过回合屏障。
        if success { toolTurn.apply(.audioDoneBarrier) }
        toolTurn.apply(.playbackEnded)
        if success {
            // ESS-944：rounds 口径对齐 play_finished——只有回答真实播完才计一轮，
            // 失败/打断/中止不计数（验收标准 4）。
            markRoundCompleted()
            WatchLog.info(
                "session", "session_answer_finished", requestId: requestId,
                detail: "turn_index=\(turnIndex) from=\(fromPhase.logName) reason=\(reason) \(toolTurn.logDetail)"
            )
        } else {
            WatchLog.error(
                "session", "session_answer_failed", requestId: requestId,
                detail: "turn_index=\(turnIndex) from=\(fromPhase.logName) reason=\(reason) \(toolTurn.logDetail)",
                code: "ERR_SESSION_ANSWER_FAILED"
            )
        }
        // ESS-650：离开 speaking 即停采（回答播完 / 失败都算）。
        stopBargeInListening(reason: success ? "answer_finished" : "answer_failed")
        // ESS-1097 核心闸门：工具回合没终结就**不许自动开下一轮**。
        // 新一轮会开一个新 generation，把仍在 running 的工具任务 supersede 掉——
        // 那正是 ESS-1095 观测到的「工具答案丢失」。这里退回等待态、重新武装
        // 有界预算，与 ESS-971 的段落 interim 走同一条路。
        guard !toolTurn.blocksAutomaticNextTurn else {
            turnPhase = .thinking
            lowVolumeHint = false
            WatchLog.info(
                "session", "session_next_turn_suppressed", requestId: requestId,
                detail: "turn_index=\(turnIndex) reason=tool_turn_open "
                    + "from=\(fromPhase.logName) answer_reason=\(reason) \(toolTurn.logDetail)"
            )
            armThinkingTimeout()
            renewTaskActivityDeadline(reason: "next_turn_suppressed")
            return
        }
        startNextTurn(reason: success ? "answer_finished" : "answer_failed:\(reason)")
    }

    /// ESS-1044：本轮在服务端**判了终态失败**（relay `phase=failed` /
    /// Bridge `state=failed`）。thinking → P6 失败态，**不等 45s 硬超时**。
    ///
    /// 为什么单开一条边而不是复用 `markChannelFailed`：通道没坏——坏的是
    /// 这一轮的执行（真机证据 `failure_stage=execution`「助手这边还没准备好」）。
    /// `markChannelFailed` 会 `onTeardownChannel?()` 把整条链拆掉并补一次
    /// `.failure` 触觉；这里两者都不做，与既有的 `session_thinking_hard_timeout`
    /// 收口路径完全同构（`enterFailed` → P6 → 15s 无操作自动挂断），
    /// 只是把 45s 的干等提前到失败到达的那一刻。触觉由 ESS-180 的
    /// `AvatarErrorPresenter` 一次性兑现，本控制器不叠加第二下。
    ///
    /// 三重闸门，缺一不可：
    /// - `isInSession`：PTT 模式的失败与会话无关，直接丢；
    /// - `activeTurnRequestId` 归属：陈旧回合的迟到失败不许杀掉当前会话；
    /// - `turnPhase == .thinking`：只有「在等回答」才有卡死可言。已 speaking
    ///   （答案在放）或已收口（P6/已回聆听）时收到的重复失败一律丢弃留证——
    ///   同一次失败会经 iPhone 回执与 Bridge WSS 各来一次，本闸门即幂等所在。
    ///
    /// 相位闸门**不足以**单独承担「成功回合不被误杀」：纯文本结果（ESS-48）与
    /// 段落屏障期间，journal 已是 `.completed` 而本控制器仍停在 `.thinking`
    /// （相位由真实起播推进），此刻闸门是敞开的。矛盾终态的 success-wins 判定
    /// 在上游 `PushToTalkController.journal.onTerminalFailure` 就地做掉，
    /// 本闸门只作纵深防御。
    func markTurnFailed(requestId: String, errorCode: String? = nil, reason: String = "relay_failed") {
        guard isInSession else { return }
        guard let active = activeTurnRequestId, active == requestId else {
            WatchLog.info(
                "session", "session_stale_turn_event", requestId: requestId,
                detail: "event=turn_failed active_request_id=\(activeTurnRequestId ?? "nil") turn_index=\(turnIndex)"
            )
            return
        }
        guard turnPhase == .thinking else {
            WatchLog.info(
                "session", "session_turn_event_dropped", requestId: requestId,
                detail: "event=turn_failed state=\(state.logName) phase=\(turnPhase.logName) reason=phase_not_thinking turn_index=\(turnIndex)"
            )
            return
        }
        toolTurn.apply(.turnFailed(code: errorCode ?? "ERR_SESSION_TURN_FAILED"))
        refreshToolProcessingText()
        WatchLog.error(
            "session", "session_turn_failed", requestId: requestId,
            detail: "turn_index=\(turnIndex) reason=\(reason) \(toolTurn.logDetail)",
            code: errorCode ?? "ERR_SESSION_TURN_FAILED"
        )
        enterFailed(reason: Self.turnFailureCopy, retryable: true)
    }

    /// 本轮**零提交**收场（说得太短 / 收尾抛错）。没有 thinking 可进，
    /// 直接重开采集；但 Watch 无 AEC，错误提示音正在外放时立刻开麦会被
    /// 自己的声音再次触发 VAD，因此退避一小段再开。
    func markTurnAborted(requestId: String, reason: String) {
        guard acceptsTurnEvent(requestId, event: "turn_aborted") else { return }
        turnCapToken?.cancel(); turnCapToken = nil
        thinkingToken?.cancel(); thinkingToken = nil
        turnPhase = .idle
        WatchLog.info(
            "session", "session_turn_aborted", requestId: requestId,
            detail: "turn_index=\(turnIndex) reason=\(reason) relisten_in_ms=\(Int(Self.abortedTurnRelistenDelaySeconds * 1000))"
        )
        relistenToken?.cancel()
        relistenToken = scheduleDelay(Self.abortedTurnRelistenDelaySeconds) { [weak self] in
            guard let self, self.state == .listening, self.turnPhase == .idle else { return }
            self.startNextTurn(reason: "turn_aborted:\(reason)")
        }
    }

    /// F4 手动打断：speaking 中点球 → 立刻停播 → 直接开下一轮。
    ///
    /// ESS-655：打断事件扩字段 `source` / `detect_ms` / `stop_ms`。
    /// - `source`：点球恒 `.orbTap`；语音打断（ESS-650 / F2）复用这同一个
    ///   入口传 `.voice`，**不另起第二条打断路径**——两条路径落到不同事件
    ///   或不同状态机，误触发率就永远算不出来。
    /// - `detectMs`：点球恒 0（点下去即判定）；语音路径填「起说 → 判定命中」。
    /// - `stopMs`：本地停播动作的真实耗时，在这里就地量——把「慢在检测」和
    ///   「慢在停播」分开，才对得上设计稿 ≤200ms 停播的口径。
    func interruptSpeaking(
        source: PhoneModeTelemetry.InterruptSource = .orbTap,
        detectMs: Int = 0
    ) {
        guard state == .listening, turnPhase == .speaking else { return }
        // ESS-1097：用户主动打断是**明确终态**，本轮就此作废——工具门禁到此
        // 让路（验收原文：「工具回合未完成时禁止自动开启新 generation；
        // 用户主动打断除外」）。
        toolTurn.apply(.userCancelled(reason: source.rawValue))
        refreshToolProcessingText()
        // ESS-650：打断即离开 speaking，先停采再停播——顺序有意：停采在前，
        // 停播过程中的扬声器余音才不会再喂进检测器。
        stopBargeInListening(reason: "interrupted")
        let stopStartedAt = DispatchTime.now().uptimeNanoseconds
        // ESS-650 F2-3：`stop_ms` 量到**播放器确认停播**，不是量到闭包返回。
        let stopConfirmed = onInterruptSpeaking?(source) ?? false
        let stopMs = Int((DispatchTime.now().uptimeNanoseconds &- stopStartedAt) / 1_000_000)
        WatchLog.record(
            PhoneModeTelemetry.speakingInterrupted(
                source: source, detectMs: detectMs, stopMs: stopMs, turnIndex: turnIndex
            ),
            requestId: activeTurnRequestId
        )
        if !stopConfirmed {
            // 没被播放器确认时 `stop_ms` 是个测量对象错了的数——必须留证，
            // 否则「≤200ms 停播」这条验收会拿它蒙混过关。
            WatchLog.error(
                "session", "session_interrupt_stop_unconfirmed",
                requestId: activeTurnRequestId,
                detail: "turn_index=\(turnIndex) source=\(source.rawValue) stop_ms=\(stopMs)",
                code: "ERR_SESSION_STOP_UNCONFIRMED"
            )
        }
        startNextTurn(reason: "user_interrupt")
    }

    /// 开启下一轮采集。`onStartTurn` 返回新一轮的 request_id——从这一刻起
    /// 旧 id 的任何事件都会被 `acceptsTurnEvent` 挡在门外。
    /// ESS-960：无人说话的回合到 `turnCap` 时**只换麦克风，不换相位**。
    ///
    /// 刻意不走 `startNextTurn`：那条路在 `onStartTurn` 返回 nil 时会把相位
    /// 打到 `.idle`，而静默治理的 30s/75s/120s 全部以 `turnPhase == .listening`
    /// 为前提（ESS-865 阻断 2 的口径）——重开失败却把会话推出聆听态，比死
    /// 麦克风更糟：用户放下手走开就再也等不到自动挂断了。
    ///
    /// 同理**不重新武装静默时钟**：那是会话级策略，不能因为换了个麦克风
    /// 就从头计时。
    private func restartCaptureAfterSilentTurnCap() {
        guard let requestId = onStartTurn?() else {
            WatchLog.error(
                "session", "session_turn_cap_restart_failed",
                requestId: activeTurnRequestId,
                detail: "turn_index=\(turnIndex) cap_s=\(Int(Self.turnCapSeconds))",
                code: "ERR_SESSION_TURN_START"
            )
            return
        }
        turnIndex += 1
        activeTurnRequestId = requestId
        didDetectSpeechThisTurn = false
        resetToolTurn(reason: "turn_cap_no_speech_restart")
        WatchLog.info(
            "session", "session_turn_cap_no_speech_restart", requestId: requestId,
            detail: "turn_index=\(turnIndex) cap_s=\(Int(Self.turnCapSeconds)) "
                + "reason=no_speech_detected"
        )
        // 继续下一个上限窗口；静默治理的会话级时钟不动。
        armTurnCap()
    }

    private func startNextTurn(reason: String) {
        guard state == .listening else { return }
        relistenToken?.cancel(); relistenToken = nil
        thinkingToken?.cancel(); thinkingToken = nil
        lowVolumeHint = false
        guard let requestId = onStartTurn?() else {
            // 启动失败不许假装还在听。真实失败事件（录音启动失败 /
            // 通道死亡）会经 markChannelFailed 把会话收口。
            turnPhase = .idle
            activeTurnRequestId = nil
            resetToolTurn(reason: "next_turn_start_failed")
            WatchLog.error(
                "session", "session_next_turn_start_failed",
                detail: "turn_index=\(turnIndex) reason=\(reason)",
                code: "ERR_SESSION_TURN_START"
            )
            return
        }
        turnIndex += 1
        previousTurnRequestId = activeTurnRequestId
        activeTurnRequestId = requestId
        turnPhase = .listening
        didDetectSpeechThisTurn = false
        resetToolTurn(reason: "next_turn")
        WatchLog.info(
            "session", "session_next_listening", requestId: requestId,
            detail: "turn_index=\(turnIndex) reason=\(reason)"
        )
        if Self.hapticOnAutoRelisten { playHaptic(.ready) }
        armTurnCap()
        // ESS-652: arm silence governance timer for the new turn.
        armSilenceTimer()
    }

    /// 通道失败（建立期或会话期），全部来自真实事件：
    /// 录音启动失败 / 上行发送失败 / 适配器回退 / 就绪超时。
    /// PRD 异常链 A/B：明确告知 + 退回待机，不静默卡在建立中、
    /// 不假装还在对话。文案按失败时所处态区分——建立中失败是
    /// 「连不上」（异常链 A），会话中断了是「连接断了」（异常链 B）。
    func markChannelFailed(_ failure: ChannelFailure) {
        guard isInSession else { return }
        let failedFrom = state
        // ESS-1097：通道死了就不会再有 `audio.done` / `task.*` 终态。如实收下
        // 这个事实，让聚合体走「放弃等待、但在播的音频要放完」那条边，
        // 而不是把回合永远按在思考态。
        toolTurn.apply(.downlinkClosed(reason: failure.logReason))
        refreshToolProcessingText()
        cancelConnectingTimers()
        cancelTurnTimers()
        stopBargeInListeningOnTeardown()
        // ESS-652: enter P6 failed state instead of dropping to idle.
        // The user stays in the call screen with failure UI.
        enterFailed(reason: Self.failureCopy(forState: failedFrom),
                    retryable: failure != .recorderStart)
        turnPhase = .idle
        activeTurnRequestId = nil
        isCapturingLocally = false
        WatchLog.info(
            "session", "session_channel_failed",
            detail: "reason=\(failure.logReason) from=\(failedFrom.logName)"
        )
        switch failure {
        case .recorderStart:
            break
        case .channelEvent:
            playHaptic(.failure)
        }
        onTeardownChannel?()
    }

    // MARK: - ESS-652 P6/P7 生命周期

    /// 进入 P6 失败态。回话内显示失败界面，不退回待机。
    func enterFailed(reason: String, retryable: Bool) {
        state = .failed
        failedReason = reason
        // 同 enterHungup：失败也必须收束回合状态与采集。
        resetTurnStateOnExit()
        failedRetryable = retryable
        thinkingSlowHint = false
        cancelAllESS652Timers()
        WatchLog.info("session", "session_failed_notice_shown",
                      detail: "reason=\(reason) retryable=\(retryable)")
        // P6 15s 无操作自动挂断
        failedAutoToken = scheduleDelay(Self.failedAutoHangupSeconds) { [weak self] in
            guard let self, self.state == .failed else { return }
            WatchLog.info("session", "session_failed_auto_hangup")
            self.enterHungup(rounds: self.completedRounds, reason: "auto")
        }
    }

    /// P6 重试：回 P1 重新接通。
    func retryFromFailed() {
        guard state == .failed else { return }
        WatchLog.info("session", "session_failed_retry_tapped")
        state = .idle
        failedReason = nil
        failedRetryable = false
        cancelAllESS652Timers()
        enterSession()
    }

    /// P6 挂断：回 idle。
    func hangupFromFailed() {
        guard state == .failed else { return }
        WatchLog.info("session", "session_failed_hangup_tapped")
        enterHungup(rounds: completedRounds, reason: "user")
    }

    /// 进入 P7 挂断态。显示摘要，1.2s 后回 idle。
    func enterHungup(rounds: Int, reason: String) {
        lastExitReasonCode = Self.exitReasonCode(for: reason)
        state = .hungup
        failedReason = nil
        failedRetryable = false
        thinkingSlowHint = false
        cancelAllESS652Timers()
        // ESS-652 用 enterHungup 取代 teardownToIdle 作为退出路径，但没有把
        // 回合状态重置搬过来：退出后 turnPhase/activeTurnRequestId/turnIndex
        // 仍是上一轮的值，迟到事件会被 acceptsTurnEvent 放行——正是 ESS-642
        // 修过的「旧回合污染新会话」事故面。这里补齐。
        resetTurnStateOnExit()
        if readyTimeoutSalvageCount > 0 {
            hungupSummary = "已结束 · \(rounds) 轮（\(reason)）· 实时链路降级 \(readyTimeoutSalvageCount) 次"
        } else {
            hungupSummary = "已结束 · \(rounds) 轮（\(reason)）"
        }
        WatchLog.info("session", "session_call_summary",
                      detail: "rounds=\(rounds) reason=\(reason) ready_timeout_salvage_count=\(readyTimeoutSalvageCount)")
        onTeardownChannel?()
        hungupDismissToken = scheduleDelay(Self.hungupDismissSeconds) { [weak self] in
            guard let self, self.state == .hungup else { return }
            self.state = .idle
            self.hungupSummary = nil
            self.completedRounds = 0
            self.readyTimeoutSalvageCount = 0
            WatchLog.info(
                "session", "session_page_exited",
                detail: "reason=\(reason) rounds=\(rounds) destination=idle"
            )
        }
    }

    // MARK: - ESS-652 思考超时与静默治理
    /// 聆听态启动静默计时器。每次新一轮聆听重置。
    func armSilenceTimer() {
        silenceToken?.cancel()
        // Stage 1: 30s soft hint
        silenceToken = scheduleDelay(Self.silenceHint1Seconds) { [weak self] in
            guard let self, self.state == .listening, self.turnPhase == .listening else { return }
            WatchLog.info("session", "session_idle_hint", requestId: self.activeTurnRequestId,
                          detail: "level=1")
            // Stage 2: 75s hint + haptic
            self.silenceToken?.cancel()
            self.silenceToken = self.scheduleDelay(Self.silenceHint2Seconds - Self.silenceHint1Seconds) { [weak self] in
                guard let self, self.state == .listening, self.turnPhase == .listening else { return }
                self.playHaptic(.failure)
                WatchLog.info("session", "session_idle_hint", requestId: self.activeTurnRequestId,
                              detail: "level=2")
                // Stage 3: 120s hangup
                self.silenceToken?.cancel()
                self.silenceToken = self.scheduleDelay(Self.silenceHangupSeconds - Self.silenceHint2Seconds) { [weak self] in
                    guard let self, self.isInSession else { return }
                    WatchLog.info("session", "session_idle_hangup")
                    self.enterHungup(rounds: self.completedRounds, reason: "静默超时")
                }
            }
        }
    }

    /// 记录一轮完成并重置静默计时器。
    func markRoundCompleted() {
        completedRounds += 1
        WatchLog.info("session", "session_round_completed",
                      detail: "rounds=\(completedRounds)")
    }

    private func cancelAllESS652Timers() {
        thinkingSlowToken?.cancel()
        thinkingHardToken?.cancel()
        toolTurnHardToken?.cancel(); toolTurnHardToken = nil
        taskActivityToken?.cancel(); taskActivityToken = nil
        downlinkResumeToken?.cancel(); downlinkResumeToken = nil
        silenceToken?.cancel()
        failedAutoToken?.cancel()
        hungupDismissToken?.cancel()
        thinkingSlowToken = nil
        thinkingHardToken = nil
        silenceToken = nil
        failedAutoToken = nil
        hungupDismissToken = nil
        thinkingSlowHint = false
    }

    /// 会话中系统进入后台。会话级 `.playAndRecord` 与前台延长已建立时，
    /// scenePhase 变化只代表 UI 不再 frontmost，不能据此主动取消仍在采集的
    /// turn；否则放腕会把一次正常说话误判成用户退出。
    func noteEnteredBackground() {
        guard isInSession else { return }
        WatchLog.info(
            "session", "session_continues_in_background",
            detail: "state=\(state.logName) channel_preserved=true"
        )
    }

    // MARK: - 退出

    /// 点 X 或下滑退出会话。任意会话态可触发。
    /// ESS-652: 走 P7 挂断页，显示摘要后回 idle。
    func exitSession() {
        guard isInSession else { return }
        WatchLog.info("session", "session_exit_requested", detail: "source=user")
        playHaptic(.exit)
        enterHungup(rounds: completedRounds, reason: "用户挂断")
    }

    private func teardownToIdle() {
        cancelConnectingTimers()
        cancelTurnTimers()
        stopBargeInListeningOnTeardown()
        let turns = turnIndex
        state = .disconnecting
        turnPhase = .idle
        resetToolTurn(reason: "teardown")
        activeTurnRequestId = nil
        turnIndex = 0
        isCapturingLocally = false
        onTeardownChannel?()
        state = .idle
        enteredAt = nil
        WatchLog.info("session", "session_ended", detail: "mic_released=true turns=\(turns)")
    }

    /// ESS-650：会话拆链 / 失败时一并停采，不把麦克风留在会话之外（PD-2）。
    /// ESS-650：会话拆链/失败时一并停采，不把麦克风留在会话之外。

    /// ESS-652：会话以任何方式结束（挂断 / 失败 / 拆链）时统一收束回合状态。
    /// 不重置会让退出后的迟到事件被当成当前轮受理（ESS-642 事故面）。
    private func resetTurnStateOnExit() {
        cancelTurnTimers()
        stopBargeInListening(reason: "session_exit")
        resetToolTurn(reason: "session_exit")
        turnPhase = .idle
        activeTurnRequestId = nil
        turnIndex = 0
        isCapturingLocally = false
        lowVolumeHint = false
    }
    private func stopBargeInListeningOnTeardown() {
        stopBargeInListening(reason: "session_exit")
    }

    private func cancelTurnTimers() {
        turnCapToken?.cancel(); turnCapToken = nil
        thinkingToken?.cancel(); thinkingToken = nil
        relistenToken?.cancel(); relistenToken = nil
        // ESS-652: cancel thinking slow/hard timers on turn reset.
        thinkingSlowToken?.cancel(); thinkingSlowToken = nil
        thinkingHardToken?.cancel(); thinkingHardToken = nil
        // ESS-1097：工具绝对上限属于回合，回合收束时一并取消。
        toolTurnHardToken?.cancel(); toolTurnHardToken = nil
        // ESS-1111：静默预算与重连宽限同为回合级。
        taskActivityToken?.cancel(); taskActivityToken = nil
        downlinkResumeToken?.cancel(); downlinkResumeToken = nil
        thinkingSlowHint = false
    }

    // MARK: - 首次引导（PRD §3.5.7）

    /// 只在「首次进入且通道就绪后」浮现，3 秒淡出，此后不再出现。
    /// 本形态最反直觉的点是不需要按住——老用户带着「按住说话」的肌肉记忆，
    /// 不给一次提示会以为坏了。这是唯一值得打断沉浸的提示。
    private func presentFirstRunGuideIfNeeded() {
        guard !defaults.bool(forKey: Self.firstRunGuideShownKey) else { return }
        defaults.set(true, forKey: Self.firstRunGuideShownKey)
        showFirstRunGuide = true
        guideToken = scheduleDelay(Self.firstRunGuideSeconds) { [weak self] in
            self?.showFirstRunGuide = false
        }
    }

    // MARK: - 失败文案

    private func presentFailureNotice(_ copy: String) {
        noticeToken?.cancel()
        failureNotice = copy
        noticeToken = scheduleDelay(Self.failureNoticeSeconds) { [weak self] in
            self?.failureNotice = nil
        }
    }

    /// ESS-843：展示文案 → 机器可读的会话结束原因码（纯函数，便于钉住映射）。
    /// 验收标准 4：用户主动退出 / 120 秒策略触发才释放 owner，并记录明确 reason。
    static func exitReasonCode(for reason: String) -> ExitReasonCode {
        switch reason {
        case "静默超时": return .silencePolicy
        case "auto": return .failedAutoHangup
        default: return .userExit
        }
    }

    /// 文案纪律（PRD 异常链 A/B）：说清「怎么办」，不出现错误码。
    /// 建立中失败 → 引导用户检查 iPhone；会话中断开 → 告知本轮已结束。
    /// ESS-1044：本轮执行失败（通道还在）的 P6 文案。与「连接断了」区分开——
    /// 链路没断，是这一轮没答上来，可重试是有意义的（PRD 异常链口径：
    /// 说清「怎么办」而非「什么错了」）。
    static let turnFailureCopy = "这轮没答上来，要再试一次吗？"

    static func failureCopy(forState state: State) -> String {
        switch state {
        case .connecting:
            return "连不上，检查一下 iPhone 是否在身边"
        // ESS-673：ESS-652 给 `State` 加了 `.failed` / `.hungup` 两态却没补
        // 这个 switch，编译不过（被同文件的 redeclaration 错误挡在后面，
        // 修掉那条才暴露出来）。两态都是「已经聊过、链路在中途断的」，
        // 与 listening 同一条文案，不新造第三种说法。
        case .listening, .disconnecting, .idle, .failed, .hungup:
            return "连接断了，本轮对话已结束"
        }
    }

    /// ESS-891：是否该提示调高音量（纯函数，便于钉住阈值）。
    static func shouldSurfaceLowVolumeHint(outputVolume: Float) -> Bool {
        outputVolume < lowVolumeHintThreshold
    }

    /// ESS-891：音量读数转日志固定精度（0.0–1.0）。
    private static func volumeText(_ volume: Float) -> String {
        String(format: "%.3f", volume)
    }

    private func cancelConnectingTimers() {
        dotsToken?.cancel(); dotsToken = nil
        timeoutToken?.cancel(); timeoutToken = nil
        showConnectingDots = false
    }

    // MARK: - 手势冲突决策（PRD §3.5.6，纯函数便于 WatchTests 钉住）

    /// 会话中是否渲染②③屏（历史/设置）。false = TabView 只剩主屏一页，
    /// 左右滑动无页可切——比「拦截手势」更彻底，不存在拖到一半回弹的
    /// 中间态。会话中滑走等于静默丢失上下文，必须禁用。
    static func showsAuxiliaryTabs(inSession: Bool) -> Bool {
        !inSession
    }

    /// 下滑是否构成「下滑退出」（等同点 X）。只响应以垂直为主、
    /// 位移足够大的下滑；水平分量大的拖拽（误触/斜滑）不触发。【待调】
    static func isVerticalDismiss(translation: CGSize) -> Bool {
        translation.height > 40 && translation.height > abs(translation.width) * 1.5
    }

    /// 主屏球松手被拒的原因（`session_enter_rejected.reason`）。
    ///
    /// ESS-686：持续对话入口不再按按住时长拒绝；这里只保留真实的起采失败，
    /// 让调用方能安全清理未建立的回合并留下可复核日志。
    enum EnterRejection: String {
        /// touch-down 那次采集没能开起来（上一轮还在收尾、
        /// 录音启动失败等）。没有在飞的一轮可认领，进会话会当场空转。
        case captureUnavailable = "capture_unavailable"
    }

    enum OrbReleaseAction: Equatable {
        case enter
        case reject(EnterRejection)
    }

    /// ESS-843：机器可读的会话结束原因（供 keep-alive owner 释放记账）。
    /// 验收标准 4 要求「用户主动退出 / 120 秒策略触发时才释放 owner，并记录
    /// 明确 reason」——本枚举把展示文案映射为可 grep 的原因码。
    enum ExitReasonCode: String {
        case userExit = "user_exit"
        case silencePolicy = "silence_policy"
        case failedAutoHangup = "failed_auto_hangup"
    }

    /// 主屏球松手的唯一判定点（纯函数，便于 WatchTests 钉死）。
    ///
    /// ESS-686：持续对话入口与旧 PTT 时长门槛彻底分流。只要 touch-down
    /// 那轮确实在采集，任何按住时长松手后都进入会话；没有分支回到单条提交。
    static func orbReleaseAction(holdSeconds: TimeInterval, isCapturing: Bool) -> OrbReleaseAction {
        _ = holdSeconds // 仅供拒绝遥测，不参与持续对话入口判定。
        guard isCapturing else { return .reject(.captureUnavailable) }
        return .enter
    }

    /// 留证一次被拒的进入。静默拒绝是设计口径（误触不该给反馈），但
    /// 「用户按了却什么都没发生」必须在日志里可解释，否则真机复盘只剩猜。
    func noteEnterRejected(reason: EnterRejection, holdSeconds: TimeInterval) {
        // `holdSeconds` 在 touch-down 时刻缺失时是 .infinity，直接 Int() 会 trap。
        let holdMs = holdSeconds.isFinite ? Int((holdSeconds * 1000).rounded()) : -1
        WatchLog.info(
            "session", "session_enter_rejected",
            detail: "reason=\(reason.rawValue) hold_ms=\(holdMs)"
        )
    }
}

// MARK: - ESS-600 会话 ↔ 采集/播放 接线

/// ESS-600：把 `SessionController` 的回合状态机接到 `PushToTalkController`
/// 的真实采集/提交/播放事件上。
///
/// 单独成函数而不是散在 `WatchAppServices.bootstrap` 里，是因为「接线有没有
/// 接上」本身就是本单第一次复审被打回的那个缺陷（realtime 播放事件根本没有
/// 接到状态机上）。接线可被测试直接调用，就能用一条断言钉死它。
@MainActor
enum SessionTurnWiring {

    /// - Parameter interruptSelfCheck: 起轮前让出音频会话（ESS-65 铁律 3）。
    static func connect(
        session: SessionController,
        pushToTalk: PushToTalkController,
        interruptSelfCheck: @escaping () -> Void
    ) {
        session.onBeginChannel = { [weak pushToTalk] in
            interruptSelfCheck()
            guard let pushToTalk else { return nil }
            // ESS-601 的「清理上一次会话残留」意图由 ESS-642 的会话边界闸门
            // 承担（beginSessionConversation 只在回合**不属于本次 touch-down**
            // 时才丢弃）。此处不得无条件 pressCancelled()——那会把本次
            // touch-down 正在飞的首轮一并杀掉，会话随后认领到的是重起的那一轮，
            // 首句丢失且 request_id 对不上（ESS-648 已钉住的用例）。
            pushToTalk.beginSessionConversation()
            // ESS-600：必须把 request_id 交回会话层认领首轮；丢掉返回值会让
            // 会话认领不到在飞那一轮，首轮永远等不到 play_started/finished。
            return pushToTalk.pressBegan()
        }
        session.onStartTurn = { [weak pushToTalk] in
            interruptSelfCheck()
            return pushToTalk?.beginSessionTurn()
        }
        session.onTeardownChannel = { [weak pushToTalk] in
            pushToTalk?.endSessionChannel()
        }
        session.onCommitTurn = { [weak pushToTalk] in
            pushToTalk?.endSessionTurn()
        }
        session.onInterruptSpeaking = { [weak pushToTalk] source in
            // ESS-650：两种触发源共用同一条停播路径，只在日志里分开。
            pushToTalk?.interruptAnswerPlayback(source: source) ?? false
        }
        session.onSalvageTurn = { [weak pushToTalk] in
            pushToTalk?.endSessionTurn()
        }
        // ESS-573：通道就绪 / 通道失败（唯一的 connecting → listening / idle 驱动源）。
        pushToTalk.onRealtimeChannelReady = { [weak session] in
            session?.markChannelReady()
        }
        pushToTalk.onRealtimeChannelFailed = { [weak session] failure in
            session?.markChannelFailed(failure)
        }
        pushToTalk.onSessionTurnCommitted = { [weak session] requestId in
            session?.markTurnCommitted(requestId: requestId)
        }
        pushToTalk.onSessionAnswerStarted = { [weak session] requestId in
            session?.markAnswerStarted(requestId: requestId)
        }
        pushToTalk.onSessionAnswerFinished = { [weak session] requestId, success, reason in
            session?.markAnswerFinished(requestId: requestId, success: success, reason: reason)
        }
        pushToTalk.onSessionAnswerInterim = { [weak session] requestId in
            session?.markAnswerInterim(requestId: requestId)
        }
        pushToTalk.onSessionTurnAborted = { [weak session] requestId, reason in
            session?.markTurnAborted(requestId: requestId, reason: reason)
        }
        // ESS-1044：服务端判本轮终态失败 → 立刻收口，不等 45s 硬超时。
        pushToTalk.onSessionTurnFailed = { [weak session] requestId, errorCode in
            session?.markTurnFailed(requestId: requestId, errorCode: errorCode)
        }
        // ESS-1097：上游任务生命周期 → 会话层回合聚合状态机。
        pushToTalk.onSessionTaskState = { [weak session] requestId, taskId, status, progress, answer, generation in
            session?.markTaskState(
                requestId: requestId, taskId: taskId, status: status,
                progress: progress, answer: answer, generation: generation
            )
        }
        // ESS-1111：长任务在跑期间的断线 → 有界重连宽限，而不是当场判失败。
        pushToTalk.sessionHasLongTaskInFlight = { [weak session] in
            session?.hasLongTaskInFlight ?? false
        }
        pushToTalk.onSessionDownlinkInterrupted = { [weak session] requestId, reason in
            session?.markDownlinkInterrupted(requestId: requestId, reason: reason)
        }
        session.onDownlinkGraceExpired = { [weak pushToTalk] reason in
            pushToTalk?.finishDeferredTransportFailure(reason: reason)
        }
        session.onDownlinkResumed = { [weak pushToTalk] reason in
            pushToTalk?.clearDeferredTransportFailure(reason: reason)
        }
        pushToTalk.onLocalCaptureChanged = { [weak session] active in
            session?.markLocalCapture(active: active)
        }
        // ESS-865：本地 VAD 起判 → 会话层记账本轮「确实有人说话」。
        pushToTalk.onSessionSpeechDetected = { [weak session] requestId in
            session?.markSpeechDetected(requestId: requestId)
        }
        // ESS-650 F2-2 / F2-3：打断监听的起停与命中回调。
        session.onBeginBargeInListening = { [weak pushToTalk] in
            pushToTalk?.beginVoiceBargeInListening()
        }
        session.onEndBargeInListening = { [weak pushToTalk] reason in
            pushToTalk?.endVoiceBargeInListening(reason: reason)
        }
        pushToTalk.onSessionVoiceBargeIn = { [weak session] detectMs in
            session?.handleVoiceBargeIn(detectMs: detectMs)
        }
    }
}

// MARK: - 延迟令牌

/// 延迟执行的取消令牌。`cancel` 幂等。
protocol SessionDelayToken {
    func cancel()
}

/// 生产实现：Task.sleep 驱动。`@MainActor` 回调在任务体内恢复。
private final class SessionTaskDelayToken: SessionDelayToken {
    private let task: Task<Void, Never>

    init(seconds: TimeInterval, fire: @escaping @MainActor () -> Void) {
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    func cancel() {
        task.cancel()
    }
}

private extension SessionController.ChannelFailure {
    var logReason: String {
        switch self {
        case .recorderStart: return "recorder_start"
        case .channelEvent: return "channel_event"
        }
    }
}

extension SessionController.TurnPhase {
    var logName: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        }
    }
}

private extension SessionController.State {
    var logName: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .listening: return "listening"
        case .failed: return "failed"
        case .hungup: return "hungup"
        case .disconnecting: return "disconnecting"
        }
    }
}
