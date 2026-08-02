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
    let player = SpeechPlayer()
    let transport: WatchVoiceTransport
    /// ESS-55 超长任务本地通知（JIT 授权 / 结果通知 / 兜底预约 / 点通知直达）。
    let notifier: ResultNotifier
    /// ESS-45：录音 → 等待 → 播放整个回合期间持有 ExtendedRuntimeSession，
    /// 降腕/熄屏不挂起；空闲即释放。
    let sessionKeeper = VoiceSessionKeeper()

    /// 结果语音自动播放即将开始（App 层用来打断欢迎语）。
    var onAutoPlayStarted: (() -> Void)?

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "PlaybackTrigger")
    private let recorder = AudioRecorder()
    /// A release can arrive while AVAudioRecorder is still being prepared. Keep
    /// it pending and finish only after record() has actually succeeded.
    private var releaseRequestedWhileStarting = false
    /// ESS-55：一键重试用的最近一条录音（失败重发不用重新说话）。
    private let retryStore: RetryRecordingStore
    /// ESS-60：跨 WS 重连和 App 重启的自动播放去重账本。
    private let playbackLedger: ResultPlaybackLedger
    /// ESS-55：远端状态 → 触觉 cue 的映射与去重。
    private var cuePolicy = VoiceCuePolicy()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journal = VoiceTurnJournal(directory: base.appendingPathComponent("VoiceTurns", isDirectory: true))
        speechVault = try? EncryptedAudioVault(directory: base.appendingPathComponent("SpeechVault", isDirectory: true))
        transport = WatchVoiceTransport(journal: journal)
        retryStore = RetryRecordingStore(directory: base.appendingPathComponent("RetryCache", isDirectory: true))
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

        // 触觉 cue（ESS-55）：挂在状态入账事件上而非 UI——熄屏/视图未挂载时
        // 结果到达/失败仍能靠震动感知（ESS-45 的 ExtendedRuntimeSession 保证
        // 回合期间 App 还在运行）。成功交付后清理重试缓存。
        // resultArrived 例外：是否播触觉取决于是否发本地通知（同一结果只震
        // 一次），而通知正文需要结果载荷——推迟到 onResultRecorded 决策。
        journal.onStateApplied = { [weak self] requestId, state in
            guard let self else { return }
            if let cue = self.cuePolicy.cue(for: state, requestId: requestId), cue != .resultArrived {
                WatchHaptics.play(cue)
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
                WatchHaptics.play(.resultArrived)
            }
        }

        // 点通知直达该条结果全文（不播额外触觉——通知本身已震过）。
        notifier.onOpenResult = { [weak self] requestId in
            self?.presentResult(requestId: requestId)
        }

        sessionKeeper.bind(
            turns: journal.$turns.eraseToAnyPublisher(),
            playing: player.$isPlaying.eraseToAnyPublisher(),
            recording: $state.map { $0 != .idle }.eraseToAnyPublisher()
        )
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

    private func enqueueAutoPlay(_ requestId: String, reason: String) {
        guard !pendingAutoPlayRequestIds.contains(requestId) else { return }
        pendingAutoPlayRequestIds.append(requestId)
        WatchLog.info(
            "player", "auto_play_queued", requestId: requestId,
            detail: "reason=\(reason) depth=\(pendingAutoPlayRequestIds.count)"
        )
    }

    /// 结果语音落盘后的定向自动播放（ESS-41 B3）。
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
        guard playbackLedger.claim(requestId: requestId) else {
            Self.logger.info("auto-play suppressed: already claimed (request_id=\(requestId, privacy: .public))")
            return
        }
        guard let turn = journal.turn(withId: requestId) else {
            Self.logger.error("auto-play failed: turn not found (request_id=\(requestId, privacy: .public))")
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
        state = .recording
        WatchHaptics.play(.recordingStarted)
        Task {
            do {
                try await recorder.start()
                guard state == .recording else {
                    WatchLog.info("recorder", "late_start_cancelled", detail: "state=\(String(describing: state))")
                    recorder.cancel()
                    return
                }
                if releaseRequestedWhileStarting {
                    WatchLog.info("recorder", "deferred_release_applied")
                    finishRecording()
                }
            } catch {
                state = .idle
                errorMessage = error.localizedDescription
            }
        }
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
                errorMessage = "没听清，请再按住说一次"
                WatchHaptics.play(.turnFailed)
                return
            }
            submit(recording: recording)
        } catch {
            errorMessage = error.localizedDescription
            WatchHaptics.play(.turnFailed)
        }
    }

    /// 提交录音：生成信封发送，同时留一份重试缓存（失败重发不用重新说话）。
    private func submit(recording: AudioRecorder.Recording) {
        let envelope = VoiceRequestEnvelope.voiceRequest(
            audio: VoiceAudioDescriptor(
                codec: "aac",
                sampleRate: AudioRecorder.sampleRate,
                channels: AudioRecorder.channels,
                durationMs: recording.durationMs,
                sha256: VoiceDigest.sha256Hex(of: recording.data)
            )
        )
        retryStore.save(requestId: envelope.requestId, data: recording.data, durationMs: recording.durationMs)
        transport.send(envelope: envelope, recording: recording)
        WatchHaptics.play(.requestSubmitted)
    }

    /// 一键重试（ESS-55）：用缓存的录音换新 request_id 重发，不需要重新说话。
    func retry(turn: VoiceTurnRecord) {
        guard case .failed = turn.phase else { return }
        guard let stored = retryStore.stored(for: turn.requestId) else {
            errorMessage = "这条录音已清理，请重新说一次"
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wristagent-retry-\(UUID().uuidString).m4a")
        guard (try? stored.data.write(to: tempURL, options: .atomic)) != nil else {
            errorMessage = "重试失败，请重新说一次"
            return
        }
        errorMessage = nil
        WatchLog.info("turn", "retry_requested", requestId: turn.requestId)
        submit(recording: AudioRecorder.Recording(
            fileURL: tempURL, data: stored.data, durationMs: stored.durationMs
        ))
    }

    /// 打开 App/回前台时呈现未读结果（ESS-55 流程图节点 C）：
    /// 有语音未播则连播带看，只有文字则直接展示全文；配触觉提醒。
    @discardableResult
    func presentUnreadIfAny() -> Bool {
        guard state == .idle, subtitleSession == nil else { return false }
        guard let turn = journal.firstUnreadResult else { return false }
        WatchHaptics.play(.resultArrived)
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
                self.speechVault?.remove(name: fileName)
                if self.journal.clearSpeech(requestId: requestId, matching: fileName) {
                    self.sessionKeeper.markDelivered(requestId: requestId)
                }
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
}
