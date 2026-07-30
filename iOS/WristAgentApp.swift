import SwiftUI

@main
struct WristAgentApp: App {
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
        }
    }
}

