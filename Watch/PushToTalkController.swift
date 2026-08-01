import Combine
import Foundation

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
        defer { state = .idle }
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
        transport.send(cancel: VoiceCancelEnvelope.cancel(requestId: turn.requestId))
        journal.recordLocal(.cancelled, requestId: turn.requestId, detail: "你取消了本次请求")
    }

    /// 播放结果语音：从加密仓解密到内存播放，播完即删（交付后删除）。
    func playResult(for turn: VoiceTurnRecord) {
        guard let fileName = turn.speechFileName, let vault = speechVault else { return }
        let data: Data
        do {
            data = try vault.load(name: fileName)
        } catch {
            // 文件已被保留期清理或损坏：说明原因并摘掉播放入口，文本仍在。
            errorMessage = "结果语音已不可用（\(String(describing: error))）"
            journal.clearSpeech(requestId: turn.requestId)
            return
        }
        // ESS-38 复测修正：此前无论播放成败都删密文并清 speechFileName——真机
        // 播放失败（会话/解码问题）时文件被"提前删除"，既不可重试也无痕迹。
        // 现在只在失败时报错并保留文件；成功也不删（退出重进可重播），
        // 密文由保留期清理兜底。
        player.play(data: data) { [weak self] success in
            if !success {
                self?.errorMessage = self?.player.lastError ?? "语音播放失败"
            }
        }
    }
}
