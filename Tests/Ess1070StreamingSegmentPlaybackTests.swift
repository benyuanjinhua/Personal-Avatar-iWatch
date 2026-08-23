import XCTest
@testable import WristAgentCore

/// ESS-1070：服务端增量语音（多段 `audio.segment_done` + 单一回合终态
/// `audio.done`）在设备侧的回执与回合收口回归。
///
/// 关键事实（`AudioRealtimeGateway/qwen-agent-transport.mjs`）：**一个回合的
/// 每一段共用同一个 `response_id`**——`openTurn({ responseId })` 是回合级参数，
/// `agent.audio.delta` / `agent.audio.segment_done` / `agent.audio.done` 都盖
/// 同一个值。因此播放回执状态机必须能在同一个 `response_id` 上**多次**开合，
/// 否则第一段的段落屏障一收口，后面所有段的 `.started/.ended` 就永久消失。
final class Ess1070StreamingSegmentPlaybackTests: XCTestCase {

    /// 复现：同一 `response_id` 的第二段播放完全没有回执。
    ///
    /// 时序取自真机多段回合（ESS-969/ESS-1002 修好 delta 通路之后）：
    /// 段0「正在查询…」→ `audio.segment_done` → 段1 真答案 → `audio.done`。
    /// 修复前 `requestDrain` 在段0 就把 `endedEmitted` 永久置位，段1 的
    /// `bufferCompleted` 和 `requestDrain` 全部返回 nil，Watch 侧
    /// `onAnswerPlaybackFinished` 永不触发，回合只能等 45s 硬超时。
    func testSecondSegmentOfSameResponseStillProducesReceipts() {
        var tracker = RealtimePlaybackReceiptTracker()
        let responseId = "resp-1070"

        // 段 0：一帧音频播完 → started，段落屏障 → ended。
        tracker.enqueue(responseId: responseId, bytes: 64)
        let seg0 = tracker.bufferCompleted(responseId: responseId, bytes: 64)
        XCTAssertEqual(seg0.started?.responseId, responseId)
        let seg0End = tracker.requestDrain(responseId: responseId)
        XCTAssertEqual(seg0End?.bytesPlayed, 64, "段落屏障必须给出本段真实播放字节")

        // 段 1：同一个 response_id 的新音频。
        tracker.enqueue(responseId: responseId, bytes: 128)
        let seg1 = tracker.bufferCompleted(responseId: responseId, bytes: 128)
        XCTAssertEqual(
            seg1.started?.responseId, responseId,
            "第二段真正出声了，必须重新发 playback.started"
        )

        // 回合终态 `audio.done` → 第二段必须收口。
        let turnEnd = tracker.requestDrain(responseId: responseId)
        XCTAssertNotNil(
            turnEnd,
            "第二段没有 .ended —— onAnswerPlaybackFinished 永不触发，回合只能等 45s 硬超时"
        )
        XCTAssertEqual(
            turnEnd?.bytesPlayed, 128,
            "段落回执按段计账：本段播了 128 字节，不该把段0 的 64 再算一次"
        )
    }

    /// 段落屏障后新一段的帧**先到**、终态 done 后到时，回执同样要按段重新开合。
    func testSegmentRestartWhenTailCompletesAfterDrain() {
        var tracker = RealtimePlaybackReceiptTracker()
        let responseId = "resp-1070-b"

        tracker.enqueue(responseId: responseId, bytes: 32)
        _ = tracker.bufferCompleted(responseId: responseId, bytes: 32)
        XCTAssertNotNil(tracker.requestDrain(responseId: responseId))

        // 段 1 的两帧先排队，done 后到 → drain 落在最后一帧完成之后。
        tracker.enqueue(responseId: responseId, bytes: 48)
        tracker.enqueue(responseId: responseId, bytes: 48)
        XCTAssertNil(
            tracker.requestDrain(responseId: responseId),
            "还有 buffer 没播完，不得提前发 .ended"
        )
        _ = tracker.bufferCompleted(responseId: responseId, bytes: 48)
        let last = tracker.bufferCompleted(responseId: responseId, bytes: 48)
        XCTAssertEqual(last.ended?.bytesPlayed, 96, "补齐后按本段字节收口")
    }

    /// 增量语音的真实时序：段落屏障到达时**本段音频还没播完**，下一段的帧
    /// 紧接着就排进了同一个 `response_id`（ADR ESS-1060 的分句窗口只有
    /// 350 ms，段与段几乎背靠背）。
    ///
    /// 收口必须按「屏障那一刻排了多少 buffer」的快照结算，而不是「completed
    /// == queued」——后者会被下一段的音频一路推迟，整回合只收口一次，回合
    /// 终态那一次永远等不到。
    func testSegmentBarrierSettlesBeforeNextSegmentAudioArrives() {
        var tracker = RealtimePlaybackReceiptTracker()
        let responseId = "resp-1070-c"
        var ended: [RealtimePlaybackReceiptTracker.EndedReceipt] = []

        // 段 0 的一帧排队，屏障先到（帧还没播完）。
        tracker.enqueue(responseId: responseId, bytes: 64)
        XCTAssertNil(tracker.requestDrain(responseId: responseId))

        // 段 1 的两帧抢在段 0 播完之前排进来。
        tracker.enqueue(responseId: responseId, bytes: 100)
        tracker.enqueue(responseId: responseId, bytes: 100)

        // 段 0 的帧播完 → 段 0 必须当场收口，不能等段 1。
        if let receipt = tracker.bufferCompleted(responseId: responseId, bytes: 64).ended {
            ended.append(receipt)
        }
        XCTAssertEqual(
            ended.map(\.bytesPlayed), [64],
            "段落屏障必须在快照的 buffer 播完时收口，实际=\(ended)"
        )

        // 回合终态 done → 段 1 的屏障重新武装。
        XCTAssertNil(tracker.requestDrain(responseId: responseId))
        let mid = tracker.bufferCompleted(responseId: responseId, bytes: 100)
        XCTAssertEqual(mid.started?.responseId, responseId, "段 1 出声要重新发 started")
        XCTAssertNil(mid.ended, "段 1 还有一帧没播完")
        if let receipt = tracker.bufferCompleted(responseId: responseId, bytes: 100).ended {
            ended.append(receipt)
        }
        XCTAssertEqual(
            ended.map(\.bytesPlayed), [64, 200],
            "回合终态必须有独立的 .ended —— 它才是 onAnswerPlaybackFinished 的唯一来源"
        )
    }

    /// 单段回合不得因为本次改动多发一次 `.ended`（幂等仍然成立）。
    func testSingleSegmentTurnStillEndsExactlyOnce() {
        var tracker = RealtimePlaybackReceiptTracker()
        tracker.enqueue(responseId: "resp-single", bytes: 64)
        _ = tracker.bufferCompleted(responseId: "resp-single", bytes: 64)
        XCTAssertNotNil(tracker.requestDrain(responseId: "resp-single"))
        XCTAssertNil(
            tracker.requestDrain(responseId: "resp-single"),
            "重复 done 不得重复收口"
        )
    }

    // MARK: - 弱网下的多段流式：边收边播 + 保序去重 + 越代隔离

    /// ESS-1070 验收 1 的端到端断言（`RealtimeMediaSession` 层）：
    /// 两段增量语音，中间夹重复帧、窗口内乱序帧和一帧**旧 generation** 的音频。
    ///
    /// 必须同时成立：
    ///  * 每一帧一到齐就释放（不等整段聚合）；
    ///  * 释放顺序严格单调、无重复；
    ///  * 旧 generation 的帧一帧都不得进入播放队列；
    ///  * 段落屏障释放本段但不终结回合，回合终态屏障单独释放一次。
    func testMultiSegmentStreamStaysOrderedDeduplicatedAndGenerationIsolated() {
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(uplinkFrameBytes: 128),
            now: { 1_800_000_000_000 },
            sessionIdFactory: { "11111111-0000-0000-0000-000000001070" }
        )
        let handle = session.beginTurn(requestId: "22222222-0000-0000-0000-000000001070")
        session.openGeneration(2)

        var played: [Int] = []
        var releases: [Int] = []
        var dropped: [RealtimeDownlinkPlayback.DropReason] = []
        session.onEvent = { event in
            switch event {
            case .playbackReady(let playables):
                played.append(contentsOf: playables.map(\.chunk.sequence))
            case .doneArrived(_, .barrierReleased(let final, _)),
                 .doneBarrierReleased(_, let final, _):
                releases.append(final)
            case .downlinkDropped(let reason):
                dropped.append(reason)
            default:
                break
            }
        }

        func chunk(_ seq: Int) -> VoiceStreamChunk {
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: seq,
                capturedAtMs: 1_800_000_000_000 + Int64(seq),
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: UInt8(seq % 251), count: 64)
            )
        }

        // 段 0：seq 0 边收边播；seq 1 重复投递；旧代的一帧夹在中间。
        session.receiveDownlink(chunk(0), responseId: "r", generation: 2)
        XCTAssertEqual(played, [0], "首帧必须立即释放，不得等整段聚合")
        session.receiveDownlink(chunk(1), responseId: "r", generation: 2)
        session.receiveDownlink(chunk(1), responseId: "r", generation: 2)
        session.receiveDownlink(chunk(9), responseId: "r-old", generation: 1)
        session.receiveDone(
            finalSequence: 1, responseId: "r", generation: 2, isSegmentBoundary: true
        )

        // 段 1：窗口内乱序（3 先于 2 到达），尾帧补齐后才释放回合终态屏障。
        session.receiveDownlink(chunk(3), responseId: "r", generation: 2)
        session.receiveDone(finalSequence: 3, responseId: "r", generation: 2)
        XCTAssertEqual(releases, [1], "尾帧未到齐，回合终态屏障不得释放")
        session.receiveDownlink(chunk(2), responseId: "r", generation: 2)

        XCTAssertEqual(played, [0, 1, 2, 3], "释放必须严格保序且不重复，实际=\(played)")
        XCTAssertEqual(releases, [1, 3], "段落屏障与回合终态屏障各释放一次")
        XCTAssertTrue(
            dropped.contains(.staleGeneration(incoming: 1, active: 2)),
            "旧 generation 的音频必须被丢弃并留证，实际=\(dropped)"
        )
        XCTAssertFalse(played.contains(9), "越代音频进入了播放队列")
    }
}
