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
        turnId: String? = nil
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
    /// ESS-960 缺陷 4：通道终态的显式信号。此前 `.failed` 在
    /// `PhoneConnectivity` 的 `onStateChange` 里被整条丢掉（那个闭包只认
    /// `.active`），Watch 侧因此永远等不到「通道死了」，用户看到的就是安静。
    static let channelFailedEnvelopeKey = "wristagent_realtime_channel_failed"
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

/// ESS-960：`RealtimeChannelReady` 的对称面——iPhone 侧实时通道走到终态。
///
/// 与 `stream.fallback`（下行快通道死掉、降级到整文件回放，用户仍能拿到结果）
/// **不是**一回事：这条说的是本回合的通道彻底没了，Watch 必须收口到 P6
/// 失败态并给用户一行可行动文案，而不是继续假装在听。
struct RealtimeChannelFailed: Codable, Equatable, Sendable {
    let requestId: String
    let sessionId: String
    /// 机器可读的失败原因（如 `gateway_error_ERR_STREAM_SEQUENCE`），
    /// 只进日志取证，不进用户文案（PRD 文案纪律：不出现错误码）。
    let reason: String
}
