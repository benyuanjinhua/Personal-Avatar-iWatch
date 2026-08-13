import XCTest
@testable import WristAgentCore

/// ESS-45：ExtendedRuntimeSession 持有/释放决策的单测。
/// 覆盖：录音/播放/活跃回合持有；completed 等音频的 grace 窗口与到期释放；
/// 播放交付后释放；失败/取消/纯文本结果不持有。
final class RuntimeSessionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_753_920_000)

    private func makeTurn(
        id: String = UUIDv7.generate().uuidString.lowercased(),
        states: [VoiceTurnState],
        endingAt terminalAt: Date? = nil,
        result: VoiceResultPayload? = nil,
        speechFileName: String? = nil
    ) -> VoiceTurnRecord {
        let base = terminalAt ?? now
        let events = states.enumerated().map { index, state in
            VoiceTurnEvent(
                state: state,
                at: base.addingTimeInterval(TimeInterval(index - states.count + 1))
            )
        }
        return VoiceTurnRecord(
            requestId: id,
            createdAt: events.first?.at ?? base,
            events: events,
            permission: nil,
            permissionApproved: nil,
            result: result,
            failureStage: nil,
            speechFileName: speechFileName
        )
    }

    private func decide(
        turns: [VoiceTurnRecord] = [],
        delivered: Set<String> = [],
        isRecording: Bool = false,
        isPlaying: Bool = false,
        realtimePending: Bool = false
    ) -> RuntimeSessionPolicy.Verdict {
        RuntimeSessionPolicy.decide(
            turns: turns,
            deliveredRequestIds: delivered,
            isRecording: isRecording,
            isPlaying: isPlaying,
            now: now,
            realtimePending: realtimePending
        )
    }

    func testIdleWithNoTurnsReleases() {
        XCTAssertEqual(decide().decision, .release)
    }

    func testRecordingHolds() {
        let decision = decide(isRecording: true).decision
        XCTAssertEqual(decision, .hold(reason: "recording"))
        XCTAssertFalse(RuntimeSessionPolicy.shouldStartExtendedSession(for: decision))
    }

    /// ESS-689：主球 touch-down 起录时先 defer；touch-up 进入持续会话后，
    /// 即使仍在录音等待用户开口，也必须消费 defer 并启动 runtime。
    func testContinuousRecordingConsumesDeferredStartAfterGestureReleased() {
        let recording = decide(isRecording: true).decision

        XCTAssertFalse(
            RuntimeSessionPolicy.shouldStartExtendedSession(
                for: recording,
                recordingGestureReleased: false
            ),
            "手势仍按住时不得启动 runtime，以免系统取消手势"
        )
        XCTAssertTrue(
            RuntimeSessionPolicy.shouldStartExtendedSession(
                for: recording,
                recordingGestureReleased: true
            ),
            "松手进入持续会话后必须在持续录音态消费 defer"
        )
        XCTAssertEqual(recording, .hold(reason: "recording"),
                       "消费 runtime defer 不得结束录音或改变持有原因")
    }

    /// ESS-692 复审补强：重复 enter 不得重复触发 reevaluate/start；退出后
    /// 必须恢复普通 PTT 的“录音中不启动 runtime”门。
    func testRecordingGateEnterIsIdempotentAndExitRestoresPTTDeferral() {
        var gate = RuntimeSessionRecordingGate()
        let recording = decide(isRecording: true).decision

        XCTAssertFalse(gate.recordingGestureReleased)
        XCTAssertTrue(gate.setContinuousConversationActive(true))
        XCTAssertTrue(gate.recordingGestureReleased)
        XCTAssertFalse(gate.setContinuousConversationActive(true),
                       "重复 enter 必须为空操作")
        XCTAssertTrue(RuntimeSessionPolicy.shouldStartExtendedSession(
            for: recording,
            recordingGestureReleased: gate.recordingGestureReleased
        ))

        XCTAssertTrue(gate.setContinuousConversationActive(false))
        XCTAssertFalse(gate.recordingGestureReleased)
        XCTAssertFalse(gate.setContinuousConversationActive(false),
                       "重复 exit 必须为空操作")
        XCTAssertFalse(RuntimeSessionPolicy.shouldStartExtendedSession(
            for: recording,
            recordingGestureReleased: gate.recordingGestureReleased
        ), "退出持续会话后普通 PTT 录音必须继续 defer runtime")
    }

    func testExtendedSessionStartsAfterGestureForActiveTurn() {
        let turn = makeTurn(states: [.recorded, .waitingForMac])
        let decision = decide(turns: [turn]).decision
        XCTAssertEqual(decision, .hold(reason: "turn_active:\(turn.requestId)"))
        XCTAssertTrue(RuntimeSessionPolicy.shouldStartExtendedSession(for: decision))
    }

    func testExtendedSessionDoesNotStartWhenIdle() {
        XCTAssertFalse(RuntimeSessionPolicy.shouldStartExtendedSession(for: .release))
    }

    func testPlayingHolds() {
        XCTAssertEqual(decide(isPlaying: true).decision, .hold(reason: "playing"))
    }

    func testActiveTurnHoldsThroughBackgroundWait() {
        // 22:49 现场：后台任务 28 秒等待期间 App 挂起。活跃回合必须持有。
        let turn = makeTurn(states: [.recorded, .waitingForMac, .backgroundProcessing])
        let verdict = decide(turns: [turn])
        XCTAssertEqual(verdict.decision, .hold(reason: "turn_active:\(turn.requestId)"))
    }

    func testCompletedPromisingAudioHoldsWithinGrace() {
        // completed 已到、语音还在 transferFile 路上：grace 窗口内持有，到期复评。
        let turn = makeTurn(
            states: [.recorded, .backgroundProcessing, .completed],
            endingAt: now.addingTimeInterval(-10),
            result: VoiceResultPayload(summary: "好的", isTruncated: false, speechSha256: "ab", speechDurationMs: 1000)
        )
        let verdict = decide(turns: [turn])
        XCTAssertEqual(verdict.decision, .hold(reason: "awaiting_result_audio:\(turn.requestId)"))
        XCTAssertEqual(
            verdict.reviewAt,
            now.addingTimeInterval(-10 + RuntimeSessionPolicy.resultAudioGrace)
        )
    }

    func testCompletedPromisingAudioReleasesAfterGrace() {
        // 有界执行：语音一直不来也不能无限持有。
        let turn = makeTurn(
            states: [.recorded, .completed],
            endingAt: now.addingTimeInterval(-RuntimeSessionPolicy.resultAudioGrace - 1),
            result: VoiceResultPayload(summary: "好的", isTruncated: false, speechSha256: "ab", speechDurationMs: 1000)
        )
        XCTAssertEqual(decide(turns: [turn]).decision, .release)
    }

    func testCompletedTextOnlyReleases() {
        let turn = makeTurn(
            states: [.recorded, .completed],
            result: VoiceResultPayload(summary: "纯文本", isTruncated: false, speechSha256: nil, speechDurationMs: nil)
        )
        XCTAssertEqual(decide(turns: [turn]).decision, .release)
    }

    func testAttachedUnplayedSpeechHoldsUntilDelivered() {
        let turn = makeTurn(
            states: [.recorded, .completed],
            endingAt: now.addingTimeInterval(-5),
            result: VoiceResultPayload(summary: "好的", isTruncated: false, speechSha256: "ab", speechDurationMs: 1000),
            speechFileName: "x.m4a"
        )
        XCTAssertEqual(
            decide(turns: [turn]).decision,
            .hold(reason: "speech_unplayed:\(turn.requestId)")
        )
        // 播放交付（play_finished）后即释放，speechFileName 是否已清空无关紧要。
        XCTAssertEqual(decide(turns: [turn], delivered: [turn.requestId]).decision, .release)
    }

    func testDeliveredCompletedTurnReleasesEvenWithinGrace() {
        // 播完后 clearSpeech 把 speechFileName 置空，靠 delivered 标记避免
        // 「看起来音频没到」而空持有到 grace 结束。
        let turn = makeTurn(
            states: [.recorded, .completed],
            endingAt: now.addingTimeInterval(-1),
            result: VoiceResultPayload(summary: "好的", isTruncated: false, speechSha256: "ab", speechDurationMs: 1000)
        )
        XCTAssertEqual(decide(turns: [turn], delivered: [turn.requestId]).decision, .release)
    }

    func testFailedAndCancelledTurnsRelease() {
        let failed = makeTurn(states: [.recorded, .failed])
        let cancelled = makeTurn(states: [.recorded, .cancelled])
        XCTAssertEqual(decide(turns: [failed, cancelled]).decision, .release)
    }

    func testRecordingTakesPriorityOverGraceHold() {
        // 录音中即使有等音频的回合，理由也应记为 recording（新回合是更强的持有原因）。
        let turn = makeTurn(
            states: [.recorded, .completed],
            result: VoiceResultPayload(summary: "好的", isTruncated: false, speechSha256: "ab", speechDurationMs: 1000)
        )
        XCTAssertEqual(decide(turns: [turn], isRecording: true).decision, .hold(reason: "recording"))
    }

    // MARK: ESS-532 实时流式待播持有

    func testRealtimePendingHoldsWithTimeout() {
        // 录音结束 → 下行首帧到达前：realtimePending=true 持有 session，
        // 防止降腕挂起 AVAudioEngine 导致 delta 无法渲染。
        let verdict = decide(realtimePending: true)
        XCTAssertEqual(verdict.decision, .hold(reason: "realtime_playback_pending"))
        XCTAssertEqual(
            verdict.reviewAt,
            now.addingTimeInterval(RuntimeSessionPolicy.realtimePlaybackPendingTimeout)
        )
    }

    func testRealtimePendingTakesPriorityOverActiveTurn() {
        // 实时待播必须在活跃回合之前返回——turn journal 尚未标记为 active，
        // 但下行 delta 已经在途。如果先检查 activeTurn（返回 release），
        // 整个 realtimePending 逻辑就白写了。
        let turn = makeTurn(states: [.recorded])
        // 非活跃回合（.recorded 不满足 isActive），realtimePending=true 应持有。
        let verdict = decide(turns: [turn], realtimePending: true)
        XCTAssertEqual(verdict.decision, .hold(reason: "realtime_playback_pending"))
    }

    func testRealtimePendingExtendedSessionStarts() {
        let decision = decide(realtimePending: true).decision
        XCTAssertTrue(RuntimeSessionPolicy.shouldStartExtendedSession(for: decision))
    }

    func testRealtimePendingDoesNotOverrideRecording() {
        // 录音中 realtimePending 也应为 true（PCM 采集和下行准备可以重叠），
        // 但 decision 理由应为 recording（更强的 hold reason）。
        XCTAssertEqual(
            decide(isRecording: true, realtimePending: true).decision,
            .hold(reason: "recording")
        )
    }

    func testRealtimePendingDoesNotOverridePlaying() {
        XCTAssertEqual(
            decide(isPlaying: true, realtimePending: true).decision,
            .hold(reason: "playing")
        )
    }

    // MARK: ESS-58 锁屏收回后的重持

    func testResignedFrontmostAllowsRestartAfterForeground() {
        // 锁屏/切走（resignedFrontmost=3，真机日志 reason_code=3）不是预算
        // 耗尽，解锁回前台应允许重新持有。
        XCTAssertTrue(RuntimeSessionPolicy.allowsRestartAfterForeground(invalidationReasonCode: 3))
    }

    func testOtherInvalidationReasonsKeepBoundedExecution() {
        // error(-1)/none(0)/sessionInProgress(1)/expired(2)/suppressedBySystem(4)：
        // 维持 ESS-45 有界执行，不自动续命。
        for code in [-1, 0, 1, 2, 4] {
            XCTAssertFalse(
                RuntimeSessionPolicy.allowsRestartAfterForeground(invalidationReasonCode: code),
                "reason_code=\(code) 不应允许自动重持"
            )
        }
    }
}
