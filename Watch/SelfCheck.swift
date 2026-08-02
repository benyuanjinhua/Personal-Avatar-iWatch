import AVFoundation
import Combine
import Foundation

/// 装机音频自检（ESS-65 / G9）：新 build 首启自动跑一遍「录音 → 播放 →
/// 播放后立刻录音 → 会话状态复位」四步，结论经 WatchLog → Bridge 回传，
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
        player.stop(reason: "selfcheck_interrupted")
        pendingPlaybackFinish?(.interrupted)
    }

    // MARK: - 主流程

    private func run(fingerprint: String) async {
        guard !running else { return }
        running = true
        interrupted = false
        WatchLog.info("selfcheck", "selfcheck_started", detail: SelfCheckPolicy.startedDetail(fingerprint: fingerprint))
        WatchLog.setObserver { [signals] module, event, code in
            // 只关心真实链路组件的会话/播放故障信号；自检自身的日志不计入。
            guard module != "selfcheck" else { return }
            signals.record(event: event, code: code)
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
        // play() 不得返回 false。
        if let failure = await playbackStep() { return failure }

        // S3 播放→录音交替（ESS-61 缺陷 A，今天这个 -50）：播放刚结束立刻再录，
        // 且全程 session_activation_failed 出现 0 次。
        if let failure = await recordStep(.playThenRecord) { return failure }

        // S4 会话状态复位（ESS-61 根因）：.longFormAudio 路由策略不得残留。
        if let failure = sessionResetStep() { return failure }

        return .pass
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

    private func playbackStep() async -> SelfCheckPolicy.Outcome? {
        let step = SelfCheckPolicy.Step.playback
        beginStep(step)
        let startedAt = Date()
        // 内置资产复用欢迎语（App 包内唯一音频，3.3s，不联网）；缺失是打包缺陷，判 fail。
        guard
            let url = Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            let data = try? Data(contentsOf: url)
        else {
            return failStep(step, startedAt: startedAt, fallbackCode: "ERR_SELFCHECK_ASSET_MISSING")
        }
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
            signals.count(of: "play_returned_false") == 0
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
        switch outcome {
        case .pass:
            WatchLog.info("selfcheck", "selfcheck_finished", detail: detail)
        case .failed(_, let code):
            WatchLog.error("selfcheck", "selfcheck_finished", detail: detail, code: code)
        case .inconclusive(let reason):
            let code = reason == .micPermissionMissing ? "ERR_MIC_PERMISSION" : "ERR_SELFCHECK_INTERRUPTED"
            WatchLog.error("selfcheck", "selfcheck_finished", detail: detail, code: code)
        }
        saveLastRun(SelfCheckPolicy.RunRecord(fingerprintDetail: fingerprint, result: outcome.result))
        stage = .finished(outcome)
        // 结论必须尽快到 Bridge——门禁判定读的是 bridge.log，不是手表本地文件。
        WatchLogShipper.shared.ship(reason: "selfcheck_finished")
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

/// 自检窗口内的故障信号计数（WatchLog 观察者回调可能来自任意线程）。
private final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var latestCode: String?

    func record(event: String, code: String?) {
        lock.lock()
        defer { lock.unlock() }
        counts[event, default: 0] += 1
        if let code { latestCode = code }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        counts = [:]
        latestCode = nil
    }

    func count(of event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[event] ?? 0
    }

    var lastErrorCode: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestCode
    }
}
