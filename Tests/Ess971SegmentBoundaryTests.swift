import XCTest
@testable import WristAgentCore

/// ESS-971 整改：**段落屏障不得终结 media session**。
///
/// 2026-08-22 真机（`request_id=01a027f8-fcc3`，包 `fabfa62`）：接线本身生效了——
///
/// ```
/// 05:37:27.357  downlink_segment_barrier    segment_index=0 final_sequence=46
/// 05:37:27.358  segment_playback_finished   bytes_played=885220
/// 05:37:27.359  session_answer_interim      turn_index=1        ← 会话层正确退回 thinking
/// ```
///
/// 但第二段的每一帧都被丢：
///
/// ```
/// 05:37:28.166  downlink_drop reason=sessionEnded   ← seq 47
/// 05:37:28.190  downlink_drop reason=sessionEnded   ← seq 48
/// …10 帧全部 sessionEnded…
/// 05:38:12.763  session_thinking_hard_timeout       ← 45s 兜底才把会话捞回
/// ```
///
/// 根因：段落屏障复用了 `audio.done` 的整条收尾路径，而
/// `RealtimeMediaSession.receiveDone` 在屏障释放时会 `downlink.endSession()`
/// （注释原文：「late frames from THIS response are rejected as `.sessionEnded`」）。
/// 那对回合终态是对的，对**段落**边界是致命的——下一段的 delta 正是「late frames」。
final class Ess971SegmentBoundaryTests: XCTestCase {

    private func makeSession() -> (RealtimeMediaSession, RealtimeMediaSession.TurnHandle) {
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(uplinkFrameBytes: 128),
            now: { 1_800_000_000_000 },
            sessionIdFactory: { "11111111-0000-0000-0000-000000000001" }
        )
        let handle = session.beginTurn(requestId: "22222222-0000-0000-0000-000000000001")
        session.openGeneration(1)
        return (session, handle)
    }

    private func chunk(
        _ handle: RealtimeMediaSession.TurnHandle, _ seq: Int
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: seq,
            capturedAtMs: 1_800_000_000_000 + Int64(seq),
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: UInt8(seq % 251), count: 64)
        )
    }

    /// 段落屏障之后，下一段的 delta **必须仍被接受**。
    func testSegmentBoundaryKeepsSessionOpenForNextSegment() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        for seq in 0...2 {
            session.receiveDownlink(chunk(handle, seq), responseId: "r-A", generation: 1)
        }
        // 段落边界（不是回合终态）
        session.receiveDone(
            finalSequence: 2, responseId: "r-A", generation: 1, isSegmentBoundary: true
        )
        events.removeAll()

        // 工具跑完，第二段来了——序号跨段连续。
        session.receiveDownlink(chunk(handle, 3), responseId: "r-A", generation: 1)

        let dropped = events.contains { event in
            if case .downlinkDropped = event { return true }
            return false
        }
        XCTAssertFalse(dropped, "段落屏障后第二段被丢 —— 真机上就是这样整段消失的")
    }

    /// 对照：**回合终态**仍然必须关掉 session，迟到帧照旧按 `.sessionEnded` 拒绝。
    /// 这条口径不能被本次整改破坏（ESS-404 的既有契约）。
    func testTurnTerminalStillEndsSession() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        for seq in 0...2 {
            session.receiveDownlink(chunk(handle, seq), responseId: "r-A", generation: 1)
        }
        session.receiveDone(finalSequence: 2, responseId: "r-A", generation: 1)
        events.removeAll()

        session.receiveDownlink(chunk(handle, 3), responseId: "r-A", generation: 1)

        let dropped = events.contains { event in
            if case .downlinkDropped = event { return true }
            return false
        }
        XCTAssertTrue(dropped, "回合终态之后的迟到帧仍必须被拒 —— ESS-404 既有契约")
    }

    /// 段落屏障本身仍要释放（这一段的音频要播出来），只是不关 session。
    func testSegmentBoundaryStillReleasesBarrier() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        for seq in 0...2 {
            session.receiveDownlink(chunk(handle, seq), responseId: "r-A", generation: 1)
        }
        session.receiveDone(
            finalSequence: 2, responseId: "r-A", generation: 1, isSegmentBoundary: true
        )

        let released = events.contains { event in
            if case .doneArrived(_, let outcome) = event,
               case .barrierReleased = outcome { return true }
            return false
        }
        XCTAssertTrue(released, "段落音频必须照常收齐并播出")
    }
}
