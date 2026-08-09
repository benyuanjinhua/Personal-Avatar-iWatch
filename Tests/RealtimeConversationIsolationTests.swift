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

    // MARK: - ESS-551 AC1 / AC2

    /// ESS-551 AC1: Given 点球进入会话, When 连续 5 轮, Then 5 轮共享同一
    /// conversation_id，turn_id 时间序递增且不复用。
    func testFiveTurnsShareConversationIdAndTurnIdsNeverRepeat() throws {
        let session = RealtimeMediaSession(sessionIdFactory: { UUID().uuidString })
        session.beginConversation()

        var turnIds: [String] = []
        var conversationIds: Set<String> = []
        for index in 0..<5 {
            let handle = session.beginTurn(requestId: "0198c001-0000-7000-8000-00000000010\(index)")
            conversationIds.insert(try XCTUnwrap(handle.conversationId))
            turnIds.append(handle.turnId)
            session.finishTurn(reason: .audioDone)
        }

        XCTAssertEqual(conversationIds.count, 1, "5 轮必须共享同一 conversation_id")
        XCTAssertEqual(Set(turnIds).count, 5, "turn_id 禁止复用——5 轮必须 5 个不同 id")

        // UUIDv7 毫秒时间戳非递减 = 时间序递增（真实设备上两轮 VAD final
        // 相隔数秒，ms 前缀严格递增；单测同毫秒内只退化为相等，「不复用」
        // 由上面的集合断言单独钉住）。
        let timestamps = try turnIds.map { try XCTUnwrap(UUID(uuidString: $0)) }.map(UUIDv7.timestampMs)
        XCTAssertEqual(timestamps, timestamps.sorted(), "turn_id 时间戳必须递增")
    }

    /// ESS-551 AC2 (Watch 侧): conversation.close 后，该 conversation 下旧
    /// request 的迟到 delta 一律被拒绝并落 drop 原因，零帧进入播放。
    ///（对应小梁建议的 testConversationCloseCleansUpAllResources 的
    /// Watch 侧一半；Gateway 侧一半在 realtime-session.test.mjs。）
    func testLateDownlinkAfterConversationCloseIsDropped() {
        var events: [RealtimeMediaSession.Event] = []
        let session = RealtimeMediaSession(sessionIdFactory: { UUID().uuidString })
        session.onEvent = { events.append($0) }

        session.beginConversation()
        let handle = session.beginTurn(requestId: request1)
        session.finishTurn(reason: .audioDone)
        session.closeConversation()
        XCTAssertNil(session.activeConversationId)

        // 旧 request 的迟到 delta 到达。
        let lateChunk = VoiceStreamChunk(
            requestId: handle.requestId,
            streamId: handle.sessionId,
            direction: .downlink,
            sequence: 0,
            capturedAtMs: 1_800_000_000_000,
            codec: "pcm_s16le",
            sampleRate: 24_000,
            payload: Data(repeating: 0x55, count: 128)
        )
        session.receiveDownlink(lateChunk)

        let dropped = events.filter {
            if case .downlinkDropped = $0 { return true }
            return false
        }
        XCTAssertEqual(dropped.count, 1, "迟到帧必须被拒绝并落 drop 事件")
        let playbackReady = events.filter {
            if case .playbackReady = $0 { return true }
            return false
        }
        XCTAssertEqual(playbackReady.count, 0, "零帧进入播放")
    }
}
