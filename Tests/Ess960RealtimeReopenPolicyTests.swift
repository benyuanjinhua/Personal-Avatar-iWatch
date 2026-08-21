import XCTest
@testable import WristAgentCore

/// ESS-960：已终结的回合不得被上行帧复活。
///
/// 真机 L1 事故形态：47 秒内 255 次握手，节奏 ≈184ms/次 —— 正是 Watch 上行
/// 音频帧的节奏。`PhoneRealtimeSession.openIfNeeded` 由每一个 `audio.append`
/// 驱动，而它的 `switch` 把 `.failed` 漏进了 `default` 分支，于是每帧重建一次
/// transport。本测试把判定本体钉死在 `Shared/`（`iOS/` 没有单测 target，同
/// `RealtimeDownlinkRelay` 的 ESS-751 先例）。
final class Ess960RealtimeReopenPolicyTests: XCTestCase {

    private let turn = RealtimeReopenPolicy.TurnKey(
        requestId: "01a017b1-3cdd-72e1-9137-94cc6b9a836c",
        sessionId: "sess-a"
    )

    // MARK: - 验收标准 1

    /// `.failed` 之后连收 20 个 `audio.append`，**一次都不许**放行建 transport。
    /// 修复前这里会是 20 次 `.open`（= 20 次 WSS 握手）。
    func testTwentyUplinkFramesAfterFailureOpenZeroTransports() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)

        var decisions: [RealtimeReopenPolicy.Decision] = []
        for _ in 0..<20 {
            decisions.append(
                policy.decide(state: .failed, key: turn, trigger: .uplinkFrame)
            )
        }

        XCTAssertEqual(decisions.filter { $0 == .open }.count, 0)
        XCTAssertEqual(
            decisions.filter { $0 == .suppress(reason: RealtimeReopenPolicy.SuppressReason.turnTerminated) }.count, 20
        )
        XCTAssertEqual(policy.suppressedCount, 20)
    }

    /// `audio.commit` 与播放回执走的是同一个 `.uplinkFrame` 入口——
    /// 它们同样不得复活回合（回合失败后 Watch 仍会送 commit）。
    func testCommitAndPlaybackReceiptsCannotRevivedTerminatedTurn() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)
        for _ in 0..<3 {
            XCTAssertEqual(
                policy.decide(state: .failed, key: turn, trigger: .uplinkFrame),
                .suppress(reason: RealtimeReopenPolicy.SuppressReason.turnTerminated)
            )
        }
        XCTAssertEqual(policy.suppressedCount, 3)
    }

    // MARK: - 验收标准 2

    /// Gateway `retriable:false` 之后：同 requestId 不再重开，
    /// **新** requestId 的 `stream.start` 正常开。
    func testRetriableFalseSealsTurnButNewRequestStillOpens() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)

        XCTAssertEqual(
            policy.decide(state: .failed, key: turn, trigger: .uplinkFrame),
            .suppress(reason: RealtimeReopenPolicy.SuppressReason.turnTerminated)
        )

        let nextTurn = RealtimeReopenPolicy.TurnKey(
            requestId: "01a017b2-0000-7000-8000-000000000001", sessionId: "sess-b"
        )
        XCTAssertEqual(
            policy.decide(state: .failed, key: nextTurn, trigger: .streamStart), .open
        )
        // ESS-962 阻断 2：新回合开始**不得**清掉旧回合的终态记账。
        XCTAssertTrue(policy.isTerminated(turn))
    }

    // MARK: - ESS-962 阻断 1

    /// **终态就是终态**：同一个 TurnKey 的 `.streamStart` 也一样 suppress。
    ///
    /// 初版对任何 `.streamStart` 都先清空终态再放行，等于「终态不是终态」，
    /// 与验收标准「`retriable:false` 之后同 requestId 不再重开」直接冲突。
    /// 生产上 Watch 每轮 `pressBegan` 都新铸 `UUIDv7`，同 requestId 的
    /// `stream.start` 只可能是重放/重试。
    func testTerminatedTurnIsNotReopenedEvenByStreamStart() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)
        XCTAssertEqual(
            policy.decide(state: .failed, key: turn, trigger: .streamStart),
            .suppress(reason: RealtimeReopenPolicy.SuppressReason.turnTerminated)
        )
        XCTAssertTrue(policy.isTerminated(turn))
    }

    /// 验收标准 1 的完整口径：同一终态回合的 `.streamStart` **加**连续 20 个
    /// 上行帧，合计 0 次 `.open`；随后新 requestId 仍能正常开。
    func testTerminatedTurnOpensZeroTimesAcrossAllTriggers() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)

        var decisions: [RealtimeReopenPolicy.Decision] = []
        decisions.append(policy.decide(state: .failed, key: turn, trigger: .streamStart))
        for _ in 0..<20 {
            decisions.append(policy.decide(state: .failed, key: turn, trigger: .uplinkFrame))
        }
        XCTAssertEqual(decisions.filter { $0 == .open }.count, 0)
        XCTAssertEqual(decisions.count, 21)

        let fresh = RealtimeReopenPolicy.TurnKey(
            requestId: "01a017b2-0000-7000-8000-000000000002", sessionId: "sess-c"
        )
        XCTAssertEqual(
            policy.decide(state: .failed, key: fresh, trigger: .streamStart), .open
        )
    }

    // MARK: - ESS-962 阻断 2

    /// **生产顺序**的迟到帧回归：新回合 `.streamStart` → 状态 `.active(new)`
    /// → 旧回合的 `.uplinkFrame`。
    ///
    /// 初版只存一个 `terminalTurn` 且被新回合的 `.streamStart` 清成 nil，
    /// 此后旧 key 的帧既不命中 reuse、也无终态可命中，最终走 `.open`；
    /// 生产路径随即关掉**正在服务新回合**的 transport 去建旧回合的。
    /// 初版那条同名测试用的是 `state: .failed`，根本没走到这个顺序。
    func testLateFrameFromTerminatedTurnCannotSupersedeLiveTurn() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)

        let next = RealtimeReopenPolicy.TurnKey(
            requestId: "01a017b2-0000-7000-8000-000000000001", sessionId: "sess-b"
        )
        XCTAssertEqual(
            policy.decide(state: .failed, key: next, trigger: .streamStart), .open
        )
        // 新回合已在服务，终态记账不得因此失忆。
        XCTAssertTrue(policy.isTerminated(turn))

        var lateDecisions: [RealtimeReopenPolicy.Decision] = []
        for _ in 0..<20 {
            lateDecisions.append(
                policy.decide(state: .active(next), key: turn, trigger: .uplinkFrame)
            )
        }
        XCTAssertEqual(lateDecisions.filter { $0 == .open }.count, 0)
        // 新回合自己的帧不受影响，仍然复用同一个 transport。
        XCTAssertEqual(
            policy.decide(state: .active(next), key: next, trigger: .uplinkFrame),
            .reuseExisting
        )
    }

    /// 从未失败过、但也不是当前回合的外来帧，同样不得顶掉正在服务的 transport
    /// （迟到帧 / WCSession 重排都能造出这个顺序）。
    func testForeignFrameCannotSupersedeLiveTurnEvenWithoutTerminalRecord() {
        var policy = RealtimeReopenPolicy()
        let live = RealtimeReopenPolicy.TurnKey(requestId: "live", sessionId: "sess-live")
        let foreign = RealtimeReopenPolicy.TurnKey(requestId: "old", sessionId: "sess-old")

        XCTAssertEqual(
            policy.decide(state: .active(live), key: foreign, trigger: .uplinkFrame),
            .suppress(reason: RealtimeReopenPolicy.SuppressReason.foreignTurnLive)
        )
        XCTAssertEqual(
            policy.decide(state: .connecting(live), key: foreign, trigger: .uplinkFrame),
            .suppress(reason: RealtimeReopenPolicy.SuppressReason.foreignTurnLive)
        )
        // 真正的新回合带着自己的 stream.start 来，照常放行。
        XCTAssertEqual(
            policy.decide(state: .active(live), key: foreign, trigger: .streamStart), .open
        )
    }

    /// 终态集合有界，且淘汰不是静默的——超出上限时 `evictedTerminalCount`
    /// 必须记账，好让日志里能看出「更早的回合已不受保护」。
    func testTerminalHistoryIsBoundedAndEvictionIsCounted() {
        var policy = RealtimeReopenPolicy()
        let limit = RealtimeReopenPolicy.terminalHistoryLimit
        let keys = (0..<(limit + 2)).map {
            RealtimeReopenPolicy.TurnKey(requestId: "req-\($0)", sessionId: "sess-\($0)")
        }
        keys.forEach { policy.markTerminalFailure($0) }

        XCTAssertEqual(policy.terminalTurns.count, limit)
        XCTAssertEqual(policy.evictedTerminalCount, 2)
        XCTAssertFalse(policy.isTerminated(keys[0]))
        XCTAssertTrue(policy.isTerminated(keys[limit + 1]))
    }

    // MARK: - 原有行为不得回归

    /// 正常回合：`.active` / `.connecting` 上的同 id 帧一律复用，不建新 transport。
    func testActiveAndConnectingTurnsReuseExistingTransport() {
        var policy = RealtimeReopenPolicy()
        XCTAssertEqual(
            policy.decide(state: .active(turn), key: turn, trigger: .uplinkFrame),
            .reuseExisting
        )
        XCTAssertEqual(
            policy.decide(state: .connecting(turn), key: turn, trigger: .uplinkFrame),
            .reuseExisting
        )
        XCTAssertEqual(policy.suppressedCount, 0)
    }

    /// 从未失败过的回合：首帧照常放行（懒开链路不受影响）。
    func testHealthyTurnStillOpensLazily() {
        var policy = RealtimeReopenPolicy()
        XCTAssertEqual(
            policy.decide(state: .idle, key: turn, trigger: .streamStart), .open
        )
        XCTAssertEqual(
            policy.decide(state: .idle, key: turn, trigger: .uplinkFrame), .open
        )
    }

    /// 换会话（同 requestId、不同 sessionId）不算同一个回合。
    func testTurnKeyIsRequestAndSessionPair() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)
        let sameRequestNewSession = RealtimeReopenPolicy.TurnKey(
            requestId: turn.requestId, sessionId: "sess-z"
        )
        XCTAssertEqual(
            policy.decide(state: .failed, key: sameRequestNewSession, trigger: .uplinkFrame),
            .open
        )
    }

    // MARK: - 验收标准 4（线格式）

    /// 通道终态信号必须能原样过 WCSession 的 JSON 编解码。
    func testChannelFailedEnvelopeRoundTrips() throws {
        let failed = RealtimeChannelFailed(
            requestId: turn.requestId, sessionId: turn.sessionId,
            reason: "gateway_error_ERR_STREAM_SEQUENCE"
        )
        let data = try JSONEncoder().encode(failed)
        XCTAssertEqual(try JSONDecoder().decode(RealtimeChannelFailed.self, from: data), failed)
        XCTAssertEqual(
            RealtimeMediaMessage.channelFailedEnvelopeKey,
            "wristagent_realtime_channel_failed"
        )
        XCTAssertNotEqual(
            RealtimeMediaMessage.channelFailedEnvelopeKey,
            RealtimeMediaMessage.channelReadyEnvelopeKey
        )
    }
}
