import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-321 uplink state-machine tests. Cover the normal path, duplicates,
/// backpressure, sequence overflow, and single-shot fallback semantics.
final class RealtimeUplinkStreamTests: XCTestCase {
    private let requestId = "11111111-1111-1111-1111-111111111111"
    private let sessionId = "22222222-2222-2222-2222-222222222222"

    private func makeStream(
        maxInFlightBytes: Int = 8_192,
        sequenceLimit: Int = 4_096
    ) -> RealtimeUplinkStream {
        RealtimeUplinkStream(
            requestId: requestId,
            sessionId: sessionId,
            format: .uplinkPCM16,
            maxInFlightBytes: maxInFlightBytes,
            sequenceLimit: sequenceLimit
        )
    }

    func testNormalStreamStartAppendCommit() {
        var stream = makeStream()
        switch stream.start(capturedAtMs: 100) {
        case .emitted(let frames):
            XCTAssertEqual(frames.count, 1)
            guard case .streamStart(let start)? = frames.first else {
                return XCTFail("expected stream.start frame")
            }
            XCTAssertEqual(start.requestId, requestId)
            XCTAssertEqual(start.sessionId, sessionId)
            XCTAssertEqual(start.codec, "pcm_s16le")
            XCTAssertEqual(start.sampleRate, 16_000)
        default:
            XCTFail("unexpected outcome for start")
        }
        for i in 0..<3 {
            let payload = Data(repeating: UInt8(i), count: 640)
            switch stream.appendPCM(payload, capturedAtMs: Int64(200 + i * 100)) {
            case .emitted(let frames):
                guard case .audioAppend(let chunk)? = frames.first else {
                    return XCTFail("expected audio.append")
                }
                XCTAssertEqual(chunk.sequence, i)
                XCTAssertEqual(chunk.direction, .uplink)
                XCTAssertEqual(chunk.payload, payload)
            default:
                XCTFail("expected emitted frame")
            }
        }
        switch stream.commit(capturedAtMs: 900) {
        case .emitted(let frames):
            guard case .audioCommit(let commit)? = frames.first else {
                return XCTFail("expected audio.commit")
            }
            XCTAssertEqual(commit.requestId, requestId)
            XCTAssertEqual(commit.sequence, 2)
        default:
            XCTFail("expected emitted commit")
        }
    }

    func testStartIsIdempotent() {
        var stream = makeStream()
        _ = stream.start(capturedAtMs: 100)
        switch stream.start(capturedAtMs: 200) {
        case .emitted(let frames):
            XCTAssertTrue(frames.isEmpty)
        default:
            XCTFail("repeat start should be a no-op")
        }
    }

    func testCommitWithoutAudioFallsBackInsteadOfSendingEmptyBuffer() {
        var stream = makeStream()
        _ = stream.start(capturedAtMs: 100)

        XCTAssertEqual(stream.commit(capturedAtMs: 200), .fallback(.noAudioFrames))
        XCTAssertTrue(stream.didFallback)
        XCTAssertFalse(stream.didCommit)
    }

    func testAppendBeforeStartFallsBack() {
        var stream = makeStream()
        let payload = Data(repeating: 0x11, count: 64)
        switch stream.appendPCM(payload, capturedAtMs: 100) {
        case .fallback(.cancelled):
            XCTAssertTrue(stream.didFallback)
        default:
            XCTFail("append before start must fall back")
        }
    }

    func testAppendAfterCommitIsIgnored() {
        var stream = makeStream()
        _ = stream.start(capturedAtMs: 100)
        _ = stream.appendPCM(Data(repeating: 1, count: 64), capturedAtMs: 150)
        _ = stream.commit(capturedAtMs: 200)
        XCTAssertEqual(
            stream.appendPCM(Data(repeating: 1, count: 64), capturedAtMs: 250),
            .ignoredAfterCommit
        )
    }

    func testBackpressureTriggersOneShotFallback() {
        var stream = makeStream(maxInFlightBytes: 256)
        _ = stream.start(capturedAtMs: 0)
        _ = stream.appendPCM(Data(repeating: 1, count: 200), capturedAtMs: 1)
        // Adding another 200-byte frame would exceed the 256-byte budget.
        switch stream.appendPCM(Data(repeating: 2, count: 100), capturedAtMs: 2) {
        case .fallback(.backpressure): break
        default: XCTFail("expected backpressure fallback")
        }
        // Subsequent operations are absorbed — the coordinator's single-shot
        // guarantee sits here.
        XCTAssertEqual(
            stream.appendPCM(Data(repeating: 3, count: 10), capturedAtMs: 3),
            .ignoredAfterFallback
        )
        XCTAssertEqual(stream.commit(capturedAtMs: 4), .ignoredAfterFallback)
        XCTAssertEqual(stream.markTransportFailed(), .ignoredAfterFallback)
    }

    func testSequenceOverflowFallsBack() {
        var stream = makeStream(sequenceLimit: 2)
        _ = stream.start(capturedAtMs: 0)
        _ = stream.appendPCM(Data(repeating: 1, count: 4), capturedAtMs: 1)
        _ = stream.appendPCM(Data(repeating: 2, count: 4), capturedAtMs: 2)
        XCTAssertEqual(
            stream.appendPCM(Data(repeating: 3, count: 4), capturedAtMs: 3),
            .fallback(.sequenceOverflow)
        )
    }

    func testAcknowledgeFreesInflightBytes() {
        var stream = makeStream(maxInFlightBytes: 64)
        _ = stream.start(capturedAtMs: 0)
        _ = stream.appendPCM(Data(repeating: 1, count: 32), capturedAtMs: 1)
        _ = stream.appendPCM(Data(repeating: 2, count: 32), capturedAtMs: 2)
        // Acking the first frame gives us room for a third payload without
        // tripping backpressure.
        stream.acknowledge(sequence: 0, byteCount: 32)
        switch stream.appendPCM(Data(repeating: 3, count: 32), capturedAtMs: 3) {
        case .emitted: break
        default: XCTFail("ack should free budget")
        }
    }

    func testMarkTransportFailedIsIdempotent() {
        var stream = makeStream()
        _ = stream.start(capturedAtMs: 0)
        _ = stream.appendPCM(Data(repeating: 1, count: 64), capturedAtMs: 1)
        XCTAssertEqual(stream.markTransportFailed(), .fallback(.transportFailed))
        XCTAssertEqual(stream.markTransportFailed(), .ignoredAfterFallback)
        XCTAssertEqual(stream.markCancelled(), .ignoredAfterFallback)
    }
}
