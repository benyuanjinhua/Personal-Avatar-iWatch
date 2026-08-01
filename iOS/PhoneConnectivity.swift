import Combine
import Foundation
import WatchConnectivity

@MainActor
final class PhoneConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = "尚未连接 Apple Watch"
    @Published private(set) var history: [ConversationHistoryEntry] = []
    @Published private(set) var voiceEntries: [VoiceInboxEntry] = []
    @Published private(set) var voiceStatus = "尚未收到语音请求"
    /// ESS-28：加密 outbox + Tailscale 上送 + 结果回传编排器。
    let relay: WristAgentPhoneRelay
    private var pendingConfiguration: AgentConfiguration?
    private let historyStorageKey = "wristagent.phone.conversation.history"
    private let voiceInbox: VoiceRequestInbox?

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        voiceInbox = try? VoiceRequestInbox(directory: base.appendingPathComponent("VoiceInbox", isDirectory: true))
        relay = WristAgentPhoneRelay()
        super.init()
        relay.watchChannel = self
        voiceEntries = voiceInbox?.entries ?? []
        if
            let data = UserDefaults.standard.data(forKey: historyStorageKey),
            let saved = try? JSONDecoder().decode([ConversationHistoryEntry].self, from: data)
        {
            history = saved
        }
    }

    /// Watch 端 transferFile 落地：sha256 校验 + request_id 幂等去重，失败不送往 Mac。
    private func ingestVoiceFile(envelopeData: Data, audioData: Data) {
        guard let inbox = voiceInbox else {
            voiceStatus = "收件箱不可用"
            return
        }
        switch inbox.ingest(envelopeData: envelopeData, audioData: audioData) {
        case .accepted(let envelope, let fileURL):
            voiceEntries = inbox.entries
            voiceStatus = "已接收 \(envelope.requestId.prefix(8))…（\(envelope.audio.durationMs) ms）"
            // 交给 Relay：加密入队 + 回执 Watch + 异步上送 Mac。
            relay.handleAccepted(envelope: envelope, audioData: audioData)
            // 明文副本删除；音频仅以 outbox 密文形式保留（§8）。
            try? FileManager.default.removeItem(at: fileURL)
        case .duplicate(let requestId):
            voiceStatus = "重复请求 \(requestId.prefix(8))…，已幂等丢弃"
            // 幂等重发：不产生第二个请求，由 Relay 重发当前状态。
            if let envelope = try? VoiceRequestEnvelope.decode(from: envelopeData) {
                relay.handleAccepted(envelope: envelope, audioData: audioData)
            }
        case .rejected(let error):
            voiceStatus = "已拒收：\(error.description)"
        }
    }

    func activate() {
        guard WCSession.isSupported() else {
            status = "此设备不支持 Watch Connectivity"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        relay.start()
    }

    func send(_ configuration: AgentConfiguration) {
        pendingConfiguration = configuration
        guard WCSession.default.activationState == .activated else { return }
        do {
            let data = try JSONEncoder().encode(configuration)
            try WCSession.default.updateApplicationContext([ConfigurationMessage.key: data])
            if WCSession.default.isReachable {
                WCSession.default.sendMessageData(data, replyHandler: nil) { [weak self] error in
                    Task { @MainActor in self?.status = "同步失败：\(error.localizedDescription)" }
                }
            }
            status = WCSession.default.isWatchAppInstalled ? "设置已同步到 Apple Watch" : "尚未安装 Watch App"
        } catch {
            status = "无法保存设置：\(error.localizedDescription)"
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.status = "连接失败：\(error.localizedDescription)"
            } else {
                self.status = activationState == .activated ? "已连接" : "正在连接"
                if let configuration = self.pendingConfiguration {
                    self.send(configuration)
                }
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard
            let envelopeData = message[VoiceMessage.envelopeKey] as? Data,
            let envelope = try? VoiceRequestEnvelope.decode(from: envelopeData)
        else { return }
        Task { @MainActor in
            self.voiceStatus = "收到元数据预告 \(envelope.requestId.prefix(8))…，等待音频文件"
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 系统会在本方法返回后删除临时文件，必须同步读出。
        guard let fileData = try? Data(contentsOf: file.fileURL) else { return }
        // Watch 交互日志 chunk（ESS-42）：入上送队列，异步转发 Bridge。
        if let chunkId = file.metadata?[WatchClientLogMessage.fileKey] as? String {
            Task { @MainActor in
                self.relay.clientLogUplink.enqueue(chunkId: chunkId, data: fileData)
            }
            return
        }
        guard let envelopeData = file.metadata?[VoiceMessage.envelopeKey] as? Data else { return }
        Task { @MainActor in
            self.ingestVoiceFile(envelopeData: envelopeData, audioData: fileData)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let fileName = fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in
            self.relay.handleResultAudioTransferFinished(fileName: fileName, error: error)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[HistoryMessage.key] as? Data else { return }
        Task { @MainActor in
            guard let entries = try? JSONDecoder().decode([ConversationHistoryEntry].self, from: data) else {
                return
            }
            self.history = entries
            UserDefaults.standard.set(data, forKey: self.historyStorageKey)
        }
    }
}

// MARK: - Relay → Watch 回执通道（ESS-28）

extension PhoneConnectivity: WatchFeedbackChannel {
    /// 状态/结果短文本：可达时 sendMessage 即时送达；不可达时 transferUserInfo 排队，
    /// 由系统在下次连接时交付（Watch 离线也不丢）。
    func notifyWatch(status: RelayStatusUpdate) {
        guard let data = try? status.jsonData() else { return }
        sendToWatch(key: VoiceMessage.relayStatusKey, data: data)
    }

    func notifyWatch(result: VoiceRelayResultPayload) {
        guard let data = try? result.jsonData() else { return }
        sendToWatch(key: VoiceMessage.resultKey, data: data)
    }

    /// 状态/权限/结果信封 → Watch VoiceTurnJournal（ESS-29 时间线；ESS-38 接通）。
    func notifyWatch(voiceStatus envelope: VoiceStatusEnvelope) {
        guard let data = try? envelope.jsonData() else { return }
        sendToWatch(key: VoiceStatusMessage.envelopeKey, data: data)
    }

    /// 结果语音走系统托管 transferFile；metadata 带含 speechSha256 的信封，
    /// Watch 端（WatchSettingsStore.storeSpeech）校验通过才加密入库并挂到回合。
    func transferSpeech(fileURL: URL, envelope: VoiceStatusEnvelope) {
        guard WCSession.default.activationState == .activated,
              let data = try? envelope.jsonData() else { return }
        WCSession.default.transferFile(fileURL, metadata: [VoiceSpeechMessage.envelopeKey: data])
    }

    private func sendToWatch(key: String, data: Data) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage([key: data], replyHandler: nil) { _ in
                // 即时通道失败退回系统排队通道。
                session.transferUserInfo([key: data])
            }
        } else {
            session.transferUserInfo([key: data])
        }
    }
}
