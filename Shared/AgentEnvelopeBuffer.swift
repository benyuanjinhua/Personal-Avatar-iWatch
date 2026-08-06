import Foundation

/// A small, bounded holding area used while the iPhone mints a per-turn
/// realtime Agent token. The limits cap both object overhead and audio bytes.
struct AgentEnvelopeBuffer {
    static let defaultMaximumCount = 64
    static let defaultMaximumBytes = 512 * 1_024

    enum AppendResult {
        case buffered
        case overflow(buffered: [RealtimeUplinkEnvelope], incoming: RealtimeUplinkEnvelope, snapshot: Snapshot)
    }

    struct Snapshot: Equatable {
        let envelopeCount: Int
        let byteCount: Int
        let waitedMilliseconds: Int
    }

    private let maximumCount: Int
    private let maximumBytes: Int
    private var entries: [(envelope: RealtimeUplinkEnvelope, byteCount: Int)] = []
    private var startedAt: Date?
    private(set) var byteCount = 0

    init(
        maximumCount: Int = Self.defaultMaximumCount,
        maximumBytes: Int = Self.defaultMaximumBytes
    ) {
        precondition(maximumCount > 0 && maximumBytes > 0)
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
    }

    mutating func append(
        _ envelope: RealtimeUplinkEnvelope,
        encodedByteCount: Int,
        now: Date = Date()
    ) -> AppendResult {
        let size = max(0, encodedByteCount)
        if entries.count >= maximumCount || size > maximumBytes - byteCount {
            let (buffered, snapshot) = drain(now: now)
            return .overflow(buffered: buffered, incoming: envelope, snapshot: snapshot)
        }
        if startedAt == nil { startedAt = now }
        entries.append((envelope, size))
        byteCount += size
        return .buffered
    }

    mutating func drain(now: Date = Date()) -> ([RealtimeUplinkEnvelope], Snapshot) {
        let waited = startedAt.map { max(0, Int(now.timeIntervalSince($0) * 1_000)) } ?? 0
        let snapshot = Snapshot(
            envelopeCount: entries.count,
            byteCount: byteCount,
            waitedMilliseconds: waited
        )
        let envelopes = entries.map(\.envelope)
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
        startedAt = nil
        return (envelopes, snapshot)
    }
}
