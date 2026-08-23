import Foundation

// MARK: - ESS-1097 工具回合本地聚合状态机
//
// 问题（ESS-1095 取证）：上游在 `tool_call_pending` 之后就发 `voice.state=idle`，
// 网关据此收回合、下发回合终态，客户端把它当成「答完了」→ 回「正在听」→
// 自动开下一轮 → 新 generation 把仍在 running 的工具任务 supersede 掉。
//
// 修法：**UI 相位不由任何单一上游信号决定**，而由本聚合体在客户端本地
// 汇总三类事实后给出：
//   1. 工具面：`tool_call_pending` 闩锁 + 未终结任务集合（`task.state`）；
//   2. 下行面：回合级 `audio.done` 屏障是否落定（段落 `audio.segment_done` 不算）；
//   3. 播放面：回答音频是否正在播 / 是否已播完。
//
// 收口（→「正在听」，并允许开下一轮）当且仅当三面同时满足：
//   `audio.done 屏障已落定` ∧ `无未终结任务` ∧ `tool_call_pending 已解除`
//   ∧ `没有在播的音频`。
//
// 反面同样是硬约束：显式取消 / 失败 / 超时 / 下行通道关闭都必须给出**明确终态**，
// 绝不允许把回合永久留在「正在思考」——那比报错更糟（ESS-600 的同一条教训）。
//
// 本文件是**纯函数式值类型**：不依赖 AVFoundation / SwiftUI / 网络，时间由调用方
// 以 `atMs` 注入，可完整在 `swift test` 中跑（`Tests/ToolTurnAggregateTests.swift`）。

// MARK: - 任务状态

/// 上游 `task.*` 生命周期在客户端的最小投影。
///
/// 取值刻意与网关 `agent.task` 的 `task.status` 字符串对齐（`AudioRealtimeGateway/
/// qwen-agent-transport.mjs`），但**不做白名单**：未知取值一律按「非终态」处理，
/// 因为把一个没见过的状态当成终态，等于回到本 issue 要修的那个 bug。
public enum ToolTaskStatus: Equatable, Sendable {
    case queued
    case accepted
    case running
    case completed
    case failed
    case cancelled
    case timedOut
    /// 上游给了一个客户端不认识的状态。按非终态处理（保守：继续等）。
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "queued", "pending": self = .queued
        case "accepted": self = .accepted
        case "running", "in_progress", "progress": self = .running
        case "completed", "complete", "done", "succeeded": self = .completed
        case "failed", "error": self = .failed
        case "cancelled", "canceled", "aborted": self = .cancelled
        case "timeout", "timed_out": self = .timedOut
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .queued: return "queued"
        case .accepted: return "accepted"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .timedOut: return "timeout"
        case .unknown(let raw): return raw
        }
    }

    /// 终态 = 这个任务不会再有后续工作。只有终态才把任务移出未结集合。
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut: return true
        case .queued, .accepted, .running, .unknown: return false
        }
    }
}

// MARK: - 聚合体

public struct ToolTurnAggregate: Equatable, Sendable {

    // MARK: 对外相位

    /// 本回合应当呈现给用户的相位。会话层据此驱动 `SessionController.TurnPhase`。
    public enum Phase: Equatable, Sendable {
        /// 「正在思考」：工具在跑 / 在等回答 / 段落间隙。
        case thinking
        /// 「正在回答」：回答音频真实在播。
        case answering
        /// 「正在听」：回合已完整收口，可以开下一轮。
        case listening
        /// 明确失败终态（不得停在 thinking）。
        case failed(code: String)
        /// 用户显式取消 / 打断。
        case cancelled(reason: String)
        /// 有界等待到点。
        case timedOut(reason: String)

        public var isTerminalFailure: Bool {
            switch self {
            case .failed, .cancelled, .timedOut: return true
            case .thinking, .answering, .listening: return false
            }
        }

        /// 结构化日志用的稳定标识。
        public var logName: String {
            switch self {
            case .thinking: return "thinking"
            case .answering: return "answering"
            case .listening: return "listening"
            case .failed: return "failed"
            case .cancelled: return "cancelled"
            case .timedOut: return "timed_out"
            }
        }
    }

    /// 回合**没有**收口时，到底卡在哪一面。日志与测试都读它——
    /// 「为什么还在思考」必须是可判定的，不能只有一个布尔。
    public enum HoldReason: String, Equatable, Sendable, CaseIterable {
        /// 上游宣告 `tool_call_pending` 且尚未解除。
        case toolCallPending = "tool_call_pending"
        /// 至少一个 `task.*` 仍未终结。
        case taskOutstanding = "task_outstanding"
        /// 回合级 `audio.done` 屏障还没落定（段落屏障不算）。
        case awaitingAudioDone = "awaiting_audio_done"
        /// 音频还在播。
        case playbackInFlight = "playback_in_flight"
    }

    // MARK: 输入事件

    public enum Event: Equatable, Sendable {
        /// 上游 `response.done{hasFunctionCall:true}` 的客户端投影：模型要调工具，
        /// 本回合还没完。**闩锁是临时占位**，语义见 `toolCallPending` 字段注释。
        case toolCallPending
        /// `tool_call_pending` 解除（工具结果这一段就是最后一段）。
        case toolCallResolved
        /// `task.*` 生命周期事件。同一 `taskId` 可重复到达，按最后一次为准。
        ///
        /// **任何带 taskId 的事件都会解除 `tool_call_pending` 闩锁**——闩锁的
        /// 全部含义就是「有个任务要来但还没有号」，号一出现它就没有存在意义了，
        /// 此后由任务集合独占裁决权。见 ESS-1098 复审阻断 1。
        case taskState(taskId: String, status: ToolTaskStatus)
        /// 回答音频**真实起播**（首帧已渲染）。收到 delta / 入队不算。
        case playbackStarted
        /// 一**段**音频播完（`audio.segment_done` 之后的 `.ended`）。回合未完。
        case playbackSegmentEnded
        /// 本回合音频播完（最后一段渲染完毕）。
        case playbackEnded
        /// 回合级 `audio.done` 屏障落定（含零音频 `final_sequence = -1`）。
        case audioDoneBarrier
        /// 下行通道在回合结束前关闭 / 传输失败。之后不会再有任何上游事实：
        /// 屏障视同落定、未结任务视同放弃，但**在播的音频要放完**。
        case downlinkClosed(reason: String)
        /// 用户显式取消（点球打断 / 退出会话）。
        case userCancelled(reason: String)
        /// 服务端判本回合终态失败。
        case turnFailed(code: String)
        /// 客户端有界等待到点。
        case timedOut(reason: String)
    }

    // MARK: 内部事实

    /// 未终结任务集合。`Set` 而不是计数：同一个 taskId 的重复 running 不能累加，
    /// 否则一次终态减不回 0，回合永远收不了口。
    public private(set) var outstandingTasks: Set<String> = []
    /// 本回合见过的全部 taskId（取证用；终态到达后不从这里删）。
    public private(set) var seenTasks: Set<String> = []
    /// `tool_call_pending` 闩锁。
    ///
    /// **不变量（ESS-1098 复审阻断 1 的收口口径）**：闩锁是「有个任务要来但还
    /// 没有任务号」的**临时占位**，只由两件事解除，二者都是上游能确定性给出的：
    ///
    /// 1. **任何 taskId 出现** —— 占位物被真身取代，此后由 `outstandingTasks`
    ///    独占裁决权；这是真实工具回合的常态路径，**不需要服务端多发一帧**。
    /// 2. **显式 `tool_call_resolved` 帧** —— 覆盖「宣告了工具调用却从未产生
    ///    任务」这一残余情形；网关侧已有 `upstream_tool_call_resolved` 的判定，
    ///    契约见 `AudioRealtimeGateway/README.md`。
    ///
    /// **刻意不设第三条「音频落定即解除」的逃生门**：那正是 ESS-1095 的故障
    /// 形态——`tool_call_pending` 之后上游发 idle、网关下发回合屏障，而任务帧
    /// 尚未到达。拿音频落定去解除闩锁，等于把这个 bug 原样装回去。残余情形
    /// 由回合绝对上限（`SessionController.toolTurnHardTimeoutSeconds`）兜底为
    /// **有界的明确失败**，而不是静默收口后 supersede 掉在跑的工具。
    public private(set) var toolCallPending = false
    public private(set) var audioDoneSettled = false
    public private(set) var playbackInFlight = false
    /// 本回合是否真的播出过声音。零音频回合与「音频还没来」在日志里必须分得开。
    public private(set) var didPlayAnyAudio = false
    /// 下行是否已被通道关闭提前收口（区别于正常 `audio.done`）。
    public private(set) var downlinkClosedReason: String?
    /// 终态一旦落定即**吸收**：后续事件只留证不改相位。
    public private(set) var terminal: Phase?

    public init() {}

    // MARK: 派生量

    /// 回合是否已完整收口（可以回「正在听」并开下一轮）。
    public var isClosed: Bool {
        if terminal != nil { return true }
        return holdReasons.isEmpty
    }

    /// 还没收口的全部原因，稳定排序（便于日志比对与断言）。
    public var holdReasons: [HoldReason] {
        if terminal != nil { return [] }
        var reasons: [HoldReason] = []
        if toolCallPending { reasons.append(.toolCallPending) }
        if !outstandingTasks.isEmpty { reasons.append(.taskOutstanding) }
        if !audioDoneSettled { reasons.append(.awaitingAudioDone) }
        if playbackInFlight { reasons.append(.playbackInFlight) }
        return reasons
    }

    /// 当前 UI 相位。
    ///
    /// 顺序有意：终态 > 在播 > 已收口 > 思考。
    /// 「在播」压过「有未结任务」——工具结果的第一段音频已经在说话了，此时对用户
    /// 显示「正在思考」是撒谎；但它**不**让回合收口（`isClosed` 仍为 false），
    /// 所以播完还会回到 thinking 继续等，而不是开下一轮。
    public var phase: Phase {
        if let terminal { return terminal }
        if playbackInFlight { return .answering }
        return isClosed ? .listening : .thinking
    }

    /// 本回合是否出现过**工具证据**（`tool_call_pending` 或任何 `task.*`）。
    ///
    /// 闸门只对工具回合生效，是刻意的收敛：没有任何工具信号的普通回合走
    /// 与本 issue 之前**逐字节相同**的路径（`audio.done` + 播完 → 开下一轮）。
    /// 把闸门无差别套到所有回合上，等于用一个未验证的新状态机替换掉一条
    /// 已被 ESS-600/ESS-971 真机验证过的主链路——那是拿主干换一个 bug 修。
    public var hasToolEvidence: Bool { toolCallPending || !seenTasks.isEmpty }

    /// 是否还有工具侧未完成的工作（在跑的任务 / 未解除的 `tool_call_pending`）。
    /// 会话层据此把「等回答」的有界预算从 45s 切到工具预算。
    public var hasOutstandingWork: Bool {
        terminal == nil && (toolCallPending || !outstandingTasks.isEmpty)
    }

    /// 工具回合未终结 → **禁止自动开启下一轮 generation**。
    /// 用户主动打断走 `userCancelled` 自成终态，不受本闸门约束。
    public var blocksAutomaticNextTurn: Bool { hasToolEvidence && !isClosed }

    /// 是否允许**自动**开启下一轮 generation。
    public var allowsAutomaticNextTurn: Bool { !blocksAutomaticNextTurn }

    // MARK: 迁移

    /// 应用一个事件。返回值 = 相位是否发生变化（调用方据此决定要不要落日志）。
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        let before = phase
        // 终态吸收：已判死的回合不再被任何后续事件改写，但播放面仍要如实记账
        // （取消后迟到的 `.ended` 不能把 `playbackInFlight` 永远留成 true）。
        if terminal != nil {
            switch event {
            case .playbackEnded, .playbackSegmentEnded:
                playbackInFlight = false
            default:
                break
            }
            return false
        }

        switch event {
        case .toolCallPending:
            toolCallPending = true

        case .toolCallResolved:
            toolCallPending = false

        case .taskState(let taskId, let status):
            seenTasks.insert(taskId)
            // ESS-1098 阻断 1：任务号一出现，闩锁就完成了它的全部使命。
            // 不清它的话，`pending → running(t1) → completed(t1) → audio.done
            // → 播完` 这条**成功**路径会永远停在 `hold=[tool_call_pending]`，
            // 一路挂到 180s 绝对上限判失败——一个答对了的回合被报成超时。
            toolCallPending = false
            if status.isTerminal {
                outstandingTasks.remove(taskId)
            } else {
                outstandingTasks.insert(taskId)
            }

        case .playbackStarted:
            playbackInFlight = true
            didPlayAnyAudio = true

        case .playbackSegmentEnded:
            // 段落播完：回合保持打开。屏障状态一个字都不动——段落屏障
            // （`audio.segment_done`）与回合屏障（`audio.done`）是两件事。
            playbackInFlight = false

        case .playbackEnded:
            playbackInFlight = false

        case .audioDoneBarrier:
            audioDoneSettled = true

        case .downlinkClosed(let reason):
            // 通道没了就不会再有 `audio.done`、也不会再有 `task.*` 终态。
            // 继续等 = 永久卡死；这里如实放弃这两面，只保留「音频要放完」。
            downlinkClosedReason = reason
            audioDoneSettled = true
            toolCallPending = false
            outstandingTasks.removeAll()

        case .userCancelled(let reason):
            terminal = .cancelled(reason: reason)

        case .turnFailed(let code):
            terminal = .failed(code: code)

        case .timedOut(let reason):
            terminal = .timedOut(reason: reason)
        }
        return phase != before
    }

    // MARK: 取证

    /// 结构化日志的一行摘要。字段名与网关侧 ESS-1096 的口径保持一致，
    /// 真机日志才能按 request/task 关联起来。
    public var logDetail: String {
        "phase=\(phase.logName)"
            + " closed=\(isClosed)"
            + " hold=\(holdReasons.isEmpty ? "none" : holdReasons.map(\.rawValue).joined(separator: "|"))"
            + " outstanding_tasks=\(outstandingTasks.count)"
            + " seen_tasks=\(seenTasks.count)"
            + " tool_call_pending=\(toolCallPending)"
            + " audio_done=\(audioDoneSettled)"
            + " playing=\(playbackInFlight)"
            + " played_any=\(didPlayAnyAudio)"
            + (downlinkClosedReason.map { " downlink_closed=\($0)" } ?? "")
    }
}
