import XCTest
@testable import WristAgentCore

@MainActor
final class ResultAudioDegradationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-degradation-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEnvelopeRoundTripsStableEventContract() throws {
        let requestId = "018f4c6e-0000-7000-8000-000000000001"
        let event = VoiceResultAudioDegradationEnvelope.event(
            requestId: requestId, occurredAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let decoded = try VoiceResultAudioDegradationEnvelope.decode(from: event.jsonData())
        XCTAssertEqual(decoded, event)
        XCTAssertNil(decoded.validate())
        XCTAssertEqual(decoded.type, "result_audio_degraded")
        XCTAssertEqual(decoded.errorCode, "ERR_NO_SPEECH_FILE")
    }

    func testCompletedTurnRecordsDegradationWithoutChangingTerminalState() {
        let requestId = "018f4c6e-0000-7000-8000-000000000002"
        let journal = VoiceTurnJournal(directory: directory)
        journal.begin(requestId: requestId)
        let result = VoiceResultPayload(
            summary: "文字答案", isTruncated: false,
            speechSha256: "abc", speechDurationMs: 1_000
        )
        XCTAssertTrue(journal.apply(.status(requestId: requestId, state: .completed, result: result)))

        var callback: (String, String)?
        journal.onResultAudioDegraded = { callback = ($0, $1) }
        XCTAssertTrue(journal.recordAudioDegradation(
            requestId: requestId, errorCode: "ERR_NO_SPEECH_FILE"
        ))
        XCTAssertEqual(journal.turn(withId: requestId)?.currentState, .completed)
        XCTAssertEqual(journal.turn(withId: requestId)?.result?.summary, "文字答案")
        XCTAssertEqual(journal.turn(withId: requestId)?.resultAudioErrorCode, "ERR_NO_SPEECH_FILE")
        XCTAssertEqual(callback?.0, requestId)
        XCTAssertEqual(callback?.1, "ERR_NO_SPEECH_FILE")
        XCTAssertFalse(journal.recordAudioDegradation(
            requestId: requestId, errorCode: "ERR_NO_SPEECH_FILE"
        ), "重放事件必须幂等")
    }
}
