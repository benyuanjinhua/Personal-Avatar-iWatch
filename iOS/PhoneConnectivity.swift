import Combine
import Foundation
import WatchConnectivity

@MainActor
final class PhoneConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = "尚未连接 Apple Watch"
    @Published private(set) var history: [ConversationHistoryEntry] = []
    @Published private(set) var voiceEntries: [VoiceInboxEntry] = []
    @Published private(set) var voiceStatus = "尚未收到语音请求"
    private var pendingConfiguration: AgentConfiguration?
    private let historyStorageKey = "wristagent.phone.conversation.history"
    private let voiceInbox: VoiceRequestInbox?

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        voiceInbox = try? VoiceRequestInbox(directory: base.appendingPathComponent("VoiceInbox", isDirectory: true))
        super.init()
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
        case .accepted(let envelope, _):
            voiceEntries = inbox.entries
            voiceStatus = "已接收 \(envelope.requestId.prefix(8))…（\(envelope.audio.durationMs) ms）"
        case .duplicate(let requestId):
            voiceStatus = "重复请求 \(requestId.prefix(8))…，已幂等丢弃"
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
        guard let audioData = try? Data(contentsOf: file.fileURL) else { return }
        guard let envelopeData = file.metadata?[VoiceMessage.envelopeKey] as? Data else { return }
        Task { @MainActor in
            self.ingestVoiceFile(envelopeData: envelopeData, audioData: audioData)
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
