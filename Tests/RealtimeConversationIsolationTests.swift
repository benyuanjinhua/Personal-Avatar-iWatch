import XCTest
@testable import WristAgentCore

final class RealtimeConversationIsolationTests: XCTestCase {
    private let request1 = "0198c001-0000-7000-8000-000000000011"
    private let request2 = "0198c001-0000-7000-8000-000000000012"

    func testConversationIdIsStableAcrossTurnsAndTurnIdRotates() throws {
        let conversation = ConversationHandle(
            conversationId: "0198c001-0000-7000-8000-000000000001",
            firstTurnId: "0198c001-0000-7000-8000-000000000002"
        )
        let session = RealtimeMediaSession(sessionIdFactory: { UUID().uuidString })
        session.beginConversation(conversation)

        let first = session.beginTurn(requestId: request1)
        session.finishTurn(reason: .audioDone)
        let second = session.beginTurn(requestId: request2)

        XCTAssertEqual(first.conversationId, conversation.conversationId)
        XCTAssertEqual(second.conversationId, conversation.conversationId)
        XCTAssertEqual(first.turnId, conversation.firstTurnId)
        XCTAssertNotEqual(second.turnId, first.turnId)
    }

    func testCloseConversationCreatesFreshBoundaryForNextTurn() throws {
        let session = RealtimeMediaSession(sessionIdFactory: { UUID().uuidString })
        let firstConversation = session.beginConversation()
        _ = session.beginTurn(requestId: request1)

        session.closeConversation()
        XCTAssertNil(session.activeConversationId)

        let next = session.beginTurn(requestId: request2)
        let nextConversationId = try XCTUnwrap(next.conversationId)
        XCTAssertNotEqual(nextConversationId, firstConversation.conversationId)
    }

    func testUplinkFactoriesPreserveConversationAndTurnScope() throws {
        let conversationId = "0198c001-0000-7000-8000-000000000001"
        let turnId = "0198c001-0000-7000-8000-000000000002"
        let start = RealtimeStreamStart(
            requestId: request1, sessionId: "session-1",
            format: .uplinkPCM16, capturedAtMs: 1
        )
        let envelope = RealtimeUplinkEnvelope.start(
            start, conversationId: conversationId, turnId: turnId
        )
        let decoded = try JSONDecoder().decode(
            RealtimeUplinkEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        XCTAssertEqual(decoded.conversationId, conversationId)
        XCTAssertEqual(decoded.turnId, turnId)
    }
}
