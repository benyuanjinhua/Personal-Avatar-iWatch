import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-402/F3 Gateway contract tests.
///
/// Validates that client `encode` output passes Gateway PR #159's
/// ALLOWED_KEYS schema (no unknown fields) and that Gateway downlink
/// fixtures decode successfully as `.event(_)` (not `.unrecognised`
/// or `.malformed`).
///
/// The Gateway fixture schemas are extracted from:
///   AudioRealtimeGateway/realtime-session.mjs (ALLOWED_KEYS + CLIENT_SCHEMAS)
///   AudioRealtimeGateway/test/wss-e2e.test.mjs (actual wire messages)
final class AgentGatewayContractTests: XCTestCase {

    // Gateway ALLOWED_KEYS as Set per type (must match exactly)
    // ESS-551 A4: `session.start` and `close` admit a free-form `meta`
    // sub-object carrying conversation_id / turn_id.
    private let allowedKeys: [String: Set<String>] = [
        "session.start":    ["type", "session_id", "request_id", "generation", "protocol_version", "meta"],
        "audio.append":     ["type", "session_id", "request_id", "generation", "sequence", "audio", "sample_rate", "codec"],
        "audio.commit":     ["type", "session_id", "request_id", "generation", "sequence"],
        "cancel":           ["type", "session_id", "request_id", "generation", "reason"],
        "playback.started": ["type", "session_id", "request_id", "response_id"],
        "playback.ended":   ["type", "session_id", "request_id", "response_id"],
        "ping":             ["type", "nonce"],
        "close":            ["type", "reason", "meta"],
    ]

    // Gateway CLIENT_SCHEMAS (required fields) per type
    private let requiredFields: [String: [String]] = [
        "session.start":    ["session_id", "request_id", "generation", "protocol_version"],
        "audio.append":     ["session_id", "request_id", "generation", "sequence", "audio"],
        "audio.commit":     ["session_id", "request_id", "generation", "sequence"],
        "cancel":           ["session_id", "request_id", "generation"],
        "playback.started": ["session_id", "request_id", "response_id"],
        "playback.ended":   ["session_id", "request_id", "response_id"],
        "ping":             ["nonce"],
        "close":            [],
    ]

    private let sessionId = "s-cc-test"
    private let requestId = "r-cc-test"
    private let generation = 1

    // MARK: - F3.1: Uplink → Gateway schema

    /// Encode a frame, decode the JSON, then assert all keys are in ALLOWED_KEYS
    /// for that type AND all required fields are present.
    private func assertGWSchemaCompliant(_ frame: AudioRealtimeAgentCodec.UplinkFrame, file: StaticString = #filePath, line: UInt = #line) {
        let text = try! XCTUnwrap(AudioRealtimeAgentCodec.encode(frame), file: file, line: line)
        let obj = try! XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
            file: file, line: line
        )
        let type = try! XCTUnwrap(obj["type"] as? String, file: file, line: line)

        // Allowed keys check
        if let allowed = allowedKeys[type] {
            for key in obj.keys {
                if !allowed.contains(key) {
                    XCTFail("Uplink type=\(type) contains forbidden key '\(key)'. Allowed: \(allowed.sorted())", file: file, line: line)
                }
            }
        } else {
            XCTFail("Unknown uplink type: \(type)", file: file, line: line)
        }

        // Required fields check
        if let required = requiredFields[type] {
            for field in required {
                XCTAssertTrue(obj.keys.contains(field),
                    "Uplink type=\(type) missing required field '\(field)'", file: file, line: line)
            }
        }
    }

    func testGW_schema_sessionStart() {
        assertGWSchemaCompliant(.sessionStart(
            sessionId: sessionId, requestId: requestId,
            generation: generation, protocolVersion: 1
        ))
    }

    func testGW_schema_audioAppend() {
        assertGWSchemaCompliant(.audioAppend(
            sessionId: sessionId, requestId: requestId, generation: generation,
            sequence: 0, sampleRate: 16_000, codec: "pcm_s16le",
            audioBase64: "AAAA"
        ))
    }

    func testGW_schema_audioAppendMinimal() {
        // sample_rate/codec are optional in ALLOWED_KEYS — omit them
        assertGWSchemaCompliant(.audioAppend(
            sessionId: sessionId, requestId: requestId, generation: generation,
            sequence: 5, sampleRate: nil, codec: nil,
            audioBase64: "BBBB"
        ))
    }

    func testGW_schema_audioCommit() {
        assertGWSchemaCompliant(.audioCommit(
            sessionId: sessionId, requestId: requestId, generation: generation, sequence: 42
        ))
    }

    func testGW_schema_cancel() {
        assertGWSchemaCompliant(.cancel(
            sessionId: sessionId, requestId: requestId, generation: generation, reason: "barge-in"
        ))
    }

    func testGW_schema_cancelMinimal() {
        assertGWSchemaCompliant(.cancel(
            sessionId: sessionId, requestId: requestId, generation: generation, reason: nil
        ))
    }

    func testGW_schema_playbackStarted() {
        assertGWSchemaCompliant(.playbackStarted(
            sessionId: sessionId, requestId: requestId, responseId: "resp-1"
        ))
    }

    func testGW_schema_playbackEnded() {
        assertGWSchemaCompliant(.playbackEnded(
            sessionId: sessionId, requestId: requestId, responseId: "resp-1"
        ))
    }

    func testGW_schema_ping() {
        assertGWSchemaCompliant(.ping(nonce: "abc123"))
    }

    func testGW_schema_close() {
        assertGWSchemaCompliant(.close(reason: "done"))
    }

    func testGW_schema_closeMinimal() {
        assertGWSchemaCompliant(.close(reason: nil))
    }

    // MARK: - ESS-551 A4: meta sub-object

    /// session.start carrying conversation_id / turn_id inside `meta` must
    /// pass the Gateway ALLOWED_KEYS schema (top-level keys unchanged).
    func testGW_schema_sessionStartWithMeta() throws {
        let meta: [String: Any] = [
            "conversation_id": "0198c001-0000-7000-8000-000000000001",
            "turn_id": "0198c001-0000-7000-8000-000000000002",
        ]
        assertGWSchemaCompliant(.sessionStart(
            sessionId: sessionId, requestId: requestId,
            generation: generation, protocolVersion: 1, meta: meta
        ))
        // …and the meta content must survive encoding verbatim (bounded
        // relay: iPhone MUST NOT rewrite it).
        let text = try XCTUnwrap(AudioRealtimeAgentCodec.encode(.sessionStart(
            sessionId: sessionId, requestId: requestId,
            generation: generation, protocolVersion: 1, meta: meta
        )))
        let obj = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        )
        let encodedMeta = try XCTUnwrap(obj["meta"] as? [String: Any])
        XCTAssertEqual(encodedMeta["conversation_id"] as? String, meta["conversation_id"] as? String)
        XCTAssertEqual(encodedMeta["turn_id"] as? String, meta["turn_id"] as? String)
    }

    /// close carrying `meta.conversation_id` (conversation destroy signal)
    /// must pass the Gateway ALLOWED_KEYS schema.
    func testGW_schema_closeWithMeta() {
        assertGWSchemaCompliant(.close(
            reason: "conversation_destroyed",
            meta: ["conversation_id": "0198c001-0000-7000-8000-000000000001"]
        ))
    }

    // MARK: - F3.2: Gateway downlink fixtures → client decodes as .event(_)

    func testGW_fixture_ready() {
        let raw: [String: Any] = [
            "type": "ready",
            "session_id": sessionId, "request_id": requestId,
            "generation": generation, "response_id": "resp-99",
            "heartbeat_interval_ms": 15_000, "protocol_version": 1
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .ready(let sid, let rid, let gen, let respId, let hb, let pv) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(gen, generation)
                XCTAssertEqual(respId, "resp-99")
                XCTAssertEqual(hb, 15_000)
                XCTAssertEqual(pv, 1)
            } else { XCTFail("wrong event: \(ev)") }
        } else { XCTFail("ready must decode as .event") }
    }

    func testGW_fixture_audioDelta() {
        let audio = Data(repeating: 0xCC, count: 64).base64EncodedString()
        let raw: [String: Any] = [
            "type": "audio.delta",
            "session_id": sessionId, "request_id": requestId,
            "response_id": "resp-99", "generation": generation,
            "sequence": 7, "sample_rate": 24_000, "codec": "pcm_s16le",
            "audio": audio
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDelta(let sid, let rid, let respId, let gen, let seq,
                               let sr, let cdc, let bytes) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(respId, "resp-99")
                XCTAssertEqual(gen, generation)
                XCTAssertEqual(seq, 7)
                XCTAssertEqual(sr, 24_000)
                XCTAssertEqual(cdc, "pcm_s16le")
                XCTAssertEqual(bytes, Data(repeating: 0xCC, count: 64))
            } else { XCTFail("wrong event") }
        } else { XCTFail("audio.delta must decode as .event") }
    }

    func testGW_fixture_audioDone() {
        let raw: [String: Any] = [
            "type": "audio.done",
            "session_id": sessionId, "request_id": requestId,
            "response_id": "resp-99", "generation": generation,
            "final_sequence": 42
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDone(let sid, let rid, let respId, let gen, let fs) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(respId, "resp-99")
                XCTAssertEqual(gen, generation)
                XCTAssertEqual(fs, 42)
            } else { XCTFail("wrong event") }
        } else { XCTFail("audio.done must decode as .event") }
    }

    func testGW_fixture_cancelAck() {
        let raw: [String: Any] = [
            "type": "cancel.ack",
            "session_id": sessionId, "request_id": requestId,
            "generation": generation, "cancelled_response_id": "resp-5"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .cancelAck(let sid, let rid, let gen, let crid) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(gen, generation)
                XCTAssertEqual(crid, "resp-5")
            } else { XCTFail("wrong event") }
        } else { XCTFail("cancel.ack must decode as .event") }
    }

    func testGW_fixture_error() {
        let raw: [String: Any] = [
            "type": "error", "code": "ERR_TOKEN_CONSUMED",
            "session_id": sessionId, "request_id": requestId,
            "generation": generation, "retriable": false,
            "detail": "token already used"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .error(let code, let sid, let rid, let gen, let retriable, let detail) = ev {
                XCTAssertEqual(code, "ERR_TOKEN_CONSUMED")
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(gen, generation)
                XCTAssertFalse(retriable)
                XCTAssertEqual(detail, "token already used")
            } else { XCTFail("wrong event") }
        } else { XCTFail("error must decode as .event") }
    }

    func testGW_fixture_pong() {
        let raw: [String: Any] = [
            "type": "pong", "nonce": "n-12345"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .pong(let nonce) = ev {
                XCTAssertEqual(nonce, "n-12345")
            } else { XCTFail("wrong event") }
        } else { XCTFail("pong must decode as .event") }
    }

    func testGW_fixture_serverPing() {
        let raw: [String: Any] = [
            "type": "server_ping", "at": 1_800_000_000_000
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .serverPing(let at) = ev {
                XCTAssertEqual(at, 1_800_000_000_000)
            } else { XCTFail("wrong event") }
        } else { XCTFail("server_ping must decode as .event") }
    }

    // MARK: - F3.3: generation type is Int (Number), NOT String

    func testGW_generationIsIntNotString() {
        // Gateway emits generation as a JSON Number
        let raw: [String: Any] = [
            "type": "audio.delta",
            "session_id": sessionId, "request_id": requestId,
            "response_id": "resp-1", "generation": 7,  // Number, not String
            "sequence": 0, "audio": Data(repeating: 0x01, count: 10).base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .audioDelta(_, _, _, let gen, _, _, _, _) = ev {
                XCTAssertEqual(gen, 7, "generation must be Int(7), got something else")
            } else { XCTFail("wrong event") }
        } else { XCTFail("must decode") }
    }

    func testGW_generationStringFailsGracefully() {
        // If Gateway were to send generation as String, it should fail decode
        let raw: [String: Any] = [
            "type": "audio.delta",
            "session_id": sessionId, "request_id": requestId,
            "response_id": "resp-1", "generation": "seven",
            "sequence": 0, "audio": Data(repeating: 0x01, count: 10).base64EncodedString()
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        // "seven" is not an Int → as? Int returns nil → guard fails → .malformed
        if case .malformed = AudioRealtimeAgentCodec.decodeOutcome(data) {
            // expected
        } else { XCTFail("String generation must fail as malformed") }
    }

    // MARK: - F2: Token must NOT appear in log output

    func testF2_tokenNotInLogTag() {
        // session.start's logTag must not contain the token
        let tag = AudioRealtimeAgentCodec.logTag(
            .sessionStart(sessionId: sessionId, requestId: requestId,
                          generation: generation, protocolVersion: 1)
        )
        XCTAssertFalse(tag.contains("tok"), "logTag must not leak token fragments")
        XCTAssertFalse(tag.contains("Bearer"), "logTag must not leak auth headers")
        // Contains session/request identifiers
        XCTAssertTrue(tag.contains("session.start"))
        XCTAssertTrue(tag.contains(sessionId.prefix(8)))
        XCTAssertTrue(tag.contains(requestId.prefix(8)))
    }

    func testF2_audioAppendLogTagHasNoRawAudio() {
        let audioB64 = Data(repeating: 0xDE, count: 3200).base64EncodedString()
        let tag = AudioRealtimeAgentCodec.logTag(
            .audioAppend(sessionId: sessionId, requestId: requestId,
                         generation: generation, sequence: 3,
                         sampleRate: 16_000, codec: "pcm_s16le",
                         audioBase64: audioB64)
        )
        XCTAssertFalse(tag.contains(audioB64), "logTag must not contain raw base64 audio")
        XCTAssertTrue(tag.contains("audio_bytes=\(audioB64.count)"), "logTag should report byte count only")
    }
}
