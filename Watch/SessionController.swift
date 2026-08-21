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
    @Published private(set) var turnPhase: TurnPhase = .idle
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
    /// ESS-600：就绪超时的**抢救**出口——把已经录到的语音经可靠通道
    /// （完整文件 / WCSession transferFile）提交，而不是连人带话一起丢。
    /// 生产接 `PushToTalkController.endSessionTurn()`。
    var onSalvageTurn: (() -> Void)?
    /// ESS-960 / ESS-962 阻断 3：**丢弃**当前这一轮采集（不提交、不动会话）。
    /// 生产接 `PushToTalkController.discardSessionTurn()`。与 `onSalvageTurn`
    /// 互补：那条是「录到了，救出去」，这条是「整轮没人说话，扔掉」。
    var onDiscardTurn: (() -> Void)?

    // MARK: - 参数（PRD 数值，【待调】项需真机体感定稿）

    /// 建立中超过该时长未就绪 → 显示三点提示。PRD §3.5.1：800ms。
    static let connectingDotsDelaySeconds: TimeInterval = 0.8
    /// 就绪硬超时：首个真实 ack 未到即判失败。【待调】初值 5s——
    /// 经验值：WCSession 投递 + iPhone WSS 首发确认正常 < 2s；
    /// 15s（iphone_relay_stuck）对本场景过长，用户在建立中干等不可接受。
    static let readyTimeoutSeconds: TimeInterval = 5.0
    /// 失败文案停留时长。PRD 异常链 A/B：2 秒后自动回待机。
    static let failureNoticeSeconds: TimeInterval = 2.0
    /// ESS-960：整轮没听到人说话时的一行提示。文案纪律（PRD 异常链）——
    /// 说清「怎么办」，不出现错误码，不解释内部状态。
    static let noSpeechNoticeCopy = "没听到你说话，抬手靠近再说一次"
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
    private var silenceToken: SessionDelayToken?
    private var failedAutoToken: SessionDelayToken?
    private var hungupDismissToken: SessionDelayToken?
    /// ESS-652: 会话内轮数。
    private var completedRounds = 0

    /// ESS-600：当前**被认领**的回合 request_id。所有回合事件都必须携带
    /// request_id 并与它相等才被受理——这是「旧 request / 旧 generation 的
    /// 迟到音频不得进入下一轮」在会话层的闸门。上一轮的迟到 `.ended` 到达时
    /// 这里已经换成新 id，事件被丢弃并留证（`session_stale_turn_event`）。
    private(set) var activeTurnRequestId: String?
    /// ESS-600：会话内回合序号，从 1 开始严格递增。conversation 级的
    /// `conversation_id` / `turn_id` 真相在 `RealtimeMediaSession.ConversationHandle`
    /// （唯一铸造点），本序号只是会话层日志的可读游标，不另铸 id。
    private(set) var turnIndex = 0
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
            WatchLog.error(
                "session", "session_ready_timeout_salvage",
                requestId: self.activeTurnRequestId,
                detail: "timeout_s=\(Int(Self.readyTimeoutSeconds)) capturing=\(self.isCapturingLocally)",
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
    ///
    /// ESS-960 缺陷 3：不提交是对的，**什么都不做是错的**。真机 L1
    /// （`audio_too_short pcm_bytes=1916800 duration_ms=59900 rms=5`）里这一轮
    /// 录满 59.9 秒、rms=5（≈ -76 dBFS，约为 VAD 门限 int16≈257 的 1/50），
    /// 永远不可能断句；50s 时本闭包已经**知道**「50 秒没听到人说话」，却只落
    /// 一条日志就走人——用户在 60s 录音自停 → 整文件回退 → Bridge 判太短 →
    /// 失败结果回投的整个过程里得不到任何提示。
    ///
    /// 收口走 `recycleSilentTurn()`，见那里的注释。
    private func armTurnCap() {
        turnCapToken?.cancel()
        turnCapToken = scheduleDelay(Self.turnCapSeconds) { [weak self] in
            guard let self, self.state == .listening, self.turnPhase == .listening else { return }
            guard self.didDetectSpeechThisTurn else {
                self.recycleSilentTurn()
                return
            }
            WatchLog.info("session", "session_turn_cap_reached",
                          requestId: self.activeTurnRequestId,
                          detail: "cap_s=\(Int(Self.turnCapSeconds))")
            self.onCommitTurn?()
        }
    }

    /// ESS-960 缺陷 3 / ESS-962 阻断 3：整轮没听到人说话，到达单轮上限。
    ///
    /// **真正收口**：丢弃这轮死采集（`onDiscardTurn` → `discardSessionTurn()`，
    /// 不提交静音），当场重开一轮新采集，回到可用态。麦克风不留死态，
    /// 会话相位一刻也不离开 `.listening`。
    ///
    /// 三条刻意保留的不变量：
    ///
    /// 1. **不提交**——提交等于把一段静音送上去（ESS-865 复审阻断 2）。
    /// 2. **不重置静默治理**——`startNextTurn` 默认会重新 `armSilenceTimer`，
    ///    那正是 ESS-865 拦下的回归：用户放下手走开，30/75/120s 三级治理被
    ///    每轮刷新，会话永远不自收。这里显式传 `resetSilenceGovernance: false`，
    ///    120s 挂断仍按**最初那次** arm 落地。
    /// 3. **先丢弃再重开**——`pressBegan` 有 `guard state == .idle`，不先把在录
    ///    的那一轮收掉，`onStartTurn` 只会把在飞的旧 request_id 原样返回，
    ///    什么也不会发生（这是初版方案的实际死点）。
    ///
    /// 用户侧复用既有 `failureNotice` 一行浮层 + 失败触觉，**不新增常驻文字、
    /// 不碰 PRD F7**。
    private func recycleSilentTurn() {
        WatchLog.info(
            "session", "session_turn_cap_skipped",
            requestId: activeTurnRequestId,
            detail: "cap_s=\(Int(Self.turnCapSeconds)) reason=no_speech_detected action=recycle turn_index=\(turnIndex)"
        )
        playHaptic(.failure)
        presentFailureNotice(Self.noSpeechNoticeCopy)
        // 先丢弃再重开，**同一个 tick 内完成**。
        //
        // 不走 `markTurnAborted` 的 1.5s 退避：那段退避是为「错误提示音正在
        // 外放、立刻开麦会被自己的声音再次触发 VAD」准备的，本路径只有触觉
        // 没有提示音，不需要它；而只要相位在退避窗里落到 `.idle`，
        // `armSilenceTimer` 三级治理的 `turnPhase == .listening` 前置就会被
        // 打断——那正是 ESS-865 复审阻断 2 钉死的东西。
        onDiscardTurn?()
        startNextTurn(reason: "turn_cap_no_speech", resetSilenceGovernance: false)
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
        thinkingHardToken = scheduleDelay(Self.thinkingHardTimeoutSeconds) { [weak self] in
            guard let self, self.isInSession, self.turnPhase == .thinking else { return }
            WatchLog.info("session", "session_thinking_hard_timeout", requestId: self.activeTurnRequestId)
            self.enterFailed(reason: "回答超时，要再试一次吗？", retryable: true)
        }
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
        // ESS-650：interim 播完退回等待态，已不在 speaking，停采。
        stopBargeInListening(reason: "answer_interim")
        WatchLog.info(
            "session", "session_answer_interim", requestId: requestId,
            detail: "turn_index=\(turnIndex) from=\(fromPhase.logName) phase=thinking"
        )
        armThinkingTimeout()
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
        WatchLog.info(
            "session", "session_answer_started", requestId: requestId,
            detail: "turn_index=\(turnIndex) phase=speaking"
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
        if success {
            // ESS-944：rounds 口径对齐 play_finished——只有回答真实播完才计一轮，
            // 失败/打断/中止不计数（验收标准 4）。
            markRoundCompleted()
            WatchLog.info(
                "session", "session_answer_finished", requestId: requestId,
                detail: "turn_index=\(turnIndex) from=\(fromPhase.logName) reason=\(reason)"
            )
        } else {
            WatchLog.error(
                "session", "session_answer_failed", requestId: requestId,
                detail: "turn_index=\(turnIndex) from=\(fromPhase.logName) reason=\(reason)",
                code: "ERR_SESSION_ANSWER_FAILED"
            )
        }
        // ESS-650：离开 speaking 即停采（回答播完 / 失败都算）。
        stopBargeInListening(reason: success ? "answer_finished" : "answer_failed")
        startNextTurn(reason: success ? "answer_finished" : "answer_failed:\(reason)")
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
    /// - Parameter resetSilenceGovernance: 是否重新起算静默治理（30/75/120s）。
    ///   默认 `true`（正常换轮：用户刚说完话，治理理应重新起算）。
    ///   ESS-962 阻断 3 的静音回收路径传 `false`——那一轮**没有**人说话，
    ///   重置等于把 ESS-865 拦下的「走开后永不自收」原样放回来。
    private func startNextTurn(reason: String, resetSilenceGovernance: Bool = true) {
        guard state == .listening else { return }
        relistenToken?.cancel(); relistenToken = nil
        thinkingToken?.cancel(); thinkingToken = nil
        lowVolumeHint = false
        guard let requestId = onStartTurn?() else {
            // 启动失败不许假装还在听。真实失败事件（录音启动失败 /
            // 通道死亡）会经 markChannelFailed 把会话收口。
            turnPhase = .idle
            activeTurnRequestId = nil
            WatchLog.error(
                "session", "session_next_turn_start_failed",
                detail: "turn_index=\(turnIndex) reason=\(reason)",
                code: "ERR_SESSION_TURN_START"
            )
            return
        }
        turnIndex += 1
        activeTurnRequestId = requestId
        turnPhase = .listening
        didDetectSpeechThisTurn = false
        WatchLog.info(
            "session", "session_next_listening", requestId: requestId,
            detail: "turn_index=\(turnIndex) reason=\(reason)"
        )
        if Self.hapticOnAutoRelisten { playHaptic(.ready) }
        armTurnCap()
        // ESS-652: arm silence governance timer for the new turn.
        if resetSilenceGovernance { armSilenceTimer() }
    }

    /// 通道失败（建立期或会话期），全部来自真实事件：
    /// 录音启动失败 / 上行发送失败 / 适配器回退 / 就绪超时。
    /// PRD 异常链 A/B：明确告知 + 退回待机，不静默卡在建立中、
    /// 不假装还在对话。文案按失败时所处态区分——建立中失败是
    /// 「连不上」（异常链 A），会话中断了是「连接断了」（异常链 B）。
    func markChannelFailed(_ failure: ChannelFailure) {
        guard isInSession else { return }
        let failedFrom = state
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
        hungupSummary = "已结束 · \(rounds) 轮（\(reason)）"
        WatchLog.info("session", "session_call_summary",
                      detail: "rounds=\(rounds) reason=\(reason)")
        onTeardownChannel?()
        hungupDismissToken = scheduleDelay(Self.hungupDismissSeconds) { [weak self] in
            guard let self, self.state == .hungup else { return }
            self.state = .idle
            self.hungupSummary = nil
            self.completedRounds = 0
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
        // ESS-962 阻断 3：静音回收——丢弃这轮采集，不提交、不动会话。
        session.onDiscardTurn = { [weak pushToTalk] in
            pushToTalk?.discardSessionTurn()
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
