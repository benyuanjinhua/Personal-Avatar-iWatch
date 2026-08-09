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

    @Published private(set) var state: State = .idle
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

    /// 会话是否存续（连接中/聆听中）。视图据此切换双模 UI 与手势集。
    var isInSession: Bool {
        switch state {
        case .connecting, .listening: return true
        case .idle, .disconnecting: return false
        }
    }

    // MARK: - 可注入接缝（测试确定性）

    /// 触觉播放接缝：生产由 WatchAppServices 接到 WatchHaptics；测试记调用。
    var playHaptic: (Haptic) -> Void = { _ in }
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
    var onInterruptSpeaking: (() -> Void)?
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
    /// 单轮时长上限（PRD F2 异常：单轮 60 秒强制结束）。取 58s——
    /// 抢在 AudioRecorder 的 60s 系统硬顶之前走正常 finishRecording 提交，
    /// 避免撞上「自动停录后 isRecording=false」的收尾死角。【待调】
    static let turnCapSeconds: TimeInterval = 58.0
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

    /// ESS-600：当前**被认领**的回合 request_id。所有回合事件都必须携带
    /// request_id 并与它相等才被受理——这是「旧 request / 旧 generation 的
    /// 迟到音频不得进入下一轮」在会话层的闸门。上一轮的迟到 `.ended` 到达时
    /// 这里已经换成新 id，事件被丢弃并留证（`session_stale_turn_event`）。
    private(set) var activeTurnRequestId: String?
    /// ESS-600：会话内回合序号，从 1 开始严格递增。conversation 级的
    /// `conversation_id` / `turn_id` 真相在 `RealtimeMediaSession.ConversationHandle`
    /// （唯一铸造点），本序号只是会话层日志的可读游标，不另铸 id。
    private(set) var turnIndex = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 进入

    /// 点球进入实时对话。只在 idle 受理；重复点/会话中点球一律忽略
    /// （会话中点球在 Wave 1 无语义，F4 的手动打断降级在后续 Wave 决定）。
    func enterSession() {
        guard state == .idle else { return }
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
        turnPhase = .listening
        WatchLog.info(
            "session", "session_next_listening", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) reason=channel_ready"
        )
        armTurnCap()
    }

    /// 单轮上限兜底：到点视同说完提交本轮，不让「聆听」悬在
    /// 已停录的死麦克风上（VAD 断句是常态路径，本条只是上限）。
    private func armTurnCap() {
        turnCapToken?.cancel()
        turnCapToken = scheduleDelay(Self.turnCapSeconds) { [weak self] in
            guard let self, self.state == .listening, self.turnPhase == .listening else { return }
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
        guard state == .listening else { return false }
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
    func markTurnCommitted(requestId: String) {
        guard acceptsTurnEvent(requestId, event: "turn_committed") else { return }
        guard turnPhase == .listening else { return }
        turnCapToken?.cancel(); turnCapToken = nil
        turnPhase = .thinking
        WatchLog.info(
            "session", "session_turn_committed", requestId: requestId,
            detail: "turn_index=\(turnIndex) phase=thinking"
        )
        // 有界执行：回答永不到达时不许无限等。
        thinkingToken?.cancel()
        thinkingToken = scheduleDelay(Self.thinkingTimeoutSeconds) { [weak self] in
            guard let self, self.state == .listening, self.turnPhase == .thinking else { return }
            WatchLog.error(
                "session", "session_thinking_timeout", requestId: self.activeTurnRequestId,
                detail: "turn_index=\(self.turnIndex) timeout_s=\(Int(Self.thinkingTimeoutSeconds))",
                code: "ERR_SESSION_ANSWER_TIMEOUT"
            )
            self.presentFailureNotice("没等到回答，再说一次试试")
            self.startNextTurn(reason: "thinking_timeout")
        }
    }

    /// 回答音频**真实起播**（realtime 首帧已渲染 / SpeechPlayer 起播成功）。
    /// thinking → speaking。收到 delta、入队、落盘都不算起播。
    func markAnswerStarted(requestId: String) {
        guard acceptsTurnEvent(requestId, event: "answer_started") else { return }
        guard turnPhase == .thinking else { return }
        thinkingToken?.cancel(); thinkingToken = nil
        turnPhase = .speaking
        WatchLog.info(
            "session", "session_answer_started", requestId: requestId,
            detail: "turn_index=\(turnIndex) phase=speaking"
        )
    }

    /// 回答**真实播完**。speaking → listening，并自动开下一轮采集。
    ///
    /// `success == false` 时同样回到聆听，但事件名与 reason 如实标注失败——
    /// 复审阻断 2 的口径：失败播放**不许**记成完成，但也不许把会话丢在
    /// 一个既不听也不说的死态里（那正是「每轮按一次」都不如的体验）。
    func markAnswerFinished(requestId: String, success: Bool = true, reason: String = "playback_finished") {
        guard acceptsTurnEvent(requestId, event: "answer_finished") else { return }
        guard turnPhase == .speaking || turnPhase == .thinking else { return }
        let fromPhase = turnPhase
        if success {
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
    /// 语音 barge-in（全双工）不在本阶段承诺——AEC 未在真机证明可行前
    /// 开语音打断等于伪装全双工，会把用户自己的回音当成新一轮输入。
    func interruptSpeaking() {
        guard state == .listening, turnPhase == .speaking else { return }
        WatchLog.info(
            "session", "session_speaking_interrupted", requestId: activeTurnRequestId,
            detail: "turn_index=\(turnIndex) source=orb_tap"
        )
        onInterruptSpeaking?()
        startNextTurn(reason: "user_interrupt")
    }

    /// 开启下一轮采集。`onStartTurn` 返回新一轮的 request_id——从这一刻起
    /// 旧 id 的任何事件都会被 `acceptsTurnEvent` 挡在门外。
    private func startNextTurn(reason: String) {
        guard state == .listening else { return }
        relistenToken?.cancel(); relistenToken = nil
        thinkingToken?.cancel(); thinkingToken = nil
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
        WatchLog.info(
            "session", "session_next_listening", requestId: requestId,
            detail: "turn_index=\(turnIndex) reason=\(reason)"
        )
        if Self.hapticOnAutoRelisten { playHaptic(.ready) }
        armTurnCap()
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
        state = .idle
        turnPhase = .idle
        activeTurnRequestId = nil
        turnIndex = 0
        isCapturingLocally = false
        enteredAt = nil
        WatchLog.info(
            "session", "session_channel_failed",
            detail: "reason=\(failure.logReason) from=\(failedFrom.logName)"
        )
        switch failure {
        case .recorderStart:
            // 分身错误卡片 + .failure 触觉已由 PushToTalkController 的
            // 既有错误链呈现（ESS-180），本控制器只负责把会话态收回 idle，
            // 不叠加第二份文案与第二次震动。
            break
        case .channelEvent:
            playHaptic(.failure)
            presentFailureNotice(Self.failureCopy(forState: failedFrom))
        }
        // 通道死了，采集侧必须同步收口（建立期失败时 pressBegan 的
        // 错误链已自行清理，endSessionChannel 幂等）。
        onTeardownChannel?()
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

    /// 点 X 或下滑退出会话。任意会话态可触发；拆链完成后回 idle。
    /// 「点 X 必须真正释放麦克风」由 onTeardownChannel 接到
    /// `endSessionChannel()` 兑现（采集停 + 未提交实时回合取消 +
    /// 会话级 AVAudioSession deactivate，≤300ms 口径见
    /// `conversation_audio_released` 的 duration_ms）。
    func exitSession() {
        guard isInSession else { return }
        WatchLog.info("session", "session_exit_requested", detail: "source=user")
        playHaptic(.exit)
        teardownToIdle()
    }

    private func teardownToIdle() {
        cancelConnectingTimers()
        cancelTurnTimers()
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

    private func cancelTurnTimers() {
        turnCapToken?.cancel(); turnCapToken = nil
        thinkingToken?.cancel(); thinkingToken = nil
        relistenToken?.cancel(); relistenToken = nil
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

    /// 文案纪律（PRD 异常链 A/B）：说清「怎么办」，不出现错误码。
    /// 建立中失败 → 引导用户检查 iPhone；会话中断开 → 告知本轮已结束。
    static func failureCopy(forState state: State) -> String {
        switch state {
        case .connecting:
            return "连不上，检查一下 iPhone 是否在身边"
        case .listening, .disconnecting, .idle:
            return "连接断了，本轮对话已结束"
        }
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

    /// 「点一下进会话」与「按住说话」的时长分界（PRD F1）：松手时
    /// 按住不足该时长记为「点」——转会话常驻监听；达到则走 PTT 提交。
    /// 0.35s【待调】：小于典型「按住说一个字」的最短按住，大于快速点按。
    static let tapToEnterMaxHoldSeconds: TimeInterval = 0.35

    static func isTapToEnter(holdSeconds: TimeInterval) -> Bool {
        holdSeconds < tapToEnterMaxHoldSeconds
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
            // 先开 conversation 边界再起第一轮，让第 1 轮的 turn_id 就落在
            // 这段 conversation 里。pressBegan 幂等——点球 touch-down 已经
            // 开录时返回的是**在飞那一轮**的 request_id，不重复发起。
            pushToTalk?.beginSessionConversation()
            return pushToTalk?.pressBegan()
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
        session.onInterruptSpeaking = { [weak pushToTalk] in
            pushToTalk?.interruptAnswerPlayback()
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
        pushToTalk.onSessionTurnAborted = { [weak session] requestId, reason in
            session?.markTurnAborted(requestId: requestId, reason: reason)
        }
        pushToTalk.onLocalCaptureChanged = { [weak session] active in
            session?.markLocalCapture(active: active)
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
        case .disconnecting: return "disconnecting"
        }
    }
}
