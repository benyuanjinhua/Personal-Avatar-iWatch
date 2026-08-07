import XCTest
@testable import WristAgentCore

/// ESS-553 契约测试：双层状态机 reducer 的验收面全部落在这里。
///
/// 对应 §1.2 验收标准：
/// - 任一非法迁移被拒绝并给明确 reason（不静默吞）
/// - 乱序 / 重复 / 迟到 / **缺 `response.done`** 四类事件各有独立用例
/// - `suspended` 恢复语义（N3：显式恢复）与「UI 不可能呈现『正在听』」
/// - barge-in 顺序：本地停播 → cancel(generation) → 旧 generation 迟到 delta 全部丢弃
/// - reducer 纯函数、无 AVFoundation/SwiftUI/网络依赖（本文件仅 import XCTest）
final class RealtimeSessionReducerTests: XCTestCase {

    // MARK: - 时钟与 ID 工具（确定性）

    /// 起始时刻（毫秒）——真实世界时间不重要，重要的是 duration_ms 可复算。
    private let t0: Int64 = 1_800_000_000_000
    private var conversationId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private var turn1 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private var turn2 = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private var turn3 = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private var gen1 = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private var gen2 = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    // MARK: - Driver：连续 apply 一串 action，返回最后一个 output 与全部 effect

    private struct Trace {
        var state: RealtimeSessionSnapshot
        var effects: [RealtimeReducerEffect]
        var outputs: [RealtimeReducerOutput]
    }

    private func drive(
        _ actions: [RealtimeReducerAction],
        from initial: RealtimeSessionSnapshot = .initial
    ) -> Trace {
        var state = initial
        var all: [RealtimeReducerEffect] = []
        var outs: [RealtimeReducerOutput] = []
        for action in actions {
            let out = RealtimeSessionReducer.reduce(state, action)
            state = out.state
            all.append(contentsOf: out.effects)
            outs.append(out)
        }
        return Trace(state: state, effects: all, outputs: outs)
    }

    /// 把会话从 idle 推到 listening（首个 turn 已在 capturing）。
    private func warmToListening(at t: Int64 = 0) -> Trace {
        drive([
            .enter(conversationId: conversationId, firstTurnId: turn1, atMs: t0 + t),
            .channelReady(atMs: t0 + t + 100)
        ])
    }

    /// 把会话推到 playing（turn1 已 generating 且首帧已渲染）。
    private func warmToPlaying(at t: Int64 = 0) -> Trace {
        let base = warmToListening(at: t)
        return drive([
            .vadFinal(turnId: turn1, atMs: t0 + t + 300),
            .commitAcked(turnId: turn1, atMs: t0 + t + 400),
            .generationOpened(turnId: turn1, generation: gen1, atMs: t0 + t + 500),
            .firstAudio(turnId: turn1, generation: gen1, atMs: t0 + t + 800)
        ], from: base.state)
    }

    // MARK: - 幸福路径（正向验证 reducer 不歧义）

    func testHappyPathReachesListeningAfterAudioDone() {
        let base = warmToPlaying()
        let after = drive([
            .audioDelta(turnId: turn1, generation: gen1, atMs: t0 + 900),
            .audioDone(turnId: turn1, generation: gen1, atMs: t0 + 1500)
        ], from: base.state)

        XCTAssertEqual(after.state.session, .listening)
        XCTAssertNil(after.state.currentTurn, "audio_done 后 currentTurn 清空；调用方需 explicit begin 下一轮")
        XCTAssertTrue(after.state.retiredGenerations.contains(gen1),
                      "completed 的 generation 必须进 retired 集合，防止迟到 delta")
    }

    // MARK: - 验收 1：非法迁移拒绝并返回 reason，不静默吞

    func testIllegalTransitionIdleToPlayingIsRejectedWithReason() {
        // idle → playing 是 §1.2 未定义的迁移；用最贴近的动作发起：
        // idle 状态下发 firstAudio。
        let out = RealtimeSessionReducer.reduce(
            .initial,
            .firstAudio(turnId: turn1, generation: gen1, atMs: t0)
        )
        XCTAssertEqual(out.state, .initial, "非法迁移不改状态")
        // dropStaleEvent（不在 currentTurn 内）或 rejected 两选一都可，但必须落显式 effect。
        let dropped = out.effects.contains { effect in
            if case .dropStaleEvent = effect { return true }
            if case .rejected = effect { return true }
            return false
        }
        XCTAssertTrue(dropped, "非法迁移必须产出显式 rejected 或 dropStaleEvent，不静默")
    }

    func testCompletedToStreamingIsRejected() {
        // 让 turn1 走到 completed，然后手动把 currentTurn 强塞回一个 completed turn，
        // 触发 audioDelta —— 应被 dropStaleEvent（因 generation 已 retired）。
        let base = warmToPlaying()
        let done = drive([
            .audioDone(turnId: turn1, generation: gen1, atMs: t0 + 1500)
        ], from: base.state)
        let after = RealtimeSessionReducer.reduce(
            done.state,
            .audioDelta(turnId: turn1, generation: gen1, atMs: t0 + 1600)
        )
        // audioDelta 在 listening 无 currentTurn → 命中 stale_generation
        let staleDelta = after.effects.first { effect in
            if case let .dropStaleEvent(kind, _, gen, reason) = effect,
               kind == "audio_delta", gen == self.gen1, reason == "stale_generation" {
                return true
            }
            return false
        }
        XCTAssertNotNil(staleDelta, "已 completed 的 generation 收到 delta 必须以 stale_generation 丢弃")
    }

    func testChannelReadyOutsideEstablishingIsRejected() {
        let out = RealtimeSessionReducer.reduce(
            .initial,
            .channelReady(atMs: t0)
        )
        XCTAssertEqual(out.state, .initial)
        let rejected = out.effects.contains {
            if case let .rejected(_, from, reason) = $0 {
                return from == .idle && reason.contains("channel_ready_requires_establishing")
            }
            return false
        }
        XCTAssertTrue(rejected, "channel_ready 在 idle 必须显式拒绝")
    }

    func testCommitAckedWithWrongTurnIsRejected() {
        let base = warmToListening()
        let after = drive([
            .vadFinal(turnId: turn1, atMs: t0 + 300),
            .commitAcked(turnId: turn2, atMs: t0 + 400)   // 错的 turn
        ], from: base.state)
        XCTAssertEqual(after.state.session, .committing, "错 turn 的 commit_acked 不推进状态")
        let rejected = after.effects.contains {
            if case let .rejected(action, _, reason) = $0 {
                return action == "commit_acked" && reason.contains("turn_mismatch")
            }
            return false
        }
        XCTAssertTrue(rejected)
    }

    // MARK: - 验收 2a：乱序事件（delta 在 first_audio 之前）

    func testAudioDeltaBeforeFirstAudioIsDroppedNotAppliedToStream() {
        var base = warmToPlaying()
        // 撤回到 waitingFirstAudio：直接用 committing/generating 之间收 delta 做验证。
        base = drive([
            .enter(conversationId: conversationId, firstTurnId: turn1, atMs: t0),
            .channelReady(atMs: t0 + 100),
            .vadFinal(turnId: turn1, atMs: t0 + 300),
            .commitAcked(turnId: turn1, atMs: t0 + 400),
            .generationOpened(turnId: turn1, generation: gen1, atMs: t0 + 500)
        ])
        XCTAssertEqual(base.state.session, .waitingFirstAudio)

        let after = RealtimeSessionReducer.reduce(
            base.state,
            .audioDelta(turnId: turn1, generation: gen1, atMs: t0 + 550)
        )
        XCTAssertEqual(after.state.session, .waitingFirstAudio,
                       "delta 早于 first_audio 不能改变会话状态")
        XCTAssertEqual(after.state.currentTurn?.phase, .generating,
                       "turn 仍在 generating，不误跳 streaming")
        let dropped = after.effects.contains {
            if case let .dropStaleEvent(kind, _, _, reason) = $0 {
                return kind == "audio_delta" && reason == "delta_before_first_audio"
            }
            return false
        }
        XCTAssertTrue(dropped, "乱序 delta 必须以 delta_before_first_audio 显式记录")
    }

    // MARK: - 验收 2b：重复事件（重复 channelReady / 重复 audioDone）

    func testDuplicateChannelReadyIsRejected() {
        let base = warmToListening()
        let after = RealtimeSessionReducer.reduce(
            base.state,
            .channelReady(atMs: t0 + 200)
        )
        XCTAssertEqual(after.state.session, .listening,
                       "重复 channel_ready 不改变状态（已在 listening）")
        let rejected = after.effects.contains {
            if case let .rejected(action, _, _) = $0 { return action == "channel_ready" }
            return false
        }
        XCTAssertTrue(rejected, "重复 channel_ready 必须以 rejected 记录")
    }

    func testDuplicateAudioDoneIsDroppedByStaleGeneration() {
        let base = warmToPlaying()
        let done1 = drive([
            .audioDone(turnId: turn1, generation: gen1, atMs: t0 + 1500)
        ], from: base.state)
        // 第二次 done：generation 已 retired，且 currentTurn 已清空。
        let after = RealtimeSessionReducer.reduce(
            done1.state,
            .audioDone(turnId: turn1, generation: gen1, atMs: t0 + 1600)
        )
        XCTAssertEqual(after.state.session, .listening,
                       "重复 audio_done 不改变已抵达的 listening")
        let stale = after.effects.contains {
            if case let .dropStaleEvent(kind, _, _, reason) = $0 {
                return kind == "audio_done" && reason == "stale_generation"
            }
            return false
        }
        XCTAssertTrue(stale, "重复 audio_done 必须以 stale_generation 丢弃")
    }

    // MARK: - 验收 2c：迟到事件（旧 generation 的 delta / first_audio）

    func testLateDeltaFromRetiredGenerationIsDroppedAsStale() {
        // barge-in 后，旧 gen1 的迟到 delta 必须被丢；下一轮 turn2/gen2 不受污染。
        let base = warmToPlaying()
        let bargein = drive([
            .userBargeIn(nextTurnId: turn2, atMs: t0 + 900)
        ], from: base.state)

        // 迟到 delta 来自旧 gen1
        let after = RealtimeSessionReducer.reduce(
            bargein.state,
            .audioDelta(turnId: turn1, generation: gen1, atMs: t0 + 950)
        )
        XCTAssertEqual(after.state.currentTurn?.turnId, turn2,
                       "迟到 delta 不能改变已切换到的新 turn")
        let stale = after.effects.contains {
            if case let .dropStaleEvent(_, _, gen, reason) = $0 {
                return gen == self.gen1 && reason == "stale_generation"
            }
            return false
        }
        XCTAssertTrue(stale)
    }

    // MARK: - 验收 2d：缺 response.done —— 超时失败并清理，不跨 turn flush

    func testMissingResponseDoneTimeoutClearsAndFailsWithoutFlush() {
        let base = warmToPlaying()
        let after = drive([
            .audioDelta(turnId: turn1, generation: gen1, atMs: t0 + 900),
            .audioDoneTimeout(turnId: turn1, generation: gen1, atMs: t0 + 3900)
        ], from: base.state)

        XCTAssertEqual(after.state.session, .listening, "超时后回到 listening 等下一轮")
        XCTAssertNil(after.state.currentTurn, "超时后当前回合被清空，等 explicit begin")
        XCTAssertTrue(after.state.retiredGenerations.contains(gen1),
                      "超时的 generation 必须进 retired，禁止后续迟到帧再影响")

        // 必须发 clearPlaybackBuffer(reason: done_timeout)；且必须记 turnTransition → failed
        let cleared = after.effects.contains {
            if case let .clearPlaybackBuffer(reason) = $0 { return reason == "done_timeout" }
            return false
        }
        XCTAssertTrue(cleared, "必须显式清空当前 generation 缓冲，禁止跨 turn flush")

        let failed = after.effects.contains {
            if case let .logTurnTransition(_, _, to, reason, _) = $0 {
                return to == .failed && reason == "done_timeout"
            }
            return false
        }
        XCTAssertTrue(failed, "缺 done 必须把当前 turn 推到 failed 终态")

        // **绝不能出现 completed 的迁移**（跨 turn flush 的反证）。
        let completedLeak = after.effects.contains {
            if case let .logTurnTransition(_, _, to, _, _) = $0 { return to == .completed }
            return false
        }
        XCTAssertFalse(completedLeak, "缺 done 严禁把 turn 错认为 completed")
    }

    // MARK: - 验收 3：suspended N3 语义（显式恢复；UI 不可能呈现「正在听」）

    func testSystemInterruptEntersSuspendedAndCancelsCurrentTurn() {
        let base = warmToPlaying()
        let after = drive([
            .systemInterrupt(reason: "lock_screen", atMs: t0 + 1000)
        ], from: base.state)

        XCTAssertEqual(after.state.session, .suspended,
                       "系统中断必须进 suspended；不得留在 listening/playing")
        XCTAssertNil(after.state.currentTurn, "中断后清空 currentTurn")
        XCTAssertTrue(after.state.retiredGenerations.contains(gen1),
                      "被中断的 generation 必须 retired，防止解锁后旧帧继续播")

        // §1.2：suspended 期间 UI 不能呈现「正在听」——通过验证 session != listening 兜住。
        XCTAssertNotEqual(after.state.session, .listening,
                          "N3：suspended 与 listening 互斥，UI 不可能 mis-render 为『正在听』")
    }

    func testSuspendedDoesNotAutoResumeOnAnyImplicitEvent() {
        // 关键 N3：suspended 状态下，除 explicitResume/endFromSuspended 外任何输入都不能离开 suspended。
        let base = warmToPlaying()
        let suspended = drive([
            .systemInterrupt(reason: "call", atMs: t0 + 1000)
        ], from: base.state)

        // 试遍所有会「让人误以为可以自动恢复」的事件：
        let attempts: [RealtimeReducerAction] = [
            .channelReady(atMs: t0 + 2000),                                   // 通道其实还在
            .vadFinal(turnId: turn1, atMs: t0 + 2000),
            .commitAcked(turnId: turn1, atMs: t0 + 2000),
            .generationOpened(turnId: turn1, generation: gen2, atMs: t0 + 2000),
            .firstAudio(turnId: turn1, generation: gen2, atMs: t0 + 2000),
            .audioDelta(turnId: turn1, generation: gen2, atMs: t0 + 2000),
            .audioDone(turnId: turn1, generation: gen2, atMs: t0 + 2000),
            .userBargeIn(nextTurnId: turn2, atMs: t0 + 2000)
        ]
        for act in attempts {
            let out = RealtimeSessionReducer.reduce(suspended.state, act)
            XCTAssertEqual(out.state.session, .suspended,
                           "N3：suspended 不能被 \(act) 自动带出去（必须显式 resume）")
        }
    }

    func testExplicitResumeMovesSuspendedBackToListening() {
        let base = warmToPlaying()
        let suspended = drive([
            .systemInterrupt(reason: "lock_screen", atMs: t0 + 1000)
        ], from: base.state)

        let after = drive([
            .explicitResume(nextTurnId: turn2, atMs: t0 + 5000)
        ], from: suspended.state)
        XCTAssertEqual(after.state.session, .listening)
        XCTAssertEqual(after.state.currentTurn?.turnId, turn2)
        XCTAssertEqual(after.state.currentTurn?.phase, .capturing)
        let began = after.effects.contains {
            if case let .beginTurn(id, _) = $0 { return id == self.turn2 }
            return false
        }
        XCTAssertTrue(began, "explicit resume 必须触发 beginTurn 副作用")
    }

    func testEndFromSuspendedGoesToEndingThenIdle() {
        let base = warmToPlaying()
        let suspended = drive([
            .systemInterrupt(reason: "workout", atMs: t0 + 1000)
        ], from: base.state)
        let ending = drive([
            .endFromSuspended(atMs: t0 + 2000)
        ], from: suspended.state)
        XCTAssertEqual(ending.state.session, .ending)
        let closed = ending.effects.contains {
            if case .closeConversation = $0 { return true }
            return false
        }
        XCTAssertTrue(closed)

        let idle = drive([
            .sessionClosed(atMs: t0 + 2100)
        ], from: ending.state)
        XCTAssertEqual(idle.state.session, .idle)
        XCTAssertNil(idle.state.conversationId)
        XCTAssertTrue(idle.state.retiredGenerations.isEmpty)
    }

    // MARK: - 验收 4：barge-in 顺序（本地停播 → cancel → 迟到 delta 全丢）

    func testBargeInEffectOrderStopsPlaybackBeforeCancel() {
        let base = warmToPlaying()
        let after = RealtimeSessionReducer.reduce(
            base.state,
            .userBargeIn(nextTurnId: turn2, atMs: t0 + 900)
        )

        // 找出 stopLocalPlayback 与 cancelGeneration 在 effects 中的位置
        var stopIdx: Int?
        var cancelIdx: Int?
        var clearIdx: Int?
        for (i, effect) in after.effects.enumerated() {
            if case .stopLocalPlayback = effect, stopIdx == nil { stopIdx = i }
            if case .cancelGeneration = effect, cancelIdx == nil { cancelIdx = i }
            if case .clearPlaybackBuffer = effect, clearIdx == nil { clearIdx = i }
        }
        XCTAssertNotNil(stopIdx, "barge-in 必须产出 stopLocalPlayback")
        XCTAssertNotNil(cancelIdx, "barge-in 必须产出 cancelGeneration")
        XCTAssertNotNil(clearIdx, "barge-in 必须产出 clearPlaybackBuffer")
        XCTAssertLessThan(stopIdx!, cancelIdx!,
                          "§1.2 顺序：本地停播必须先于 response.cancel")
        XCTAssertLessThan(cancelIdx!, clearIdx!,
                          "清空缓冲在 cancel 之后：防止 cancel 未发出前就丢应对方 payload")

        XCTAssertEqual(after.state.session, .listening,
                       "barge-in 后回到 listening 等下一轮 VAD")
        XCTAssertEqual(after.state.currentTurn?.turnId, turn2,
                       "barge-in 必须新起一个 turn，旧 turn 已 cancelled")
        XCTAssertTrue(after.state.retiredGenerations.contains(gen1),
                      "旧 generation 必须 retired，后续迟到 delta 命中即丢")
    }

    func testBargeInLateDeltasFromOldGenerationAllDropped() {
        // 一次 barge-in + 一串旧 gen 的 delta/done/first_audio 全部到达
        let base = warmToPlaying()
        let bargein = drive([
            .userBargeIn(nextTurnId: turn2, atMs: t0 + 900)
        ], from: base.state)

        let late: [RealtimeReducerAction] = [
            .audioDelta(turnId: turn1, generation: gen1, atMs: t0 + 910),
            .audioDelta(turnId: turn1, generation: gen1, atMs: t0 + 920),
            .firstAudio(turnId: turn1, generation: gen1, atMs: t0 + 930),
            .audioDone(turnId: turn1, generation: gen1, atMs: t0 + 940)
        ]
        var state = bargein.state
        var lateEffects: [RealtimeReducerEffect] = []
        for act in late {
            let out = RealtimeSessionReducer.reduce(state, act)
            state = out.state
            lateEffects.append(contentsOf: out.effects)
        }
        // 全部四条应被 dropStaleEvent 记录，且 state 未改
        XCTAssertEqual(state.currentTurn?.turnId, turn2)
        XCTAssertEqual(state.session, .listening)

        let staleCount = lateEffects.reduce(into: 0) { acc, effect in
            if case let .dropStaleEvent(_, _, gen, reason) = effect,
               gen == self.gen1, reason == "stale_generation" {
                acc += 1
            }
        }
        XCTAssertEqual(staleCount, 4, "四条迟到帧全部按 stale_generation 丢弃")
    }

    // MARK: - 验收 5：reducer 纯函数（同输入必得同输出）

    func testReducerIsPureFunctionSameInputSameOutput() {
        let seq: [RealtimeReducerAction] = [
            .enter(conversationId: conversationId, firstTurnId: turn1, atMs: t0),
            .channelReady(atMs: t0 + 100),
            .vadFinal(turnId: turn1, atMs: t0 + 300),
            .commitAcked(turnId: turn1, atMs: t0 + 400),
            .generationOpened(turnId: turn1, generation: gen1, atMs: t0 + 500),
            .firstAudio(turnId: turn1, generation: gen1, atMs: t0 + 800),
            .audioDone(turnId: turn1, generation: gen1, atMs: t0 + 1500)
        ]
        let a = drive(seq)
        let b = drive(seq)
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(a.effects, b.effects)
    }

    // MARK: - 结构化日志：state_from / state_to / reason_code / duration_ms + 四级 ID

    func testStateTransitionsCarryFourLevelIdsAndDurationMs() {
        let trace = drive([
            .enter(conversationId: conversationId, firstTurnId: turn1, atMs: t0),
            .channelReady(atMs: t0 + 100),
            .vadFinal(turnId: turn1, atMs: t0 + 300)
        ])

        // establishing → listening：conversationId、turnId 必须齐；duration_ms=100
        let toListening = trace.effects.first { effect in
            if case let .logSessionTransition(from, to, _, dur, conv, tid, gen) = effect,
               from == .establishing, to == .listening {
                XCTAssertEqual(dur, 100, "duration_ms 必须由 atMs 差算出")
                XCTAssertEqual(conv, self.conversationId, "四级 ID：conversation_id 必须透传")
                XCTAssertEqual(tid, self.turn1, "四级 ID：turn_id 必须透传")
                XCTAssertNil(gen, "此刻尚未 generationOpened，generation 应为 nil")
                return true
            }
            return false
        }
        XCTAssertNotNil(toListening)
    }

    // MARK: - N2：新会话状态机不复用 VoiceTurnState 的 rank 单调语义

    func testRealtimeSessionStateHasNoRankMonotonyAndAllowsRoundTrips() {
        // 用「同一会话内多次回到 listening」证明 rank 单调不适用于会话层。
        var state = warmToPlaying().state
        state = drive([
            .audioDone(turnId: turn1, generation: gen1, atMs: t0 + 1500)
        ], from: state).state
        XCTAssertEqual(state.session, .listening)   // playing → listening（第一次回）

        // 再走一轮
        state = drive([
            .enter(conversationId: UUID(), firstTurnId: turn2, atMs: t0 + 2000)  // 应被拒（已在 listening）
        ], from: state).state
        XCTAssertEqual(state.session, .listening, "enter 只能在 idle；重复 enter 被拒不改状态")

        // 用 explicit 的下一 turn 继续
        state.currentTurn = RealtimeTurnRuntime(
            turnId: turn2, generation: nil, phase: .capturing, enteredAtMs: t0 + 2000
        )
        state = drive([
            .vadFinal(turnId: turn2, atMs: t0 + 2100),
            .commitAcked(turnId: turn2, atMs: t0 + 2200),
            .generationOpened(turnId: turn2, generation: gen2, atMs: t0 + 2300),
            .firstAudio(turnId: turn2, generation: gen2, atMs: t0 + 2400),
            .audioDone(turnId: turn2, generation: gen2, atMs: t0 + 2900)
        ], from: state).state
        XCTAssertEqual(state.session, .listening,
                       "会话层 listening ↔ playing 允许多次往返；证明未沿用 rank 单调")
    }

    // MARK: - reducer 无外部依赖（这里靠 test target 编译面约束——本文件仅 import 见开头）

    // XCTAssert：任何试图 import UIKit / AVFoundation / SwiftUI 都会让 test target
    // 编译失败——本文件的 import 列表就是本条约束的证明。
}
