import Foundation

/// ESS-335 receipt state machine, extracted from `RealtimePlaybackEngine`
/// so the "when does `.started/.ended` fire?" logic is unit-testable without
/// AVFoundation.
///
/// The real engine schedules PCM buffers on an `AVAudioPlayerNode` with a
/// `.dataPlayedBack` completion callback; each callback pokes this tracker
/// with `bufferCompleted(...)`. `.started` fires on the FIRST completion of
/// each segment (matching real playback beginning), `.ended` fires when a
/// drained segment's buffers have all completed (ESS-1070: 一个回合级
/// `response_id` 会被 `audio.segment_done` 切成多段，逐段开合),
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

    /// ESS-1070：一个 `response_id` 的生命周期被切成若干**段**。段与段之间由
    /// `requestDrain`（`audio.segment_done` / `audio.done`）分界，计数器是
    /// 累计的，收口按段结算。
    private struct Response {
        var queuedBuffers: Int = 0
        var completedBuffers: Int = 0
        var queuedBytes: Int = 0
        var playedBytes: Int = 0
        /// 本段是否已发过 `.started`。每段收口后归零——下一段真正出声时
        /// 重新发一次，与「这一段开始播了」一一对应。
        var startedEmitted = false
        /// 本段 drain 时的 `queuedBuffers` **快照**。收齐这么多 buffer 即收口。
        ///
        /// 用快照而不是「completed == queued」是 ESS-1070 的核心：段落屏障之后
        /// 紧接着就会有下一段的帧排进来，用活的 `queuedBuffers` 判定会让本段的
        /// `.ended` 被下一段的音频一路推迟，最终整个回合只收口一次——回合终态
        /// 那一次就永远等不到，只能落到 45s 硬超时。
        var drainTarget: Int?
        /// `audio.done` 抢在**任何** delta 之前到达（WCSession 不保证跨消息
        /// 顺序）。此时还不知道要等几个 buffer，语义是「排到的都算本段」。
        var drainAll = false
        /// 上一次 `.ended` 时的 `completedBuffers` 快照；nil = 还没收口过。
        var endedAtBuffer: Int?
        /// 上一次 `.ended` 时的 `playedBytes` 快照——本段字节数的起点。
        var playedBytesAtEnded: Int = 0

        /// 本段已收口且此后没有新帧：重复的 done 应当幂等丢弃。
        var isSettled: Bool { endedAtBuffer == queuedBuffers }
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
    ///
    /// **ESS-1070（增量语音多段回合）**：Gateway 的 `response_id` 是**回合级**的
    /// （`qwen-agent-transport.mjs` 的 `openTurn({ responseId })`），一个回合的
    /// 每一段 `audio.delta` / `audio.segment_done` / `audio.done` 共用同一个值。
    /// 因此「这个 response 已经收口过」不等于「这个 response 再也不会有音频」——
    /// 段落屏障收口后紧接着就是下一段的帧。整改前收口是 response 级一次性的，
    /// 后面每一段都拿不到 `.started/.ended`：Watch 的 `onAnswerPlaybackFinished`
    /// 永不触发，回合只能等 45s 硬超时，`playback.ended` 也永远不回传。
    /// 这里把「收口后再来的 enqueue」识别为**新一段**，按段重新开合计数。
    mutating func enqueue(responseId: String?, bytes: Int) {
        let key = responseId ?? Self.anonymousKey
        var state = byResponse[key] ?? Response()
        if state.isSettled {
            // 上一段已收口，这是**新一段**的第一帧：它又是当前最新的
            // response，重新排到队尾，`superseded` 判定才不会把它当成被顶掉的
            // 旧 response。累计计数不清零——收口按段结算即可。
            order.removeAll { $0 == key }
        }
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
            started = StartedReceipt(responseId: Self.keyToResponseId(key))
        }
        var ended: EndedReceipt?
        if let receipt = Self.settleIfDrained(&state, key: key, order: order) {
            ended = receipt
        }
        // ESS-531: emit progress on every completion for realtime tracking.
        let progress = ProgressReceipt(
            responseId: Self.keyToResponseId(key),
            bytesPlayed: state.playedBytes,
            totalBytes: state.queuedBytes
        )
        byResponse[key] = state
        return (started, ended, progress)
    }

    /// Bridge sent `audio.segment_done` / `audio.done` — no more deltas
    /// coming for the segment that is open right now. Emits `.ended`
    /// immediately if every buffer queued so far already completed;
    /// otherwise records the buffer-count target so the completion that
    /// reaches it triggers `.ended`.
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
            pending.drainAll = true
            byResponse[key] = pending
            if !order.contains(key) { order.append(key) }
            return nil
        }
        // ESS-1070：幂等只对「本段已收口且此后没有新帧」成立。若这一段之后
        // 又排进了新帧（多段回合的下一段），这次 done 属于**新的一段**，
        // 必须重新武装屏障，不能沿用上一段的收口结果直接丢弃。
        guard var state = byResponse[key], !state.isSettled else { return nil }
        state.drainTarget = state.queuedBuffers
        let ended = Self.settleIfDrained(&state, key: key, order: order)
        byResponse[key] = state
        return ended
    }

    /// 本段是否已经收齐：收齐就结算一次 `.ended`（按段计算 `bytesPlayed`），
    /// 并把段落起点推到当前位置，让下一段从零重新开合。
    ///
    /// 三条收口条件：
    ///  * `drainTarget`：`audio.segment_done` / `audio.done` 时的 buffer 快照；
    ///  * `drainAll`：done 抢在首帧之前到达，排到的都算本段；
    ///  * `superseded`：被更新的 response 顶掉的旧 response，不等 done 也收口。
    private static func settleIfDrained(
        _ state: inout Response, key: String, order: [String]
    ) -> EndedReceipt? {
        let allCompleted = state.completedBuffers == state.queuedBuffers
        let reachedTarget = state.drainTarget.map { state.completedBuffers >= $0 } ?? false
        let superseded = order.last != key && allCompleted && !state.isSettled
        guard reachedTarget || (state.drainAll && allCompleted) || superseded else { return nil }
        let bytes = state.playedBytes - state.playedBytesAtEnded
        state.drainTarget = nil
        state.drainAll = false
        state.endedAtBuffer = state.completedBuffers
        state.playedBytesAtEnded = state.playedBytes
        state.startedEmitted = false
        return EndedReceipt(responseId: Self.keyToResponseId(key), bytesPlayed: bytes)
    }

    /// User barge-in / stop: emit per-response `.bargedIn(bytesDropped)` where
    /// `bytesDropped = queuedBytes - playedBytes`. Empties the tracker.
    mutating func bargeAll() -> [BargedInReceipt] {
        var receipts: [BargedInReceipt] = []
        for key in order {
            guard let state = byResponse[key], !state.isSettled else { continue }
            let dropped = max(0, state.queuedBytes - state.playedBytes)
            receipts.append(BargedInReceipt(
                responseId: Self.keyToResponseId(key), bytesDropped: dropped
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

    private static func keyToResponseId(_ key: String) -> String? {
        key == Self.anonymousKey ? nil : key
    }
}
