import Combine
import Foundation

@MainActor
final class CompanionSettings: ObservableObject {
    @Published var configuration: AgentConfiguration {
        didSet { save() }
    }
    @Published var realtimeGatewayURL: String {
        didSet { saveRealtimeConfiguration() }
    }
    @Published var realtimeCredential: String {
        didSet { saveRealtimeConfiguration() }
    }
    @Published private(set) var realtimeValidationMessage: String?

    private let defaults = UserDefaults.standard
    private let storageKey = "wristagent.configuration"

    init() {
        let flag = AudioRealtimeAgentFeatureFlag()
        realtimeGatewayURL = flag.gatewayURLString
        realtimeCredential = SecureTokenStore.read()
        realtimeValidationMessage = nil
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

    private func saveRealtimeConfiguration() {
        let trimmed = realtimeGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = AudioRealtimeAgentFeatureFlag.validateGatewayURLString(trimmed) {
            realtimeValidationMessage = error.description
            return
        }
        realtimeValidationMessage = nil
        let flag = AudioRealtimeAgentFeatureFlag()
        flag.setGatewayURLString(trimmed)
        flag.setDirectPathEnabled(true)
        SecureTokenStore.save(realtimeCredential)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configuration.watchSafe) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
