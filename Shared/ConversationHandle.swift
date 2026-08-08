import Foundation

/// ESS-571 Wave 0: ConversationHandle — the conversation-level identity carrier.
///
/// Created by the Watch on entry into real-time conversation (user taps the
/// voice orb). It produces a UUIDv7 `conversationId` that stays constant for
/// the entire conversation lifecycle (enter → X / 10-min expiry / lifecycle
/// termination) and serves as the primary key for:
///
/// - `ConversationAudioController`: session-level audio ownership
/// - iPhone coordinator: relay routing
/// - Gateway session: session association
/// - ②-screen history: archival primary key
///
/// One conversation contains multiple turns; each turn carries its own
/// UUIDv7 `turnId`. The handle is the single source of truth for the
/// conversation identity — no other component may mint conversation IDs.
struct ConversationHandle: Equatable, Hashable, Sendable, Codable {

    /// UUIDv7 that identifies this conversation. Generated at construction
    /// time and immutable thereafter.
    let conversationId: String

    /// The first turn within this conversation (set at construction).
    /// Subsequent turns receive new `turnId`s via `nextTurn()`.
    let firstTurnId: String

    /// When the conversation was created (Watch-local wall clock).
    let createdAt: Date

    /// Conversation-level count of turns that have entered the media pipeline.
    /// Starts at 0 before the pre-minted first turn begins.
    private(set) var turnCount: Int

    /// Whether the conversation has been explicitly closed.
    private(set) var isClosed: Bool

    /// The identifier used on the wire for cross-component routing.
    /// This is the `conversation_id` JSON key value.
    var id: String { conversationId }

    // MARK: - Init

    /// Create a new conversation handle.
    ///
    /// - Parameters:
    ///   - conversationId: UUIDv7 for the conversation. Defaults to a new UUIDv7.
    ///   - firstTurnId: UUIDv7 for the first turn. Defaults to a new UUIDv7.
    ///   - createdAt: Wall-clock creation time. Injectable for tests.
    init(
        conversationId: String = UUIDv7.generate().uuidString,
        firstTurnId: String = UUIDv7.generate().uuidString,
        createdAt: Date = Date()
    ) {
        self.conversationId = conversationId
        self.firstTurnId = firstTurnId
        self.createdAt = createdAt
        self.turnCount = 0
        self.isClosed = false
    }

    // MARK: - Lifecycle

    /// Record that the pre-minted first turn has entered the media pipeline.
    /// Idempotence is owned by `RealtimeMediaSession`, which calls this once.
    mutating func markFirstTurnStarted() {
        precondition(!isClosed, "Cannot start a turn on a closed conversation")
        precondition(turnCount == 0, "First turn already started")
        turnCount = 1
    }

    /// Mint a new turn within this conversation.
    /// - Returns: A new UUIDv7 `turnId` for the next user utterance.
    /// - Precondition: The conversation must not be closed.
    mutating func nextTurn() -> String {
        precondition(!isClosed, "Cannot mint a new turn on a closed conversation")
        turnCount += 1
        return UUIDv7.generate().uuidString
    }

    /// Mark the conversation as closed. Idempotent.
    mutating func close() {
        isClosed = true
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case firstTurnId = "first_turn_id"
        case createdAt = "created_at"
        case turnCount = "turn_count"
        case isClosed = "is_closed"
    }
}

// MARK: - CustomStringConvertible

extension ConversationHandle: CustomStringConvertible {
    var description: String {
        "ConversationHandle(id: \(conversationId.prefix(8))…, turns: \(turnCount), closed: \(isClosed))"
    }
}
