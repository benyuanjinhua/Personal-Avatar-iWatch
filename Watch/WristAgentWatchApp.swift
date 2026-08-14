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
                selfCheck: services.selfCheck,
                debugSettings: services.debugSettings,
                settings: services.settings,
                session: services.sessionController
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
                    // 注意：watchOS 26+ 已废弃此 API（模拟器日志
                    // `frontmostTimeoutExtended is no longer supported`，设了也无效）。
                    // 前台保活已由 WorkoutSessionKeeper（HKWorkoutSession，ESS-540 F6 /
                    // ESS-843）承担，这里保留仅为旧系统兼容，不再作为保活依据。
                    WKExtension.shared().isFrontmostTimeoutExtended = true
                    WatchLog.info("lifecycle", "frontmost_timeout_extended")
                    services.bootstrap(reason: "scene_task")
                    // ESS-688：正常冷启动不得自动占用麦克风或播放自检音频。
                    // 自检只允许从设置页由用户显式触发。
                    services.selfCheck.handleColdStart()
                    // ESS-55 未读优先：有未读结果直接呈现（触觉 + 全文）。
                    // ESS-639：冷启动欢迎语已移除。
                    services.pushToTalk.presentUnreadIfAny()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    WatchLog.info(
                        "lifecycle", "scene_phase",
                        requestId: services.sessionController.activeTurnRequestId,
                        detail: "phase=\(String(describing: newPhase)) "
                            + "session_state=\(String(describing: services.sessionController.state)) "
                            + "session_preserved=\(services.sessionController.isInSession)"
                    )
                    switch newPhase {
                    case .active:
                        // ESS-58：解锁/切回后，被锁屏截断的播放原位续播，
                        // 被 resignedFrontmost 收回的 runtime session 重新持有。
                        services.pushToTalk.player.recoverAfterForeground()
                        services.pushToTalk.sessionKeeper.appDidBecomeActive()
                        // ESS-519：回到前台时若静音保活仍在但无真实播放，
                        // 停止保活以释放系统资源（runtime session 已重启，
                        // 前台态不需额外保活）。
                        if !services.pushToTalk.player.isPlaying {
                            services.pushToTalk.breather.stop(reason: "foreground")
                        }
                        WatchLogShipper.shared.ship(reason: "foreground")
                        services.pushToTalk.evictStaleAudio()
                        // ESS-538：屏灭/后台期间丢弃的录音，回前台补呈现
                        // 「录音被打断」卡片（屏灭时呈现会被自动收起吞掉）。
                        services.pushToTalk.presentInterruptedNoticeIfNeeded()
                        services.pushToTalk.presentUnreadIfAny()
                    case .inactive:
                        // ESS-538：录音进行中降腕息屏——打断流标记，收尾时
                        // 残片按 RecordingInterruptionPolicy 丢弃并提示重说。
                        if !services.sessionController.isInSession {
                            services.pushToTalk.noteScreenOffDuringRecording(phase: "inactive")
                        }
                    case .background:
                        // ESS-598：实时会话由会话级音频持有，scenePhase 变化
                        // 不能等价为用户取消；普通 PTT 仍沿用 ESS-538 的中断
                        // 收尾，避免手势丢失后卡在 recording。
                        if services.sessionController.isInSession {
                            services.sessionController.noteEnteredBackground()
                        } else {
                            services.pushToTalk.noteScreenOffDuringRecording(phase: "background")
                        }
                        WatchLogShipper.shared.ship(reason: "background")
                    default: break
                    }
                }
        }
    }
}
