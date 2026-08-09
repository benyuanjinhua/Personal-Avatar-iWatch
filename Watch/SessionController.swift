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
    /// 存续**是本级真相；回合进行到哪一步由视图层投影（见文件头注释）。
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case disconnecting
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

    /// 进入会话时发起通道：生产接 `PushToTalkController.beginSessionChannel()`
    /// （与 PTT 同一录音/实时上行链；`.start` 触觉在该链内部兑现）。
    var onBeginChannel: (() -> Void)?
    /// 退出会话时拆链：生产接 `PushToTalkController.endSessionChannel()`
    /// （停采集、取消未提交实时回合、取消进行中回合、deactivate 会话级音频）。
    var onTeardownChannel: (() -> Void)?
    /// 单轮时长到上限：生产接 `PushToTalkController.endSessionTurn()`
    /// （视同松手提交本轮；PRD F2 的 60s 单轮上限，VAD 自动断句在后续 Wave 接管）。
    var onCommitTurn: (() -> Void)?

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
    /// 首次引导的 UserDefaults 键。
    static let firstRunGuideShownKey = "ess573_first_run_guide_shown_v1"

    private let defaults: UserDefaults
    private var enteredAt: Date?
    private var dotsToken: SessionDelayToken?
    private var timeoutToken: SessionDelayToken?
    private var noticeToken: SessionDelayToken?
    private var guideToken: SessionDelayToken?
    private var turnCapToken: SessionDelayToken?

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
            self.markChannelFailed(.channelEvent)
        }
        // 注意：不在此处同步宣告 ready。`onBeginChannel` 只是发起——
        // listening 只能由 markChannelReady（首个真实 uplink ack）进入。
        onBeginChannel?()
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
        // 单轮上限兜底：VAD（F2）落地前，到点视同说完提交本轮，
        // 不让「聆听」悬在已停录的死麦克风上。
        turnCapToken = scheduleDelay(Self.turnCapSeconds) { [weak self] in
            guard let self, self.state == .listening else { return }
            WatchLog.info("session", "session_turn_cap_reached",
                          detail: "cap_s=\(Int(Self.turnCapSeconds))")
            self.onCommitTurn?()
        }
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
        turnCapToken?.cancel(); turnCapToken = nil
        state = .idle
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
        turnCapToken?.cancel(); turnCapToken = nil
        state = .disconnecting
        onTeardownChannel?()
        state = .idle
        enteredAt = nil
        WatchLog.info("session", "session_ended", detail: "mic_released=true")
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
