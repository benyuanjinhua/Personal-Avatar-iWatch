import XCTest
@testable import WristAgentCore

/// ESS-655（F6）验收标准 3 / 4。
///
/// 验收标准 3 要的是「一次完整链路可按 session/request id 复原且无重复 summary」，
/// 验收标准 4 要的是「四条指标可由事件算出来」。这套用例用**事件流**做输入，
/// 断言的是切分结果和指标数值——口径写在代码里，谁跑都是同一个数。
///
/// 注意：这里的目标值（0% / ≥99% / 0 / 0）是设计稿 §10.3 的【假设】目标，
/// 用例只验「算得出来、算得对」，不宣称真机已达成（R-04.3）。
final class PhoneModeCallMetricsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - 验收标准 3：链路可复原

    func testFullCallChainReconstructsTurnsAndSummary() {
        let samples = healthyCall(turns: 3, startingAt: t0, conversationID: "conv-1")
        let segmentation = PhoneModeCallTrace.segment(samples)

        XCTAssertEqual(segmentation.calls.count, 1)
        XCTAssertTrue(segmentation.rejected.isEmpty, "健康链路不该有任何校验失败记录")

        let call = segmentation.calls.first
        // req-4 是末轮播完后自动开的那一轮聆听——用户没再说话就挂断，
        // 它确实是一个已开启的回合，不该被切分逻辑吞掉。
        XCTAssertEqual(call?.turns.map(\.requestId), ["req-1", "req-2", "req-3", "req-4"],
                       "回合必须按 request_id 复原且顺序与发生顺序一致")
        XCTAssertEqual(call?.summaries.count, 1, "一通有且只有一条 summary")
        XCTAssertEqual(call?.orderViolations, [], "健康链路不该有顺序违例")
        XCTAssertTrue(call?.isClosed == true)

        let metrics = PhoneModeCallMetrics.compute(segmentation)
        XCTAssertTrue(metrics.hasCleanChains)
        XCTAssertEqual(metrics.callsWithoutSummary, 0)
        XCTAssertEqual(metrics.callsWithDuplicateSummary, 0)
    }

    /// summary 在 `session_ended` **之后**到达仍算这一通——P7 与拆链的先后
    /// 取决于 F3 的实现顺序，指标口径不该被那个顺序绑架。
    func testSummaryArrivingAfterSessionEndedStillBelongsToThatCall() {
        var samples = healthyCall(turns: 1, startingAt: t0, conversationID: "conv-1", includesSummary: false)
        let endedAt = samples.last?.ts ?? t0
        samples.append(summary(at: endedAt + 0.05, turns: 1, endReason: .userExit, conversationID: "conv-1"))

        let metrics = PhoneModeCallMetrics.compute(samples)
        XCTAssertEqual(metrics.closedCalls, 1)
        XCTAssertEqual(metrics.callsWithoutSummary, 0)
    }

    /// 「无提示消失」：结束了却没有 summary。目标 0%，这里造一条证明算得出来。
    func testCallWithoutSummaryCountsAsSilentDisappearance() {
        let quiet = healthyCall(turns: 1, startingAt: t0, conversationID: "conv-1", includesSummary: false)
        let good = healthyCall(turns: 1, startingAt: t0 + 100, conversationID: "conv-2")

        let metrics = PhoneModeCallMetrics.compute(quiet + good)
        XCTAssertEqual(metrics.closedCalls, 2)
        XCTAssertEqual(metrics.callsWithoutSummary, 1)
        XCTAssertEqual(metrics.silentDisappearanceRate, 0.5)
        XCTAssertEqual(metrics.callsWithDuplicateSummary, 0, "少一条和多一条是两种病，别混在一起报")
    }

    /// 重复 summary = 有第二个结束路径在自说自话，必须报出来。
    func testDuplicateSummaryIsDetected() {
        var samples = healthyCall(turns: 1, startingAt: t0, conversationID: "conv-1")
        let endedAt = samples.last?.ts ?? t0
        samples.append(summary(at: endedAt + 0.02, turns: 1, endReason: .channelFailed, conversationID: "conv-1"))

        let metrics = PhoneModeCallMetrics.compute(samples)
        XCTAssertEqual(metrics.callsWithDuplicateSummary, 1)
        XCTAssertFalse(metrics.hasCleanChains, "重复 summary 不能算干净链路")
    }

    /// 回合内事件乱序（还没提交就报答完）必须被抓到——这类问题在计数式断言
    /// （「finished 出现 1 次」）下完全隐形。
    func testOutOfOrderTurnEventsAreReported() {
        let samples = [
            enterRequested(at: t0),
            sample(at: t0 + 0.1, "session_next_listening", requestId: "req-1"),
            sample(at: t0 + 0.2, "session_answer_finished", requestId: "req-1"),
            sample(at: t0 + 0.3, "session_turn_committed", requestId: "req-1"),
            sample(at: t0 + 0.4, "session_ended"),
        ]
        let metrics = PhoneModeCallMetrics.compute(samples)
        XCTAssertEqual(metrics.turnOrderViolations.count, 1)
        XCTAssertTrue(metrics.turnOrderViolations[0].contains("req-1"))
    }

    // MARK: - 验收标准 4：指标口径

    func testRelistenSuccessRateUsesFourHundredMillisecondBudget() {
        // 第 1 通：播完 200ms 就回聆听（达标）；第 2 通：600ms（不达标）。
        let fast = callWithRelisten(gap: 0.2, startingAt: t0, conversationID: "conv-1")
        let slow = callWithRelisten(gap: 0.6, startingAt: t0 + 100, conversationID: "conv-2")

        let metrics = PhoneModeCallMetrics.compute(fast + slow)
        XCTAssertEqual(metrics.relistenOpportunities, 2)
        XCTAssertEqual(metrics.relistenWithinBudget, 1)
        XCTAssertEqual(metrics.relistenSuccessRate, 0.5)
    }

    /// 用户在回答播完后直接挂断，不算一次轮转失败——否则「主动结束」会被
    /// 记成系统缺陷，指标就没法用来判定 F3-8 了。
    func testUserHangUpAfterAnswerIsNotARelistenOpportunity() {
        let samples = [
            enterRequested(at: t0),
            sample(at: t0 + 0.1, "session_next_listening", requestId: "req-1"),
            sample(at: t0 + 0.2, "session_turn_committed", requestId: "req-1"),
            sample(at: t0 + 0.3, "session_answer_started", requestId: "req-1"),
            sample(at: t0 + 1.0, "session_answer_finished", requestId: "req-1"),
            sample(at: t0 + 1.1, "session_exit_requested", detail: "source=user"),
            summary(at: t0 + 1.2, turns: 1, endReason: .userExit, conversationID: "conv-1"),
            sample(at: t0 + 1.3, "session_ended", detail: "mic_released=true turns=1"),
        ]
        let metrics = PhoneModeCallMetrics.compute(samples)
        XCTAssertEqual(metrics.relistenOpportunities, 0)
        XCTAssertNil(metrics.relistenSuccessRate, "没有样本时不许返回 0 或 1")
    }

    /// 「每通额外按键数」目标 0：进入、挂断、打断都不算；被失败逼出来的
    /// 长按拒绝与 P6 重试才算。
    func testExtraTapsCountOnlyFailureDrivenPresses() {
        var samples: [PhoneModeCallTrace.Sample] = [
            // 待机屏长按被拒——记在它想打通的那一通头上。
            record(at: t0, PhoneModeTelemetry.enterRejected(holdMs: 900)),
        ]
        samples += healthyCall(turns: 1, startingAt: t0 + 1, conversationID: "conv-1")
        samples.insert(
            record(at: t0 + 1.5, PhoneModeTelemetry.failedRetryTapped(reason: .readyTimeout, dwellMs: 1_200)),
            at: samples.count - 1
        )
        // 打断按 §10.3 明确「除外」。
        samples.insert(
            record(
                at: t0 + 1.6,
                PhoneModeTelemetry.speakingInterrupted(source: .orbTap, detectMs: 0, stopMs: 90, turnIndex: 1),
                requestId: "req-1"
            ),
            at: samples.count - 1
        )

        let metrics = PhoneModeCallMetrics.compute(samples)
        XCTAssertEqual(metrics.calls, 1)
        XCTAssertEqual(metrics.extraTaps, 2, "长按被拒 + P6 重试；点球打断不算")
        XCTAssertEqual(metrics.extraTapsPerCall, 2)
        XCTAssertEqual(metrics.orbTapInterrupts, 1)
        XCTAssertEqual(metrics.voiceInterrupts, 0)
    }

    /// gate 门槛：跑过语音打断且零自身回声才算通过。
    func testVoiceBargeInGateEligibilityRequiresSamplesAndZeroSelfEcho() {
        let clean = PhoneModeCallMetrics.compute(
            healthyCall(turns: 1, startingAt: t0, conversationID: "conv-1") + [
                record(
                    at: t0 + 0.5,
                    PhoneModeTelemetry.speakingInterrupted(source: .voice, detectMs: 300, stopMs: 150, turnIndex: 1),
                    requestId: "req-1"
                ),
            ]
        )
        XCTAssertEqual(clean.voiceInterrupts, 1)
        XCTAssertEqual(clean.voiceBargeInFalseTriggerRate, 0)
        XCTAssertTrue(clean.isEligibleForDefaultOnGate)

        let echoing = PhoneModeCallMetrics.compute(
            healthyCall(turns: 1, startingAt: t0, conversationID: "conv-1") + [
                record(
                    at: t0 + 0.5,
                    PhoneModeTelemetry.speakingInterrupted(source: .voice, detectMs: 300, stopMs: 150, turnIndex: 1),
                    requestId: "req-1"
                ),
                record(at: t0 + 0.6, PhoneModeTelemetry.bargeInSelfEcho(turnIndex: 1, energyDB: -6.2)),
            ]
        )
        XCTAssertEqual(echoing.selfEchoFalseTriggers, 1)
        XCTAssertEqual(echoing.voiceBargeInFalseTriggerRate, 0.5)
        XCTAssertFalse(echoing.isEligibleForDefaultOnGate, "有误触发就不许默认 ON")

        // 没跑过语音打断 = 没有证据，同样不算通过（ESS-650「未通过不得默认 ON」）。
        let untested = PhoneModeCallMetrics.compute(
            healthyCall(turns: 1, startingAt: t0, conversationID: "conv-1")
        )
        XCTAssertNil(untested.voiceBargeInFalseTriggerRate, "零样本不是 0%")
        XCTAssertFalse(untested.isEligibleForDefaultOnGate)
    }

    // MARK: - 外部输入

    /// 校验不过的记录进 `rejected`，不静默混进指标——算不出来和算成 0 是两回事。
    func testInvalidRecordsAreRejectedNotSilentlyCounted() {
        var samples = healthyCall(turns: 1, startingAt: t0, conversationID: "conv-1")
        samples.append(
            sample(at: t0 + 0.5, "session_speaking_interrupted",
                   requestId: "req-1", detail: "source=voice detect_ms=300")  // 缺 stop_ms
        )

        let segmentation = PhoneModeCallTrace.segment(samples)
        XCTAssertEqual(segmentation.rejected.count, 1)
        XCTAssertEqual(
            segmentation.rejected.first?.error,
            .missingField(event: "session_speaking_interrupted", field: "stop_ms")
        )

        let metrics = PhoneModeCallMetrics.compute(segmentation)
        XCTAssertEqual(metrics.voiceInterrupts, 0, "非法记录不许进分子")
        XCTAssertEqual(metrics.rejectedRecords, 1)
        XCTAssertFalse(metrics.hasCleanChains)
    }

    /// 落盘 JSONL → 样本的往返：时间戳必须用写侧同一个 formatter 读回来，
    /// 否则小数秒被丢掉，400ms 这种量级的指标直接失真。
    func testSampleRoundTripsThroughClientLogEntry() throws {
        let ts = ClientLogClock.timestamp(t0)
        let entry = ClientLogEntry(
            ts: ts, requestId: "req-1", module: PhoneModeTelemetry.module,
            event: "session_next_listening", detail: "turn_index=1 reason=answer_finished"
        )
        let sample = try XCTUnwrap(PhoneModeCallTrace.Sample(entry: entry))
        XCTAssertEqual(sample.event, "session_next_listening")
        XCTAssertEqual(sample.requestId, "req-1")
        XCTAssertEqual(sample.ts.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 0.001)

        let broken = ClientLogEntry(ts: "not-a-timestamp", module: "session", event: "session_ended")
        XCTAssertNil(PhoneModeCallTrace.Sample(entry: broken), "时间戳读不出来就不许编一个")
    }

    // MARK: - 事件流构造器

    private func sample(
        at ts: Date, _ event: String, requestId: String? = nil, detail: String? = nil
    ) -> PhoneModeCallTrace.Sample {
        PhoneModeCallTrace.Sample(ts: ts, event: event, requestId: requestId, detail: detail)
    }

    private func record(
        at ts: Date, _ record: PhoneModeTelemetry.Record, requestId: String? = nil
    ) -> PhoneModeCallTrace.Sample {
        PhoneModeCallTrace.Sample(
            ts: ts, event: record.event, requestId: requestId, detail: record.detail
        )
    }

    private func enterRequested(at ts: Date) -> PhoneModeCallTrace.Sample {
        sample(at: ts, "session_enter_requested", detail: "source=orb_tap")
    }

    private func summary(
        at ts: Date, turns: Int,
        endReason: PhoneModeTelemetry.CallEndReason, conversationID: String
    ) -> PhoneModeCallTrace.Sample {
        record(at: ts, PhoneModeTelemetry.callSummary(
            turns: turns, durationMs: 60_000, endReason: endReason, conversationID: conversationID
        ))
    }

    /// 一通正常通话：进入 → N 轮（聆听 → 提交 → 起播 → 播完 → 回聆听）→ 小结 → 结束。
    private func healthyCall(
        turns: Int, startingAt start: Date, conversationID: String, includesSummary: Bool = true
    ) -> [PhoneModeCallTrace.Sample] {
        var samples = [enterRequested(at: start)]
        var cursor = start + 0.1
        for index in 1...turns {
            let requestId = "req-\(index)"
            samples.append(sample(at: cursor, "session_next_listening", requestId: requestId))
            samples.append(sample(at: cursor + 0.1, "session_turn_committed", requestId: requestId))
            samples.append(sample(at: cursor + 0.2, "session_answer_started", requestId: requestId))
            samples.append(sample(at: cursor + 1.0, "session_answer_finished", requestId: requestId))
            cursor += 1.2
        }
        // 末轮播完后回到聆听（会话仍在听，只是没人再说话）。
        samples.append(sample(at: cursor, "session_next_listening", requestId: "req-\(turns + 1)"))
        if includesSummary {
            samples.append(summary(
                at: cursor + 0.5, turns: turns, endReason: .userExit, conversationID: conversationID
            ))
        }
        samples.append(sample(
            at: cursor + 0.6, "session_ended", detail: "mic_released=true turns=\(turns)"
        ))
        return samples
    }

    /// 单轮通话，播完到回聆听的间隔可控——轮转成功率用例专用。
    private func callWithRelisten(
        gap: TimeInterval, startingAt start: Date, conversationID: String
    ) -> [PhoneModeCallTrace.Sample] {
        [
            enterRequested(at: start),
            sample(at: start + 0.1, "session_next_listening", requestId: "req-1"),
            sample(at: start + 0.2, "session_turn_committed", requestId: "req-1"),
            sample(at: start + 0.3, "session_answer_started", requestId: "req-1"),
            sample(at: start + 1.0, "session_answer_finished", requestId: "req-1"),
            sample(at: start + 1.0 + gap, "session_next_listening", requestId: "req-2"),
            summary(at: start + 5, turns: 1, endReason: .userExit, conversationID: conversationID),
            sample(at: start + 5.1, "session_ended", detail: "mic_released=true turns=1"),
        ]
    }
}
