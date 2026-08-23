import Foundation

/// ESS-773: realtime media must use one WCSession delivery path at a time.
/// Status/result messages are idempotent and may use durable + interactive
/// delivery together; ordered `audio.delta` / `audio.done` envelopes may not.
enum RealtimeDownlinkDeliveryPolicy {
    enum Route: Equatable {
        case interactiveOnly
        case durableOnly
    }

    static func route(isActivated: Bool, isReachable: Bool) -> Route {
        isActivated && isReachable ? .interactiveOnly : .durableOnly
    }

    static func shouldAddInteractiveCopyToDurable(messageKey: String) -> Bool {
        messageKey != RealtimeMediaMessage.downlinkEnvelopeKey
    }
}

/// ESS-321 wire envelope for the Watch → iPhone hop.
///
/// The Watch fast channel is `WCSession.sendMessageData`, which carries an
/// opaque `Data`. To keep every media frame self-describing (so a reordered
/// or delayed frame can be routed without cross-referencing another message),
/// each frame goes across as an `RealtimeUplinkEnvelope` — a small tagged
/// union around the coordinator's uplink frames.
///
/// The iPhone side (`PhoneRealtimeSession`) decodes this envelope, translates
/// it into the WSS event the bridge expects (`stream.start` / `audio.append`
/// / `audio.commit`) and forwards it frame-by-frame. The wire format is
/// deliberately versioned to make future schema breaks explicit.
enum RealtimeWireVersion {
    static let uplink: Int = 1
    static let downlink: Int = 1
}

/// iPhone receipt for a Watch `audio.append`. ACKs travel independently from
/// uplink frames, so the Watch validates the turn identity and sequence and
/// treats duplicates / reordering as harmless no-ops.
struct RealtimeUplinkAck: Codable, Sendable, Equatable {
    let requestId: String
    let sessionId: String
    let sequence: Int
    let byteCount: Int
    /// ESS-571: optional conversation-level identity (Phase 0 dual-write).
    var conversationId: String?
    /// ESS-571: optional turn-level identity (Phase 0 dual-write).
    var turnId: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case sequence
        case byteCount = "byte_count"
        case conversationId = "conversation_id"
        case turnId = "turn_id"
    }
}

enum RealtimeUplinkKind: String, Codable, Sendable {
    case streamStart = "stream.start"
    case audioAppend = "audio.append"
    case audioCommit = "audio.commit"
    case playbackStarted = "playback.started"
    case playbackEnded = "playback.ended"
    case fallback = "stream.fallback"
    /// ESS-404 A4: barge-in request from Watch → iPhone (Watch is not the
    /// generation owner; it asks iPhone to advance `generation` and issue
    /// `cancel` on the WSS).
    case bargeInRequest = "bargein.request"
}

struct RealtimeUplinkEnvelope: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let kind: RealtimeUplinkKind
    let start: RealtimeStreamStart?
    let append: VoiceStreamChunk?
    let commit: RealtimeStreamCommit?
    let playback: RealtimePlaybackReceipt?
    let fallback: RealtimeUplinkFallbackDescriptor?
    /// ESS-404 A4: only present when `kind == .bargeInRequest`.
    let bargeIn: RealtimeBargeInRequest?
    /// ESS-571: optional conversation-level identity (Phase 0 dual-write).
    var conversationId: String?
    /// ESS-571: optional turn-level identity (Phase 0 dual-write).
    var turnId: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case kind
        case start
        case append
        case commit
        case playback
        case fallback
        case bargeIn = "bargein"
        case conversationId = "conversation_id"
        case turnId = "turn_id"
    }

    init(
        protocolVersion: Int,
        kind: RealtimeUplinkKind,
        start: RealtimeStreamStart?,
        append: VoiceStreamChunk?,
        commit: RealtimeStreamCommit?,
        playback: RealtimePlaybackReceipt?,
        fallback: RealtimeUplinkFallbackDescriptor?,
        bargeIn: RealtimeBargeInRequest? = nil,
        conversationId: String? = nil,
        turnId: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.start = start
        self.append = append
        self.commit = commit
        self.playback = playback
        self.fallback = fallback
        self.bargeIn = bargeIn
        self.conversationId = conversationId
        self.turnId = turnId
    }

    /// Explicit initializer used by the JSON decoder: the `bargein` key is
    /// optional on the wire so pre-ESS-404 messages still decode cleanly.
    /// ESS-571: conversation_id / turn_id are optional so pre-migration
    /// messages also decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        self.kind = try c.decode(RealtimeUplinkKind.self, forKey: .kind)
        self.start = try c.decodeIfPresent(RealtimeStreamStart.self, forKey: .start)
        self.append = try c.decodeIfPresent(VoiceStreamChunk.self, forKey: .append)
        self.commit = try c.decodeIfPresent(RealtimeStreamCommit.self, forKey: .commit)
        self.playback = try c.decodeIfPresent(RealtimePlaybackReceipt.self, forKey: .playback)
        self.fallback = try c.decodeIfPresent(RealtimeUplinkFallbackDescriptor.self, forKey: .fallback)
        self.bargeIn = try c.decodeIfPresent(RealtimeBargeInRequest.self, forKey: .bargeIn)
        self.conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        self.turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
    }

    static func start(_ start: RealtimeStreamStart, conversationId: String? = nil, turnId: String? = nil) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .streamStart, start: start, append: nil, commit: nil,
            playback: nil, fallback: nil,
            conversationId: conversationId, turnId: turnId
        )
    }

    static func append(_ chunk: VoiceStreamChunk, conversationId: String? = nil, turnId: String? = nil) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .audioAppend, start: nil, append: chunk, commit: nil,
            playback: nil, fallback: nil,
            conversationId: conversationId, turnId: turnId
        )
    }

    static func commit(_ commit: RealtimeStreamCommit, conversationId: String? = nil, turnId: String? = nil) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .audioCommit, start: nil, append: nil, commit: commit,
            playback: nil, fallback: nil,
            conversationId: conversationId, turnId: turnId
        )
    }

    static func playbackStarted(_ receipt: RealtimePlaybackReceipt) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .playbackStarted, start: nil, append: nil, commit: nil,
            playback: receipt, fallback: nil
        )
    }

    static func playbackEnded(_ receipt: RealtimePlaybackReceipt) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .playbackEnded, start: nil, append: nil, commit: nil,
            playback: receipt, fallback: nil
        )
    }

    static func fallback(_ descriptor: RealtimeUplinkFallbackDescriptor) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .fallback, start: nil, append: nil, commit: nil,
            playback: nil, fallback: descriptor
        )
    }

    /// ESS-404 A4: Watch asks iPhone to advance the generation and send
    /// `cancel(from_generation)` on the WSS. Watch does not embed the target
    /// generation — iPhone is the generation owner.
    static func bargeInRequest(_ request: RealtimeBargeInRequest) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .bargeInRequest, start: nil, append: nil, commit: nil,
            playback: nil, fallback: nil, bargeIn: request
        )
    }
}

/// ESS-404 A4 barge-in request payload — carries which generation the Watch
/// last saw (`fromGeneration`) so iPhone can dedupe stale requests.
struct RealtimeBargeInRequest: Codable, Sendable, Equatable {
    let requestId: String
    let sessionId: String
    let fromGeneration: Int
    /// ESS-571: optional conversation-level identity.
    var conversationId: String?
    /// ESS-571: optional turn-level identity.
    var turnId: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case fromGeneration = "from_generation"
        case conversationId = "conversation_id"
        case turnId = "turn_id"
    }
}

struct RealtimeUplinkFallbackDescriptor: Codable, Sendable, Equatable {
    let requestId: String
    let sessionId: String
    let reason: String
    /// ESS-571: optional conversation-level identity.
    var conversationId: String?
    /// ESS-571: optional turn-level identity.
    var turnId: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case reason
        case conversationId = "conversation_id"
        case turnId = "turn_id"
    }
}

struct RealtimePlaybackReceipt: Codable, Sendable, Equatable {
    let requestId: String
    let sessionId: String
    let responseId: String
    let bytesPlayed: Int?
    /// ESS-571: optional conversation-level identity.
    var conversationId: String?
    /// ESS-571: optional turn-level identity.
    var turnId: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case responseId = "response_id"
        case bytesPlayed = "bytes_played"
        case conversationId = "conversation_id"
        case turnId = "turn_id"
    }
}

/// ESS-321 wire envelope for the iPhone → Watch downlink hop.
///
/// The iPhone → Watch fast channel carries `audio.delta`, transcript deltas,
/// `audio.done`, `playback.clear` and `response.interrupted` events. Each
/// carries `request_id/session_id/sequence` for isolation and rejection of
/// late frames from prior sessions.
enum RealtimeDownlinkKind: String, Codable, Sendable {
    /// Bridge handshake ack; Watch/iPhone treat it as a benign no-op that
    /// simply proves the socket accepted the `start` frame.
    case ready = "ready"
    case audioDelta = "audio.delta"
    case transcriptDelta = "transcript.delta"
    case transcriptFinal = "transcript.final"
    case audioDone = "audio.done"
    case playbackClear = "playback.clear"
    case responseInterrupted = "response.interrupted"
    case bridgeFallback = "stream.fallback"
    /// ESS-404: iPhone → Watch generation lifecycle. `generationOpen`
    /// promotes Watch's `activeGeneration` and unblocks the pending window
    /// that follows a barge-in. `bargeInFailed` reports that iPhone could
    /// not send `cancel` on the WSS, so the pending window must collapse.
    case generationOpen = "generation.open"
    case bargeInFailed = "bargein.failed"
    /// ESS-1008: the iPhone-owned Agent WSS died after the turn had become
    /// active. This control event travels over WCSession (not the dead WSS)
    /// so Watch can leave `.thinking` deterministically instead of arming a
    /// fresh 45 s timeout and reporting a misleading "answer timeout".
    case transportFailed = "transport.failed"
    /// ESS-969 / ESS-971：**本段结束，回合未结束**。屏障语义与 `audioDone`
    /// 一致，但客户端必须保持本轮打开（`markAnswerInterim`），不开下一轮。
    case audioSegmentDone = "audio.segment_done"
    /// ESS-1097：上游任务生命周期（`task.accepted/running/completed/…`）。
    /// 客户端此前对「工具任务还在跑」完全不知情，只能靠网关的有界空闲窗
    /// 猜回合终态；窗口被一次更慢的工具跑穿，手表就提前回「正在听」，用户
    /// 一开口就把工具回合 supersede 掉。本事件把任务事实交到客户端手里。
    /// 纯取证 + 门禁，不携带音频，也不改变任何播放屏障。
    case turnTask = "turn.task"

    /// 未知 kind 不得让**整个信封**解码失败。
    ///
    /// ESS-971：本枚举原先是裸 `String, Codable`，新增任何取值都会让尚未升级的
    /// 一侧在 `RealtimeDownlinkEnvelope` 解码时整帧抛错——不是忽略一个字段，
    /// 是**丢掉整条下行**。Watch 与 iPhone 虽然同包发布，但 WCSession 的队列
    /// 里可能残留上一版进程投递的信封，滚动升级窗口内真实存在混版。
    /// 未知取值降级为 `.unrecognised`，由分发层按「不认识就跳过」处理。
    case unrecognised = "__unrecognised__"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RealtimeDownlinkKind(rawValue: raw) ?? .unrecognised
    }
}

/// ESS-541: a downlink may only enter the playback pipeline for the exact
/// request/session tuple that currently owns the phone-side transport.
/// Superseded transports can still deliver already-queued callbacks after
/// `close(reason:)`; those callbacks must never leak into the next turn.
enum RealtimeRequestIsolationPolicy {
    static func accepts(
        incomingRequestId: String,
        incomingSessionId: String,
        activeRequestId: String,
        activeSessionId: String
    ) -> Bool {
        guard !incomingRequestId.isEmpty, !incomingSessionId.isEmpty else { return false }
        return incomingRequestId == activeRequestId && incomingSessionId == activeSessionId
    }
}

struct RealtimeDownlinkEnvelope: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let kind: RealtimeDownlinkKind
    let requestId: String
    let sessionId: String
    let sequence: Int?
    let audio: VoiceStreamChunk?
    let transcript: String?
    let reason: String?
    /// ESS-330: real Agent response_id carried on `audio.delta` / `audio.done`.
    /// Bridge PR #113 emits this per delta and expects it back on playback
    /// receipts so multi-response sessions are disambiguated. Absent for
    /// event kinds that have no notion of an Agent response.
    let responseId: String?
    /// ESS-404 §3.1: turn generation. Optional on the wire during rollout
    /// (Gateway ESS-403 may lag), but required by contract; `nil` triggers
    /// the legacy path in `RealtimeDownlinkPlayback`, not a hard drop.
    let generation: Int?
    /// ESS-404 §3.2: completion barrier value on `audio.done`.
    /// `n ≥ 0` means release once seq 0…n have arrived; `-1` means "zero
    /// audio for this response" (release immediately, no `.ended`); `nil`
    /// means Gateway did not send the field — a contract violation that
    /// degrades to `n = max seq seen so far` under `done_missing_final_sequence`.
    let finalSequence: Int?
    /// ESS-571: optional conversation-level identity (Phase 0 dual-write).
    var conversationId: String?
    /// ESS-571: optional turn-level identity (Phase 0 dual-write).
    var turnId: String?
    /// ESS-1097: `turn.task` 的任务 id。只在该 kind 上出现。
    ///
    /// 这里**没有**复用 `transcript` / `reason` 之类的既有字段（ESS-971 给
    /// `segmentIndex` 借 `sequence` 是权衡后的例外）：任务 id 会进入分发层的
    /// 路由与日志，借道 `transcript` 会让「文本事件」这条路由拿到一个不是文本
    /// 的值，是下一个 ESS-971 式的隐藏坑。三个可选字段对未升级的一侧完全透明
    /// （解码 `decodeIfPresent`，编码 nil 即不写键）。
    var taskId: String?
    /// ESS-1097: 任务状态原文（`accepted` / `running` / `completed` / …）。取证用；
    /// 门禁只看 `taskTerminal`——终态口径由网关按上游事件判定后下发，客户端不
    /// 自己维护一份 status 白名单，避免两侧口径漂移。
    var taskStatus: String?
    /// ESS-1097: 该任务是否已达终态。
    var taskTerminal: Bool?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case kind
        case requestId = "request_id"
        case sessionId = "session_id"
        case sequence
        case audio
        case transcript
        case reason
        case responseId = "response_id"
        case generation
        case finalSequence = "final_sequence"
        case conversationId = "conversation_id"
        case turnId = "turn_id"
        case taskId = "task_id"
        case taskStatus = "task_status"
        case taskTerminal = "task_terminal"
    }

    init(
        protocolVersion: Int,
        kind: RealtimeDownlinkKind,
        requestId: String,
        sessionId: String,
        sequence: Int?,
        audio: VoiceStreamChunk?,
        transcript: String?,
        reason: String?,
        responseId: String?,
        generation: Int? = nil,
        finalSequence: Int? = nil,
        conversationId: String? = nil,
        turnId: String? = nil,
        taskId: String? = nil,
        taskStatus: String? = nil,
        taskTerminal: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.requestId = requestId
        self.sessionId = sessionId
        self.sequence = sequence
        self.audio = audio
        self.transcript = transcript
        self.reason = reason
        self.responseId = responseId
        self.generation = generation
        self.finalSequence = finalSequence
        self.conversationId = conversationId
        self.turnId = turnId
        self.taskId = taskId
        self.taskStatus = taskStatus
        self.taskTerminal = taskTerminal
    }

    /// Explicit decoder so pre-ESS-404 messages (no `generation`, no
    /// `final_sequence`) and pre-ESS-571 messages (no `conversation_id`,
    /// no `turn_id`) still decode. Only mandatory keys are strict.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        self.kind = try c.decode(RealtimeDownlinkKind.self, forKey: .kind)
        self.requestId = try c.decode(String.self, forKey: .requestId)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.sequence = try c.decodeIfPresent(Int.self, forKey: .sequence)
        self.audio = try c.decodeIfPresent(VoiceStreamChunk.self, forKey: .audio)
        self.transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.responseId = try c.decodeIfPresent(String.self, forKey: .responseId)
        self.generation = try c.decodeIfPresent(Int.self, forKey: .generation)
        self.finalSequence = try c.decodeIfPresent(Int.self, forKey: .finalSequence)
        self.conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        self.turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        self.taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        self.taskStatus = try c.decodeIfPresent(String.self, forKey: .taskStatus)
        self.taskTerminal = try c.decodeIfPresent(Bool.self, forKey: .taskTerminal)
    }

    /// Bridge PR #113 handshake ack. Carries no payload. Adapter treats this
    /// as "socket is live" and does nothing further.
    static func ready(requestId: String, sessionId: String) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .ready, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: nil, responseId: nil
        )
    }

    static func audioDelta(
        _ chunk: VoiceStreamChunk,
        responseId: String? = nil,
        generation: Int? = nil
    ) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .audioDelta, requestId: chunk.requestId, sessionId: chunk.streamId,
            sequence: chunk.sequence, audio: chunk, transcript: nil, reason: nil,
            responseId: responseId, generation: generation
        )
    }

    static func transcriptDelta(requestId: String, sessionId: String, text: String) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .transcriptDelta, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: text, reason: nil, responseId: nil
        )
    }

    static func transcriptFinal(requestId: String, sessionId: String, text: String) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .transcriptFinal, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: text, reason: nil, responseId: nil
        )
    }

    static func audioDone(
        requestId: String,
        sessionId: String,
        responseId: String? = nil,
        generation: Int? = nil,
        finalSequence: Int? = nil
    ) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .audioDone, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: nil,
            responseId: responseId, generation: generation, finalSequence: finalSequence
        )
    }

    /// ESS-969 / ESS-971：段落屏障。`sequence` 复用 `finalSequence` 承载屏障值，
    /// `segmentIndex` 借 `sequence` 字段传递（信封无专用字段，避免为一个取证字段
    /// 改动全链路 Codable 契约）。
    static func audioSegmentDone(
        requestId: String,
        sessionId: String,
        responseId: String? = nil,
        generation: Int? = nil,
        segmentIndex: Int,
        finalSequence: Int
    ) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .audioSegmentDone, requestId: requestId, sessionId: sessionId,
            sequence: segmentIndex, audio: nil, transcript: nil, reason: nil,
            responseId: responseId, generation: generation, finalSequence: finalSequence
        )
    }

    /// ESS-1097：上游任务生命周期。不携带音频，不动任何播放屏障——它唯一的
    /// 作用是让 Watch 的回合聚合知道「工具还在跑」，从而不提前回聆听、不自动
    /// 开下一轮。`generation` 照常带上，陈旧代的任务事件在 iPhone 侧就被
    /// 既有的 generation 门禁挡掉。
    static func turnTask(
        requestId: String,
        sessionId: String,
        responseId: String? = nil,
        generation: Int? = nil,
        taskId: String,
        status: String,
        terminal: Bool
    ) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .turnTask, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: nil,
            responseId: responseId, generation: generation,
            taskId: taskId, taskStatus: status, taskTerminal: terminal
        )
    }

    static func playbackClear(requestId: String, sessionId: String) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .playbackClear, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: nil, responseId: nil
        )
    }

    static func responseInterrupted(requestId: String, sessionId: String, reason: String) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .responseInterrupted, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: reason, responseId: nil
        )
    }

    static func bridgeFallback(requestId: String, sessionId: String, reason: String) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .bridgeFallback, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: reason, responseId: nil
        )
    }

    /// ESS-404 §5: iPhone announces the new generation after processing a
    /// barge-in (or on a fresh turn). Watch treats this as the trigger that
    /// exits the pending window and sets `activeGeneration = generation`.
    static func generationOpen(
        requestId: String,
        sessionId: String,
        generation: Int
    ) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .generationOpen, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: nil,
            responseId: nil, generation: generation
        )
    }

    /// ESS-404 §5 exception branch: iPhone could not send `cancel` on the
    /// WSS, so the pending window must collapse into a single fallback +
    /// structured error card. `reason` explains why.
    static func bargeInFailed(
        requestId: String,
        sessionId: String,
        fromGeneration: Int,
        reason: String
    ) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .bargeInFailed, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: reason,
            responseId: nil, generation: fromGeneration
        )
    }

    static func transportFailed(
        requestId: String,
        sessionId: String,
        generation: Int,
        reason: String
    ) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .transportFailed, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: reason,
            responseId: nil, generation: generation
        )
    }
}

/// The `sendMessageData` key used to distinguish realtime envelopes from
/// legacy protocol-v2 `VoiceStreamChunk` blobs that already flow on the wire.
///
/// Watch encodes an envelope, then sends `[RealtimeMediaMessage.envelopeKey:
/// data]` via `sendMessage` (fast path) and `transferUserInfo` (durable ack).
enum RealtimeMediaMessage {
    static let uplinkEnvelopeKey = "wristagent_realtime_uplink"
    static let uplinkAckEnvelopeKey = "wristagent_realtime_uplink_ack"
    static let channelReadyEnvelopeKey = "wristagent_realtime_channel_ready"
    static let downlinkEnvelopeKey = "wristagent_realtime_downlink"
}

/// Explicit transport-level readiness signal. Unlike an audio append ACK this
/// is emitted as soon as the iPhone has established the selected realtime
/// transport, so entering a conversation never depends on the user speaking
/// or finishing the first recording.
struct RealtimeChannelReady: Codable, Equatable, Sendable {
    let requestId: String
    let sessionId: String
}
