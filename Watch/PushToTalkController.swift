import Combine
import Foundation
import os

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
    /// ESS-180：屏幕分身错误卡片状态机；订阅 `errorPresenter.active` 即得 UI。
    let errorPresenter = AvatarErrorPresenter()

    /// 结果语音自动播放即将开始（App 层用来打断欢迎语）。
    var onAutoPlayStarted: (() -> Void)?
    /// ESS-535: 用户按住说话时立即触发，用于打断欢迎语音释放音频会话。
    var onPressBegan: (() -> Void)?

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

        recorder.$level
            .receive(on: RunLoop.main)
            .assign(to: &$recordingLevel)

        // ESS-41 B3 深修：播放触发下沉到 speech attach 事件本身，按 request_id
        // 定向交付——不依赖该回合仍是 activeTurn、不依赖 UI 挂载、不依赖回合
        // 未被判失败（语音后到时这三个条件都可能已不成立，旧 onChange 触发
        // 会静默漏播）。
        journal.onSpeechAttached = { [weak self] requestId in
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
            default:
                break
            }
            if state == .completed || state == .cancelled {
                self.retryStore.clear(requestId: requestId)
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
            playing: player.$isPlaying.eraseToAnyPublisher(),
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

    func pressBegan() {
        guard state == .idle else { return }
        errorMessage = nil
        releaseRequestedWhileStarting = false
        if let interrupted = player.currentContext {
            enqueueAutoPlay(interrupted, reason: "recording_interrupted")
        }
        player.stop(reason: "recording_started")
        // ESS-535: interrupt the welcome speech before recording starts
        // so the RealtimePlaybackEngine can own the audio session.
        onPressBegan?()
        state = .recording
        let streaming = voiceStreamingEnabled()
        streamRequestId = streaming ? UUIDv7.generate() : nil
        streamId = streaming ? UUID() : nil
        streamSequence = 0
        streamAborted = false
        WatchHaptics.play(.recordingStarted)
        Task {
            do {
                try await recorder.start(streamHandler: streaming ? { [weak self] payload, end in
                    self?.emitUplinkChunk(payload: payload, end: end)
                } : nil)
                guard state == .recording else {
                    WatchLog.info("recorder", "late_start_cancelled", detail: "state=\(String(describing: state))")
                    recorder.cancel()
                    clearStreamStateAfterAbort()
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
                clearStreamStateAfterAbort()
                errorMessage = Self.recordingErrorDescription(error)
                // ESS-180：录音启动失败也是一次「秒失败」，走分身卡片 + 触觉，
                // 不让手表只有底部一行灰字，然后就没了。
                presentAvatarError(code: "ERR_RECORDER_START", requestId: nil)
            }
        }
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
            clearStreamStateAfterAbort()
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

    func pressEnded() {
        guard state == .recording else { return }
        guard recorder.isRecording else {
            releaseRequestedWhileStarting = true
            WatchLog.info("recorder", "release_deferred_until_started")
            return
        }
        finishRecording()
    }

    private func finishRecording() {
        guard state == .recording else { return }
        state = .finishing
        defer {
            state = .idle
            releaseRequestedWhileStarting = false
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
                // ESS-180：本地失败与 Bridge 侧 ERR_AUDIO_TOO_SHORT 走同一
                // 拟人化卡片；触觉在 presenter 内响一次，此处不再重复播放，
                // 避免同一次「按太短」震两下。
                presentAvatarError(code: "ERR_AUDIO_TOO_SHORT", requestId: nil)
                return
            }
            submit(recording: recording)
        } catch {
            errorMessage = Self.recordingErrorDescription(error)
            // ESS-375: recordingNeverStarted 走 ERR_AUDIO_TOO_SHORT cue
            // （与 too-short guard 统一），让手表看到可行动中文提示而非
            // 通用"录音器错误"卡片。
            let code: String
            if case RecorderError.recordingNeverStarted = error {
                code = "ERR_AUDIO_TOO_SHORT"
            } else {
                code = "ERR_RECORDER_FINISH"
            }
            presentAvatarError(code: code, requestId: nil)
        }
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
        streamRequestId = nil
        streamId = nil
        streamAborted = false
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
        let pcmRecorder = PCMFrameRecorder()
        let playbackEngine = RealtimePlaybackEngine()
        let adapter = WatchRealtimeMediaAdapter(
            recorder: pcmRecorder,
            player: playbackEngine,
            transport: transport,
            fullFileFallback: { [weak self] handle, reason in
                self?.performFullFileFallback(handle: handle, reason: reason)
            },
            logger: { message in
                WatchLog.info("realtime", "adapter", detail: message)
            }
        )
        // ESS-532: clear the pending hold when playback starts, the turn
        // falls back to complete-file, or the turn finishes entirely.
        adapter.onRealtimePendingResolved = { [weak self] in
            self?.realtimePlaybackPending = false
        }
        realtimeAdapter = adapter
        return adapter
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
        flushPendingAutoPlay()
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
    }

    // MARK: - ESS-317 F2.4 再次对话

    /// ESS-317 再次对话的上下文（Q1=a：只传上一轮问+答文本）。
    struct ContinuationContext {
        let parentRequestId: String
        let contextText: String
    }

    /// 当前续聊上下文，供提交语音请求时附加 `parent_request_id`。
    private(set) var continuationContext: ContinuationContext?
}
