import XCTest
@testable import WristAgentCore

/// ESS-655（F6）验收标准 1 / 2 的契约测试。
///
/// 这套用例盯的是三件事，全部是「事后才会发现」的那类问题：
/// 1. 12 个事件的名字与必带字段与 ESS-634 设计稿 §10.2 逐条对齐——
///    表在这里写死，谁改了 schema 而没改设计稿（或反过来）当场红；
/// 2. 任何一个必需字段缺失、任何一个非法枚举值都**抛得出来**，
///    不是「宽容地当成 nil」；
/// 3. 工厂造出来的每一条记录自己都过得了校验（写侧读侧同构）。
final class PhoneModeTelemetryTests: XCTestCase {

    // MARK: - 契约表（设计稿 §10.2 的逐条副本）

    /// 事件名 → 必带字段。**改这张表前先改设计稿**，反之亦然。
    private let contract: [String: Set<String>] = [
        "session_failed_notice_shown": ["reason", "from_phase", "copy_id"],
        "session_failed_retry_tapped": ["reason", "dwell_ms"],
        "session_failed_auto_hangup": ["reason"],
        "session_thinking_slow": ["turn_index"],
        "session_idle_hint": ["level"],
        "session_idle_hangup": ["turns"],
        "session_background_cap": ["duration_ms"],
        "session_call_summary": ["turns", "duration_ms", "end_reason", "conversation_id"],
        "session_enter_rejected": ["reason", "hold_ms"],
        "session_speaking_interrupted": ["source", "detect_ms", "stop_ms"],
        "session_barge_in_self_echo": ["turn_index", "energy_db"],
        "voice_barge_in_gate": ["state", "reason"],
    ]

    func testEventCatalogMatchesDesignSpec() {
        XCTAssertEqual(
            Set(PhoneModeTelemetry.Event.allCases.map(\.rawValue)), Set(contract.keys),
            "事件清单与设计稿 §10.2 不一致——11 个新增 + 1 个扩字段"
        )
        XCTAssertEqual(PhoneModeTelemetry.Event.allCases.count, 12)

        for event in PhoneModeTelemetry.Event.allCases {
            XCTAssertEqual(
                Set(event.requiredFields), contract[event.rawValue],
                "\(event.rawValue) 的必带字段与设计稿不一致"
            )
        }
    }

    // MARK: - 写侧：每个工厂造出的记录都自洽

    /// 12 个事件各造一条真实记录，逐条过严格校验（含「不许有契约外字段」）。
    /// 这是「写侧拼不出非法 detail」的证据。
    func testEveryFactoryProducesValidRecord() throws {
        for record in Self.sampleRecords() {
            XCTAssertNoThrow(
                try PhoneModeTelemetry.validate(record),
                "\(record.event) 的工厂产出没通过自己的 schema：\(record.detail)"
            )
        }
        XCTAssertEqual(
            Set(Self.sampleRecords().map(\.event)),
            Set(PhoneModeTelemetry.Event.allCases.map(\.rawValue)),
            "样本没覆盖全部事件——新增事件必须同时补样本"
        )
    }

    func testDetailEncodingIsCanonicalAndOrdered() {
        let record = PhoneModeTelemetry.callSummary(
            turns: 3, durationMs: 42_000, endReason: .userExit, conversationID: "conv-7"
        )
        XCTAssertEqual(record.event, "session_call_summary")
        XCTAssertEqual(
            record.detail,
            "turns=3 duration_ms=42000 end_reason=user_exit conversation_id=conv-7",
            "字段顺序即编码顺序，同一事件在任何调用点产出的字节必须一致"
        )
    }

    /// 点球与语音必须落在同一事件、靠 `source` 区分，且语音路径带得出
    /// 检测/停播两段延迟（验收标准 2）。
    func testSpeakingInterruptedDistinguishesVoiceFromOrbTap() throws {
        let orbTap = PhoneModeTelemetry.speakingInterrupted(
            source: .orbTap, detectMs: 0, stopMs: 120, turnIndex: 2
        )
        let voice = PhoneModeTelemetry.speakingInterrupted(
            source: .voice, detectMs: 310, stopMs: 180, turnIndex: 2
        )
        XCTAssertEqual(orbTap.event, voice.event, "两种打断必须是同一个事件，否则误触发率算不出来")

        let orbFields = try PhoneModeTelemetry.validate(orbTap)
        let voiceFields = try PhoneModeTelemetry.validate(voice)
        XCTAssertEqual(orbFields["source"], "orb_tap")
        XCTAssertEqual(orbFields["detect_ms"], "0", "点球没有检测过程，detect_ms 恒 0")
        XCTAssertEqual(voiceFields["source"], "voice")
        XCTAssertEqual(voiceFields["detect_ms"], "310")
        XCTAssertEqual(voiceFields["stop_ms"], "180")
    }

    /// 负数是调用点算错时间差的典型症状（起止取反）。夹到 0 而不是写出
    /// `stop_ms=-3`——后者会让 schema 当场拒收，把一条本可用的证据整条丢掉。
    func testNegativeDurationsAreClampedNotEmitted() throws {
        let record = PhoneModeTelemetry.speakingInterrupted(
            source: .voice, detectMs: -5, stopMs: -1, turnIndex: nil
        )
        let fields = try PhoneModeTelemetry.validate(record)
        XCTAssertEqual(fields["detect_ms"], "0")
        XCTAssertEqual(fields["stop_ms"], "0")
        XCTAssertNil(fields["turn_index"], "turn_index 未知时不该编出来")
    }

    /// `energy_db` 是负数为常态，且不能随 locale 变成逗号小数点。
    func testEnergyDBIsNegativeCapableAndLocaleIndependent() throws {
        let record = PhoneModeTelemetry.bargeInSelfEcho(turnIndex: 4, energyDB: -12.34)
        XCTAssertEqual(record.detail, "turn_index=4 energy_db=-12.3")
        let fields = try PhoneModeTelemetry.validate(record)
        XCTAssertEqual(Double(fields["energy_db"] ?? ""), -12.3)
    }

    // MARK: - 读侧：非法输入必须能检测失败

    func testMissingRequiredFieldIsDetected() {
        // 少 stop_ms 的打断事件——F2 接线时最容易漏的那个字段。
        assertThrows(
            event: "session_speaking_interrupted",
            detail: "turn_index=1 source=voice detect_ms=300",
            expected: .missingField(event: "session_speaking_interrupted", field: "stop_ms")
        )
    }

    func testEveryRequiredFieldIsIndividuallyEnforced() throws {
        for record in Self.sampleRecords() {
            guard let event = PhoneModeTelemetry.Event(rawValue: record.event) else {
                return XCTFail("样本事件不在契约内：\(record.event)")
            }
            let fields = try PhoneModeTelemetry.fields(in: record.detail)
            for required in event.requiredFields {
                let reduced = fields
                    .filter { $0.key != required }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                XCTAssertThrowsError(
                    try PhoneModeTelemetry.validate(event: record.event, detail: reduced),
                    "\(record.event) 少了 \(required) 竟然通过了校验"
                ) { error in
                    XCTAssertEqual(
                        error as? PhoneModeTelemetry.ValidationError,
                        .missingField(event: record.event, field: required)
                    )
                }
            }
        }
    }

    func testIllegalEnumValuesAreRejected() {
        assertThrows(
            event: "session_speaking_interrupted",
            detail: "source=shouting detect_ms=10 stop_ms=10",
            expected: .illegalValue(field: "source", value: "shouting")
        )
        assertThrows(
            event: "voice_barge_in_gate",
            detail: "state=maybe reason=user_toggle",
            expected: .illegalValue(field: "state", value: "maybe")
        )
        assertThrows(
            event: "session_call_summary",
            detail: "turns=1 duration_ms=10 end_reason=user_hung_up conversation_id=c1",
            expected: .illegalValue(field: "end_reason", value: "user_hung_up")
        )
        assertThrows(
            event: "session_failed_notice_shown",
            detail: "reason=ready_timeout from_phase=paused copy_id=cannot_connect",
            expected: .illegalValue(field: "from_phase", value: "paused")
        )
        // 静默提示只有两档；第 3 档意味着有人加了提示却没更契约。
        assertThrows(
            event: "session_idle_hint",
            detail: "level=3 silent_ms=90000",
            expected: .illegalValue(field: "level", value: "3")
        )
    }

    func testNonNumericAndNegativeCountsAreRejected() {
        assertThrows(
            event: "session_background_cap",
            detail: "duration_ms=a_while",
            expected: .illegalValue(field: "duration_ms", value: "a_while")
        )
        assertThrows(
            event: "session_enter_rejected",
            detail: "reason=hold_too_long hold_ms=-200",
            expected: .illegalValue(field: "hold_ms", value: "-200")
        )
    }

    func testUnknownEventIsRejected() {
        assertThrows(
            event: "session_totally_made_up",
            detail: "turns=1",
            expected: .unknownEvent("session_totally_made_up")
        )
    }

    func testMalformedAndDuplicateDetailTokensAreRejected() {
        assertThrows(
            event: "session_idle_hangup",
            detail: "turns 3",
            expected: .malformedDetail(token: "turns")
        )
        assertThrows(
            event: "session_idle_hangup",
            detail: "turns=",
            expected: .malformedDetail(token: "turns=")
        )
        // 同一个键两个值——哪个算数无法判定，不许静默取其一。
        assertThrows(
            event: "session_idle_hangup",
            detail: "turns=3 turns=4",
            expected: .duplicateField("turns")
        )
    }

    /// 契约外字段默认放行（日志多带一个诊断字段不该让整条作废），
    /// 严格模式下才报——回归测试用严格模式防字段悄悄漂移。
    func testUnknownFieldIsTolerantByDefaultAndStrictOnDemand() {
        let detail = "turns=3 silent_ms=120000 vendor_hint=x"
        XCTAssertNoThrow(
            try PhoneModeTelemetry.validate(event: "session_idle_hangup", detail: detail)
        )
        assertThrows(
            event: "session_idle_hangup", detail: detail, strict: true,
            expected: .unknownField(event: "session_idle_hangup", field: "vendor_hint")
        )
    }

    // MARK: - 辅助

    private func assertThrows(
        event: String,
        detail: String?,
        strict: Bool = false,
        expected: PhoneModeTelemetry.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try PhoneModeTelemetry.validate(
                event: event, detail: detail, rejectsUnknownFields: strict
            ),
            "\(event) | \(detail ?? "-") 应当校验失败", file: file, line: line
        ) { error in
            XCTAssertEqual(
                error as? PhoneModeTelemetry.ValidationError, expected,
                file: file, line: line
            )
        }
    }

    /// 12 个事件各一条代表性记录，被多个用例复用。
    static func sampleRecords() -> [PhoneModeTelemetry.Record] {
        [
            PhoneModeTelemetry.failedNoticeShown(
                reason: .readyTimeout, fromPhase: .connecting, copyID: .cannotConnect
            ),
            PhoneModeTelemetry.failedRetryTapped(reason: .channelEvent, dwellMs: 2_400),
            PhoneModeTelemetry.failedAutoHangup(reason: .thinkingTimeout, dwellMs: 15_000),
            PhoneModeTelemetry.thinkingSlow(turnIndex: 2, elapsedMs: 25_000),
            PhoneModeTelemetry.idleHint(level: .second, silentMs: 75_000),
            PhoneModeTelemetry.idleHangup(turns: 4, silentMs: 120_000),
            PhoneModeTelemetry.backgroundCap(durationMs: 600_000),
            PhoneModeTelemetry.callSummary(
                turns: 5, durationMs: 90_000, endReason: .idleTimeout, conversationID: "conv-1"
            ),
            PhoneModeTelemetry.enterRejected(holdMs: 830),
            PhoneModeTelemetry.speakingInterrupted(
                source: .voice, detectMs: 320, stopMs: 150, turnIndex: 3
            ),
            PhoneModeTelemetry.bargeInSelfEcho(turnIndex: 3, energyDB: -8.5),
            PhoneModeTelemetry.voiceBargeInGate(state: .off, reason: .launchSnapshot),
        ]
    }
}
