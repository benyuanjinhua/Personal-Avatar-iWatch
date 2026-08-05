import XCTest
@testable import WristAgentCore

final class BargeInGenerationCoordinatorTests: XCTestCase {
    func testCancelMintReadyOpenOrdering() {
        var gate = BargeInGenerationCoordinator(generation: 1)
        XCTAssertEqual(gate.request(from: 1), .cancel(1))
        XCTAssertEqual(gate.ready(generation: 2), .ignore)
        XCTAssertEqual(gate.cancelSettled(generation: 1), .mintAndConnect(2))
        XCTAssertEqual(gate.ready(generation: 2), .open(2))
        XCTAssertEqual(gate.generation, 2)
    }

    func testLateOldEventsAndDuplicateFailureAreIgnored() {
        var gate = BargeInGenerationCoordinator(generation: 1)
        XCTAssertEqual(gate.request(from: 1), .cancel(1))
        XCTAssertEqual(gate.cancelSettled(generation: 0), .ignore)
        XCTAssertEqual(gate.fail("token_mint_failed"), .fallback("token_mint_failed"))
        XCTAssertEqual(gate.fail("upgrade_failed"), .ignore)
        XCTAssertEqual(gate.ready(generation: 2), .ignore)
    }
}
