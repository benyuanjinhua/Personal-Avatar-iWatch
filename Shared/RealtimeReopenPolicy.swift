import Foundation

/// ESS-960：**一个已经终结的回合不得被上行帧复活，一个正在服务的回合不得被
/// 别的回合的帧顶掉。**
///
/// 事故形态（真机 L1）：`PhoneRealtimeSession.openIfNeeded` 的 `switch` 只把
/// `.active` / `.connecting` 且 id 相同的两种情形短路掉，`.failed` 落进
/// `default: break` 继续往下建 transport；而 `openIfNeeded` 由**每一个**
/// `audio.append` 驱动（Watch 上行 ~184ms 一帧）。回合失败后 Watch 并不知情、
/// 继续送帧 → 每帧重建一次 transport → 新 WSS → Gateway 新建
/// `nextUplinkSequence=0` 的会话 → 客户端 sequence 已是 N →
/// `ERR_STREAM_SEQUENCE(retriable:false)` → 再次 `.failed` → 下一帧重来。
/// 观测到 47 秒内 255 次握手，节奏 ≈ 184ms/次，正是上行帧节奏——
/// 它不是「退避没写」，而是**根本不存在「重试」这个概念**：风暴是被帧泵出来的。
///
/// 本类型是这条判定的**唯一**真值来源，并且刻意做成 `Shared/` 里的纯值类型：
/// `iOS/` 没有单测 target（同 `RealtimeDownlinkRelay` 的 ESS-751 先例），
/// 判定逻辑留在 `PhoneRealtimeSession` 里就只能靠人眼复核，而这正是本缺陷
/// 能合进 main 的原因。
///
/// ESS-962 架构复审整改（两条阻断，都已复核成立）：
///
/// * **阻断 1**：初版对**任何** `.streamStart` 都先清空终态再放行，等于
///   「终态不是终态」——与验收标准「`retriable:false` 之后同 requestId 不再
///   重开」直接冲突。现在终态记账**不因任何触发被清除**，同一 TurnKey 的
///   `.streamStart` 一样 suppress。
/// * **阻断 2**：初版只存**一个** `terminalTurn`，新回合 `.streamStart` 会把它
///   清成 nil；此后旧回合的迟到帧既不命中 reuse、也无终态可命中，最终走
///   `.open`，在生产路径上会关掉**正在服务新回合**的 transport 再去建旧回合的。
///   现在改为有界终态集合 + 「活跃回合不得被外来帧顶掉」两道防线。
struct RealtimeReopenPolicy: Equatable, Sendable {

    /// 终态集合的容量上限。超出按 FIFO 淘汰最旧的一条。
    ///
    /// 取 8 的依据：终态只可能由「回合失败」产生，而一次会话里的回合是人说话
    /// 的节奏（秒级），8 条足以覆盖任何现实的迟到帧窗口；不设上限则是一个随
    /// 会话时长单调增长的集合。淘汰不是静默的——`evictedTerminalCount` 会进
    /// `realtime_turn_terminated` 的日志，口径可查。
    static let terminalHistoryLimit = 8

    /// 回合身份。Gateway 侧 `(request_id, session_id)` 二元组即一个回合。
    struct TurnKey: Hashable, Sendable {
        let requestId: String
        let sessionId: String

        init(requestId: String, sessionId: String) {
            self.requestId = requestId
            self.sessionId = sessionId
        }
    }

    /// 触发一次 open 判定的上行来源。**区分这两者是本修复的全部要点。**
    enum Trigger: String, Sendable {
        /// `stream.start` —— 回合的显式起点，每回合恰好一次。
        case streamStart = "stream_start"
        /// `audio.append` / `audio.commit` / 播放回执 —— 由帧节奏驱动，
        /// 一个回合内成百上千次。绝不允许它把已终结的回合复活，
        /// 也绝不允许它把正在服务另一个回合的 transport 顶掉。
        case uplinkFrame = "uplink_frame"
    }

    /// `PhoneRealtimeSession.State` 的镜像。`Shared/` 不依赖 `iOS/`，
    /// 由调用方做一次投影；`.failed` 不带 id，回合身份由终态集合记账。
    enum SessionState: Equatable, Sendable {
        case idle
        case connecting(TurnKey)
        case active(TurnKey)
        case cancelled
        case failed

        /// 当前是否有一个正在建立/服务中的回合，以及它是谁。
        var liveTurn: TurnKey? {
            switch self {
            case .connecting(let key), .active(let key):
                return key
            case .idle, .cancelled, .failed:
                return nil
            }
        }
    }

    enum Decision: Equatable, Sendable {
        /// 需要新建 transport。
        case open
        /// 当前 transport 已经在服务同一个回合，直接复用，不建新的。
        case reuseExisting
        /// 不得建立。`reason` 直接进日志取证。
        case suppress(reason: String)
    }

    /// 抑制原因（字符串常量集中一处，日志与断言不会各写各的）。
    enum SuppressReason {
        /// 该回合已判终态，永不重开。
        static let turnTerminated = "turn_terminated"
        /// 有别的回合正在被服务，外来帧不得顶掉它。
        static let foreignTurnLive = "foreign_turn_live"
    }

    /// 已判终态、不可再重开的回合（FIFO，容量 `terminalHistoryLimit`）。
    private(set) var terminalTurns: [TurnKey] = []
    /// 被拦下的重开次数——把「风暴规模」变成可断言的数，而不是靠人数日志。
    private(set) var suppressedCount = 0
    /// 因容量上限被淘汰的终态条数。不为 0 就意味着「更早的回合已不受保护」，
    /// 必须能在日志里看见，不做静默截断。
    private(set) var evictedTerminalCount = 0

    init() {}

    /// 该回合走到终态（通道失败 / Gateway `retriable:false` / 显式回退）。
    ///
    /// ESS-960 缺陷 2：服务端明确说了「别重试」，客户端此前只是关掉本会话
    /// （`AudioRealtimeAgentSession.handleTransportFailure`），**没有任何机制
    /// 阻止上层 184ms 后再建一个**。落成终态记账后，重开一律走 `.suppress`，
    /// 且**不因新回合开始而失忆**（ESS-962 阻断 2）。
    mutating func markTerminalFailure(_ key: TurnKey) {
        guard !terminalTurns.contains(key) else { return }
        terminalTurns.append(key)
        while terminalTurns.count > Self.terminalHistoryLimit {
            terminalTurns.removeFirst()
            evictedTerminalCount += 1
        }
    }

    /// 该回合是否已判终态。
    func isTerminated(_ key: TurnKey) -> Bool { terminalTurns.contains(key) }

    /// 判定是否放行一次 open。
    mutating func decide(
        state: SessionState,
        key: TurnKey,
        trigger: Trigger
    ) -> Decision {
        // 1. 当前 transport 就在服务这一个回合——复用，不建新的。
        if state.liveTurn == key { return .reuseExisting }

        // 2. 终态优先于一切触发。ESS-962 阻断 1：`.streamStart` 也不例外，
        //    否则「终态」只是个名字。Watch 每轮 `pressBegan` 都新铸
        //    `UUIDv7`，同 requestId 的 `stream.start` 只可能是重放/重试。
        if terminalTurns.contains(key) {
            suppressedCount += 1
            return .suppress(reason: SuppressReason.turnTerminated)
        }

        // 3. `stream.start` 是回合的显式起点，允许顶掉上一轮——它每回合恰好
        //    一次，做不出帧节奏的风暴。
        if trigger == .streamStart { return .open }

        // 4. ESS-962 阻断 2：有别的回合正在建立/服务时，外来帧一律不得开。
        //    放行等于「关掉正在服务新回合的 socket 去建旧回合的」——迟到帧与
        //    WCSession 重排都能触发，是风暴链路残留的可达入口。
        //    这里刻意 fail-closed：策略层没有代际/时序信息，无法判断哪一个才
        //    是“新”的，猜错的代价是打死一个活着的回合。真正的新回合会带着
        //    自己的 `stream.start` 走分支 3。
        if state.liveTurn != nil {
            suppressedCount += 1
            return .suppress(reason: SuppressReason.foreignTurnLive)
        }

        // 5. 没有在服务的回合、也没判过终态：保留 `stream.start` 丢失时由首帧
        //    懒开链路的既有行为。
        return .open
    }
}
