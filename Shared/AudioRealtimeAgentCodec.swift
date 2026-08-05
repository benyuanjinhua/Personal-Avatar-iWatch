import Foundation

/// ESS-402 native Audio Realtime Agent wire codec.
///
/// Distinct from `RealtimeBridgeWireCodec`: the Agent Gateway speaks a different
/// event vocabulary than the Mac Bridge, with its own session/turn/generation
/// lifecycle. This codec does NOT reuse the Bridge's `start`/`audio.append`/
/// `audio.delta` flat JSON shape — the Agent protocol carries `session_id`,
/// `turn_id`, and `generation` identifiers inline, and auth is per-session
/// rather than per-request HMAC-signed.
///
/// Wire schema (flat JSON, top-level `type` discriminator):
///
///   Uplink (iPhone → Agent Gateway):
///     { "type": "session.update", "session_id": "...", "token": "..." }
///     { "type": "input_audio.append", "session_id": "...", "turn_id": "...", "sequence": N,
///       "sample_rate": 16000, "codec": "pcm_s16le", "audio": "<base64>" }
///     { "type": "input_audio.commit", "session_id": "...", "turn_id": "...", "sequence": N }
///     { "type": "heartbeat", "session_id": "...", "timestamp_ms": N }
///
///   Downlink (Agent Gateway → iPhone):
///     { "type": "session.created", "session_id": "...", "turn_id": "..." }
///     { "type": "response.audio.delta", "session_id": "...", "turn_id": "...", "generation": "...",
///       "sequence": N, "sample_rate": 24000, "codec": "pcm_s16le", "audio": "<base64>" }
///     { "type": "response.audio.done", "session_id": "...", "turn_id": "...", "generation": "..." }
///     { "type": "response.transcript.delta", "session_id": "...", "turn_id": "...", "text": "..." }
///     { "type": "response.transcript.done", "session_id": "...", "turn_id": "..." }
///     { "type": "heartbeat_ack", "session_id": "...", "timestamp_ms": N }
///     { "type": "error", "session_id": "...", "code": "...", "message": "..." }
enum AudioRealtimeAgentCodec {

    // MARK: - Uplink frames

    enum UplinkFrame {
        case sessionUpdate(sessionId: String, token: String)
        case inputAudioAppend(sessionId: String, turnId: String, sequence: Int,
                              sampleRate: Int, codec: String, audioBase64: String, endOfStream: Bool)
        case inputAudioCommit(sessionId: String, turnId: String, sequence: Int)
        case heartbeat(sessionId: String, timestampMs: Int64)
    }

    /// Encode an uplink frame into the flat JSON string the Agent Gateway
    /// expects on the WSS socket. Returns `nil` on serialization failure.
    static func encode(_ frame: UplinkFrame) -> String? {
        var payload: [String: Any] = [:]
        switch frame {
        case .sessionUpdate(let sessionId, let token):
            payload["type"] = "session.update"
            payload["session_id"] = sessionId
            payload["token"] = token
        case .inputAudioAppend(let sessionId, let turnId, let sequence,
                               let sampleRate, let codec, let audioBase64, let endOfStream):
            payload["type"] = "input_audio.append"
            payload["session_id"] = sessionId
            payload["turn_id"] = turnId
            payload["sequence"] = sequence
            payload["sample_rate"] = sampleRate
            payload["codec"] = codec
            payload["audio"] = audioBase64
            if endOfStream { payload["end_of_stream"] = true }
        case .inputAudioCommit(let sessionId, let turnId, let sequence):
            payload["type"] = "input_audio.commit"
            payload["session_id"] = sessionId
            payload["turn_id"] = turnId
            payload["sequence"] = sequence
        case .heartbeat(let sessionId, let timestampMs):
            payload["type"] = "heartbeat"
            payload["session_id"] = sessionId
            payload["timestamp_ms"] = timestampMs
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Uplink convenience: VoiceStreamChunk → Agent frame

    /// Encode a `VoiceStreamChunk` (the project-wide streaming chunk type) as
    /// an Agent `input_audio.append` frame. This bridges the existing uplink
    /// pipeline into the Agent wire without duplicating the chunk type.
    static func encodeInputAudioAppend(
        chunk: VoiceStreamChunk,
        turnId: String
    ) -> String? {
        return encode(.inputAudioAppend(
            sessionId: chunk.streamId,
            turnId: turnId,
            sequence: chunk.sequence,
            sampleRate: chunk.sampleRate,
            codec: chunk.codec,
            audioBase64: chunk.payload.base64EncodedString(),
            endOfStream: chunk.endOfStream
        ))
    }

    // MARK: - Downlink decode outcome

    /// Decode outcome for a received Agent Gateway frame. Distinguishes
    /// "parsed and routable" from "well-formed but unknown type" from
    /// "malformed bytes" — the transport logs unknown types and keeps
    /// receiving so future frames still arrive.
    enum DecodeOutcome {
        case event(DownlinkEvent)
        /// Well-formed JSON with a `type` field the codec does not recognise.
        case unrecognised(type: String)
        /// Bytes were not decodable as an Agent Gateway frame.
        case malformed
    }

    // MARK: - Downlink events

    enum DownlinkEvent {
        case sessionCreated(sessionId: String, turnId: String?)
        case audioDelta(sessionId: String, turnId: String, generation: String?,
                        sequence: Int, sampleRate: Int, codec: String,
                        audioBytes: Data, endOfStream: Bool, capturedAtMs: Int64?)
        case audioDone(sessionId: String, turnId: String, generation: String?)
        case transcriptDelta(sessionId: String, turnId: String, text: String)
        case transcriptDone(sessionId: String, turnId: String)
        case heartbeatAck(sessionId: String, timestampMs: Int64)
        case error(sessionId: String, code: String, message: String)
    }

    /// Decode a raw JSON string into the decoded outcome.
    static func decodeOutcome(_ text: String) -> DecodeOutcome {
        guard let data = text.data(using: .utf8) else { return .malformed }
        return decodeOutcome(data)
    }

    /// Decode raw bytes into the decoded outcome.
    static func decodeOutcome(_ data: Data) -> DecodeOutcome {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard let type = raw["type"] as? String else { return .malformed }
        let sessionId = raw["session_id"] as? String

        switch type {
        case "session.created":
            guard let sid = sessionId else { return .malformed }
            return .event(.sessionCreated(
                sessionId: sid,
                turnId: raw["turn_id"] as? String
            ))

        case "response.audio.delta":
            guard let sid = sessionId,
                  let turnId = raw["turn_id"] as? String,
                  let sequence = raw["sequence"] as? Int,
                  let base64 = raw["audio"] as? String,
                  let audioBytes = Data(base64Encoded: base64) else { return .malformed }
            let sampleRate = (raw["sample_rate"] as? Int) ?? RealtimeMediaFormat.downlinkPCM16.sampleRate
            let codec = (raw["codec"] as? String) ?? RealtimeMediaFormat.downlinkPCM16.codec
            let generation = raw["generation"] as? String
            let endOfStream = (raw["end_of_stream"] as? Bool) ?? false
            var capturedAtMs: Int64? = nil
            if let ms = raw["captured_at_ms"] as? Int64 { capturedAtMs = ms }
            else if let msInt = raw["captured_at_ms"] as? Int { capturedAtMs = Int64(msInt) }
            return .event(.audioDelta(
                sessionId: sid, turnId: turnId, generation: generation,
                sequence: sequence, sampleRate: sampleRate, codec: codec,
                audioBytes: audioBytes, endOfStream: endOfStream, capturedAtMs: capturedAtMs
            ))

        case "response.audio.done":
            guard let sid = sessionId,
                  let turnId = raw["turn_id"] as? String else { return .malformed }
            return .event(.audioDone(
                sessionId: sid, turnId: turnId,
                generation: raw["generation"] as? String
            ))

        case "response.transcript.delta":
            guard let sid = sessionId,
                  let turnId = raw["turn_id"] as? String else { return .malformed }
            return .event(.transcriptDelta(
                sessionId: sid, turnId: turnId,
                text: (raw["text"] as? String) ?? ""
            ))

        case "response.transcript.done":
            guard let sid = sessionId,
                  let turnId = raw["turn_id"] as? String else { return .malformed }
            return .event(.transcriptDone(sessionId: sid, turnId: turnId))

        case "heartbeat_ack":
            guard let sid = sessionId,
                  let ts = raw["timestamp_ms"] as? Int64 else { return .malformed }
            return .event(.heartbeatAck(sessionId: sid, timestampMs: ts))

        case "error":
            guard let sid = sessionId else { return .malformed }
            return .event(.error(
                sessionId: sid,
                code: (raw["code"] as? String) ?? "unknown",
                message: (raw["message"] as? String) ?? ""
            ))

        default:
            return .unrecognised(type: type)
        }
    }

    // MARK: - Downlink convenience: convert to existing types

    /// Convert an `audioDelta` event into the project-standard
    /// `VoiceStreamChunk` for downstream playback. Returns `nil` if the
    /// event is not an audio delta.
    static func toVoiceStreamChunk(_ event: DownlinkEvent, requestId: String) -> VoiceStreamChunk? {
        guard case .audioDelta(let sessionId, _, _,
                               let sequence, let sampleRate, let codec,
                               let audioBytes, let endOfStream, let capturedAtMs) = event else {
            return nil
        }
        return VoiceStreamChunk(
            requestId: requestId,
            streamId: sessionId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: capturedAtMs ?? 1,
            codec: codec,
            sampleRate: sampleRate,
            payload: audioBytes,
            endOfStream: endOfStream
        )
    }
}
