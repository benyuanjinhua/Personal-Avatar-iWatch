import SwiftUI
import WatchKit

@main
struct WristAgentWatchApp: App {
    /// ESS-55：后台 WC 唤醒（挂起时结果送达 → 当场发通知）依赖 delegate；
    /// 服务图上移到 WatchAppServices 单例，前台/后台启动共用一套接线。
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    private let services = WatchAppServices.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView(pushToTalk: services.pushToTalk, welcome: services.welcome)
                .task {
                    WatchLog.info(
                        "lifecycle", "cold_start",
                        detail: "version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")"
                    )
                    // ESS-45：降腕后 frontmost 保持从默认 ~8s 延长到 70s，
                    // 与 ExtendedRuntimeSession（VoiceSessionKeeper）叠加覆盖长任务等待。
                    WKExtension.shared().isFrontmostTimeoutExtended = true
                    WatchLog.info("lifecycle", "frontmost_timeout_extended")
                    services.bootstrap(reason: "scene_task")
                    // ESS-55 未读优先：有未读结果直接呈现（触觉 + 全文），欢迎语让路。
                    if !services.pushToTalk.presentUnreadIfAny() {
                        services.welcome.greetIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    WatchLog.info("lifecycle", "scene_phase", detail: String(describing: newPhase))
                    switch newPhase {
                    case .active:
                        WatchLogShipper.shared.ship(reason: "foreground")
                        services.pushToTalk.presentUnreadIfAny()
                    case .background: WatchLogShipper.shared.ship(reason: "background")
                    default: break
                    }
                }
        }
    }
}
