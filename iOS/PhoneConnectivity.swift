import Combine
import Foundation
import WatchConnectivity

@MainActor
final class PhoneConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = "尚未连接 Apple Watch"
    @Published private(set) var history: [ConversationHistoryEntry] = []
    private var pendingConfiguration: AgentConfiguration?
    private let historyStorageKey = "wristagent.phone.conversation.history"

    override init() {
        super.init()
        if
            let data = UserDefaults.standard.data(forKey: historyStorageKey),
            let saved = try? JSONDecoder().decode([ConversationHistoryEntry].self, from: data)
        {
            history = saved
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
