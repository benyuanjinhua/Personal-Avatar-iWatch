import Combine
import Foundation
import os
import WatchKit

/// 按住说话（ESS-22/ESS-29）：按下开始录音（最长 60 秒），松开生成
/// UUIDv7 request_id + 版本化信封，交给 WatchVoiceTransport 发送。
/// 半双工：录完即传，没有持续 PCM 流；回合状态由 VoiceTurnJournal 持久化，
/// 退出页面任务继续、重开可恢复。
@MainActor
final class PushToTalkController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?

    /// 录音链路的系统错误只进日志；UI 始终显示中文可行动文案。
    static func recordingErrorDescription(_ error: Error) -> String {
        if let recorderError = error as? RecorderError,
           let description = recorderError.errorDescription {
            return description
        }
        return RecorderError.sessionActivationFailed.errorDescription
            ?? "录音启动失败，请松开后再按住重试。"
    }
    @Published private(set) var recordingLevel: Float = 0
    /// 当前字幕播放会话（ESS-48）：结果播放/纯文本结果到达时置值，
    /// UI 以 sheet(item:) 呈现；用户关闭视图时由绑定置回 nil。
    /// ESS-55 未读机制：用户关闭全文视图（非会话替换）视为「已读」——
    /// 只有用户主动 dismiss 才可靠地证明看过，结果到达本身不算。
    @Published var subtitleSession: SubtitleSession? {
        didSet {
            guard let closed = oldValue, subtitleSession == nil else { return }
            if journal.turn(withId: closed.requestId)?.currentState == .completed {
                journal.markResultViewed(requestId: closed.requestId)
            }
        }
    }
    /// ESS-58：播放被截断（锁屏挂起/解码失败）的回合。语音留在加密仓、
    /// 不发交付 ACK，结果卡片显式标出「未播完」并保留重播入口——中断
    /// 只允许可见，不允许静默。
    @Published private(set) var unfinishedPlaybackIds: Set<String> = []

    let journal: VoiceTurnJournal
    let speechVault: EncryptedAudioVault?
    let player = SpeechPlayer(instanceTag: "ptt")
    /// ESS-180：错误语音专用播放器，与结果语音 `player` 隔离。
    /// 失败到达时结果语音（如果之前有）不能被覆盖，反过来结果语音在播时
    /// 收到失败也不能压过来；两个播放器各自持有各自的 AVAudioPlayer，会话
    /// 抢占由 SpeechPlayer 内部的 generation 兜住，比"用同一个 player.play"
    /// 更能保住彼此的完整性。
    let errorSpeech = SpeechPlayer(instanceTag: "error_speech")
    let transport: WatchVoiceTransport
    /// ESS-55 超长任务本地通知（JIT 授权 / 结果通知 / 兜底预约 / 点通知直达）。
    let notifier: ResultNotifier
    /// ESS-45：录音 → 等待 → 播放整个回合期间持有 ExtendedRuntimeSession，
    /// 降腕/熄屏不挂起；空闲即释放。
    let sessionKeeper = VoiceSessionKeeper()
    /// ESS-519：后台音频保活器——录音结束后立即播放静音音频保持进程在后台
    /// 存活，解决 WKExtendedRuntimeSession 被 .resignedFrontmost 收回后
    /// 进程挂起导致结果音频无法播放的问题。
    let breather = BackgroundAudioBreather()
    /// ESS-587：保留可断言的提交接线，不让 breather 本体单测掩盖调用方被删。
    var startBreatherAfterSubmit: (() -> Void)?
    /// ESS-180：屏幕分身错误卡片状态机；订阅 `errorPresenter.active` 即得 UI。
    let errorPresenter = AvatarErrorPresenter()

    /// ESS-522：本地兜底确认计时器，专用播放器与结果/错误隔离。
    let confirmPlayer = SpeechPlayer(instanceTag: "confirm")
    private(set) var confirmTimer: VoiceConfirmTimer?

    /// 结果语音自动播放即将开始（App 层用来打断欢迎语）。
    var onAutoPlayStarted: (() -> Void)?
    /// ESS-535: 用户按住说话时立即触发，用于打断欢迎语音释放音频会话。
    var onPressBegan: (() -> Void)?
    /// ESS-573: 实时通道**真实就绪**——首个被对端（iPhone WSS 实际发出后
    /// 回发）接受的 uplink ack 到达。SessionController 据此把 connecting
    /// 推进到 listening；绝不在 pressBegan 后同步宣告 ready（复审硬约束）。
    var onRealtimeChannelReady: (() -> Void)?
    /// ESS-573: 实时通道**真实失败**——录音启动失败 / 上行发送失败
    /// （WCSession 不可达或 sendMessage 报错）/ 适配器单发回退。
    /// 仅 SessionController 在会话中消费；PTT 自身错误链不变。
    var onRealtimeChannelFailed: ((SessionController.ChannelFailure) -> Void)?

    // MARK: - ESS-600 会话回合事件（全部携带 request_id，会话层据此闸门）

    /// 本轮上行**真正提交**（realtime commit 或完整文件二选一，`submit` 走完）。
    var onSessionTurnCommitted: ((_ requestId: String) -> Void)?
    /// 回答音频**真实起播**。两条播放路径各自在真实起播点回调：
    /// realtime = 首帧已渲染；完整文件 = `SpeechPlayer.play()` 返回 true。
    var onSessionAnswerStarted: ((_ requestId: String) -> Void)?
    /// 回答音频**真实播完**。`success=false` 表示播放以失败终局收场
    /// （exhausted / playRejected / deferredTimeout…），绝不记成播完。
    var onSessionAnswerFinished: ((_ requestId: String, _ success: Bool, _ reason: String) -> Void)?
    /// ESS-600 复审阻断 B：完整文件路径的 **interim** 语音播完（回合尚未达终态，
    /// 最终回答还在路上）。它不是本轮答完，不得开下一轮——会话据此回到等待态
    /// 并重新武装有界超时。
    var onSessionAnswerInterim: ((_ requestId: String) -> Void)?
    /// 本轮**零提交**收场（太短 / 收尾抛错）——没有回答可等，会话需重开采集。
    var onSessionTurnAborted: ((_ requestId: String, _ reason: String) -> Void)?
    /// 本地采集起停（与网络 ready 独立呈现）。
    var onLocalCaptureChanged: ((_ active: Bool) -> Void)?

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "PlaybackTrigger")
    private let recorder = AudioRecorder()
    var voiceStreamingEnabled: () -> Bool = { VoiceStreamingGate.defaultEnabled }
/// ESS-383: the single request_id for this turn, shared between the streaming
    /// uplink and the complete-file fallback. Generated once in `pressBegan()`,
    /// consumed by `submit()`. Never cleared mid-recording — even after a streaming
    /// abort, `submit()` must reuse it so the Bridge sees the same `request_id`
    /// on both paths and can associate the streaming frames with the fallback upload.
    private var streamRequestId: UUID?
    private var streamId: UUID?
    private var streamSequence = 0
    /// ESS-383: set when the streaming path aborted before `submit()` could consume
    /// `streamRequestId`. When true, `submit()` still uses `streamRequestId` but
    /// routes through the complete-file path instead of `adapter.commit()`.
    private var streamAborted = false
    /// ESS-321 real-time adapter. Lazily created on first press when the
    /// streaming gate is on. Wiring lives in `ensureRealtimeAdapter()`.
    private(set) var realtimeAdapter: WatchRealtimeMediaAdapter?
    /// ESS-642：会话边界闸门。`pressBegan` 真正新起一轮时置真，
    /// `endSessionConversation`（退出会话）与开新 conversation 时置假。
    /// `beginSessionConversation` 只在它为真时才允许复用在飞回合——
    /// 上一会话遗留的 activeTurn 因此永远进不了复用分支。
    private(set) var didStartTurnSinceConversationBoundary = false

    /// ESS-509: true when the realtime adapter owns an active turn (from
    /// `beginTurn` through `turnFinished`). Drives WCSession keep-alive by
    /// keeping the VoiceSessionKeeper's runtime session alive while the Watch
    /// waits for audio.delta or plays realtime audio — the SpeechPlayer's
    /// `isPlaying` alone cannot cover this window because it only fires for
    /// m4a playback, not PCM streaming.
    /// ESS-554 rebase 注：本属性来自 e725654（ESS-509），与分支的
    /// realtimePlaybackPending（ESS-532）机制并存，双路保活。
    @Published private(set) var isRealtimeStreaming = false
    /// ESS-554：会话级音频所有权开关（编译期默认 ON；关闭即回退到今天
    /// main 的回合级 RealtimePlaybackAudioSessionGate 路径）。读点在
    /// `ensureRealtimeAdapter()` / 首次流式回合的 acquire，与
    /// `voiceStreamingEnabled` 同为可注入缝，测试/灰度可覆盖。
    var conversationAudioEnabled: () -> Bool = { ConversationAudioGate.defaultEnabled }
    /// ESS-554：会话级音频控制器。懒创建于首个流式回合（或 adapter 预
    /// 热）；conversation 期间独占 `.playAndRecord` 与两个实时引擎。
    private(set) var conversationAudioController: ConversationAudioController?
    /// ESS-603 test seam：会话级控制器的构造缝。生产恒为真实控制器；
    /// 测试注入 fake session/engine 后才能在 CI（无音频硬件）里断言
    /// 「gate ON 持有期间 breather 不启动」这条契约。
    var makeConversationAudioController: () -> ConversationAudioController = {
        ConversationAudioController()
    }
    private var pendingRealtimeRecording: [String: AudioRecorder.Recording] = [:]
    /// ESS-331: fast-channel failures can arrive while the m4a is still being
    /// recorded (i.e. before `finishRecording()`). When that happens we keep
    /// the fallback intent here and honour it in `submit(recording:)` — the
    /// adapter's single-shot flag already prevents re-entry, so this map
    /// tracks the "already promised, still owed" outstanding fallbacks.
    private var pendingFallbackReason: [String: RealtimeUplinkStream.FallbackReason] = [:]
    /// A release can arrive while AVAudioRecorder is still being prepared. Keep
    /// it pending and finish only after record() has actually succeeded.
    private var releaseRequestedWhileStarting = false
    /// ESS-55：一键重试用的最近一条录音（失败重发不用重新说话）。
    private let retryStore: RetryRecordingStore
    /// ESS-60：跨 WS 重连和 App 重启的自动播放去重账本。
    private let playbackLedger: ResultPlaybackLedger
    /// ESS-55：远端状态 → 触觉 cue 的映射与去重。
    private var cuePolicy = VoiceCuePolicy()
    /// ESS-317：再次对话待用上下文。pressBegan 时消费，submit 后清空。
    /// nil = 普通新请求，非 nil = 带上下文的再次对话请求。
    private var pendingReChatContext: (parentRequestId: String, contextSummary: String)?
    /// ESS-317：①屏球体旁「续：<摘要>」的展示文本。nil = 普通模式。
    @Published private(set) var reChatContextText: String?
    /// ESS-532: true from uplink commit until the first playback render event
    /// or fallback. Keeps the ExtendedRuntimeSession alive so the audio engine
    /// stays hot while downlink deltas are in flight.
    @Published private(set) var realtimePlaybackPending = false

    /// ESS-573: 上行发送失败通知的观察者令牌（WCSession 不可达 / sendMessage
    /// 报错）。该通知此前**没有观察者**——发帖即丢；接入后成为会话模式
    /// 「通道建立失败/中途断开」的真实事件源之一。
    private var realtimeUplinkFailedObserver: NSObjectProtocol?

    /// ESS-522：主屏封锁起点（ASR final / accepted 时刻），用于计算 main_screen_blocked_ms。
    private var mainScreenBlockedAt: Date?
    /// ESS-522：进度事件是否发生过——任何 progress spoken 计数。恒为 0 才合格。
    private(set) var progressSpokenCount = 0

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journal = VoiceTurnJournal(
            directory: base.appendingPathComponent("VoiceTurns", isDirectory: true),
            onStorageFailure: { detail in
                WatchLog.error("journal", "persist_failed", detail: detail)
            }
        )
        // ESS-363：冷启动时清理超期活跃回合的观测日志（诊断上次是否异常退出）。
        journal.onStaleTurnsCleaned = { staleIds, phase in
            let holdReasons = staleIds.map { "turn_active:\($0)" }.joined(separator: ",")
            WatchLog.info(
                "lifecycle", "stale_turns_cleaned",
                detail: "count=\(staleIds.count) holds=[\(holdReasons)] scene_phase=\(phase)"
            )
        }
        speechVault = try? EncryptedAudioVault(directory: base.appendingPathComponent("SpeechVault", isDirectory: true))
        transport = WatchVoiceTransport(journal: journal)
        retryStore = RetryRecordingStore(
            directory: base.appendingPathComponent("RetryCache", isDirectory: true),
            onStorageFailure: { detail in
                WatchLog.error("retry_store", "persist_failed", detail: detail)
            }
        )
        playbackLedger = ResultPlaybackLedger(
            directory: base.appendingPathComponent("PlaybackLedger", isDirectory: true)
        )
        notifier = ResultNotifier(policy: ResultNotificationPolicy(
            directory: base.appendingPathComponent("NotificationLedger", isDirectory: true)
        ))

        // ESS-522：确认计时器——本地兜底语音在 1.5s 无后端确认时触发。
        let cfm = VoiceConfirmTimer(player: confirmPlayer)
        confirmTimer = cfm
        cfm.onConfirmComplete = { [weak self] requestId, outcome in
            self?.handleConfirmComplete(requestId: requestId, outcome: outcome)
        }

        recorder.$level
            .receive(on: RunLoop.main)
            .assign(to: &$recordingLevel)

        // ESS-573：上行发送失败（WCSession 未激活/不可达、sendMessage 报错）
        // 是「通道建立失败/中途断开」的真实事件。该通知此前无观察者（发帖
        // 即丢）；这里转发给 SessionController——只有会话中才会消费，PTT
        // 路径的完整文件回退行为不变。
        realtimeUplinkFailedObserver = NotificationCenter.default.addObserver(
            forName: WatchVoiceTransport.realtimeUplinkFailedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onRealtimeChannelFailed?(.channelEvent)
            }
        }

        // ESS-554：会话级持有期间 AudioRecorder 跳过每回合的会话 configure
        // 与 deactivate（PD-2：点 X 才真 deactivate，由 controller 兑现）。
        recorder.sessionManagedExternally = { [weak self] in
            self?.conversationAudioController?.isAcquired == true
        }

        // ESS-41 B3 深修：播放触发下沉到 speech attach 事件本身，按 request_id
        // 定向交付——不依赖该回合仍是 activeTurn、不依赖 UI 挂载、不依赖回合
        // 未被判失败（语音后到时这三个条件都可能已不成立，旧 onChange 触发
        // 会静默漏播）。
        journal.onSpeechAttached = { [weak self] requestId in
            // ESS-522：后台语音到了，取消本地兜底确认计时器。
            self?.confirmTimer?.cancel(reason: "speech_attached")
            self?.autoPlayResult(requestId: requestId)
        }

        // 纯文本降级（ESS-48）：没有语音可播，直接展示全文，不进播放态。
        journal.onResultWithoutSpeech = { [weak self] requestId in
            self?.presentTranscriptOnly(requestId: requestId)
        }
        journal.onResultAudioDegraded = { [weak self] requestId, code in
            guard let self else { return }
            self.presentTranscriptOnly(requestId: requestId)
            self.presentAvatarError(code: code, requestId: requestId)
        }

        // 触觉 cue（ESS-55）：挂在状态入账事件上而非 UI——熄屏/视图未挂载时
        // 结果到达/失败仍能靠震动感知（ESS-45 的 ExtendedRuntimeSession 保证
        // 回合期间 App 还在运行）。成功交付后清理重试缓存。
        // resultArrived 例外：是否播触觉取决于是否发本地通知（同一结果只震
        // 一次），而通知正文需要结果载荷——推迟到 onResultRecorded 决策。
        //
        // ESS-180：failed 时把稳定错误码交给 errorPresenter 走「语音 + 文字 + 触觉」——
        // turnFailed 触觉的落点从此处下沉到 presenter 内部，避免同一次失败震两下。
        journal.onStateApplied = { [weak self] requestId, state in
            guard let self else { return }
            // ESS-522 S-2：收到 accepted（后端已确认受理，ASR final 之后），
            // 启动 1.5 秒确认计时器。同时记录主屏封锁起点。
            if state == .accepted {
                self.mainScreenBlockedAt = Date()
                self.confirmTimer?.arm(requestId: requestId)
                self.setSpawnConfirmSpoken(requestId: requestId, value: false)
            }
            if state == .failed {
                let code = self.journal.turn(withId: requestId)?.errorCode
                self.presentAvatarError(code: code, requestId: requestId)
            } else if let cue = self.cuePolicy.cue(for: state, requestId: requestId),
                      cue != .resultArrived, cue != .turnFailed {
                WatchHaptics.play(cue, requestId: requestId)
            }
            switch state {
            case .backgroundAccepted:
                // 首次长任务场景：JIT 授权引导 / 已授权则预约兜底通知。
                self.notifier.longTaskAccepted(requestId: requestId)
            case .failed, .cancelled:
                self.notifier.cancelProvisional(requestId: requestId)
                // ESS-522：终态释放主屏封锁。
                self.releaseMainScreenBlock(requestId: requestId)
            default:
                break
            }
            if state == .completed || state == .cancelled {
                self.retryStore.clear(requestId: requestId)
                // ESS-522：终态释放主屏封锁（completed 路径）。
                if state == .completed {
                    self.releaseMainScreenBlock(requestId: requestId)
                }
            }
        }

        // 结果入账（含摘要，ESS-55 通知链路）：够格就发本地通知（自带震动），
        // 否则回落到 .notification 触觉——同一结果只震一次。
        journal.onResultRecorded = { [weak self] requestId in
            guard let self, let turn = self.journal.turn(withId: requestId) else { return }
            let notified = self.notifier.notifyResultIfEligible(turn: turn, completedAt: Date())
            if !notified {
                WatchHaptics.play(.resultArrived, requestId: requestId)
            }
        }

        // 点通知直达该条结果全文（不播额外触觉——通知本身已震过）。
        notifier.onOpenResult = { [weak self] requestId in
            self?.presentResult(requestId: requestId)
        }

        // ESS-154 T2 播放终局告知：播放失败（激活穷尽 / 中断截断 / 挂起
        // 超时 / 解码错误）走 PlaybackEndgamePolicy 决策——播触觉、发横幅
        // （横幅无视 T1 的 short_task/app_active，见 ResultNotifier 里的说明）。
        // 成功终局（.success）不追加任何动作，T1 已在结果入账时判过。
        player.onPlaybackEndgame = { [weak self] requestId, bytes, endgame in
            self?.handlePlaybackEndgame(requestId: requestId, bytes: bytes, endgame: endgame)
        }
        // ESS-180：错误语音（错误提示 fallback）不参与 result ACK 链路，只需要
        // 传 endgame 给 handler，其中 ACK gate 会因 bytes 小或不匹配 result 而跳过。
        errorSpeech.onPlaybackEndgame = { [weak self] requestId, bytes, endgame in
            self?.handlePlaybackEndgame(requestId: requestId, bytes: bytes, endgame: endgame)
        }

        sessionKeeper.bind(
            turns: journal.$turns.eraseToAnyPublisher(),
            // ESS-509: realtime 回合期间（含等 audio.delta 与 PCM 播放窗口）
            // 也算「播放中」，VoiceSessionKeeper 不放 ExtendedRuntimeSession。
            playing: Publishers.CombineLatest(player.$isPlaying, $isRealtimeStreaming)
                .map { $0 || $1 }
                .eraseToAnyPublisher(),
            recording: $state.map { $0 != .idle }.eraseToAnyPublisher(),
            realtimePending: $realtimePlaybackPending.eraseToAnyPublisher()
        )

        // ESS-317 历史对话留存：trim 时间监听清理 vault（必须在所有 stored property 初始化之后）。
        journal.onTurnEvicted = { [weak self] turn in
            if let fileName = turn.speechFileName {
                self?.speechVault?.remove(name: fileName)
                WatchLog.info("retention", "trim_evicted",
                              detail: "request_id=\(turn.requestId) file=\(fileName)")
            }
        }

        // ESS-317：冷启动时清理超过 24h 的过期轮次与音频。
        journal.evictExpiredAudio(vault: speechVault)

        // ESS-587：默认接线——提交后启动后台保活；测试可覆盖为计数闭包。
        startBreatherAfterSubmit = { [weak breather] in breather?.start() }

        // ESS-603：会话级 owner 在场时 breather 既不启动也不去激活。
        // 与上面 recorder.sessionManagedExternally 同一判据（isAcquired），
        // 保证「谁持有会话」在录音侧与保活侧不会各说各话。
        breather.isSessionOwnedExternally = { [weak self] in
            self?.conversationAudioController?.isAcquired == true
        }
    }

    /// 展示纯文本结果全文。录音期间不弹（打断按住说话手势），文字仍在结果卡片里可点开。
    private func presentTranscriptOnly(requestId: String) {
        guard state == .idle else { return }
        guard let turn = journal.turn(withId: requestId), let result = turn.result else { return }
        subtitleSession = SubtitleSession(
            requestId: requestId, text: result.displaySummary, hasAudio: false
        )
    }

    /// 结果卡片「查看全文」入口：正在播本回合语音则接入实时字幕，否则纯回看。
    func showTranscript(for turn: VoiceTurnRecord) {
        guard let result = turn.result else { return }
        subtitleSession = SubtitleSession(
            requestId: turn.requestId,
            text: result.displaySummary,
            hasAudio: player.progress(matching: turn.requestId) != nil
        )
    }

    /// 录音期间到达的结果语音先挂起，录音结束后补播（不静默丢弃）。
    private var pendingAutoPlayRequestIds: [String] = []
    /// ESS-541: durable result redelivery is admitted only for the latest
    /// request/generation. A new press clears all old queued ownership.
    private var resultPlaybackIsolation = ResultPlaybackIsolation()
    /// ESS-154 T2：同一 request_id 的同种失败终局只播一次触觉（防止
    /// 重复 finishPlayback 回调把用户震到关通知；横幅幂等在 ResultNotificationPolicy
    /// 侧按 request_id 一辈子记账，比这里更严——两层配合，不重复）。
    private var playbackEndgameHapticsSent: [String: Set<PlaybackEndgame>] = [:]

    /// ESS-154 T2 收口：把 SpeechPlayer 的播放终局映射为触觉 + 横幅动作。
    /// - 用 request_id 定位摘要文案，欢迎语等无 request_id 的终局只留取证。
    /// - 触觉走 PlaybackEndgamePolicy.outcome（.turnFailed）；同回合同终局
    ///   去重（本地 Set），跨终局仍会震（比如 halted 后用户重播又 exhausted）。
    /// - 横幅委托 ResultNotifier.notifyPlaybackFailureIfEligible，那里管
    ///   授权/幂等/T1 覆写。这里只出「要不要发」的意图。
    /// ESS-233: interim/fallback 音频固定 16837 bytes。真回复音频通常 > 100KB。
    /// 用 20_000 作为启发式阈值——低于此不触发 ACK，避免把 interim playback
    /// 当作 result 终态触发器，进而被 Bridge 拒 ERR_MISSING_FIELD。
    /// 长期方案是把 `SpeechPlaybackContext.source`（result_direct/result_background/welcome）
    /// 透传到回调，做语义级判断。
    private static let resultAckMinBytes = 20_000

    /// 播放终局映射到结果卡错误码。错误提示音使用 `error-<request_id>` 作为
    /// context；它自己的播放失败只留结构化日志，不能再次弹错误卡并递归播报。
    /// `.halted` 是可恢复的系统中断，继续由「未播完 · 重播」承担，不升级为错误。
    static func avatarErrorCode(requestId: String, endgame: PlaybackEndgame) -> String? {
        guard !requestId.hasPrefix("error-") else { return nil }
        switch endgame {
        case .exhausted, .resumeFailed:
            return "ERR_PLAYBACK_ACTIVATION"
        case .deferredTimeout:
            return "ERR_PLAYBACK_DEFERRED_TIMEOUT"
        case .playRejected:
            return "ERR_PLAY_RETURNED_FALSE"
        case .success, .halted:
            return nil
        }
    }

    private func handlePlaybackEndgame(requestId: String?, bytes: Int, endgame: PlaybackEndgame) {
        // ESS-171 + ESS-233: 播放成功且是真回复（非 interim/fallback）才触发 ACK。
        // interim（16.8KB fallback）尚未使 turn 达终态，ACK 会被 Bridge 拒
        // ERR_MISSING_FIELD 并导致 iPhone 无限重试。
        if endgame == .success, let requestId {
            if bytes >= Self.resultAckMinBytes {
                transport.sendResultAck(requestId: requestId)
                WatchLog.info(
                    "player", "result_ack_on_playback_success", requestId: requestId,
                    detail: "endgame=success bytes=\(bytes)"
                )
            } else {
                WatchLog.info(
                    "player", "result_ack_skipped_interim", requestId: requestId,
                    detail: "endgame=success bytes=\(bytes) threshold=\(Self.resultAckMinBytes)"
                )
            }
        }
        // ESS-600（复审阻断 2）：终局分流后再上报会话。`error-` 前缀是错误
        // 提示音，不是回答，绝不驱动回合相位。`.success` 之外的一切终局
        // （halted / exhausted / playRejected / deferredTimeout）都按失败上报——
        // 无差别上报「播完」会让一次失败的播放照样开启下一轮。
        if let requestId, !requestId.hasPrefix("error-") {
            if endgame == .success {
                // ESS-600 复审阻断 B：完整文件路径的 interim 与 final **共用同一个
                // request_id**。interim（回合尚未达终态的 16.8KB fallback）播完不是
                // 「这一轮答完了」——此时开下一轮，最终回答到达时会落在下一轮里，
                // 造成跨轮与顺序错乱。终态判定复用 ESS-45×ESS-46 的同一口径
                // （`turn.currentState.isTerminal`），不另立第二套真相。
                if journal.turn(withId: requestId)?.currentState.isTerminal == true {
                    onSessionAnswerFinished?(requestId, true, "endgame_success")
                } else {
                    WatchLog.info(
                        "player", "interim_playback_not_final", requestId: requestId,
                        detail: "endgame=success bytes=\(bytes) reason=turn_not_terminal"
                    )
                    // 回退到「等最终回答」而不是停在回答态：最终结果若永不到达，
                    // thinking 的有界超时会把会话捞回聆听；停在 speaking 会永久挂死。
                    onSessionAnswerInterim?(requestId)
                }
            } else {
                onSessionAnswerFinished?(requestId, false, "endgame_\(endgame.logToken)")
            }
        }
        guard let outcome = PlaybackEndgamePolicy.outcome(for: endgame) else { return }
        WatchLog.info(
            "player", "playback_endgame", requestId: requestId,
            detail: "endgame=\(endgame.logToken) reason=\(outcome.reasonLabel)"
        )
        var presentedError = false
        if let requestId {
            if let code = Self.avatarErrorCode(requestId: requestId, endgame: endgame) {
                presentTranscriptOnly(requestId: requestId)
                presentAvatarError(code: code, requestId: requestId)
                presentedError = true
            }
        }
        // E-13/E-14 的 presenter 已发一次失败触觉；其他终局仍沿用 T2 cue。
        if !presentedError, let cue = outcome.haptic,
           shouldPlayHaptic(requestId: requestId, endgame: endgame) {
            WatchHaptics.play(cue, requestId: requestId)
        }
        guard outcome.shouldNotifyBanner, let requestId else { return }
        let summary = journal.turn(withId: requestId)?.result?.displaySummary ?? ""
        notifier.notifyPlaybackFailureIfEligible(
            requestId: requestId, resultSummary: summary, reasonLabel: outcome.reasonLabel
        )
    }

    private func shouldPlayHaptic(requestId: String?, endgame: PlaybackEndgame) -> Bool {
        guard let requestId else { return true }
        var sent = playbackEndgameHapticsSent[requestId] ?? []
        guard !sent.contains(endgame) else { return false }
        sent.insert(endgame)
        playbackEndgameHapticsSent[requestId] = sent
        return true
    }

    private func enqueueAutoPlay(_ requestId: String, reason: String) {
        guard !pendingAutoPlayRequestIds.contains(requestId) else { return }
        pendingAutoPlayRequestIds.append(requestId)
        WatchLog.info(
            "player", "auto_play_queued", requestId: requestId,
            detail: "reason=\(reason) depth=\(pendingAutoPlayRequestIds.count)"
        )
    }

    /// ESS-180：触发一次屏幕分身错误呈现——查表 → 起播语音 → 触觉一次 →
    /// 卡片停留 5s；语音路径任一步失败自动降级到「文字 + 触觉」，绝不静音吞错。
    /// requestId 为 nil 表示本地失败（录音太短、启动失败），每次都是新一次呈现。
    func presentAvatarError(code: String?, requestId: String?) {
        errorPresenter.present(
            code: code,
            requestId: requestId,
            playAudio: { [weak self] data, ctx in
                guard let self else { return false }
                let context = ctx.map { "error-\($0)" } ?? "error-local"
                return self.errorSpeech.play(data: data, context: context, onFinish: nil)
            },
            playHaptic: { requestId in
                WatchHaptics.play(.turnFailed, requestId: requestId)
            }
        )
    }

    /// 结果语音落盘后的定向自动播放（ESS-41 B3）。
    /// ESS-182：dedup token 用 `speechFileName`（`<requestId>-<sha>.m4a`），
    /// 保证同一 request_id 的 interim / final 两段各自独立去重——旧实现按裸
    /// request_id 去重会让 final 被 interim 顶掉、静默丢弃。
    private func autoPlayResult(requestId: String) {
        guard case .accept = resultPlaybackIsolation.decide(requestId: requestId) else {
            logPlaybackIsolationDrop(incomingRequestId: requestId, source: "speech_attached")
            return
        }
        // ESS-539 v3: suppress SpeechPlayer auto-play for old M4A results
        // when realtime playback is pending or in progress. The SpeechPlayer
        // and RealtimePlaybackEngine compete for the shared AVAudioSession,
        // causing repeated interruptions and stuttering playback.
        guard !realtimePlaybackPending, realtimeAdapter?.currentTurn == nil else {
            WatchLog.info(
                "player", "auto_play_suppressed_realtime_active",
                requestId: requestId,
                detail: "realtime_pending=\(realtimePlaybackPending) adapter_turn=\(realtimeAdapter?.currentTurn?.requestId ?? "nil")"
            )
            return
        }
        guard state == .idle else {
            Self.logger.info("auto-play deferred: recording in progress (request_id=\(requestId, privacy: .public))")
            enqueueAutoPlay(requestId, reason: "recording")
            return
        }
        guard !player.isPlaying else {
            enqueueAutoPlay(requestId, reason: "player_busy")
            return
        }
        guard let turn = journal.turn(withId: requestId) else {
            Self.logger.error("auto-play failed: turn not found (request_id=\(requestId, privacy: .public))")
            return
        }
        guard let fileName = turn.speechFileName else {
            WatchLog.error(
                "player", "auto_play_missing_speech", requestId: requestId,
                code: "ERR_NO_SPEECH_FILE"
            )
            presentTranscriptOnly(requestId: requestId)
            presentAvatarError(code: "ERR_NO_SPEECH_FILE", requestId: requestId)
            return
        }
        guard playbackLedger.claim(token: fileName) else {
            Self.logger.info("auto-play suppressed: already claimed (request_id=\(requestId, privacy: .public) file=\(fileName, privacy: .public))")
            return
        }
        onAutoPlayStarted?()
        playResult(for: turn)
    }

    /// 录音结束/取消后补播挂起的结果语音。
    private func flushPendingAutoPlay() {
        guard state == .idle, !player.isPlaying,
              !pendingAutoPlayRequestIds.isEmpty else { return }
        let requestId = pendingAutoPlayRequestIds.removeFirst()
        autoPlayResult(requestId: requestId)
    }

    private func logPlaybackIsolationDrop(incomingRequestId: String?, source: String) {
        guard case .drop(let incoming, let incomingGeneration, let current, let reason) =
                resultPlaybackIsolation.decide(requestId: incomingRequestId) else { return }
        let incomingId = incoming ?? "nil"
        let currentId = current?.requestId ?? "nil"
        let incomingGen = incomingGeneration.map(String.init) ?? "nil"
        let currentGen = current.map { String($0.generation) } ?? "nil"
        WatchLog.info(
            "player", "cross_turn_audio_dropped", requestId: incoming,
            detail: "source=\(source) reason=\(reason.rawValue) incoming_request_id=\(incomingId) current_request_id=\(currentId) incoming_generation=\(incomingGen) current_generation=\(currentGen)"
        )
    }

    /// ESS-600：自动重新聆听的程序化采集入口。与 `pressBegan()` 完全同一条
    /// 录音 + 实时上行链（不另建第二条采集路径），只是没有「用户按下」这个
    /// 手势语义——`.recordingStarted` 触觉由会话层的「可以开口」click 承担，
    /// 不在同一时刻震两下。
    /// - Returns: 本轮 `request_id`；nil = 采集未能开启。
    func beginSessionTurn() -> String? {
        pressBegan(programmatic: true)
    }

    /// - Parameter programmatic: true = 会话自动开轮（非用户手势），跳过
    ///   按下触觉。
    /// - Returns: 本轮 `request_id`。已在录音时返回**在飞那一轮**的 id——
    ///   点球进会话时录音在 touch-down 已经开始，会话必须认领它而不是
    ///   再起一轮（再起一轮会当场打断用户正在说的话）。
    @discardableResult
    func pressBegan(programmatic: Bool = false) -> String? {
        guard state == .idle else { return streamRequestId?.uuidString.lowercased() }
        errorMessage = nil
        releaseRequestedWhileStarting = false
        let requestId = UUIDv7.generate()
        let requestIdString = requestId.uuidString.lowercased()
        let cleared = pendingAutoPlayRequestIds.count
        let previous = resultPlaybackIsolation.current
        pendingAutoPlayRequestIds.removeAll(keepingCapacity: true)
        let current = resultPlaybackIsolation.begin(requestId: requestIdString)
        let previousId = previous?.requestId ?? "nil"
        let previousGeneration = previous.map { String($0.generation) } ?? "nil"
        WatchLog.info(
            "player", "playback_generation_opened", requestId: requestIdString,
            detail: "generation=\(current.generation) previous_request_id=\(previousId) previous_generation=\(previousGeneration) cleared_queue=\(cleared)"
        )
        player.stop(reason: "recording_started")
        // ESS-519：新一轮录音开始，停止后台保活音频避免与
        // AudioRecorder 的 .playAndRecord 会话冲突。
        breather.stop(reason: "recording_started")
        // ESS-535: interrupt the welcome speech before recording starts
        // so the RealtimePlaybackEngine can own the audio session.
        onPressBegan?()
        state = .recording
        let streaming = voiceStreamingEnabled()
        // Generate once for both realtime and complete-file paths so result
        // playback ownership is known from trigger-down, before late frames
        // can race the recording finish.
        streamRequestId = requestId
        streamId = streaming ? UUID() : nil
        streamSequence = 0
        streamAborted = false
        if !programmatic { WatchHaptics.play(.recordingStarted) }
        // ESS-642：本轮是在当前 conversation 边界之后新起的，可被会话入口复用。
        didStartTurnSinceConversationBoundary = true
        onLocalCaptureChanged?(true)
        Task {
            // ESS-554：会话级路径下，首个流式回合在录音启动前完成
            // conversation acquire（`.playAndRecord` 会话级激活 + 播放引擎
            // 会话级重挂）。两个顺序约束：
            // 1. adapter 必须先于 acquire 就位——acquire 会 start 播放引擎，
            //    引擎在 RealtimePlaybackEngine.init 接上 playerNode 后才是
            //    可启动状态（裸引擎在无输入设备环境起图会抛 ObjC 异常，
            //    ESS-488 同族；生产路径 bootstrap 预热已保证本顺序）。
            // 2. acquire 必须先于 recorder.start()——AudioRecorder 检测到
            //    会话已持有才跳过回合级配置，否则首轮会多一次激活。
            // acquire 失败不阻断——AudioRecorder 走回 ESS-61 回合级配置，
            // 本轮降级为旧行为。
            if streaming {
                ensureRealtimeAdapter()
                ensureConversationAudioAcquired()
            }
            do {
                try await recorder.start(streamHandler: streaming ? { [weak self] payload, end in
                    self?.emitUplinkChunk(payload: payload, end: end)
                } : nil)
                guard state == .recording else {
                    WatchLog.info("recorder", "late_start_cancelled", detail: "state=\(String(describing: state))")
                    recorder.cancel()
                    clearStreamStateAfterAbort()
                    onLocalCaptureChanged?(false)
                    return
                }
                // ESS-362: bring up the realtime PCM tap only AFTER
                // `AudioRecorder.start()` has configured `.playAndRecord` and
                // the mic permission has been granted. Calling
                // `adapter.beginTurn()` synchronously in `pressBegan()` (the
                // old ordering) reached `PCMFrameRecorder.start()` while the
                // shared session was still in `.soloAmbient` — `installTap`
                // on the invalid input format then threw an uncatchable
                // Objective-C exception and terminated the app on the very
                // first press, so we never even logged `record_started`.
                if streaming, let requestId = streamRequestId {
                    startRealtimeTurnIfPossible(requestId: requestId)
                }
                if releaseRequestedWhileStarting {
                    WatchLog.info("recorder", "deferred_release_applied")
                    finishRecording()
                }
            } catch {
                state = .idle
                isRealtimeStreaming = false
                clearStreamStateAfterAbort()
                onLocalCaptureChanged?(false)
                // ESS-554：会话级持有期间录音启动失败 = 持有的会话可疑
                // （挂起期间被系统拆掉且中断通知丢失的场景靠这里收口），
                // 释放后下次按压走完整 acquire 自愈。
                endConversationAudio(reason: .startFailed)
                errorMessage = Self.recordingErrorDescription(error)
                // ESS-180：录音启动失败也是一次「秒失败」，走分身卡片 + 触觉，
                // 不让手表只有底部一行灰字，然后就没了。
                presentAvatarError(code: "ERR_RECORDER_START", requestId: nil)
                // ESS-573：真实失败事件上抛——会话模式据此退出 connecting，
                // 不再静默卡在「建立中」。卡片与 .failure 触觉已由上面既
                // 有链呈现，SessionController 不再重复。
                onRealtimeChannelFailed?(.recorderStart)
            }
        }
        return requestIdString
    }

    /// ESS-554：会话级音频 acquire 的唯一入口。仅在流式开关 +
    /// 会话级开关同开、且当前无持有会话时执行；conversation_id 在此
    /// 生成并贯穿 acquired/released/engine_restarted 三条日志。
    private func ensureConversationAudioAcquired() {
        guard conversationAudioEnabled() else { return }
        let controller = ensureConversationAudioController()
        guard !controller.isAcquired else { return }
        let conversationId = UUIDv7.generate().uuidString.lowercased()
        do {
            try controller.beginConversation(conversationId: conversationId)
        } catch {
            // 失败后果：本轮走回合级旧路径（AudioRecorder 自配会话、
            // RealtimePlaybackEngine 门内翻转），与关旗行为一致。
            WatchLog.error(
                "realtime", "conversation_audio_acquire_failed",
                detail: "conversation_id=\(conversationId)",
                code: "ERR_AUDIO_SESSION", error: error
            )
        }
    }

    /// ESS-554：懒建会话级控制器。公开以便 WatchAppServices 预热线缆与
    /// 测试断言。
    @discardableResult
    func ensureConversationAudioController() -> ConversationAudioController {
        if let controller = conversationAudioController { return controller }
        let controller = makeConversationAudioController()
        conversationAudioController = controller
        return controller
    }

    /// ESS-554 / PD-2：用户显式退出（取消当前回合、取消按压；ESS-556 的
    /// X 按钮亦调此入口）——真正 deactivate 会话，≤300ms 口径按 session
    /// deactivate 完成计。未持有时为空操作。
    func endConversationAudio(reason: ConversationAudioController.ReleaseReason = .userExit) {
        conversationAudioController?.endConversation(reason: reason)
    }

    /// ESS-362: stand up the realtime coordinator turn once the audio session
    /// is safely `.playAndRecord`. Any failure (invalid input format, engine
    /// start refused, etc.) is downgraded to a clean fallback: we cancel the
    /// half-brought-up adapter turn, clear the stream identifiers so
    /// `submit(recording:)` takes the reliable full-file branch, and the m4a
    /// we're already recording still goes out. Nothing here is allowed to
    /// throw — the goal is "no crash, no silent half-configured stream,
    /// always deliverable."
    ///
    /// ESS-532: on successful adapter start, set `realtimePlaybackPending = true`
    /// so the VoiceSessionKeeper holds the ExtendedRuntimeSession across the
    /// recording→playback gap where the turn journal does not yet show an
    /// active turn.
    private func startRealtimeTurnIfPossible(requestId: UUID) {
        let adapter = ensureRealtimeAdapter()
        let requestIdString = requestId.uuidString.lowercased()
        _ = adapter.beginTurn(requestId: requestIdString)
        // ESS-509: mark realtime streaming active so VoiceSessionKeeper holds
        // the WKExtendedRuntimeSession — without this, WCSession may be torn
        // down between commit and the first audio.delta arrival.
        isRealtimeStreaming = adapter.currentTurn != nil
        // The adapter catches its own recorder/player errors internally and
        // marks the uplink transport-failed — that trips
        // `didTriggerCompleteFileFallback` before `beginTurn` returns. If it
        // ever does, we're now in a half-alive state (a currentTurn that
        // won't produce frames); cancel it and fall back to the reliable
        // upload path for this turn.
        if adapter.didTriggerCompleteFileFallback {
            WatchLog.error(
                "realtime", "adapter_start_fell_back",
                requestId: requestIdString,
                detail: "reason=recorder_or_player_failed",
                code: "ERR_REALTIME_START"
            )
            adapter.cancel(reason: .fallback)
            pendingFallbackReason.removeValue(forKey: requestIdString)
            isRealtimeStreaming = false
            clearStreamStateAfterAbort()
            // ESS-573：实时通道在启动点即回退 = 建立失败的真实事件。
            onRealtimeChannelFailed?(.channelEvent)
            return
        }
        realtimePlaybackPending = true
    }

    /// ESS-383: reset streaming identifiers after an abort WITHOUT clearing
    /// `streamRequestId`. The request_id is shared between the streaming path
    /// and the complete-file fallback — `submit()` still needs it so the Bridge
    /// sees the same UUID on both paths. Only `streamId` and `streamSequence`
    /// are reset; `streamAborted` signals `submit()` to skip `adapter.commit()`.
    private func clearStreamStateAfterAbort() {
        streamAborted = true
        streamId = nil
        streamSequence = 0
    }

    /// ESS-653（F1-3）：**已不再由任何用户手势触发**。入口收敛后主屏长按
    /// 不提交，全 UI 没有手动单条提交入口；提交只走会话内的
    /// `endSessionTurn()`（含 `onSalvageTurn` 兜底）。保留本入口是因为
    /// 「松手即收尾」的语义与 deferred-release 处理仍是底层能力的一部分
    /// （AudioRecorder 的启动竞态口径引用它），不随 UI 收敛一起删除。
    func pressEnded() {
        guard state == .recording else { return }
        guard recorder.isRecording else {
            releaseRequestedWhileStarting = true
            WatchLog.info("recorder", "release_deferred_until_started")
            return
        }
        finishRecording()
    }

    /// ESS-538：录音进行中息屏/降腕——打断流标记。
    /// - `.inactive`（降腕/横幅等瞬态）：只打标记，手势可能还活着，收尾交给
    ///   松手路径——不主动 finish，避免通知横幅把「还在说」的录音截断。
    /// - `.background`（表冠/切 App）：手势必然已死，主动收尾。onEnded 一旦
    ///   丢失，`.recording` 态会把整个 PTT 卡死到重启（pressBegan 要 idle）。
    /// 收尾仍走 finishRecording → RecordingInterruptionPolicy 裁决：残片丢弃
    /// （卡片回前台补呈现），已说完的可用音频照常提交。
    func noteScreenOffDuringRecording(phase: String) {
        guard state == .recording else { return }
        recorder.noteExternalInterruption(reason: "scene_phase=\(phase)")
        guard phase == "background" else { return }
        guard recorder.isRecording else {
            // start() 还在权限/会话激活里：沿用 deferred-release 通道，
            // start 完成后立即 finishRecording 收尾（几乎必落太短/丢弃分支）。
            releaseRequestedWhileStarting = true
            return
        }
        finishRecording()
    }

    /// ESS-538：中断丢弃的卡片若发生在屏灭/后台，当下到不了用户（卡片最小
    /// 停留 5s 的自动收起会在抬腕前把它吞掉）——记账，回 .active 补呈现。
    private var pendingInterruptedNotice = false

    /// 回前台补呈现「刚才录音被打断了」。触觉与卡片同刻到达可见时刻。
    func presentInterruptedNoticeIfNeeded() {
        guard pendingInterruptedNotice else { return }
        pendingInterruptedNotice = false
        errorMessage = RecorderError.recordingInterrupted.errorDescription
        presentAvatarError(code: "ERR_RECORDING_INTERRUPTED", requestId: nil)
    }

    /// ESS-538 test seam：直接记账一笔待呈现的中断提示，验证
    /// presentInterruptedNoticeIfNeeded 的呈现契约（生产置位路径依赖真实
    /// 采集 + 非 active 场景，模拟器不可达——口径同 AudioRecorderHandoverTests）。
    func simulateInterruptedNoticeForTests() {
        pendingInterruptedNotice = true
    }

    private func finishRecording() {
        guard state == .recording else { return }
        state = .finishing
        onLocalCaptureChanged?(false)
        // ESS-600：本轮零提交（太短 / 收尾抛错）时把 request_id 交回会话层，
        // 由它退避后重开采集——否则会话会停在一个已经停录的死麦克风上。
        let turnRequestId = streamRequestId?.uuidString.lowercased()
        var abortReason: String?
        defer {
            state = .idle
            releaseRequestedWhileStarting = false
            if let abortReason, let turnRequestId {
                onSessionTurnAborted?(turnRequestId, abortReason)
            }
            flushPendingAutoPlay()
        }
        do {
            let recording = try recorder.finish()
            // 误触/太短（ESS-54×ESS-55）：不发请求，本地提示重说；
            // 阈值与 Bridge 解码门一致（VoiceRequestEnvelope.minimumAudioDurationMs）。
            guard recording.durationMs >= VoiceRequestEnvelope.minimumAudioDurationMs else {
                try? FileManager.default.removeItem(at: recording.fileURL)
                WatchLog.error(
                    "recorder", "recording_too_short_local",
                    detail: "duration_ms=\(recording.durationMs) bytes=\(recording.data.count)",
                    code: "ERR_AUDIO_TOO_SHORT"
                )
                errorMessage = RecorderError.recordingTooShortDescription
                // ESS-538：太短不提交 = 本回合零提交，实时回合同样当场取消，
                // 不让 PCM tap 挂到下次按住（与收尾抛错路径同一清理）。
                abortUnsubmittedRealtimeTurn()
                // ESS-180：本地失败与 Bridge 侧 ERR_AUDIO_TOO_SHORT 走同一
                // 拟人化卡片；触觉在 presenter 内响一次，此处不再重复播放，
                // 避免同一次「按太短」震两下。
                presentAvatarError(code: "ERR_AUDIO_TOO_SHORT", requestId: nil)
                abortReason = "too_short"
                return
            }
            submit(recording: recording)
        } catch {
            // ESS-538：收尾抛错 = 本回合零提交。streaming 开启时 beginTurn
            // 已在 pressBegan 跑过，必须当场取消（否则 PCM tap 挂到下次
            // 按住才停），streamRequestId 一并清掉，避免后续 retry() 误用
            // 陈旧 request_id。
            abortUnsubmittedRealtimeTurn()
            // ESS-375: recordingNeverStarted 走 ERR_AUDIO_TOO_SHORT cue
            // （与 too-short guard 统一），让手表看到可行动中文提示而非
            // 通用"录音器错误"卡片。
            let code: String
            if case RecorderError.recordingNeverStarted = error {
                code = "ERR_AUDIO_TOO_SHORT"
            } else if case RecorderError.recordingInterrupted = error {
                code = "ERR_RECORDING_INTERRUPTED"
            } else {
                code = "ERR_RECORDER_FINISH"
            }
            // ESS-538：中断丢弃发生在屏灭/后台时不当场呈现——卡片最小停留
            // 5s 的自动收起会在抬腕前吞掉它（触觉也白费）。记账，回 .active
            // 由 presentInterruptedNoticeIfNeeded 补呈现。
            abortReason = "finish_failed:\(code)"
            if case RecorderError.recordingInterrupted = error,
               WKApplication.shared().applicationState != .active {
                pendingInterruptedNotice = true
                WatchLog.info("recorder", "interrupt_notice_deferred", detail: "scene_not_active")
                return
            }
            errorMessage = Self.recordingErrorDescription(error)
            presentAvatarError(code: code, requestId: nil)
        }
    }

    /// ESS-538：收尾抛错路径的实时回合清理。finish() 抛错 = 本回合不会有
    /// 任何提交；取消已 begin 的实时回合让 PCM tap 停止、uplink 作废、
    /// realtimePlaybackPending 解除（cancel → turnFinished →
    /// onRealtimePendingResolved → VoiceSessionKeeper 释放）。
    private func abortUnsubmittedRealtimeTurn() {
        if let requestId = streamRequestId?.uuidString.lowercased() {
            pendingFallbackReason.removeValue(forKey: requestId)
            if let adapter = realtimeAdapter, adapter.currentTurn?.requestId == requestId {
                WatchLog.info("realtime", "unsubmitted_turn_aborted", requestId: requestId)
                adapter.cancel(reason: .cancelled)
            }
        }
        streamRequestId = nil
        clearStreamStateAfterAbort()
    }

    /// 提交录音：生成信封发送，同时留一份重试缓存（失败重发不用重新说话）。
    /// ESS-383: `streamRequestId` is always preserved (even after streaming abort)
    /// so the Bridge sees the same `request_id` on both the streaming frames and
    /// the complete-file upload. `streamAborted` gates whether we route through
    /// `adapter.commit()` or the reliable full-file path.
    private func submit(recording: AudioRecorder.Recording) {
        let requestId = streamRequestId ?? UUIDv7.generate()
        // ESS-317: consume re-chat context for parent_request_id + context_summary
        let parentId: String?
        let contextText: String?
        if let ctx = pendingReChatContext {
            parentId = ctx.parentRequestId
            contextText = ctx.contextSummary
            pendingReChatContext = nil
            reChatContextText = nil
        } else {
            parentId = nil
            contextText = nil
        }
        let envelope = VoiceRequestEnvelope.voiceRequest(
            requestId: requestId,
            audio: VoiceAudioDescriptor(
                codec: "aac",
                sampleRate: AudioRecorder.sampleRate,
                channels: AudioRecorder.channels,
                durationMs: recording.durationMs,
                sha256: VoiceDigest.sha256Hex(of: recording.data)
            ),
            streamingRequested: voiceStreamingEnabled(),
            parentRequestId: parentId,
            contextSummary: contextText
        )
        retryStore.save(requestId: envelope.requestId, data: recording.data, durationMs: recording.durationMs)

        let requestIdStr = requestId.uuidString.lowercased()
        // ESS-331: if the fast channel died while recording was still in
        // flight, the adapter has already tripped its single-shot flag. Now
        // that the m4a exists, honour the deferred fallback with the real
        // recording body — this is the one and only allowed integer full-file
        // upload for this turn.
        if let deferredReason = pendingFallbackReason.removeValue(forKey: requestIdStr) {
            submitFullFileFallback(
                recording: recording, requestId: requestIdStr, reason: deferredReason
            )
        } else if !streamAborted,
                  let adapter = realtimeAdapter,
                  adapter.currentTurn?.requestId == requestIdStr {
            // ESS-321: streaming path is live. Retain the m4a so a fast-channel
            // failure can invoke the single-shot fallback with the real body;
            // commit the uplink and skip the direct full-file submission —
            // the Bridge will assemble the answer from PCM frames.
            retainRealtimeRecording(recording, forRequestId: requestIdStr)
            adapter.commit()
            WatchLog.info(
                "realtime", "uplink_committed",
                requestId: envelope.requestId,
                detail: "duration_ms=\(recording.durationMs) bytes=\(recording.data.count)"
            )
        } else {
            transport.send(envelope: envelope, recording: recording)
        }
        WatchHaptics.play(.requestSubmitted)
        // ESS-519：录音已发送，进入等待阶段。立即启动后台音频保活——
        // 此时 App 仍在 active 态，音频会话可成功激活；后续降腕/熄屏时
        // WKExtendedRuntimeSession 虽会被 .resignedFrontmost 收回，但
        // 活跃的音频会话保持进程不被挂起，结果到达时可正常播放。
        // ESS-587：经注入缝启动，测试可断言接线存在（本体单测覆盖不到调用方）。
        startBreatherAfterSubmit?()
        streamRequestId = nil
        streamId = nil
        streamAborted = false
        // ESS-600：上行**真的**提交完了才推进会话回合相位 listening → thinking。
        // 放在最后：前面任何一条分支都已把音频交给某条真实通道。
        onSessionTurnCommitted?(requestIdStr)
    }

    private func emitUplinkChunk(payload: Data, end: Bool) {
        guard let requestId = streamRequestId, let streamId else { return }
        let chunk = VoiceStreamChunk(
            requestId: requestId.uuidString.lowercased(), streamId: streamId.uuidString.lowercased(),
            direction: .uplink, sequence: streamSequence,
            capturedAtMs: Int64(Date().timeIntervalSince1970 * 1_000), codec: "aac_lc",
            sampleRate: AudioRecorder.sampleRate, payload: payload, endOfStream: end
        )
        streamSequence += 1
        transport.sendStreamChunk(chunk)
    }

    // MARK: - ESS-321 real-time adapter wiring

    /// Lazily construct the adapter. Public so the WatchSettingsStore can
    /// hand incoming `RealtimeDownlinkEnvelope` payloads to it, and so tests
    /// can substitute recorder / player fakes if needed.
    @discardableResult
    func ensureRealtimeAdapter() -> WatchRealtimeMediaAdapter {
        if let adapter = realtimeAdapter { return adapter }
        // ESS-554：会话级开关 ON 时，两个实时组件改用 controller 持有的
        // 引擎 + `.conversation` 生命周期（会话级起停）；OFF 时与今天
        // main 完全一致（各自持引擎、回合级会话门）。开关在 adapter
        // 创建时读取并冻结——运行期翻转需要重建 adapter 才生效。
        let conversationScoped = conversationAudioEnabled()
        let audioController = conversationScoped ? ensureConversationAudioController() : nil
        let owner: RealtimeAudioLifecycleOwner = conversationScoped ? .conversation : .turn
        let lifecycleOwner: () -> RealtimeAudioLifecycleOwner = { owner }
        let pcmRecorder: PCMFrameRecorder
        let playbackEngine: RealtimePlaybackEngine
        if let audioController {
            pcmRecorder = PCMFrameRecorder(
                audioEngine: audioController.captureEngine,
                lifecycleOwner: lifecycleOwner
            )
            playbackEngine = RealtimePlaybackEngine(
                audioEngine: audioController.playbackEngine,
                lifecycleOwner: lifecycleOwner
            )
        } else {
            pcmRecorder = PCMFrameRecorder(lifecycleOwner: lifecycleOwner)
            playbackEngine = RealtimePlaybackEngine(lifecycleOwner: lifecycleOwner)
        }
        let adapter = WatchRealtimeMediaAdapter(
            recorder: pcmRecorder,
            player: playbackEngine,
            transport: transport,
            fullFileFallback: { [weak self] handle, reason in
                self?.performFullFileFallback(handle: handle, reason: reason)
            },
            logger: { message in
                WatchLog.info("realtime", "adapter", detail: message)
            },
            vadConfiguration: LocalVADConfiguration(
                endpointSilenceMs: Int64(WatchDebugSettings().vadEndpointSilenceMs)
            ),
            automaticallyCommitOnSpeechFinal: true
        )
        // ESS-575: when VAD auto-commits on speech end, finish the AAC
        // recording so the file fallback and retry cache are set up.
        adapter.onVADEvent = { [weak self] event in
            guard let self, case .speechFinal = event,
                  self.state == .recording, self.recorder.isRecording else { return }
            self.finishRecording()
        }
        // ESS-532: clear the pending hold when playback starts, the turn
        // falls back to complete-file, or the turn finishes entirely.
        adapter.onRealtimePendingResolved = { [weak self] in
            self?.realtimePlaybackPending = false
        }
        // ESS-587: realtime is the default production playback path. Stop the
        // silent keep-alive before its shared AVAudioSession is repurposed by
        // real playback, keeping the breather state in sync with the session.
        adapter.onRealtimePlaybackStarted = { [weak self] in
            self?.breather.stop(reason: "realtime_playback")
        }
        // ESS-509: track turn lifecycle so WCSession keep-alive releases
        // exactly when the realtime path is done — no premature release
        // that would drop audio.delta delivery, no zombie hold after
        // fallback/cancel that would burn battery.
        adapter.onTurnFinished = { [weak self] _, _ in
            self?.isRealtimeStreaming = false
            WatchLog.info("realtime", "streaming_hold_released",
                          detail: "reason=turn_finished adapter_turn_active=false")
        }
        attachSessionEvents(to: adapter)
        realtimeAdapter = adapter
        return adapter
    }

    /// 把 adapter 的真实链路事件透传到会话层。
    ///
    /// - ESS-573：通道就绪只认首个被对端接受的 uplink ack；快速上行死亡如实上报。
    /// - ESS-600（复审阻断 1）：realtime 是**默认**播放路径，回合状态机必须
    ///   由它的真实 `.started/.ended` 驱动——只接完整文件那条回退路径，等于
    ///   默认路径下核心闭环根本没形成。
    ///
    /// 单独成函数是为了让 WatchTests 能用**同一段生产接线**驱动一个装了
    /// mock player 的 adapter：把接线复制进测试就只能证明副本是对的，
    /// 证明不了生产路径接上了（这正是本单第一次复审被打回的原因）。
    /// PTT 路径本身不消费这些回调，行为不变。
    /// ESS-600 test seam：注入一个已装好替身的 adapter（生产路径从不调用）。
    /// `ensureRealtimeAdapter()` 会构造真实 `RealtimePlaybackEngine`，其
    /// `AVAudioEngine` 在无音频硬件的 hosted CI 上 `SetFormat` 直接 -10868
    /// （ESS-498 家族）。没有这条缝，「beginSessionConversation 不得打死在飞
    /// 首轮」这条契约就只能靠跳过测试来回避，等于在 CI 上没有防线。
    func useRealtimeAdapterForTests(_ adapter: WatchRealtimeMediaAdapter) {
        realtimeAdapter = adapter
        attachSessionEvents(to: adapter)
    }

    func attachSessionEvents(to adapter: WatchRealtimeMediaAdapter) {
        adapter.onChannelReady = { [weak self] _ in
            self?.onRealtimeChannelReady?()
        }
        adapter.onUplinkFallback = { [weak self] _ in
            self?.onRealtimeChannelFailed?(.channelEvent)
        }
        adapter.onAnswerPlaybackStarted = { [weak self] handle in
            self?.onSessionAnswerStarted?(handle.requestId)
        }
        adapter.onAnswerPlaybackFinished = { [weak self] handle, bytes in
            self?.onSessionAnswerFinished?(handle.requestId, true, "realtime_rendered:\(bytes)")
        }
        adapter.onAnswerPlaybackFailed = { [weak self] handle, code in
            self?.onSessionAnswerFinished?(handle.requestId, false, "realtime_\(code)")
        }
    }

    // MARK: - ESS-600 会话边界与手动打断

    /// ESS-600：会话开始——开一个 conversation 边界。`conversation_id` 在
    /// 整段会话内不变，`turn_id` 每轮递增（唯一铸造点在 `ConversationHandle`，
    /// 本控制器不另铸 id）。
    func beginSessionConversation() {
        guard voiceStreamingEnabled() else { return }
        let adapter = ensureRealtimeAdapter()
        // ESS-600 复审阻断 A：`RealtimeMediaSession.beginConversation` 开头就是
        // `finishTurn(reason: .interrupted)`（`Shared/RealtimeMediaSession.swift`）。
        // 短按进会话时，录音与实时回合在 touch-down 已经起来了——此刻再开一次
        // conversation 会把**正在飞的首轮打死**，而 `pressBegan()` 因为 state
        // 已是 .recording 又会把同一个 request_id 交回会话层认领：会话盯着一个
        // realtime 回合已被 interrupt 的 id，首轮拿不到 play_started/finished。
        //
        // 在飞回合本身已经隐式开了 conversation（`beginTurn` 在 conversation
        // 为 nil 时自建），它就是这段会话的 conversation——直接复用，不重开。
        // 判据取 `session.activeTurn` 而非 adapter 的镜像：被
        // `beginConversation` 的 `finishTurn` 打死的正是会话侧那一个。
        //
        // ESS-642（本条是上面那个复用的**边界修正**）：「有没有 activeTurn」
        // 不足以判定可复用——它区分不了「本次 touch-down 新起的首轮」与
        // 「上一会话遗留的回合」。真机 L1 证据：进入电话模式后
        // `session_next_listening` 认领了上一会话的 request_id，紧接着
        // `play_started` 用同一个旧 id 播出上一轮答案，同时刷
        // `downlink_drop reason=staleSession`。
        // 闸门收紧为两条同时成立：① 本次 conversation 边界之后确实由
        // touch-down 起过一轮（`didStartTurnSinceConversationBoundary`，
        // 上一会话退出时被 `endSessionConversation` 清掉）；② 在飞回合的
        // request_id 与当前录音的 `streamRequestId` 一致。
        let entryTurnRequestId = didStartTurnSinceConversationBoundary
            ? streamRequestId?.uuidString.lowercased() : nil
        if let inFlight = adapter.session.activeTurn,
           let entryTurnRequestId, inFlight.requestId == entryTurnRequestId {
            WatchLog.info(
                "session", "conversation_reused", requestId: inFlight.requestId,
                detail: "conversation_id=\(adapter.session.activeConversationId ?? "nil") "
                    + "reason=turn_started_after_boundary turn_id=\(inFlight.turnId)"
            )
            return
        }
        // ESS-648：短按的真实时序里还有第三种形态——**本次 touch-down 已经起轮、
        // 但 activeTurn 尚未异步建立**。`pressBegan()` 同步段只置 `state = .recording`
        // 与 `streamRequestId`；`adapter.beginTurn` 要等 `recorder.start()` 返回后
        // 才在 Task 里执行（ESS-362 的顺序约束，不能提前）。短按松手往往比这更快，
        // 于是入口看到的是「gate 为真 + request_id 已铸 + activeTurn 仍为 nil」。
        // 上面的复用分支要求 activeTurn 已存在，下面的遗留清理分支只看
        // `state != .idle`——两条都不认这个窗口，结果把**本次合法首轮**当遗留物
        // `pressCancelled()` 掉，正是 ESS-600 要保护的那一轮。
        // 判据用 gate + `streamRequestId`（两者都在 `pressBegan` 同步段建立，
        // `endSessionConversation` 退出时清 gate），因此上一会话遗留的录音状态
        // gate 为假，仍走下面的清理分支，ESS-642 的边界隔离不受影响。
        // 这里只开边界、不动录音与 request_id：随后异步落地的 `beginTurn` 会挂到
        // 刚开的这段 conversation 上，gate 保持为真让它仍是「本次边界之后起的轮」。
        if let entryTurnRequestId, adapter.session.activeTurn == nil, state != .idle {
            let handle = adapter.beginConversation()
            didStartTurnSinceConversationBoundary = true
            WatchLog.info(
                "session", "conversation_opened_awaiting_turn", requestId: entryTurnRequestId,
                detail: "conversation_id=\(handle.conversationId) "
                    + "ptt_state=\(String(describing: state)) reason=turn_start_pending"
            )
            return
        }
        // 走到这里 = 没有可复用的本轮回合。任何遗留物（上一会话的 activeTurn、
        // 仍在跑的录音、未提交的实时回合）都必须在开新边界**之前**清掉，
        // 否则新会话会继续认领旧 request_id。
        if adapter.session.activeTurn != nil || state != .idle {
            WatchLog.info(
                "session", "stale_turn_discarded_at_entry",
                requestId: adapter.session.activeTurn?.requestId,
                detail: "ptt_state=\(String(describing: state)) "
                    + "stream_request_id=\(streamRequestId?.uuidString.lowercased() ?? "nil") "
                    + "started_after_boundary=\(didStartTurnSinceConversationBoundary)"
            )
            // 停录 + 清 stream 状态 + abort 未提交实时回合 + 回 .idle，
            // 让紧随其后的 `pressBegan()` 真正新起一轮、铸新 request_id。
            pressCancelled()
            // pressCancelled 只处理 .recording；遗留回合可能停在别的相位，
            // 这里补一次 adapter 级取消（停播放器 + finishTurn + 停采集）。
            if adapter.session.activeTurn != nil {
                adapter.cancel(reason: .cancelled)
            }
        }
        let handle = adapter.beginConversation()
        didStartTurnSinceConversationBoundary = false
        WatchLog.info(
            "session", "conversation_opened",
            detail: "conversation_id=\(handle.conversationId)"
        )
    }

    /// ESS-600：会话结束——关闭 conversation 边界，旧回合的迟到事件因无
    /// conversation 存续而被拒，不会漏进下一次会话。
    func endSessionConversation() {
        // ESS-642：边界闸门先落。即便下面因为没有 adapter 而早退，也不能把
        // 「上一会话起过一轮」这个事实留给下一次进入会话去复用。
        didStartTurnSinceConversationBoundary = false
        guard let adapter = realtimeAdapter else { return }
        let conversationId = adapter.session.activeConversationId
        // ESS-642：退出时把播放器一并停掉。`closeConversation` 只 finishTurn +
        // 关边界，不动播放器——旧答案若正在渲染，它会继续播到下一次进入会话，
        // 真机上表现为「刚进电话模式就听见上一轮的回答」。
        if adapter.session.activeTurn != nil {
            adapter.cancel(reason: .cancelled)
        }
        adapter.closeConversation()
        WatchLog.info(
            "session", "conversation_closed",
            detail: "conversation_id=\(conversationId ?? "nil")"
        )
    }

    /// ESS-600（F4）：speaking 中用户点球 → 立刻停播。
    /// - realtime：走 `bargeIn()` 请求 iPhone 换代——清空已缓冲下行并让
    ///   旧 generation 的迟到 delta 被拒，这正是「旧音频零补播」需要的语义；
    ///   单纯 stop 会让换代前在途的 delta 继续灌进下一轮。
    /// - 完整文件：走既有 `stopPlaybackByUser`（不派发终局、不改回合状态）。
    func interruptAnswerPlayback() {
        if let adapter = realtimeAdapter, let handle = adapter.currentTurn {
            WatchLog.info(
                "realtime", "playback_user_interrupted", requestId: handle.requestId,
                detail: "source=orb_tap path=realtime"
            )
            adapter.bargeIn()
        }
        if let context = player.currentContext {
            stopPlaybackByUser(requestId: context)
        }
    }

    /// Called by the adapter when the fast channel dies. If the recording
    /// has already been finalised, upload it via the reliable path
    /// immediately; otherwise (ESS-331: failure fired mid-record) record the
    /// intent so `submit(recording:)` can honour it once the m4a exists.
    /// The adapter's single-shot flag guarantees this is called at most once
    /// per turn, so this map holds at most one deferred fallback per turn.
    private func performFullFileFallback(
        handle: RealtimeMediaSession.TurnHandle,
        reason: RealtimeUplinkStream.FallbackReason
    ) {
        if let recording = pendingRealtimeRecording.removeValue(forKey: handle.requestId) {
            submitFullFileFallback(recording: recording, requestId: handle.requestId, reason: reason)
        } else {
            pendingFallbackReason[handle.requestId] = reason
            WatchLog.info(
                "realtime", "fallback_deferred_until_recording_finish",
                requestId: handle.requestId,
                detail: "reason=\(reason)"
            )
        }
    }

    /// Actual m4a upload via the existing reliable relay path. Called both
    /// on immediate fallback (adapter fires after recording finishes) and on
    /// deferred fallback (adapter fired mid-record, `submit` picks it up).
    private func submitFullFileFallback(
        recording: AudioRecorder.Recording,
        requestId: String,
        reason: RealtimeUplinkStream.FallbackReason
    ) {
        let uuid = UUID(uuidString: requestId) ?? UUIDv7.generate()
        let envelope = VoiceRequestEnvelope.voiceRequest(
            requestId: uuid,
            audio: VoiceAudioDescriptor(
                codec: "aac",
                sampleRate: AudioRecorder.sampleRate,
                channels: AudioRecorder.channels,
                durationMs: recording.durationMs,
                sha256: VoiceDigest.sha256Hex(of: recording.data)
            ),
            streamingRequested: voiceStreamingEnabled()
        )
        retryStore.save(
            requestId: envelope.requestId,
            data: recording.data,
            durationMs: recording.durationMs
        )
        transport.send(envelope: envelope, recording: recording)
        submittedFullFileFallbackCount += 1
        WatchLog.info(
            "realtime", "fallback_full_file_submitted",
            requestId: requestId,
            detail: "reason=\(reason) duration_ms=\(recording.durationMs) bytes=\(recording.data.count)"
        )
    }

    /// Stash the just-finished m4a so a subsequent fast-channel failure can
    /// still reach the reliable upload path. Cleared once the turn is
    /// submitted normally or the adapter consumes it.
    func retainRealtimeRecording(_ recording: AudioRecorder.Recording, forRequestId requestId: String) {
        pendingRealtimeRecording[requestId] = recording
    }

    /// Snapshot for tests: outstanding deferred fallback reasons keyed by
    /// request id. Production paths do not read this.
    var deferredFallbackReasons: [String: RealtimeUplinkStream.FallbackReason] {
        pendingFallbackReason
    }

    /// ESS-331 seam for tests: count of `transport.send(envelope:recording:)`
    /// invocations that came in through the fallback path (both immediate
    /// and deferred). Tests assert this equals exactly 1 to prove the
    /// reliable path fired exactly once per failed turn.
    private(set) var submittedFullFileFallbackCount = 0

    /// ESS-587 test seam：走完整提交尾部，断言录音发送后 breather 接线存在。
    func simulateSubmitForTests(recording: AudioRecorder.Recording) {
        submit(recording: recording)
    }

    /// ESS-331 test seam: mimics `submit(recording:)`'s drain-of-deferred
    /// codepath without needing an AVFoundation-backed recorder round-trip.
    /// Only intended for the deferred-fallback WatchTests.
    func simulateDeferredFallbackDrainForTests(
        requestId: String,
        reason: RealtimeUplinkStream.FallbackReason
    ) {
        guard let recording = pendingRealtimeRecording.removeValue(forKey: requestId) else { return }
        pendingFallbackReason.removeValue(forKey: requestId)
        submitFullFileFallback(recording: recording, requestId: requestId, reason: reason)
    }

    /// 一键重试（ESS-55）：用缓存的录音换新 request_id 重发，不需要重新说话。
    ///
    /// ESS-180：重试失败也走屏幕分身错误卡片。旧路径把提示塞进 `errorMessage`
    /// 底部灰字里，主界面重构后已没人读它——用户点了「重试」后要么什么都没
    /// 发生（缓存丢失），要么静默继续等待（写盘失败），都是本 issue 明确
    /// 要消灭的「傻等」体验。
    func retry(turn: VoiceTurnRecord) {
        guard case .failed = turn.phase else { return }
        guard let stored = retryStore.stored(for: turn.requestId) else {
            errorMessage = "这条录音已清理，请重新说一次"
            presentAvatarError(code: "ERR_RETRY_CACHE_MISSING", requestId: nil)
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wristagent-retry-\(UUID().uuidString).m4a")
        guard (try? stored.data.write(to: tempURL, options: .atomic)) != nil else {
            errorMessage = "重试失败，请重新说一次"
            presentAvatarError(code: "ERR_RETRY_WRITE_FAILED", requestId: nil)
            return
        }
        errorMessage = nil
        WatchLog.info("turn", "retry_requested", requestId: turn.requestId)
        submit(recording: AudioRecorder.Recording(
            fileURL: tempURL, data: stored.data, durationMs: stored.durationMs
        ))
    }

    // MARK: - ESS-317 再次对话

    /// 准备「再次对话」上下文：记录父轮次的 request_id 和问答摘要，
    /// 下次 pressBegan → submit 时新轮次会自动携带 parent_request_id + contextSummary。
    /// ①屏球体旁会显示「续：<摘要>」。
    func prepareReChat(from turn: VoiceTurnRecord) {
        let parentId = turn.requestId
        let qText: String
        if let result = turn.result, !result.displaySummary.isEmpty {
            let firstLine = result.displaySummary
                .components(separatedBy: .newlines)
                .first ?? result.displaySummary
            qText = String(firstLine.prefix(60))
        } else {
            qText = "历史对话"
        }
        let contextSummary = "用户问：\(qText)"
        pendingReChatContext = (parentRequestId: parentId, contextSummary: contextSummary)
        reChatContextText = "续：\(qText)"
        WatchLog.info(
            "turn", "rechat_prepared", requestId: parentId,
            detail: "context_chars=\(contextSummary.count)"
        )
    }

    /// 清空再次对话上下文（新请求提交后 / 用户取消）。
    func clearReChatContext() {
        pendingReChatContext = nil
        reChatContextText = nil
    }

    /// ESS-317 历史对话留存：前台时触发 24h 过期清理。
    /// 调用 journal.evictExpiredAudio 清理超期轮次及关联加密音频。
    func evictStaleAudio() {
        journal.evictExpiredAudio(vault: speechVault)
    }

    /// 打开 App/回前台时呈现未读结果（ESS-55 流程图节点 C）：
    /// 有语音未播则连播带看，只有文字则直接展示全文；配触觉提醒。
    @discardableResult
    func presentUnreadIfAny() -> Bool {
        guard state == .idle, subtitleSession == nil else { return false }
        guard let turn = journal.firstUnreadResult else { return false }
        WatchHaptics.play(.resultArrived, requestId: turn.requestId)
        presentResult(requestId: turn.requestId)
        return true
    }

    /// 直达某条结果的全文视图（点通知进入 / 未读呈现，ESS-55 细则 #3）。
    /// 不播触觉——调用方各自决定（通知本身已震过）。
    func presentResult(requestId: String) {
        guard let turn = journal.turn(withId: requestId), let result = turn.result else {
            WatchLog.error("notify", "present_result_missing", requestId: requestId, code: "ERR_NO_RESULT")
            return
        }
        if turn.speechFileName != nil {
            playResult(for: turn)
        } else {
            subtitleSession = SubtitleSession(
                requestId: turn.requestId, text: result.displaySummary, hasAudio: false
            )
        }
    }

    func pressCancelled() {
        guard state == .recording else { return }
        recorder.cancel()
        releaseRequestedWhileStarting = false
        state = .idle
        onLocalCaptureChanged?(false)
        // ESS-573：取消未提交的实时回合——与 finishRecording 错误路径
        // 同一清理口径，不让 PCM tap 挂到下次按压才停。
        abortUnsubmittedRealtimeTurn()
        // ESS-554：按压被取消 = 本轮不会发起，会话随之显式收口（PD-2）。
        endConversationAudio(reason: .userExit)
        flushPendingAutoPlay()
    }

    /// ESS-573 / PRD F1：会话模式点 X / 下滑退出的统一拆链入口——
    /// 「点 X 必须真正释放麦克风」：
    /// - 录音中 → pressCancelled（不提交、停采集、取消实时回合、deactivate）
    /// - 有进行中回合 → cancelActiveTurn（上行取消 + 本地投影 + deactivate）
    /// - 其余（回合已终态/仅会话级音频持有）→ 幂等 deactivate。
    /// 「≤300ms 麦克风释放」按 AVAudioSession deactivate 完成计，证据见
    /// `conversation_audio_released` 的 duration_ms。
    func endSessionChannel() {
        // ESS-600：先关 conversation 边界，再拆采集/回合。顺序有意——
        // 边界关掉后，拆链过程中冒出来的迟到事件不会再被认成「某一轮」。
        endSessionConversation()
        onLocalCaptureChanged?(false)
        if state == .recording {
            pressCancelled()
            return
        }
        if let turn = journal.activeTurn, turn.isActive {
            cancelActiveTurn()
            return
        }
        endConversationAudio(reason: .userExit)
    }

    /// ESS-573 / PRD F2 异常（单轮 60s 上限）：会话模式到点视同松手，
    /// 走与 pressEnded 完全相同的 finishRecording → submit 链路。
    /// VAD 自动断句（F2）在后续 Wave 接管后本入口退居上限兜底。
    func endSessionTurn() {
        guard state == .recording else { return }
        guard recorder.isRecording else { return }
        finishRecording()
    }

    /// 权限确认（§5.3）：只对当前回合生效；先本地记账（UI 立即反馈），再上行给 iPhone 签名转发。
    func respondPermission(approved: Bool) {
        guard
            let turn = journal.activeTurn,
            turn.currentState == .permissionRequired,
            turn.permissionApproved == nil,
            let permission = turn.permission
        else { return }
        journal.recordDecision(requestId: turn.requestId, approved: approved)
        transport.send(decision: PermissionDecisionEnvelope.decision(
            requestId: turn.requestId,
            permissionId: permission.id,
            approved: approved
        ))
    }

    /// 取消当前进行中的回合：上行取消请求，本地立即投影为已取消。
    func cancelActiveTurn() {
        guard let turn = journal.activeTurn, turn.isActive else { return }
        WatchLog.info("turn", "cancel_requested", requestId: turn.requestId)
        transport.send(cancel: VoiceCancelEnvelope.cancel(requestId: turn.requestId))
        journal.recordLocal(.cancelled, requestId: turn.requestId, detail: "你取消了本次请求")
        // ESS-554 / PD-2：显式取消即退出会话——点 X 语义在 Phase 0 由本
        // 入口承担，必须真正 deactivate 会话（≤300ms 口径按 session
        // deactivate 完成计），不得只停 tap。
        endConversationAudio(reason: .userExit)
    }

    /// ESS-259 B-STOP：用户在字幕视图轻点打断本回合结果语音。
    /// - `player.stop(reason:)` 只清进程内状态、不派发 onFinish/onPlaybackEndgame，
    ///   因此不会走 `PlaybackEndgamePolicy`——不播 `.failure` 触觉、不发失败横幅、
    ///   不改状态机（回合仍是 `.completed`）。
    /// - 不重新入队（区别于 B-PTT：按住说话打断在 pressBegan 里 enqueueAutoPlay）；
    ///   语音留在加密仓，用户可点结果卡片「播放语音」重播。
    /// - `journal.recordPlaybackInterrupted` 落打断时间戳，供②历史时间线追加
    ///   「已打断」一行；同一次播放里连点两下幂等。
    /// - 单独落 `playback_user_interrupted` 结构化事件作为 R-02.1 运行时证据。
    func stopPlaybackByUser(requestId: String) {
        guard player.currentContext == requestId else { return }
        WatchLog.info(
            "player", "playback_user_interrupted", requestId: requestId,
            detail: "source=subtitle_tap"
        )
        player.stop(reason: "user_interrupt")
        journal.recordPlaybackInterrupted(requestId: requestId)
    }

    /// 播放结果语音：从加密仓解密到内存播放，播完即删（交付后删除）。
    func playResult(for turn: VoiceTurnRecord) {
        let requestId = turn.requestId
        guard let fileName = turn.speechFileName else {
            WatchLog.error("player", "result_speech_missing", requestId: requestId, code: "ERR_NO_SPEECH_FILE")
            return
        }
        guard let vault = speechVault, let data = try? vault.load(name: fileName) else {
            WatchLog.error(
                "player", "result_speech_load_failed", requestId: requestId,
                detail: "vault=\(speechVault != nil)", code: "ERR_VAULT_LOAD"
            )
            presentTranscriptOnly(requestId: requestId)
            presentAvatarError(code: "ERR_VAULT_LOAD", requestId: requestId)
            return
        }
        // ESS-519：真实播放即将开始，停止静音保活音频以释放系统资源。
        breather.stop(reason: "real_playback")
        let started = player.play(data: data, context: requestId) { [weak self] finished in
            guard let self else { return }
            // ESS-45×ESS-46：只有终态回合的结果语音播完才算交付——interim
            // （回合仍在处理中）播完不算，否则 completed 后等待最终语音的
            // 120s grace 持有会被跳过，App 挂起、最终结果播不出来。
            // ESS-58：未播完（锁屏截断/解码失败）不删语音不记交付，保留重播。
            // ESS-54：清账时校验 fileName，语音后到覆盖的情形不误删新语音。
            switch PlaybackRecoveryPolicy.finishOutcome(
                finishedSuccessfully: finished,
                turnIsTerminal: self.journal.turn(withId: requestId)?.currentState.isTerminal == true
            ) {
            case .retainForReplay:
                self.unfinishedPlaybackIds.insert(requestId)
                WatchLog.info(
                    "player", "playback_retained", requestId: requestId,
                    detail: "unfinished=true speech kept for replay"
                )
            case .deliverInterim:
                self.unfinishedPlaybackIds.remove(requestId)
                self.speechVault?.remove(name: fileName)
                _ = self.journal.clearSpeech(requestId: requestId, matching: fileName)
            case .deliverFinal:
                self.unfinishedPlaybackIds.remove(requestId)
                // ESS-317 留存：播放成功不删音频，保留 24h/最近 10 轮供历史重播。
                // 清理由 VoiceTurnJournal.trimAndSave + evictExpiredAudio 集中处理。
                self.sessionKeeper.markDelivered(requestId: requestId)
            }
            // 播完整段视为已读（ESS-55 未读机制）：熄屏听完也算送达。
            if self.journal.turn(withId: requestId)?.currentState == .completed {
                self.journal.markResultViewed(requestId: requestId)
            }
            self.flushPendingAutoPlay()
        }
        // 字幕式播放（ESS-48）：播放开始即进入全文视图，按进度逐句高亮；
        // 播放起不来但有文字时降级为纯文本展示，不留空白。
        // interim 播放中最终结果到达：play() 已 stop 前一段，会话整体替换，不叠加。
        let text = turn.result?.displaySummary ?? ""
        if started {
            subtitleSession = SubtitleSession(requestId: requestId, text: text, hasAudio: true)
        } else if !text.isEmpty {
            subtitleSession = SubtitleSession(requestId: requestId, text: text, hasAudio: false)
        }
        // ESS-600（复审阻断 2）：**起播成功才算开口**。`play()` 返回 false
        // 意味着这段语音一个字都没出，此时上报 answer_started 会让会话在
        // 一段根本没响的「回答」后自动开下一轮，用户以为分身答过了。
        if started {
            onSessionAnswerStarted?(requestId)
        } else {
            onSessionAnswerFinished?(requestId, false, "play_rejected")
        }
    }

    // MARK: - ESS-317 F2.4 再次对话

    /// ESS-317 再次对话的上下文（Q1=a：只传上一轮问+答文本）。
    struct ContinuationContext {
        let parentRequestId: String
        let contextText: String
    }

    /// 当前续聊上下文，供提交语音请求时附加 `parent_request_id`。
    private(set) var continuationContext: ContinuationContext?

    // MARK: - ESS-522 确认计时与主屏释放

    /// 确认流程结束后回调（本地兜底或后端确认到达）。
    /// 写 telemetry、释放主屏封锁。
    private func handleConfirmComplete(requestId: String, outcome: VoiceConfirmTimer.Outcome) {
        switch outcome {
        case .backendConfirmationArrived:
            // 后端确认来得及时——语音是从后台来的真实语音，记为已播。
            setSpawnConfirmSpoken(requestId: requestId, value: true)
        case .localFallbackPlayed:
            // 本地兜底语音播出——记为已播。
            setSpawnConfirmSpoken(requestId: requestId, value: true)
        case .localFallbackMissing:
            // 本地资源缺失，只落日志 + 触觉，不计为「已播」。
            // spawnConfirmSpoken 保持 false——确实没有语音可播。
            break
        }
        releaseMainScreenBlock(requestId: requestId)
    }

    /// 释放主屏封锁，计算并写入 `main_screen_blocked_ms`。
    private func releaseMainScreenBlock(requestId: String) {
        guard let blockedAt = mainScreenBlockedAt else { return }
        mainScreenBlockedAt = nil
        let elapsedMs = Int(Date().timeIntervalSince(blockedAt) * 1_000)
        setMainScreenBlockedMs(requestId: requestId, value: elapsedMs)
        WatchLog.info(
            "confirm", "main_screen_released", requestId: requestId,
            detail: "blocked_ms=\(elapsedMs)"
        )
    }

    /// ESS-522 埋点：写入确认语音已播标记。
    private func setSpawnConfirmSpoken(requestId: String, value: Bool) {
        journal.setSpawnConfirmSpoken(requestId: requestId, value: value)
    }

    /// ESS-522 埋点：写入主屏封锁时长。
    private func setMainScreenBlockedMs(requestId: String, value: Int) {
        journal.setMainScreenBlockedMs(requestId: requestId, value: value)
    }

    /// ESS-522 S-3 进度静默：记录任意一次试图将进度转为语音的调用为「已违规」。
    /// 调用方（WatchVoiceTransport / relay handler）在收到进度事件时调用此方法，
    /// 确保 `progress_spoken` 恒为 0——进度只占角落一行，永远不出声。
    func recordProgressEvent(requestId: String) {
        journal.setProgressSpoken(requestId: requestId, value: true)
        progressSpokenCount += 1
        WatchLog.error(
            "confirm", "progress_spoken_violation", requestId: requestId,
            detail: "count=\(progressSpokenCount)",
            code: "ERR_PROGRESS_SPOKEN"
        )
    }
}
