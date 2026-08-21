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
            decisions.filter { $0 == .suppress(reason: "turn_terminated") }.count, 20
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
                .suppress(reason: "turn_terminated")
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
            .suppress(reason: "turn_terminated")
        )

        let nextTurn = RealtimeReopenPolicy.TurnKey(
            requestId: "01a017b2-0000-7000-8000-000000000001", sessionId: "sess-b"
        )
        XCTAssertEqual(
            policy.decide(state: .failed, key: nextTurn, trigger: .streamStart), .open
        )
        XCTAssertNil(policy.terminalTurn)
        XCTAssertEqual(policy.suppressedCount, 0)
    }

    /// 同一个回合被新的 `stream.start` 显式重启也放行——它每回合恰好一次，
    /// 做不出帧节奏的风暴，且这是失败之后唯一的复原路径。
    func testStreamStartIsTheOnlyReopenRoute() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)
        XCTAssertEqual(
            policy.decide(state: .failed, key: turn, trigger: .streamStart), .open
        )
        XCTAssertNil(policy.terminalTurn)
    }

    /// 被新回合顶掉之后，**旧**回合的迟到帧仍然不得复活：
    /// `terminalTurn` 只由 `stream.start` 清，不由「别的 key 开了」清。
    func testLateFramesFromSupersededTurnStaySuppressed() {
        var policy = RealtimeReopenPolicy()
        policy.markTerminalFailure(turn)
        let other = RealtimeReopenPolicy.TurnKey(requestId: "other", sessionId: "sess-b")
        XCTAssertEqual(
            policy.decide(state: .failed, key: other, trigger: .uplinkFrame), .open
        )
        XCTAssertEqual(
            policy.decide(state: .failed, key: turn, trigger: .uplinkFrame),
            .suppress(reason: "turn_terminated")
        )
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
