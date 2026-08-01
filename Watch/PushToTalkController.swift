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

    let journal: VoiceTurnJournal
    let speechVault: EncryptedAudioVault?
    let player = SpeechPlayer()
    let transport: WatchVoiceTransport

    /// 结果语音自动播放即将开始（App 层用来打断欢迎语）。
    var onAutoPlayStarted: (() -> Void)?

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "PlaybackTrigger")
    private let recorder = AudioRecorder()

    /// 结果语音密文的保留期：不再"播放即删除"（退出重进可重播是验收项），
    /// 到期由启动时的清理兜底。
    private static let speechRetention: TimeInterval = 24 * 60 * 60

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journal = VoiceTurnJournal(directory: base.appendingPathComponent("VoiceTurns", isDirectory: true))
        speechVault = try? EncryptedAudioVault(directory: base.appendingPathComponent("SpeechVault", isDirectory: true))
        transport = WatchVoiceTransport(journal: journal)
        _ = speechVault?.purge(olderThan: Self.speechRetention)

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
        Task {
            do {
                try await recorder.start()
            } catch {
                state = .idle
                errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
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

    /// 播放结果语音：从加密仓解密到内存播放。
    ///
    /// ESS-38 复测修正：此前无论播放成败都删密文并清 speechFileName——真机
    /// 播放失败（会话/解码问题）时文件被"提前删除"，既不可重试也无痕迹。
    /// 现在失败只报错并保留密文；成功也不删（退出重进可重播），密文统一由
    /// 保留期清理（`speechRetention`）兜底。
    func playResult(for turn: VoiceTurnRecord) {
        let requestId = turn.requestId
        guard let fileName = turn.speechFileName else {
            WatchLog.error("player", "result_speech_missing", requestId: requestId, code: "ERR_NO_SPEECH_FILE")
            return
        }
        guard let vault = speechVault else {
            WatchLog.error(
                "player", "result_speech_load_failed", requestId: requestId,
                detail: "vault=false", code: "ERR_VAULT_LOAD"
            )
            errorMessage = "结果语音不可用（本地加密仓未就绪）"
            return
        }
        let data: Data
        do {
            data = try vault.load(name: fileName)
        } catch {
            // 文件已被保留期清理或损坏：不可恢复，说明原因并摘掉播放入口，文本仍在。
            WatchLog.error(
                "player", "result_speech_load_failed", requestId: requestId,
                detail: "vault=true", code: "ERR_VAULT_LOAD", error: error
            )
            errorMessage = "结果语音已不可用（\(String(describing: error))）"
            journal.clearSpeech(requestId: requestId)
            return
        }
        player.play(data: data, context: requestId) { [weak self] success in
            guard let self, !success else { return }
            // 失败不删密文、不清 speechFileName：可重试，真机排查也需要留证。
            self.errorMessage = self.player.lastError ?? "语音播放失败"
        }
    }
}
