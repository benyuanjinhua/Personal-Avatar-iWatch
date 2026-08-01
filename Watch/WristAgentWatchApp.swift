import SwiftUI

@main
struct WristAgentWatchApp: App {
    @StateObject private var settings = WatchSettingsStore()
    @StateObject private var pushToTalk = PushToTalkController()
    @StateObject private var welcome = WelcomeGreeter()

    var body: some Scene {
        WindowGroup {
            WatchContentView(pushToTalk: pushToTalk, welcome: welcome)
                .task {
                    settings.voiceTransport = pushToTalk.transport
                    settings.voiceJournal = pushToTalk.journal
                    settings.speechVault = pushToTalk.speechVault
                    pushToTalk.onAutoPlayStarted = { welcome.interrupt() }
                    settings.activate()
                    welcome.greetIfNeeded()
                }
        }
    }
}
