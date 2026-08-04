import Foundation
import WatchConnectivity
import WatchKit

/// App 级服务图（ESS-55 通知链路）：从 SwiftUI 视图生命周期上移到单例——
/// WC 后台唤醒（WKWatchConnectivityRefreshBackgroundTask）时场景不会渲染，
/// 视图 .task 里的接线不执行；服务必须在 delegate 阶段就能就位，
/// 否则挂起状态下结果送到也无人入账、通知发不出。
@MainActor
final class WatchAppServices {
    static let shared = WatchAppServices()
    let settings = WatchSettingsStore()
    let pushToTalk = PushToTalkController()
    let welcome = WelcomeGreeter()
    let selfCheck = SelfCheckRunner()
    /// ESS-280 Debug 灰度：只在 Watch 本机生效，与 `settings`（会同步给
    /// iPhone 的用户配置）严格分开，避免最终用户被开发者态污染。
    let debugSettings = WatchDebugSettings()
    private var bootstrapped = false

    /// 幂等接线 + WCSession 激活；前台启动与后台唤醒共用。
    func bootstrap(reason: String) {
        guard !bootstrapped else { return }
        bootstrapped = true
        settings.voiceTransport = pushToTalk.transport
        settings.voiceJournal = pushToTalk.journal
        settings.speechVault = pushToTalk.speechVault
        pushToTalk.onAutoPlayStarted = { [welcome] in welcome.interrupt() }
        settings.activate()
        WatchLog.info("lifecycle", "services_bootstrapped", detail: reason)
    }
}

/// ESS-55：挂起状态下 iPhone 排队的 transferUserInfo/transferFile（状态与结果）
/// 靠这里的后台任务处理才会被系统投递进来——这是「App 已挂起、结果到达、
/// 手表当场发本地通知」成立的前提。
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { @MainActor in
            WatchAppServices.shared.bootstrap(reason: "did_finish_launching")
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let wcTask = task as? WKWatchConnectivityRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            Task { @MainActor in
                WatchAppServices.shared.bootstrap(reason: "wc_background_task")
                WatchLog.info(
                    "wcsession", "background_task_begin",
                    detail: "pending=\(WCSession.default.hasContentPending)"
                )
                // 给系统投递排队内容留窗口：清空或 8s 超时即完成，防止吊死后台预算。
                let deadline = Date().addingTimeInterval(8)
                while WCSession.default.hasContentPending, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                WatchLog.info(
                    "wcsession", "background_task_end",
                    detail: "pending=\(WCSession.default.hasContentPending)"
                )
                wcTask.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
