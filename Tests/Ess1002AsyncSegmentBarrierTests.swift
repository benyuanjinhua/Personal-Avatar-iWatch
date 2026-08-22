import XCTest
@testable import WristAgentCore

/// ESS-1002：`audio.segment_done` 在**异步屏障释放**路径上仍会结束 session。
///
/// ESS-971（PR #375）只修了 `RealtimeMediaSession.receiveDone` 的**同步**分支
/// （`markDone` 当场返回 `.barrierReleased/.zeroAudio` 时按 `isSegmentBoundary`
/// 跳过 `downlink.endSession()`）。但控制帧先于尾部音频帧到达时：
///
/// ```
/// audio.delta(seq 0)              → buffered/ready
/// audio.segment_done(final=2)     → markDone 返回 .waiting(missing: [1, 2])
/// audio.delta(seq 1) / (seq 2)    → receiveDownlink 尾部 checkBarrierRelease() 释放
///                                   ↑ 这里当时无条件 endSession()
/// audio.delta(seq 3)  ← 第二段     → .sessionEnded，整段再次消失
/// ```
///
/// 修法：边界类型跟着屏障一起等——`markDone` 在 `.waiting` 时把
/// `isSegmentBoundary` 存进 `RealtimeDownlinkPlayback`，异步释放路径用
/// `consumePendingDoneIsSegmentBoundary()` 取回，同步/异步两条路同口径。
///
/// 本文件覆盖验收要求的四类：同步释放（见 `Ess971SegmentBoundaryTests`，此处
/// 再补终态对照）、异步释放、zero-audio、终态迟到帧。
final class Ess1002AsyncSegmentBarrierTests: XCTestCase {

    private func makeSession() -> (RealtimeMediaSession, RealtimeMediaSession.TurnHandle) {
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(uplinkFrameBytes: 128),
            now: { 1_800_000_000_000 },
            sessionIdFactory: { "11111111-0000-0000-0000-000000000002" }
        )
        let handle = session.beginTurn(requestId: "22222222-0000-0000-0000-000000000002")
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

    private func drops(in events: [RealtimeMediaSession.Event])
        -> [RealtimeDownlinkPlayback.DropReason] {
        events.compactMap { event in
            if case .downlinkDropped(let reason) = event { return reason }
            return nil
        }
    }

    private func barrierReleased(in events: [RealtimeMediaSession.Event]) -> Bool {
        events.contains { event in
            if case .doneBarrierReleased = event { return true }
            return false
        }
    }

    // MARK: - 异步释放（本单的核心失败面）

    /// 段落边界先到、尾帧后到：屏障在 `receiveDownlink` 尾部异步释放，
    /// 释放后 session 必须仍然开着，第二段 delta 必须被接受。
    func testAsyncSegmentBarrierKeepsSessionOpen() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        // 第一段只到了 seq 0；seq 1、2 还在路上。
        session.receiveDownlink(chunk(handle, 0), responseId: "r-A", generation: 1)

        // 控制帧先到 —— 屏障 armed 但收不齐。
        session.receiveDone(
            finalSequence: 2, responseId: "r-A", generation: 1, isSegmentBoundary: true
        )
        let waiting = events.contains { event in
            if case .doneArrived(_, let outcome) = event,
               case .waiting(let missing, _) = outcome { return missing == [1, 2] }
            return false
        }
        XCTAssertTrue(waiting, "前置条件：本用例要覆盖的是 .waiting 之后的异步释放")

        events.removeAll()
        // 尾帧补齐 → 异步释放。
        session.receiveDownlink(chunk(handle, 1), responseId: "r-A", generation: 1)
        session.receiveDownlink(chunk(handle, 2), responseId: "r-A", generation: 1)
        XCTAssertTrue(barrierReleased(in: events), "补齐尾帧后段落屏障必须释放并播完本段")

        events.removeAll()
        // 工具跑完，第二段来了。
        session.receiveDownlink(chunk(handle, 3), responseId: "r-A", generation: 1)
        session.receiveDownlink(chunk(handle, 4), responseId: "r-A", generation: 1)

        XCTAssertEqual(
            drops(in: events), [],
            "异步屏障释放后第二段被丢 —— 真机 05:37:28 那 10 帧 sessionEnded 就是这条路径"
        )
        let ready = events.contains { event in
            if case .playbackReady = event { return true }
            return false
        }
        XCTAssertTrue(ready, "第二段必须继续出声")
    }

    /// 对照：**回合终态**走同一条异步路径时，仍然必须关掉 session。
    func testAsyncTerminalBarrierStillEndsSession() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        session.receiveDownlink(chunk(handle, 0), responseId: "r-A", generation: 1)
        session.receiveDone(finalSequence: 2, responseId: "r-A", generation: 1)
        session.receiveDownlink(chunk(handle, 1), responseId: "r-A", generation: 1)
        session.receiveDownlink(chunk(handle, 2), responseId: "r-A", generation: 1)

        events.removeAll()
        session.receiveDownlink(chunk(handle, 3), responseId: "r-A", generation: 1)

        XCTAssertEqual(
            drops(in: events), [.sessionEnded],
            "回合终态之后的迟到帧仍必须被拒 —— ESS-404 既有契约不能被本次整改破坏"
        )
    }

    /// 段落异步释放之后，本回合真正的终态 `audio.done` 必须仍能关闭 session。
    /// 防的是「边界类型被记住之后忘了清」这一类漏洞。
    func testTerminalAfterAsyncSegmentStillEndsSession() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        // 第一段：异步释放的段落边界。
        session.receiveDownlink(chunk(handle, 0), responseId: "r-A", generation: 1)
        session.receiveDone(
            finalSequence: 2, responseId: "r-A", generation: 1, isSegmentBoundary: true
        )
        session.receiveDownlink(chunk(handle, 1), responseId: "r-A", generation: 1)
        session.receiveDownlink(chunk(handle, 2), responseId: "r-A", generation: 1)

        // 第二段：同样先控制帧后尾帧，但这次是回合终态。
        session.receiveDownlink(chunk(handle, 3), responseId: "r-A", generation: 1)
        session.receiveDone(finalSequence: 4, responseId: "r-A", generation: 1)
        session.receiveDownlink(chunk(handle, 4), responseId: "r-A", generation: 1)

        events.removeAll()
        session.receiveDownlink(chunk(handle, 5), responseId: "r-A", generation: 1)

        XCTAssertEqual(
            drops(in: events), [.sessionEnded],
            "段落边界的标志必须是一次性的，终态 done 之后 session 必须真的关掉"
        )
    }

    /// 屏障释放事件只能发一次 —— 异步释放后再来重复帧不得二次 `doneBarrierReleased`
    /// （ESS-442 B1 的口径，段落路径同样适用）。
    func testAsyncSegmentBarrierReleasesExactlyOnce() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        session.receiveDownlink(chunk(handle, 0), responseId: "r-A", generation: 1)
        session.receiveDone(
            finalSequence: 1, responseId: "r-A", generation: 1, isSegmentBoundary: true
        )
        session.receiveDownlink(chunk(handle, 1), responseId: "r-A", generation: 1)
        session.receiveDownlink(chunk(handle, 1), responseId: "r-A", generation: 1) // 重复帧

        let releases = events.filter { event in
            if case .doneBarrierReleased = event { return true }
            return false
        }
        XCTAssertEqual(releases.count, 1, "段落屏障释放必须恰好一次")
    }

    // MARK: - zero-audio

    /// 段落边界的 zero-audio（`final_sequence = -1`）：本段没有音频，
    /// 但回合没完 —— session 必须开着等下一段。
    func testZeroAudioSegmentBoundaryKeepsSessionOpen() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        session.receiveDone(
            finalSequence: -1, responseId: "r-A", generation: 1, isSegmentBoundary: true
        )
        let zero = events.contains { event in
            if case .doneArrived(_, let outcome) = event,
               case .zeroAudio = outcome { return true }
            return false
        }
        XCTAssertTrue(zero, "前置条件：-1 必须走 zero-audio 契约")

        events.removeAll()
        session.receiveDownlink(chunk(handle, 0), responseId: "r-A", generation: 1)

        XCTAssertEqual(drops(in: events), [], "zero-audio 段落边界之后第二段仍必须被接受")
    }

    /// 对照：**回合终态**的 zero-audio 仍必须关闭 session。
    func testZeroAudioTerminalStillEndsSession() {
        let (session, handle) = makeSession()
        var events: [RealtimeMediaSession.Event] = []
        session.onEvent = { events.append($0) }

        session.receiveDone(finalSequence: -1, responseId: "r-A", generation: 1)

        events.removeAll()
        session.receiveDownlink(chunk(handle, 0), responseId: "r-A", generation: 1)

        XCTAssertEqual(drops(in: events), [.sessionEnded], "终态 zero-audio 之后 session 必须关闭")
    }

    // MARK: - buffer 层直测

    /// `markDone` 只在 `.waiting` 时记住边界类型；同步分支不需要，也不该留下残留。
    func testBufferRemembersBoundaryOnlyWhileWaiting() {
        var buffer = RealtimeDownlinkPlayback()
        buffer.attach(session: RealtimeDownlinkPlayback.SessionKey(
            requestId: "req", sessionId: "sess"
        ))
        _ = buffer.openGeneration(1)

        // 同步释放路径：没有 delta，final=-1 → zeroAudio，不记。
        _ = buffer.markDone(
            finalSequence: -1, responseId: "r-A", generation: 1, isSegmentBoundary: true
        )
        XCTAssertFalse(
            buffer.pendingDoneIsSegmentBoundary,
            "同步分支不需要跨调用记忆，留下残留会让后续终态 done 忘记关 session"
        )

        // 异步等待路径：记住，并且只能被取走一次。
        _ = buffer.markDone(
            finalSequence: 3, responseId: "r-B", generation: 1, isSegmentBoundary: true
        )
        XCTAssertTrue(buffer.pendingDoneIsSegmentBoundary)
        XCTAssertTrue(buffer.consumePendingDoneIsSegmentBoundary())
        XCTAssertFalse(buffer.consumePendingDoneIsSegmentBoundary(), "一次性语义")
    }
}
