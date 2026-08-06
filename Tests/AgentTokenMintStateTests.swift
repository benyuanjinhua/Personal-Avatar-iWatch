import XCTest
@testable import WristAgentCore

final class AgentTokenMintStateTests: XCTestCase {
    private let turnA = AgentTokenMintState.Turn(requestId: "request-a", sessionId: "session-a")
    private let turnB = AgentTokenMintState.Turn(requestId: "request-b", sessionId: "session-b")
    private let turnC = AgentTokenMintState.Turn(requestId: "request-c", sessionId: "session-c")

    func testLateFailureCannotMarkReplacementTurnFailed() throws {
        var state = AgentTokenMintState()
        XCTAssertTrue(state.activate(turnA))
        let taskA = try XCTUnwrap(state.registerTask())

        XCTAssertTrue(state.activate(turnB))
        let taskB = try XCTUnwrap(state.registerTask())

        XCTAssertFalse(state.markFailed(taskId: taskA, turn: turnA))
        XCTAssertNil(state.failedTurn)
        XCTAssertEqual(state.activeTaskId, taskB)
    }

    func testLateDeferCannotClearReplacementTaskHandle() throws {
        var state = AgentTokenMintState()
        XCTAssertTrue(state.activate(turnA))
        let taskA = try XCTUnwrap(state.registerTask())
        XCTAssertTrue(state.activate(turnB))
        let taskB = try XCTUnwrap(state.registerTask())

        XCTAssertFalse(state.finish(taskId: taskA, turn: turnA))
        XCTAssertEqual(state.activeTaskId, taskB)
        XCTAssertTrue(state.finish(taskId: taskB, turn: turnB))
        XCTAssertNil(state.activeTaskId)
    }

    func testNextTurnReplacesTheOnlyRegisteredMintTask() throws {
        var state = AgentTokenMintState()
        XCTAssertTrue(state.activate(turnB))
        let taskB = try XCTUnwrap(state.registerTask())
        XCTAssertNil(state.registerTask())

        XCTAssertTrue(state.activate(turnC))
        let taskC = try XCTUnwrap(state.registerTask())
        XCTAssertNotEqual(taskB, taskC)
        XCTAssertEqual(state.activeTaskId, taskC)
    }

    func testMissingConfigurationFailureUsesSameOwnershipGuard() throws {
        var state = AgentTokenMintState()
        XCTAssertTrue(state.activate(turnA))
        let taskA = try XCTUnwrap(state.registerTask())
        XCTAssertTrue(state.markFailed(taskId: taskA, turn: turnA))
        XCTAssertEqual(state.failedTurn, turnA)

        XCTAssertTrue(state.activate(turnB))
        _ = try XCTUnwrap(state.registerTask())
        XCTAssertFalse(state.markFailed(taskId: taskA, turn: turnA))
        XCTAssertNil(state.failedTurn)
    }

    func testSynchronousFallbackCannotFailAReplacementTurn() {
        var state = AgentTokenMintState()
        XCTAssertTrue(state.activate(turnA))
        XCTAssertTrue(state.activate(turnB))

        XCTAssertFalse(state.markCurrentTurnFailed(turnA))
        XCTAssertNil(state.failedTurn)
        XCTAssertTrue(state.markCurrentTurnFailed(turnB))
        XCTAssertEqual(state.failedTurn, turnB)
    }
}
