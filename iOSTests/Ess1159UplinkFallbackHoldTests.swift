import XCTest
@testable import WristAgent

/// ESS-1159：一条 `stream.fallback` 不得关掉上游还在干活的 WSS。
///
/// 事故（2026-09-05 最新真机复测，两条委派用例全部无最终语音）：
///   • 天气：task `work_9e37b3be-…`，Watch **12.157s** 断开，Codex 22.272s 完成；
///   • 知识库：task `work_11ecbeaf-…`，Watch **12.4s** 断开，Codex 18.985s 完成。
/// 服务端两条都记 `task.stream.frame_dropped reason=socket_closed`。
///
/// `PhoneRealtimeSession.forward` 的 `.fallback` 分支是 ESS-1139 那道判定
/// **唯一被写死绕开**的入口：它固定用 `cause: .transportFailure`，而该动因
/// `overridesInFlightUpstreamWork == true`，于是无论账本上挂着多少未结任务，
/// 一条 `stream.fallback` 都当场 `close`。而 `stream.fallback` 的全部来源都在
/// Watch 自己那一侧（`RealtimeUplinkStream.FallbackReason`：录音器故障、
/// WCSession 送不出去、没采到音频、上行背压、本轮取消）——说的是
/// **Watch↔iPhone** 那一跳，不是 iPhone↔网关这条 WSS。
///
/// 这个缺陷在 `Shared/` 的纯策略用例里结构上看不见：策略从没被问过。
/// 因此本套件驱动 `PhoneRealtimeSession` 本体，断言 hold 之后 transport 引用、
/// 会话状态与下行能力三者原样保留，且最终答案仍然恰好送达一次。
@MainActor
final class Ess1159UplinkFallbackHoldTests: XCTestCase {

    private static let requestId = "01a0392b-c9ea-7c1a-a265-4688ba0cd894"
    private static let sessionId = "B4C6D281-550C-4679-8FB3-685831B223BC"
    private static let taskId = "work_9e37b3be-6764-4840-90a6-8e1813075509"

    /// 真机上 Watch 断开的时刻（天气回合）。
    private static let incidentMs: Int64 = 12_157
    /// 真机上 Codex 完成的时刻（天气回合）。
    private static let taskCompletedMs: Int64 = 22_272

    // MARK: - 事故正面复现

    /// **阻断正面复现**：12.157s 的一条 `stream.fallback`，任务仍在 running。
    /// socket 不得关闭，会话状态与 transport 引用原样保留；随后的最终答案与
    /// 回合终态照常送达，恰好一次；上游真的说完之后才补上那次被推迟的关闭。
    func testUplinkFallbackAtTwelveSecondsHoldsSocketAndStillDeliversFinalAnswer() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }

        var forwarded = false
        h.session.forward(.fallback(RealtimeUplinkFallbackDescriptor(
            requestId: Self.requestId, sessionId: Self.sessionId, reason: "transportFailed"
        ))) { forwarded = $0 }

        // 上行回退本身照常被接受（完整文件回退走的是另一条链路）。
        XCTAssertTrue(forwarded, "上行回退的语义不得因为 socket 被保住而改变")
        // hold 的三条不变量。
        XCTAssertTrue(h.transport.closeReasons.isEmpty,
                      "任务仍在 running ⇒ 一条 stream.fallback 不得关掉这条 WSS")
        XCTAssertEqual(h.session.state,
                       .active(requestId: Self.requestId, sessionId: Self.sessionId),
                       "会话状态必须原样保留——转成 .failed 等于第二道身份闸门自杀")
        XCTAssertTrue(h.session.hasCurrentTransportForTesting,
                      "transport 引用必须原样保留——丢了它所有下行回调都被拒")

        // 上游继续干活：22.272s 任务终态，随后最终答案的回合终态。
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: Self.taskCompletedMs
        )
        h.session.nowMs = { Self.taskCompletedMs }
        h.session.receiveAgentDownlink(
            .taskState(requestId: Self.requestId, sessionId: Self.sessionId,
                       taskId: Self.taskId, status: "completed",
                       answer: AgentTaskAnswerDelta(
                           sequence: 1, delta: "杭州当前气温约 26℃，多云。")),
            from: h.transport
        )
        XCTAssertTrue(h.transport.closeReasons.isEmpty,
                      "任务终态与最终答案之间不得收口——那正好把答案切掉")

        h.transport.upstreamWorkLedger.noteTurnTerminal(atMs: Self.taskCompletedMs + 500)
        h.session.nowMs = { Self.taskCompletedMs + 500 }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 94, upstreamWorkOutstanding: false),
            from: h.transport
        )

        XCTAssertEqual(h.delivered.map(\.kind), [.taskState, .audioDone],
                       "最终答案与回合终态必须按序、恰好各送达一次")
        XCTAssertEqual(h.delivered.first?.answerDelta, "杭州当前气温约 26℃，多云。")
        XCTAssertEqual(h.delivered.last?.finalSequence, 94)
        XCTAssertEqual(h.transport.closeReasons, ["transportFailed"],
                       "上游终态之后才补上那次被推迟的关闭，且只关一次")
        XCTAssertEqual(h.session.state, .failed(reason: "transportFailed"))
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    /// 超过 30 秒的知识库回合：上游每 5s 一帧活动，`stream.fallback` 在
    /// 12.4s 与 31s 各来一次都必须被拦下，socket 全程存活。
    func testRepeatedUplinkFallbackAcrossThirtySecondsNeverClosesTheSocket() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )

        for atMs in stride(from: Int64(5_000), through: 35_000, by: 5_000) {
            h.transport.upstreamWorkLedger.noteTaskState(
                taskId: Self.taskId, status: "running", atMs: atMs
            )
        }
        for atMs in [Int64(12_400), 31_000, 35_100] {
            h.session.nowMs = { atMs }
            h.session.forward(.fallback(RealtimeUplinkFallbackDescriptor(
                requestId: Self.requestId, sessionId: Self.sessionId, reason: "cancelled"
            )))
            XCTAssertTrue(h.transport.closeReasons.isEmpty,
                          "\(atMs)ms：上游还在说话，socket 不得关闭")
            XCTAssertTrue(h.session.hasCurrentTransportForTesting)
        }
        // 重复的回退不得把重试计时器叠起来。
        XCTAssertEqual(h.pendingRetries.count, 1, "任何时刻至多一支重试计时器在跑")
    }

    // MARK: - 主链路不受影响

    /// 没有在飞任务时，`stream.fallback` 的行为与本单之前逐字相同：
    /// 当场关闭、状态转 `.failed`、清 transport 引用。
    func testUplinkFallbackWithoutUpstreamWorkStillTearsDownImmediately() {
        let h = makeActiveSession()
        h.session.nowMs = { 1_000 }

        var forwarded = false
        h.session.forward(.fallback(RealtimeUplinkFallbackDescriptor(
            requestId: Self.requestId, sessionId: Self.sessionId, reason: "noAudioFrames"
        ))) { forwarded = $0 }

        XCTAssertTrue(forwarded)
        XCTAssertEqual(h.transport.closeReasons, ["noAudioFrames"])
        XCTAssertEqual(h.session.state, .failed(reason: "noAudioFrames"))
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    /// 被推迟的关闭仍然有界：上游从此静默，重试计时器到点必须真的收口。
    func testDeferredUplinkFallbackIsReleasedByTheRetryTimer() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }
        h.session.forward(.fallback(RealtimeUplinkFallbackDescriptor(
            requestId: Self.requestId, sessionId: Self.sessionId, reason: "backpressure"
        )))
        XCTAssertTrue(h.transport.closeReasons.isEmpty)
        XCTAssertEqual(h.pendingRetries.count, 1, "hold 必须武装一支重试计时器")

        h.session.nowMs = { Self.incidentMs + RealtimeSocketLifetimePolicy.upstreamSilenceBudgetMs }
        h.firePendingRetries()

        XCTAssertEqual(h.transport.closeReasons, ["backpressure"])
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    // MARK: - 夹具

    private struct Harness {
        let session: PhoneRealtimeSession
        let transport: FakeTransport
        private let box: Box

        final class Box {
            var delivered: [RealtimeDownlinkEnvelope] = []
            var pendingRetries: [@MainActor () -> Void] = []
        }

        init(session: PhoneRealtimeSession, transport: FakeTransport, box: Box) {
            self.session = session
            self.transport = transport
            self.box = box
        }

        var delivered: [RealtimeDownlinkEnvelope] { box.delivered }
        var pendingRetries: [@MainActor () -> Void] { box.pendingRetries }

        @MainActor
        func firePendingRetries() {
            let due = box.pendingRetries
            box.pendingRetries.removeAll()
            for fire in due { fire() }
        }
    }

    private func makeActiveSession() -> Harness {
        let transport = FakeTransport()
        let box = Harness.Box()
        let session = PhoneRealtimeSession(transportFactory: { requestId, _ in
            requestId == Self.requestId ? transport : FakeTransport()
        })
        session.isAgentTransport = true
        session.onDownlink = { envelope in
            box.delivered.append(envelope)
            return .handled
        }
        session.scheduleDeferredCloseRetry = { _, fire in box.pendingRetries.append(fire) }

        session.forward(.start(RealtimeStreamStart(
            requestId: Self.requestId, sessionId: Self.sessionId,
            format: .uplinkPCM16, capturedAtMs: 0
        )))
        session.agentTransportDidChangeState(
            .active(requestId: Self.requestId, sessionId: Self.sessionId), from: transport
        )
        XCTAssertEqual(session.state,
                       .active(requestId: Self.requestId, sessionId: Self.sessionId),
                       "夹具前提：会话已经在服务这一轮")
        return Harness(session: session, transport: transport, box: box)
    }
}

/// 会话层测试替身。只做两件事：如实记账本、如实记 close 调用。
@MainActor
private final class FakeTransport: PhoneRealtimeSession.Transport {
    var upstreamWorkLedger = UpstreamWorkLedger()
    private(set) var closeReasons: [String] = []

    func send(_ envelope: RealtimeUplinkEnvelope, completion: @escaping @MainActor (Error?) -> Void) {
        completion(nil)
    }

    func receive(handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void) {}

    func close(reason: String) {
        closeReasons.append(reason)
    }
}
