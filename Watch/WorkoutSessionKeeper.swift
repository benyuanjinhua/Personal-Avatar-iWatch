import HealthKit

/// ESS-540 F6: HKWorkoutSession-based foreground keep-alive.
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
/// Debug/development builds require no special entitlements beyond the
/// HealthKit capability in the Xcode project. App Store submission would
/// need a privacy policy covering HealthKit usage.
@MainActor
final class WorkoutSessionKeeper: NSObject {
    typealias EnabledProvider = () -> Bool
    typealias StartProbe = () throws -> Void

    private let enabledProvider: EnabledProvider
    private let startProbe: StartProbe?
    private lazy var healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isActive = false

    init(
        enabledProvider: @escaping EnabledProvider = {
            Bundle.main.object(forInfoDictionaryKey: "HealthKitWorkoutKeepAliveEnabled") as? Bool == true
        },
        startProbe: StartProbe? = nil
    ) {
        self.enabledProvider = enabledProvider
        self.startProbe = startProbe
        super.init()
    }

    /// Start a workout session to keep the app foregrounded.
    /// Call when the user enters a real-time conversation.
    func start() {
        guard !isActive else { return }
        // HKWorkoutSession is an entitlement-backed API. Calling it from a
        // build whose capability/provisioning is incomplete can terminate the
        // process before Swift receives an Error. It must therefore be an
        // explicit, fail-closed capability, not an optimistic runtime probe.
        guard enabledProvider() else {
            WatchLog.info(
                "workout", "workout_session_skipped",
                detail: "reason=capability_disabled session_preserved=true"
            )
            return
        }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown

        do {
            try startProbe?()
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
            try builder.beginCollection(withStart: Date()) { _, _ in }
            isActive = true
            WatchLog.info("workout", "workout_session_started")
        } catch {
            self.session = nil
            self.builder = nil
            isActive = false
            WatchLog.error(
                "workout", "workout_session_start_failed",
                detail: "session_preserved=true", error: error
            )
        }
    }

    /// End the workout session. Call when the user exits the conversation.
    func stop() {
        guard isActive, let session else { return }
        isActive = false
        do {
            session.stopActivity(with: Date())
            try session.end()
            try builder?.endCollection(withEnd: Date()) { _, _ in }
        } catch {
            WatchLog.error("workout", "workout_session_stop_failed", error: error)
        }
        self.session = nil
        self.builder = nil
        WatchLog.info("workout", "workout_session_stopped")
    }
}

extension WorkoutSessionKeeper: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            WatchLog.info(
                "workout", "workout_session_state_changed",
                detail: "from=\(fromState.rawValue) to=\(toState.rawValue)"
            )
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            WatchLog.error(
                "workout", "workout_session_failed",
                detail: "session_preserved=true", error: error
            )
            self.isActive = false
            self.session = nil
            self.builder = nil
        }
    }
}
