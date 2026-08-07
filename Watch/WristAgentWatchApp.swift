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
            WatchContentView(
                pushToTalk: services.pushToTalk,
                welcome: services.welcome,
                selfCheck: services.selfCheck,
                debugSettings: services.debugSettings,
                settings: services.settings
            )
                .task {
                    // ESS-56：版本号在本工程恒为 0.1.0/1，分不出新旧安装——R3 就是
                    // 因此在旧 build 上白测了一轮。改为上报可执行文件时间戳，
                    // Bridge 侧据此在开测前判定表端 build 是否覆盖待验收 commit。
                    WatchLog.info("lifecycle", "cold_start", detail: BuildFingerprint.current().detail)
                    // ESS-280 观测（PM 明确要求「排障时得知道他当时开没开」）：
                    // 冷启动补落一次当前开关值，Bridge 侧按 build 反向对账。
                    services.debugSettings.logStateAtLaunch()
                    // ESS-45：降腕后 frontmost 保持从默认 ~8s 延长到 70s，
                    // 与 ExtendedRuntimeSession（VoiceSessionKeeper）叠加覆盖长任务等待。
                    WKExtension.shared().isFrontmostTimeoutExtended = true
                    WatchLog.info("lifecycle", "frontmost_timeout_extended")
                    services.bootstrap(reason: "scene_task")
                    // ESS-65 / G9：新 build 首启先跑装机音频自检（同 build 只跑一次），
                    // 结束前不放欢迎语/未读播放——两者会与自检抢同一个音频会话。
                    // 用户按住说话可随时打断自检（SelfCheckRunner.interrupt）。
                    await services.selfCheck.autoRunIfNeeded()
                    // ESS-55 未读优先：有未读结果直接呈现（触觉 + 全文），欢迎语让路。
                    if !services.pushToTalk.presentUnreadIfAny() {
                        services.welcome.greetIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    WatchLog.info("lifecycle", "scene_phase", detail: String(describing: newPhase))
                    switch newPhase {
                    case .active:
                        // ESS-58：解锁/切回后，被锁屏截断的播放原位续播，
                        // 被 resignedFrontmost 收回的 runtime session 重新持有。
                        services.pushToTalk.player.recoverAfterForeground()
                        services.pushToTalk.sessionKeeper.appDidBecomeActive()
                        WatchLogShipper.shared.ship(reason: "foreground")
                        services.pushToTalk.evictStaleAudio()
                        // ESS-538：抬腕后补呈现「锁屏打断了录音」
                        // （锁屏当下卡片/语音都到不了用户）。
                        services.pushToTalk.presentLockInterruptNoticeIfNeeded()
                        services.pushToTalk.presentUnreadIfAny()
                    case .inactive, .background:
                        // ESS-538：录音进行中锁屏 → 立即主动收尾（抢救提交或
                        // 丢弃 + 抬腕告知），不再让残片在松手时被当正常录音提交。
                        services.pushToTalk.recordingInterruptedByLock(
                            phase: String(describing: newPhase)
                        )
                        if newPhase == .background {
                            WatchLogShipper.shared.ship(reason: "background")
                        }
                    }
                }
        }
    }
}
