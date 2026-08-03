import AVFoundation
import Combine
import Foundation
import WatchKit

/// 装机音频自检（ESS-65 / G9）：新 build 首启自动跑一遍「录音 → 播放 →
/// 播放后立刻录音 → 录音后立刻播放 → 会话状态复位 → 中断残留 → 双激活
/// 失败」（S1/S2/S3/S3R/S4/S5/S6），结论经 WatchLog → Bridge 回传，
/// Bridge 侧 `Scripts/watch-smoke-gate.mjs` 一条命令判定 PASS/FAIL，
/// 不 PASS 不进入人工验收。
///
/// 铁律（PD 决策，见 ESS-65 §三）：
/// 1. 不污染生产数据——用自有 AudioRecorder/SpeechPlayer 实例直接跑，
///    不发 voice request、不产生 turn、不写 outbox；自检录音断言完即删；
/// 2. 权限缺失判 inconclusive（不是代码坏了），但同样不放行；
/// 3. 自检失败绝不锁死 App——只落日志与提示卡片，业务入口照常可用；
/// 4. 自检期间 UI 有明确提示（WatchContentView 横幅）；
/// 5. 可手动重跑（结果卡片上的按钮）。
///
/// 自检必须走真实链路组件（AudioRecorder / SpeechPlayer 原类原路径），
/// 否则测的是「另一套代码」，ESS-61 那类会话状态缺陷照样漏网。
@MainActor
final class SelfCheckRunner: ObservableObject {
    enum Stage: Equatable {
        case idle
        case running(step: SelfCheckPolicy.Step)
        case finished(SelfCheckPolicy.Outcome)
    }

    static let lastRunDefaultsKey = "wristagent.watch.selfcheck.last-run"
    /// 单步录音时长：够产生非空音频文件、又不拖长总时长。
    private static let recordSeconds: Double = 0.6
    /// S2 播放看门狗：资产约 3.3s，留出会话激活与回调的余量。
    /// 解码错误路径不回调 onFinish（SpeechPlayer 现状），靠它兜底不吊死。
    private static let playbackTimeout: Double = 10

    @Published private(set) var stage: Stage = .idle

    private let recorder = AudioRecorder()
    private let player = SpeechPlayer()
    private let defaults: UserDefaults
    private let signals = SignalCounter()
    private var interrupted = false
    private var running = false
    /// S2 等待中的收尾闭包：正常由播放回调/看门狗触发，interrupt() 也可直接触发。
    private var pendingPlaybackFinish: ((PlaybackWaitResult) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isRunning: Bool {
        if case .running = stage { return true }
        return false
    }

    /// 自检没通过（fail/inconclusive）时给 UI 的提示与重跑入口。
    var pendingAttention: SelfCheckPolicy.Outcome? {
        guard case .finished(let outcome) = stage, outcome != .pass else { return nil }
        return outcome
    }

    // MARK: - 入口

    /// 冷启动入口：同一 build 只跑一次（inconclusive 例外，见 SelfCheckPolicy）。
    /// 返回时自检已结束（或被打断/无需跑），调用方再放行欢迎语/未读结果，
    /// 避免自检与欢迎语抢同一个音频会话。
    func autoRunIfNeeded() async {
        let fingerprint = BuildFingerprint.current().detail
        guard SelfCheckPolicy.shouldAutoRun(currentFingerprint: fingerprint, lastRun: loadLastRun()) else {
            WatchLog.info("selfcheck", "selfcheck_skipped", detail: "reason=same_build \(fingerprint)")
            return
        }
        await run(fingerprint: fingerprint)
    }

    /// 手动重跑（结果卡片按钮）：不受「同 build 只跑一次」限制。
    func rerun() {
        guard !running else { return }
        Task { await self.run(fingerprint: BuildFingerprint.current().detail) }
    }

    /// 用户按住说话/欢迎语需要让路时打断自检：立即释放麦克风与播放器，
    /// 结论记 inconclusive（下次启动自动补跑）。
    func interrupt() {
        guard running else { return }
        interrupted = true
        recorder.cancel()
        player.selfCheckForcedActivationFailures = []
        player.stop(reason: "selfcheck_interrupted")
        pendingPlaybackFinish?(.interrupted)
    }

    // MARK: - 主流程

    private func run(fingerprint: String) async {
        guard !running else { return }
        running = true
        interrupted = false
        WatchLog.info("selfcheck", "selfcheck_started", detail: SelfCheckPolicy.startedDetail(fingerprint: fingerprint))
        WatchLog.setObserver { [signals] module, event, detail, code in
            // 只关心真实链路组件的会话/播放信号；自检自身的日志不计入。
            guard module != "selfcheck" else { return }
            signals.record(event: event, detail: detail, code: code)
        }

        let outcome = await executeSteps()

        WatchLog.setObserver(nil)
        finish(outcome: outcome, fingerprint: fingerprint)
        running = false
    }

    private func executeSteps() async -> SelfCheckPolicy.Outcome {
        // S1 录音可用（ESS-52/54）：静默录 0.6s，产出非空文件。
        if let failure = await recordStep(.record) { return failure }

        // S2 播放可用（ESS-61 缺陷 B）：播内置资产，会话必须真正激活、
        // play() 不得返回 false。资产缺失是打包缺陷，按 S2 fail 报。
        guard let assetData = loadAsset() else {
            beginStep(.playback)
            return failStep(.playback, startedAt: Date(), fallbackCode: "ERR_SELFCHECK_ASSET_MISSING")
        }
        // ESS-137：录音刚结束立即起播在真机上会 !res(561145203)——recorder.finish()
        // 里 setActive(false, .notifyOthersOnDeactivation) 只是提交请求，硬件真正
        // 归还到 setCategory(.playback, .longFormAudio) 可用之间有毫秒级延迟。
        // 让实际的 SpeechPlayer.activateSession 先跑一遍会话让出探测，
        // 直到探测通过或超时。模拟器上一发即中；真机上大多在 100–400ms 内清空。
        await yieldRecordSessionForPlayback(prevStep: .record, nextStep: .playback)
        if let failure = await playbackStep(.playback, data: assetData) { return failure }

        // S3 播放→录音交替（ESS-61 缺陷 A，-50）：播放刚结束立刻再录，
        // 且全程 session_activation_failed 出现 0 次。
        if let failure = await recordStep(.playThenRecord) { return failure }

        // S3R 录音→播放交替（ESS-72 的 S3'，真机事故 09:12:15→09:12:17 的
        // 复现链）：S3 的录音刚结束立刻播放——录音会话未交还时两级激活
        // 全 !res(561145203)、play_started 为 0，本步在装机时就拦下。
        // ESS-137：与 S1→S2 同因同治，让出屏障也要在这里跑一次。
        await yieldRecordSessionForPlayback(prevStep: .playThenRecord, nextStep: .recordThenPlay)
        if let failure = await playbackStep(.recordThenPlay, data: assetData) { return failure }

        // S4 会话状态复位（ESS-61 根因）：.longFormAudio 路由策略不得残留。
        if let failure = sessionResetStep() { return failure }

        // S5 中断残留（ESS-73）：合成 .began 后不投 .ended，新播放不得被
        // 挂起等待，必须直接激活并出声。
        if let failure = await interruptionGateStep(data: assetData) { return failure }

        // S6 双激活失败（ESS-64 验收 3）：两级激活都失败时不得 play()，
        // 落 exhausted 取证，音频按未播完保留可重播。
        if let failure = await dualActivationFailureStep(data: assetData) { return failure }

        return .pass
    }

    private func loadAsset() -> Data? {
        guard let url = Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// S1/S3 共用的录音步骤。失败返回 Outcome，通过返回 nil。
    private func recordStep(_ step: SelfCheckPolicy.Step) async -> SelfCheckPolicy.Outcome? {
        beginStep(step)
        let startedAt = Date()
        do {
            try await recorder.start()
        } catch RecorderError.permissionDenied {
            // 权限缺失不是代码缺陷：判 inconclusive、不放行，文案指向授权。
            return .inconclusive(.micPermissionMissing)
        } catch {
            if interrupted { return .inconclusive(.interrupted) }
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_RECORD_START")
        }
        if interrupted {
            recorder.cancel()
            return .inconclusive(.interrupted)
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.recordSeconds * 1_000_000_000))
        if interrupted {
            recorder.cancel()
            return .inconclusive(.interrupted)
        }
        guard let recording = try? recorder.finish(), !recording.data.isEmpty else {
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_NO_RECORDING")
        }
        // 铁律 1：自检录音断言完成后立即删除，不留任何生产可见痕迹。
        try? FileManager.default.removeItem(at: recording.fileURL)
        guard signals.count(of: "session_activation_failed") == 0 else {
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_SESSION_ACTIVATION")
        }
        passStep(step, startedAt: startedAt)
        return nil
    }

    /// S2/S3R 共用的播放步骤：播内置资产，会话必须真正激活、play() 不得
    /// 返回 false、两级激活不得耗尽（S3R 专拦 ESS-72 的 !res）。
    private func playbackStep(
        _ step: SelfCheckPolicy.Step, data: Data
    ) async -> SelfCheckPolicy.Outcome? {
        beginStep(step)
        let startedAt = Date()
        let waited = await awaitPlayback(data: data)
        switch waited {
        case .interrupted:
            return .inconclusive(.interrupted)
        case .timeout:
            player.stop(reason: "selfcheck_timeout")
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_SELFCHECK_TIMEOUT")
        case .startFailed, .truncated:
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_PLAY_INCOMPLETE")
        case .finished:
            break
        }
        // activated == true 的判据：激活失败（含 activated=false 回落前台）与
        // play() 返回 false 都会由真实链路落对应事件，这里断言它们零出现。
        guard
            signals.count(of: "session_activation_failed") == 0,
            signals.count(of: "play_returned_false") == 0,
            signals.count(of: "playback_activation_exhausted") == 0
        else {
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_SESSION_ACTIVATION")
        }
        passStep(step, startedAt: startedAt)
        return nil
    }

    private func sessionResetStep() -> SelfCheckPolicy.Outcome? {
        let step = SelfCheckPolicy.Step.sessionReset
        beginStep(step)
        let startedAt = Date()
        let session = AVAudioSession.sharedInstance()
        let policy = session.routeSharingPolicy
        WatchLog.info(
            "selfcheck", "session_state",
            detail: "category=\(session.category.rawValue) route_policy=\(policy.rawValue)"
        )
        guard policy != .longFormAudio else {
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_ROUTE_POLICY_RESIDUE")
        }
        passStep(step, startedAt: startedAt)
        return nil
    }

    // MARK: - S5/S6：中断残留与双激活失败（ESS-73 / ESS-64）

    /// S5 中断残留（ESS-73 → ESS-228）：合成 .began 且**不投 .ended**，
    /// 复现真机上「.ended 丢失」（bridge.log 全窗口：began 209 / ended 0）。
    /// 此时发起新播放必须直接激活并起播——不得出现 playback_deferred，
    /// 也不得依赖任何缓存中断标志（ESS-228 起 SpeechPlayer 不再缓存该状态，
    /// 共享会话状态就是 AVAudioSession.sharedInstance() 本身）。断言就是：
    /// 残留 .began 下 play_started 必须到、defer 事件必须为 0。
    private func interruptionGateStep(data: Data) async -> SelfCheckPolicy.Outcome? {
        let step = SelfCheckPolicy.Step.interruptionGate
        beginStep(step)
        let startedAt = Date()
        // 合成通知只落一次 session_interruption 证据；ESS-228 后不再改动
        // 任何实例状态，因此不必再补一条 ended 清理残留。
        defer { Self.postSyntheticInterruption(.ended) }

        Self.postSyntheticInterruption(.began)
        // 通知回调经 Task 跳一拍主线程，给证据落位留一个节拍。
        try? await Task.sleep(nanoseconds: 150_000_000)
        if interrupted { return .inconclusive(.interrupted) }

        let requestTs = Self.epochMs()
        player.play(data: data, context: "selfcheck-s5")
        let started = await waitFor(timeout: 6) { [signals] in signals.count(of: "play_started") > 0 }
        let callbackTs = signals.firstTimestamp(of: "play_started").map { Int64($0.timeIntervalSince1970 * 1000) }
        let deferredSeen = signals.count(of: "playback_deferred")
        WatchLog.info(
            "selfcheck", "selfcheck_observation",
            detail: SelfCheckPolicy.observationDetail(
                step: step, phase: "stale_flag_play", scenePhase: Self.scenePhase(),
                interruptionState: .began, requestTs: requestTs, callbackTs: callbackTs,
                longFormResult: activationResult(policy: "long_form"),
                fallbackResult: activationResult(policy: "foreground")
            )
        )
        player.stop(reason: "selfcheck_s5_complete")
        if interrupted { return .inconclusive(.interrupted) }
        guard started, deferredSeen == 0 else {
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_STALE_INTERRUPTION_BLOCKS")
        }
        passStep(step, startedAt: startedAt)
        return nil
    }

    /// S6 双激活失败：经 SpeechPlayer 的自检注入缝强制 long-form 与
    /// foreground 都失败（真机无法按需制造），断言真实决策链走到
    /// playback_activation_exhausted、绝不 play()、onFinish(false) 通知
    /// 上层保留重播。
    private func dualActivationFailureStep(data: Data) async -> SelfCheckPolicy.Outcome? {
        let step = SelfCheckPolicy.Step.dualActivationFailure
        beginStep(step)
        let startedAt = Date()
        player.selfCheckForcedActivationFailures = ["long_form", "foreground"]
        defer { player.selfCheckForcedActivationFailures = [] }

        let requestTs = Self.epochMs()
        var retainedForReplay = false
        player.play(data: data, context: "selfcheck-s6") { finished in
            // 契约：未播完一律 onFinish(false)，上层据此保留重播——静默丢失即失败。
            retainedForReplay = !finished
        }
        let exhausted = await waitFor(timeout: 4) { [signals] in
            signals.count(of: "playback_activation_exhausted") > 0
        }
        let callbackTs = signals.firstTimestamp(of: "playback_activation_exhausted")
            .map { Int64($0.timeIntervalSince1970 * 1000) }
        WatchLog.info(
            "selfcheck", "selfcheck_observation",
            detail: SelfCheckPolicy.observationDetail(
                step: step, phase: "exhausted", scenePhase: Self.scenePhase(),
                interruptionState: .none, requestTs: requestTs, callbackTs: callbackTs,
                longFormResult: .failed, fallbackResult: .failed
            )
        )
        if interrupted { player.stop(reason: "selfcheck_interrupted"); return .inconclusive(.interrupted) }
        guard exhausted, signals.count(of: "play_started") == 0, retainedForReplay else {
            player.stop(reason: "selfcheck_s6_abort")
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_DUAL_FAILURE_LEAK")
        }
        passStep(step, startedAt: startedAt)
        return nil
    }

    /// 观察到的激活结果 → ESS-64 契约枚举（按 policy 区分同名事件）。
    private func activationResult(policy: String) -> SelfCheckPolicy.ActivationResult {
        if signals.count(of: "session_activated", detailContains: "policy=\(policy)") > 0 { return .success }
        if signals.count(of: "session_activation_failed", detailContains: "policy=\(policy)") > 0 { return .failed }
        return .notAttempted
    }

    // MARK: - ESS-137 会话让出屏障

    /// 每次探测的等待毫秒序列：首次 0（立即试一次），随后 100 / 200 / 400 ms。
    /// 累计上限约 700 ms，真机取证 ESS-72 的两级激活在录音收尾后 100–400 ms
    /// 内即可通过；再长就是硬件真的卡住，让实际步骤跑一次拿到原始错误码即可。
    static let sessionYieldWaitsMs: [UInt64] = [0, 100, 200, 400]

    /// 录音刚结束到起播之间的「会话让出」屏障：轮询式 setCategory(.playback,
    /// .longFormAudio) → setActive(true) 探测，直到 activation 通过或探测
    /// 序列耗尽。
    /// - **通过判据是 activation 成功，不是 setCategory 成功**——真机
    ///   561145203(`resourceNotAvailable`) 出在 activation 阶段而非 category
    ///   赋值；ESS-137 review（fee56b6a）明确指出「category 成功不等价于
    ///   硬件已归还」，必须用会话真正激活作为让出证据。
    /// - 探测通过后**保留 activated 状态**回到调用方：紧随其后的
    ///   `SpeechPlayer.activateSession`（同 category / policy / activate 语义）
    ///   会在已激活的会话上瞬间通过——不再需要再等一次硬件握手；
    /// - 未通过也不算失败——把 next 步骤放行，让真实链路拿到 !res 的原始
    ///   错误码进 fallbackCode，可判定的 fail 优于「看不见的静默」。
    /// - 全程留 selfcheck_session_yield 事件（result=ready|unavailable、
    ///   probes、elapsed_ms、last_error），G9 定位时能一眼看清是「屏障没能
    ///   等到硬件归还」还是「屏障通过后 playback 自己坏了」。
    /// 内部可见（非 private）以便 WatchTests 直接触发屏障并观察会话/事件——
    /// 无 mic 的模拟器上 SelfCheckRunner 无法跑完整流程，屏障若不能独立触发
    /// 就没有运行时证据（R-02.1）。
    internal func yieldRecordSessionForPlayback(prevStep: SelfCheckPolicy.Step, nextStep: SelfCheckPolicy.Step) async {
        let session = AVAudioSession.sharedInstance()
        let startedAt = Date()
        var probes = 0
        var succeeded = false
        var lastErrorCode: String?
        var lastFailingStage = "none"
        for delayMs in Self.sessionYieldWaitsMs {
            if interrupted { break }
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            // 再次把 .playAndRecord 会话显式让出——多次调用是幂等的；不成功
            // 也不致命，靠随后的 setCategory + activate 探测判定。
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            probes += 1
            do {
                // 分两段捕错：让 detail 能区分「category 失败」和「activate
                // 失败」——真机上后者是主要故障模式（561145203）。
                do {
                    try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                } catch {
                    lastFailingStage = "set_category"
                    let nsError = error as NSError
                    lastErrorCode = "\(nsError.domain)#\(nsError.code)"
                    continue
                }
                do {
                    try session.setActive(true)
                } catch {
                    lastFailingStage = "activate"
                    let nsError = error as NSError
                    lastErrorCode = "\(nsError.domain)#\(nsError.code)"
                    continue
                }
                succeeded = true
                break
            }
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        var detail = "from=\(prevStep.rawValue) to=\(nextStep.rawValue) "
            + "probes=\(probes) elapsed_ms=\(elapsedMs) result=\(succeeded ? "ready" : "unavailable")"
        if !succeeded {
            detail += " failing_stage=\(lastFailingStage)"
        }
        if succeeded {
            WatchLog.info("selfcheck", "selfcheck_session_yield", detail: detail)
        } else {
            WatchLog.error(
                "selfcheck", "selfcheck_session_yield",
                detail: detail, code: lastErrorCode ?? "ERR_YIELD_UNAVAILABLE"
            )
        }
    }

    private func waitFor(timeout: Double, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            if interrupted { return predicate() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return predicate()
    }

    private static func postSyntheticInterruption(_ type: AVAudioSession.InterruptionType) {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
    }

    private static func scenePhase() -> String {
        switch WKApplication.shared().applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func epochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - S2 播放等待

    private enum PlaybackWaitResult {
        case finished
        case truncated
        case startFailed
        case timeout
        case interrupted
    }

    private func awaitPlayback(data: Data) async -> PlaybackWaitResult {
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (PlaybackWaitResult) -> Void = { [weak self] result in
                guard !resumed else { return }
                resumed = true
                self?.pendingPlaybackFinish = nil
                continuation.resume(returning: result)
            }
            pendingPlaybackFinish = finish
            let accepted = player.play(data: data, context: "selfcheck") { completed in
                finish(completed ? .finished : .truncated)
            }
            if !accepted {
                finish(.startFailed)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.playbackTimeout * 1_000_000_000))
                finish(.timeout)
            }
        }
    }

    // MARK: - 步骤取证与收尾

    private func beginStep(_ step: SelfCheckPolicy.Step) {
        signals.reset()
        stage = .running(step: step)
    }

    private func passStep(_ step: SelfCheckPolicy.Step, startedAt: Date) {
        WatchLog.info(
            "selfcheck", "selfcheck_step",
            detail: SelfCheckPolicy.stepDetail(step: step, passed: true, elapsedMs: elapsedMs(since: startedAt))
        )
    }

    private func failStep(
        _ step: SelfCheckPolicy.Step, startedAt: Date, fallbackCode: String
    ) -> SelfCheckPolicy.Outcome {
        // 优先上报真实链路的原始错误码（如 NSOSStatusErrorDomain#-50），
        // 排查者要的是系统原话，不是自检的转述。
        let code = signals.lastErrorCode ?? fallbackCode
        WatchLog.error(
            "selfcheck", "selfcheck_step",
            detail: SelfCheckPolicy.stepDetail(step: step, passed: false, elapsedMs: elapsedMs(since: startedAt)),
            code: code
        )
        return .failed(step: step, code: code)
    }

    private func finish(outcome: SelfCheckPolicy.Outcome, fingerprint: String) {
        let detail = SelfCheckPolicy.finishedDetail(outcome: outcome, fingerprint: fingerprint)
        let errorInfo: ClientLogEntry.ErrorInfo?
        switch outcome {
        case .pass:
            WatchLog.info("selfcheck", "selfcheck_finished", detail: detail)
            errorInfo = nil
        case .failed(_, let code):
            WatchLog.error("selfcheck", "selfcheck_finished", detail: detail, code: code)
            errorInfo = ClientLogEntry.ErrorInfo(code: code, description: detail)
        case .inconclusive(let reason):
            let code = reason == .micPermissionMissing ? "ERR_MIC_PERMISSION" : "ERR_SELFCHECK_INTERRUPTED"
            WatchLog.error("selfcheck", "selfcheck_finished", detail: detail, code: code)
            errorInfo = ClientLogEntry.ErrorInfo(code: code, description: detail)
        }
        saveLastRun(SelfCheckPolicy.RunRecord(fingerprintDetail: fingerprint, result: outcome.result))
        stage = .finished(outcome)
        // 结论必须尽快到 Bridge——门禁判定读的是 bridge.log，不是手表本地文件。
        WatchLogShipper.shared.ship(reason: "selfcheck_finished")
        // ESS-137 快速旁路：主路径 transferFile 正在批量失败时（真机取证 37
        // 次 chunk_transfer_failed），G9 会读到 ERR_NO_SELFCHECK 与真实 FAIL
        // 混同。用 sendMessage/transferUserInfo 单独直投 selfcheck_finished
        // 这一行——sendMessage 可达即刻送达（含 reachable 恢复后 5 秒内的
        // 补发，见 WatchLogShipper.handleReachabilityChange），transferUserInfo
        // 系统托管兜底。旁路与主路径 chunk_id 不同（前缀不同）不跨路去重；
        // 详细契约见 `SelfCheckSummaryPayload` 类型注释。
        shipSelfCheckFinishedFastPath(detail: detail, errorInfo: errorInfo)
    }

    /// 把 `selfcheck_finished` 打包成与主路径逐字节一致的 JSONL microchunk，
    /// 通过 WatchLogShipper 的旁路直投给 iPhone。
    private func shipSelfCheckFinishedFastPath(detail: String, errorInfo: ClientLogEntry.ErrorInfo?) {
        let entry = ClientLogEntry(
            module: "selfcheck", event: "selfcheck_finished",
            detail: detail, error: errorInfo
        )
        guard let jsonl = try? entry.jsonlLine(),
              let jsonlString = String(data: jsonl, encoding: .utf8) else {
            return
        }
        // 与主路径的 chunk 命名前缀（watchlog-…）区分——iPhone 侧按前缀分流
        // 到 ClientLogUplink 队列。旁路自身的两条子路径（sendMessage /
        // transferUserInfo）共用同一 chunk_id，Bridge 幂等只让第一到达者进
        // bridge.log；旁路与主路径 id 不同，若两路都到 bridge.log 会各有
        // 一行 selfcheck_finished，`latestSelfCheckFinished` 取最新即可。
        let chunkId = "selfcheck-\(UUIDv7.generate().uuidString.lowercased()).jsonl"
        let payload = SelfCheckSummaryPayload(chunkId: chunkId, jsonl: jsonlString)
        WatchLogShipper.shared.shipSelfCheckSummary(payload: payload)
    }

    private func elapsedMs(since startedAt: Date) -> Int {
        Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
    }

    // MARK: - 持久化

    private func loadLastRun() -> SelfCheckPolicy.RunRecord? {
        guard let data = defaults.data(forKey: Self.lastRunDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SelfCheckPolicy.RunRecord.self, from: data)
    }

    private func saveLastRun(_ record: SelfCheckPolicy.RunRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.lastRunDefaultsKey)
    }
}

/// 自检窗口内的故障/进展信号记录（WatchLog 观察者回调可能来自任意线程）。
/// S5/S6 需要按 detail 区分同名事件（如 session_activated 的
/// policy=long_form 与 policy=foreground），故整条留存而非只计数。
private final class SignalCounter: @unchecked Sendable {
    private struct Signal {
        let event: String
        let detail: String?
        let code: String?
        let at: Date
    }

    private let lock = NSLock()
    private var signals: [Signal] = []
    private var latestCode: String?

    func record(event: String, detail: String?, code: String?) {
        lock.lock()
        defer { lock.unlock() }
        signals.append(Signal(event: event, detail: detail, code: code, at: Date()))
        if let code { latestCode = code }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        signals = []
        latestCode = nil
    }

    func count(of event: String, detailContains fragment: String? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return signals.filter { signal in
            guard signal.event == event else { return false }
            guard let fragment else { return true }
            return signal.detail?.contains(fragment) == true
        }.count
    }

    func firstTimestamp(of event: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return signals.first { $0.event == event }?.at
    }

    var lastErrorCode: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestCode
    }
}
