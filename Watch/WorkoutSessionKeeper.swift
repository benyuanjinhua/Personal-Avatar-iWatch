import HealthKit

/// ESS-540 F6 / ESS-843: HKWorkoutSession-based foreground keep-alive.
///
/// WKExtendedRuntimeSession is torn down by watchOS with reason_code=3
/// (`.resignedFrontmost`) ~2s after the wrist is lowered. A HealthKit
/// workout session, in contrast, keeps the app at the front of the
/// wrist-raise queue — exactly the behaviour workout apps like Keep
/// and Nike Run Club rely on.
///
/// This class creates a minimal "Other" workout session that satisfies
/// the system's foreground requirement without recording any health data.
/// The session starts when the user enters a conversation and ends when
/// they exit or the conversation is terminated.
///
/// ESS-843 复审修复：
/// 1. `HKWorkoutSession` 是 entitlement-backed API，且创建 workout session
///    前必须请求 HealthKit 授权（Apple《Running workout sessions》）。缺失
///    usage description 或授权未完成时直接调用会崩溃 / 无法形成可证明的
///    保活链。因此 start() 先 fail-closed 检查 capability + HealthKit 可用性，
///    再请求 workout type 的 share 授权；拒绝 / 失败 / 错误都落 WatchLog 且
///    不启动 workout。
/// 2. `session_preserved=true` 只能在**真实 owner acquired** 后记录——即
///    delegate 确认 `.running` 且 `beginCollection` 成功回调到达之后。启动
///    中（starting）、失败、结束分别可区分，杜绝“先报 preserved 后被系统
///    拒绝”的假阳性。
///
/// 测试接缝（全部可注入，模拟器无 HealthKit 时不构造真实 session）：
/// - `enabledProvider` / `healthDataAvailableProvider` / `authorizationStatusProvider`
/// - `requestAuthorization`（异步授权，回调必须回 MainActor）
/// - `startWorkoutOverride`（生产为 nil = 走真实构造；测试注入 no-op / throw）
@MainActor
final class WorkoutSessionKeeper: NSObject {
    typealias EnabledProvider = () -> Bool
    typealias HealthDataAvailableProvider = () -> Bool
    typealias AuthorizationStatusProvider = () -> HKAuthorizationStatus
    typealias RequestAuthorization = (@escaping @MainActor (Bool, Error?) -> Void) -> Void
    typealias StartWorkout = () throws -> Void

    private let enabledProvider: EnabledProvider
    private let healthDataAvailableProvider: HealthDataAvailableProvider
    private let authorizationStatusProvider: AuthorizationStatusProvider
    private let requestAuthorization: RequestAuthorization
    private let startWorkoutOverride: StartWorkout?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// owner 已确认获取（delegate `.running` + `beginCollection` 成功）。
    private(set) var isAcquired = false
    /// `startActivity` 已发出、`.running` 尚未确认的窗口。
    private(set) var isStarting = false
    /// 最近一次释放原因（机器可读，供日志与测试断言）。
    private(set) var lastReleaseReason: String?

    private var didReachRunning = false
    private var collectionSucceeded = false

    init(
        enabledProvider: @escaping EnabledProvider = {
            Bundle.main.object(forInfoDictionaryKey: "HealthKitWorkoutKeepAliveEnabled") as? Bool == true
        },
        healthDataAvailableProvider: @escaping HealthDataAvailableProvider = {
            HKHealthStore.isHealthDataAvailable()
        },
        authorizationStatusProvider: @escaping AuthorizationStatusProvider = {
            HKHealthStore().authorizationStatus(for: HKObjectType.workoutType())
        },
        requestAuthorization: @escaping RequestAuthorization = { completion in
            HKHealthStore().requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: []
            ) { granted, error in
                Task { @MainActor in completion(granted, error) }
            }
        },
        startWorkoutOverride: StartWorkout? = nil
    ) {
        self.enabledProvider = enabledProvider
        self.healthDataAvailableProvider = healthDataAvailableProvider
        self.authorizationStatusProvider = authorizationStatusProvider
        self.requestAuthorization = requestAuthorization
        self.startWorkoutOverride = startWorkoutOverride
        super.init()
    }

    // MARK: - 前台保活

    /// Start a workout session to keep the app foregrounded.
    /// Call when the user enters a real-time conversation.
    func start() {
        guard !isAcquired, !isStarting else { return }
        // HKWorkoutSession is an entitlement-backed API. Calling it from a
        // build whose capability/provisioning is incomplete can terminate the
        // process before Swift receives an Error. It must therefore be an
        // explicit, fail-closed capability, not an optimistic runtime probe.
        guard enabledProvider() else {
            WatchLog.info(
                "workout", "workout_session_skipped",
                detail: "reason=capability_disabled session_preserved=false"
            )
            return
        }
        guard healthDataAvailableProvider() else {
            WatchLog.info(
                "workout", "workout_session_skipped",
                detail: "reason=health_data_unavailable session_preserved=false"
            )
            return
        }
        resolveAuthorizationAndStart()
    }

    private func resolveAuthorizationAndStart() {
        switch authorizationStatusProvider() {
        case .sharingAuthorized:
            beginWorkout()
        case .notDetermined:
            WatchLog.info("workout", "workout_authorization_requested")
            requestAuthorization { [weak self] granted, error in
                guard let self else { return }
                if let error {
                    WatchLog.error(
                        "workout", "workout_authorization_failed",
                        detail: "session_preserved=false", error: error
                    )
                    return
                }
                guard granted else {
                    WatchLog.info(
                        "workout", "workout_authorization_denied",
                        detail: "session_preserved=false"
                    )
                    return
                }
                self.beginWorkout()
            }
        case .sharingDenied:
            WatchLog.info(
                "workout", "workout_authorization_denied",
                detail: "session_preserved=false"
            )
        @unknown default:
            WatchLog.info(
                "workout", "workout_session_skipped",
                detail: "reason=authorization_unknown session_preserved=false"
            )
        }
    }

    private func beginWorkout() {
        isStarting = true
        didReachRunning = false
        collectionSucceeded = false
        lastReleaseReason = nil
        WatchLog.info("workout", "workout_session_starting", detail: "session_preserved=false")
        do {
            if let override = startWorkoutOverride {
                try override()
            } else {
                try startDefaultWorkout()
            }
            // 注意：此处绝不置 isAcquired。owner acquired 只由 delegate
            // `.running` + beginCollection 成功回调驱动（maybeAcquire）。
        } catch {
            isStarting = false
            WatchLog.error(
                "workout", "workout_session_start_failed",
                detail: "session_preserved=false", error: error
            )
        }
    }

    private func startDefaultWorkout() throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        let session = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: config
        )
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: config
        )
        session.delegate = self
        self.session = session
        self.builder = builder
        try session.startActivity(with: Date())
        builder.beginCollection(withStart: Date()) { [weak self] success, error in
            Task { @MainActor in self?.handleCollectionResult(success: success, error: error) }
        }
    }

    /// End the workout session. Call when the user exits the conversation or
    /// the 120s silence policy terminates it. `reason` is machine-readable and
    /// recorded in `workout_session_released`.
    func stop(reason: String = "conversation_exit") {
        releaseSession(reason: reason)
    }

    // MARK: - 状态推进（delegate 与 collection 结果，测试可直接驱动）

    /// 由 `HKWorkoutSessionDelegate.workoutSession(_:didChangeTo:from:date:)`
    /// 转发。`.running` 才推进 owner acquired。
    func handleStateChange(to: HKWorkoutSessionState, from: HKWorkoutSessionState) {
        WatchLog.info(
            "workout", "workout_session_state_changed",
            detail: "from=\(from.rawValue) to=\(to.rawValue)"
        )
        switch to {
        case .running:
            didReachRunning = true
            maybeAcquire()
        case .ended:
            releaseSession(reason: "session_ended")
        default:
            break
        }
    }

    /// `HKLiveWorkoutBuilder.beginCollection` 完成回调。成功才推进 owner acquired，
    /// 失败不报 preserved（review 阻断 2）。
    func handleCollectionResult(success: Bool, error: Error?) {
        if let error {
            collectionSucceeded = false
            WatchLog.error(
                "workout", "workout_collection_failed",
                detail: "session_preserved=false", error: error
            )
            return
        }
        guard success else {
            collectionSucceeded = false
            WatchLog.error(
                "workout", "workout_collection_failed",
                detail: "session_preserved=false"
            )
            return
        }
        collectionSucceeded = true
        maybeAcquire()
    }

    /// 由 `HKWorkoutSessionDelegate.workoutSession(_:didFailWithError:)` 转发。
    func handleWorkoutFailure(_ error: Error) {
        WatchLog.error(
            "workout", "workout_session_failed",
            detail: "session_preserved=false", error: error
        )
        releaseSession(reason: "system_failure")
    }

    private func maybeAcquire() {
        guard didReachRunning, collectionSucceeded, !isAcquired else { return }
        isAcquired = true
        isStarting = false
        WatchLog.info(
            "workout", "workout_session_acquired",
            detail: "session_preserved=true"
        )
    }

    private func releaseSession(reason: String) {
        guard isAcquired || isStarting else { return }
        lastReleaseReason = reason
        WatchLog.info(
            "workout", "workout_session_released",
            detail: "reason=\(reason) session_preserved=false"
        )
        isAcquired = false
        isStarting = false
        didReachRunning = false
        collectionSucceeded = false

        let session = self.session
        let builder = self.builder
        self.session = nil
        self.builder = nil

        if let session {
            if session.state == .running || session.state == .paused {
                do {
                    session.stopActivity(with: Date())
                    try session.end()
                } catch {
                    WatchLog.error("workout", "workout_session_stop_failed", error: error)
                }
            }
        }
        if let builder {
            builder.endCollection(withEnd: Date()) { _, _ in }
        }
    }
}

extension WorkoutSessionKeeper: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in self.handleStateChange(to: toState, from: fromState) }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in self.handleWorkoutFailure(error) }
    }
}
