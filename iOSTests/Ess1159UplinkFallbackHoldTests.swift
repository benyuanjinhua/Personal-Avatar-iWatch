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

    /// 与 `WatchVoiceTransport.fallbackToCompleteFile` **逐字同构**的构造路径：
    /// 同一个 `FallbackReason`、同一个 `reason` 字符串、同一个 `wireKind`。
    /// 复审要求的「生产链路测试」就落在这里——测试不自己捏 `kind`，它和真机
    /// 走同一条映射。
    private static func fallback(
        _ reason: RealtimeUplinkStream.FallbackReason
    ) -> RealtimeUplinkEnvelope {
        .fallback(RealtimeUplinkFallbackDescriptor(
            requestId: requestId, sessionId: sessionId,
            reason: "\(reason)", kind: reason.wireKind
        ))
    }

    private static func playbackStarted(_ responseId: String) -> RealtimeUplinkEnvelope {
        .playbackStarted(RealtimePlaybackReceipt(
            requestId: requestId, sessionId: sessionId,
            responseId: responseId, bytesPlayed: nil
        ))
    }

    private static func playbackEnded(_ responseId: String) -> RealtimeUplinkEnvelope {
        .playbackEnded(RealtimePlaybackReceipt(
            requestId: requestId, sessionId: sessionId,
            responseId: responseId, bytesPlayed: 176_256
        ))
    }

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
        h.session.forward(Self.fallback(.transportFailed)) { forwarded = $0 }

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

        // 最终答案开始播：Watch 回执 `playback.started`。
        h.session.forward(Self.playbackStarted("resp-final"))

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
        // 复审阻断 1：终态到了也**还不能关**——播放队列还没排空。
        XCTAssertTrue(h.transport.closeReasons.isEmpty,
                      "audio.done 不是收口的充分条件：播放还没放完")

        // 播完了，三条件齐全，这才收口。
        h.session.forward(Self.playbackEnded("resp-final"))
        XCTAssertEqual(h.transport.closeReasons, ["transportFailed"],
                       "播放排空之后才补上那次被推迟的关闭，且只关一次")
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
            h.session.forward(Self.fallback(.backpressure))
            XCTAssertTrue(h.transport.closeReasons.isEmpty,
                          "\(atMs)ms：上游还在说话，socket 不得关闭")
            XCTAssertTrue(h.session.hasCurrentTransportForTesting)
        }
        // 重复的回退不得把重试计时器叠起来。
        XCTAssertEqual(h.pendingRetries.count, 1, "任何时刻至多一支重试计时器在跑")
    }

    // MARK: - 复审阻断 2：取消 / 用户意图必须可抢占

    /// **阻断 2 正面复现**：`.cancelled` 的文档口径是「user cancel / new turn /
    /// lifecycle switch」。任务在飞时，它必须**当场**收口，不能被 hold 到终态 /
    /// 30s 静默 / 180s 上限——那是用「保住答案」劫持用户。
    func testCancelledFallbackWithOutstandingTaskClosesImmediately() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }

        h.session.forward(Self.fallback(.cancelled))

        XCTAssertEqual(h.transport.closeReasons, ["cancelled"],
                       "用户取消 / 新回合 / 生命周期切换必须当场收口")
        XCTAssertEqual(h.session.state, .failed(reason: "cancelled"))
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
        XCTAssertTrue(h.pendingRetries.isEmpty, "当场关掉就不该留下任何待兑现的关闭")
    }

    /// 反面：纯上行故障 + 在飞任务 ⇒ 一律 hold。两条一起看才说明「分开」
    /// 是真的分开了，而不是把所有回退都改成同一种行为。
    func testUplinkFailureFallbacksWithOutstandingTaskAllHold() {
        for reason in [RealtimeUplinkStream.FallbackReason.transportFailed,
                       .backpressure, .sequenceOverflow, .noAudioFrames] {
            let h = makeActiveSession()
            h.transport.upstreamWorkLedger.noteTaskState(
                taskId: Self.taskId, status: "running", atMs: 0
            )
            h.session.nowMs = { Self.incidentMs }

            h.session.forward(Self.fallback(reason))

            XCTAssertTrue(h.transport.closeReasons.isEmpty,
                          "\(reason) 是纯上行故障，任务在飞时不得关闭 WSS")
            XCTAssertEqual(h.session.state,
                           .active(requestId: Self.requestId, sessionId: Self.sessionId))
            XCTAssertTrue(h.session.hasCurrentTransportForTesting)
        }
    }

    /// 归类必须来自**结构化字段**，不是 reason 字符串：一条 `reason` 写着
    /// `"cancelled"` 但 `kind` 是 `uplink_failure` 的帧，判定必须听 `kind`。
    /// 反过来也一样。这条挡的是「将来有人改回字符串解析」。
    func testCauseFollowsStructuredKindNotTheReasonString() {
        let misleadingFailure = RealtimeUplinkFallbackDescriptor(
            requestId: Self.requestId, sessionId: Self.sessionId,
            reason: "cancelled", kind: .uplinkFailure
        )
        XCTAssertEqual(PhoneRealtimeSession.closeCause(for: misleadingFailure), .uplinkFallback)

        let misleadingCancel = RealtimeUplinkFallbackDescriptor(
            requestId: Self.requestId, sessionId: Self.sessionId,
            reason: "transportFailed", kind: .userCancelled
        )
        XCTAssertEqual(PhoneRealtimeSession.closeCause(for: misleadingCancel), .userExit)
        XCTAssertTrue(RealtimeSocketCloseCause.userExit.overridesInFlightUpstreamWork)
    }

    /// 老 Watch 进程（无 `kind`）：退回本单之前的可抢占行为，绝不替一个没说话
    /// 的对端决定「继续持有 socket」——那会把一次用户退出拖上 30 秒。
    func testLegacyDescriptorWithoutKindStaysPreemptive() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }

        h.session.forward(.fallback(RealtimeUplinkFallbackDescriptor(
            requestId: Self.requestId, sessionId: Self.sessionId, reason: "cancelled"
        )))

        XCTAssertEqual(h.transport.closeReasons, ["cancelled"])
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    // MARK: - 复审阻断 1：播放排空屏障

    /// **阻断 1 正面复现**：`playbackStarted → audioDone → playbackEnded`。
    /// 收口必须**晚于**播放排空，不能在 `audio.done` 那一刻就关。
    func testDeferredCloseWaitsForPlaybackDrainAndOrdersAfterIt() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }
        h.session.forward(Self.fallback(.transportFailed))
        XCTAssertTrue(h.transport.closeReasons.isEmpty)

        // 最终答案开始播。
        h.session.forward(Self.playbackStarted("resp-final"))
        XCTAssertEqual(h.session.playbackInFlight, ["resp-final"])

        // 业务终态 + 唯一最终 audio.done 都到了，但播放还没完 ⇒ 仍然不许关。
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: Self.taskCompletedMs
        )
        h.session.nowMs = { Self.taskCompletedMs }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 94, upstreamWorkOutstanding: false),
            from: h.transport
        )
        XCTAssertTrue(h.transport.closeReasons.isEmpty,
                      "三条件缺一条（播放未排空）⇒ 不得收口")
        XCTAssertTrue(h.session.hasCurrentTransportForTesting)
        XCTAssertEqual(h.pendingDrainTimers.count, 1, "必须武装排空上限，且只有一支")
        XCTAssertEqual(h.pendingDrainTimers[0].seconds,
                       PhoneRealtimeSession.deferredClosePlaybackDrainCapSeconds,
                       "播放在跑时用的是排空上限，不是首帧回执宽限")

        // 播完 ⇒ 三条件齐 ⇒ 收口，且只关一次。
        h.session.forward(Self.playbackEnded("resp-final"))
        XCTAssertEqual(h.transport.closeReasons, ["transportFailed"])
        XCTAssertTrue(h.session.playbackInFlight.isEmpty)
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    /// 多段播放：任意一段还在播都不许收口，最后一段排空才行。
    func testDrainBarrierWaitsForEverySegmentNotJustTheFirst() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }
        h.session.forward(Self.fallback(.transportFailed))

        h.session.forward(Self.playbackStarted("resp-a"))
        h.session.forward(Self.playbackStarted("resp-b"))
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: Self.taskCompletedMs
        )
        h.session.nowMs = { Self.taskCompletedMs }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 94, upstreamWorkOutstanding: false),
            from: h.transport
        )

        h.session.forward(Self.playbackEnded("resp-a"))
        XCTAssertTrue(h.transport.closeReasons.isEmpty, "还有一段在播，不得收口")

        h.session.forward(Self.playbackEnded("resp-b"))
        XCTAssertEqual(h.transport.closeReasons, ["transportFailed"])
    }

    /// 这一轮压根没有音频要放：终态到了、首帧回执宽限到点仍无回执 ⇒ 照常收口。
    /// 没有这一条，纯错误终态的回合会白等一个排空上限。
    func testReceiptGraceClosesWhenNoPlaybackEverStarts() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }
        h.session.forward(Self.fallback(.transportFailed))

        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: Self.taskCompletedMs
        )
        h.session.nowMs = { Self.taskCompletedMs }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 3, upstreamWorkOutstanding: false),
            from: h.transport
        )
        XCTAssertTrue(h.transport.closeReasons.isEmpty, "先给首帧回执一点宽限")
        XCTAssertEqual(h.pendingDrainTimers.map(\.seconds),
                       [PhoneRealtimeSession.deferredClosePlaybackReceiptGraceSeconds])

        h.fireDrainTimers()
        XCTAssertEqual(h.transport.closeReasons, ["transportFailed"],
                       "宽限到点一帧回执都没有 ⇒ 这一轮没有音频要放，照常收口")
    }

    /// 终态先到、首帧回执晚到（WCSession 那一跳）：宽限到点时播放已经开始，
    /// 必须**升级**成排空上限继续等，而不是当场把正在开口的答案切掉。
    func testReceiptGracePromotesToDrainCapWhenPlaybackStartsLate() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }
        h.session.forward(Self.fallback(.transportFailed))

        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: Self.taskCompletedMs
        )
        h.session.nowMs = { Self.taskCompletedMs }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 94, upstreamWorkOutstanding: false),
            from: h.transport
        )
        // 回执在宽限窗口里才到。
        h.session.forward(Self.playbackStarted("resp-late"))

        h.fireDrainTimers()
        XCTAssertTrue(h.transport.closeReasons.isEmpty,
                      "宽限到点时播放真的在跑 ⇒ 升级为排空上限，不得收口")
        XCTAssertEqual(h.pendingDrainTimers.map(\.seconds),
                       [PhoneRealtimeSession.deferredClosePlaybackDrainCapSeconds])

        h.session.forward(Self.playbackEnded("resp-late"))
        XCTAssertEqual(h.transport.closeReasons, ["transportFailed"])
    }

    /// **有界性**：`playback.ended` 永远不来（Watch 挂了 / WCSession 断了）时，
    /// 排空上限到点必须真的收口。屏障不得变成一条永远关不掉的 socket。
    func testDrainCapReleasesWhenPlaybackEndedNeverArrives() {
        let h = makeActiveSession()
        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "running", atMs: 0
        )
        h.session.nowMs = { Self.incidentMs }
        h.session.forward(Self.fallback(.transportFailed))
        h.session.forward(Self.playbackStarted("resp-final"))

        h.transport.upstreamWorkLedger.noteTaskState(
            taskId: Self.taskId, status: "completed", atMs: Self.taskCompletedMs
        )
        h.session.nowMs = { Self.taskCompletedMs }
        h.session.receiveAgentDownlink(
            .audioDone(requestId: Self.requestId, sessionId: Self.sessionId,
                       finalSequence: 94, upstreamWorkOutstanding: false),
            from: h.transport
        )
        XCTAssertTrue(h.transport.closeReasons.isEmpty)

        h.fireDrainTimers()   // 排空上限到点，回执始终没来
        XCTAssertEqual(h.transport.closeReasons, ["transportFailed"],
                       "排空上限必须真的兜住，否则 socket 永远关不掉")
        XCTAssertFalse(h.session.hasCurrentTransportForTesting)
    }

    /// 屏障只挡**被推迟**的那次关闭。用户显式退出在播放中途依然当场收口——
    /// 「等播完」不能变成第二种劫持用户的方式。
    func testUserExitStillClosesMidPlayback() {
        let h = makeActiveSession()
        h.session.forward(Self.playbackStarted("resp-final"))
        h.session.nowMs = { Self.incidentMs }

        XCTAssertTrue(h.session.endTurn(reason: "user_exit", cause: .userExit))
        XCTAssertEqual(h.transport.closeReasons, ["user_exit"])
    }

    // MARK: - 主链路不受影响

    /// 没有在飞任务时，`stream.fallback` 的行为与本单之前逐字相同：
    /// 当场关闭、状态转 `.failed`、清 transport 引用。
    func testUplinkFallbackWithoutUpstreamWorkStillTearsDownImmediately() {
        let h = makeActiveSession()
        h.session.nowMs = { 1_000 }

        var forwarded = false
        h.session.forward(Self.fallback(.noAudioFrames)) { forwarded = $0 }

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
        h.session.forward(Self.fallback(.backpressure))
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
            /// ESS-1159 复审整改：播放排空屏障的兜底计时器（宽限 / 排空上限）。
            var pendingDrainTimers: [(seconds: TimeInterval, fire: @MainActor () -> Void)] = []
        }

        init(session: PhoneRealtimeSession, transport: FakeTransport, box: Box) {
            self.session = session
            self.transport = transport
            self.box = box
        }

        var delivered: [RealtimeDownlinkEnvelope] { box.delivered }
        var pendingRetries: [@MainActor () -> Void] { box.pendingRetries }
        var pendingDrainTimers: [(seconds: TimeInterval, fire: @MainActor () -> Void)] {
            box.pendingDrainTimers
        }

        @MainActor
        func firePendingRetries() {
            let due = box.pendingRetries
            box.pendingRetries.removeAll()
            for fire in due { fire() }
        }

        /// 触发当前武装着的排空屏障计时器（触发中新武装的留到下一次）。
        @MainActor
        @discardableResult
        func fireDrainTimers() -> [TimeInterval] {
            let due = box.pendingDrainTimers
            box.pendingDrainTimers.removeAll()
            for entry in due { entry.fire() }
            return due.map(\.seconds)
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
        session.schedulePlaybackDrainCap = { seconds, fire in
            box.pendingDrainTimers.append((seconds, fire))
        }

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
