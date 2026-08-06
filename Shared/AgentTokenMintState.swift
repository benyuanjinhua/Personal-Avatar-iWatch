import Foundation

/// Serializes per-turn token mint ownership without depending on networking.
/// A completion may mutate the active turn only while both its turn and task
/// identity are still current.
struct AgentTokenMintState: Equatable {
    struct Turn: Equatable {
        let requestId: String
        let sessionId: String
    }

    private(set) var turn: Turn?
    private(set) var failedTurn: Turn?
    private(set) var activeTaskId: UUID?

    mutating func activate(_ newTurn: Turn) -> Bool {
        guard turn != newTurn else { return false }
        turn = newTurn
        failedTurn = nil
        activeTaskId = nil
        return true
    }

    mutating func registerTask() -> UUID? {
        guard turn != nil, activeTaskId == nil else { return nil }
        let taskId = UUID()
        activeTaskId = taskId
        return taskId
    }

    func owns(taskId: UUID, turn expectedTurn: Turn) -> Bool {
        activeTaskId == taskId && turn == expectedTurn
    }

    mutating func markFailed(taskId: UUID, turn expectedTurn: Turn) -> Bool {
        guard owns(taskId: taskId, turn: expectedTurn) else { return false }
        failedTurn = expectedTurn
        return true
    }

    mutating func markCurrentTurnFailed(_ expectedTurn: Turn) -> Bool {
        guard turn == expectedTurn else { return false }
        failedTurn = expectedTurn
        return true
    }

    mutating func finish(taskId: UUID, turn expectedTurn: Turn) -> Bool {
        guard owns(taskId: taskId, turn: expectedTurn) else { return false }
        activeTaskId = nil
        return true
    }
}
