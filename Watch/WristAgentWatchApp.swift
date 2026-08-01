import SwiftUI
import WatchKit

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
                    // ESS-45：降腕后 frontmost 保持从默认 ~8s 延长到 70s，
                    // 与 ExtendedRuntimeSession（VoiceSessionKeeper）叠加覆盖长任务等待。
                    WKExtension.shared().isFrontmostTimeoutExtended = true
                    WatchLog.info("lifecycle", "frontmost_timeout_extended")
                    settings.voiceTransport = pushToTalk.transport
                    settings.voiceJournal = pushToTalk.journal
                    settings.speechVault = pushToTalk.speechVault
                    pushToTalk.onAutoPlayStarted = { welcome.interrupt() }
                    settings.activate()
                    // ESS-55 未读优先：有未读结果直接呈现（触觉 + 全文），欢迎语让路。
                    if !pushToTalk.presentUnreadIfAny() {
                        welcome.greetIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    WatchLog.info("lifecycle", "scene_phase", detail: String(describing: newPhase))
                    switch newPhase {
                    case .active:
                        WatchLogShipper.shared.ship(reason: "foreground")
                        pushToTalk.presentUnreadIfAny()
                    case .background: WatchLogShipper.shared.ship(reason: "background")
                    default: break
                    }
                }
        }
    }
}
