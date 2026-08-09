import Foundation

/// ESS-321 Bridge WSS wire codec.
///
/// Bridge PR #113 `server.mjs` expects **flat** JSON messages on the realtime
/// socket — the top-level `type` field distinguishes stream lifecycle events,
/// with the audio payload inlined next to `sequence` / `sample_rate` / `codec`.
///
/// Uplink  : { "type": "start",          "protocol_version": 1, "request_id": "...", "session_id": "...", "sample_rate": 16000, "codec": "pcm_s16le" }
/// Uplink  : { "type": "audio.append",   "request_id": "...", "session_id": "...", "sequence": N, "sample_rate": 16000, "codec": "pcm_s16le", "audio": "<base64>" }
/// Uplink  : { "type": "audio.commit",   "request_id": "...", "session_id": "..." }
/// Uplink  : { "type": "playback.started", "request_id": "...", "session_id": "...", "response_id": "..." }
/// Uplink  : { "type": "playback.ended",   "request_id": "...", "session_id": "...", "response_id": "...", "bytes_played": N }
/// Uplink  : { "type": "close",          "request_id": "...", "session_id": "...", "reason": "..." }
///
/// ESS-571 Phase 0: when `RealtimeEnvelopeFlag.useV1Envelope` is set, each
/// message also carries `conversation_id` and `turn_id` for dual-write.
///
///   Downlink: { "type": "audio.delta",    "request_id": "...", "session_id": "...", "sequence": N, "sample_rate": 24000, "codec": "pcm_s16le", "audio": "<base64>" }
///   Downlink: { "type": "transcript.delta"/"transcript.final", "request_id": "...", "session_id": "...", "text": "..." }
///   Downlink: { "type": "audio.done",     "request_id": "...", "session_id": "..." }
///   Downlink: { "type": "playback.clear", "request_id": "...", "session_id": "..." }
///   Downlink: { "type": "response.interrupted", "request_id": "...", "session_id": "...", "reason": "..." }
///   Downlink: { "type": "stream.fallback",      "request_id": "...", "session_id": "...", "reason": "..." }
///
/// This codec sits between the coordinator's `RealtimeUplinkEnvelope` /
/// `RealtimeDownlinkEnvelope` (which is the Watch↔iPhone hop, tagged-union
/// shape) and the flat Bridge wire shape. Keeping the translation in a single
/// file means any Bridge schema drift lives in one place.
enum RealtimeBridgeWireCodec {

    // MARK: - Uplink (iPhone → Bridge)

    enum UplinkFlatFrame {
        case start(RealtimeStreamStart, conversationId: String? = nil, turnId: String? = nil)
        case audioAppend(VoiceStreamChunk, conversationId: String? = nil, turnId: String? = nil)
        case audioCommit(RealtimeStreamCommit, conversationId: String? = nil, turnId: String? = nil)
        case playbackStarted(requestId: String, sessionId: String, responseId: String, conversationId: String? = nil, turnId: String? = nil)
        case playbackEnded(requestId: String, sessionId: String, responseId: String, bytesPlayed: Int, conversationId: String? = nil, turnId: String? = nil)
        case close(requestId: String, sessionId: String, reason: String, conversationId: String? = nil, turnId: String? = nil)
    }

    /// Encode a Watch→iPhone envelope into the flat JSON string the Bridge
    /// accepts on the WSS socket. Returns `nil` when the envelope carries no
    /// bridge-forwardable payload (e.g. adapter-local fallback signals).
    ///
    /// ESS-571: when `envelope.conversationId` or `envelope.turnId` are
    /// non-nil, they are appended to the JSON payload as dual-write fields.
    static func encode(_ envelope: RealtimeUplinkEnvelope) -> String? {
        let convId = envelope.conversationId
        let tId = envelope.turnId
        switch envelope.kind {
        case .streamStart:
            guard let start = envelope.start else { return nil }
            return encode(UplinkFlatFrame.start(start, conversationId: convId, turnId: tId))
        case .audioAppend:
            guard let chunk = envelope.append else { return nil }
            return encode(.audioAppend(chunk, conversationId: convId, turnId: tId))
        case .audioCommit:
            guard let commit = envelope.commit else { return nil }
            return encode(.audioCommit(commit, conversationId: convId, turnId: tId))
        case .playbackStarted:
            guard let receipt = envelope.playback else { return nil }
            return encode(.playbackStarted(
                requestId: receipt.requestId,
                sessionId: receipt.sessionId,
                responseId: receipt.responseId,
                conversationId: convId, turnId: tId
            ))
        case .playbackEnded:
            guard let receipt = envelope.playback else { return nil }
            return encode(.playbackEnded(
                requestId: receipt.requestId,
                sessionId: receipt.sessionId,
                responseId: receipt.responseId,
                bytesPlayed: receipt.bytesPlayed ?? 0,
                conversationId: convId, turnId: tId
            ))
        case .fallback:
            guard let descriptor = envelope.fallback else { return nil }
            return encode(.close(
                requestId: descriptor.requestId,
                sessionId: descriptor.sessionId,
                reason: descriptor.reason,
                conversationId: convId, turnId: tId
            ))
        case .bargeInRequest:
            return nil
        case .conversationClose:
            // ESS-551：会话关闭信号只走 Gateway 直连路径（PhoneRealtimeAgent
            // Transport），Bridge 旧路无对应帧——返回 nil 不桥接。
            return nil
        }
    }

    static func encode(_ frame: UplinkFlatFrame) -> String? {
        var payload: [String: Any] = [:]
        var convId: String? = nil
        var tId: String? = nil
        switch frame {
        case .start(let start, let conversationId, let turnId):
            convId = conversationId; tId = turnId
            payload["type"] = "start"
            payload["protocol_version"] = start.protocolVersionForWire
            payload["request_id"] = start.requestId
            payload["session_id"] = start.sessionId
            payload["sample_rate"] = start.sampleRate
            payload["codec"] = start.codec
        case .audioAppend(let chunk, let conversationId, let turnId):
            convId = conversationId; tId = turnId
            payload["type"] = "audio.append"
            payload["request_id"] = chunk.requestId
            payload["session_id"] = chunk.streamId
            payload["sequence"] = chunk.sequence
            payload["sample_rate"] = chunk.sampleRate
            payload["codec"] = chunk.codec
            payload["audio"] = chunk.payload.base64EncodedString()
            if chunk.endOfStream { payload["end_of_stream"] = true }
        case .audioCommit(let commit, let conversationId, let turnId):
            convId = conversationId; tId = turnId
            payload["type"] = "audio.commit"
            payload["request_id"] = commit.requestId
            payload["session_id"] = commit.sessionId
        case .playbackStarted(let requestId, let sessionId, let responseId, let conversationId, let turnId):
            convId = conversationId; tId = turnId
            payload["type"] = "playback.started"
            payload["request_id"] = requestId
            payload["session_id"] = sessionId
            payload["response_id"] = responseId
        case .playbackEnded(let requestId, let sessionId, let responseId, let bytesPlayed, let conversationId, let turnId):
            convId = conversationId; tId = turnId
            payload["type"] = "playback.ended"
            payload["request_id"] = requestId
            payload["session_id"] = sessionId
            payload["response_id"] = responseId
            payload["bytes_played"] = bytesPlayed
        case .close(let requestId, let sessionId, let reason, let conversationId, let turnId):
            convId = conversationId; tId = turnId
            payload["type"] = "close"
            payload["request_id"] = requestId
            payload["session_id"] = sessionId
            payload["reason"] = reason
        }
        // ESS-571 Phase 0: dual-write conversation/turn IDs when present
        if let cid = convId { payload["conversation_id"] = cid }
        if let tid = tId { payload["turn_id"] = tid }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Downlink (Bridge → iPhone)

    enum DecodeOutcome {
        case envelope(RealtimeDownlinkEnvelope)
        case unrecognised(type: String)
        case malformed
    }

    static func decode(_ text: String) -> RealtimeDownlinkEnvelope? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> RealtimeDownlinkEnvelope? {
        if case .envelope(let envelope) = decodeOutcome(data) { return envelope }
        return nil
    }

    static func decodeOutcome(_ text: String) -> DecodeOutcome {
        guard let data = text.data(using: .utf8) else { return .malformed }
        return decodeOutcome(data)
    }

    static func decodeOutcome(_ data: Data) -> DecodeOutcome {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard let type = raw["type"] as? String,
              let requestId = raw["request_id"] as? String,
              let sessionId = raw["session_id"] as? String else {
            return .malformed
        }
        // ESS-571: extract new envelope fields when present (forward-compat)
        let conversationId = raw["conversation_id"] as? String
        let turnId = raw["turn_id"] as? String
        switch type {
        case "ready":
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .ready, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil, transcript: nil, reason: nil, responseId: nil,
                conversationId: conversationId, turnId: turnId
            ))
        case "audio.delta":
            guard
                let sequence = raw["sequence"] as? Int,
                let base64 = raw["audio"] as? String,
                let audioBytes = Data(base64Encoded: base64)
            else { return .malformed }
            let codec = (raw["codec"] as? String) ?? RealtimeMediaFormat.downlinkPCM16.codec
            let sampleRate = (raw["sample_rate"] as? Int) ?? RealtimeMediaFormat.downlinkPCM16.sampleRate
            let capturedAt = (raw["captured_at_ms"] as? Int64)
                ?? Int64((raw["captured_at_ms"] as? Int) ?? 0)
            let endOfStream = (raw["end_of_stream"] as? Bool) ?? false
            let responseId = raw["response_id"] as? String
            let generation = raw["generation"] as? Int
            let chunk = VoiceStreamChunk(
                requestId: requestId, streamId: sessionId, direction: .downlink,
                sequence: sequence, capturedAtMs: capturedAt > 0 ? capturedAt : 1,
                codec: codec, sampleRate: sampleRate,
                payload: audioBytes, endOfStream: endOfStream
            )
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .audioDelta,
                requestId: requestId, sessionId: sessionId,
                sequence: sequence,
                audio: chunk,
                transcript: nil,
                reason: nil,
                responseId: responseId,
                generation: generation,
                conversationId: conversationId, turnId: turnId
            ))
        case "transcript.delta":
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .transcriptDelta, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil,
                transcript: (raw["text"] as? String) ?? "", reason: nil,
                responseId: nil,
                conversationId: conversationId, turnId: turnId
            ))
        case "transcript.final":
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .transcriptFinal, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil,
                transcript: (raw["text"] as? String) ?? "", reason: nil,
                responseId: nil,
                conversationId: conversationId, turnId: turnId
            ))
        case "audio.done":
            let responseId = raw["response_id"] as? String
            let generation = raw["generation"] as? Int
            let finalSequence = raw["final_sequence"] as? Int
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .audioDone,
                requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil, transcript: nil, reason: nil,
                responseId: responseId,
                generation: generation,
                finalSequence: finalSequence,
                conversationId: conversationId, turnId: turnId
            ))
        case "playback.clear":
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .playbackClear, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil, transcript: nil, reason: nil, responseId: nil,
                conversationId: conversationId, turnId: turnId
            ))
        case "response.interrupted":
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .responseInterrupted, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil, transcript: nil,
                reason: (raw["reason"] as? String) ?? "unspecified",
                responseId: nil,
                conversationId: conversationId, turnId: turnId
            ))
        case "stream.fallback":
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .bridgeFallback, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil, transcript: nil,
                reason: (raw["reason"] as? String) ?? "unspecified",
                responseId: nil,
                conversationId: conversationId, turnId: turnId
            ))
        case "generation.open":
            guard let generation = raw["generation"] as? Int else { return .malformed }
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .generationOpen, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil, transcript: nil, reason: nil,
                responseId: nil, generation: generation,
                conversationId: conversationId, turnId: turnId
            ))
        case "bargein.failed":
            let fromGeneration = raw["generation"] as? Int ?? -1
            let reason = (raw["reason"] as? String) ?? "unspecified"
            return .envelope(RealtimeDownlinkEnvelope(
                protocolVersion: RealtimeWireVersion.downlink,
                kind: .bargeInFailed, requestId: requestId, sessionId: sessionId,
                sequence: nil, audio: nil, transcript: nil, reason: reason,
                responseId: nil, generation: fromGeneration,
                conversationId: conversationId, turnId: turnId
            ))
        default:
            return .unrecognised(type: type)
        }
    }
}

private extension RealtimeStreamStart {
    /// The wire schema Bridge PR #113 stamps as `protocol_version: 1`; expose
    /// it explicitly so we don't drift when `RealtimeWireVersion.uplink`
    /// changes on our side of the boundary.
    var protocolVersionForWire: Int { RealtimeWireVersion.uplink }
}
