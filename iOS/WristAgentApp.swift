import SwiftUI

@main
struct WristAgentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = CompanionSettings()
    @StateObject private var connectivity = PhoneConnectivity()

    var body: some Scene {
        WindowGroup {
            CompanionContentView()
                .environmentObject(settings)
                .environmentObject(connectivity)
                .task {
                    connectivity.activate()
                    connectivity.send(settings.configuration)
                }
                .onChange(of: settings.configuration) { _, configuration in
                    connectivity.send(configuration)
                }
                .onChange(of: scenePhase) { _, phase in
                    let value: String
                    switch phase {
                    case .active: value = "active"
                    case .inactive: value = "inactive"
                    case .background: value = "background"
                    @unknown default: value = "unknown"
                    }
                    connectivity.recordLifecycle(value)
                }
        }
    }
}
