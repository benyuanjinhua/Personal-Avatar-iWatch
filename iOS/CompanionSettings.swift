import Combine
import Foundation

@MainActor
final class CompanionSettings: ObservableObject {
    @Published var configuration: AgentConfiguration {
        didSet { save() }
    }
    @Published var realtimeGatewayURL: String {
        didSet { saveRealtimeGatewayURL() }
    }
    @Published var realtimeCredential: String {
        didSet { saveRealtimeCredential() }
    }
    @Published var realtimeDirectEnabled: Bool {
        didSet { AudioRealtimeAgentFeatureFlag().setDirectPathEnabled(realtimeDirectEnabled) }
    }
    @Published private(set) var realtimeValidationMessage: String?

    private let defaults = UserDefaults.standard
    private let storageKey = "wristagent.configuration"

    init() {
        let flag = AudioRealtimeAgentFeatureFlag()
        realtimeGatewayURL = flag.gatewayURLString
        realtimeCredential = RelayCredentialsStore.read()?.token ?? ""
        realtimeDirectEnabled = flag.isDirectPathEnabled
        realtimeValidationMessage = nil
        SecureTokenStore.delete()
        guard
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(AgentConfiguration.self, from: data)
        else {
            configuration = .demo
            return
        }
        configuration = saved.watchSafe
    }

    var realtimeCredentialSummary: String {
        AudioRealtimeAgentFeatureFlag.redactedCredentialDescription(realtimeCredential)
    }

    private func saveRealtimeGatewayURL() {
        let trimmed = realtimeGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = AudioRealtimeAgentFeatureFlag.validateGatewayURLString(trimmed) {
            realtimeValidationMessage = error.description
            return
        }
        realtimeValidationMessage = nil
        AudioRealtimeAgentFeatureFlag().setGatewayURLString(trimmed)
    }

    private func saveRealtimeCredential() {
        guard let existing = RelayCredentialsStore.read() else {
            realtimeValidationMessage = "请先完成 Mac Relay 配对，以取得 Gateway 已注册的设备 ID。"
            return
        }
        RelayCredentialsStore.save(RelayDeviceCredentials(
            deviceId: existing.deviceId, token: realtimeCredential
        ))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configuration.watchSafe) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
