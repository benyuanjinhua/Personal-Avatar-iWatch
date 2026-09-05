import Dispatch
import Foundation

// MARK: - ESS-1139 实时套接字生命周期
//
// 事故形态（2026-09-05 真机，三条用例全部无返回）：
//   • 天气：任务正常进入 Codex，约 10s 产出首答案；**客户端在任务启动后约
//     1.2s 关闭 WSS**，其后所有帧被上游按 `socket_closed` 丢弃；
//   • 知识库：任务 4.75s 就有首答案，客户端 11.5s 关闭 WSS，最终答案送不到；
//   • 两条链路都在阶段播报之后出现 `mute` / `socket_closed`。
//
// `mute` 是网关 `qwen-agent-transport.mjs` 的**会话拆除**动作
// （`close()` → `ws.send({type:'mute'})` → `ws.terminate()`），它只会因为
// 下游（iPhone）那条 WSS 先断掉而发生。也就是说：**杀死这三个回合的是客户端
// 自己的一次关闭动作，不是上游超时**。
//
// 客户端为什么会关：套接字是**回合级**的。
// `PhoneRealtimeSession.openIfNeeded` 一见到新的 `request_id` 就
// `currentTransport?.close(reason: "supersede")`，而「要不要开新一轮」整个
// 判定只存在于 Watch 的 `ToolTurnAggregate`（ESS-1097），且只由**已经到达并
// 被接受**的 `task.state` / `tool_call_pending` 武装。任何一条绕过或抢在那个
// 证据之前的路径——阶段播报的回合级 `audio.done`、录音停止、UI 状态切换、
// 本地超时——都会让 iPhone 无条件关掉一条**上游还在干活**的 socket。
//
// 本文件是那条不变量的**唯一判定点**，放在 `Shared/` 是因为 `iOS/` 没有单测
// target（同 `RealtimeTurnGate` / `RealtimeDownlinkRelay` 的既有分工）：
//
//   **上游工作未终结前，客户端不得因回合切换、UI 状态、本地超时或生命周期
//   事件主动关闭这条 WSS；用户显式退出与传输真死除外，且一切保持有界。**
//
// 有界性刻意按**静默时长**而不是固定时长计（ESS-1111 的同一条教训）：24s 的
// Codex 任务绝大多数帧是重复的 `running`，用固定时长兜底等于把事故装回去。

// MARK: - 关闭动因

/// 一次**客户端主动**关闭实时套接字的动因。
///
/// 分类的唯一意义是回答一个问题：这次关闭**压不压得过**「上游还有活在跑」
/// 这个事实。用字符串 reason 现场解析是不行的——调用点各写各的，判定就会
/// 随着一次手滑的措辞漂移。
public enum RealtimeSocketCloseCause: String, Equatable, Sendable, CaseIterable {
    /// 用户显式退出会话 / 取消本轮。用户的意图压过一切。
    case userExit = "user_exit"
    /// 用户打断（点球 / 语音）。换代由 `cancel` 承担，socket 该关就关。
    case bargeIn = "barge_in"
    /// 传输已经死了（WSS 报错 / 心跳失败）。socket 本来就没了，"关闭"只是记账。
    case transportFailure = "transport_failure"
    /// 新一轮 generation 要顶掉旧回合（`openIfNeeded` 的 supersede）。
    case turnSupersede = "turn_supersede"
    /// UI / 会话状态切换（录音停止、阶段播报播完、回到聆听）。
    case uiStateChange = "ui_state_change"
    /// 客户端自己的有界等待到点。
    case localTimeout = "local_timeout"
    /// 前后台切换、可达性丢失一类的生命周期事件。
    case lifecycle = "lifecycle"

    /// 这次关闭是否**压过**在飞的上游工作。
    ///
    /// 只有三种：用户显式退出、用户打断、传输真的死了。其余四种全部是
    /// 「客户端自己的状态变了」——它们没有资格替上游宣布任务结束，这正是
    /// ESS-1139 三条用例共同的死因。
    public var overridesInFlightUpstreamWork: Bool {
        switch self {
        case .userExit, .bargeIn, .transportFailure: return true
        case .turnSupersede, .uiStateChange, .localTimeout, .lifecycle: return false
        }
    }
}

// MARK: - 上游工作账本

/// 这条 socket 上**还有没有上游工作在跑**的唯一账本。
///
/// 与 `ToolTurnAggregate` 的分工是刻意的，两者不可互相替代：
/// - `ToolTurnAggregate` 回答「**这一轮**该给用户看什么相位、能不能开下一轮」，
///   它是 Watch 的展示与回合语义，随 `startNextTurn` 一起被重置；
/// - 本账本回答「**这条 socket** 关得掉吗」，它随 socket 存活，回合重置动不了它。
///   ESS-1139 的三条用例里丢结果的正是这条边：Watch 那边已经重置进下一轮，
///   而 iPhone 手上那条 socket 上的任务还在跑。
public struct UpstreamWorkLedger: Equatable, Sendable {

    /// 未终结任务集合。`Set` 而非计数：同一 taskId 的重复 `running` 不能累加，
    /// 否则一次终态减不回 0，socket 就永远关不掉（另一种形式的卡死）。
    public private(set) var outstandingTasks: Set<String> = []
    /// 本 socket 见过的全部 taskId（取证用，终态后不删）。
    public private(set) var seenTasks: Set<String> = []
    /// `tool_call_pending` 闩锁：上游宣告要调工具但还没有任务号。
    /// 与 `ToolTurnAggregate` 同一口径——**任何 taskId 出现即解除**。
    public private(set) var toolCallPending = false
    /// 本 socket 累计收到的合法上游活动帧数（取证用）。
    public private(set) var activityFrames = 0
    /// 最近一次合法上游活动的时刻。有界性按**它**计，不按开始时刻计。
    public private(set) var lastActivityAtMs: Int64?
    /// 第一次出现「有活在跑」的时刻，绝对上限的起点。
    public private(set) var firstOutstandingAtMs: Int64?
    /// 上游宣布过本回合终态（回合级 `audio.done` / 网关明确失败）。
    public private(set) var sawTurnTerminal = false

    public init() {}

    /// 此刻还有没有上游工作在跑。
    public var hasOutstandingWork: Bool { !outstandingTasks.isEmpty || toolCallPending }

    /// 本 socket 是否出现过任何工具/任务证据（取证与日志用）。
    public var hasUpstreamWorkEvidence: Bool { !seenTasks.isEmpty || activityFrames > 0 }

    // MARK: 记账

    /// 一帧 `task.state`。`taskId == nil` 表示 `tool_call_pending` 这类
    /// 还没有任务号的信号。
    ///
    /// `status` **不做白名单**：不认识的取值一律按非终态处理。把没见过的状态
    /// 当终态，等于回到本单要修的那个 bug。
    public mutating func noteTaskState(taskId: String?, status: String, atMs: Int64) {
        activityFrames += 1
        lastActivityAtMs = atMs
        if let taskId {
            seenTasks.insert(taskId)
            // 任务号一出现，闩锁就完成了它的全部使命（ESS-1098 的同一口径）。
            toolCallPending = false
            if ToolTaskStatus(rawValue: status).isTerminal {
                outstandingTasks.remove(taskId)
            } else {
                outstandingTasks.insert(taskId)
            }
        } else {
            switch status.lowercased() {
            case "resolved", "tool_call_resolved", "completed", "done":
                toolCallPending = false
            default:
                toolCallPending = true
            }
        }
        if hasOutstandingWork, firstOutstandingAtMs == nil {
            firstOutstandingAtMs = atMs
        }
        if !hasOutstandingWork {
            firstOutstandingAtMs = nil
        }
    }

    /// 回合级终态（`audio.done`）到达。
    ///
    /// **刻意不清空未结任务**：ESS-1139 天气用例里回合级 `audio.done` 恰恰是
    /// 阶段播报的收口，而 Codex 任务此后还要跑 10s。用一条音频事件去宣布
    /// 任务结束，正是这条 socket 被提前关掉的那一步。
    public mutating func noteTurnTerminal(atMs: Int64) {
        sawTurnTerminal = true
        lastActivityAtMs = atMs
    }

    /// 上游/网关明确判死这条 socket（不可重试错误、cancel.ack、会话结束）。
    /// 此后不会再有任何上游事实，账本如实清空，socket 该关就关。
    public mutating func noteUpstreamSettled(atMs: Int64) {
        outstandingTasks.removeAll()
        toolCallPending = false
        lastActivityAtMs = atMs
        firstOutstandingAtMs = nil
    }

    /// 结构化日志的一行摘要。字段名与 `ToolTurnAggregate.logDetail`
    /// 及网关 `downlink_task_state` 对齐，真机日志才能按 request/task 串起来。
    public var logDetail: String {
        "outstanding_tasks=\(outstandingTasks.count)"
            + " seen_tasks=\(seenTasks.count)"
            + " tool_call_pending=\(toolCallPending)"
            + " turn_terminal=\(sawTurnTerminal)"
            + " activity_frames=\(activityFrames)"
    }
}

// MARK: - 回合终态分类

/// 一条到达 Watch 的回合级 `audio.done` 到底是什么。
public enum RealtimeTurnTerminalKind: Equatable, Sendable {
    /// 真的答完了：屏障落定、可以收口、可以开下一轮。
    case turnTerminal
    /// 只是**一段**：上游还有活在跑，回合必须继续等下一段。
    case segmentBoundary
}

/// 「这条回合终态该按终态还是按段落处理」的唯一判定。
///
/// 判据由 iPhone 在**有序的** WSS 上产出并随帧下发；Watch 只消费，不再靠
/// 「`task.state` 有没有先到」这个 WCSession 不保证的顺序去猜。逻辑放在
/// `Shared/` 是因为它的消费点在 `Watch/WatchSettingsStore` 的 WCSession
/// 委托里——那里没有单测接缝，留在那里就只能靠人眼复核。
public enum RealtimeTurnTerminalClassifier {

    /// - Parameter upstreamWorkOutstanding: 帧上的 `upstream_work_outstanding`。
    ///   `nil` = 老 iPhone 进程没带这个字段，退回本单之前的路径（按终态处理）。
    public static func classify(upstreamWorkOutstanding: Bool?) -> RealtimeTurnTerminalKind {
        upstreamWorkOutstanding == true ? .segmentBoundary : .turnTerminal
    }

    /// 同一帧顺带喂给回合聚合体的工具证据 `status`。
    ///
    /// 它把「上游还有没有活」这件事一次性说清楚，**两个方向都权威**：
    /// - `tool_call_pending`：还有活 ⇒ 聚合体挂住回合，有界性从 45s 的「等
    ///   回答」预算切到 180s 的工具绝对上限；
    /// - `tool_call_resolved`：没活了 ⇒ 解除闩锁。少了这一半，一个从未收到
    ///   真实 `task.state` 的回合会被自己挂到绝对上限判失败。
    ///
    /// 字段缺席时返回 `nil`：不猜、不喂，一个字都不改。
    public static func toolEvidenceStatus(upstreamWorkOutstanding: Bool?) -> String? {
        guard let upstreamWorkOutstanding else { return nil }
        return upstreamWorkOutstanding ? "tool_call_pending" : "tool_call_resolved"
    }
}

// MARK: - 判定

/// 一次关闭请求的裁决。
public enum RealtimeSocketCloseDecision: Equatable, Sendable {
    /// 关掉。`detail` 进日志，说明为什么这次关闭是正当的。
    case close(detail: String)
    /// 不关：上游还有活在跑。`detail` 进日志，说明卡在哪一面。
    case hold(detail: String)

    public var isClose: Bool { if case .close = self { return true }; return false }
    public var detail: String {
        switch self {
        case .close(let d), .hold(let d): return d
        }
    }
}

/// 「这条 socket 现在关得掉吗」的唯一判定。
public enum RealtimeSocketLifetimePolicy {

    /// 上游**静默**多久之后，即使账本上还挂着未结任务也放行关闭。
    ///
    /// 取 30s：网关对单个工具调用的窗口是 `toolCallWindowMs = 30_000`
    /// （`AudioRealtimeGateway/qwen-agent-transport.mjs`），一个还活着的任务
    /// 至少每秒有一帧 `running`，静默 30s 意味着上游那一头已经没人说话了。
    /// 按静默而不是按总时长计，是 ESS-1111 钉住的那条：24s 任务的绝大多数帧
    /// 是重复的 `running`，用固定总时长兜底等于把事故装回去。
    public static let upstreamSilenceBudgetMs: Int64 = 30_000

    /// 绝对上限：从第一次出现未结任务算起，最多把一条 socket 保住这么久。
    ///
    /// 取 180s，与 `SessionController.toolTurnHardTimeoutSeconds` 同值——
    /// 会话层那条硬上限到点时回合已判失败，socket 再留着没有意义。
    /// 有了它，「保住 socket」在任何异常上游下都不会变成永久泄漏。
    public static let absoluteHoldCapMs: Int64 = 180_000

    /// 生产用单调时钟（毫秒）。测试一律注入固定值，不碰它。
    ///
    /// `DispatchTime.uptimeNanoseconds` 单调不减；**先除后转**，理由同
    /// `MonotonicDuration`——watchOS arm64_32 上 `Int` 只有 32 位，先转后除
    /// 会在 2.147s 处陷入。
    public static func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// - Parameters:
    ///   - cause: 这次关闭的动因。
    ///   - ledger: 这条 socket 的上游工作账本。
    ///   - nowMs: 单调时钟毫秒（测试注入）。
    public static func decide(
        cause: RealtimeSocketCloseCause,
        ledger: UpstreamWorkLedger,
        nowMs: Int64
    ) -> RealtimeSocketCloseDecision {
        let scope = "cause=\(cause.rawValue) \(ledger.logDetail)"
        if cause.overridesInFlightUpstreamWork {
            return .close(detail: "\(scope) disposition=cause_overrides")
        }
        guard ledger.hasOutstandingWork else {
            return .close(detail: "\(scope) disposition=no_outstanding_work")
        }
        if let last = ledger.lastActivityAtMs, nowMs - last >= upstreamSilenceBudgetMs {
            return .close(
                detail: "\(scope) disposition=upstream_silent silence_ms=\(nowMs - last)"
            )
        }
        if let first = ledger.firstOutstandingAtMs, nowMs - first >= absoluteHoldCapMs {
            return .close(
                detail: "\(scope) disposition=hold_cap_reached held_ms=\(nowMs - first)"
            )
        }
        let heldMs = ledger.firstOutstandingAtMs.map { nowMs - $0 } ?? 0
        return .hold(detail: "\(scope) disposition=upstream_work_in_flight held_ms=\(heldMs)")
    }
}
