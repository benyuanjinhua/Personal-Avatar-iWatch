import Combine
import Foundation

@MainActor
final class CompanionSettings: ObservableObject {
    @Published var configuration: AgentConfiguration {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let storageKey = "wristagent.configuration"

    init() {
        guard
            let data = defaults.data(forKey: storageKey),
            var saved = try? JSONDecoder().decode(AgentConfiguration.self, from: data)
        else {
            configuration = .demo
            return
        }
        saved.bearerToken = SecureTokenStore.read()
        configuration = saved
    }

    private func save() {
        SecureTokenStore.save(configuration.bearerToken)
        var redacted = configuration
        redacted.bearerToken = ""
        guard let data = try? JSONEncoder().encode(redacted) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
