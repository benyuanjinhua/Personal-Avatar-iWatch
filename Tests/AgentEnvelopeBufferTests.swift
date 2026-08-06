import Foundation
import XCTest
@testable import WristAgentCore

final class AgentEnvelopeBufferTests: XCTestCase {
    func testCountOverflowDrainsBufferedEnvelopesAndReportsQuantities() {
        var buffer = AgentEnvelopeBuffer(maximumCount: 2, maximumBytes: 1_000)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertBuffered(buffer.append(.fallback(descriptor("one")), encodedByteCount: 10, now: start))
        XCTAssertBuffered(buffer.append(.fallback(descriptor("two")), encodedByteCount: 20, now: start))

        guard case .overflow(let buffered, let incoming, let snapshot) = buffer.append(
            .fallback(descriptor("three")), encodedByteCount: 30, now: start.addingTimeInterval(1.25)
        ) else { return XCTFail("expected bounded overflow") }

        XCTAssertEqual(buffered.count, 2)
        XCTAssertEqual(incoming.fallback?.reason, "three")
        XCTAssertEqual(snapshot, .init(envelopeCount: 2, byteCount: 30, waitedMilliseconds: 1_250))
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testByteOverflowDoesNotRetainOversizedIncomingEnvelope() {
        var buffer = AgentEnvelopeBuffer(maximumCount: 10, maximumBytes: 15)
        XCTAssertBuffered(buffer.append(.fallback(descriptor("one")), encodedByteCount: 10))
        guard case .overflow(let buffered, _, let snapshot) = buffer.append(
            .fallback(descriptor("two")), encodedByteCount: 6
        ) else { return XCTFail("expected byte overflow") }
        XCTAssertEqual(buffered.count, 1)
        XCTAssertEqual(snapshot.byteCount, 10)
        XCTAssertEqual(buffer.byteCount, 0)
    }

    private func descriptor(_ reason: String) -> RealtimeUplinkFallbackDescriptor {
        .init(requestId: "request", sessionId: "session", reason: reason)
    }

    private func XCTAssertBuffered(
        _ result: AgentEnvelopeBuffer.AppendResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .buffered = result else { return XCTFail("expected buffered", file: file, line: line) }
    }
}
