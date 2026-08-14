import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-321 cross-schema wire codec tests. Assert that the flat JSON strings
/// produced by `RealtimeBridgeWireCodec.encode` match the exact shape Bridge
/// PR #113 (`server.mjs`) accepts, and that the codec can decode the
/// downlink shapes it emits.
///
/// This is the paper-thin protocol contract test that the earlier round of
/// reviews called out as missing: without it, iPhone-side encoders and
/// Bridge-side decoders each pass their own mocks but the real socket 400s
/// with `ERR_STREAM_OWNERSHIP` or `ERR_UNKNOWN_TYPE`.
final class RealtimeBridgeWireCodecTests: XCTestCase {
    private let requestId = "d3f01234-0000-4000-8000-000000000001"
    private let sessionId = "d3f05678-0000-4000-8000-000000000002"

    private func decodedJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    // MARK: - Uplink (iPhone → Bridge)

    func testStreamStartIsFlatWithBridgeFields() throws {
        let start = RealtimeStreamStart(
            requestId: requestId, sessionId: sessionId,
            format: .uplinkPCM16, capturedAtMs: 1_800_000_000_000
        )
        let text = try XCTUnwrap(RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.start(start)))
        guard let obj = decodedJSON(text) else { return XCTFail("invalid json") }
        XCTAssertEqual(obj["type"] as? String, "start")
        XCTAssertEqual(obj["protocol_version"] as? Int, RealtimeWireVersion.uplink)
        XCTAssertEqual(obj["request_id"] as? String, requestId)
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(obj["codec"] as? String, "pcm_s16le")
        // The `start` sub-object of our internal envelope must NOT leak.
        XCTAssertNil(obj["start"])
        XCTAssertNil(obj["kind"])
    }

    func testAudioAppendIsFlatWithBase64Audio() throws {
        let payload = Data([0x11, 0x22, 0x33, 0x44])
        let chunk = VoiceStreamChunk(
            requestId: requestId, streamId: sessionId, direction: .uplink,
            sequence: 7, capturedAtMs: 1_800_000_000_000,
            codec: "pcm_s16le", sampleRate: 16_000, payload: payload
        )
        let text = try XCTUnwrap(RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.audioAppend(chunk)))
        guard let obj = decodedJSON(text) else { return XCTFail("invalid json") }
        XCTAssertEqual(obj["type"] as? String, "audio.append")
        XCTAssertEqual(obj["request_id"] as? String, requestId)
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
        XCTAssertEqual(obj["sequence"] as? Int, 7)
        XCTAssertEqual(obj["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(obj["codec"] as? String, "pcm_s16le")
        XCTAssertEqual(obj["audio"] as? String, payload.base64EncodedString())
        // No nested `append` or `kind`.
        XCTAssertNil(obj["append"])
        XCTAssertNil(obj["kind"])
    }

    func testAudioCommitIsFlat() throws {
        let commit = RealtimeStreamCommit(
            requestId: requestId, sessionId: sessionId, sequence: 0, capturedAtMs: 1
        )
        let text = try XCTUnwrap(RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.audioCommit(commit)))
        guard let obj = decodedJSON(text) else { return XCTFail("invalid json") }
        XCTAssertEqual(obj["type"] as? String, "audio.commit")
        XCTAssertEqual(obj["request_id"] as? String, requestId)
        XCTAssertEqual(obj["session_id"] as? String, sessionId)
    }

    func testPlaybackStartedEmitsResponseId() throws {
        let receipt = RealtimePlaybackReceipt(
            requestId: requestId, sessionId: sessionId,
            responseId: "resp-1", bytesPlayed: nil
        )
        let text = try XCTUnwrap(RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.playbackStarted(
            requestId: receipt.requestId, sessionId: receipt.sessionId, responseId: receipt.responseId
        )))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "playback.started")
        XCTAssertEqual(obj["response_id"] as? String, "resp-1")
    }

    func testPlaybackEndedEmitsBytesPlayed() throws {
        let receipt = RealtimePlaybackReceipt(
            requestId: requestId, sessionId: sessionId,
            responseId: "resp-2", bytesPlayed: 12_345
        )
        let text = try XCTUnwrap(RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.playbackEnded(
            requestId: receipt.requestId, sessionId: receipt.sessionId,
            responseId: receipt.responseId, bytesPlayed: receipt.bytesPlayed ?? 0
        )))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "playback.ended")
        XCTAssertEqual(obj["response_id"] as? String, "resp-2")
        XCTAssertEqual(obj["bytes_played"] as? Int, 12_345)
    }

    func testFallbackEnvelopeBecomesCloseFrame() throws {
        let descriptor = RealtimeUplinkFallbackDescriptor(
            requestId: requestId, sessionId: sessionId, reason: "backpressure"
        )
        let envelope = RealtimeUplinkEnvelope.fallback(descriptor)
        let text = try XCTUnwrap(RealtimeBridgeWireCodec.encode(envelope))
        let obj = try XCTUnwrap(decodedJSON(text))
        XCTAssertEqual(obj["type"] as? String, "close")
        XCTAssertEqual(obj["reason"] as? String, "backpressure")
    }

    // MARK: - Downlink (Bridge → iPhone)

    func testAudioDeltaDecodesFromFlatBridgeShape() throws {
        let audioBytes = Data(repeating: 0xAB, count: 96)
        let bridgeMessage: [String: Any] = [
            "type": "audio.delta",
            "request_id": requestId,
            "session_id": sessionId,
            "sequence": 3,
            "sample_rate": 24_000,
            "codec": "pcm_s16le",
            "audio": audioBytes.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: bridgeMessage)
        let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
        XCTAssertEqual(envelope.kind, .audioDelta)
        XCTAssertEqual(envelope.requestId, requestId)
        XCTAssertEqual(envelope.sessionId, sessionId)
        XCTAssertEqual(envelope.sequence, 3)
        XCTAssertEqual(envelope.audio?.payload, audioBytes)
    }

    func testAudioDoneAndClearAndInterruptDecode() throws {
        for type in ["audio.done", "playback.clear", "response.interrupted"] {
            let bridgeMessage: [String: Any] = [
                "type": type,
                "request_id": requestId,
                "session_id": sessionId,
                "reason": "test"
            ]
            let data = try JSONSerialization.data(withJSONObject: bridgeMessage)
            let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
            XCTAssertEqual(envelope.requestId, requestId)
            XCTAssertEqual(envelope.sessionId, sessionId)
            switch (type, envelope.kind) {
            case ("audio.done", .audioDone),
                 ("playback.clear", .playbackClear),
                 ("response.interrupted", .responseInterrupted):
                break
            default: XCTFail("type=\(type) decoded as \(envelope.kind)")
            }
        }
    }

    func testTranscriptDeltaAndFinalDecode() throws {
        for (type, expected) in [
            ("transcript.delta", RealtimeDownlinkKind.transcriptDelta),
            ("transcript.final", RealtimeDownlinkKind.transcriptFinal)
        ] {
            let bridgeMessage: [String: Any] = [
                "type": type,
                "request_id": requestId,
                "session_id": sessionId,
                "text": "hello"
            ]
            let data = try JSONSerialization.data(withJSONObject: bridgeMessage)
            let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
            XCTAssertEqual(envelope.kind, expected)
            XCTAssertEqual(envelope.transcript, "hello")
        }
    }

    func testStreamFallbackDecodesToAbsorbingFallback() throws {
        let bridgeMessage: [String: Any] = [
            "type": "stream.fallback",
            "request_id": requestId,
            "session_id": sessionId,
            "reason": "bridge_died"
        ]
        let data = try JSONSerialization.data(withJSONObject: bridgeMessage)
        let envelope = try XCTUnwrap(RealtimeBridgeWireCodec.decode(data))
        XCTAssertEqual(envelope.kind, .bridgeFallback)
        XCTAssertEqual(envelope.reason, "bridge_died")
    }

    func testUnknownDownlinkTypeIsRejected() {
        let bridgeMessage: [String: Any] = [
            "type": "unknown.event",
            "request_id": requestId,
            "session_id": sessionId
        ]
        let data = try! JSONSerialization.data(withJSONObject: bridgeMessage)
        XCTAssertNil(RealtimeBridgeWireCodec.decode(data))
    }

    // MARK: - Round-trip via coordinator

    func testCoordinatorProducesBridgeShapedFrames() {
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(uplinkFrameBytes: 64),
            now: { 100 }, sessionIdFactory: { self.sessionId }
        )
        var wireLines: [String] = []
        session.onEvent = { event in
            switch event {
            case .uplinkStart(let start):
                if let s = RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.start(start)) { wireLines.append(s) }
            case .uplinkAppend(let chunk):
                if let s = RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.audioAppend(chunk)) { wireLines.append(s) }
            case .uplinkCommit(let commit):
                if let s = RealtimeBridgeWireCodec.encode(RealtimeBridgeWireCodec.UplinkFlatFrame.audioCommit(commit)) { wireLines.append(s) }
            default: break
            }
        }
        _ = session.beginTurn(requestId: requestId)
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 128)) // → 2 appends
        session.commitUplink()

        XCTAssertEqual(wireLines.count, 4)
        XCTAssertTrue(wireLines[0].contains("\"type\":\"start\""))
        XCTAssertTrue(wireLines[1].contains("\"type\":\"audio.append\""))
        XCTAssertTrue(wireLines[1].contains("\"sequence\":0"))
        XCTAssertTrue(wireLines[2].contains("\"sequence\":1"))
        XCTAssertTrue(wireLines[3].contains("\"type\":\"audio.commit\""))
    }

    // MARK: - ESS-832: dual-write flag is a real lever, in both states

    /// ESS-829 blocker 1: the rollout flag used to be declared but never read,
    /// so "turn dual-write off" was not actually reachable. These two cases
    /// pin both states of `RealtimeEnvelopeFlag.dualWriteConversationIds`.
    private var identityFrames: [(String, RealtimeBridgeWireCodec.UplinkFlatFrame)] {
        let conversationId = "01920000-0000-7000-8000-00000000000a"
        let turnId = "01920000-0000-7000-8000-00000000000b"
        let start = RealtimeStreamStart(
            requestId: requestId, sessionId: sessionId,
            format: .uplinkPCM16, capturedAtMs: 1_800_000_000_000
        )
        let commit = RealtimeStreamCommit(
            requestId: requestId, sessionId: sessionId,
            sequence: 0, capturedAtMs: 1_800_000_000_000
        )
        return [
            ("start", .start(start, conversationId: conversationId, turnId: turnId)),
            ("audio.commit", .audioCommit(commit, conversationId: conversationId, turnId: turnId)),
            ("playback.started", .playbackStarted(
                requestId: requestId, sessionId: sessionId, responseId: "resp_1",
                conversationId: conversationId, turnId: turnId
            )),
            ("close", .close(
                requestId: requestId, sessionId: sessionId, reason: "done",
                conversationId: conversationId, turnId: turnId
            )),
        ]
    }

    func testDualWriteOnEmitsConversationAndTurnIds() throws {
        for (label, frame) in identityFrames {
            let text = try XCTUnwrap(
                RealtimeBridgeWireCodec.encode(frame, dualWriteConversationIds: true),
                "\(label) 必须可编码"
            )
            guard let obj = decodedJSON(text) else { return XCTFail("\(label) invalid json") }
            XCTAssertEqual(obj["type"] as? String, label)
            XCTAssertEqual(
                obj["conversation_id"] as? String, "01920000-0000-7000-8000-00000000000a",
                "\(label) 开启双写时必须带 conversation_id"
            )
            XCTAssertEqual(
                obj["turn_id"] as? String, "01920000-0000-7000-8000-00000000000b",
                "\(label) 开启双写时必须带 turn_id"
            )
        }
    }

    func testDualWriteOffRestoresPreESS571WireShape() throws {
        for (label, frame) in identityFrames {
            let off = try XCTUnwrap(
                RealtimeBridgeWireCodec.encode(frame, dualWriteConversationIds: false),
                "\(label) 必须可编码"
            )
            guard let offObj = decodedJSON(off) else { return XCTFail("\(label) invalid json") }
            XCTAssertNil(offObj["conversation_id"], "\(label) 关闭双写后不得写出 conversation_id")
            XCTAssertNil(offObj["turn_id"], "\(label) 关闭双写后不得写出 turn_id")

            // The legacy flat shape must be byte-identical to a frame that
            // never carried the identity fields — the keys are purely additive.
            let on = try XCTUnwrap(RealtimeBridgeWireCodec.encode(frame, dualWriteConversationIds: true))
            guard var onObj = decodedJSON(on) else { return XCTFail("\(label) invalid json") }
            onObj.removeValue(forKey: "conversation_id")
            onObj.removeValue(forKey: "turn_id")
            XCTAssertEqual(
                NSDictionary(dictionary: onObj), NSDictionary(dictionary: offObj),
                "\(label) 双写只应新增键，不得改动既有字段"
            )
        }
    }

    func testDualWriteDefaultsToRolloutFlag() throws {
        let frame = identityFrames[0].1
        let defaulted = try XCTUnwrap(RealtimeBridgeWireCodec.encode(frame))
        let explicit = try XCTUnwrap(
            RealtimeBridgeWireCodec.encode(
                frame, dualWriteConversationIds: RealtimeEnvelopeFlag.dualWriteConversationIds
            )
        )
        XCTAssertEqual(defaulted, explicit, "默认参数必须取自 rollout flag")
    }
}
