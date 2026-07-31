import SwiftUI

@main
struct WristAgentWatchApp: App {
    @StateObject private var settings = WatchSettingsStore()
    @StateObject private var conversation = ConversationViewModel()
    @StateObject private var pushToTalk = PushToTalkController()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(settings)
                .environmentObject(conversation)
                .environmentObject(pushToTalk)
                .task {
                    settings.voiceTransport = pushToTalk.transport
                    settings.activate()
                    conversation.configure(with: settings.configuration)
                    if settings.configuration.autoListen {
                        await conversation.startListening()
                    }
                }
                .onChange(of: settings.configuration) { _, configuration in
                    conversation.configure(with: configuration)
                }
                .onChange(of: conversation.historyEntries, initial: true) { _, entries in
                    settings.sendHistory(entries)
                }
        }
    }
}
