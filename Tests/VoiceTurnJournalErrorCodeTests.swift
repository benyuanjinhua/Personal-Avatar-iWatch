import XCTest
@testable import WristAgentCore

/// ESS-180：Journal apply(_:) 把 failed 信封里的稳定 error_code 落到
/// VoiceTurnRecord 上；一旦锁定不被后续乱序事件覆盖。
@MainActor
final class VoiceTurnJournalErrorCodeTests: XCTestCase {
    private let requestId = "019fbbdd-5c39-70fa-9760-dc262ee092b0"

    private func makeJournal() -> VoiceTurnJournal {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess180-journal-\(UUID().uuidString)")
        return VoiceTurnJournal(directory: dir)
    }

    func testFailedApplyStoresErrorCode() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            detail: "ERR_VOICE_BUSY", failureStage: .execution,
            errorCode: "ERR_VOICE_BUSY"
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertEqual(journal.turn(withId: requestId)?.errorCode, "ERR_VOICE_BUSY")
    }

    func testFailedWithoutErrorCodeLeavesFieldNil() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            failureStage: .execution, errorCode: nil
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertNil(journal.turn(withId: requestId)?.errorCode,
                     "无 code 让 catalog 走 generic，不塞占位符")
    }

    func testCompletedNeverCarriesErrorCode() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        // 即使有 bug 把 errorCode 塞进 completed 信封，也不能落到回合上——
        // 语义无效，宁可丢也不装作是失败。
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .completed,
            result: VoiceResultPayload(summary: "ok", isTruncated: false, speechSha256: nil, speechDurationMs: nil),
            errorCode: "ERR_SHOULD_BE_IGNORED"
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertNil(journal.turn(withId: requestId)?.errorCode)
    }
}
