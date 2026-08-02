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
                    // ESS-56：版本号在本工程恒为 0.1.0/1，分不出新旧安装——R3 就是
                    // 因此在旧 build 上白测了一轮。改为上报可执行文件时间戳，
                    // Bridge 侧据此在开测前判定表端 build 是否覆盖待验收 commit。
                    WatchLog.info("lifecycle", "cold_start", detail: BuildFingerprint.current().detail)
                    // ESS-45：降腕后 frontmost 保持从默认 ~8s 延长到 70s，
                    // 与 ExtendedRuntimeSession（VoiceSessionKeeper）叠加覆盖长任务等待。
                    WKExtension.shared().isFrontmostTimeoutExtended = true
                    WatchLog.info("lifecycle", "frontmost_timeout_extended")
                    settings.voiceTransport = pushToTalk.transport
                    settings.voiceJournal = pushToTalk.journal
                    settings.speechVault = pushToTalk.speechVault
                    pushToTalk.onAutoPlayStarted = { welcome.interrupt() }
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
