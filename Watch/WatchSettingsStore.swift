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
}
