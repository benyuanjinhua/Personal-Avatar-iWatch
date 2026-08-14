import XCTest
import HealthKit
@testable import WristAgent_Watch_App

@MainActor
final class WorkoutSessionKeeperTests: XCTestCase {
    private enum ProbeError: Error { case rejected }

    /// 收集一段同步执行里产生的 workout 事件名。局部 `var` 捕获与既有
    /// WorkoutSessionKeeperTests 风格一致（Sendable 闭包内可安全累加）。
    private func collectEvents(_ body: () -> Void) -> [String] {
        var events: [String] = []
        WatchLog.setObserver { module, event, _, _, _ in
            if module == "workout" { events.append(event) }
        }
        defer { WatchLog.setObserver(nil) }
        body()
        return events
    }

    private func acquiredCount(in events: [String]) -> Int {
        events.filter { $0 == "workout_session_acquired" }.count
    }

    private func releasedCount(in events: [String]) -> Int {
        events.filter { $0 == "workout_session_released" }.count
    }

    // MARK: - 阻断 1：HealthKit 授权 fail-closed

    func testDisabledCapabilityDoesNotTouchHealthKit() {
        var started = false
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { false },
            startWorkoutOverride: { started = true }
        )
        let events = collectEvents { keeper.start() }
        XCTAssertFalse(started)
        XCTAssertFalse(keeper.isStarting)
        XCTAssertFalse(keeper.isAcquired)
        XCTAssertTrue(events.contains("workout_session_skipped"))
    }

    func testHealthDataUnavailableFailsClosed() {
        var started = false
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { false },
            startWorkoutOverride: { started = true }
        )
        let events = collectEvents { keeper.start() }
        XCTAssertFalse(started)
        XCTAssertFalse(keeper.isStarting)
        XCTAssertTrue(events.contains("workout_session_skipped"))
    }

    func testAuthorizationDeniedDoesNotStartWorkout() {
        var requested = false
        var started = false
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingDenied },
            requestAuthorization: { _ in requested = true },
            startWorkoutOverride: { started = true }
        )
        let events = collectEvents { keeper.start() }
        XCTAssertFalse(requested, "denied 态不应再次请求授权")
        XCTAssertFalse(started)
        XCTAssertFalse(keeper.isStarting)
        XCTAssertTrue(events.contains("workout_authorization_denied"))
    }

    func testAuthorizationNotDeterminedRequestsThenStartsOnGrant() {
        var started = 0
        var capturedCompletion: ((Bool, Error?) -> Void)?
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .notDetermined },
            requestAuthorization: { completion in capturedCompletion = completion },
            startWorkoutOverride: { started += 1 }
        )
        let events = collectEvents { keeper.start() }
        XCTAssertTrue(events.contains("workout_authorization_requested"))
        XCTAssertFalse(keeper.isStarting, "授权回调前不得启动 workout")
        XCTAssertEqual(started, 0)

        capturedCompletion?(true, nil)
        XCTAssertEqual(started, 1)
        XCTAssertTrue(keeper.isStarting)
        XCTAssertFalse(keeper.isAcquired, "启动不等于 acquired")
    }

    func testAuthorizationRequestErrorFailsClosed() {
        var capturedCompletion: ((Bool, Error?) -> Void)?
        var started = false
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .notDetermined },
            requestAuthorization: { completion in capturedCompletion = completion },
            startWorkoutOverride: { started = true }
        )
        let events = collectEvents {
            keeper.start()
            capturedCompletion?(false, ProbeError.rejected)
        }
        XCTAssertFalse(started)
        XCTAssertFalse(keeper.isStarting)
        XCTAssertTrue(events.contains("workout_authorization_failed"))
    }

    func testAuthorizationRequestDeniedFailsClosed() {
        var capturedCompletion: ((Bool, Error?) -> Void)?
        var started = false
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .notDetermined },
            requestAuthorization: { completion in capturedCompletion = completion },
            startWorkoutOverride: { started = true }
        )
        let events = collectEvents {
            keeper.start()
            capturedCompletion?(false, nil)
        }
        XCTAssertFalse(started)
        XCTAssertFalse(keeper.isStarting)
        XCTAssertTrue(events.contains("workout_authorization_denied"))
    }

    // MARK: - 阻断 1 补充：授权通过但启动失败仍被包含

    func testWorkoutStartErrorIsContained() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: { throw ProbeError.rejected }
        )
        let events = collectEvents { keeper.start() }
        XCTAssertTrue(events.contains("workout_session_start_failed"))
        XCTAssertFalse(keeper.isStarting)
        XCTAssertFalse(keeper.isAcquired)
    }

    // MARK: - 阻断 2：acquired 只由真实 delegate/collection 事件驱动

    func testStartCallDoesNotAcquire() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents { keeper.start() }
        XCTAssertTrue(keeper.isStarting)
        XCTAssertFalse(keeper.isAcquired, "startActivity 调用不等于 acquired")
        XCTAssertEqual(acquiredCount(in: events), 0)
    }

    func testCollectionFailureDoesNotReportPreserved() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents {
            keeper.start()
            keeper.handleStateChange(to: .running, from: .notStarted)
            keeper.handleCollectionResult(success: false, error: nil)
        }
        XCTAssertFalse(keeper.isAcquired)
        XCTAssertEqual(acquiredCount(in: events), 0)
        XCTAssertTrue(events.contains("workout_collection_failed"))
    }

    func testCollectionErrorDoesNotReportPreserved() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents {
            keeper.start()
            keeper.handleStateChange(to: .running, from: .notStarted)
            keeper.handleCollectionResult(success: false, error: ProbeError.rejected)
        }
        XCTAssertFalse(keeper.isAcquired)
        XCTAssertEqual(acquiredCount(in: events), 0)
        XCTAssertTrue(events.contains("workout_collection_failed"))
    }

    func testRunningWithoutCollectionSuccessDoesNotAcquire() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents {
            keeper.start()
            keeper.handleStateChange(to: .running, from: .notStarted)
        }
        XCTAssertFalse(keeper.isAcquired, "仅 .running 无 collection 成功不报 acquired")
        XCTAssertEqual(acquiredCount(in: events), 0)
    }

    func testRunningThenCollectionSuccessAcquiresExactlyOnce() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents {
            keeper.start()
            keeper.handleStateChange(to: .running, from: .notStarted)
            keeper.handleCollectionResult(success: true, error: nil)
            // 重复推进不得再次报 acquired。
            keeper.handleStateChange(to: .running, from: .notStarted)
            keeper.handleCollectionResult(success: true, error: nil)
        }
        XCTAssertTrue(keeper.isAcquired)
        XCTAssertFalse(keeper.isStarting)
        XCTAssertEqual(acquiredCount(in: events), 1)
        XCTAssertTrue(events.contains("workout_session_acquired"))
    }

    // MARK: - 阻断 2：release 带明确 reason 且幂等

    func testFailureReleasesOnceWithSystemFailureReason() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents {
            keeper.start()
            keeper.handleStateChange(to: .running, from: .notStarted)
            keeper.handleCollectionResult(success: true, error: nil)
            XCTAssertTrue(keeper.isAcquired)
            keeper.handleWorkoutFailure(ProbeError.rejected)
            keeper.stop(reason: "user_exit")
        }
        XCTAssertFalse(keeper.isAcquired)
        XCTAssertEqual(releasedCount(in: events), 1)
        XCTAssertEqual(keeper.lastReleaseReason, "system_failure")
    }

    func testStopReleasesOnceWithReason() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents {
            keeper.start()
            keeper.handleStateChange(to: .running, from: .notStarted)
            keeper.handleCollectionResult(success: true, error: nil)
            keeper.stop(reason: "user_exit")
            keeper.stop(reason: "user_exit")
        }
        XCTAssertFalse(keeper.isAcquired)
        XCTAssertEqual(releasedCount(in: events), 1)
        XCTAssertEqual(keeper.lastReleaseReason, "user_exit")
    }

    func testSessionEndedReleasesWithoutDoubleCounting() {
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            healthDataAvailableProvider: { true },
            authorizationStatusProvider: { .sharingAuthorized },
            startWorkoutOverride: {}
        )
        let events = collectEvents {
            keeper.start()
            keeper.handleStateChange(to: .running, from: .notStarted)
            keeper.handleCollectionResult(success: true, error: nil)
            keeper.handleStateChange(to: .ended, from: .running)
        }
        XCTAssertFalse(keeper.isAcquired)
        XCTAssertEqual(releasedCount(in: events), 1)
        XCTAssertEqual(keeper.lastReleaseReason, "session_ended")
    }
}
