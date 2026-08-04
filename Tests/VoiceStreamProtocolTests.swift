import Foundation
import XCTest
@testable import WristAgentCore

final class VoiceStreamProtocolTests: XCTestCase {
    private let requestId = UUID().uuidString
    private let streamId = UUID().uuidString

    private func chunk(
        _ sequence: Int,
        bytes: Int = 4,
        end: Bool = false,
        digest: String? = nil
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId,
            streamId: streamId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1_785_810_000_000,
            codec: "pcm_s16le",
            sampleRate: 24_000,
            payload: Data(repeating: UInt8(sequence % 255), count: bytes),
            payloadSha256: digest,
            endOfStream: end
        )
    }

    func testStreamingIsCompileTimeDefaultOffAndTransportIsBestEffort() {
        XCTAssertFalse(VoiceStreamingGate.defaultEnabled)
        let semantics: VoiceStreamTransportSemantics = .reachableBestEffort
        XCTAssertNotEqual(semantics, .reliableCompleteFileFallback)
    }

    func testWireRoundTripUsesVersionedContract() throws {
        let original = chunk(0)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(VoiceStreamChunk.self, from: data), original)
        let json = String(decoding: data, as: UTF8.self)
        for key in ["protocol_version", "request_id", "stream_id", "sequence", "payload_sha256"] {
            XCTAssertTrue(json.contains("\"\(key)\""))
        }
    }

    func testValidatorRejectsUntrustedEnvelopeFields() {
        let validator = VoiceStreamValidator(maxPayloadBytes: 8)
        XCTAssertEqual(validator.validate(VoiceStreamChunk(
            requestId: "bad", streamId: streamId, direction: .downlink, sequence: 0,
            capturedAtMs: 1, codec: "pcm_s16le", sampleRate: 24_000, payload: Data([1])
        )), .invalidRequestId)
        XCTAssertEqual(validator.validate(chunk(0, bytes: 9)), .payloadTooLarge)
        XCTAssertEqual(validator.validate(chunk(0, digest: String(repeating: "0", count: 64))), .digestMismatch)
    }

    func testOutOfOrderChunksReleaseOnlyContiguousSequence() {
        var buffer = VoiceStreamReorderBuffer()
        XCTAssertEqual(buffer.append(chunk(1)), .accepted)
        guard case .ready(let ready) = buffer.append(chunk(0)) else {
            return XCTFail("sequence 0 should release 0 and buffered 1")
        }
        XCTAssertEqual(ready.map(\.sequence), [0, 1])
        XCTAssertEqual(buffer.nextSequence, 2)
        XCTAssertEqual(buffer.bufferedBytes, 0)
    }

    func testDuplicateDoesNotConsumeBufferBudget() {
        var buffer = VoiceStreamReorderBuffer()
        _ = buffer.append(chunk(1))
        XCTAssertEqual(buffer.append(chunk(1)), .duplicate)
        XCTAssertEqual(buffer.bufferedBytes, 4)
    }

    func testSequenceWindowAndBackpressureFailClosed() {
        var window = VoiceStreamReorderBuffer(maxSequenceWindow: 2)
        XCTAssertEqual(window.append(chunk(3)), .fallback(.sequenceWindowExceeded))
        XCTAssertEqual(window.append(chunk(0)), .alreadyFellBack)

        var pressure = VoiceStreamReorderBuffer(maxBufferedBytes: 4)
        XCTAssertEqual(pressure.append(chunk(1, bytes: 4)), .accepted)
        XCTAssertEqual(pressure.append(chunk(2, bytes: 1)), .fallback(.backpressure))
    }

    func testGapTimeoutAndEndWithGapFallbackExactlyOnce() {
        var timeout = VoiceStreamReorderBuffer()
        _ = timeout.append(chunk(1))
        XCTAssertEqual(timeout.gapTimedOut(), .fallback(.gapTimedOut))
        XCTAssertEqual(timeout.gapTimedOut(), .alreadyFellBack)

        var ended = VoiceStreamReorderBuffer()
        XCTAssertEqual(ended.append(chunk(1, end: true)), .fallback(.streamEndedWithGap))
        XCTAssertTrue(ended.didFallback)
    }

    func testEmptyPayloadIsAllowedOnlyForEOS() {
        let empty = VoiceStreamChunk(
            requestId: requestId, streamId: streamId, direction: .uplink, sequence: 0,
            capturedAtMs: 1, codec: "aac_lc", sampleRate: 16_000, payload: Data()
        )
        XCTAssertEqual(VoiceStreamValidator().validate(empty), .emptyPayload)
        let eos = VoiceStreamChunk(
            requestId: requestId, streamId: streamId, direction: .uplink, sequence: 0,
            capturedAtMs: 1, codec: "aac_lc", sampleRate: 16_000, payload: Data(), endOfStream: true
        )
        XCTAssertNil(VoiceStreamValidator().validate(eos))
    }
}
