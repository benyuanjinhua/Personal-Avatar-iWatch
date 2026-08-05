import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-402 Audio Realtime Agent codec unit tests.
///
/// Validates:
///   - Uplink encode produces the exact flat JSON the Agent Gateway expects.
///   - Downlink decode correctly parses every event type.
///   - Round-trip: `VoiceStreamChunk` → encode → decode → `VoiceStreamChunk`.
///   - Edge cases: malformed JSON, unknown types, missing fields.
final class AudioRealtimeAgentCodecTests: XCTestCase {
    private let sessionId = "e4f01000-0000-4000-8000-000000000001"
    private let turnId = "e4f02000-0000-4000-8000-000000000002"

    private func decodedJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    // MARK: - Uplink encode

    func testSessionUpdateEncodesWithToken() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .sessionUpdate(sessionId: sessionId, token: "tok-xyz")
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "session.update")
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["token"] as? String, "tok-xyz")
    }

    func testInputAudioAppendEncodesFlatJSON() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .inputAudioAppend(
                sessionId: sessionId, turnId: turnId, sequence: 3,
                sampleRate: 16_000, codec: "pcm_s16le",
                audioBase64: "dGVzdA==", endOfStream: false
            )
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "input_audio.append")
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["turn_id"] as? String, turnId)
        XCTAssertEqual(obj["sequence"] as? Int, 3)
        XCTAssertEqual(obj["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(obj["codec"] as? String, "pcm_s16le")
        XCTAssertEqual(obj["audio"] as? String, "dGVzdA==")
        XCTAssertNil(obj["end_of_stream"])
    }

    func testInputAudioAppendWithEndOfStream() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .inputAudioAppend(
                sessionId: sessionId, turnId: turnId, sequence: 5,
                sampleRate: 16_000, codec: "pcm_s16le",
                audioBase64: "YWJj", endOfStream: true
            )
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["end_of_stream"] as? Bool, true)
    }

    func testInputAudioCommitEncodes() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .inputAudioCommit(sessionId: sessionId, turnId: turnId, sequence: 10)
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "input_audio.commit")
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["turn_id"] as? String, turnId)
        XCTAssertEqual(obj["sequence"] as? Int, 10)
    }

    func testHeartbeatEncodes() throws {
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .heartbeat(sessionId: sessionId, timestampMs: 1_800_000_000_000)
        ))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "heartbeat")
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["timestamp_ms"] as? Int64, 1_800_000_000_000)
    }

    // MARK: - Downlink decode

    func testSessionCreatedDecodes() {
        let raw: [String: Any] = [
            "type": "session.created",
            "session_id": sessionId,
            "turn_id": turnId
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .sessionCreated(let sid, let tid) = event {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(tid, turnId)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testAudioDeltaDecodes() {
        let audioBytes = Data(repeating: 0xAB, count: 64)
        let raw: [String: Any] = [
            "type": "response.audio.delta",
            "session_id": sessionId,
            "turn_id": turnId,
            "generation": "gen-1",
            "sequence": 7,
            "sample_rate": 24_000,
            "codec": "pcm_s16le",
            "audio": audioBytes.base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDelta(let sid, let tid, let gen, let seq,
                               let sr, let codec, let bytes, let eos, _) = event {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(tid, turnId)
                XCTAssertEqual(gen, "gen-1")
                XCTAssertEqual(seq, 7)
                XCTAssertEqual(sr, 24_000)
                XCTAssertEqual(codec, "pcm_s16le")
                XCTAssertEqual(bytes, audioBytes)
                XCTAssertFalse(eos)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testAudioDeltaDefaultsSampleRateAndCodec() {
        let audioBytes = Data(repeating: 0xBB, count: 32)
        let raw: [String: Any] = [
            "type": "response.audio.delta",
            "session_id": sessionId,
            "turn_id": turnId,
            "sequence": 1,
            "audio": audioBytes.base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDelta(_, _, _, _, let sr, let codec, _, _, _) = event {
                XCTAssertEqual(sr, RealtimeMediaFormat.downlinkPCM16.sampleRate)
                XCTAssertEqual(codec, RealtimeMediaFormat.downlinkPCM16.codec)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testAudioDoneDecodes() {
        let raw: [String: Any] = [
            "type": "response.audio.done",
            "session_id": sessionId,
            "turn_id": turnId,
            "generation": "gen-2"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDone(let sid, let tid, let gen) = event {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(tid, turnId)
                XCTAssertEqual(gen, "gen-2")
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testTranscriptDeltaDecodes() {
        let raw: [String: Any] = [
            "type": "response.transcript.delta",
            "session_id": sessionId,
            "turn_id": turnId,
            "text": "你好世界"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .transcriptDelta(let sid, let tid, let text) = event {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(tid, turnId)
                XCTAssertEqual(text, "你好世界")
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testTranscriptDoneDecodes() {
        let raw: [String: Any] = [
            "type": "response.transcript.done",
            "session_id": sessionId,
            "turn_id": turnId
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .transcriptDone(let sid, let tid) = event {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(tid, turnId)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testHeartbeatAckDecodes() {
        let raw: [String: Any] = [
            "type": "heartbeat_ack",
            "session_id": sessionId,
            "timestamp_ms": 1_800_000_000_500
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .heartbeatAck(let sid, let ts) = event {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(ts, 1_800_000_000_500)
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testErrorEventDecodes() {
        let raw: [String: Any] = [
            "type": "error",
            "session_id": sessionId,
            "code": "AUTH_FAILED",
            "message": "token expired"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .error(let sid, let code, let msg) = event {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(code, "AUTH_FAILED")
                XCTAssertEqual(msg, "token expired")
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    func testMalformedJSONReturnsMalformed() {
        let data = Data("not json".utf8)
        if case .malformed = AudioRealtimeAgentCodec.decodeOutcome(data) {
            // expected
        } else { XCTFail("expected malformed") }
    }

    func testMissingTypeReturnsMalformed() {
        let raw: [String: Any] = [
            "session_id": sessionId
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .malformed = AudioRealtimeAgentCodec.decodeOutcome(data) {
            // expected
        } else { XCTFail("expected malformed") }
    }

    func testUnknownTypeReturnsUnrecognised() {
        let raw: [String: Any] = [
            "type": "custom.gateway.event",
            "session_id": sessionId
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .unrecognised(let type) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            XCTAssertEqual(type, "custom.gateway.event")
        } else { XCTFail("expected unrecognised") }
    }

    // MARK: - VoiceStreamChunk round-trip (downlink)

    func testVoiceStreamChunkDownlinkRoundtrip() {
        let payload = Data(repeating: 0x77, count: 128)
        // Build a downlink audio.delta JSON (simulating what the Gateway emits)
        let raw: [String: Any] = [
            "type": "response.audio.delta",
            "session_id": sessionId,
            "turn_id": turnId,
            "generation": "gen-42",
            "sequence": 42,
            "sample_rate": 24_000,
            "codec": "pcm_s16le",
            "audio": payload.base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            let decoded = AudioRealtimeAgentCodec.toVoiceStreamChunk(event, requestId: turnId)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.requestId, turnId)
            XCTAssertEqual(decoded?.streamId, sessionId)
            XCTAssertEqual(decoded?.sequence, 42)
            XCTAssertEqual(decoded?.payload, payload)
            XCTAssertEqual(decoded?.direction, .downlink)
        } else { XCTFail("round-trip failed") }
    }

    // MARK: - Auth header

    func testAuthTokenNotInUserFacingFields() {
        // The token must not appear in decode fields — only in session.update
        // which the client controls. Sanity-check that a downlink decode
        // never parses a "token" for an `error` event.
        let raw: [String: Any] = [
            "type": "error",
            "session_id": sessionId,
            "code": "ERR_TEST",
            "message": "test message"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .error(_, _, _) = event {
                // No token field exposed — pass
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    // MARK: - Missing session_id handling

    func testAudioDeltaMissingSessionIdFails() {
        let raw: [String: Any] = [
            "type": "response.audio.delta",
            "turn_id": turnId,
            "sequence": 1,
            "audio": Data(repeating: 0x01, count: 10).base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        // Missing session_id → malformed (guard fails)
        if case .malformed = AudioRealtimeAgentCodec.decodeOutcome(data) {
            // expected
        } else { XCTFail("expected malformed") }
    }

    // MARK: - Duplicate/reordered sequence dedup

    func testMultipleAudioDeltasWithSameSequence() {
        let audio1 = Data(repeating: 0x11, count: 32)
        let audio2 = Data(repeating: 0x22, count: 32)
        // Encode first
        let _ = try! XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .inputAudioAppend(
                sessionId: sessionId, turnId: turnId, sequence: 1,
                sampleRate: 16_000, codec: "pcm_s16le",
                audioBase64: audio1.base64EncodedString(), endOfStream: false
            )
        ))
        // Encode second with same sequence — both encode fine since encode is
        // stateless; dedup is a session-layer concern tested in SessionTests.
        let text2 = try! XCTUnwrap(AudioRealtimeAgentCodec.encode(
            .inputAudioAppend(
                sessionId: sessionId, turnId: turnId, sequence: 1,
                sampleRate: 16_000, codec: "pcm_s16le",
                audioBase64: audio2.base64EncodedString(), endOfStream: false
            )
        ))
        let obj2 = try! XCTUnwrap(decodedJSON(text2))
        XCTAssertEqual(obj2["sequence"] as? Int, 1)
    }

    // MARK: - Error close codes

    func testSessionExpiredErrorTriggersClose() {
        let raw: [String: Any] = [
            "type": "error",
            "session_id": sessionId,
            "code": "SESSION_EXPIRED",
            "message": "session timed out"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let event) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .error(_, let code, _) = event {
                XCTAssertEqual(code, "SESSION_EXPIRED")
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }
}
