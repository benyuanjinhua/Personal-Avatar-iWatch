import Foundation

/// ESS-402 native Audio Realtime Agent wire codec, aligned with Gateway PR #159
/// (`AudioRealtimeGateway/realtime-session.mjs` ALLOWED_KEYS).
///
/// Distinct from `RealtimeBridgeWireCodec`: the Agent Gateway enforces a strict
/// JSON schema of its own with `session_id` / `request_id` / `generation`
/// (Number) / `response_id` / `sequence`. Auth is per-WSS-upgrade via the HTTP
/// `Authorization: Bearer <token>` header (not in the JSON payload), per ESS-388
/// v_final A1.
///
/// ### Uplink (iPhone → Agent Gateway) — matched to ALLOWED_KEYS
///
///   { "type": "session.start",      "session_id":"...","request_id":"...","generation":N,"protocol_version":1 }
///   { "type": "audio.append",       "session_id":"...","request_id":"...","generation":N,"sequence":N,"audio":"<base64>" [,"sample_rate":16000,"codec":"pcm_s16le"] }
///   { "type": "audio.commit",       "session_id":"...","request_id":"...","generation":N,"sequence":N }
///   { "type": "cancel",             "session_id":"...","request_id":"...","generation":N [,"reason":"..."] }
///   { "type": "playback.started",   "session_id":"...","request_id":"...","response_id":"..." }
///   { "type": "playback.ended",     "session_id":"...","request_id":"...","response_id":"..." }
///   { "type": "ping",               "nonce":"..." }
///   { "type": "close"               [,"reason":"..."] }
///
/// ### Downlink (Agent Gateway → iPhone) — what the Gateway emits
///
///   { "type":"ready",           "session_id":"...","request_id":"...","generation":N,"response_id":"...","heartbeat_interval_ms":N,"protocol_version":1 }
///   { "type":"audio.delta",     "session_id":"...","request_id":"...","response_id":"...","generation":N,"sequence":N,"sample_rate":24000,"codec":"pcm_s16le","audio":"<base64>" }
///   { "type":"audio.done",      "session_id":"...","request_id":"...","response_id":"...","generation":N,"final_sequence":N }
///   { "type":"cancel.ack",      "session_id":"...","request_id":"...","generation":N,"cancelled_response_id":"..." }
///   { "type":"error",           "code":"...","session_id":"...","request_id":"...","generation":N,"retriable":bool [,"detail":"..."...] }
///   { "type":"pong",            "nonce":"..." }
///   { "type":"server_ping",     "at":N }
enum AudioRealtimeAgentCodec {

    // MARK: - Uplink frames (matched to Gateway CLIENT_SCHEMAS)

    enum UplinkFrame {
        /// Maps to Gateway `session.start`. Auth token is sent via HTTP header,
        /// NOT in the JSON payload (ESS-388 A1: token never in JSON).
        /// ESS-551: conversation/turn 主键经 `meta` 子对象携带（可选；缺失时
        /// Gateway 退回 (requestId, sessionId) 旧隔离基线）。
        case sessionStart(sessionId: String, requestId: String, generation: Int, protocolVersion: Int,
                          conversationId: String? = nil, turnId: String? = nil)
        /// Maps to Gateway `audio.append`.
        case audioAppend(sessionId: String, requestId: String, generation: Int,
                         sequence: Int, sampleRate: Int?, codec: String?, audioBase64: String)
        /// Maps to Gateway `audio.commit`.
        case audioCommit(sessionId: String, requestId: String, generation: Int, sequence: Int)
        /// Maps to Gateway `cancel`.
        case cancel(sessionId: String, requestId: String, generation: Int, reason: String?)
        /// Maps to Gateway `playback.started`.
        case playbackStarted(sessionId: String, requestId: String, responseId: String)
        /// Maps to Gateway `playback.ended`.
        case playbackEnded(sessionId: String, requestId: String, responseId: String)
        /// Maps to Gateway `ping`.
        case ping(nonce: String)
        /// Maps to Gateway `close`.
        /// ESS-551: 仅会话终结时携带 meta.conversation_id——Gateway 据此拒绝
        /// 该 conversation 下一切迟到帧（每回合拆连不带 meta）。
        case close(reason: String?, conversationId: String? = nil, turnId: String? = nil)
    }

    /// Encode an uplink frame into the flat JSON string the Gateway expects.
    /// Returns `nil` on serialization failure.
    static func encode(_ frame: UplinkFrame) -> String? {
        var payload: [String: Any] = [:]
        switch frame {
        case .sessionStart(let sessionId, let requestId, let generation, let protocolVersion,
                           let conversationId, let turnId):
            payload["type"] = "session.start"
            payload["session_id"] = sessionId
            payload["request_id"] = requestId
            payload["generation"] = generation
            payload["protocol_version"] = protocolVersion
            if let meta = Self.metaPayload(conversationId: conversationId, turnId: turnId) {
                payload["meta"] = meta
            }
        case .audioAppend(let sessionId, let requestId, let generation,
                          let sequence, let sampleRate, let codec, let audioBase64):
            payload["type"] = "audio.append"
            payload["session_id"] = sessionId
            payload["request_id"] = requestId
            payload["generation"] = generation
            payload["sequence"] = sequence
            payload["audio"] = audioBase64
            if let sr = sampleRate { payload["sample_rate"] = sr }
            if let c = codec { payload["codec"] = c }
        case .audioCommit(let sessionId, let requestId, let generation, let sequence):
            payload["type"] = "audio.commit"
            payload["session_id"] = sessionId
            payload["request_id"] = requestId
            payload["generation"] = generation
            payload["sequence"] = sequence
        case .cancel(let sessionId, let requestId, let generation, let reason):
            payload["type"] = "cancel"
            payload["session_id"] = sessionId
            payload["request_id"] = requestId
            payload["generation"] = generation
            if let reason { payload["reason"] = reason }
        case .playbackStarted(let sessionId, let requestId, let responseId):
            payload["type"] = "playback.started"
            payload["session_id"] = sessionId
            payload["request_id"] = requestId
            payload["response_id"] = responseId
        case .playbackEnded(let sessionId, let requestId, let responseId):
            payload["type"] = "playback.ended"
            payload["session_id"] = sessionId
            payload["request_id"] = requestId
            payload["response_id"] = responseId
        case .ping(let nonce):
            payload["type"] = "ping"
            payload["nonce"] = nonce
        case .close(let reason, let conversationId, let turnId):
            payload["type"] = "close"
            if let reason { payload["reason"] = reason }
            if let meta = Self.metaPayload(conversationId: conversationId, turnId: turnId) {
                payload["meta"] = meta
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// ESS-551：conversation/turn 主键的 `meta` 子对象；两者皆 nil 时返回
    /// nil（不下发空 meta，保持帧面与旧版完全一致）。
    static func metaPayload(conversationId: String?, turnId: String?) -> [String: Any]? {
        var meta: [String: Any] = [:]
        if let conversationId { meta["conversation_id"] = conversationId }
        if let turnId { meta["turn_id"] = turnId }
        return meta.isEmpty ? nil : meta
    }

    /// Structured log tag for an uplink frame — type + key identity fields
    /// only. Never includes raw audio payload or token bytes. Safe to log
    /// with `privacy: .public`.
    static func logTag(_ frame: UplinkFrame) -> String {
        switch frame {
        case .sessionStart(let sid, let rid, let gen, _, _, _):
            return "SEND type=session.start sid=\(sid.prefix(8)) rid=\(rid.prefix(8)) gen=\(gen)"
        case .audioAppend(let sid, let rid, let gen, let seq, _, _, let audioB64):
            return "SEND type=audio.append sid=\(sid.prefix(8)) rid=\(rid.prefix(8)) gen=\(gen) seq=\(seq) audio_bytes=\(audioB64.count)"
        case .audioCommit(let sid, let rid, let gen, let seq):
            return "SEND type=audio.commit sid=\(sid.prefix(8)) rid=\(rid.prefix(8)) gen=\(gen) seq=\(seq)"
        case .cancel(let sid, let rid, let gen, _):
            return "SEND type=cancel sid=\(sid.prefix(8)) rid=\(rid.prefix(8)) gen=\(gen)"
        case .playbackStarted(let sid, let rid, let respId):
            return "SEND type=playback.started sid=\(sid.prefix(8)) rid=\(rid.prefix(8)) resp=\(respId.prefix(8))"
        case .playbackEnded(let sid, let rid, let respId):
            return "SEND type=playback.ended sid=\(sid.prefix(8)) rid=\(rid.prefix(8)) resp=\(respId.prefix(8))"
        case .ping(let nonce):
            return "SEND type=ping nonce=\(nonce.prefix(8))"
        case .close:
            return "SEND type=close"
        }
    }

    // MARK: - Uplink convenience: VoiceStreamChunk → Agent frame

    /// Encode a `VoiceStreamChunk` as an Agent `audio.append` frame.
    static func encodeAudioAppend(
        chunk: VoiceStreamChunk,
        requestId: String,
        generation: Int
    ) -> String? {
        return encode(.audioAppend(
            sessionId: chunk.streamId,
            requestId: requestId,
            generation: generation,
            sequence: chunk.sequence,
            sampleRate: chunk.sampleRate,
            codec: chunk.codec,
            audioBase64: chunk.payload.base64EncodedString()
        ))
    }

    // MARK: - Downlink decode

    enum DecodeOutcome {
        case event(DownlinkEvent)
        case unrecognised(type: String)
        case malformed
    }

    // MARK: - Downlink events (Gateway → iPhone)

    enum DownlinkEvent {
        /// Gateway `ready` — response to `session.start`. Carries the
        /// server-assigned `response_id` and heartbeat interval.
        case ready(sessionId: String, requestId: String, generation: Int,
                   responseId: String, heartbeatIntervalMs: Int, protocolVersion: Int)
        /// Gateway `audio.delta`. `response_id` and `generation` are always
        /// present; `sampleRate`/`codec` default to 24000/pcm_s16le.
        case audioDelta(sessionId: String, requestId: String, responseId: String,
                        generation: Int, sequence: Int, sampleRate: Int,
                        codec: String, audioBytes: Data)
        /// Gateway `audio.done`. `finalSequence` is the highest dense prefix
        /// of downlink sequences the server delivered.
        case audioDone(sessionId: String, requestId: String, responseId: String,
                       generation: Int, finalSequence: Int)
        /// Gateway `cancel.ack` — server-authoritative cancel confirmation.
        case cancelAck(sessionId: String, requestId: String, generation: Int,
                       cancelledResponseId: String)
        /// Gateway `error` with structured code and optional detail.
        case error(code: String, sessionId: String, requestId: String,
                   generation: Int, retriable: Bool, detail: String?)
        /// Gateway `pong` — response to client `ping`.
        case pong(nonce: String)
        /// Gateway `server_ping` — server-driven heartbeat.
        case serverPing(at: Int64)
    }

    static func decodeOutcome(_ text: String) -> DecodeOutcome {
        guard let data = text.data(using: .utf8) else { return .malformed }
        return decodeOutcome(data)
    }

    static func decodeOutcome(_ data: Data) -> DecodeOutcome {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard let type = raw["type"] as? String else { return .malformed }

        switch type {
        case "ready":
            guard let sid = raw["session_id"] as? String,
                  let rid = raw["request_id"] as? String,
                  let gen = raw["generation"] as? Int,
                  let respId = raw["response_id"] as? String else { return .malformed }
            let hbMs = (raw["heartbeat_interval_ms"] as? Int) ?? 15_000
            let pv = (raw["protocol_version"] as? Int) ?? 1
            return .event(.ready(
                sessionId: sid, requestId: rid, generation: gen,
                responseId: respId, heartbeatIntervalMs: hbMs, protocolVersion: pv
            ))

        case "audio.delta":
            guard let sid = raw["session_id"] as? String,
                  let rid = raw["request_id"] as? String,
                  let respId = raw["response_id"] as? String,
                  let gen = raw["generation"] as? Int,
                  let sequence = raw["sequence"] as? Int,
                  let base64 = raw["audio"] as? String,
                  let audioBytes = Data(base64Encoded: base64) else { return .malformed }
            let sampleRate = (raw["sample_rate"] as? Int) ?? RealtimeMediaFormat.downlinkPCM16.sampleRate
            let codec = (raw["codec"] as? String) ?? RealtimeMediaFormat.downlinkPCM16.codec
            return .event(.audioDelta(
                sessionId: sid, requestId: rid, responseId: respId,
                generation: gen, sequence: sequence,
                sampleRate: sampleRate, codec: codec, audioBytes: audioBytes
            ))

        case "audio.done":
            guard let sid = raw["session_id"] as? String,
                  let rid = raw["request_id"] as? String,
                  let respId = raw["response_id"] as? String,
                  let gen = raw["generation"] as? Int,
                  let finalSeq = raw["final_sequence"] as? Int else { return .malformed }
            return .event(.audioDone(
                sessionId: sid, requestId: rid, responseId: respId,
                generation: gen, finalSequence: finalSeq
            ))

        case "cancel.ack":
            guard let sid = raw["session_id"] as? String,
                  let rid = raw["request_id"] as? String,
                  let gen = raw["generation"] as? Int,
                  let cancelledRespId = raw["cancelled_response_id"] as? String else {
                return .malformed
            }
            return .event(.cancelAck(
                sessionId: sid, requestId: rid, generation: gen,
                cancelledResponseId: cancelledRespId
            ))

        case "error":
            guard let code = raw["code"] as? String,
                  let sid = raw["session_id"] as? String,
                  let rid = raw["request_id"] as? String,
                  let gen = raw["generation"] as? Int else { return .malformed }
            let retriable = (raw["retriable"] as? Bool) ?? false
            let detail = raw["detail"] as? String
            return .event(.error(
                code: code, sessionId: sid, requestId: rid, generation: gen,
                retriable: retriable, detail: detail
            ))

        case "pong":
            guard let nonce = raw["nonce"] as? String else { return .malformed }
            return .event(.pong(nonce: nonce))

        case "server_ping":
            guard let at = raw["at"] as? Int64 else { return .malformed }
            return .event(.serverPing(at: at))

        default:
            return .unrecognised(type: type)
        }
    }

    // MARK: - Downlink convenience: convert to existing types

    /// Convert an `audioDelta` event into the project-standard
    /// `VoiceStreamChunk` for downstream playback.
    static func toVoiceStreamChunk(_ event: DownlinkEvent, requestId: String) -> VoiceStreamChunk? {
        guard case .audioDelta(let sessionId, _, _, _, let sequence,
                               let sampleRate, let codec, let audioBytes) = event else {
            return nil
        }
        return VoiceStreamChunk(
            requestId: requestId,
            streamId: sessionId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1,
            codec: codec,
            sampleRate: sampleRate,
            payload: audioBytes,
            endOfStream: false
        )
    }
}
