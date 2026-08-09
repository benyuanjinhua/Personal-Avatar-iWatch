import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-402 Audio Realtime Agent codec tests — aligned with Gateway PR #159.
///
/// Validates:
///   - Uplink encode produces flat JSON matching Gateway ALLOWED_KEYS.
///   - Downlink decode correctly parses every Gateway event type.
///   - Round-trip: downlink JSON → VoiceStreamChunk.
///   - Edge cases: malformed JSON, missing fields, unknown types.
final class AudioRealtimeAgentCodecTests: XCTestCase {
    private let sessionId = "e4f01000-0000-4000-8000-000000000001"
    private let requestId = "e4f02000-0000-4000-8000-000000000002"

    private func decodedJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    // MARK: - Uplink encode

    func testSessionStartEncodes() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .sessionStart(sessionId: sessionId, requestId: requestId,
                          generation: 1, protocolVersion: 1)
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "session.start")
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["request_id"] as? String, requestId)
        XCTAssertEqual(obj["generation"] as? Int, 1)
        XCTAssertEqual(obj["protocol_version"] as? Int, 1)
        // Token must NOT be in the JSON payload (it's in HTTP header)
        XCTAssertNil(obj["token"])
        // ESS-551 A4: meta omitted entirely when nil (backward compatible).
        XCTAssertNil(obj["meta"])
    }

    /// ESS-551 A4: session.start with meta carries conversation_id / turn_id
    /// verbatim in the `meta` sub-object, and the log tag surfaces them.
    func testSessionStartWithMetaEncodes() throws {
        let meta: [String: Any] = [
            "conversation_id": "0198c001-0000-7000-8000-0000000000aa",
            "turn_id": "0198c001-0000-7000-8000-0000000000bb",
        ]
        let frame = AudioRealtimeAgentCodec.UplinkFrame.sessionStart(
            sessionId: sessionId, requestId: requestId,
            generation: 1, protocolVersion: 1, meta: meta
        )
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(frame))
        let obj = try XCTUnwrap(decodedJSON(text))
        let encodedMeta = try XCTUnwrap(obj["meta"] as? [String: Any])
        XCTAssertEqual(encodedMeta["conversation_id"] as? String,
                       "0198c001-0000-7000-8000-0000000000aa")
        XCTAssertEqual(encodedMeta["turn_id"] as? String,
                       "0198c001-0000-7000-8000-0000000000bb")

        let tag = AudioRealtimeAgentCodec.logTag(frame)
        XCTAssertTrue(tag.contains("cid=0198c001"), "logTag must surface the conversation prefix: \(tag)")
        XCTAssertTrue(tag.contains("turn=0198c001"), "logTag must surface the turn prefix: \(tag)")
    }

    func testAudioAppendEncodes() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .audioAppend(sessionId: sessionId, requestId: requestId,
                         generation: 1, sequence: 3,
                         sampleRate: 16_000, codec: "pcm_s16le",
                         audioBase64: "dGVzdA==")
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "audio.append")
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["request_id"] as? String, requestId)
        XCTAssertEqual(obj["generation"] as? Int, 1)
        XCTAssertEqual(obj["sequence"] as? Int, 3)
        XCTAssertEqual(obj["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(obj["codec"] as? String, "pcm_s16le")
        XCTAssertEqual(obj["audio"] as? String, "dGVzdA==")
    }

    func testAudioAppendMinimalEncodes() throws {
        // sample_rate and codec are optional
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .audioAppend(sessionId: sessionId, requestId: requestId,
                         generation: 1, sequence: 0,
                         sampleRate: nil, codec: nil,
                         audioBase64: "AAAA")
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertNil(obj["sample_rate"])
        XCTAssertNil(obj["codec"])
    }

    func testAudioCommitEncodes() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .audioCommit(sessionId: sessionId, requestId: requestId,
                         generation: 1, sequence: 10)
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "audio.commit")
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["request_id"] as? String, requestId)
        XCTAssertEqual(obj["generation"] as? Int, 1)
        XCTAssertEqual(obj["sequence"] as? Int, 10)
    }

    func testCancelEncodes() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .cancel(sessionId: sessionId, requestId: requestId,
                    generation: 1, reason: "barge-in")
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "cancel")
        XCTAssertEqual(obj["reason"] as? String, "barge-in")
    }

    func testPingEncodes() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .ping(nonce: "n-abc")
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "ping")
        XCTAssertEqual(obj["nonce"] as? String, "n-abc")
    }

    // MARK: - Downlink decode

    func testReadyDecodes() {
        let raw: [String: Any] = [
            "type": "ready", "session_id": sessionId, "request_id": requestId,
            "generation": 1, "response_id": "resp-42",
            "heartbeat_interval_ms": 15_000, "protocol_version": 1
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .ready(let sid, let rid, let gen, let respId, let hb, let pv) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(gen, 1)
                XCTAssertEqual(respId, "resp-42")
                XCTAssertEqual(hb, 15_000)
                XCTAssertEqual(pv, 1)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testAudioDeltaDecodes() {
        let audioBytes = Data(repeating: 0xAB, count: 64)
        let raw: [String: Any] = [
            "type": "audio.delta", "session_id": sessionId, "request_id": requestId,
            "response_id": "resp-1", "generation": 1, "sequence": 7,
            "sample_rate": 24_000, "codec": "pcm_s16le",
            "audio": audioBytes.base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDelta(let sid, let rid, let respId, let gen, let seq,
                               let sr, let codec, let bytes) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(respId, "resp-1")
                XCTAssertEqual(gen, 1)
                XCTAssertEqual(seq, 7)
                XCTAssertEqual(sr, 24_000)
                XCTAssertEqual(codec, "pcm_s16le")
                XCTAssertEqual(bytes, audioBytes)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testAudioDoneDecodes() {
        let raw: [String: Any] = [
            "type": "audio.done", "session_id": sessionId, "request_id": requestId,
            "response_id": "resp-1", "generation": 1, "final_sequence": 99
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDone(let sid, let rid, let respId, let gen, let fs) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(respId, "resp-1")
                XCTAssertEqual(gen, 1)
                XCTAssertEqual(fs, 99)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testErrorDecodes() {
        let raw: [String: Any] = [
            "type": "error", "code": "ERR_TOKEN_CONSUMED",
            "session_id": sessionId, "request_id": requestId,
            "generation": 1, "retriable": false, "detail": "token already used"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .error(let code, let sid, let rid, let gen, let retry, let detail) = ev {
                XCTAssertEqual(code, "ERR_TOKEN_CONSUMED")
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(gen, 1)
                XCTAssertFalse(retry)
                XCTAssertEqual(detail, "token already used")
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testPongDecodes() {
        let raw: [String: Any] = ["type": "pong", "nonce": "n-test"]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .pong(let nonce) = ev {
                XCTAssertEqual(nonce, "n-test")
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testServerPingDecodes() {
        let raw: [String: Any] = ["type": "server_ping", "at": 1_800_000_000_000]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .serverPing(let at) = ev {
                XCTAssertEqual(at, 1_800_000_000_000)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testMalformedJSONReturnsMalformed() {
        let data = Data("not json".utf8)
        if case .malformed = AudioRealtimeAgentCodec.decodeOutcome(data) { /* ok */ }
        else { XCTFail("expected malformed") }
    }

    func testUnknownTypeReturnsUnrecognised() {
        let raw: [String: Any] = ["type": "custom.event", "session_id": sessionId]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .unrecognised(let type) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            XCTAssertEqual(type, "custom.event")
        } else { XCTFail("expected unrecognised") }
    }

    // MARK: - Round-trip: downlink audio.delta → VoiceStreamChunk

    func testDownlinkRoundtrip() {
        let payload = Data(repeating: 0x77, count: 128)
        let raw: [String: Any] = [
            "type": "audio.delta", "session_id": sessionId, "request_id": requestId,
            "response_id": "resp-1", "generation": 1, "sequence": 42,
            "sample_rate": 24_000, "codec": "pcm_s16le",
            "audio": payload.base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            let chunk = AudioRealtimeAgentCodec.toVoiceStreamChunk(ev, requestId: requestId)
            XCTAssertNotNil(chunk)
            XCTAssertEqual(chunk?.requestId, requestId)
            XCTAssertEqual(chunk?.streamId, sessionId)
            XCTAssertEqual(chunk?.sequence, 42)
            XCTAssertEqual(chunk?.payload, payload)
            XCTAssertEqual(chunk?.direction, .downlink)
        } else { XCTFail("round-trip failed") }
    }

    // MARK: - logTag safety

    func testLogTagDoesNotContainAudioPayload() {
        let tag = AudioRealtimeAgentCodec.logTag(
            .audioAppend(sessionId: sessionId, requestId: requestId,
                         generation: 1, sequence: 0,
                         sampleRate: 16_000, codec: "pcm_s16le",
                         audioBase64: "VERY_LONG_BASE64_STRING_THAT_SHOULD_NOT_APPEAR")
        )
        XCTAssertFalse(tag.contains("BASE64"))
        XCTAssertTrue(tag.contains("audio_bytes="))
    }
}
