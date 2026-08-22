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

    /// ESS-971：`audio.segment_done` 必须被当成一等事件解码。
    ///
    /// 2026-08-22 真机（`request_id=01a02783-7e78`）：网关侧 ESS-969 已经在发这一帧
    /// （`downlink_segment_done segment_index=0`），但 Watch 侧只落了一条
    /// `downlink_decode_unrecognised type=audio.segment_done` —— 协议上线、客户端没接，
    /// 于是回合既收不到「这段完了」也收不到「这轮完了」，一直挂到用户关掉 App。
    func testAudioSegmentDoneDecodes() {
        let raw: [String: Any] = [
            "type": "audio.segment_done", "session_id": sessionId,
            "request_id": requestId, "response_id": "resp-1", "generation": 1,
            "segment_index": 0, "final_sequence": 46
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        guard case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) else {
            return XCTFail("decode failed")
        }
        guard case .audioSegmentDone(let sid, let rid, let respId, let gen,
                                     let segmentIndex, let finalSeq) = ev else {
            return XCTFail("wrong event")
        }
        XCTAssertEqual(sid, sessionId)
        XCTAssertEqual(rid, requestId)
        XCTAssertEqual(respId, "resp-1")
        XCTAssertEqual(gen, 1)
        XCTAssertEqual(segmentIndex, 0)
        XCTAssertEqual(finalSeq, 46)
    }

    /// `segment_index` 缺失时按 0 计，不得整帧判 malformed——
    /// 判 malformed 等于回到「客户端什么都不知道」，正是本单要修的状态。
    func testAudioSegmentDoneToleratesMissingSegmentIndex() {
        let raw: [String: Any] = [
            "type": "audio.segment_done", "session_id": sessionId,
            "request_id": requestId, "response_id": "resp-1", "generation": 1,
            "final_sequence": 46
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        guard case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) else {
            return XCTFail("decode failed")
        }
        guard case .audioSegmentDone(_, _, _, _, let segmentIndex, let finalSeq) = ev else {
            XCTFail("wrong event"); return
        }
        XCTAssertEqual(segmentIndex, 0)
        XCTAssertEqual(finalSeq, 46)
    }

    /// `final_sequence` 是屏障值，缺了就没法判「这一段收齐没有」——必须判 malformed。
    func testAudioSegmentDoneWithoutFinalSequenceIsMalformed() {
        let raw: [String: Any] = [
            "type": "audio.segment_done", "session_id": sessionId,
            "request_id": requestId, "response_id": "resp-1", "generation": 1,
            "segment_index": 0
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .malformed = AudioRealtimeAgentCodec.decodeOutcome(data) { return }
        XCTFail("缺 final_sequence 应判 malformed")
    }

    /// ESS-957 / ESS-969：网关在丢弃 post-done 帧时下发的
    /// `audio.segment_dropped` 必须被**当成一等事件解码**，而不是掉进
    /// `default: .unrecognised`。
    ///
    /// 背景：`faed305` 在网关侧加了这个 warning 帧，理由是「让客户端能
    /// 提示/降级」。但全仓 Swift 当时搜不到任何 `segment_dropped`，客户端
    /// 只会落一条 `downlink_decode_unrecognised` 日志——**那个理由一行都
    /// 没兑现**。这条用例钉住它确实被接上了。
    func testSegmentDroppedDecodes() {
        let raw: [String: Any] = [
            "type": "audio.segment_dropped", "session_id": sessionId,
            "request_id": requestId, "response_id": "resp-1", "generation": 1,
            "sequence": 13, "dropped_count": 3, "reason": "post_done"
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        if case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) {
            if case .segmentDropped(let sid, let rid, let respId, let gen,
                                    let seq, let droppedCount, let reason) = ev {
                XCTAssertEqual(sid, sessionId)
                XCTAssertEqual(rid, requestId)
                XCTAssertEqual(respId, "resp-1")
                XCTAssertEqual(gen, 1)
                XCTAssertEqual(seq, 13)
                XCTAssertEqual(droppedCount, 3)
                XCTAssertEqual(reason, "post_done")
            } else { XCTFail("wrong event") }
        } else { XCTFail("decode failed") }
    }

    /// 网关未来可能只发必填字段。缺 `dropped_count` / `reason` 时不得整帧
    /// 判 malformed——那等于又回到「客户端什么都不知道」。
    func testSegmentDroppedToleratesOptionalFields() {
        let raw: [String: Any] = [
            "type": "audio.segment_dropped", "session_id": sessionId,
            "request_id": requestId, "response_id": "resp-1", "generation": 1,
            "sequence": 4
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw)
        guard case .event(let ev) = AudioRealtimeAgentCodec.decodeOutcome(data) else {
            return XCTFail("decode failed")
        }
        guard case .segmentDropped(_, _, _, _, let seq, let droppedCount, let reason) = ev else {
            return XCTFail("wrong event")
        }
        XCTAssertEqual(seq, 4)
        XCTAssertEqual(droppedCount, 1, "缺省按至少丢了一帧计")
        XCTAssertNil(reason)
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
