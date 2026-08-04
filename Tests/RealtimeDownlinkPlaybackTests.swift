import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-321 downlink buffer tests. Cover session isolation, barge-in, gap
/// timeout, backpressure, duplicates, and single-shot fallback.
final class RealtimeDownlinkPlaybackTests: XCTestCase {
    private let requestId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let sessionId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let siblingSession = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    private func chunk(
        _ sequence: Int,
        bytes: Int = 512,
        requestId: String? = nil,
        streamId: String? = nil,
        codec: String = "pcm_s16le",
        sampleRate: Int = 24_000,
        end: Bool = false
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId ?? self.requestId,
            streamId: streamId ?? self.sessionId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1_800_000_000_000 + Int64(sequence),
            codec: codec,
            sampleRate: sampleRate,
            payload: Data(repeating: UInt8(sequence % 255), count: bytes),
            endOfStream: end
        )
    }

    private func attachedBuffer(
        maxBufferedBytes: Int = 4 * 1024,
        maxSequenceWindow: Int = 8
    ) -> RealtimeDownlinkPlayback {
        var buffer = RealtimeDownlinkPlayback(
            maxBufferedBytes: maxBufferedBytes,
            maxSequenceWindow: maxSequenceWindow
        )
        _ = buffer.attach(session: .init(requestId: requestId, sessionId: sessionId))
        return buffer
    }

    func testInOrderDeliveryProducesContiguousReady() {
        var buffer = attachedBuffer()
        for i in 0..<3 {
            switch buffer.ingest(chunk(i, bytes: 128)) {
            case .ready(let frames):
                XCTAssertEqual(frames.map(\.sequence), [i])
            default:
                XCTFail("expected ready single frame at seq=\(i)")
            }
        }
    }

    func testOutOfOrderReleasesOnFill() {
        var buffer = attachedBuffer()
        XCTAssertEqual(buffer.ingest(chunk(1, bytes: 64)), .buffered)
        guard case .ready(let frames) = buffer.ingest(chunk(0, bytes: 64)) else {
            return XCTFail("expected fill to release 0,1")
        }
        XCTAssertEqual(frames.map(\.sequence), [0, 1])
    }

    func testDuplicateIsRejected() {
        var buffer = attachedBuffer()
        _ = buffer.ingest(chunk(0, bytes: 64))
        XCTAssertEqual(buffer.ingest(chunk(0, bytes: 64)), .dropped(.duplicate))
    }

    func testMissingFrameSurvivesUntilGapTimeout() {
        var buffer = attachedBuffer()
        _ = buffer.ingest(chunk(1, bytes: 64))
        _ = buffer.ingest(chunk(2, bytes: 64))
        // Head-of-line 0 never arrives; gap timeout must fall back once.
        XCTAssertEqual(buffer.gapTimedOut(), .fallback(.gapTimedOut))
        XCTAssertEqual(buffer.gapTimedOut(), .alreadyFellBack)
    }

    func testBackpressureFallsBackOnce() {
        var buffer = attachedBuffer(maxBufferedBytes: 128)
        _ = buffer.ingest(chunk(1, bytes: 96))
        XCTAssertEqual(buffer.ingest(chunk(2, bytes: 96)), .fallback(.backpressure))
        // Second failure is absorbed.
        XCTAssertEqual(buffer.ingest(chunk(0, bytes: 32)), .alreadyFellBack)
    }

    func testSequenceWindowExceededFallsBack() {
        var buffer = attachedBuffer(maxBufferedBytes: 8 * 1024, maxSequenceWindow: 2)
        XCTAssertEqual(buffer.ingest(chunk(5, bytes: 64)), .fallback(.sequenceWindowExceeded))
    }

    func testLateFramesFromPriorSessionAreDropped() {
        var buffer = attachedBuffer()
        _ = buffer.ingest(chunk(0, bytes: 32))
        // Simulated barge-in: coordinator switches sessions.
        _ = buffer.attach(session: .init(requestId: requestId, sessionId: siblingSession))
        // Late frame from the old session arrives — must be dropped.
        switch buffer.ingest(chunk(1, bytes: 32, streamId: sessionId)) {
        case .dropped(.staleSession(let key)):
            XCTAssertEqual(key.sessionId, sessionId)
        default:
            XCTFail("late frame from prior session must be dropped")
        }
    }

    func testBargeInClearsBufferedBytes() {
        var buffer = attachedBuffer()
        _ = buffer.ingest(chunk(1, bytes: 64))
        XCTAssertEqual(buffer.bufferedBytes, 64)
        switch buffer.bargeIn() {
        case .bargedIn(let cleared):
            XCTAssertEqual(cleared, 64)
            XCTAssertEqual(buffer.bufferedBytes, 0)
        default: XCTFail("expected bargedIn outcome")
        }
    }

    func testInvalidChunkFallsBack() {
        var buffer = attachedBuffer()
        // Mismatched sample rate: downlink expects 24 kHz.
        let bad = chunk(0, bytes: 32, sampleRate: 16_000)
        switch buffer.ingest(bad) {
        case .fallback(.invalidChunk(let error)):
            XCTAssertEqual(error, .unsupportedSampleRate)
        default: XCTFail("expected fallback")
        }
    }

    func testSessionEndedRejectsFurtherChunks() {
        var buffer = attachedBuffer()
        _ = buffer.endSession()
        XCTAssertEqual(buffer.ingest(chunk(0, bytes: 32)), .dropped(.sessionEnded))
    }

    func testBridgeFallbackAbsorbing() {
        var buffer = attachedBuffer()
        XCTAssertEqual(
            buffer.markBridgeFallback(),
            .fallback(.bridgeReportedFallback)
        )
        XCTAssertEqual(buffer.markBridgeFallback(), .alreadyFellBack)
    }
}
