import Foundation
import XCTest
@testable import WristAgentCore

final class ResultPlaybackLedgerTests: XCTestCase {
    func testClaimSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(ResultPlaybackLedger(directory: directory).claim(requestId: "req-1"))
        XCTAssertFalse(ResultPlaybackLedger(directory: directory).claim(requestId: "req-1"))
        XCTAssertTrue(ResultPlaybackLedger(directory: directory).claim(requestId: "req-2"))
    }
}
