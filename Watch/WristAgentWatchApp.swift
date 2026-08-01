import SwiftUI

@main
struct WristAgentWatchApp: App {
    @StateObject private var settings = WatchSettingsStore()
    @StateObject private var pushToTalk = PushToTalkController()
    @StateObject private var welcome = WelcomeGreeter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView(pushToTalk: pushToTalk, welcome: welcome)
                .task {
                    WatchLog.info(
                        "lifecycle", "cold_start",
                        detail: "version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")"
                    )
                    settings.voiceTransport = pushToTalk.transport
                    settings.voiceJournal = pushToTalk.journal
                    settings.speechVault = pushToTalk.speechVault
                    settings.activate()
                    welcome.greetIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    WatchLog.info("lifecycle", "scene_phase", detail: String(describing: newPhase))
                    switch newPhase {
                    case .active: WatchLogShipper.shared.ship(reason: "foreground")
                    case .background: WatchLogShipper.shared.ship(reason: "background")
                    default: break
                    }
                }
        }
    }
}
