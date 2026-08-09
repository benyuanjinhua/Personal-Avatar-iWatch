import AVFoundation
import Foundation

/// ESS-554：实时录/放组件的会话与引擎生命周期归谁所有。
enum RealtimeAudioLifecycleOwner {
    /// 旧路径（ESS-554 之前）：每个回合各自 configure/activate/deactivate
    /// 共享会话、按回合起停引擎——连续 N 轮放大成 2N 次会话翻转，
    /// 正是 ESS-532 / ESS-535 的事故面。
    case turn
    /// ESS-554：`ConversationAudioController` 在整个 conversation 内持有
    /// `.playAndRecord` 激活态与两个引擎；回合内只剩 tap 装卸与
    /// playerNode play/stop，零会话翻转、零回合级引擎重启。
    case conversation
}

/// 窄化 AVAudioSession 接缝：验收口径「连续 5 轮 = 1 次激活 + 1 次去激活」
/// 必须能确定性计数真实会话调用，而不是靠日志 scraping（R-02.1）。
protocol ConversationAudioSessionDriving: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: ConversationAudioSessionDriving {}

/// 窄化引擎接缝：hosted CI 无音频硬件，真实 `AVAudioEngine.start()` 属于
/// ESS-498 hang 家族，单测用 fake 注入；生产默认转发到真实引擎。
protocol ConversationAudioEngineControlling: AnyObject {
    var isRunning: Bool { get }
    func prepare()
    func start() throws
    func stop()
}

extension AVAudioEngine: ConversationAudioEngineControlling {}

/// ESS-554 (Phase 0 / A2)：conversation 生命周期内**独占**共享
/// `AVAudioSession`（`.playAndRecord` 全程激活）与两个实时
/// `AVAudioEngine`（采集 / 播放）的生命周期。
///
/// 为什么存在（ESS-547 C1 证据）：Watch 上 `PCMFrameRecorder` 与
/// `RealtimePlaybackEngine` 各持一个 `AVAudioEngine`，`AVAudioSession`
/// 类别按回合在 `.playAndRecord ↔ .playback` 间翻转，
/// `RealtimePlaybackAudioSessionGate` 是回合级（`stop()` 即 reset）。
/// 连续多轮把每轮 2 次切换放大成 2N 次，正面撞上 ESS-532（录音
/// deactivate 后引擎静音）/ ESS-535（引擎需 stop/start 重挂会话）/
/// `Shared/AudioSessionPolicy.swift` 记录的 -50 paramErr 与 88s 无声事故。
///
/// 本控制器的契约：
/// 1. `beginConversation` 一次性配好 `.playAndRecord` 并激活，随后把
///    播放引擎 stop→prepare→start 重挂到新会话（ESS-535 的重启逻辑保留，
///    但从「每轮首帧」提到「会话级一次性」；采集引擎的首次启动延迟到
///    首个经过输入格式防御门的回合，见 restartEngines 注释）。
/// 2. 回合之间只停 tap / playerNode —— 不 deactivate 会话、不起停引擎
///    （由 `RealtimeAudioLifecycleOwner.conversation` 模式下的
///    PCMFrameRecorder / RealtimePlaybackEngine 兑现）。
/// 3. `endConversation`（点 X / 显式退出，PD-2）真正 deactivate 会话；
///    「≤300ms 麦克风释放」按 **session deactivate 完成** 计，不按 tap
///    停止计——`conversation_audio_released` 的 `duration_ms` 即该口径。
/// 4. PD-2 产品口径：`.playAndRecord` 激活 ≠ 正在采集。AI 回答期间会话
///    仍激活但 tap 已停，球的「回答态」即「此刻没在听你」的信号；只有
///    点 X 之后仍不 deactivate 才构成隐私承诺违背。
///
/// 结构化日志（module=`conversation_audio`，均含 conversation_id 与
/// duration_ms）：`conversation_audio_acquired` /
/// `conversation_audio_released` / `engine_restarted`。
@MainActor
final class ConversationAudioController {
    enum ReleaseReason: String {
        /// 点 X / 取消等用户显式退出（Phase 0 由 cancelActiveTurn /
        /// pressCancelled 承担；ESS-556 的 X 按钮直接调 endConversation）。
        case userExit = "user_exit"
        /// 系统中断（来电 / Siri 等）抢走会话，系统侧已 deactivate。
        case interrupted = "interrupted"
        /// media services reset —— 会话在我们脚下被系统拆掉。
        case mediaReset = "media_reset"
        /// 录音启动失败。会话级持有期间 AVAudioRecorder 不再自配会话，
        /// 启动失败说明持有的会话可能已被系统在挂起期间拆掉（中断通知
        /// 按 Apple 口径不保证投递）——释放陈旧会话，下次按压重新 acquire。
        case startFailed = "start_failed"
    }

    static let module = "conversation_audio"

    private let session: any ConversationAudioSessionDriving
    private let captureControl: any ConversationAudioEngineControlling
    private let playbackControl: any ConversationAudioEngineControlling

    /// 会话级持有的两个引擎。构造 adapter 时注入 PCMFrameRecorder /
    /// RealtimePlaybackEngine；`.conversation` 模式下它们的回合级代码
    /// 不再起停这两个引擎。采集引擎的**首次**启动由 PCMFrameRecorder
    /// 的输入格式防御门后完成（见 restartEngines 注释），此后跨回合
    /// 保持运行，直到 endConversation 统一停止。
    let captureEngine = AVAudioEngine()
    let playbackEngine = AVAudioEngine()

    private(set) var conversationId: String?
    private(set) var isAcquired = false
    private var acquiredAt: DispatchTime?

    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    init(
        session: any ConversationAudioSessionDriving = AVAudioSession.sharedInstance(),
        captureControl: (any ConversationAudioEngineControlling)? = nil,
        playbackControl: (any ConversationAudioEngineControlling)? = nil
    ) {
        self.session = session
        self.captureControl = captureControl ?? captureEngine
        self.playbackControl = playbackControl ?? playbackEngine

        // 系统在我们持有期间把会话拆掉（中断 / media reset）时，必须立刻
        // 按 released 收口并把状态打回 idle——否则下一轮回合会拿着一个
        // 已失效的会话静默无声。App 挂起期间发生的中断，按 Apple 文档在
        // 恢复时补投 began，本观察者同样能兜住「挂起被拆」的情形。
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let kind = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                guard let self, kind == .began, self.isAcquired else { return }
                WatchLog.info(
                    Self.module, "conversation_audio_interrupted",
                    detail: "conversation_id=\(self.conversationId ?? "-")"
                )
                self.endConversation(reason: .interrupted)
            }
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAcquired else { return }
                self.endConversation(reason: .mediaReset)
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let mediaResetObserver {
            NotificationCenter.default.removeObserver(mediaResetObserver)
        }
    }

    // MARK: - 会话级获取

    /// 进入 conversation：配好 `.playAndRecord` 并激活（整个会话仅这一次），
    /// 随后把两个引擎重挂到新会话。同一会话内幂等；失败抛错、保持 idle，
    /// 调用方（PushToTalkController）据此回落到回合级旧路径。
    func beginConversation(conversationId: String) throws {
        guard !isAcquired else { return }
        let started = DispatchTime.now()

        // ESS-61 同款阶梯：会话开始前 SpeechPlayer（欢迎语/错误语音）可能
        // 留下粘性 .longFormAudio 路由策略，不显式复位直接 setCategory 会
        // 抛 -50 paramErr。沿用 Shared/AudioSessionPolicy 的
        // resetRoutePolicy → minimal 两级尝试。
        var attempt = AudioSessionPolicy.nextRecordingAttempt(after: nil)
        var lastError: Error?
        var configured = false
        while let current = attempt {
            do {
                try configureSession(attempt: current)
                configured = true
                break
            } catch {
                lastError = error
                WatchLog.error(
                    Self.module, "conversation_audio_acquire_failed",
                    detail: "conversation_id=\(conversationId) attempt=\(current)",
                    error: error
                )
                attempt = AudioSessionPolicy.nextRecordingAttempt(after: current)
            }
        }
        guard configured else {
            throw lastError ?? RecorderError.sessionActivationFailed
        }

        // ESS-535 会话级重启：引擎若带着旧会话的 I/O 状态，stop→start
        // 才会重挂到新激活的会话；幂等（未运行则直接 prepare+start）。
        try restartEngines(conversationId: conversationId, trigger: "acquire")

        self.conversationId = conversationId
        self.acquiredAt = started
        isAcquired = true
        WatchLog.info(
            Self.module, "conversation_audio_acquired",
            detail: "conversation_id=\(conversationId) "
                + "duration_ms=\(Self.elapsedMs(since: started))"
        )
    }

    // MARK: - 会话级释放（点 X / PD-2）

    /// 退出 conversation：停两个引擎并**真正 deactivate** 会话。
    /// PD-2 验收口径：「≤300ms 麦克风释放」按 session deactivate 完成计
    /// （本函数同步执行，`duration_ms` 即点击 → deactivate 完成的延迟），
    /// 不按 tap 停止计。幂等：未持有时调用为空操作。
    func endConversation(reason: ReleaseReason) {
        guard isAcquired, let conversationId else { return }
        let started = DispatchTime.now()

        captureControl.stop()
        playbackControl.stop()

        var deactivated = true
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // 中断/reset 路径下系统已收走会话，setActive(false) 可能抛错——
            // 吞掉但必须在 released 事件里落 deactivated=false（R-02 对账）。
            deactivated = false
            WatchLog.error(
                Self.module, "conversation_audio_release_failed",
                detail: "conversation_id=\(conversationId) reason=\(reason.rawValue)",
                code: "ERR_AUDIO_SESSION", error: error
            )
        }

        let heldMs = acquiredAt.map { Self.elapsedMs(since: $0) } ?? 0
        isAcquired = false
        self.conversationId = nil
        acquiredAt = nil
        WatchLog.info(
            Self.module, "conversation_audio_released",
            detail: "conversation_id=\(conversationId) "
                + "duration_ms=\(Self.elapsedMs(since: started)) "
                + "held_ms=\(heldMs) reason=\(reason.rawValue) deactivated=\(deactivated)"
        )
    }

    // MARK: - 内部

    /// ESS-535 的引擎重启逻辑，会话级触发：播放引擎 stop(若运行)→prepare
    /// →start，保证 I/O 单元挂到当前激活的会话上。
    ///
    /// 采集引擎**不在此启动**：无输入设备的环境（headless / 部分模拟器）
    /// 里 start 一台带 inputNode 的引擎会抛不可捕获的 ObjC 异常杀进程
    /// （ESS-362/ESS-488 同族，本单在 watchOS 26.5 模拟器复现：
    /// `AVAudioEngineGraph Initialize: (inputNode != nullptr ||
    /// outputNode != nullptr)`）。唯一安全的采集启动路径是
    /// PCMFrameRecorder.start() 里 inputFormatValidationError 门后的那次——
    /// 会话级模式下它只在引擎未跑时启动一次、跨回合保持（「回合间只停
    /// tap」不变），本控制器仍在 endConversation 统一停两台引擎。
    private func restartEngines(conversationId: String, trigger: String) throws {
        let started = DispatchTime.now()
        if playbackControl.isRunning { playbackControl.stop() }
        playbackControl.prepare()
        try playbackControl.start()
        WatchLog.info(
            Self.module, "engine_restarted",
            detail: "conversation_id=\(conversationId) "
                + "duration_ms=\(Self.elapsedMs(since: started)) "
                + "scope=playback trigger=\(trigger)"
        )
    }

    /// ESS-650：语音打断功能启用时使用 `.voiceChat` 替代 `.spokenAudio`。
    /// `.voiceChat` 提供 AEC（声学回声消除），是语音打断得以实现的硬件前提——
    /// 没有 AEC 时扬声器播放的回答音频会被麦克风拾取并误判为用户语音。
    /// 但 `.voiceChat` 会改变路由、增益、播放音量与录音质量，必须经 R-02.2
    /// 双向与并发冒烟验证。门禁：F2-1 真机 `setActive` 成功且自身回声能量
    /// 相对 `.spokenAudio` 记录实测 dB 降低量。
    var voiceBargeInEnabled: Bool = false

    /// 与 `AudioRecorder.configureSession` 同源的 ESS-61 配置序列：
    /// 先 setActive(false, .notifyOthersOnDeactivation) 清掉播放侧残留的
    /// 激活态，再用带 policy 参数的重载显式声明 .default 复位粘性
    /// .longFormAudio；minimal 回落去掉 mode/options 只留最简
    /// .playAndRecord。这条阶梯在真机上验证过（ESS-61/ESS-72），不要简化。
    ///
    /// ESS-650：voiceBargeInEnabled 为 true 时第一级阶梯使用 `.voiceChat`
    /// 而非 `.spokenAudio`——这是 AEC 生效的唯一路径。回落阶梯保持不变。
    private func configureSession(attempt: AudioSessionPolicy.RecordingAttempt) throws {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        switch attempt {
        case .resetRoutePolicy:
            let mode: AVAudioSession.Mode = voiceBargeInEnabled ? .voiceChat : .spokenAudio
            if #available(watchOS 11.0, *) {
                try session.setCategory(
                    .playAndRecord, mode: mode, policy: .default,
                    options: [.allowBluetooth]
                )
            } else {
                try session.setCategory(
                    .playAndRecord, mode: mode, policy: .default, options: []
                )
            }
        case .minimal:
            try session.setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
        }
        try session.setActive(true, options: [])
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        Int(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}
