import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-321 simulated transport closed-loop test. Drives `RealtimeMediaSession`
/// with a fake bridge — pushed PCM bytes come back out as `stream.start` /
/// `audio.append` / `audio.commit` events, and the "bridge" round-trips
/// `audio.delta` chunks through the downlink buffer. Also exercises the
/// barge-in, session cross-talk, disconnect, and fallback branches.
///
/// This test IS the "simulated transport closed loop" the ticket's completion
/// definition asks for: no AVAudioEngine, no WSS, no WCSession — but the exact
/// state machine that runs on the watch and iPhone.
final class RealtimeMediaSessionClosedLoopTests: XCTestCase {
    private var sessionIds: [String] = []
    private var events: [RealtimeMediaSession.Event] = []
    private var clock: Int64 = 0
    private var session: RealtimeMediaSession!

    override func setUp() {
        super.setUp()
        sessionIds = [
            "11111111-0000-0000-0000-000000000001",
            "11111111-0000-0000-0000-000000000002",
            "11111111-0000-0000-0000-000000000003"
        ]
        events.removeAll()
        clock = 100
        var index = 0
        session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(
                uplinkFormat: .uplinkPCM16,
                downlinkFormat: .downlinkPCM16,
                uplinkFrameBytes: 128,
                maxInFlightUplinkBytes: 8 * 1024,
                maxDownlinkBufferBytes: 4 * 1024,
                maxUplinkSequence: 4_096
            ),
            now: { [unowned self] in
                self.clock += 10
                return self.clock
            },
            sessionIdFactory: { [self] in
                defer { index += 1 }
                return sessionIds[min(index, sessionIds.count - 1)]
            }
        )
        session.onEvent = { [weak self] event in self?.events.append(event) }
    }

    private func requestId(_ suffix: Int) -> String {
        String(format: "22222222-0000-0000-0000-%012x", suffix)
    }

    private func downlink(
        _ sequence: Int,
        forHandle handle: RealtimeMediaSession.TurnHandle,
        bytes: Int = 128
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: handle.requestId,
            streamId: handle.sessionId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1_800_000_000_000 + Int64(sequence),
            codec: "pcm_s16le",
            sampleRate: 24_000,
            payload: Data(repeating: UInt8(sequence % 255), count: bytes)
        )
    }

    func testHappyPathUplinkAndDownlink() {
        let handle = session.beginTurn(requestId: requestId(1))
        // 3 frames of 128 bytes each — the coordinator emits them one by one.
        session.pushMicrophonePCM(Data(repeating: 0xAA, count: 128 * 3))
        session.commitUplink()

        // Simulated bridge fires 4 downlink deltas in order.
        for i in 0..<4 { session.receiveDownlink(downlink(i, forHandle: handle)) }

        // Assert uplink event sequence
        let uplinkStarts = events.compactMap { event -> RealtimeStreamStart? in
            if case .uplinkStart(let s) = event { return s }; return nil
        }
        XCTAssertEqual(uplinkStarts.count, 1)
        XCTAssertEqual(uplinkStarts.first?.sessionId, handle.sessionId)

        let uplinkAppends = events.compactMap { event -> VoiceStreamChunk? in
            if case .uplinkAppend(let c) = event { return c }; return nil
        }
        XCTAssertEqual(uplinkAppends.count, 3)
        XCTAssertEqual(uplinkAppends.map(\.sequence), [0, 1, 2])

        let uplinkCommits = events.compactMap { event -> RealtimeStreamCommit? in
            if case .uplinkCommit(let c) = event { return c }; return nil
        }
        XCTAssertEqual(uplinkCommits.count, 1)

        // Assert downlink playback receipts: each in-order chunk releases one
        // playbackReady event with a single chunk.
        let readyFrames = events.compactMap { event -> [VoiceStreamChunk]? in
            if case .playbackReady(let frames) = event { return frames }; return nil
        }.flatMap { $0 }
        XCTAssertEqual(readyFrames.map(\.sequence), [0, 1, 2, 3])
    }

    func testBargeInDropsPriorDownlink() {
        let handle = session.beginTurn(requestId: requestId(1))
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 128))
        session.receiveDownlink(downlink(0, forHandle: handle, bytes: 256))
        // Two more buffered but not head-of-line — barge-in should dump them.
        session.receiveDownlink(downlink(2, forHandle: handle, bytes: 256))
        session.receiveDownlink(downlink(3, forHandle: handle, bytes: 256))
        session.bargeInDownlink()

        let cleared = events.compactMap { event -> Int? in
            if case .playbackCleared(let bytes) = event { return bytes }; return nil
        }
        XCTAssertFalse(cleared.isEmpty, "expected at least one playbackCleared")
        XCTAssertGreaterThan(cleared.last ?? 0, 0)
    }

    func testNewTurnBargesInAndOldSessionFramesAreDropped() {
        let first = session.beginTurn(requestId: requestId(1))
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 128))
        // Feed a downlink chunk for the first session but keep it out of order.
        session.receiveDownlink(downlink(1, forHandle: first))

        // New turn starts — coordinator should barge in.
        let second = session.beginTurn(requestId: requestId(2))
        XCTAssertNotEqual(first.sessionId, second.sessionId)

        // A late chunk from the old session must be dropped, not played.
        session.receiveDownlink(downlink(0, forHandle: first))
        let staleDrops = events.compactMap { event -> Bool? in
            if case .downlinkDropped(.staleSession) = event { return true }; return nil
        }
        XCTAssertFalse(staleDrops.isEmpty)

        // The new session's chunk plays back normally.
        session.receiveDownlink(downlink(0, forHandle: second))
        let ready = events.compactMap { event -> [VoiceStreamChunk]? in
            if case .playbackReady(let frames) = event { return frames }; return nil
        }.flatMap { $0 }
        XCTAssertTrue(ready.contains(where: { $0.streamId == second.sessionId }))
    }

    func testUplinkTransportFailureFallsBackExactlyOnce() {
        let handle = session.beginTurn(requestId: requestId(1))
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 128))
        session.markUplinkTransportFailed()
        session.markUplinkTransportFailed()
        // Further pushes must not produce more uplinks or a second fallback.
        session.pushMicrophonePCM(Data(repeating: 0x22, count: 128))
        let fallbacks = events.compactMap { event -> RealtimeUplinkStream.FallbackReason? in
            if case .uplinkFallback(let reason, let h) = event, h == handle { return reason }
            return nil
        }
        XCTAssertEqual(fallbacks.count, 1, "single-shot fallback per turn")
        XCTAssertEqual(fallbacks.first, .transportFailed)
    }

    func testDownlinkGapTimeoutFallsBackOnce() {
        let handle = session.beginTurn(requestId: requestId(1))
        // Feed a downlink chunk that leaves seq 0 missing.
        session.receiveDownlink(downlink(1, forHandle: handle))
        session.downlinkGapTimeout()
        session.downlinkGapTimeout()
        let fallbacks = events.compactMap { event -> RealtimeDownlinkPlayback.FallbackReason? in
            if case .playbackFallback(let reason, _) = event { return reason }; return nil
        }
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertEqual(fallbacks.first, .gapTimedOut)
    }

    func testCommitAfterFallbackDoesNotEmitCommitFrame() {
        _ = session.beginTurn(requestId: requestId(1))
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 128))
        session.markUplinkTransportFailed()
        session.commitUplink()
        let commits = events.filter {
            if case .uplinkCommit = $0 { return true }; return false
        }
        XCTAssertTrue(commits.isEmpty, "no commit emitted after fallback")
    }

    func testCancelFromRecorderIsIdempotentAndClearsScratch() {
        _ = session.beginTurn(requestId: requestId(1))
        // Push < one frame worth of bytes — they sit in the scratch buffer.
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 32))
        session.cancelUplink()
        session.cancelUplink()
        // Nothing has been emitted.
        let appends = events.filter {
            if case .uplinkAppend = $0 { return true }; return false
        }
        XCTAssertTrue(appends.isEmpty)
    }

    func testWireEnvelopeRoundTrip() throws {
        let handle = session.beginTurn(requestId: requestId(1))
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 128))
        session.commitUplink()

        // Grab the emitted uplink events and encode them to the wire envelope
        // — this is exactly what WatchVoiceTransport does via sendMessageData.
        var envelopes: [RealtimeUplinkEnvelope] = []
        for event in events {
            switch event {
            case .uplinkStart(let start): envelopes.append(.start(start))
            case .uplinkAppend(let chunk): envelopes.append(.append(chunk))
            case .uplinkCommit(let commit): envelopes.append(.commit(commit))
            default: break
            }
        }
        XCTAssertGreaterThanOrEqual(envelopes.count, 3)

        // Round-trip through JSON — PhoneRealtimeSession decodes what
        // sendMessage delivered.
        for envelope in envelopes {
            let data = try JSONEncoder().encode(envelope)
            let decoded = try JSONDecoder().decode(RealtimeUplinkEnvelope.self, from: data)
            XCTAssertEqual(decoded, envelope)
            XCTAssertEqual(decoded.protocolVersion, RealtimeWireVersion.uplink)
            switch decoded.kind {
            case .streamStart: XCTAssertEqual(decoded.start?.sessionId, handle.sessionId)
            case .audioAppend: XCTAssertEqual(decoded.append?.streamId, handle.sessionId)
            case .audioCommit: XCTAssertEqual(decoded.commit?.sessionId, handle.sessionId)
            case .playbackStarted, .playbackEnded:
                XCTFail("no playback receipt envelope expected on happy path")
            case .fallback: XCTFail("no fallback envelope expected on happy path")
            }
        }
    }

    func testDownlinkEnvelopeWireContract() throws {
        let handle = session.beginTurn(requestId: requestId(1))
        let chunk = downlink(0, forHandle: handle)
        let envelope = RealtimeDownlinkEnvelope.audioDelta(chunk)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.audio?.sequence, 0)
        XCTAssertEqual(decoded.sequence, 0)
        XCTAssertEqual(decoded.requestId, handle.requestId)
        XCTAssertEqual(decoded.sessionId, handle.sessionId)
        XCTAssertEqual(decoded.kind, .audioDelta)
    }

    func testDisconnectMidTurnPreservesSingleFallbackContract() {
        let handle = session.beginTurn(requestId: requestId(1))
        session.pushMicrophonePCM(Data(repeating: 0x11, count: 128 * 2))
        // Simulated iPhone reports WSS disconnect via bridge fallback signal.
        session.markDownlinkBridgeFallback()
        // The coordinator MUST NOT double-play or double-fallback.
        session.markDownlinkBridgeFallback()
        session.downlinkGapTimeout()
        let downlinkFallbacks = events.compactMap { event -> RealtimeDownlinkPlayback.FallbackReason? in
            if case .playbackFallback(let reason, _) = event { return reason }; return nil
        }
        XCTAssertEqual(downlinkFallbacks.count, 1)
        XCTAssertEqual(downlinkFallbacks.first, .bridgeReportedFallback)
        XCTAssertEqual(handle.requestId, session.activeTurn?.requestId)
    }
}
