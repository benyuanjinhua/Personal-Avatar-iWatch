import Foundation
import XCTest
@testable import WristAgent_Watch_App

@MainActor
final class SelfCheckColdStartTests: XCTestCase {
    func testColdStartDoesNotStartOrPlaySelfCheck() {
        let suiteName = "SelfCheckColdStartTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runner = SelfCheckRunner(defaults: defaults)
        var events: [(module: String, event: String)] = []
        WatchLog.setObserver { module, event, _, _, _ in
            events.append((module, event))
        }
        defer { WatchLog.setObserver(nil) }

        runner.handleColdStart()

        XCTAssertEqual(runner.stage, .idle)
        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(events.contains { $0.module == "selfcheck" && $0.event == "selfcheck_started" })
        XCTAssertFalse(events.contains { $0.event == "play_started" })
        XCTAssertTrue(events.contains { $0.module == "selfcheck" && $0.event == "selfcheck_skipped" })
    }
}
