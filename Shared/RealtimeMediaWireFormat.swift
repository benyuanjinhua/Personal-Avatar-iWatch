import Foundation

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

enum RealtimeUplinkKind: String, Codable, Sendable {
    case streamStart = "stream.start"
    case audioAppend = "audio.append"
    case audioCommit = "audio.commit"
    case playbackStarted = "playback.started"
    case playbackEnded = "playback.ended"
    case fallback = "stream.fallback"
}

struct RealtimeUplinkEnvelope: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let kind: RealtimeUplinkKind
    let start: RealtimeStreamStart?
    let append: VoiceStreamChunk?
    let commit: RealtimeStreamCommit?
    let playback: RealtimePlaybackReceipt?
    let fallback: RealtimeUplinkFallbackDescriptor?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case kind
        case start
        case append
        case commit
        case playback
        case fallback
    }

    static func start(_ start: RealtimeStreamStart) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .streamStart, start: start, append: nil, commit: nil,
            playback: nil, fallback: nil
        )
    }

    static func append(_ chunk: VoiceStreamChunk) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .audioAppend, start: nil, append: chunk, commit: nil,
            playback: nil, fallback: nil
        )
    }

    static func commit(_ commit: RealtimeStreamCommit) -> Self {
        RealtimeUplinkEnvelope(
            protocolVersion: RealtimeWireVersion.uplink,
            kind: .audioCommit, start: nil, append: nil, commit: commit,
            playback: nil, fallback: nil
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
}

struct RealtimeUplinkFallbackDescriptor: Codable, Sendable, Equatable {
    let requestId: String
    let sessionId: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case reason
    }
}

struct RealtimePlaybackReceipt: Codable, Sendable, Equatable {
    let requestId: String
    let sessionId: String
    let responseId: String
    let bytesPlayed: Int?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case responseId = "response_id"
        case bytesPlayed = "bytes_played"
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

    static func audioDelta(_ chunk: VoiceStreamChunk, responseId: String? = nil) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .audioDelta, requestId: chunk.requestId, sessionId: chunk.streamId,
            sequence: chunk.sequence, audio: chunk, transcript: nil, reason: nil,
            responseId: responseId
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

    static func audioDone(requestId: String, sessionId: String, responseId: String? = nil) -> Self {
        RealtimeDownlinkEnvelope(
            protocolVersion: RealtimeWireVersion.downlink,
            kind: .audioDone, requestId: requestId, sessionId: sessionId,
            sequence: nil, audio: nil, transcript: nil, reason: nil,
            responseId: responseId
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
}

/// The `sendMessageData` key used to distinguish realtime envelopes from
/// legacy protocol-v2 `VoiceStreamChunk` blobs that already flow on the wire.
///
/// Watch encodes an envelope, then sends `[RealtimeMediaMessage.envelopeKey:
/// data]` via `sendMessage` (fast path) and `transferUserInfo` (durable ack).
enum RealtimeMediaMessage {
    static let uplinkEnvelopeKey = "wristagent_realtime_uplink"
    static let downlinkEnvelopeKey = "wristagent_realtime_downlink"
}
