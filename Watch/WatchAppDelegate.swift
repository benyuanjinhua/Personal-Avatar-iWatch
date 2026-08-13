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
    let selfCheck = SelfCheckRunner()
    /// ESS-280 Debug 灰度：只在 Watch 本机生效，与 `settings`（会同步给
    /// iPhone 的用户配置）严格分开，避免最终用户被开发者态污染。
    let debugSettings = WatchDebugSettings()
    /// ESS-349 接缝：B4 的下行 chunk 接收器。`WatchSettingsStore.streamReceiver`
    /// 是 weak，服务图必须自己持有强引用，否则 `didReceiveMessageData` 解出
    /// chunk 时接收器已经被释放，链路静默断在最后一跳。
    private(set) var streamReceiver: WatchStreamReceiver?
    /// ESS-573（Wave 1 / F1）：会话态主屏生命周期控制器。与其他控制器
    /// 同级持有在服务图——视图挂载与否不影响会话态与计时器存活。
    let sessionController = SessionController()
    /// ESS-540 F6: HKWorkoutSession keep-alive. Starts when entering
    /// conversation, stops when exiting. Keeps app foregrounded on wrist-down.
    let workoutKeeper = WorkoutSessionKeeper()
    private var bootstrapped = false
    /// ESS-650：gate 订阅令牌。服务图与 debugSettings 同生命周期（都挂在
    /// `shared` 上）所以不需要反注册；持有它是为了让「订阅确实建立了」可断言。
    private(set) var voiceBargeInGateToken: UUID?

    /// 幂等接线 + WCSession 激活；前台启动与后台唤醒共用。
    func bootstrap(reason: String) {
        guard !bootstrapped else { return }
        bootstrapped = true
        settings.voiceTransport = pushToTalk.transport
        settings.voiceJournal = pushToTalk.journal
        settings.speechVault = pushToTalk.speechVault
        // ESS-354: uplink gate must read the same knob that gates the downlink
        // receiver — `WatchDebugSettings.isStreamingActive` (Debug 直连/流式).
        // The old wiring pointed at `AgentConfiguration.voiceStreamingV2`, an
        // iPhone-synced field that no UI ever sets, so turning the Watch debug
        // toggle ON opened only the downlink gate; the uplink adapter never
        // started, no `stream.start` reached iPhone, no realtime WSS was built,
        // and every turn ended with `result_synthesized_from_realtime` (m4a).
        pushToTalk.voiceStreamingEnabled = { [weak debugSettings] in
            debugSettings?.isStreamingActive ?? VoiceStreamingGate.defaultEnabled
        }
        // ESS-639: welcome greeting removed; no-op callbacks retained for API stability.
        pushToTalk.onAutoPlayStarted = {}
        pushToTalk.onPressBegan = {}
        // ESS-573：会话模式接线。
        // - 进入：与 PTT 共用同一条录音 + 实时上行链（pressBegan），进入
        //   触觉 .start 由该链既有的 .recordingStarted 兑现，不重复播；
        // - 就绪/失败：只认真实通道事件（首个 uplink ack / 发送失败 /
        //   回退 / 超时），由 SessionController 驱动 connecting →
        //   listening / idle——不在发起后同步宣告 ready；
        // - 退出：点 X / 下滑走 endSessionChannel，真正释放麦克风。
        sessionController.playHaptic = { haptic in
            switch haptic {
            case .ready: WatchHaptics.play(.sessionReady)
            case .exit: WatchHaptics.play(.sessionExit)
            case .failure: WatchHaptics.play(.sessionChannelFailed)
            }
        }
        // ESS-600：会话回合状态机（listening → thinking → speaking → listening
        // 自动轮转、手动打断、超时抢救）的全部接线。抽成函数是为了让
        // WatchTests 能对同一段接线断言——「接线没接上」正是本单第一次
        // 复审被打回的缺陷本身。
        SessionTurnWiring.connect(
            session: sessionController,
            pushToTalk: pushToTalk,
            // 与 PTT 手势同一前置：自检让出音频会话（ESS-65 铁律 3）。
            interruptSelfCheck: { [selfCheck] in selfCheck.interrupt() }
        )
        // ESS-540 F6: HKWorkoutSession keeps app foregrounded during calls.
        sessionController.onSessionStateChange = { [weak self] state in
            switch state {
            case .connecting, .listening:
                self?.pushToTalk.sessionKeeper.setContinuousConversationActive(true)
                self?.workoutKeeper.start()
            case .idle, .disconnecting:
                self?.pushToTalk.sessionKeeper.setContinuousConversationActive(false)
                self?.workoutKeeper.stop()
            case .failed, .hungup:
                // 会话页仍可见且用户可能重试，保持 runtime/workout；真正拆链
                // 进入 disconnecting/idle 时统一释放。
                self?.pushToTalk.sessionKeeper.setContinuousConversationActive(true)
            }
        }
        // ESS-650 F2-4：语音打断开关（默认 OFF）。gate 判定只在会话层读一次。
        sessionController.voiceBargeInEnabled = { [weak debugSettings] in
            debugSettings?.voiceBargeInEnabled ?? false
        }
        // ESS-650 F2-1：同一个 gate 也要喂给音频侧——`.voiceChat`（AEC）
        // 是语音打断的硬件前提，缺这条接线 F2-1 就是死代码。
        pushToTalk.voiceBargeInEnabled = { [weak debugSettings] in
            debugSettings?.voiceBargeInEnabled ?? false
        }
        // gate 每次变化都要闭环：翻到 OFF 必须**即时停采**（不能等本轮回答
        // 播完，否则用户关了开关麦克风还开着）；翻到 ON 时若本轮正在回答，
        // 立刻开始监听，不用等下一轮。
        voiceBargeInGateToken = debugSettings.onVoiceBargeInChanged { [weak sessionController] enabled in
            sessionController?.noteVoiceBargeInGateChanged(enabled: enabled)
        }
        // ESS-554：会话级持有期间，所有 SpeechPlayer（结果语音 / 错误语音 /
        // 欢迎语 / 自检）既不重配会话也不 deactivate——会话归
        // ConversationAudioController 独占，点 X 才由它真释放（PD-2）。
        SpeechPlayer.sessionExternallyOwned = { [pushToTalk] in
            pushToTalk.conversationAudioController?.isAcquired == true
        }
        // ESS-755：StreamingAudioPlayer 同理——会话级持有期间不得重配/释放
        // AVAudioSession，引擎与 playerNode 正常起停但 avtouch 零触碰。
        StreamingAudioPlayer.sessionExternallyOwned = { [pushToTalk] in
            pushToTalk.conversationAudioController?.isAcquired == true
        }
        // ESS-321: pre-warm the adapter so the settings store's downlink
        // dispatch has somewhere to send `audio.delta` payloads even before
        // the first press has fired.
        // ESS-488: skip the pre-warm when the app is hosted as an xctest
        // target. On the GitHub macos-15 runner's watchOS 26 simulator,
        // `AVAudioEngine.connect(playerNode, mainMixerNode, format:)` inside
        // `RealtimePlaybackEngine.init` throws an ObjC exception (`-10868`
        // `AUInterface.mm SetFormat`) at launch and terminates the test host
        // before any `Test Case ... started` is emitted. Real device and app
        // preview paths never see `XCTestConfigurationFilePath`, so the
        // pre-warm still runs there and ESS-321's downlink readiness intent
        // is preserved. Tests that exercise the adapter construct it
        // explicitly via `PushToTalkController.ensureRealtimeAdapter()`
        // (see WatchTests/PushToTalkStreamingStartupTests.swift and
        // WatchTests/PushToTalkDeferredFallbackTests.swift), so nothing
        // downstream loses coverage.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            settings.realtimeAdapter = pushToTalk.ensureRealtimeAdapter()
        }
        // ESS-349 接缝：接上 B4 接收器。降级只记事件——整段 m4a 走的是
        // transferSpeech 可靠通道，与 chunk 流并行，不依赖这里回信。
        let receiver = WatchStreamReceiver(debugSettings: debugSettings) { requestId, reason in
            WatchLog.info(
                "stream_downlink", "stream_fallback",
                requestId: requestId, detail: "\(reason)"
            )
        }
        streamReceiver = receiver
        settings.streamReceiver = receiver
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
