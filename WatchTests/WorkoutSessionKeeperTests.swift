import XCTest
@testable import WristAgent_Watch_App

@MainActor
final class WorkoutSessionKeeperTests: XCTestCase {
    private enum ProbeError: Error { case rejected }

    func testDisabledCapabilityDoesNotTouchHealthKitOrExitSession() {
        var probed = false
        let keeper = WorkoutSessionKeeper(
            enabledProvider: { false },
            startProbe: { probed = true }
        )
        keeper.start()
        XCTAssertFalse(probed)
    }

    func testWorkoutStartErrorIsContained() {
        var event: String?
        WatchLog.setObserver { module, observed, _, _, _ in
            if module == "workout" { event = observed }
        }
        defer { WatchLog.setObserver(nil) }

        let keeper = WorkoutSessionKeeper(
            enabledProvider: { true },
            startProbe: { throw ProbeError.rejected }
        )
        keeper.start()

        XCTAssertEqual(event, "workout_session_start_failed")
    }
}
