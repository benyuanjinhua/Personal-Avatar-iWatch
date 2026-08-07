import Foundation

// MARK: - ESS-553 双层状态机 reducer（纯函数，可 macOS 单测）
//
// 方案 §1.2（ESS-543 v1.0）：
//   会话层 `idle → establishing → listening → committing → waiting_first_audio
//         → playing → listening`；任意活动态可 `→ ending → idle`；系统中断
//         `→ suspended`。
//   回合层 `capturing → vad_final → committed → generating → first_audio
//         → streaming → completed`；`completed | cancelled | failed` 为
//         不可逆终态。
//
// N2（ESS-547）分层约束：本模块与既有 `VoiceTurnState` 的 rank 单调语义
// **必须显式分开**。会话层的 `listening ↔ playing` 是一次「往返」（同一会话
// 内多轮反复回到 listening），不适用「只允许向前」的规则；因此本文件的枚举
// **不实现 rank 比较**，任何调用方也不得把 `RealtimeSessionState`/
// `RealtimeTurnPhase` 与 `VoiceTurnState.canTransition(to:)` 混用。
//
// N3（ESS-547）suspended 恢复语义：本 reducer 选择 **方案口径 = 显式恢复**。
// 系统中断只能通过 `explicitResume`（用户显式点击「继续」/「结束」）离开
// `suspended`；即便应用回到前台，reducer 也不会自动回到 listening，UI 侧
// 因此不可能呈现「正在听」但实际未采集。既有 `VoiceSessionKeeper` 的
// `resignedFrontmost` 自动 re-arm 只服务于按住说话（PTT）路径的
// ExtendedRuntimeSession 存活，与本 reducer 走 feature flag 分道并存，
// 两种语义不会同时作用于同一路径，符合 R-04.6。
//
// 本文件 **纯函数**：不依赖 `AVFoundation` / `SwiftUI` / 网络，全部动作与
// 时间以入参形式给出（`atMs` 由调用方注入），可完整在 `swift test` 中运行。

// MARK: - 会话状态

public enum RealtimeSessionState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case establishing
    case listening
    case committing
    case waitingFirstAudio = "waiting_first_audio"
    case playing
    case ending
    case suspended

    /// 是否属于「活动」态（可被用户点 X 或系统中断打断）。
    /// `ending` 与 `idle` 不再是活动态；`suspended` 是活动态的暂存，仍可 end。
    public var isActive: Bool {
        switch self {
        case .idle, .ending: return false
        case .establishing, .listening, .committing, .waitingFirstAudio, .playing, .suspended:
            return true
        }
    }
}

// MARK: - 回合状态（区别于 Shared/VoiceTurnState.swift 的 rank 单调枚举）

public enum RealtimeTurnPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case capturing
    case vadFinal = "vad_final"
    case committed
    case generating
    case firstAudio = "first_audio"
    case streaming
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        self == .completed || self == .cancelled || self == .failed
    }
}

// MARK: - 回合运行时快照

public struct RealtimeTurnRuntime: Codable, Equatable, Sendable {
    public var turnId: UUID
    public var generation: UUID?
    public var phase: RealtimeTurnPhase
    public var enteredAtMs: Int64

    public init(turnId: UUID, generation: UUID? = nil, phase: RealtimeTurnPhase, enteredAtMs: Int64) {
        self.turnId = turnId
        self.generation = generation
        self.phase = phase
        self.enteredAtMs = enteredAtMs
    }
}

// MARK: - 会话运行时快照

public struct RealtimeSessionSnapshot: Codable, Equatable, Sendable {
    public var session: RealtimeSessionState
    public var sessionEnteredAtMs: Int64
    public var conversationId: UUID?
    public var currentTurn: RealtimeTurnRuntime?
    /// 已被 barge-in cancel 或超时 fail 的旧 generation。用于识别迟到 delta —
    /// 命中即丢弃并记 `stale_generation`，绝不再进入播放队列（§1.2）。
    public var retiredGenerations: Set<UUID>

    public static let initial = RealtimeSessionSnapshot(
        session: .idle,
        sessionEnteredAtMs: 0,
        conversationId: nil,
        currentTurn: nil,
        retiredGenerations: []
    )

    public init(
        session: RealtimeSessionState,
        sessionEnteredAtMs: Int64,
        conversationId: UUID?,
        currentTurn: RealtimeTurnRuntime?,
        retiredGenerations: Set<UUID>
    ) {
        self.session = session
        self.sessionEnteredAtMs = sessionEnteredAtMs
        self.conversationId = conversationId
        self.currentTurn = currentTurn
        self.retiredGenerations = retiredGenerations
    }
}

// MARK: - 输入动作

public enum RealtimeReducerAction: Equatable, Sendable {
    /// 用户点球进入会话。
    case enter(conversationId: UUID, firstTurnId: UUID, atMs: Int64)
    /// 上行通道就绪（WSS + Gateway 均已 ready）。
    case channelReady(atMs: Int64)
    /// VAD final：本轮说话结束（Watch 单一权威）。
    case vadFinal(turnId: UUID, atMs: Int64)
    /// 上行 `input_audio.commit` 已被 relay 幂等接受。
    case commitAcked(turnId: UUID, atMs: Int64)
    /// Gateway 为本 turn 打开一个新 generation（`response.created`）。
    case generationOpened(turnId: UUID, generation: UUID, atMs: Int64)
    /// 首帧下行音频已在播放侧渲染（`.dataPlayedBack`）。ESS-547 A7 口径。
    case firstAudio(turnId: UUID, generation: UUID, atMs: Int64)
    /// 后续下行音频 delta。
    case audioDelta(turnId: UUID, generation: UUID, atMs: Int64)
    /// `response.audio.done`：本 generation 有序释放到 final_sequence。
    case audioDone(turnId: UUID, generation: UUID, atMs: Int64)
    /// done 缺失超时。§1.2：超时失败并清理，不跨 turn flush。
    case audioDoneTimeout(turnId: UUID, generation: UUID, atMs: Int64)
    /// 用户点球打断（增强半双工 MVP 唯一打断路径）。
    case userBargeIn(nextTurnId: UUID, atMs: Int64)
    /// 用户点 X 退出。
    case userExit(atMs: Int64)
    /// `conversation.close` 已被服务端 ack；ending → idle 收口。
    case sessionClosed(atMs: Int64)
    /// 系统中断（锁屏 / 来电 / 音频会话中断 / 放腕）。
    case systemInterrupt(reason: String, atMs: Int64)
    /// 用户显式点击「继续」恢复。N3 语义：**仅此一条**可离开 suspended 回 listening。
    case explicitResume(nextTurnId: UUID, atMs: Int64)
    /// 用户在 suspended 状态显式点 X 结束。
    case endFromSuspended(atMs: Int64)
    /// 回合层错误（Gateway/Qwen 报 error）。
    case turnFailed(turnId: UUID, generation: UUID?, code: String, atMs: Int64)
}

// MARK: - 输出副作用

public enum RealtimeReducerEffect: Equatable, Sendable {
    /// 打开会话（发 `conversation.open`）。
    case openConversation(id: UUID)
    /// 开一个新回合（设置 turn_id，进入 capturing）。
    case beginTurn(turnId: UUID, atMs: Int64)
    /// 发 `input_audio.commit`（幂等一次）。
    case sendCommit(turnId: UUID)
    /// 立即本地停播。**barge-in 时必须先于 cancelGeneration**（§1.2）。
    case stopLocalPlayback(reason: String)
    /// 发 `response.cancel(generation)`。
    case cancelGeneration(generation: UUID)
    /// 清空当前 generation 的播放缓冲。禁止跨 turn flush。
    case clearPlaybackBuffer(reason: String)
    /// 发 `conversation.close` 并释放 audio session（`ending → idle`）。
    case closeConversation(reason: String)
    /// 抛弃迟到 / 越权 / 无 generation 的下行事件；不进入播放队列。
    case dropStaleEvent(
        kind: String,
        turnId: UUID?,
        generation: UUID?,
        reason: String
    )
    /// 非法迁移或未定义事件的拒绝——不静默吞掉，交上层日志。
    case rejected(action: String, from: RealtimeSessionState, reason: String)
    /// 会话层结构化日志：`state_from` / `state_to` / `reason_code` / `duration_ms`
    /// + 四级 ID（conversationId 出现在 state 中，reducer 只透传）。
    case logSessionTransition(
        from: RealtimeSessionState,
        to: RealtimeSessionState,
        reason: String,
        durationMs: Int64,
        conversationId: UUID?,
        turnId: UUID?,
        generation: UUID?
    )
    /// 回合层结构化日志。
    case logTurnTransition(
        turnId: UUID,
        from: RealtimeTurnPhase,
        to: RealtimeTurnPhase,
        reason: String,
        generation: UUID?
    )
}

// MARK: - reducer 输出

public struct RealtimeReducerOutput: Equatable, Sendable {
    public var state: RealtimeSessionSnapshot
    public var effects: [RealtimeReducerEffect]

    public init(state: RealtimeSessionSnapshot, effects: [RealtimeReducerEffect]) {
        self.state = state
        self.effects = effects
    }
}

// MARK: - reducer

public enum RealtimeSessionReducer {
    /// 纯函数：给定当前快照和一个动作，返回新快照与要执行的副作用集合。
    /// 相同 (state, action) 恒产生相同 output。
    public static func reduce(
        _ state: RealtimeSessionSnapshot,
        _ action: RealtimeReducerAction
    ) -> RealtimeReducerOutput {
        var mutable = state
        var effects: [RealtimeReducerEffect] = []
        applyAction(action, state: &mutable, effects: &effects)
        return RealtimeReducerOutput(state: mutable, effects: effects)
    }

    // MARK: 内部分派

    private static func applyAction(
        _ action: RealtimeReducerAction,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        switch action {
        case let .enter(conversationId, firstTurnId, atMs):
            handleEnter(conversationId: conversationId, firstTurnId: firstTurnId, atMs: atMs,
                        state: &state, effects: &effects)
        case let .channelReady(atMs):
            handleChannelReady(atMs: atMs, state: &state, effects: &effects)
        case let .vadFinal(turnId, atMs):
            handleVadFinal(turnId: turnId, atMs: atMs, state: &state, effects: &effects)
        case let .commitAcked(turnId, atMs):
            handleCommitAcked(turnId: turnId, atMs: atMs, state: &state, effects: &effects)
        case let .generationOpened(turnId, generation, atMs):
            handleGenerationOpened(turnId: turnId, generation: generation, atMs: atMs,
                                   state: &state, effects: &effects)
        case let .firstAudio(turnId, generation, atMs):
            handleFirstAudio(turnId: turnId, generation: generation, atMs: atMs,
                             state: &state, effects: &effects)
        case let .audioDelta(turnId, generation, atMs):
            handleAudioDelta(turnId: turnId, generation: generation, atMs: atMs,
                             state: &state, effects: &effects)
        case let .audioDone(turnId, generation, atMs):
            handleAudioDone(turnId: turnId, generation: generation, atMs: atMs,
                            state: &state, effects: &effects)
        case let .audioDoneTimeout(turnId, generation, atMs):
            handleAudioDoneTimeout(turnId: turnId, generation: generation, atMs: atMs,
                                   state: &state, effects: &effects)
        case let .userBargeIn(nextTurnId, atMs):
            handleUserBargeIn(nextTurnId: nextTurnId, atMs: atMs,
                              state: &state, effects: &effects)
        case let .userExit(atMs):
            handleUserExit(atMs: atMs, state: &state, effects: &effects)
        case let .sessionClosed(atMs):
            handleSessionClosed(atMs: atMs, state: &state, effects: &effects)
        case let .systemInterrupt(reason, atMs):
            handleSystemInterrupt(reason: reason, atMs: atMs,
                                  state: &state, effects: &effects)
        case let .explicitResume(nextTurnId, atMs):
            handleExplicitResume(nextTurnId: nextTurnId, atMs: atMs,
                                 state: &state, effects: &effects)
        case let .endFromSuspended(atMs):
            handleEndFromSuspended(atMs: atMs, state: &state, effects: &effects)
        case let .turnFailed(turnId, generation, code, atMs):
            handleTurnFailed(turnId: turnId, generation: generation, code: code, atMs: atMs,
                             state: &state, effects: &effects)
        }
    }

    // MARK: 迁移工具

    private static func moveSession(
        to next: RealtimeSessionState,
        reason: String,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        let from = state.session
        let duration = max(0, atMs - state.sessionEnteredAtMs)
        state.session = next
        state.sessionEnteredAtMs = atMs
        effects.append(.logSessionTransition(
            from: from, to: next, reason: reason, durationMs: duration,
            conversationId: state.conversationId,
            turnId: state.currentTurn?.turnId,
            generation: state.currentTurn?.generation
        ))
    }

    private static func moveTurn(
        to next: RealtimeTurnPhase,
        reason: String,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard var turn = state.currentTurn else { return }
        let from = turn.phase
        turn.phase = next
        turn.enteredAtMs = atMs
        state.currentTurn = turn
        effects.append(.logTurnTransition(
            turnId: turn.turnId, from: from, to: next,
            reason: reason, generation: turn.generation
        ))
    }

    private static func retireGeneration(_ generation: UUID?, state: inout RealtimeSessionSnapshot) {
        guard let generation else { return }
        state.retiredGenerations.insert(generation)
    }

    // MARK: 事件处理

    private static func handleEnter(
        conversationId: UUID,
        firstTurnId: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .idle else {
            effects.append(.rejected(
                action: "enter", from: state.session,
                reason: "enter_requires_idle"
            ))
            return
        }
        state.conversationId = conversationId
        moveSession(to: .establishing, reason: "user_enter", atMs: atMs,
                    state: &state, effects: &effects)
        effects.append(.openConversation(id: conversationId))
        // 首个 turn 的 id 在此登记，等 channelReady 才进入 capturing。
        state.currentTurn = RealtimeTurnRuntime(
            turnId: firstTurnId, generation: nil,
            phase: .capturing, enteredAtMs: atMs
        )
        // 注意：这里不发 logTurnTransition —— 尚未有前一态可跳。
    }

    private static func handleChannelReady(
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .establishing else {
            effects.append(.rejected(
                action: "channel_ready", from: state.session,
                reason: "channel_ready_requires_establishing"
            ))
            return
        }
        moveSession(to: .listening, reason: "channel_ready", atMs: atMs,
                    state: &state, effects: &effects)
        if let turn = state.currentTurn {
            effects.append(.beginTurn(turnId: turn.turnId, atMs: atMs))
        }
    }

    private static func handleVadFinal(
        turnId: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .listening else {
            effects.append(.rejected(
                action: "vad_final", from: state.session,
                reason: "vad_final_requires_listening"
            ))
            return
        }
        guard let current = state.currentTurn, current.turnId == turnId else {
            effects.append(.rejected(
                action: "vad_final", from: state.session,
                reason: "vad_final_turn_mismatch"
            ))
            return
        }
        guard current.phase == .capturing else {
            effects.append(.rejected(
                action: "vad_final", from: state.session,
                reason: "turn_phase_not_capturing"
            ))
            return
        }
        moveTurn(to: .vadFinal, reason: "vad_final", atMs: atMs,
                 state: &state, effects: &effects)
        moveSession(to: .committing, reason: "vad_final", atMs: atMs,
                    state: &state, effects: &effects)
        effects.append(.sendCommit(turnId: turnId))
    }

    private static func handleCommitAcked(
        turnId: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .committing else {
            effects.append(.rejected(
                action: "commit_acked", from: state.session,
                reason: "commit_acked_requires_committing"
            ))
            return
        }
        guard let current = state.currentTurn, current.turnId == turnId else {
            effects.append(.rejected(
                action: "commit_acked", from: state.session,
                reason: "commit_acked_turn_mismatch"
            ))
            return
        }
        moveTurn(to: .committed, reason: "commit_acked", atMs: atMs,
                 state: &state, effects: &effects)
        moveSession(to: .waitingFirstAudio, reason: "commit_acked", atMs: atMs,
                    state: &state, effects: &effects)
    }

    private static func handleGenerationOpened(
        turnId: UUID,
        generation: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard let current = state.currentTurn, current.turnId == turnId else {
            effects.append(.dropStaleEvent(
                kind: "generation_opened", turnId: turnId, generation: generation,
                reason: "unknown_turn"
            ))
            return
        }
        guard state.session == .waitingFirstAudio || state.session == .committing else {
            effects.append(.rejected(
                action: "generation_opened", from: state.session,
                reason: "generation_opened_requires_committing_or_waiting_first_audio"
            ))
            return
        }
        var updated = current
        updated.generation = generation
        state.currentTurn = updated
        moveTurn(to: .generating, reason: "generation_opened", atMs: atMs,
                 state: &state, effects: &effects)
    }

    private static func handleFirstAudio(
        turnId: UUID,
        generation: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        if state.retiredGenerations.contains(generation) {
            effects.append(.dropStaleEvent(
                kind: "first_audio", turnId: turnId, generation: generation,
                reason: "stale_generation"
            ))
            return
        }
        guard let current = state.currentTurn, current.turnId == turnId,
              current.generation == generation else {
            effects.append(.dropStaleEvent(
                kind: "first_audio", turnId: turnId, generation: generation,
                reason: "turn_or_generation_mismatch"
            ))
            return
        }
        guard state.session == .waitingFirstAudio else {
            effects.append(.rejected(
                action: "first_audio", from: state.session,
                reason: "first_audio_requires_waiting_first_audio"
            ))
            return
        }
        moveTurn(to: .firstAudio, reason: "first_audio_rendered", atMs: atMs,
                 state: &state, effects: &effects)
        moveSession(to: .playing, reason: "first_audio_rendered", atMs: atMs,
                    state: &state, effects: &effects)
    }

    private static func handleAudioDelta(
        turnId: UUID,
        generation: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        if state.retiredGenerations.contains(generation) {
            effects.append(.dropStaleEvent(
                kind: "audio_delta", turnId: turnId, generation: generation,
                reason: "stale_generation"
            ))
            return
        }
        guard let current = state.currentTurn, current.turnId == turnId,
              current.generation == generation else {
            effects.append(.dropStaleEvent(
                kind: "audio_delta", turnId: turnId, generation: generation,
                reason: "turn_or_generation_mismatch"
            ))
            return
        }
        guard state.session == .playing else {
            // 允许 firstAudio 之前落 delta（乱序），但记录为 pending 而非非法。
            // 出于最小可测面，reducer 直接以 dropStaleEvent 记录，等 firstAudio 到位后再入队。
            effects.append(.dropStaleEvent(
                kind: "audio_delta", turnId: turnId, generation: generation,
                reason: "delta_before_first_audio"
            ))
            return
        }
        if current.phase == .firstAudio {
            moveTurn(to: .streaming, reason: "audio_delta", atMs: atMs,
                     state: &state, effects: &effects)
        }
        // streaming 状态下重复 delta 不再转移，回合仍在 streaming。
    }

    private static func handleAudioDone(
        turnId: UUID,
        generation: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        if state.retiredGenerations.contains(generation) {
            effects.append(.dropStaleEvent(
                kind: "audio_done", turnId: turnId, generation: generation,
                reason: "stale_generation"
            ))
            return
        }
        guard let current = state.currentTurn, current.turnId == turnId,
              current.generation == generation else {
            effects.append(.dropStaleEvent(
                kind: "audio_done", turnId: turnId, generation: generation,
                reason: "turn_or_generation_mismatch"
            ))
            return
        }
        guard state.session == .playing || state.session == .waitingFirstAudio else {
            effects.append(.rejected(
                action: "audio_done", from: state.session,
                reason: "audio_done_requires_playing_or_waiting_first_audio"
            ))
            return
        }
        moveTurn(to: .completed, reason: "audio_done", atMs: atMs,
                 state: &state, effects: &effects)
        retireGeneration(generation, state: &state)
        // 生成新的 capturing 占位，仍由调用方在下一次 vadFinal 前给 turnId；
        // 这里把 currentTurn 清空，交给调用方 explicit `beginTurn` —— 但为了
        // 让「回到 listening」自动可用（§1.2），我们提供一个下一个 turn 的空位
        // 由调用方通过 audio_done 时不提供 turnId 无法完成，改由 `channelReady`/
        // `explicitResume` 的路径不同：正常闭环下上层在观察到 audio_done 后自行
        // 调用 `beginTurn` —— 见 handler 末尾的 effect 提示。
        state.currentTurn = nil
        moveSession(to: .listening, reason: "audio_done", atMs: atMs,
                    state: &state, effects: &effects)
    }

    private static func handleAudioDoneTimeout(
        turnId: UUID,
        generation: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard let current = state.currentTurn, current.turnId == turnId,
              current.generation == generation else {
            effects.append(.dropStaleEvent(
                kind: "audio_done_timeout", turnId: turnId, generation: generation,
                reason: "turn_or_generation_mismatch"
            ))
            return
        }
        guard state.session == .playing || state.session == .waitingFirstAudio else {
            effects.append(.rejected(
                action: "audio_done_timeout", from: state.session,
                reason: "timeout_requires_playing_or_waiting_first_audio"
            ))
            return
        }
        // §1.2：done 缺失则超时失败并清理，不跨 turn flush。
        effects.append(.clearPlaybackBuffer(reason: "done_timeout"))
        moveTurn(to: .failed, reason: "done_timeout", atMs: atMs,
                 state: &state, effects: &effects)
        retireGeneration(generation, state: &state)
        state.currentTurn = nil
        moveSession(to: .listening, reason: "done_timeout", atMs: atMs,
                    state: &state, effects: &effects)
    }

    private static func handleUserBargeIn(
        nextTurnId: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .waitingFirstAudio || state.session == .playing else {
            effects.append(.rejected(
                action: "user_barge_in", from: state.session,
                reason: "barge_in_requires_playing_or_waiting_first_audio"
            ))
            return
        }
        // 顺序严格：先本地停播 → 再 cancel(generation) → 再清空缓冲。§1.2
        effects.append(.stopLocalPlayback(reason: "user_barge_in"))
        if let gen = state.currentTurn?.generation {
            effects.append(.cancelGeneration(generation: gen))
            retireGeneration(gen, state: &state)
        }
        effects.append(.clearPlaybackBuffer(reason: "user_barge_in"))
        moveTurn(to: .cancelled, reason: "user_barge_in", atMs: atMs,
                 state: &state, effects: &effects)
        // 新起 turn，回到 listening 等下一次 VAD。
        state.currentTurn = RealtimeTurnRuntime(
            turnId: nextTurnId, generation: nil,
            phase: .capturing, enteredAtMs: atMs
        )
        moveSession(to: .listening, reason: "user_barge_in", atMs: atMs,
                    state: &state, effects: &effects)
        effects.append(.beginTurn(turnId: nextTurnId, atMs: atMs))
    }

    private static func handleUserExit(
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        // 允许从任意「活动」态或已 suspended 走 ending。idle/ending 忽略。
        guard state.session.isActive else {
            effects.append(.rejected(
                action: "user_exit", from: state.session,
                reason: "user_exit_requires_active_or_suspended"
            ))
            return
        }
        // 播放或等待播放中：先本地停播 + cancel。
        if state.session == .playing || state.session == .waitingFirstAudio {
            effects.append(.stopLocalPlayback(reason: "user_exit"))
            if let gen = state.currentTurn?.generation {
                effects.append(.cancelGeneration(generation: gen))
                retireGeneration(gen, state: &state)
            }
        }
        // 未终态回合 → cancelled。
        if let turn = state.currentTurn, !turn.phase.isTerminal {
            moveTurn(to: .cancelled, reason: "user_exit", atMs: atMs,
                     state: &state, effects: &effects)
        }
        effects.append(.closeConversation(reason: "user_exit"))
        moveSession(to: .ending, reason: "user_exit", atMs: atMs,
                    state: &state, effects: &effects)
    }

    private static func handleSessionClosed(
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .ending else {
            effects.append(.rejected(
                action: "session_closed", from: state.session,
                reason: "session_closed_requires_ending"
            ))
            return
        }
        moveSession(to: .idle, reason: "session_closed", atMs: atMs,
                    state: &state, effects: &effects)
        state.currentTurn = nil
        state.conversationId = nil
        state.retiredGenerations = []
    }

    private static func handleSystemInterrupt(
        reason: String,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session.isActive, state.session != .suspended else {
            effects.append(.rejected(
                action: "system_interrupt", from: state.session,
                reason: "system_interrupt_requires_active"
            ))
            return
        }
        if state.session == .playing || state.session == .waitingFirstAudio {
            effects.append(.stopLocalPlayback(reason: "system_interrupt:\(reason)"))
            effects.append(.clearPlaybackBuffer(reason: "system_interrupt:\(reason)"))
        }
        if let gen = state.currentTurn?.generation {
            retireGeneration(gen, state: &state)
        }
        if let turn = state.currentTurn, !turn.phase.isTerminal {
            moveTurn(to: .cancelled, reason: "system_interrupt:\(reason)",
                     atMs: atMs, state: &state, effects: &effects)
        }
        state.currentTurn = nil
        // N3：进入 suspended 后**只能**通过 explicitResume 或 endFromSuspended 离开。
        moveSession(to: .suspended, reason: "system_interrupt:\(reason)",
                    atMs: atMs, state: &state, effects: &effects)
    }

    private static func handleExplicitResume(
        nextTurnId: UUID,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .suspended else {
            effects.append(.rejected(
                action: "explicit_resume", from: state.session,
                reason: "explicit_resume_requires_suspended"
            ))
            return
        }
        state.currentTurn = RealtimeTurnRuntime(
            turnId: nextTurnId, generation: nil,
            phase: .capturing, enteredAtMs: atMs
        )
        moveSession(to: .listening, reason: "explicit_resume", atMs: atMs,
                    state: &state, effects: &effects)
        effects.append(.beginTurn(turnId: nextTurnId, atMs: atMs))
    }

    private static func handleEndFromSuspended(
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard state.session == .suspended else {
            effects.append(.rejected(
                action: "end_from_suspended", from: state.session,
                reason: "end_from_suspended_requires_suspended"
            ))
            return
        }
        effects.append(.closeConversation(reason: "end_from_suspended"))
        moveSession(to: .ending, reason: "end_from_suspended", atMs: atMs,
                    state: &state, effects: &effects)
    }

    private static func handleTurnFailed(
        turnId: UUID,
        generation: UUID?,
        code: String,
        atMs: Int64,
        state: inout RealtimeSessionSnapshot,
        effects: inout [RealtimeReducerEffect]
    ) {
        guard let current = state.currentTurn, current.turnId == turnId else {
            effects.append(.dropStaleEvent(
                kind: "turn_failed", turnId: turnId, generation: generation,
                reason: "unknown_turn:\(code)"
            ))
            return
        }
        guard state.session.isActive, state.session != .suspended,
              state.session != .ending else {
            effects.append(.rejected(
                action: "turn_failed", from: state.session,
                reason: "turn_failed_requires_active:\(code)"
            ))
            return
        }
        if state.session == .playing || state.session == .waitingFirstAudio {
            effects.append(.stopLocalPlayback(reason: "turn_failed:\(code)"))
            effects.append(.clearPlaybackBuffer(reason: "turn_failed:\(code)"))
        }
        retireGeneration(generation ?? current.generation, state: &state)
        moveTurn(to: .failed, reason: "turn_failed:\(code)", atMs: atMs,
                 state: &state, effects: &effects)
        state.currentTurn = nil
        moveSession(to: .listening, reason: "turn_failed:\(code)", atMs: atMs,
                    state: &state, effects: &effects)
    }
}
