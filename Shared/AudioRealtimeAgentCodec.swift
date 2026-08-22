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
        case sessionStart(sessionId: String, requestId: String, generation: Int, protocolVersion: Int)
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
        case close(reason: String?)
    }

    /// Encode an uplink frame into the flat JSON string the Gateway expects.
    /// Returns `nil` on serialization failure.
    static func encode(_ frame: UplinkFrame) -> String? {
        var payload: [String: Any] = [:]
        switch frame {
        case .sessionStart(let sessionId, let requestId, let generation, let protocolVersion):
            payload["type"] = "session.start"
            payload["session_id"] = sessionId
            payload["request_id"] = requestId
            payload["generation"] = generation
            payload["protocol_version"] = protocolVersion
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
        case .close(let reason):
            payload["type"] = "close"
            if let reason { payload["reason"] = reason }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Structured log tag for an uplink frame — type + key identity fields
    /// only. Never includes raw audio payload or token bytes. Safe to log
    /// with `privacy: .public`.
    static func logTag(_ frame: UplinkFrame) -> String {
        switch frame {
        case .sessionStart(let sid, let rid, let gen, _):
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
        /// Gateway `audio.segment_done`（ESS-969）——**本段结束，回合未结束**。
        ///
        /// 工具调用回合里模型先说「我正在查询…」并关闭该 response，跑完工具后再开
        /// 第二个 response 说真正的答案。屏障语义与 `audio.done` 一致（`final_sequence`
        /// 之前的序号收齐即释放），但客户端**必须保持本轮打开**：退回等待态、
        /// 重新武装有界超时、**不开下一轮**（Watch：`SessionController.markAnswerInterim`）。
        ///
        /// 一个回合可以有 0..N 个 `audio.segment_done`，但有且只有一个 `audio.done`。
        case audioSegmentDone(sessionId: String, requestId: String, responseId: String,
                              generation: Int, segmentIndex: Int, finalSequence: Int)
        /// Gateway `audio.segment_dropped`（ESS-957）——本回合 `audio.done`
        /// 之后上游又产出了音频，被网关丢弃。
        ///
        /// 工具调用场景：模型先说「我正在查询…」并 `audio.done`，工具返回后
        /// 再产出**真正的答案**；而网关的会话模型把一个回合绑死成一段回答
        /// （`realtime-session.mjs:98` 的 `responseId = request_id:genN`），
        /// 第二段无处可回。能力层的修复见 ESS-969；在那之前，至少不能让
        /// 用户对着一句「我正在查询…」干等——这条事件就是唯一的知情来源。
        case segmentDropped(sessionId: String, requestId: String, responseId: String,
                            generation: Int, sequence: Int, droppedCount: Int,
                            reason: String?)
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

        case "audio.segment_done":
            guard let sid = raw["session_id"] as? String,
                  let rid = raw["request_id"] as? String,
                  let respId = raw["response_id"] as? String,
                  let gen = raw["generation"] as? Int,
                  // `final_sequence` 是屏障值，缺了就无法判定这一段收齐没有。
                  let finalSeq = raw["final_sequence"] as? Int else { return .malformed }
            // `segment_index` 只用于取证与排序，缺省按 0——不值得为它把整帧判死。
            let segmentIndex = (raw["segment_index"] as? Int) ?? 0
            return .event(.audioSegmentDone(
                sessionId: sid, requestId: rid, responseId: respId,
                generation: gen, segmentIndex: segmentIndex, finalSequence: finalSeq
            ))

        case "audio.segment_dropped":
            guard let sid = raw["session_id"] as? String,
                  let rid = raw["request_id"] as? String,
                  let respId = raw["response_id"] as? String,
                  let gen = raw["generation"] as? Int,
                  let sequence = raw["sequence"] as? Int else { return .malformed }
            // `dropped_count` / `reason` 是取证补充，缺了不该把整帧判死——
            // 那等于又回到「客户端什么都不知道」的老路。
            let droppedCount = (raw["dropped_count"] as? Int) ?? 1
            let reason = raw["reason"] as? String
            return .event(.segmentDropped(
                sessionId: sid, requestId: rid, responseId: respId,
                generation: gen, sequence: sequence,
                droppedCount: droppedCount, reason: reason
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
