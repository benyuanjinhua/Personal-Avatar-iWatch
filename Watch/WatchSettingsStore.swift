import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchSettingsStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var configuration: AgentConfiguration = .demo
    /// 语音传输回调转发目标（WCSession 只允许一个 delegate）。
    weak var voiceTransport: WatchVoiceTransport?
    private let defaults = UserDefaults.standard
    private let storageKey = "wristagent.watch.configuration"

    override init() {
        super.init()
        if
            let data = defaults.data(forKey: storageKey),
            var saved = try? JSONDecoder().decode(AgentConfiguration.self, from: data)
        {
            saved.bearerToken = SecureTokenStore.read()
            configuration = saved
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        if let data = WCSession.default.receivedApplicationContext[ConfigurationMessage.key] as? Data {
            apply(data)
        }
    }

    func sendHistory(_ entries: [ConversationHistoryEntry]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? WCSession.default.updateApplicationContext([HistoryMessage.key: data])
    }

    private func apply(_ data: Data) {
        guard let value = try? JSONDecoder().decode(AgentConfiguration.self, from: data) else { return }
        configuration = value
        SecureTokenStore.save(value.bearerToken)
        var redacted = value
        redacted.bearerToken = ""
        if let redactedData = try? JSONEncoder().encode(redacted) {
            defaults.set(redactedData, forKey: storageKey)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.voiceTransport?.retryPending() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in self.voiceTransport?.handleReachabilityChange(isReachable: isReachable) }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let fileName = fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in self.voiceTransport?.handleTransferFinished(fileName: fileName, error: error) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[ConfigurationMessage.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data
    ) {
        Task { @MainActor in self.apply(messageData) }
    }

    // MARK: - iPhone Relay 回执（ESS-28）

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        forwardRelayPayloads(in: message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        forwardRelayPayloads(in: userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 系统会在本方法返回后删除临时文件，必须同步读出/搬移。
        let payloadData = file.metadata?[VoiceMessage.resultKey] as? Data
        guard payloadData != nil else { return }
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-result-\(UUID().uuidString).m4a")
        try? FileManager.default.moveItem(at: file.fileURL, to: stagedURL)
        Task { @MainActor in
            self.voiceTransport?.handleResultAudioFile(tempURL: stagedURL, payloadData: payloadData)
            try? FileManager.default.removeItem(at: stagedURL)
        }
    }

    private nonisolated func forwardRelayPayloads(in userInfo: [String: Any]) {
        let statusData = userInfo[VoiceMessage.relayStatusKey] as? Data
        let resultData = userInfo[VoiceMessage.resultKey] as? Data
        guard statusData != nil || resultData != nil else { return }
        Task { @MainActor in
            if let statusData { self.voiceTransport?.handleRelayStatus(data: statusData) }
            if let resultData { self.voiceTransport?.handleResultPayload(data: resultData) }
        }
    }
}
