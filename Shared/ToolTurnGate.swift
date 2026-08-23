import Foundation

// MARK: - ESS-1097 工具回合聚合状态（纯值类型，可 macOS 单测）
//
// 问题（ESS-1095 运行证据）：工具型请求里，模型先说一句「我查一下」，关掉
// 这一段 response，跑工具，再开第二段 response 说真正的答案。客户端此前
// 判「这一轮完了没有」只有两个输入——回合终态屏障（`audio.done`）与本地
// 播放终局——两者都只描述**音频**，对「工具任务还在跑」一无所知。
// 于是只要网关那侧的有界空闲窗（ESS-1043 `toolCallWindowMs = 30_000`，按
// 实测 8–16 s 工具耗时标定）被一次更慢的工具跑穿，客户端就会收到一个
// 回合终态、播完、回「正在听」，用户随即开口 → 新 request → 上游
// supersede → 工具结果丢失。**客户端不能把自己的回合终态建立在服务端的
// 启发式窗口上**，这就是本类型存在的理由。
//
// 设计口径：
//
// 1. 本类型是**聚合**，不是第二套相位真相。`SessionController.TurnPhase`
//    仍然是 UI 相位的唯一持有者；本类型只回答两个问题——「此刻这一轮
//    对用户应该显示成什么」以及「现在允许不允许开下一轮」——并由
//    `SessionController` 在它已有的边上消费。两者不并列，也不互相覆盖。
//
// 2. 输入全部是**真实链路事件**：提交、任务生命周期（上游 `task.*`，经
//    网关 `turn.task` 下发）、回答音频真实起播、回合终态屏障、播放终局、
//    显式终态（取消/失败/超时）。没有任何一条是本类型自己想当然置位的。
//
// 3. `voice.state` **不是输入**。ESS-990 已用真机取证推翻它的终态语义
//    （每段 `audio.done` 后 0.14–0.54 ms 到达，10/10 回合其后又开新段），
//    ESS-1097 的验收因此写的是「UI 由本地回合聚合状态驱动，而不是单一
//    upstream voice.state」——这里连接收口都不给它留。
//
// 4. **不许永久锁死**。任务未终结时保持思考是对的，但保持必须有上界：
//    `maxTaskHoldSeconds` 到点即强制释放并留证，回合走既有的显式终态路径。
//    一个永远等不到 `task.completed` 的 bug 只应该让用户多等有限的一段
//    时间，不应该让手表卡在「正在思考」直到用户自己退出。
//
// 本文件纯函数/纯值：不依赖 AVFoundation / SwiftUI / 网络，时间以入参
// 形式给出，可完整在 `swift test` 中运行。

/// 工具回合对用户呈现的聚合态。与 `SessionController.TurnPhase` 一一对应，
/// 但由**聚合事实**导出，而不是由某一条上游事件直接映射。
public enum ToolTurnUIState: String, Equatable, Sendable {
    /// 本轮还没提交（正在采集）或已收口 —— 「正在听…」。
    case listening
    /// 已提交、答案音频还没真实起播，或工具任务仍在跑 —— 「正在思考…」。
    case thinking
    /// 答案音频真实起播且还没播完 —— 「正在回答…」。
    case answering
    /// 显式终态（取消 / 失败 / 超时）—— 由调用方呈现明确终态文案，
    /// **不得**继续显示「正在思考」。
    case terminal
}

/// 回合的显式终态。三者都是「这一轮不会再有答案了」的确定事实。
public enum ToolTurnTerminal: String, Equatable, Sendable {
    case cancelled
    case failed
    case timedOut = "timed_out"
}

/// 工具回合聚合。值类型：`SessionController` 每轮持有一份，跨轮重置。
public struct ToolTurnAggregate: Equatable, Sendable {

    /// 任务未终结时允许保持「正在思考」的上界。
    ///
    /// 取值依据（不是拍脑袋的整数）：网关侧 ESS-1043 的工具窗
    /// `toolCallWindowMs = 30_000` 按实测工具耗时 8–16 s 标定并留 1.9x 余量；
    /// 客户端这条闸门只在**网关窗口已经放过**、而任务仍报 running 时才起作用，
    /// 所以它必须比 30 s 大才有意义，同时必须让用户在一个可忍受的时间内
    /// 拿到确定结论。60 s ≈ 网关窗的 2x、实测最慢工具的 3.75x。
    ///
    /// 它与 `SessionController` 既有的 45 s 硬思考超时是**同一条时间线上的
    /// 两个闸门**：45 s 那条在没有任何任务证据时收口（行为不变）；本闸门只在
    /// 「有任务在跑」这一显式证据下把预算延长到 60 s，到点强制释放并留证。
    public static let maxTaskHoldSeconds: TimeInterval = 60

    /// 本轮上行已真正提交。
    public private(set) var committed = false
    /// 上游报告过、且尚未终结的任务 id（有序去重：日志里要看得出先后）。
    public private(set) var outstandingTaskIds: [String] = []
    /// 本轮曾经有过工具任务。用于取证与文案分档，不参与释放判定。
    public private(set) var sawTask = false
    /// 答案音频**真实起播**过（收到 delta / 入队都不算）。
    public private(set) var answerAudioStarted = false
    /// 回合终态屏障（`audio.done`）已到。段落屏障 `audio.segment_done`
    /// **不得**置位本字段——那正是 ESS-969/971 分开两个 kind 的全部意义。
    public private(set) var turnBarrierDone = false
    /// 本轮音频已播完（真实播放终局，成功或失败都算「不再出声」）。
    public private(set) var playbackEnded = false
    /// 显式终态。一旦置位不可逆（本轮不会再回到思考/回答）。
    public private(set) var terminal: ToolTurnTerminal?
    /// 首个任务被登记的时刻（毫秒）。上界计时以它为起点。
    public private(set) var firstTaskAtMs: Int64?
    /// 强制释放的原因（`nil` 表示没发生过）。留证用。
    public private(set) var forcedReleaseReason: String?

    public init() {}

    // MARK: - 事件入口（全部返回「聚合是否真的变了」，便于调用方只在变更时留证）

    /// 本轮上行真正提交。
    @discardableResult
    public mutating func noteCommitted() -> Bool {
        guard !committed else { return false }
        committed = true
        return true
    }

    /// 上游任务生命周期。`terminal` 由网关按上游 `task.*` 事件判定后下发；
    /// 客户端不再自己猜哪些 status 算终态——那会让两侧口径漂移。
    ///
    /// - Returns: 聚合是否变化（新任务登记 / 已知任务终结）。
    @discardableResult
    public mutating func noteTask(id: String, terminal isTerminal: Bool, atMs: Int64) -> Bool {
        guard !id.isEmpty else { return false }
        guard terminal == nil else { return false }   // 已终态的回合不再吸收任务事件
        if isTerminal {
            guard let index = outstandingTaskIds.firstIndex(of: id) else { return false }
            outstandingTaskIds.remove(at: index)
            return true
        }
        guard !outstandingTaskIds.contains(id) else { return false }
        outstandingTaskIds.append(id)
        sawTask = true
        if firstTaskAtMs == nil { firstTaskAtMs = atMs }
        return true
    }

    /// 答案音频真实起播。
    @discardableResult
    public mutating func noteAnswerAudioStarted() -> Bool {
        guard !answerAudioStarted || playbackEnded else { return false }
        answerAudioStarted = true
        // 第二段（工具结果）起播时把上一段的播完标记清掉——回合没结束，
        // 「播完了」这个事实只属于上一段。
        playbackEnded = false
        return true
    }

    /// 回合终态屏障到达（`audio.done`）。
    @discardableResult
    public mutating func noteTurnBarrierDone() -> Bool {
        guard !turnBarrierDone else { return false }
        turnBarrierDone = true
        return true
    }

    /// 本轮音频播完（真实播放终局）。
    @discardableResult
    public mutating func notePlaybackEnded() -> Bool {
        guard !playbackEnded else { return false }
        playbackEnded = true
        return true
    }

    /// 显式终态。取消 / 失败 / 超时。先到的终态胜出，不被后到的覆盖。
    @discardableResult
    public mutating func noteTerminal(_ kind: ToolTurnTerminal) -> Bool {
        guard terminal == nil else { return false }
        terminal = kind
        outstandingTaskIds.removeAll()
        return true
    }

    /// 上界到点：强制释放任务闸门并留证。**不**置显式终态——释放之后
    /// 回合按既有路径正常收口（屏障 + 播完齐了就回聆听）。
    @discardableResult
    public mutating func forceReleaseTasks(reason: String) -> Bool {
        guard !outstandingTaskIds.isEmpty else { return false }
        outstandingTaskIds.removeAll()
        forcedReleaseReason = reason
        return true
    }

    // MARK: - 派生结论

    /// 是否仍有未终结的工具任务在跑。
    public var isHoldingForTask: Bool {
        terminal == nil && !outstandingTaskIds.isEmpty
    }

    /// 回合的音频侧是否已经收口（屏障 + 播完，两者缺一不可）。
    public var audioSettled: Bool {
        turnBarrierDone && playbackEnded
    }

    /// UI 应该显示的聚合态。这是 ESS-1097 验收 1–4 的可判定形式。
    public var uiState: ToolTurnUIState {
        if terminal != nil { return .terminal }
        if !committed { return .listening }
        if answerAudioStarted && !playbackEnded { return .answering }
        if audioSettled && !isHoldingForTask { return .listening }
        return .thinking
    }

    /// 是否允许**自动**开下一轮（新 generation）。用户显式打断/退出走各自的
    /// 路径，不问这道闸门——「不许自动」与「不许用户主动」是两件事。
    public var mayAutoStartNextTurn: Bool {
        if terminal != nil { return true }
        if !committed { return true }
        return audioSettled && !isHoldingForTask
    }

    /// 任务闸门已经保持了多久（毫秒）。`nil` 表示本轮没有任务证据。
    public func taskHoldElapsedMs(nowMs: Int64) -> Int64? {
        guard let firstTaskAtMs else { return nil }
        return max(0, nowMs - firstTaskAtMs)
    }

    /// 取证串：一行说清「为什么现在不回聆听」。
    public var evidence: String {
        "committed=\(committed) tasks=\(outstandingTaskIds.count)"
            + " saw_task=\(sawTask) answer_started=\(answerAudioStarted)"
            + " barrier=\(turnBarrierDone) playback_ended=\(playbackEnded)"
            + " terminal=\(terminal?.rawValue ?? "none")"
            + " forced_release=\(forcedReleaseReason ?? "none")"
    }
}
