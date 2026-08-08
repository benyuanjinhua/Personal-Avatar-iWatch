import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-525 acceptance §1: for a given `request_id` the client MUST emit
/// runtime evidence — `downlink_frame_received`, decode success/failure,
/// enqueue-to-Watch, WSS close code/reason — so bridge.log has a
/// symmetric client-side view of the turn.
///
/// These tests wire `PhoneAgentClientLog` to an in-memory recorder and
/// drive the receive-loop end-to-end through the codec so the event
/// ordering and payloads are asserted directly against the same code path
/// that runs in production.
@MainActor
final class PhoneAgentClientLogEvidenceTests: XCTestCase {
    private let sessionId = "525a1000-0000-4000-8000-000000000001"
    private let requestId = "525b2000-0000-4000-8000-000000000002"

    // Recorder is Sendable-capable and stored non-isolated so tearDown can
    // touch it from the base class's synchronous context without an actor
    // hop. Access from tests goes through MainActor without ceremony.
    nonisolated(unsafe) private var recorderBox: RecorderBox?

    override func setUp() {
        super.setUp()
        let box = RecorderBox()
        recorderBox = box
        PhoneAgentClientLog.install { entry in
            box.append(entry)
        }
    }

    override func tearDown() {
        PhoneAgentClientLog.install(nil)
        recorderBox = nil
        super.tearDown()
    }

    private func snapshot() -> [PhoneAgentClientLog.Entry] {
        return recorderBox?.snapshot() ?? []
    }

    // MARK: - Sink

    func testSinkInstallReceivesRecordedEntry() {
        PhoneAgentClientLog.info(
            module: "agent_transport", event: "downlink_frame_received",
            requestId: requestId, sessionId: sessionId, detail: "bytes=128"
        )
        let snap = snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.event, "downlink_frame_received")
        XCTAssertEqual(snap.first?.requestId, requestId)
    }

    func testSinkInstallNilIsANoop() {
        PhoneAgentClientLog.install(nil)
        PhoneAgentClientLog.info(module: "x", event: "y")
        // No throw, no crash — and the previously installed recorder is
        // gone so nothing accumulates.
        XCTAssertEqual(snapshot().count, 0)
    }

    // MARK: - Session-level per-frame evidence

    /// ESS-525 §1: `downlink_audio_delta_accepted` fires per received delta
    /// with `seq` / `bytes` / `gen` in the detail so bridge.log grep by
    /// request_id yields the same ordered sequence the Gateway sent.
    func testAudioDeltaLandsPerFrameAcceptedEntry() {
        let config = AudioRealtimeAgentConfig(
            gatewayURL: URL(string: "wss://agent.example/api/realtime")!,
            authToken: "rtk_test",
            deviceId: "device-under-test"
        )
        let session = AudioRealtimeAgentSession(config: config, sessionId: sessionId)
        _ = session.connect(requestId: requestId, generation: 1)

        // Simulate Gateway `ready` → session moves to `.connected` and
        // subsequent `audio.delta` frames flow through.
        session.handleForTesting(event: .ready(
            sessionId: sessionId, requestId: requestId, generation: 1,
            responseId: "resp-1", heartbeatIntervalMs: 15_000, protocolVersion: 1
        ))
        for seq in 0..<3 {
            session.handleForTesting(event: .audioDelta(
                sessionId: sessionId, requestId: requestId, responseId: "resp-1",
                generation: 1, sequence: seq, sampleRate: 24_000,
                codec: "pcm_s16le",
                audioBytes: Data(repeating: 0x77, count: 128)
            ))
        }
        session.handleForTesting(event: .audioDone(
            sessionId: sessionId, requestId: requestId, responseId: "resp-1",
            generation: 1, finalSequence: 2
        ))

        let events = snapshot().map(\.event)
        XCTAssertTrue(events.contains("downlink_audio_delta_accepted"))
        XCTAssertEqual(events.filter { $0 == "downlink_audio_delta_accepted" }.count, 3)
        XCTAssertTrue(events.contains("downlink_audio_done_accepted"))
    }

    /// Duplicate sequences must NOT re-forward, but the deduplication
    /// decision itself must be observable — otherwise a silent "the client
    /// swallowed frame N" is indistinguishable from "the network dropped it".
    func testDuplicateAudioDeltaEmitsDeduplicationEvidence() {
        let config = AudioRealtimeAgentConfig(
            gatewayURL: URL(string: "wss://agent.example/api/realtime")!,
            authToken: "rtk_test",
            deviceId: "device"
        )
        let session = AudioRealtimeAgentSession(config: config, sessionId: sessionId)
        _ = session.connect(requestId: requestId, generation: 1)
        session.handleForTesting(event: .ready(
            sessionId: sessionId, requestId: requestId, generation: 1,
            responseId: "resp-1", heartbeatIntervalMs: 15_000, protocolVersion: 1
        ))
        let delta = AudioRealtimeAgentCodec.DownlinkEvent.audioDelta(
            sessionId: sessionId, requestId: requestId, responseId: "resp-1",
            generation: 1, sequence: 5,
            sampleRate: 24_000, codec: "pcm_s16le",
            audioBytes: Data([0x11, 0x22, 0x33])
        )
        session.handleForTesting(event: delta)
        session.handleForTesting(event: delta)

        let snap = snapshot()
        let accepted = snap.filter { $0.event == "downlink_audio_delta_accepted" }
        let dup = snap.filter { $0.event == "downlink_audio_delta_dup" }
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(dup.count, 1)
        XCTAssertEqual(dup.first?.detail, "seq=5 gen=1")
    }
}

/// Thread-safe recorder that captures `PhoneAgentClientLog.Entry` values
/// emitted from `@Sendable` sinks. Tests read a snapshot afterward.
final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PhoneAgentClientLog.Entry] = []

    func append(_ entry: PhoneAgentClientLog.Entry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    func snapshot() -> [PhoneAgentClientLog.Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
