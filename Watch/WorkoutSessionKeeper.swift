import HealthKit
import WatchKit
import os

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
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.watch",
        category: "WorkoutSession"
    )

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isActive = false

    /// Start a workout session to keep the app foregrounded.
    /// Call when the user enters a real-time conversation.
    func start() {
        guard !isActive else { return }
        // ESS-843: HKWorkoutSession requires HealthKit authorization.
        // Request workout-type access before starting the session — without
        // it, the session fails silently and the app is NOT kept foregrounded.
        let types: Set = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: [], read: types) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if !success {
                    Self.logger.error(
                        "workout_healthkit_auth_failed error=\(error?.localizedDescription ?? "denied")"
                    )
                }
                self.startSession()
            }
        }
    }

    private func startSession() {
        guard !isActive else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown

        do {
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
            Self.logger.info("workout_session_started")
        } catch {
            Self.logger.error(
                "workout_session_start_failed error=\(error.localizedDescription)"
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
            Self.logger.error("workout_session_stop_failed error=\(error.localizedDescription)")
        }
        self.session = nil
        self.builder = nil
        Self.logger.info("workout_session_stopped")
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
            Self.logger.info(
                "workout_session_state_changed from=\(fromState.rawValue) to=\(toState.rawValue)"
            )
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            Self.logger.error(
                "workout_session_failed error=\(error.localizedDescription)"
            )
            self.isActive = false
            self.session = nil
            self.builder = nil
        }
    }
}
