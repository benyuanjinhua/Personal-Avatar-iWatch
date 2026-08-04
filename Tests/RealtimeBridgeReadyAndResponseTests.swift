import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-329 + ESS-330 regression tests.
///
/// These lock down the exact wire behaviour Bridge PR #113 requires so a
/// future edit to `RealtimeBridgeWireCodec` cannot silently regress the
/// receive loop or drop the real `response_id`.
final class RealtimeBridgeReadyAndResponseTests: XCTestCase {
    private let requestId = "d3f01234-0000-4000-8000-00000000dead"
    private let sessionId = "d3f05678-0000-4000-8000-00000000beef"

    // MARK: - ESS-329: `ready` frame

    func testReadyFrameDecodesAsEnvelopeNotFailure() throws {
        let bridgeMessage: [String: Any] = [
            "type": "ready",
            "request_id": requestId,
            "session_id": sessionId
        ]
        let data = try JSONSerialization.data(withJSONObject: bridgeMessage)
        let outcome = RealtimeBridgeWireCodec.decodeOutcome(data)
        guard case .envelope(let envelope) = outcome else {
            return XCTFail("ready should decode into an envelope, got \(outcome)")
        }
        XCTAssertEqual(envelope.kind, .ready)
        XCTAssertEqual(envelope.requestId, requestId)
        XCTAssertEqual(envelope.sessionId, sessionId)
    }

    func testUnknownTypeIsUnrecognisedNotMalformed() throws {
        let bridgeMessage: [String: Any] = [
            "type": "future.heartbeat",
            "request_id": requestId,
            "session_id": sessionId
        ]
        let data = try JSONSerialization.data(withJSONObject: bridgeMessage)
        switch RealtimeBridgeWireCodec.decodeOutcome(data) {
        case .unrecognised(let type): XCTAssertEqual(type, "future.heartbeat")
        default: XCTFail("expected .unrecognised outcome")
        }
    }

    func testMalformedJSONIsClassifiedAsMalformed() {
        switch RealtimeBridgeWireCodec.decodeOutcome(Data("not json".utf8)) {
        case .malformed: break
        default: XCTFail("expected .malformed outcome")
        }
    }

    func testFullBridgeSequenceStartReadyAppendDelta() throws {
        // Simulate the full Bridge conversation the receive loop must survive.
        let ready = try JSONSerialization.data(withJSONObject: [
            "type": "ready", "request_id": requestId, "session_id": sessionId
        ])
        let audioBytes = Data(repeating: 0x11, count: 96)
        let delta = try JSONSerialization.data(withJSONObject: [
            "type": "audio.delta",
            "request_id": requestId,
            "session_id": sessionId,
            "sequence": 0,
            "sample_rate": 24_000,
            "codec": "pcm_s16le",
            "audio": audioBytes.base64EncodedString(),
            "response_id": "resp-alpha"
        ] as [String: Any])
        let done = try JSONSerialization.data(withJSONObject: [
            "type": "audio.done",
            "request_id": requestId,
            "session_id": sessionId,
            "response_id": "resp-alpha"
        ])

        guard case .envelope(let readyEnv) = RealtimeBridgeWireCodec.decodeOutcome(ready) else {
            return XCTFail("ready malformed")
        }
        guard case .envelope(let deltaEnv) = RealtimeBridgeWireCodec.decodeOutcome(delta) else {
            return XCTFail("delta malformed")
        }
        guard case .envelope(let doneEnv) = RealtimeBridgeWireCodec.decodeOutcome(done) else {
            return XCTFail("done malformed")
        }
        XCTAssertEqual(readyEnv.kind, .ready)
        XCTAssertEqual(deltaEnv.kind, .audioDelta)
        XCTAssertEqual(deltaEnv.responseId, "resp-alpha")
        XCTAssertEqual(deltaEnv.audio?.payload, audioBytes)
        XCTAssertEqual(doneEnv.kind, .audioDone)
        XCTAssertEqual(doneEnv.responseId, "resp-alpha")
    }

    // MARK: - ESS-330: response_id round-trip

    func testAudioDeltaCarriesResponseIdOnEnvelope() throws {
        let audioBytes = Data(repeating: 0x22, count: 64)
        let raw: [String: Any] = [
            "type": "audio.delta",
            "request_id": requestId,
            "session_id": sessionId,
            "sequence": 5,
            "sample_rate": 24_000,
            "codec": "pcm_s16le",
            "audio": audioBytes.base64EncodedString(),
            "response_id": "resp-42"
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
        XCTAssertEqual(envelope.responseId, "resp-42")
    }

    func testAudioDoneCarriesResponseIdOnEnvelope() throws {
        let raw: [String: Any] = [
            "type": "audio.done",
            "request_id": requestId,
            "session_id": sessionId,
            "response_id": "resp-99"
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
        XCTAssertEqual(envelope.kind, .audioDone)
        XCTAssertEqual(envelope.responseId, "resp-99")
    }

    func testMultipleResponseIdsAreDistinguishedAcrossDeltas() throws {
        // Two responses in the same session — envelope's response_id must
        // reflect the current delta, not a session identifier.
        let audio = Data(repeating: 0x33, count: 32)
        func delta(responseId: String, sequence: Int) throws -> RealtimeDownlinkEnvelope {
            let raw: [String: Any] = [
                "type": "audio.delta",
                "request_id": requestId,
                "session_id": sessionId,
                "sequence": sequence,
                "sample_rate": 24_000,
                "codec": "pcm_s16le",
                "audio": audio.base64EncodedString(),
                "response_id": responseId
            ]
            let data = try JSONSerialization.data(withJSONObject: raw)
            return try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
        }
        XCTAssertEqual(try delta(responseId: "resp-A", sequence: 0).responseId, "resp-A")
        XCTAssertEqual(try delta(responseId: "resp-A", sequence: 1).responseId, "resp-A")
        XCTAssertEqual(try delta(responseId: "resp-B", sequence: 2).responseId, "resp-B")
    }

    func testResponseIdOmittedIsNilNotSessionId() throws {
        // Bridge should always ship response_id on audio.delta; ensure our
        // codec does not fabricate one from session_id when it is absent.
        let audio = Data(repeating: 0x44, count: 16)
        let raw: [String: Any] = [
            "type": "audio.delta",
            "request_id": requestId,
            "session_id": sessionId,
            "sequence": 0,
            "sample_rate": 24_000,
            "codec": "pcm_s16le",
            "audio": audio.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
        XCTAssertNil(envelope.responseId, "session_id must not be silently used as response_id")
    }
}
