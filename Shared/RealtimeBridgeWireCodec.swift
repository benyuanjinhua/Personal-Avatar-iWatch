import Foundation

/// ESS-321 Bridge WSS wire codec.
///
/// Bridge PR #113 `server.mjs` expects **flat** JSON messages on the realtime
/// socket — the top-level `type` field distinguishes stream lifecycle events,
/// with the audio payload inlined next to `sequence` / `sample_rate` / `codec`.
///
///   Uplink  : { "type": "start",          "protocol_version": 1, "request_id": "...", "session_id": "...", "sample_rate": 16000, "codec": "pcm_s16le" }
///   Uplink  : { "type": "audio.append",   "request_id": "...", "session_id": "...", "sequence": N, "sample_rate": 16000, "codec": "pcm_s16le", "audio": "<base64>" }
///   Uplink  : { "type": "audio.commit",   "request_id": "...", "session_id": "..." }
///   Uplink  : { "type": "playback.started", "request_id": "...", "session_id": "...", "response_id": "..." }
///   Uplink  : { "type": "playback.ended",   "request_id": "...", "session_id": "...", "response_id": "...", "bytes_played": N }
///   Uplink  : { "type": "close",          "request_id": "...", "session_id": "...", "reason": "..." }
///
///   Downlink: { "type": "audio.delta",    "request_id": "...", "session_id": "...", "response_id": "...", "sequence": N, "sample_rate": 24000, "codec": "pcm_s16le", "audio": "<base64>" }
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
        case start(RealtimeStreamStart)
        case audioAppend(VoiceStreamChunk)
        case audioCommit(RealtimeStreamCommit)
        case playbackStarted(requestId: String, sessionId: String, responseId: String)
        case playbackEnded(requestId: String, sessionId: String, responseId: String, bytesPlayed: Int)
        case close(requestId: String, sessionId: String, reason: String)
    }

    /// Encode a Watch→iPhone envelope into the flat JSON string the Bridge
    /// accepts on the WSS socket. Returns `nil` when the envelope carries no
    /// bridge-forwardable payload (e.g. adapter-local fallback signals).
    static func encode(_ envelope: RealtimeUplinkEnvelope) -> String? {
        switch envelope.kind {
        case .streamStart:
            guard let start = envelope.start else { return nil }
            return encode(UplinkFlatFrame.start(start))
        case .audioAppend:
            guard let chunk = envelope.append else { return nil }
            return encode(.audioAppend(chunk))
        case .audioCommit:
            guard let commit = envelope.commit else { return nil }
            return encode(.audioCommit(commit))
        case .playbackStarted:
            guard let receipt = envelope.playback else { return nil }
            return encode(.playbackStarted(
                requestId: receipt.requestId,
                sessionId: receipt.sessionId,
                responseId: receipt.responseId
            ))
        case .playbackEnded:
            guard let receipt = envelope.playback else { return nil }
            return encode(.playbackEnded(
                requestId: receipt.requestId,
                sessionId: receipt.sessionId,
                responseId: receipt.responseId,
                bytesPlayed: receipt.bytesPlayed ?? 0
            ))
        case .fallback:
            // Fallback is a coordinator-local signal; the Bridge sees it as a
            // socket close, not a business message. Emit `close` instead.
            guard let descriptor = envelope.fallback else { return nil }
            return encode(.close(
                requestId: descriptor.requestId,
                sessionId: descriptor.sessionId,
                reason: descriptor.reason
            ))
        }
    }

    static func encode(_ frame: UplinkFlatFrame) -> String? {
        var payload: [String: Any] = [:]
        switch frame {
        case .start(let start):
            payload["type"] = "start"
            payload["protocol_version"] = start.protocolVersionForWire
            payload["request_id"] = start.requestId
            payload["session_id"] = start.sessionId
            payload["sample_rate"] = start.sampleRate
            payload["codec"] = start.codec
        case .audioAppend(let chunk):
            payload["type"] = "audio.append"
            payload["request_id"] = chunk.requestId
            payload["session_id"] = chunk.streamId
            payload["sequence"] = chunk.sequence
            payload["sample_rate"] = chunk.sampleRate
            payload["codec"] = chunk.codec
            payload["audio"] = chunk.payload.base64EncodedString()
            if chunk.endOfStream { payload["end_of_stream"] = true }
        case .audioCommit(let commit):
            payload["type"] = "audio.commit"
            payload["request_id"] = commit.requestId
            payload["session_id"] = commit.sessionId
        case .playbackStarted(let requestId, let sessionId, let responseId):
            payload["type"] = "playback.started"
            payload["request_id"] = requestId
            payload["session_id"] = sessionId
            payload["response_id"] = responseId
        case .playbackEnded(let requestId, let sessionId, let responseId, let bytesPlayed):
            payload["type"] = "playback.ended"
            payload["request_id"] = requestId
            payload["session_id"] = sessionId
            payload["response_id"] = responseId
            payload["bytes_played"] = bytesPlayed
        case .close(let requestId, let sessionId, let reason):
            payload["type"] = "close"
            payload["request_id"] = requestId
            payload["session_id"] = sessionId
            payload["reason"] = reason
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Downlink (Bridge → iPhone)

    /// Decode a flat Bridge-shape JSON string into the tagged-union envelope
    /// the Watch coordinator consumes.
    static func decode(_ text: String) -> RealtimeDownlinkEnvelope? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> RealtimeDownlinkEnvelope? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = raw["type"] as? String,
              let requestId = raw["request_id"] as? String,
              let sessionId = raw["session_id"] as? String else { return nil }
        switch type {
        case "audio.delta":
            guard
                let sequence = raw["sequence"] as? Int,
                let base64 = raw["audio"] as? String,
                let audioBytes = Data(base64Encoded: base64)
            else { return nil }
            let codec = (raw["codec"] as? String) ?? RealtimeMediaFormat.downlinkPCM16.codec
            let sampleRate = (raw["sample_rate"] as? Int) ?? RealtimeMediaFormat.downlinkPCM16.sampleRate
            let capturedAt = (raw["captured_at_ms"] as? Int64)
                ?? Int64((raw["captured_at_ms"] as? Int) ?? 0)
            let endOfStream = (raw["end_of_stream"] as? Bool) ?? false
            // ESS-330: preserve Bridge PR #113's `response_id` so playback
            // receipts can identify the originating response, not the session.
            let responseId = raw["response_id"] as? String
            let chunk = VoiceStreamChunk(
                requestId: requestId, streamId: sessionId, direction: .downlink,
                sequence: sequence, capturedAtMs: capturedAt > 0 ? capturedAt : 1,
                codec: codec, sampleRate: sampleRate,
                payload: audioBytes, endOfStream: endOfStream,
                responseId: responseId
            )
            return .audioDelta(chunk)
        case "transcript.delta":
            return .transcriptDelta(
                requestId: requestId, sessionId: sessionId,
                text: (raw["text"] as? String) ?? ""
            )
        case "transcript.final":
            return .transcriptFinal(
                requestId: requestId, sessionId: sessionId,
                text: (raw["text"] as? String) ?? ""
            )
        case "audio.done":
            return .audioDone(requestId: requestId, sessionId: sessionId)
        case "playback.clear":
            return .playbackClear(requestId: requestId, sessionId: sessionId)
        case "response.interrupted":
            return .responseInterrupted(
                requestId: requestId, sessionId: sessionId,
                reason: (raw["reason"] as? String) ?? "unspecified"
            )
        case "stream.fallback":
            return .bridgeFallback(
                requestId: requestId, sessionId: sessionId,
                reason: (raw["reason"] as? String) ?? "unspecified"
            )
        default:
            return nil
        }
    }
}

private extension RealtimeStreamStart {
    /// The wire schema Bridge PR #113 stamps as `protocol_version: 1`; expose
    /// it explicitly so we don't drift when `RealtimeWireVersion.uplink`
    /// changes on our side of the boundary.
    var protocolVersionForWire: Int { RealtimeWireVersion.uplink }
}
