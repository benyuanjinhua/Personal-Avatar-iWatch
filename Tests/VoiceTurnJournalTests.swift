import XCTest
@testable import WristAgentCore

final class VoiceTurnLatencyTests: XCTestCase {
    func testMeasuresTextAndAudioTTFTFromWatchRecordingCompletion() {
        let start = Date(timeIntervalSince1970: 1_000)
        let turn = VoiceTurnRecord(
            requestId: UUID().uuidString,
            createdAt: start,
            events: [
                VoiceTurnEvent(state: .recorded, at: start),
                VoiceTurnEvent(state: .completed, at: start.addingTimeInterval(1.234))
            ],
            speechFileName: "result.m4a",
            speechAttachedAt: start.addingTimeInterval(1.75),
            firstResultAt: start.addingTimeInterval(1.234)
        )

        let metric = VoiceTurnLatency.measure(turn)
        XCTAssertEqual(metric.textTTFTMs, 1_234)
        XCTAssertEqual(metric.audioTTFTMs, 1_750)
    }

    func testMissingMilestonesRemainAbsentAndNegativeSkewIsClamped() {
        let start = Date(timeIntervalSince1970: 2_000)
        var turn = VoiceTurnRecord(
            requestId: UUID().uuidString,
            createdAt: start,
            events: [VoiceTurnEvent(state: .recorded, at: start)]
        )
        XCTAssertEqual(VoiceTurnLatency.measure(turn), VoiceTurnLatency(textTTFTMs: nil, audioTTFTMs: nil))
        turn.speechAttachedAt = start.addingTimeInterval(-1)
        XCTAssertEqual(VoiceTurnLatency.measure(turn).audioTTFTMs, 0)
    }
}

final class VoiceStatusEnvelopeTests: XCTestCase {
    func testAudioDownlinkPolicyRejectsMissingAndUnknownWireKinds() throws {
        XCTAssertFalse(AudioDownlinkPolicy.allows(nil, expected: [.interim, .result]))
        XCTAssertFalse(AudioDownlinkPolicy.allows(.welcome, expected: [.interim, .result]))
        XCTAssertTrue(AudioDownlinkPolicy.allows(.interim, expected: [.interim, .result]))
        XCTAssertTrue(AudioDownlinkPolicy.allows(.result, expected: [.interim, .result]))
        XCTAssertFalse(AudioDownlinkPolicy.allows(.unknown, expected: [.interim, .result]))
        let unknown = Data("\"unknown\"".utf8)
        XCTAssertEqual(try VoiceProtocolJSON.decoder.decode(AudioDownlinkKind.self, from: unknown), .unknown)
    }
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
        XCTAssertFalse(journal.attachSpeech(requestId: newRequestId(), fileName: "ghost.m4a"))
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

/// ESS-55：文字与语音解耦 + 未读结果机制。
@MainActor
final class VoiceTurnUnreadAndDecouplingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-unread-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func newRequestId() -> String {
        UUIDv7.generate().uuidString.lowercased()
    }

    func testTextSurvivesWhenSpeechPayloadIsDropped() {
        // 验收硬口径：人为丢弃语音载荷（speech_sha256 承诺了语音但 transferFile
        // 永远不到、attachSpeech 从不发生），文字仍完整展示。
        let journal = VoiceTurnJournal(directory: directory)
        let requestId = newRequestId()
        journal.begin(requestId: requestId)
        let applied = journal.apply(VoiceStatusEnvelope.status(
            requestId: requestId,
            state: .completed,
            result: VoiceResultPayload(
                summary: "明天北京晴，18 到 26 度。",
                isTruncated: false,
                speechSha256: String(repeating: "a", count: 64),
                speechDurationMs: 3200
            )
        ))
        XCTAssertTrue(applied)

        let turn = journal.turn(withId: requestId)
        XCTAssertEqual(turn?.currentState, .completed)
        XCTAssertEqual(turn?.result?.displaySummary, "明天北京晴，18 到 26 度。", "语音丢失时文字必须完整在场")
        XCTAssertNil(turn?.speechFileName, "语音从未落盘")
        XCTAssertTrue(turn?.hasUnreadResult == true, "只有文字的结果同样进入未读态，不丢失")
    }

    func testUnreadResultPersistsAcrossRelaunchUntilViewed() {
        // 验收：结果在用户未查看前不丢失，下次打开仍在（未读态）。
        let requestId = newRequestId()
        do {
            let journal = VoiceTurnJournal(directory: directory)
            journal.begin(requestId: requestId)
            journal.apply(VoiceStatusEnvelope.status(
                requestId: requestId,
                state: .completed,
                result: VoiceResultPayload(summary: "查询完成", isTruncated: false, speechSha256: nil, speechDurationMs: nil)
            ))
        }

        let relaunched = VoiceTurnJournal(directory: directory)
        XCTAssertEqual(relaunched.firstUnreadResult?.requestId, requestId, "重开 App 未读结果仍在")

        relaunched.markResultViewed(requestId: requestId)
        XCTAssertNil(relaunched.firstUnreadResult)
        XCTAssertNil(VoiceTurnJournal(directory: directory).firstUnreadResult, "已读状态持久化")
    }

    func testMarkResultViewedKeepsFirstReadTimeAndRequiresResult() {
        let journal = VoiceTurnJournal(directory: directory)
        let pending = newRequestId()
        journal.begin(requestId: pending)
        journal.markResultViewed(requestId: pending)
        XCTAssertNil(journal.turn(withId: pending)?.resultViewedAt, "没有结果就没有已读")

        let done = newRequestId()
        journal.begin(requestId: done)
        journal.apply(VoiceStatusEnvelope.status(
            requestId: done,
            state: .completed,
            result: VoiceResultPayload(summary: "OK", isTruncated: false, speechSha256: nil, speechDurationMs: nil)
        ))
        let first = Date(timeIntervalSince1970: 1_753_920_000)
        journal.markResultViewed(requestId: done, at: first)
        journal.markResultViewed(requestId: done, at: first.addingTimeInterval(60))
        XCTAssertEqual(journal.turn(withId: done)?.resultViewedAt, first, "重复标记不覆盖首读时间")
    }

    func testOnStateAppliedFiresForLocalAndRemoteEvents() {
        // ESS-55 触觉链路的事件源：本地状态与远端状态入账都必须回调；
        // 被去重/非法转移拒绝的事件不回调。
        let journal = VoiceTurnJournal(directory: directory)
        let requestId = newRequestId()
        var received: [VoiceTurnState] = []
        journal.onStateApplied = { id, state in
            XCTAssertEqual(id, requestId)
            received.append(state)
        }
        journal.begin(requestId: requestId)
        journal.recordLocal(.waitingForMac, requestId: requestId)
        journal.apply(VoiceStatusEnvelope.status(requestId: requestId, state: .accepted))
        journal.apply(VoiceStatusEnvelope.status(requestId: requestId, state: .accepted))
        journal.apply(VoiceStatusEnvelope.status(requestId: requestId, state: .completed))
        XCTAssertEqual(received, [.waitingForMac, .accepted, .completed])
    }
}
