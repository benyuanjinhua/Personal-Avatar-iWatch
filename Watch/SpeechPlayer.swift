import AVFoundation
import Foundation
import WatchKit

/// 播放上下文（ESS-41 L4 取证）：request_id + 音频来源贯穿 session 激活、
/// player init/start/finish/error 全链日志，与 Bridge/iPhone 侧同一
/// request_id 串成 L1→L4 证据链。
struct SpeechPlaybackContext {
    let requestId: String
    /// welcome | result_direct | result_background
    let source: String

    static let welcome = SpeechPlaybackContext(requestId: "welcome", source: "welcome")
}

/// 语音播放器：只播真实链路语音（Qwen Audio Realtime 生成、AudioPipe 转码的
/// AAC/M4A），不做系统 TTS（ESS-40 起系统 TTS 随静态 demo 一并移除）。
/// ESS-42 取证：会话激活、音频路由、播放器创建、play() 返回、完成/解码
/// 错误/系统中断回调全部走统一 WatchLog，context 为 request_id（结果播放）
/// 或 welcome-<id>（欢迎语），Mac 侧按同一 id 串链。
/// ESS-58 后台音频：watchOS 上锁屏/降腕/切走后还要出声，唯一正路是
/// WKBackgroundModes=audio + .playback 会话带 .longFormAudio 路由策略 +
/// 异步 activate()——纯 setActive(true) 的前台会话在 App 挂起时播放被无声
/// 截断（真机取证 play_started 无 play_finished）。激活失败回落前台会话，
/// 宁可只在前台响也不失声；未播完一律走 onFinish(false) 交由上层保留重播。
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false

    private var audioPlayer: AVAudioPlayer?
    private var currentAudioBytes = 0
    /// 收尾回调：true=完整播完；false=未播完（截断/解码失败/起播失败）。
    private var onFinish: ((Bool) -> Void)?
    /// 当前播放的取证关联 id（request_id / welcome attempt id）。
    private var context: String?
    private var interruptionObserver: NSObjectProtocol?
    /// ESS-154 T2：播放终局告知回调。SpeechPlayer 内部只负责在每次
    /// finishPlayback（含 30s 挂起超时兜底）时按具体终局回调；决策与
    /// 是否发触觉/横幅在 PlaybackEndgamePolicy + PushToTalkController。
    /// 欢迎语与自检不设此回调 → 零开销、行为完全不变。
    /// ESS-233: `bytes` 参数用于让上层区分 interim/fallback（16.8KB 固定大小）
    /// 与真实回复音频（通常 > 100KB）——PushToTalkController 据此决定是否触发
    /// result ACK（interim 未终态，ACK 会被 Bridge 拒 ERR_MISSING_FIELD 并造成
    /// iPhone 无限重试）。0 = 未知（player_init 失败等边缘路径）。
    var onPlaybackEndgame: ((_ requestId: String?, _ bytes: Int, _ endgame: PlaybackEndgame) -> Void)?
    /// ESS-154 T2-4：起播挂起兜底（30s 无 play_started 即认作失败终局）。
    /// 一旦 beginPlayback 成功起播（或任何终局路径先到）即取消。
    private var deferredWatchdog: Task<Void, Never>?
    /// ESS-73：仅作取证留痕，不再闸门任何播放路径——.ended 不保证投递，
    /// 以它为唯一清除路径曾把播放通道永久锁死。清除时机：.ended 到达、
    /// 回前台恢复、任一次激活成功（硬件已归还的实证）。
    private var isSessionInterrupted = false
    /// 异步激活期间又来了新 play()/stop() 时，旧激活回调据此作废。
    private var playbackGeneration = 0
    /// ESS-65 S6 注入缝：「long-form 与 foreground 双激活失败」在真机上无法
    /// 按需制造，装机自检靠它把 ESS-64 的 exhausted 分支（不许 play()、音频
    /// 保留重播）变成可执行断言。命中的策略级不触碰真实 AVAudioSession、
    /// 直接按失败处理——回落顺序、exhausted 判定、finishPlayback 全走真实
    /// 代码。仅 SelfCheckRunner 在 S6 窗口内设置；生产路径恒为空集。
    var selfCheckForcedActivationFailures: Set<String> = []

    /// ESS-228 Phase 1（E1 evidence-only）：实例身份标签。四个长期存活的
    /// SpeechPlayer 各注册一份 interruption observer，仅靠 `context` 无法在
    /// 单条 began/ended 上区分归属；调用方按 `ptt` / `error_speech` / `welcome`
    /// / `selfcheck` 传入固定标签，让 `bridge.log` 里 `began` 事件可按
    /// `instance=` 去重、按 `watch_ts` 分组给出真实频率。
    let instanceTag: String

    /// ESS-224 复审补丁（毕玄 2026-08-03 21:07Z）：进程级 AVAudioSession
    /// 所有权令牌。四个长期存活的 SpeechPlayer 共用一个 session，谁最后
    /// 一次激活成功谁就是当前 owner；`releaseAudioSession` 只有在自己仍是
    /// owner 时才 `setActive(false)`——防止 A 晚到的 finishPlayback 把 B
    /// 刚激活的会话拆掉、静默截断 B 的播放。
    ///
    /// 不使用 `ObjectIdentifier`：实例销毁后其地址可被新实例复用，静态 owner
    /// 若尚未清掉就会发生 ABA，把从未激活的新 player 误判成旧 owner。
    /// UUID 随实例生成且不复用；全部访问点都在 `@MainActor` 上，无需锁。
    /// `internal` 只为让 WatchTests 复现「旧 player 收尾 × 新 player 已激活」
    /// 交错场景。AudioRecorder 走独立 `.playAndRecord` 类别，
    /// `releaseAudioSession` 里有 category 兜底检查——录音已接管时也不误 deactivate。
    let sessionOwnerToken = UUID()
    static var sharedSessionOwner: UUID?

    /// ESS-554：ConversationAudioController 持有会话期间（整个 conversation
    /// `.playAndRecord` 全程激活）返回 true。此时 SpeechPlayer 既不重新
    /// configure/activate（会把持有的 `.playAndRecord` 改成 `.playback`，
    /// 踩塌会话级所有权），也不在收尾时 deactivate（会把别人持有的会话
    /// 拆掉）。AVAudioPlayer 在已激活的 `.playAndRecord` 会话上直接可播。
    /// 由 WatchAppServices.bootstrap 一次性接线；默认 false = 今天的
    /// 回合级行为（回退路径）。
    static var sessionExternallyOwned: () -> Bool = { false }

    var currentContext: String? { isPlaying ? context : nil }

    init(instanceTag: String = "unknown") {
        self.instanceTag = instanceTag
        super.init()
        WatchLog.info(
            "player", "interruption_observer_registered",
            detail: "instance=\(instanceTag) queue=main"
        )
        // 播放中断（电话/系统占用）是真机欢迎语「响一半没了」的候选根因，必须留痕。
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let kind = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            // ESS-228 Phase 1 (E3)：先取 userInfo 详情——`type` 已有，追加
            // `reason` / `options.shouldResume` / `wasSuspended` 三项。
            // `.appWasSuspended` 命中与否是 `.ended 为什么不来` 的关键分水岭。
            let userInfoDetail = Self.interruptionUserInfoDetail(notification.userInfo)
            Task { @MainActor in
                guard let self, let kind else { return }
                self.isSessionInterrupted = kind == .began
                WatchLog.info(
                    "player", "session_interruption", requestId: self.context,
                    detail: "state=\(kind == .began ? "began" : "ended") "
                        + "instance=\(self.instanceTag) "
                        + userInfoDetail + " "
                        + self.activationEvidence()
                )
                // ESS-73：.began 只负责停当前播放并留痕——系统此刻已暂停
                // 硬件，把这一段判「未播完」走 retainForReplay，UI 立即离开
                // 「播放中」、结果卡片给出重播入口。不再挂起等 .ended 恢复：
                // 该通知不保证投递（中断方不归还会话/App 曾挂起都会丢），
                // 等待会把播放通道永久锁死（真机取证：6 条 began 0 条 ended）。
                guard kind == .began else { return }
                self.haltPlaybackForInterruption()
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            WatchLog.info(
                "player", "interruption_observer_removed",
                detail: "instance=\(instanceTag)"
            )
        }
    }

    /// 播放语音片段（ESS-29）。数据只在内存中解密，不落明文文件。
    /// 返回 true 表示播放请求已受理（播放器创建成功、会话激活已在途）；
    /// play_started 在激活完成后落日志。onFinish(true) 仅在完整播完时回调，
    /// 其余路径（起播失败/截断/解码失败）回调 onFinish(false)。
    @discardableResult
    func play(data: Data, context: String? = nil, onFinish: ((Bool) -> Void)? = nil) -> Bool {
        stop()
        self.context = context
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            WatchLog.error(
                "player", "player_init_failed", requestId: context,
                detail: "bytes=\(data.count)", error: error
            )
            self.context = nil
            onFinish?(false)
            // player_init_failed 属于 T2「起播前失败」，同 exhausted 语义（用户
            // 什么也听不到、音频未被消费）；走 T2 追加告知。
            onPlaybackEndgame?(context, data.count, .exhausted)
            return false
        }
        player.delegate = self
        audioPlayer = player
        currentAudioBytes = data.count
        self.onFinish = onFinish
        isPlaying = true
        playbackGeneration += 1
        let generation = playbackGeneration
        armDeferredWatchdog(context: context, generation: generation)
        requestActivationAndPlayback(player, bytes: data.count, generation: generation)
        return true
    }

    /// ESS-154 T2-4：起播挂起兜底。play() 请求发出后 30s 内若激活/播放器都
    /// 没到任何终局（例如 session.activate 回调丢失），落一条 `playback_deferred_timeout`
    /// 取证并按 `.deferredTimeout` 收尾。`play_started` / 任何 finishPlayback 先到即取消。
    private func armDeferredWatchdog(context: String?, generation: Int) {
        deferredWatchdog?.cancel()
        let requestId = context
        deferredWatchdog = Task { [weak self] in
            let seconds = PlaybackEndgamePolicy.deferredTimeoutSeconds
            let nanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.playbackGeneration == generation, self.isPlaying else { return }
                WatchLog.error(
                    "player", "playback_deferred_timeout", requestId: requestId,
                    detail: "threshold_s=\(Int(seconds)) bytes=\(self.currentAudioBytes) "
                        + self.activationEvidence(),
                    code: "ERR_PLAYBACK_DEFERRED_TIMEOUT"
                )
                self.playbackGeneration += 1
                self.audioPlayer?.stop()
                self.finishPlayback(endgame: .deferredTimeout)
            }
        }
    }

    private func cancelDeferredWatchdog() {
        deferredWatchdog?.cancel()
        deferredWatchdog = nil
    }

    private func requestActivationAndPlayback(_ player: AVAudioPlayer, bytes: Int, generation: Int) {
        // ESS-73：新播放请求视为用户意图，直接激活，激活结果即唯一门禁
        // （见 AudioSessionPolicy.nextPlaybackActivationAction）。中断期间
        // 到来的 .began 会经 haltPlaybackForInterruption 收掉本次播放并使
        // generation 失效，无需在此处预判中断状态。
        // ESS-554：会话级持有期间跳过激活——会话已是激活的 `.playAndRecord`，
        // 直接起播；重配类别会踩塌 ConversationAudioController 的所有权。
        if Self.sessionExternallyOwned() {
            WatchLog.info(
                "player", "session_activation_skipped", requestId: context,
                detail: "reason=conversation_owned instance=\(instanceTag) "
                    + activationEvidence()
            )
            beginPlayback(player, bytes: bytes)
            return
        }
        activateSession(context: context) { [weak self] activated in
            guard let self, self.playbackGeneration == generation, self.audioPlayer === player else { return }
            if activated {
                if self.isSessionInterrupted {
                    // 激活成功即证明硬件已归还，残留的中断标志是 .ended
                    // 丢失所致，就地清除。
                    self.isSessionInterrupted = false
                    WatchLog.info(
                        "player", "interruption_flag_cleared", requestId: self.context,
                        detail: "reason=activation_succeeded " + self.activationEvidence()
                    )
                }
                self.beginPlayback(player, bytes: bytes)
            } else {
                WatchLog.error(
                    "player", "playback_activation_exhausted", requestId: self.context,
                    detail: "long_form=false foreground=false bytes=\(bytes) "
                        + self.activationEvidence(),
                    code: "ERR_PLAYBACK_ACTIVATION"
                )
                self.finishPlayback(endgame: .exhausted)
            }
        }
    }

    /// ESS-73：中断 .began 收掉当前播放。系统已抢走硬件，这一段不可能
    /// 继续；判未播完（onFinish(false)）让上层走 retainForReplay，语音留仓
    /// 可重播。generation 递增使在途激活回调作废。
    private func haltPlaybackForInterruption() {
        guard isPlaying, let audioPlayer else { return }
        playbackGeneration += 1
        WatchLog.info(
            "player", "playback_halted_by_interruption", requestId: context,
            detail: String(
                format: "pos=%.2fs duration=%.2fs bytes=%d",
                audioPlayer.currentTime, audioPlayer.duration, currentAudioBytes
            )
        )
        audioPlayer.stop()
        finishPlayback(endgame: .halted)
    }

    /// ESS-58 方案 A：优先 .longFormAudio + 异步 activate()（watchOS 后台
    /// 音频的系统合同）；setCategory 抛错（旧系统/参数拒绝）时回落原有
    /// 前台同步激活，行为等同 ESS-41 B3，不失声但锁屏会被挂起。
    private func activateSession(context: String?, completion: @escaping @MainActor (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        let requestedAt = Date()
        WatchLog.info(
            "player", "session_activation_requested", requestId: context,
            detail: "policy=long_form requested_at=\(Self.milliseconds(requestedAt)) "
                + activationEvidence()
        )
        if selfCheckForcedActivationFailures.contains("long_form") {
            WatchLog.error(
                "player", "session_activation_failed", requestId: context,
                detail: "policy=long_form result=forced_by_selfcheck fallback=foreground "
                    + "requested_at=\(Self.milliseconds(requestedAt)) "
                    + "callback_at=\(Self.milliseconds(Date())) " + activationEvidence(),
                code: "ERR_SELFCHECK_FORCED"
            )
            completion(activateForegroundFallback(context: context))
            return
        }
        do {
            // ESS-226: 用 .default 让 OS 按当前默认输出设备路由——
            // BT 连接 → BT，未连 → Watch 扬声器；不再强偏好 BT。
            try session.setCategory(.playback, mode: .default, policy: .default)
        } catch {
            WatchLog.error(
                "player", "session_policy_rejected", requestId: context,
                detail: "policy=long_form result=category_rejected fallback=foreground "
                    + activationEvidence(), error: error
            )
            completion(activateForegroundFallback(context: context))
            return
        }
        session.activate { [weak self] activated, error in
            Task { @MainActor in
                guard let self else { return }
                let callbackAt = Date()
                // ESS-73：不再依据 isSessionInterrupted 拦截激活结果——激活
                // 成功即硬件可用（标志由调用方清除）；失败自然回落/收尾。
                // ESS-61 F2：activated=false 且 error=nil 也是失败（真机取证
                // 88 秒静默），一律回落前台会话，不许在未激活的会话上 play()。
                if AudioSessionPolicy.playbackActivationSucceeded(activated: activated, hasError: error != nil) {
                    // ESS-224 复审补丁：激活成功即声明本实例为当前 owner，
                    // 覆盖任何更早的 owner 记录。四个长期存活的 player 共用
                    // 同一 session，谁最后激活谁负责最终 deactivate；旧 owner
                    // 的 finishPlayback 到达时会看到 owner 已换人、跳过 release。
                    SpeechPlayer.sharedSessionOwner = self.sessionOwnerToken
                    WatchLog.info(
                        "player", "session_activated", requestId: context,
                        detail: "category=playback policy=long_form activated=true "
                            + "requested_at=\(Self.milliseconds(requestedAt)) "
                            + "callback_at=\(Self.milliseconds(callbackAt)) "
                            + "route=\(Self.routeDescription(session)) " + self.activationEvidence()
                    )
                    completion(true)
                } else {
                    WatchLog.error(
                        "player", "session_activation_failed", requestId: context,
                        detail: "policy=long_form activated=\(activated) fallback=foreground "
                            + "requested_at=\(Self.milliseconds(requestedAt)) "
                            + "callback_at=\(Self.milliseconds(callbackAt)) "
                            + "route=\(Self.routeDescription(session)) " + self.activationEvidence(),
                        error: error
                    )
                    completion(self.activateForegroundFallback(context: context))
                }
            }
        }
    }

    /// ESS-41 B3 原路径：watchOS 冷启动默认会话下 AVAudioPlayer 可能静默无
    /// 输出，播放前必须激活 .playback；激活失败不中止播放尝试，但落取证日志。
    private func activateForegroundFallback(context: String?) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let requestedAt = Date()
        WatchLog.info(
            "player", "session_activation_requested", requestId: context,
            detail: "policy=foreground requested_at=\(Self.milliseconds(requestedAt)) "
                + activationEvidence()
        )
        if selfCheckForcedActivationFailures.contains("foreground") {
            WatchLog.error(
                "player", "session_activation_failed", requestId: context,
                detail: "policy=foreground result=forced_by_selfcheck "
                    + "requested_at=\(Self.milliseconds(requestedAt)) "
                    + "callback_at=\(Self.milliseconds(Date())) " + activationEvidence(),
                code: "ERR_SELFCHECK_FORCED"
            )
            return false
        }
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            // ESS-224 复审补丁：foreground 分支激活成功同样声明 owner，
            // 与 long_form 分支保持对称——否则回落路径下 finishPlayback
            // 永远不会走真 release，session 一直留活。
            SpeechPlayer.sharedSessionOwner = sessionOwnerToken
            WatchLog.info(
                "player", "session_activated", requestId: context,
                detail: "category=playback policy=foreground result=true "
                    + "requested_at=\(Self.milliseconds(requestedAt)) "
                    + "callback_at=\(Self.milliseconds(Date())) "
                    + "route=\(Self.routeDescription(session)) " + activationEvidence()
            )
            return true
        } catch {
            WatchLog.error(
                "player", "session_activation_failed", requestId: context,
                detail: "policy=foreground result=false "
                    + "requested_at=\(Self.milliseconds(requestedAt)) "
                    + "callback_at=\(Self.milliseconds(Date())) "
                    + "route=\(Self.routeDescription(session)) " + activationEvidence(), error: error
            )
            return false
        }
    }

    private func beginPlayback(_ player: AVAudioPlayer, bytes: Int) {
        let started = player.play()
        if started {
            // 起播成功 → 撤挂起兜底（30s 挂起超时只覆盖激活阶段，正常播放
            // 允许 > 30s 长音频，否则会误报）。
            cancelDeferredWatchdog()
            WatchLog.info(
                "player", "play_started", requestId: context,
                detail: String(format: "bytes=%d duration=%.2fs", bytes, player.duration)
            )
        } else {
            WatchLog.error(
                "player", "play_returned_false", requestId: context,
                detail: "bytes=\(bytes) duration=\(player.duration)",
                code: "ERR_PLAY_RETURNED_FALSE"
            )
            finishPlayback(endgame: .playRejected)
        }
    }

    /// 回前台钩子（ESS-58）：后台音频路径正常时声音一直在响，无事发生；
    /// App 曾被挂起截断（播放标记在、播放器已停）则原位续播，续不动才
    /// 判未播完——播放不允许静默消失。
    func recoverAfterForeground() {
        // ESS-73：回前台即清残留中断标志——.ended 不保证投递，Apple 口径
        // 是前台恢复时重新激活探测；硬件是否真的可用交给下一次激活结果。
        if isSessionInterrupted {
            isSessionInterrupted = false
            WatchLog.info(
                "player", "interruption_flag_cleared", requestId: context,
                detail: "reason=foreground_recovery " + activationEvidence()
            )
        }
        guard let audioPlayer else { return }
        let action = PlaybackRecoveryPolicy.onForeground(
            hasActivePlayback: isPlaying,
            playerReportsPlaying: audioPlayer.isPlaying
        )
        guard action == .resume else { return }
        let position = String(
            format: "pos=%.2fs duration=%.2fs", audioPlayer.currentTime, audioPlayer.duration
        )
        if audioPlayer.play() {
            WatchLog.info("player", "play_resumed", requestId: context, detail: position)
        } else {
            WatchLog.error(
                "player", "play_resume_failed", requestId: context,
                detail: position, code: "ERR_PLAY_RESUME"
            )
            finishPlayback(endgame: .resumeFailed)
        }
    }

    /// 当前播放进度快照（ESS-48 字幕对位）。按 context 对账：player 正在播
    /// 别的内容（如欢迎语）或已停止时返回 nil，字幕视图据此进入回看态。
    func progress(matching context: String) -> (time: TimeInterval, duration: TimeInterval)? {
        guard isPlaying, self.context == context, let audioPlayer, audioPlayer.duration > 0 else {
            return nil
        }
        return (audioPlayer.currentTime, audioPlayer.duration)
    }

    func stop(reason: String = "explicit") {
        if isPlaying, let audioPlayer {
            WatchLog.info(
                "player", "stopped", requestId: context,
                detail: String(
                    format: "reason=%@ pos=%.2fs duration=%.2fs",
                    reason, audioPlayer.currentTime, audioPlayer.duration
                )
            )
        }
        cancelDeferredWatchdog()
        playbackGeneration += 1
        audioPlayer?.stop()
        audioPlayer = nil
        currentAudioBytes = 0
        isPlaying = false
        onFinish = nil
        context = nil
    }

    private func finishPlayback(endgame: PlaybackEndgame) {
        cancelDeferredWatchdog()
        let requestId = context
        let bytes = currentAudioBytes  // ESS-233: 在 reset 前捕获，传给 endgame 回调
        audioPlayer = nil
        currentAudioBytes = 0
        isPlaying = false
        context = nil
        let callback = onFinish
        onFinish = nil
        // ESS-224：播放结束后归还共享 AVAudioSession。修复前只清进程内状态、
        // 从不 setActive(false)，`.playback` 会话一直挂在系统上：其它 App
        // 播不出满音量（secondary_silence 一直生效），且没有交还观测点。
        // 释放放在回调之前，让回调里紧接着起播的新 play() 从「无我方持有」
        // 的干净态开始激活；已经不活跃时 setActive(false) 无害，中断 .began
        // 场景下系统已收走硬件，可能抛错——`try?` 吞掉后落 result=false 事件
        // 供排查，不影响后续 T2 决策。
        releaseAudioSession(requestId: requestId, reason: endgame.rawValue)
        // 现有 Bool 契约不变（.retainForReplay / .deliverInterim / .deliverFinal
        // 决策仍走 PlaybackRecoveryPolicy.finishOutcome）；T2 决策通过独立
        // 回调追加，二者互不干扰、welcome/自检不设 T2 回调即零开销。
        callback?(endgame == .success)
        onPlaybackEndgame?(requestId, bytes, endgame)
    }

    /// ESS-224：与 `AudioRecorder.releaseSession` 对称——播放侧收尾也留一条
    /// 交还观测点（`session_released`），Bridge 侧才有证据判「会话是否真的
    /// 交还」。事件名与录音侧一致，`module=player` / `module=recorder` 区分
    /// 归属。
    ///
    /// 复审补丁（毕玄 2026-08-03 21:07Z）：加入两级 owner 校验，防止旧 player
    /// 的晚到收尾把当前活跃 owner 的会话拆掉——
    ///  1. `sharedSessionOwner` 令牌：本实例不是当前 owner 则跳过（`session_release_skipped
    ///     skipped_reason=not_current_owner`）
    ///  2. category 兜底：录音接管后 category 变成 `.playAndRecord`，即使 owner
    ///     校验偶然通过也不 deactivate（`skipped_reason=category_taken_over`）
    /// 跳过路径与真 release 都留取证事件，Bridge 侧可以对账两条路径的比例。
    private func releaseAudioSession(requestId: String?, reason: String) {
        // ESS-554：会话级持有期间绝不 deactivate——会话归
        // ConversationAudioController 所有，点 X 才由它真释放（PD-2）。
        if Self.sessionExternallyOwned() {
            WatchLog.info(
                "player", "session_release_skipped", requestId: requestId,
                detail: "reason=\(reason) skipped_reason=conversation_owned "
                    + "instance=\(instanceTag) " + activationEvidence()
            )
            return
        }
        let session = AVAudioSession.sharedInstance()
        let me = sessionOwnerToken
        guard SpeechPlayer.sharedSessionOwner == me else {
            WatchLog.info(
                "player", "session_release_skipped", requestId: requestId,
                detail: "reason=\(reason) skipped_reason=not_current_owner "
                    + "instance=\(instanceTag) " + activationEvidence()
            )
            return
        }
        // 只要我们仍是记录中的 owner，就先交出令牌——不论下方 setActive 是否
        // 真的执行（category 兜底可能跳过），令牌都不该再指向本实例。
        SpeechPlayer.sharedSessionOwner = nil
        guard session.category == .playback else {
            WatchLog.info(
                "player", "session_release_skipped", requestId: requestId,
                detail: "reason=\(reason) skipped_reason=category_taken_over "
                    + "actual_category=\(session.category.rawValue) "
                    + "instance=\(instanceTag) " + activationEvidence()
            )
            return
        }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            WatchLog.info(
                "player", "session_released", requestId: requestId,
                detail: "reason=\(reason) result=true instance=\(instanceTag) " + activationEvidence()
            )
        } catch {
            WatchLog.error(
                "player", "session_released", requestId: requestId,
                detail: "reason=\(reason) result=false instance=\(instanceTag) " + activationEvidence(),
                error: error
            )
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            WatchLog.info("player", "play_finished", requestId: self.context, detail: "successfully=\(flag)")
            // AVAudioPlayer flag=false 出在 stop() 被外部调用或系统占用未走
            // interruption 通道的边缘场景——用户角度都是「本段没听全」，同
            // .halted 语义交给 T2；不搞新终局枚举增加认知负担。
            self.finishPlayback(endgame: flag ? .success : .halted)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            let requestId = self.context
            WatchLog.error(
                "player", "decode_error", requestId: requestId,
                code: "ERR_AUDIO_DECODE", error: error
            )
            // 保持既有契约：decode 分支不发 onFinish（历史行为，
            // SelfCheck 依赖不吊死上层，见 SelfCheck.swift:34）。仅补 T2 告知回调，
            // 让用户能感知「语音没能播出」——原状态下解码失败零反馈。
            self.cancelDeferredWatchdog()
            let bytes = self.currentAudioBytes  // ESS-233: 捕获 bytes 传给 endgame 回调
            self.isPlaying = false
            self.audioPlayer = nil
            self.currentAudioBytes = 0
            self.onFinish = nil
            self.context = nil
            // ESS-224：解码错误分支不走 finishPlayback，独立补一次会话交还——
            // 与 finishPlayback 里的调用保持同一契约，避免这一条路径漏交还。
            self.releaseAudioSession(requestId: requestId, reason: "decode_error")
            self.onPlaybackEndgame?(requestId, bytes, .exhausted)
        }
    }

    private static func routeDescription(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue)(\($0.portName))" }
            .joined(separator: "+")
        return outputs.isEmpty ? "none" : outputs
    }

    private func activationEvidence() -> String {
        // ESS-228 Phase 1 (E4)：会话/路由状态实时快照。这些字段来自
        // `AVAudioSession.sharedInstance()`，只读、不改变任何行为。
        // watchOS 的 interruption userInfo 大概率不携带抢占方 App 标识，
        // 但 route / other_audio / secondary_silence 组合足以还原「谁在响」。
        let session = AVAudioSession.sharedInstance()
        let category = session.category.rawValue
        let mode = session.mode.rawValue
        let routePolicy = "\(session.routeSharingPolicy.rawValue)"
        let otherAudio = session.isOtherAudioPlaying ? "yes" : "no"
        let secondarySilence = session.secondaryAudioShouldBeSilencedHint ? "yes" : "no"
        let route = Self.routeDescription(session)
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue)(\($0.portName))" }
            .joined(separator: "+")
        let inputsField = inputs.isEmpty ? "none" : inputs
        return "scene_phase=\(Self.scenePhaseDescription()) "
            + "interruption=\(isSessionInterrupted ? "active" : "inactive") "
            + "category=\(category) mode=\(mode) route_share=\(routePolicy) "
            + "other_audio=\(otherAudio) secondary_silence=\(secondarySilence) "
            + "route_out=\(route) route_in=\(inputsField)"
    }

    /// ESS-228 Phase 1 (E3)：从 interruption userInfo 抽取新的取证字段——
    /// `reason` / `should_resume` / `was_suspended`。仅生成字符串，不动
    /// 任何决策路径。
    /// - `reason` 命中 `.appWasSuspended` 是「.ended 从不投递」最直接的
    ///   系统侧解释假说（`began` 在挂起窗口补发、`ended` 在挂起中丢弃）；
    ///   命中 `.default` 则说明是 App 存活时的抢占，方向完全不同。
    /// - `should_resume` 反映系统是否希望我们在 `.ended` 后自动续播——
    ///   对应「回落 vs 主动放弃」的产品决策判断。
    /// - `was_suspended` 键在部分 iOS/watchOS 版本存在；缺失即写 `absent`。
    private static func interruptionUserInfoDetail(_ userInfo: [AnyHashable: Any]?) -> String {
        let rawType = (userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).map(String.init) ?? "nil"
        let reason = interruptionReasonDescription(userInfo)
        let shouldResume = interruptionShouldResumeDescription(userInfo)
        let wasSuspended = interruptionWasSuspendedDescription(userInfo)
        return "type=\(rawType) reason=\(reason) should_resume=\(shouldResume) was_suspended=\(wasSuspended)"
    }

    private static func interruptionReasonDescription(_ userInfo: [AnyHashable: Any]?) -> String {
        guard let userInfo else { return "absent" }
        // AVAudioSessionInterruptionReasonKey 在 iOS 14.5+/watchOS 8+ 存在；
        // 值是 UInt。0=default，1=appWasSuspended（iOS 16 起弃用），
        // 2=builtInMicMuted，3=routeDisconnected（Apple 内部）。命名以运行时
        // 字符串为准，未识别的直接以数值返回，防止我们编未见过的值。
        let key = "AVAudioSessionInterruptionReasonKey"
        if let raw = userInfo[key] as? UInt {
            switch raw {
            case 0: return "default"
            case 1: return "app_was_suspended"
            case 2: return "built_in_mic_muted"
            case 3: return "route_disconnected"
            default: return "unknown(\(raw))"
            }
        }
        if let raw = userInfo[key] as? Int, raw >= 0 {
            return interruptionReasonDescription([key: UInt(raw) as Any])
        }
        return "absent"
    }

    private static func interruptionShouldResumeDescription(_ userInfo: [AnyHashable: Any]?) -> String {
        guard let userInfo else { return "absent" }
        // AVAudioSessionInterruptionOptionKey 是位掩码；`shouldResume` = 1。
        guard let raw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return "absent" }
        return AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) ? "yes" : "no"
    }

    private static func interruptionWasSuspendedDescription(_ userInfo: [AnyHashable: Any]?) -> String {
        guard let userInfo else { return "absent" }
        // AVAudioSessionInterruptionWasSuspendedKey 在部分版本存在（NSNumber）。
        // 使用字面串键，避免不同 SDK 下常量不可用而编译失败。
        let key = "AVAudioSessionInterruptionWasSuspendedKey"
        if let flag = userInfo[key] as? Bool { return flag ? "yes" : "no" }
        if let num = userInfo[key] as? NSNumber { return num.boolValue ? "yes" : "no" }
        return "absent"
    }

    private static func scenePhaseDescription() -> String {
        switch WKApplication.shared().applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}
