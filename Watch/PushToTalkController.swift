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
    @Published var subtitleSession: SubtitleSession?

    let journal: VoiceTurnJournal
    let speechVault: EncryptedAudioVault?
    let player = SpeechPlayer()
    let transport: WatchVoiceTransport
    /// ESS-45：录音 → 等待 → 播放整个回合期间持有 ExtendedRuntimeSession，
    /// 降腕/熄屏不挂起；空闲即释放。
    let sessionKeeper = VoiceSessionKeeper()
    /// 触觉反馈（ESS-53 §4）：录音启停直接触发；回合变迁由 feedbackPolicy diff 驱动。
    let haptics = WatchHaptics()
    private var feedbackPolicy = TurnFeedbackPolicy()
    private var cancellables = Set<AnyCancellable>()
    /// 内存重播缓存（ESS-53 §6）：仅保留最近一条已播结果语音。加密仓照删、
    /// ACK 照发（交付协议不变），本次会话内可重播；退出 App 即失。
    private var lastPlayedAudio: (requestId: String, data: Data)?

    /// 结果语音自动播放即将开始（App 层用来打断欢迎语）。
    var onAutoPlayStarted: (() -> Void)?

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "PlaybackTrigger")
    private let recorder = AudioRecorder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journal = VoiceTurnJournal(directory: base.appendingPathComponent("VoiceTurns", isDirectory: true))
        speechVault = try? EncryptedAudioVault(directory: base.appendingPathComponent("SpeechVault", isDirectory: true))
        transport = WatchVoiceTransport(journal: journal)

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

        sessionKeeper.bind(
            turns: journal.$turns.eraseToAnyPublisher(),
            playing: player.$isPlaying.eraseToAnyPublisher(),
            recording: $state.map { $0 != .idle }.eraseToAnyPublisher()
        )

        // 触觉由状态机变迁驱动（ESS-53 §4）：不依赖 UI 挂载；首次快照静默 seed，
        // 重开 App 恢复历史回合不补发触觉。
        journal.$turns
            .receive(on: RunLoop.main)
            .sink { [weak self] turns in
                guard let self else { return }
                let events = self.feedbackPolicy.observe(
                    turns: turns.map { ($0.requestId, $0.currentState) }
                )
                events.forEach { self.haptics.play(event: $0) }
            }
            .store(in: &cancellables)
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
    private var pendingAutoPlayRequestId: String?

    /// 结果语音落盘后的定向自动播放（ESS-41 B3）。
    private func autoPlayResult(requestId: String) {
        guard state == .idle else {
            Self.logger.info("auto-play deferred: recording in progress (request_id=\(requestId, privacy: .public))")
            pendingAutoPlayRequestId = requestId
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
        guard let requestId = pendingAutoPlayRequestId else { return }
        pendingAutoPlayRequestId = nil
        autoPlayResult(requestId: requestId)
    }

    func pressBegan() {
        guard state == .idle else { return }
        errorMessage = nil
        player.stop()
        state = .recording
        haptics.playRecordStarted()
        Task {
            do {
                try await recorder.start()
            } catch {
                state = .idle
                errorMessage = Self.friendlyRecorderMessage(for: error)
                haptics.playLocalFailure()
            }
        }
    }

    func pressEnded() {
        guard state == .recording else { return }
        state = .finishing
        defer {
            state = .idle
            flushPendingAutoPlay()
        }
        do {
            let recording = try recorder.finish()
            haptics.playRecordStopped()
            let envelope = VoiceRequestEnvelope.voiceRequest(
                audio: VoiceAudioDescriptor(
                    codec: "aac",
                    sampleRate: AudioRecorder.sampleRate,
                    channels: AudioRecorder.channels,
                    durationMs: recording.durationMs,
                    sha256: VoiceDigest.sha256Hex(of: recording.data)
                )
            )
            transport.send(envelope: envelope, recording: recording)
        } catch {
            errorMessage = Self.friendlyRecorderMessage(for: error)
            haptics.playLocalFailure()
        }
    }

    /// 技术错误 → 人话（ESS-53 §5）：RecorderError 自带可读文案；
    /// 其余（AVAudioSession 激活失败等）不把系统原文抛给用户。
    static func friendlyRecorderMessage(for error: Error) -> String {
        if let recorderError = error as? RecorderError {
            return recorderError.localizedDescription
        }
        return "无法开始录音，请稍后重试"
    }

    func pressCancelled() {
        guard state == .recording else { return }
        recorder.cancel()
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

    /// 结果语音当前是否可播/可重播（加密仓仍有文件，或命中本会话内存重播缓存）。
    func hasPlayableAudio(for turn: VoiceTurnRecord) -> Bool {
        turn.speechFileName != nil || lastPlayedAudio?.requestId == turn.requestId
    }

    /// 结果卡片播放按钮（ESS-53 §6）：播放中→暂停，暂停中→继续，否则（重新）播放。
    func togglePlayback(for turn: VoiceTurnRecord) {
        if player.progress(matching: turn.requestId) != nil {
            if player.isPlaying {
                player.pause()
            } else {
                player.resume()
            }
            return
        }
        playResult(for: turn)
    }

    /// 播放结果语音：从加密仓解密到内存播放，播完即删（交付后删除）。
    /// 播完后加密仓文件已删时回落到内存重播缓存（ESS-53 §6），本次会话内可重播。
    func playResult(for turn: VoiceTurnRecord) {
        let requestId = turn.requestId
        guard let data = loadPlayableAudio(for: turn) else { return }
        lastPlayedAudio = (requestId, data)
        let fileName = turn.speechFileName
        let started = player.play(data: data, context: requestId) { [weak self] in
            if let fileName {
                self?.speechVault?.remove(name: fileName)
                self?.journal.clearSpeech(requestId: requestId)
            }
            // ESS-45×ESS-46：只有终态回合的结果语音播完才算交付——interim
            // （回合仍在处理中）播完不算，否则 completed 后等待最终语音的
            // 120s grace 持有会被跳过，App 挂起、最终结果播不出来。
            if self?.journal.turn(withId: requestId)?.currentState.isTerminal == true {
                self?.sessionKeeper.markDelivered(requestId: requestId)
            }
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

    /// 字幕视图重播入口（ESS-53 §6）。
    func replayResult(requestId: String) {
        guard let turn = journal.turn(withId: requestId) else { return }
        playResult(for: turn)
    }

    /// 取可播放的音频数据：优先加密仓；播完已删时回落内存重播缓存（ESS-53 §6）。
    private func loadPlayableAudio(for turn: VoiceTurnRecord) -> Data? {
        let requestId = turn.requestId
        if let fileName = turn.speechFileName {
            if let vault = speechVault, let data = try? vault.load(name: fileName) {
                return data
            }
            WatchLog.error(
                "player", "result_speech_load_failed", requestId: requestId,
                detail: "vault=\(speechVault != nil)", code: "ERR_VAULT_LOAD"
            )
        }
        if let cached = lastPlayedAudio, cached.requestId == requestId {
            WatchLog.info("player", "replay_from_memory", requestId: requestId, detail: "bytes=\(cached.data.count)")
            return cached.data
        }
        WatchLog.error("player", "result_speech_missing", requestId: requestId, code: "ERR_NO_SPEECH_FILE")
        return nil
    }
}
