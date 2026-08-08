import Foundation

/// ESS-335 receipt state machine, extracted from `RealtimePlaybackEngine`
/// so the "when does `.started/.ended` fire?" logic is unit-testable without
/// AVFoundation.
///
/// The real engine schedules PCM buffers on an `AVAudioPlayerNode` with a
/// `.dataPlayedBack` completion callback; each callback pokes this tracker
/// with `bufferCompleted(...)`. `.started` fires on the FIRST completion for
/// a response (matching real playback beginning), `.ended` fires when the
/// per-response drain flag is set AND every queued buffer has completed,
/// and `bargeAll(...)` produces per-response barge-in receipts using
/// completed bytes vs queued bytes so `bytes_played` stays honest.
///
/// Bixuan's ESS-335 acceptance: "started fires on real playback start, not
/// on schedule; ended fires only when all buffers complete; bytes_played
/// counts only completed bytes; barge-in bytes are not counted."
struct RealtimePlaybackReceiptTracker: Sendable {
    struct StartedReceipt: Equatable, Sendable { let responseId: String? }
    struct EndedReceipt: Equatable, Sendable { let responseId: String?; let bytesPlayed: Int }
    /// ESS-531: emitted on every buffer completion so the Bridge can track
    /// playback progress across the streaming 40+ chunk response.
    struct ProgressReceipt: Equatable, Sendable {
        let responseId: String?
        let bytesPlayed: Int
        let totalBytes: Int
    }
    struct BargedInReceipt: Equatable, Sendable { let responseId: String?; let bytesDropped: Int }

    private struct Response {
        var queuedBuffers: Int = 0
        var completedBuffers: Int = 0
        var queuedBytes: Int = 0
        var playedBytes: Int = 0
        var startedEmitted = false
        var drainRequested = false
        var endedEmitted = false
    }

    /// Reserved key for chunks that carried no `response_id`.
    static let anonymousKey = "\u{200B}anonymous\u{200B}"

    private var byResponse: [String: Response] = [:]
    private var order: [String] = []

    /// Snapshot: outstanding responses in enqueue order.
    var responseOrder: [String] { order }

    var isEmpty: Bool { byResponse.isEmpty }

    /// Called when a chunk is scheduled on the player. Increments queued
    /// counters — does NOT emit `.started`; that waits for real completion.
    mutating func enqueue(responseId: String?, bytes: Int) {
        let key = responseId ?? Self.anonymousKey
        var state = byResponse[key] ?? Response()
        state.queuedBuffers += 1
        state.queuedBytes += bytes
        byResponse[key] = state
        if !order.contains(key) { order.append(key) }
    }

    /// Called from the player's real completion callback (`.dataPlayedBack`).
    /// Returns any receipts triggered by this completion.
    mutating func bufferCompleted(responseId: String?, bytes: Int) -> (
        started: StartedReceipt?, ended: EndedReceipt?, progress: ProgressReceipt?
    ) {
        let key = responseId ?? Self.anonymousKey
        guard var state = byResponse[key] else { return (nil, nil, nil) }
        state.completedBuffers += 1
        state.playedBytes += bytes
        var started: StartedReceipt?
        if !state.startedEmitted {
            state.startedEmitted = true
            started = StartedReceipt(responseId: keyToResponseId(key))
        }
        var ended: EndedReceipt?
        if !state.endedEmitted, state.completedBuffers == state.queuedBuffers {
            let superseded = order.last != key
            if state.drainRequested || superseded {
                state.endedEmitted = true
                ended = EndedReceipt(
                    responseId: keyToResponseId(key), bytesPlayed: state.playedBytes
                )
            }
        }
        // ESS-531: emit progress on every completion for realtime tracking.
        let progress = ProgressReceipt(
            responseId: keyToResponseId(key),
            bytesPlayed: state.playedBytes,
            totalBytes: state.queuedBytes
        )
        byResponse[key] = state
        return (started, ended, progress)
    }

    /// Bridge sent `audio.done` — no more deltas coming for the latest
    /// response. Emits `.ended` immediately if all queued buffers already
    /// completed; otherwise flips the drain flag so the next completion
    /// triggers `.ended` correctly.
    ///
    /// **ESS-404 G3 fix**: when `responseId` is nil AND no delta has ever
    /// been queued (`order.last == nil`), this method previously returned a
    /// zero-byte `.ended` receipt. That short-circuit forced `playback.ended`
    /// with `bytes_played = 0` for the "done before any delta" race — the
    /// exact silent-finish path the spec forbids. Post-fix: no receipt is
    /// emitted; the done-barrier layer decides whether this is the legit
    /// `-1` zero-audio case (no receipt expected) or a barrier timeout
    /// (structured failure via `AvatarErrorPresenter`).
    mutating func requestDrain(responseId: String? = nil) -> EndedReceipt? {
        let requestedKey = responseId ?? order.last
        guard let key = requestedKey else {
            // G3 core fix: no response known, no delta seen. Do NOT emit a
            // zero-byte `.ended`. The receipt was semantically meaningless
            // (nothing was played) and the barrier layer covers the real
            // completion decision.
            return nil
        }
        // WCSession does not guarantee that independently enqueued downlink
        // messages reach the Watch in the same order. If `audio.done` wins
        // the race against its `audio.delta`, retain a drain placeholder
        // instead of emitting a false zero-byte playback receipt. A later
        // enqueue for this response inherits `drainRequested` and produces
        // `.ended` only after the real buffer completion.
        if byResponse[key] == nil {
            var pending = Response()
            pending.drainRequested = true
            byResponse[key] = pending
            if !order.contains(key) { order.append(key) }
            return nil
        }
        guard var state = byResponse[key], !state.endedEmitted else { return nil }
        state.drainRequested = true
        var ended: EndedReceipt?
        if state.completedBuffers == state.queuedBuffers {
            state.endedEmitted = true
            ended = EndedReceipt(
                responseId: keyToResponseId(key), bytesPlayed: state.playedBytes
            )
        }
        byResponse[key] = state
        return ended
    }

    /// User barge-in / stop: emit per-response `.bargedIn(bytesDropped)` where
    /// `bytesDropped = queuedBytes - playedBytes`. Empties the tracker.
    mutating func bargeAll() -> [BargedInReceipt] {
        var receipts: [BargedInReceipt] = []
        for key in order {
            guard let state = byResponse[key], !state.endedEmitted else { continue }
            let dropped = max(0, state.queuedBytes - state.playedBytes)
            receipts.append(BargedInReceipt(
                responseId: keyToResponseId(key), bytesDropped: dropped
            ))
        }
        byResponse.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        return receipts
    }

    mutating func reset() {
        byResponse.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }

    private func keyToResponseId(_ key: String) -> String? {
        key == Self.anonymousKey ? nil : key
    }
}
