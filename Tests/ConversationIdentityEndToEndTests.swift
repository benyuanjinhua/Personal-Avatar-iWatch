import XCTest
@testable import WristAgentCore

/// ESS-551 A4/A3：conversation_id / turn_id 端到端贯通的 Swift 侧证据。
///
/// - A4 AC1（5 轮共享 conversation_id、turn_id 严格递增不复用）由
///   RealtimeMediaSession + ConversationHandle 给出——句柄是唯一 mint 方。
/// - 协议面：`meta` 子对象承载主键，不扩散顶层字段（ALLOWED_KEYS 收紧不变）；
///   缺失时完全不下发 meta（与旧版帧面一致，退出方案）。
final class ConversationIdentityEndToEndTests: XCTestCase {

    // MARK: - AC1：5 轮共享 conversation_id，turn_id 不复用且单调

    func testFiveTurnsShareConversationIdWithUniqueMonotonicTurnIds() {
        let session = RealtimeMediaSession(sessionIdFactory: { UUID().uuidString })
        let handle = session.beginConversation()

        var turnIds: [String] = []
        var conversationIds: Set<String> = []
        for i in 0..<5 {
            let turn = session.beginTurn(requestId: "0198c001-0000-7000-8000-00000000100\(i)")
            conversationIds.insert(try! XCTUnwrap(turn.conversationId))
            turnIds.append(turn.turnId)
            session.finishTurn(reason: .audioDone)
        }

        XCTAssertEqual(conversationIds.count, 1, "5 轮必须共享同一 conversation_id")
        XCTAssertEqual(conversationIds.first, handle.conversationId)
        XCTAssertEqual(Set(turnIds).count, 5, "turn_id 禁止复用")
        // UUIDv7 前 48 bit 是毫秒时间戳：同毫秒内随机后缀无次序（不算违反），
        // 跨毫秒必须非递减。「严格递增」的可判定口径 = 唯一 + 时间戳非递减。
        let timestamps = turnIds.map { Self.uuidV7TimestampMs($0) }
        XCTAssertEqual(timestamps, timestamps.sorted(), "turn_id 时间戳必须非递减")
        XCTAssertEqual(turnIds.first, handle.firstTurnId, "首轮使用预铸的 firstTurnId")
    }

    /// 提取 UUIDv7 字符串前 48 bit 的毫秒时间戳（横杠不计）。
    private static func uuidV7TimestampMs(_ uuidString: String) -> UInt64 {
        let hex = uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        return UInt64(String(hex), radix: 16) ?? 0
    }

    func testTurnAfterCloseGetsFreshConversationId() {
        let session = RealtimeMediaSession(sessionIdFactory: { UUID().uuidString })
        let first = session.beginConversation()
        _ = session.beginTurn(requestId: "0198c001-0000-7000-8000-000000002001")
        session.closeConversation(reason: .cancelled)

        let next = session.beginTurn(requestId: "0198c001-0000-7000-8000-000000002002")
        XCTAssertNotEqual(next.conversationId, first.conversationId,
                          "关闭后再开的轮次必须属于新 conversation")
    }

    // MARK: - 协议面：meta 子对象承载主键

    private func decoded(_ frame: AudioRealtimeAgentCodec.UplinkFrame) -> [String: Any] {
        let encoded = AudioRealtimeAgentCodec.encode(frame)
        XCTAssertNotNil(encoded)
        return (try! JSONSerialization.jsonObject(with: Data(encoded!.utf8))) as! [String: Any]
    }

    func testSessionStartCarriesMetaWhenConversationPresent() {
        let payload = decoded(.sessionStart(
            sessionId: "s", requestId: "r", generation: 1, protocolVersion: 1,
            conversationId: "conv-1", turnId: "turn-1"
        ))
        let meta = payload["meta"] as? [String: Any]
        XCTAssertEqual(meta?["conversation_id"] as? String, "conv-1")
        XCTAssertEqual(meta?["turn_id"] as? String, "turn-1")
        // 顶层字段不扩散（ALLOWED_KEYS 收紧语义不变）。
        XCTAssertNil(payload["conversation_id"])
        XCTAssertNil(payload["turn_id"])
    }

    func testSessionStartOmitsMetaWhenConversationAbsent() {
        let payload = decoded(.sessionStart(
            sessionId: "s", requestId: "r", generation: 1, protocolVersion: 1
        ))
        XCTAssertNil(payload["meta"], "无会话身份时不下发空 meta——帧面与旧版一致（退出方案）")
    }

    func testCloseCarriesMetaOnlyWithConversation() {
        let withMeta = decoded(.close(reason: "conversation_end",
                                      conversationId: "conv-1", turnId: nil))
        let meta = withMeta["meta"] as? [String: Any]
        XCTAssertEqual(meta?["conversation_id"] as? String, "conv-1")
        XCTAssertNil(meta?["turn_id"])

        let plain = decoded(.close(reason: "supersede"))
        XCTAssertNil(plain["meta"], "每回合普通拆连不带 meta（不关闭 conversation）")
    }
}
