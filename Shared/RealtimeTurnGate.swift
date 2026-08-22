import Foundation

/// ESS-960：判定一个上行信封有没有资格（重新）打开实时通道。
///
/// 2026-08-21 真机事故的客户端侧根因：`PhoneRealtimeSession.openIfNeeded`
/// 把 `.failed` 漏进了 `default` 分支，而它由**每一个上行音频帧**驱动
/// （`forward(_:)` 的 `.audioAppend` 分支）。回合一旦判死，Watch 并不知情、
/// 继续送帧，于是每帧重建一次 transport → 新 WSS → Gateway 新建
/// `nextUplinkSequence = 0` 的会话 → 客户端 sequence 已是 N →
/// `ERR_STREAM_SEQUENCE(retriable: false)` → 再来一遍。
///
/// 实测 255 次握手 / 47 秒，节奏 ≈184ms 正是上行帧节奏——**零退避不是因为
/// 退避没写，而是根本不存在「重试」这个概念，它是被上行帧泵出来的。**
///
/// 判定放在 `Shared/` 而不是 `iOS/`：`iOS/` 没有单测 target，留在那里这条
/// 逻辑就只能靠人眼复核（ESS-751 已经在同一个位置吃过一次亏）。
///
/// ---
///
/// ESS-987（2026-08-22 真机 `request_id=01a02744-06e5`）：ESS-960 挡住了
/// 255 次**真实握手**，但没挡住上游继续尝试——闸门只负责拦，不负责让调用方
/// 停下，于是 40 条 / 4 秒（≈10.6 条/秒）的 `realtime_reopen_suppressed`
/// 逐帧刷屏，全天 236 条。本轮把三件事补齐，全部落在这里而不是 `iOS/`：
///
/// 1. **`admit(...)` 取代裸判定**：调用方拿到的是「收不收这个信封」的最终
///    结论 + 「该打哪几条日志」，`iOS/` 侧不再有任何判定逻辑；
/// 2. **日志收敛**：同一回合首次压制打一条，其余只计数，回合收口时打一条
///    `suppressed_total=N` 的汇总——每个回合最多两条；
/// 3. **握手重试退避**：ESS-960 保留的有界握手重试此前零退避（同样是被帧泵
///    出来的），现在按 `2^n` 退避；`audio.commit` 是一轮的最后机会，不受退避
///    约束（否则末帧被退避窗口吃掉，用户这一轮直接没有结果）。
struct RealtimeTurnGate: Equatable {
    /// 一个回合的身份。Gateway 侧的会话就是按这一对建立的。
    struct Turn: Hashable {
        let requestId: String
        let sessionId: String

        init(requestId: String, sessionId: String) {
            self.requestId = requestId
            self.sessionId = sessionId
        }
    }

    enum Decision: Equatable {
        /// 放行：可以建立通道。
        case open
        /// 拦下：该回合已判终态，不得再复活。`reason` 进日志。
        case suppress(reason: String)
    }

    /// ESS-987：信封为什么会走到闸门。语义差别决定退避是否适用。
    enum Trigger: Equatable {
        /// `stream.start`——Watch 表达「我要开新一轮」的唯一显式信号。
        case turnStart
        /// `audio.append`——被录音节奏泵动的帧，正是刷屏的来源。
        case uplinkFrame
        /// `audio.commit`——一轮的最后一帧。**不受退避约束**：退避的目的是
        /// 压住高频空转，不是把用户这一轮的收口吃掉。
        case turnCommit
        /// `playback.started` / `playback.ended` 回执。
        case receipt
    }

    /// ESS-987：闸门要求调用方打的日志。调用方只负责把它翻译成平台日志格式，
    /// 不做任何「要不要打」的判断——那正是逐帧刷屏的成因。
    enum LogLine: Equatable {
        /// 该回合**首次**被压制。
        case suppressed(requestId: String, sessionId: String, reason: String, closedTurns: Int)
        /// 该回合的压制汇总（收口时打，`total` 含首次那一条）。
        case suppressedSummary(requestId: String, sessionId: String, reason: String, total: Int)
    }

    /// `admit(...)` 的结论：收不收，以及顺带要打的日志。
    struct Verdict: Equatable {
        let isAdmitted: Bool
        let logs: [LogLine]
    }

    private struct Entry: Equatable {
        let turn: Turn
        var handshakeFailures: Int
        var closed: Bool
        /// 最近一次失败的时间，退避窗口的起点。`nil` 表示还没失败过。
        var lastFailureAt: Double?
        /// 本回合累计被压制多少次（收口后清零）。
        var suppressionCount: Int
        /// 首次压制是否已经打过日志。**一旦为 true 就不再回退**——否则每次
        /// 收口都会重新打一条「首次」，刷屏换个频率回来。
        var didLogFirstSuppression: Bool
        var lastSuppressionReason: String
    }

    /// 最近若干个回合的闸门状态。
    ///
    /// **有界**：只保留最近 `capacity` 个。一个永不清理的集合正是
    /// ESS-742/743/744 那一类缺陷；超出容量的老回合早就不会再有帧进来。
    private var entries: [Entry] = []
    /// 被容量挤出去、但压制账还没收口的回合。挤出不等于证据可以丢——
    /// 下一次 `flushSuppressionSummaries()` 仍要把它们报出来。同样有界。
    private var pendingSummaries: [LogLine] = []
    private let capacity: Int
    /// 握手连续失败多少次后封死该回合。
    private let maxHandshakeAttempts: Int
    /// 握手退避基数：第 n 次失败后要等 `base * 2^(n-1)` 秒才允许再试。
    private let handshakeBackoffBase: Double

    init(capacity: Int = 8, maxHandshakeAttempts: Int = 3, handshakeBackoffBase: Double = 0.5) {
        self.capacity = max(1, capacity)
        self.maxHandshakeAttempts = max(1, maxHandshakeAttempts)
        self.handshakeBackoffBase = max(0, handshakeBackoffBase)
    }

    /// 通道进入失败态时调用。
    ///
    /// - Parameter wasActive: 失败前这条通道是否**已经握手成功**（`.active`）。
    /// - Parameter nowSeconds: 单调时间戳，退避窗口的起点。
    ///
    /// 这个区分是 2026-08-21 18:27 真机事故教的：当时网关因 ESS-886 复发对
    /// **所有**握手回 401（`missing_bearer`），客户端拿到 `-1011`，而上一版
    /// 闸门把「第一次握手就被拒」也当成终态，于是整轮当场判死、用户连说话的
    /// 机会都没有。
    ///
    /// 「token 单次使用、重开必然失败」这条理由**只适用于已经握手成功过的
    /// 通道**——那时 token 确实被消耗了。握手本身被拒时 token 压根没进过
    /// 网关的账，重试是合理的；但也不能无界重试（那就退回 255 次风暴），
    /// 所以给一个小的上限，ESS-987 起再叠一层退避。
    mutating func noteFailure(
        requestId: String, sessionId: String, wasActive: Bool, nowSeconds: Double
    ) {
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        if let index = entries.firstIndex(where: { $0.turn == turn }) {
            entries[index].lastFailureAt = nowSeconds
            if wasActive {
                entries[index].closed = true
            } else {
                entries[index].handshakeFailures += 1
                if entries[index].handshakeFailures >= maxHandshakeAttempts {
                    entries[index].closed = true
                }
            }
            return
        }
        entries.append(
            Entry(
                turn: turn,
                handshakeFailures: wasActive ? 0 : 1,
                closed: wasActive || maxHandshakeAttempts <= 1,
                lastFailureAt: nowSeconds,
                suppressionCount: 0,
                didLogFirstSuppression: false,
                lastSuppressionReason: ""
            )
        )
        evictOverflow()
    }

    /// 新回合显式开始（`stream.start`）时调用：解除该回合的封印。
    ///
    /// `stream.start` 是 Watch 表达「我要开一轮新的」的唯一信号，与被上行帧
    /// 泵出来的隐式重开有本质区别，必须放行——否则 request_id 复用时新回合
    /// 会被上一轮的判死结论误伤。
    ///
    /// ESS-987 起生产路径走 `admit(..., trigger: .turnStart)`（它还要顺带把
    /// 上一轮的压制账收口）；本方法保留为解封语义的最小操作，ESS-960 的用例
    /// 继续钉它。
    mutating func noteTurnStart(requestId: String, sessionId: String) {
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        entries.removeAll { $0.turn == turn }
    }

    /// 这个信封能不能打开通道（**只回答终态问题**）。
    ///
    /// ESS-987 起生产路径走 `admit(...)`：退避与日志收敛都在那里。本方法保留
    /// 为终态语义的纯判定，ESS-960 的用例继续钉它。
    ///
    /// - Parameter isTurnStart: 该信封是否为 `stream.start`。
    func decide(requestId: String, sessionId: String, isTurnStart: Bool) -> Decision {
        if isTurnStart { return .open }
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        guard let entry = entries.first(where: { $0.turn == turn }), entry.closed else {
            return .open
        }
        return .suppress(reason: "turn_closed_terminal")
    }

    /// ESS-987：生产路径的唯一入口。返回「收不收这个信封」+「要打哪几条日志」。
    ///
    /// 调用方（`PhoneRealtimeSession.forward`）必须在**任何可能建通道的动作
    /// 之前**调用它，`isAdmitted == false` 时直接丢弃该信封并结束——不再往下
    /// 走 `openIfNeeded`，也不再落到 `transport.send`（后者会把一个已判死回合
    /// 的帧发到**下一轮**的 transport 上，见 ESS-987 讨论）。
    mutating func admit(
        requestId: String, sessionId: String, trigger: Trigger, nowSeconds: Double
    ) -> Verdict {
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        if trigger == .turnStart {
            // 新一轮开始：先把上一轮的压制账收口，再解封本回合。
            let logs = flushSuppressionSummaries()
            entries.removeAll { $0.turn == turn }
            return Verdict(isAdmitted: true, logs: logs)
        }
        guard let index = entries.firstIndex(where: { $0.turn == turn }) else {
            return Verdict(isAdmitted: true, logs: [])
        }
        guard let reason = suppressionReason(for: entries[index], trigger: trigger, now: nowSeconds)
        else {
            return Verdict(isAdmitted: true, logs: [])
        }
        entries[index].suppressionCount += 1
        entries[index].lastSuppressionReason = reason
        guard !entries[index].didLogFirstSuppression else {
            // 已经打过首条——只计数，收口时汇总。这就是 40 条/4 秒变 2 条的地方。
            return Verdict(isAdmitted: false, logs: [])
        }
        entries[index].didLogFirstSuppression = true
        return Verdict(
            isAdmitted: false,
            logs: [
                .suppressed(
                    requestId: requestId, sessionId: sessionId,
                    reason: reason, closedTurns: closedTurnCount
                )
            ]
        )
    }

    /// 收口：把各回合累计的压制次数汇总成日志并清零。
    ///
    /// 调用点是回合边界（`endTurn` / `lifecycleInterrupted` / 下一个
    /// `stream.start`）。只压制过一次的回合不再出汇总——首条日志已经说完了，
    /// 再补一条 `total=1` 是纯噪音。
    @discardableResult
    mutating func flushSuppressionSummaries() -> [LogLine] {
        var logs = pendingSummaries
        pendingSummaries.removeAll()
        for index in entries.indices where entries[index].suppressionCount > 0 {
            if entries[index].suppressionCount > 1 {
                logs.append(summaryLine(for: entries[index]))
            }
            entries[index].suppressionCount = 0
        }
        return logs
    }

    /// 取证用：当前封死了几个回合。
    var closedTurnCount: Int { entries.filter(\.closed).count }

    /// 取证用：某回合当前累计了多少条尚未收口的压制。
    func pendingSuppressionCount(requestId: String, sessionId: String) -> Int {
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        return entries.first(where: { $0.turn == turn })?.suppressionCount ?? 0
    }

    private func suppressionReason(for entry: Entry, trigger: Trigger, now: Double) -> String? {
        if entry.closed { return "turn_closed_terminal" }
        // ESS-987：握手重试必须有退避。`audio.commit` 是一轮的最后机会，
        // 放它过去——退避要压的是高频空转，不是用户这一轮的收口。
        guard trigger != .turnCommit,
              entry.handshakeFailures > 0,
              let last = entry.lastFailureAt,
              now - last < backoffInterval(afterFailures: entry.handshakeFailures)
        else { return nil }
        return "handshake_backoff"
    }

    /// 第 n 次握手失败后的退避时长：`base * 2^(n-1)`，指数退避。
    private func backoffInterval(afterFailures failures: Int) -> Double {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 16)
        return handshakeBackoffBase * pow(2, Double(exponent))
    }

    private func summaryLine(for entry: Entry) -> LogLine {
        .suppressedSummary(
            requestId: entry.turn.requestId,
            sessionId: entry.turn.sessionId,
            reason: entry.lastSuppressionReason,
            total: entry.suppressionCount
        )
    }

    /// 超容量时挤出最老的回合。被挤出的回合若还欠一条汇总，转存到
    /// `pendingSummaries`——挤出是容量决策，不是丢证据的理由。
    private mutating func evictOverflow() {
        guard entries.count > capacity else { return }
        let overflow = entries.count - capacity
        for entry in entries.prefix(overflow) where entry.suppressionCount > 1 {
            pendingSummaries.append(summaryLine(for: entry))
        }
        entries.removeFirst(overflow)
        if pendingSummaries.count > capacity {
            pendingSummaries.removeFirst(pendingSummaries.count - capacity)
        }
    }
}
