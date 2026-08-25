import XCTest
@testable import WristAgentCore

/// ESS-1111 验收 1 的**纯逻辑**那一半：展示分类、答案流的去重/保序/截断，
/// 以及回合聚合体在断线-重连下保留 task identity 的行为。会话层的时序
/// （活动续期、24s 夹具、代际闸门）在 `WatchTests/Ess1111LongTaskSessionTests.swift`。
///
/// 断言一律落在「用户会看到什么」与「回合能不能收口」上，而不是内部字段——
/// ESS-1109 的故障现象就是这两样说了谎。
final class Ess1111LongTaskStreamTests: XCTestCase {

    // MARK: - 展示分类（验收 1：queued/running/reasoning/tool/result/answer）

    func testEveryDocumentedCategoryProjectsToItsOwnKind() {
        XCTAssertEqual(LongTaskActivityKind(category: "queued"), .queued)
        XCTAssertEqual(LongTaskActivityKind(category: "running"), .running)
        XCTAssertEqual(LongTaskActivityKind(category: "reasoning"), .reasoning)
        XCTAssertEqual(LongTaskActivityKind(category: "plan"), .reasoning)
        XCTAssertEqual(LongTaskActivityKind(category: "search"), .tool)
        XCTAssertEqual(LongTaskActivityKind(category: "read"), .tool)
        XCTAssertEqual(LongTaskActivityKind(category: "image"), .tool)
        XCTAssertEqual(LongTaskActivityKind(category: "finalizing"), .result)
        XCTAssertEqual(LongTaskActivityKind(category: "answer"), .answer)
    }

    /// 类目缺席（老网关只发 `task_status`）时退到状态，而不是丢掉这一帧。
    func testStatusIsUsedWhenCategoryIsAbsent() {
        XCTAssertEqual(LongTaskActivityKind(category: nil, status: "queued"), .queued)
        XCTAssertEqual(LongTaskActivityKind(category: "", status: "running"), .running)
        XCTAssertEqual(LongTaskActivityKind(category: nil, status: "finalizing"), .result)
    }

    /// 向前兼容：没见过的类目**照常展示**（降级为 `.other`），不丢帧、不抛错。
    /// 把未知类目当错误处理，等于每次协议演进都让手表的进展展示整个消失。
    func testUnknownCategoryDegradesToOtherAndStaysDisplayable() {
        let kind = LongTaskActivityKind(category: "sandbox_exec", status: "running")
        XCTAssertEqual(kind, .other("sandbox_exec"))
        XCTAssertEqual(kind.logName, "other:sandbox_exec")
        XCTAssertEqual(kind.statusFallbackText, ToolProgressNarration.fallbackText,
                       "认不出来也要有一句稳定的话，不能空屏")
        XCTAssertFalse(kind.isAnswerStream)
    }

    /// 两个字段都缺席时按 `.running` —— `task.state` 能到达本身就证明有任务在跑。
    func testFullyAbsentMetadataFallsBackToRunning() {
        XCTAssertEqual(LongTaskActivityKind(category: nil, status: nil), .running)
    }

    /// 不伪造：手表不知道模型在想什么、也不知道调的哪个工具，兜底一律是通用
    /// 的「正在处理」；只有纯生命周期类目才给具体说法。
    func testFallbackCopyNeverFabricatesReasoningOrToolDetail() {
        XCTAssertEqual(LongTaskActivityKind.queued.statusFallbackText, "正在排队")
        XCTAssertEqual(LongTaskActivityKind.result.statusFallbackText, "正在整理结果")
        XCTAssertEqual(LongTaskActivityKind.reasoning.statusFallbackText,
                       ToolProgressNarration.fallbackText)
        XCTAssertEqual(LongTaskActivityKind.tool.statusFallbackText,
                       ToolProgressNarration.fallbackText)
        XCTAssertNil(LongTaskActivityKind.answer.statusFallbackText,
                     "一条没有文字的「答案增量」什么都不是")
    }

    // MARK: - 答案流：增量、去重、保序

    func testAnswerDeltasAccumulateInOrder() {
        var transcript = LongTaskAnswerTranscript()

        XCTAssertEqual(transcript.apply(sequence: 1, delta: "上海明天"), .appended)
        XCTAssertEqual(transcript.apply(sequence: 2, delta: "多云转晴，"), .appended)
        XCTAssertEqual(transcript.apply(sequence: 3, delta: "最高 28 度。"), .appended)

        XCTAssertEqual(transcript.retainedText, "上海明天多云转晴，最高 28 度。")
        XCTAssertEqual(transcript.displayText, "上海明天多云转晴，最高 28 度。")
        XCTAssertEqual(transcript.appliedCount, 3)
        XCTAssertEqual(transcript.droppedCount, 0)
    }

    func testDuplicateAndOutOfOrderAnswerDeltasAreDropped() {
        var transcript = LongTaskAnswerTranscript()
        transcript.apply(sequence: 5, delta: "第一片")
        transcript.apply(sequence: 6, delta: "第二片")

        XCTAssertEqual(transcript.apply(sequence: 6, delta: "第二片"), .duplicate)
        XCTAssertEqual(transcript.apply(sequence: 4, delta: "迟到的旧片"), .outOfOrder)

        XCTAssertEqual(transcript.retainedText, "第一片第二片",
                       "重复与迟到都不得改写已经渲染出去的答案")
        XCTAssertEqual(transcript.droppedCount, 2)
    }

    /// 老网关不带 `progress_seq`：照常应用，不推进序号闸门。把没带号的帧一律
    /// 丢掉，等于滚动升级窗口内答案流整个消失。
    func testUnnumberedAnswerDeltasStillApply() {
        var transcript = LongTaskAnswerTranscript()
        XCTAssertEqual(transcript.apply(sequence: nil, delta: "甲"), .appended)
        XCTAssertEqual(transcript.apply(sequence: nil, delta: "乙"), .appended)
        XCTAssertEqual(transcript.retainedText, "甲乙")
        XCTAssertNil(transcript.latestSequence)
    }

    func testWhitespaceOnlyDeltaIsDroppedAsEmpty() {
        var transcript = LongTaskAnswerTranscript()
        XCTAssertEqual(transcript.apply(sequence: 1, delta: "   \n "), .empty)
        XCTAssertEqual(transcript.apply(sequence: 2, delta: nil), .empty)
        XCTAssertFalse(transcript.hasAnswer)
    }

    /// 英文答案的分词全靠增量之间那一个前导空格：trim 掉就会把
    /// "hello" + " world" 粘成 "helloworld"。
    func testLeadingSpaceInsideADeltaIsPreserved() {
        var transcript = LongTaskAnswerTranscript()
        transcript.apply(sequence: 1, delta: "hello")
        transcript.apply(sequence: 2, delta: " world")
        XCTAssertEqual(transcript.retainedText, "hello world")
    }

    /// 上游改用**全量快照**口径重发时必须收敛到同一结果，而不是把答案重复一遍。
    func testCumulativeSnapshotReplacesInsteadOfDuplicating() {
        var transcript = LongTaskAnswerTranscript()
        transcript.apply(sequence: 1, delta: "上海明天")
        transcript.apply(sequence: 2, delta: "多云转晴")

        XCTAssertEqual(transcript.apply(sequence: 3, delta: "上海明天多云转晴，最高 28 度。"),
                       .replaced)
        XCTAssertEqual(transcript.retainedText, "上海明天多云转晴，最高 28 度。")
    }

    /// 一段与已收内容**无关**的长文本不是快照，必须按增量追加。
    func testLongUnrelatedDeltaIsNotMistakenForASnapshot() {
        var transcript = LongTaskAnswerTranscript()
        transcript.apply(sequence: 1, delta: "甲")
        XCTAssertEqual(transcript.apply(sequence: 2, delta: "乙丙丁戊己庚辛"), .appended)
        XCTAssertEqual(transcript.retainedText, "甲乙丙丁戊己庚辛")
    }

    /// 反例护栏：一串**等长且同头**的增量（重复短语、列表项）绝不能被误判成
    /// 全量快照 —— 误判一次就把前面所有内容整段抹掉。
    func testRepeatedEqualLengthDeltasAreNeverTreatedAsSnapshots() {
        var transcript = LongTaskAnswerTranscript()
        for seq in 1...4 {
            XCTAssertEqual(transcript.apply(sequence: seq, delta: "第一项：好"), .appended)
        }
        XCTAssertEqual(transcript.receivedCharacterCount, 20)
        XCTAssertEqual(transcript.retainedText, String(repeating: "第一项：好", count: 4))
    }

    // MARK: - 长文本：长度上限与尾窗滚动（验收：不阻塞音频线程）

    func testRetainedTextIsCappedAndScrollsFromTheHead() {
        var transcript = LongTaskAnswerTranscript()
        let piece = String(repeating: "字", count: 50)
        for seq in 1...10 { transcript.apply(sequence: seq, delta: piece) }

        XCTAssertEqual(transcript.receivedCharacterCount, 500)
        XCTAssertEqual(transcript.retainedText.count,
                       LongTaskAnswerTranscript.maxRetainedCharacters,
                       "保留量必须钉死在常数，长答案不得在手表上无界增长")
        XCTAssertTrue(transcript.didTrim)
    }

    func testDisplayTextIsBoundedToTheTailWindow() {
        var transcript = LongTaskAnswerTranscript()
        transcript.apply(sequence: 1, delta: String(repeating: "甲", count: 200))

        let display = try! XCTUnwrap(transcript.displayText)
        XCTAssertEqual(display.count, LongTaskAnswerTranscript.displayWindowCharacters + 1,
                       "尾窗 + 一个前导省略号")
        XCTAssertTrue(display.hasPrefix("…"), "前面还有内容这件事必须在屏幕上可见")
    }

    func testShortAnswerIsRenderedWholeWithoutEllipsis() {
        var transcript = LongTaskAnswerTranscript()
        transcript.apply(sequence: 1, delta: "好的")
        XCTAssertEqual(transcript.displayText, "好的")
    }

    /// 截断之后全量快照判据依然成立 —— 判据只读定长的头部指纹。
    func testSnapshotDetectionSurvivesTrimming() {
        var transcript = LongTaskAnswerTranscript()
        let head = "开头这段话很有辨识度"
        transcript.apply(sequence: 1, delta: head)
        transcript.apply(sequence: 2, delta: String(repeating: "尾", count: 300))
        XCTAssertTrue(transcript.didTrim)

        let snapshot = head + String(repeating: "尾", count: 320) + "收尾一句。"
        XCTAssertEqual(transcript.apply(sequence: 3, delta: snapshot), .replaced)
        XCTAssertEqual(transcript.receivedCharacterCount, snapshot.count)
        XCTAssertTrue(transcript.retainedText.hasSuffix("收尾一句。"))
    }

    func testClearDropsEverythingIncludingTheFingerprint() {
        var transcript = LongTaskAnswerTranscript()
        transcript.apply(sequence: 9, delta: "上一轮的答案")
        transcript.clear()

        XCTAssertFalse(transcript.hasAnswer)
        XCTAssertNil(transcript.displayText)
        XCTAssertNil(transcript.latestSequence)
        XCTAssertEqual(transcript.apply(sequence: 1, delta: "新一轮"), .appended)
        XCTAssertEqual(transcript.retainedText, "新一轮",
                       "上一轮的答案不得挂到新一轮头上")
    }

    // MARK: - 断线重连：task identity 必须活过断线（验收 1 / 实现要求 4）

    func testInterruptionRetainsTaskIdentityAndBlocksClosure() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "work_a8f61916", status: .running))

        agg.apply(.downlinkInterrupted(reason: "wcsession_unreachable"))

        XCTAssertEqual(agg.outstandingTasks, ["work_a8f61916"],
                       "断线不等于任务结束：identity 必须原样保留")
        XCTAssertTrue(agg.awaitingReconnect)
        XCTAssertTrue(agg.holdReasons.contains(.awaitingReconnect))
        XCTAssertFalse(agg.isClosed)
        XCTAssertEqual(agg.phase, .thinking, "断线期间不得回到「正在听」")
        XCTAssertTrue(agg.blocksAutomaticNextTurn, "更不得开下一轮")
    }

    /// 断线**之后**才落定的屏障不足以让回合收口 —— 重连之前始终挂着。
    func testBarrierAloneCannotCloseAnInterruptedTurn() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: .completed))
        agg.apply(.audioDoneBarrier)
        XCTAssertTrue(agg.isClosed, "正常路径此时就该收口")

        var interrupted = ToolTurnAggregate()
        interrupted.apply(.taskState(taskId: "t1", status: .running))
        interrupted.apply(.downlinkInterrupted(reason: "socket_1006"))
        interrupted.apply(.taskState(taskId: "t1", status: .completed))
        interrupted.apply(.audioDoneBarrier)

        XCTAssertFalse(interrupted.isClosed)
        XCTAssertEqual(interrupted.holdReasons, [.awaitingReconnect])
    }

    func testResumeClearsTheHoldAndLetsTheTurnFinishNormally() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.downlinkInterrupted(reason: "socket_1006"))

        agg.apply(.downlinkResumed)
        XCTAssertFalse(agg.awaitingReconnect)
        XCTAssertEqual(agg.resumeCount, 1)
        XCTAssertEqual(agg.interruptCount, 1)

        // 重连后同一个 task 继续把答案送完。
        agg.apply(.taskState(taskId: "t1", status: .completed))
        agg.apply(.audioDoneBarrier)
        agg.apply(.playbackStarted)
        agg.apply(.playbackEnded)

        XCTAssertTrue(agg.isClosed)
        XCTAssertEqual(agg.phase, .listening)
    }

    /// 通道**真的**关了（不是抖一下）时，旧语义一个字不变：放弃等待，收口。
    func testHardCloseStillAbandonsEverythingEvenAfterAnInterruption() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.downlinkInterrupted(reason: "socket_1006"))

        agg.apply(.downlinkClosed(reason: "resume_timeout"))

        XCTAssertFalse(agg.awaitingReconnect)
        XCTAssertTrue(agg.outstandingTasks.isEmpty)
        XCTAssertTrue(agg.isClosed)
        XCTAssertEqual(agg.downlinkClosedReason, "resume_timeout")
    }

    func testResumeWithoutAPriorInterruptionIsANoOp() {
        var agg = ToolTurnAggregate()
        agg.apply(.taskState(taskId: "t1", status: .running))
        agg.apply(.downlinkResumed)
        XCTAssertEqual(agg.resumeCount, 0)
        XCTAssertFalse(agg.awaitingReconnect)
    }

    // MARK: - 活动记账与失败终态

    /// 24s 长任务的真机形状：每秒一帧重复的 `running`。它们**每一帧都算活动**——
    /// 会话层的静默预算正是靠这个计数把「上游在说话」与「上游死了」分开。
    func testRepeatedRunningFramesAllCountAsActivity() {
        var agg = ToolTurnAggregate()
        for _ in 0..<24 {
            agg.apply(.taskState(taskId: "work_a8f61916", status: .running))
        }
        XCTAssertEqual(agg.activityFrameCount, 24)
        XCTAssertEqual(agg.outstandingTasks.count, 1, "重复的 running 不得累加")
        XCTAssertTrue(agg.hasOutstandingWork)
    }

    func testFailureTerminalStatusesAreDistinguishedFromCompletion() {
        XCTAssertFalse(ToolTaskStatus.completed.isFailureTerminal)
        XCTAssertTrue(ToolTaskStatus.failed.isFailureTerminal)
        XCTAssertTrue(ToolTaskStatus.cancelled.isFailureTerminal)
        XCTAssertTrue(ToolTaskStatus.timedOut.isFailureTerminal)
        XCTAssertFalse(ToolTaskStatus.running.isFailureTerminal)
        XCTAssertFalse(ToolTaskStatus.unknown("sandboxing").isFailureTerminal,
                       "没见过的状态一律按非终态：当成终态正是 ESS-1097 修的那个 bug")

        XCTAssertNotNil(ToolTaskStatus.failed.failureNoticeText)
        XCTAssertNotNil(ToolTaskStatus.cancelled.failureNoticeText)
        XCTAssertNil(ToolTaskStatus.completed.failureNoticeText)
    }

    // MARK: - 线格向前兼容（实现要求 1）

    /// 网关新增的字段不得让整条下行报废 —— ESS-971 的教训是丢掉整帧，
    /// 而不是忽略一个字段。
    func testUnknownWireFieldsDoNotBreakTaskStateDecoding() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "protocol_version": RealtimeWireVersion.downlink,
            "kind": "task.state",
            "request_id": "req-1111",
            "session_id": "sess-1111",
            "task_id": "work_a8f61916",
            "task_status": "running",
            "progress_seq": 7,
            "progress_text": "正在查询相关信息",
            "progress_category": "search",
            "generation": 3,
            // 本客户端还不认识的字段（ESS-1110 / ESS-1112 后续演进）。
            "progress_kind": "reasoning",
            "task_elapsed_ms": 12107,
            "activity": ["a", "b"],
        ])

        let envelope = try JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: json)

        XCTAssertEqual(envelope.kind, .taskState)
        XCTAssertEqual(envelope.taskStatus, "running")
        XCTAssertEqual(envelope.progressSequence, 7)
        XCTAssertEqual(envelope.progressCategory, "search")
        XCTAssertEqual(envelope.generation, 3, "代际必须一路带到客户端")
    }
}
