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
        isPlaying: Bool = false
    ) -> RuntimeSessionPolicy.Verdict {
        RuntimeSessionPolicy.decide(
            turns: turns,
            deliveredRequestIds: delivered,
            isRecording: isRecording,
            isPlaying: isPlaying,
            now: now
        )
    }

    func testIdleWithNoTurnsReleases() {
        XCTAssertEqual(decide().decision, .release)
    }

    func testRecordingHolds() {
        XCTAssertEqual(decide(isRecording: true).decision, .hold(reason: "recording"))
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
}
