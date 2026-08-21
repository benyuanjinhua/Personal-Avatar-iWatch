import Foundation

/// ESS-960：**一个已经终结的回合不得被上行帧复活。**
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
struct RealtimeReopenPolicy: Equatable, Sendable {

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
        /// `stream.start` —— 回合的显式起点，每回合恰好一次，
        /// 也是失败之后**唯一**的重开入口。
        case streamStart = "stream_start"
        /// `audio.append` / `audio.commit` / 播放回执 —— 由帧节奏驱动，
        /// 一个回合内成百上千次。绝不允许它把已终结的回合复活。
        case uplinkFrame = "uplink_frame"
    }

    /// `PhoneRealtimeSession.State` 的镜像。`Shared/` 不依赖 `iOS/`，
    /// 由调用方做一次投影；`.failed` 不带 id，回合身份由 `terminalTurn` 记账。
    enum SessionState: Equatable, Sendable {
        case idle
        case connecting(TurnKey)
        case active(TurnKey)
        case cancelled
        case failed
    }

    enum Decision: Equatable, Sendable {
        /// 需要新建 transport。
        case open
        /// 当前 transport 已经在服务同一个回合，直接复用，不建新的。
        case reuseExisting
        /// 该回合已终结，**不得**重开。`reason` 直接进日志取证。
        case suppress(reason: String)
    }

    /// 已判终态、不可再被帧复活的回合。
    private(set) var terminalTurn: TurnKey?
    /// 被拦下的重开次数——把「风暴规模」变成可断言的数，而不是靠人数日志。
    private(set) var suppressedCount = 0

    init() {}

    /// 该回合走到终态（通道失败 / Gateway `retriable:false` / 显式回退）。
    ///
    /// ESS-960 缺陷 2：服务端明确说了「别重试」，客户端此前只是关掉本会话
    /// （`AudioRealtimeAgentSession.handleTransportFailure`），**没有任何机制
    /// 阻止上层 184ms 后再建一个**。落成终态记账后，重开一律走 `.suppress`。
    mutating func markTerminalFailure(_ key: TurnKey) {
        guard terminalTurn != key else { return }
        terminalTurn = key
        suppressedCount = 0
    }

    /// 判定是否放行一次 open。
    mutating func decide(
        state: SessionState,
        key: TurnKey,
        trigger: Trigger
    ) -> Decision {
        switch state {
        case .active(let active) where active == key:
            return .reuseExisting
        case .connecting(let pending) where pending == key:
            return .reuseExisting
        default:
            break
        }
        // 新回合的显式起点：清掉终态记账后放行。这是失败之后唯一的复原路径，
        // 且它每回合只来一次，做不出帧节奏的风暴。
        if trigger == .streamStart {
            terminalTurn = nil
            suppressedCount = 0
            return .open
        }
        if let terminal = terminalTurn, terminal == key {
            suppressedCount += 1
            return .suppress(reason: "turn_terminated")
        }
        return .open
    }
}
