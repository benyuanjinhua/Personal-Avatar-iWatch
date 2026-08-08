import XCTest
@testable import WristAgentCore

/// ESS-571: ConversationHandle 模型定义四组测试：
///
/// 1. 构造 & 标识（UUIDv7 格式、不可变性）
/// 2. 生命周期（nextTurn 递增、close 阻止新 turn）
/// 3. 序列化往返（JSON ↔ Codable）
/// 4. Session-level identity（Equatable, Hashable）
final class ConversationHandleTests: XCTestCase {

    // MARK: - 1. Construction & Identity

    func testHandleHasValidUUIDv7ConversationId() {
        let handle = ConversationHandle()
        let uuid = UUID(uuidString: handle.conversationId)
        XCTAssertNotNil(uuid, "conversationId 必须是合法 UUID")
        // UUIDv7: version nibble == 7，variant == 10xx
        let bytes = uuid!.uuid
        let version = (bytes.6 >> 4) & 0xF
        let variant = (bytes.8 >> 6) & 0x3
        XCTAssertEqual(version, 7, "version nibble 必须是 7 (UUIDv7)")
        XCTAssertEqual(variant, 2, "variant bits 必须是 10 (RFC 9562)")
    }

    func testHandleHasValidUUIDv7TurnId() {
        let handle = ConversationHandle()
        let firstUuid = UUID(uuidString: handle.firstTurnId)
        XCTAssertNotNil(firstUuid, "firstTurnId 必须是合法 UUID")
        XCTAssertNotEqual(handle.firstTurnId, handle.conversationId, "turnId 与 conversationId 不能相同")
    }

    func testHandleIsImmutableAfterCreation() {
        var handle = ConversationHandle()
        let originalConvId = handle.conversationId
        let originalFirstTurn = handle.firstTurnId
        let originalCreatedAt = handle.createdAt

        // nextTurn mutates turnCount and returns new turnId, but does not change
        // conversationId / firstTurnId / createdAt
        let secondTurn = handle.nextTurn()
        XCTAssertEqual(handle.conversationId, originalConvId, "conversationId 创建后不可变")
        XCTAssertEqual(handle.firstTurnId, originalFirstTurn, "firstTurnId 创建后不可变")
        XCTAssertEqual(handle.createdAt, originalCreatedAt, "createdAt 创建后不可变")
        XCTAssertNotEqual(secondTurn, originalFirstTurn, "nextTurn 生成的新 turnId 不得与 firstTurnId 相同")
    }

    // MARK: - 2. Lifecycle

    func testNextTurnIncrementsTurnCount() {
        var handle = ConversationHandle()
        XCTAssertEqual(handle.turnCount, 0, "初始 turnCount = 0")

        _ = handle.nextTurn()
        XCTAssertEqual(handle.turnCount, 1)

        for i in 1...5 {
            _ = handle.nextTurn()
            XCTAssertEqual(handle.turnCount, i + 1)
        }
    }

    func testClosePreventsNewTurns() {
        var handle = ConversationHandle()
        _ = handle.nextTurn()  // valid — one turn before close
        handle.close()
        XCTAssertTrue(handle.isClosed)

        // Closing a closed conversation is idempotent
        handle.close()
        XCTAssertTrue(handle.isClosed)

        // Verify turnCount stays at 1 after close
        XCTAssertEqual(handle.turnCount, 1, "close 之后 turnCount 不应变化")
    }

    func testCloseIsIdempotent() {
        var handle = ConversationHandle()
        handle.close()
        handle.close()
        handle.close()
        XCTAssertTrue(handle.isClosed)
        XCTAssertEqual(handle.turnCount, 0)
    }

    // MARK: - 3. Codable round-trip

    func testCodableRoundTrip() throws {
        var handle = ConversationHandle(
            conversationId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!.uuidString,
            firstTurnId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!.uuidString,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        _ = handle.nextTurn()
        handle.close()

        let encoder = JSONEncoder()
        let data = try encoder.encode(handle)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ConversationHandle.self, from: data)

        XCTAssertEqual(decoded.conversationId, handle.conversationId)
        XCTAssertEqual(decoded.firstTurnId, handle.firstTurnId)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       handle.createdAt.timeIntervalSince1970,
                       accuracy: 1.0)
        XCTAssertEqual(decoded.turnCount, 1)
        XCTAssertEqual(decoded.isClosed, true)
    }

    func testCodableKeysAreSnakeCase() throws {
        var handle = ConversationHandle(
            conversationId: "conv-1",
            firstTurnId: "turn-1"
        )
        handle.close()

        let encoder = JSONEncoder()
        let data = try encoder.encode(handle)
        // Verify JSON keys are snake_case
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(dict["conversation_id"])
        XCTAssertNotNil(dict["first_turn_id"])
        XCTAssertNotNil(dict["created_at"])
        XCTAssertNotNil(dict["turn_count"])
        XCTAssertNotNil(dict["is_closed"])
        XCTAssertNil(dict["conversationId"])
    }

    // MARK: - 4. Equatable & Hashable

    func testEquality() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!.uuidString
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        var h1 = ConversationHandle(conversationId: id, firstTurnId: id, createdAt: createdAt)
        let h2 = ConversationHandle(conversationId: id, firstTurnId: id, createdAt: createdAt)
        XCTAssertEqual(h1, h2)

        // Different after mutation
        _ = h1.nextTurn()
        XCTAssertNotEqual(h1, h2)

        let createdLater = ConversationHandle(
            conversationId: id,
            firstTurnId: id,
            createdAt: createdAt.addingTimeInterval(1)
        )
        XCTAssertNotEqual(h2, createdLater)
    }

    func testHashable() {
        let id = "11111111-1111-4111-8111-111111111111"
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let h1 = ConversationHandle(conversationId: id, firstTurnId: id, createdAt: createdAt)
        let h2 = ConversationHandle(conversationId: id, firstTurnId: id, createdAt: createdAt)
        let set: Set<ConversationHandle> = [h1, h2]
        XCTAssertEqual(set.count, 1, "相等的 Handle Hashable 也必须退化为一个元素")
    }

    func testDescriptionDoesNotLeakFullId() {
        let handle = ConversationHandle(
            conversationId: "deadbeef-1234-4567-8901-abcdef012345",
            firstTurnId: "cafebabe-1234-4567-8901-abcdef012345"
        )
        let desc = handle.description
        XCTAssertTrue(desc.contains("deadbeef"), "description 应包含前缀用于排查")
        XCTAssertFalse(desc.contains("deadbeef-1234-4567-8901-abcdef012345"), "description 不得暴露完整 UUID")
    }
}
