import XCTest
@testable import WristAgentCore

final class VoiceStatusEnvelopeTests: XCTestCase {
    private let requestId = UUIDv7.generate().uuidString.lowercased()

    func testStatusJSONUsesSnakeCaseContractKeys() throws {
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId,
            state: .backgroundProcessing,
            occurredAt: Date(timeIntervalSince1970: 1_753_920_000),
            failureStage: nil,
            result: VoiceResultPayload(summary: "好的", isTruncated: true, speechSha256: "ab", speechDurationMs: 1200)
        )
        let json = String(data: try envelope.jsonData(), encoding: .utf8)!
        for key in ["protocol_version", "request_id", "occurred_at", "background_processing", "is_truncated", "speech_sha256", "speech_duration_ms"] {
            XCTAssertTrue(json.contains(key), "缺少契约键：\(key)")
        }
    }

    func testStatusRoundTrip() throws {
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId,
            state: .permissionRequired,
            occurredAt: Date(timeIntervalSince1970: 1_753_920_000),
            permission: VoicePermissionPayload(id: "perm-1", action: "写入", target: "README.md", summary: "允许修改 README.md？")
        )
        let decoded = try VoiceStatusEnvelope.decode(from: try envelope.jsonData())
        XCTAssertEqual(decoded, envelope)
        XCTAssertNil(decoded.validate())
    }

    func testValidateRejectsBadEnvelopes() {
        XCTAssertNotNil(VoiceStatusEnvelope.status(requestId: "not-a-uuid", state: .accepted).validate())
        XCTAssertNotNil(
            VoiceStatusEnvelope.status(requestId: requestId, state: .permissionRequired).validate(),
            "permission_required 缺少权限载荷必须被拒绝"
        )
        let wrongVersion = VoiceStatusEnvelope(
            protocolVersion: "9.9",
            requestId: requestId,
            type: VoiceStatusEnvelope.statusType,
            state: .accepted,
            occurredAt: Date(),
            detail: nil,
            failureStage: nil,
            permission: nil,
            result: nil
        )
        XCTAssertNotNil(wrongVersion.validate())
    }

    func testDecisionEnvelopeContract() throws {
        let decision = PermissionDecisionEnvelope.decision(requestId: requestId, permissionId: "perm-1", approved: true)
        let json = String(data: try decision.jsonData(), encoding: .utf8)!
        for key in ["protocol_version", "request_id", "permission_id", "approved", "decided_at"] {
            XCTAssertTrue(json.contains(key), "缺少契约键：\(key)")
        }
        XCTAssertNil(decision.validate())
        XCTAssertNotNil(PermissionDecisionEnvelope.decision(requestId: requestId, permissionId: "", approved: false).validate())
    }

    func testResultSummaryFallbackTruncation() {
        let long = VoiceResultPayload(
            summary: String(repeating: "长", count: 500),
            isTruncated: false,
            speechSha256: nil,
            speechDurationMs: nil
        )
        XCTAssertLessThanOrEqual(long.displaySummary.count, VoiceResultPayload.maxSummaryLength + 1)
        XCTAssertTrue(long.displayIsTruncated)

        let short = VoiceResultPayload(summary: "短结果", isTruncated: false, speechSha256: nil, speechDurationMs: nil)
        XCTAssertEqual(short.displaySummary, "短结果")
        XCTAssertFalse(short.displayIsTruncated)
    }
}

@MainActor
final class VoiceTurnJournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-journal-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func newRequestId() -> String {
        UUIDv7.generate().uuidString.lowercased()
    }

    func testAttachSpeechFiresCallbackAndLookupFindsInactiveTurn() {
        // ESS-41 B3：播放触发下沉到 attachSpeech 事件——即使该回合已被新回合
        // 顶掉（不再是 activeTurn）甚至已判失败，回调仍按 request_id 精确命中。
        let journal = VoiceTurnJournal(directory: directory)
        let older = newRequestId()
        let newer = newRequestId()
        journal.begin(requestId: older)
        journal.recordLocal(.failed, requestId: older, detail: "ERR_WORK_TIMEOUT")
        journal.begin(requestId: newer)
        XCTAssertEqual(journal.activeTurn?.requestId, newer, "旧回合已终态且被顶掉")

        var attached: [String] = []
        journal.onSpeechAttached = { attached.append($0) }
        journal.attachSpeech(requestId: older, fileName: "\(older).m4a")
        XCTAssertEqual(attached, [older])
        XCTAssertEqual(journal.turn(withId: older)?.speechFileName, "\(older).m4a")

        // 未知 request_id：不落盘也不回调
        journal.attachSpeech(requestId: newRequestId(), fileName: "ghost.m4a")
        XCTAssertEqual(attached, [older])
    }

    func testBeginIsIdempotent() {
        let journal = VoiceTurnJournal(directory: directory)
        let id = newRequestId()
        journal.begin(requestId: id)
        journal.begin(requestId: id)
        XCTAssertEqual(journal.turns.count, 1)
        XCTAssertEqual(journal.activeTurn?.currentState, .recorded)
    }

    func testFullLifecycleProjection() {
        let journal = VoiceTurnJournal(directory: directory)
        let id = newRequestId()
        journal.begin(requestId: id)
        journal.recordLocal(.waitingForPhone, requestId: id)
        journal.recordLocal(.waitingForMac, requestId: id)
        XCTAssertTrue(journal.apply(.status(requestId: id, state: .accepted)))
        XCTAssertTrue(journal.apply(.status(requestId: id, state: .backgroundAccepted)))
        XCTAssertTrue(journal.apply(.status(requestId: id, state: .backgroundProcessing)))
        XCTAssertTrue(journal.apply(.status(
            requestId: id,
            state: .permissionRequired,
            permission: VoicePermissionPayload(id: "perm-1", action: "写入", target: "README.md", summary: "允许修改 README.md？")
        )))

        let turn = journal.activeTurn!
        XCTAssertEqual(turn.phase, .needsConfirmation)
        XCTAssertEqual(turn.permission?.target, "README.md")

        journal.recordDecision(requestId: id, approved: true)
        XCTAssertTrue(journal.apply(.status(requestId: id, state: .backgroundProcessing)), "确认后应能回到后台执行")
        XCTAssertTrue(journal.apply(.status(
            requestId: id,
            state: .completed,
            result: VoiceResultPayload(summary: "已修改", isTruncated: false, speechSha256: nil, speechDurationMs: nil)
        )))

        let finished = journal.turns.first!
        XCTAssertEqual(finished.phase, .completed)
        XCTAssertEqual(finished.permissionApproved, true)
        XCTAssertEqual(finished.result?.summary, "已修改")
        XCTAssertEqual(finished.events.count, 9)
    }

    func testOutOfOrderAndDuplicateEventsDropped() {
        let journal = VoiceTurnJournal(directory: directory)
        let id = newRequestId()
        journal.begin(requestId: id)
        XCTAssertTrue(journal.apply(.status(requestId: id, state: .backgroundProcessing)))
        XCTAssertFalse(journal.apply(.status(requestId: id, state: .accepted)), "乱序回退必须被丢弃")
        XCTAssertFalse(journal.apply(.status(requestId: id, state: .backgroundProcessing)), "重复状态必须被丢弃")
        XCTAssertTrue(journal.apply(.status(requestId: id, state: .completed)))
        XCTAssertFalse(journal.apply(.status(requestId: id, state: .failed)), "终态之后的事件必须被丢弃")
        XCTAssertEqual(journal.turns.first?.phase, .completed)
    }

    func testInvalidEnvelopeRejected() {
        let journal = VoiceTurnJournal(directory: directory)
        XCTAssertFalse(journal.apply(.status(requestId: "not-a-uuid", state: .accepted)))
        XCTAssertTrue(journal.turns.isEmpty)
    }

    func testFailureStageStoredAndInferred() {
        let journal = VoiceTurnJournal(directory: directory)
        let explicitId = newRequestId()
        journal.begin(requestId: explicitId)
        journal.apply(.status(requestId: explicitId, state: .failed, failureStage: .macUnreachable))
        XCTAssertEqual(journal.turns.first?.phase, .failed(.macUnreachable))

        let inferredId = newRequestId()
        journal.begin(requestId: inferredId)
        journal.recordLocal(.waitingForPhone, requestId: inferredId)
        journal.recordLocal(.failed, requestId: inferredId)
        XCTAssertEqual(
            journal.turns.first(where: { $0.requestId == inferredId })?.phase,
            .failed(.phoneUnreachable),
            "未显式给失败阶段时按最后状态推断"
        )
    }

    // 验收：退出页面后任务继续，重新打开可恢复状态。
    func testPersistenceRestoresAcrossInstances() {
        let id = newRequestId()
        do {
            let journal = VoiceTurnJournal(directory: directory)
            journal.begin(requestId: id)
            journal.apply(.status(
                requestId: id,
                state: .permissionRequired,
                permission: VoicePermissionPayload(id: "perm-1", action: "写入", target: "a.txt", summary: "允许修改 a.txt？")
            ))
        }
        let reopened = VoiceTurnJournal(directory: directory)
        XCTAssertEqual(reopened.turns.count, 1)
        XCTAssertEqual(reopened.activeTurn?.requestId, id)
        XCTAssertEqual(reopened.activeTurn?.phase, .needsConfirmation)
        XCTAssertEqual(reopened.activeTurn?.permission?.target, "a.txt")
    }

    func testUnknownRequestIdCreatesTurnForRecovery() {
        let journal = VoiceTurnJournal(directory: directory)
        let id = newRequestId()
        XCTAssertTrue(journal.apply(.status(requestId: id, state: .backgroundProcessing)))
        XCTAssertEqual(journal.turns.count, 1)
        XCTAssertEqual(journal.activeTurn?.currentState, .backgroundProcessing)
    }

    func testSpeechAttachAndClear() {
        let journal = VoiceTurnJournal(directory: directory)
        let id = newRequestId()
        journal.begin(requestId: id)
        journal.attachSpeech(requestId: id, fileName: "\(id).m4a")
        XCTAssertEqual(journal.turns.first?.speechFileName, "\(id).m4a")
        journal.clearSpeech(requestId: id)
        XCTAssertNil(journal.turns.first?.speechFileName)
    }

    func testTrimKeepsMostRecentTurns() {
        let journal = VoiceTurnJournal(directory: directory, maximumCount: 3)
        for _ in 0..<5 {
            journal.begin(requestId: newRequestId())
        }
        XCTAssertEqual(journal.turns.count, 3)
    }
}
