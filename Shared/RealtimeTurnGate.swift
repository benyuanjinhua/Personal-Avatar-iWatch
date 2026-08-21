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

    /// 已判终态、禁止再打开的回合。
    ///
    /// **有界**：只保留最近 `capacity` 个。一个永不清理的集合正是
    /// ESS-742/743/744 那一类缺陷；这里存的是「最近判死的回合」，
    /// 超出容量的老回合早就不会再有帧进来，丢掉无损。
    private var closed: [Turn] = []
    private let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    /// 通道进入失败态时调用。
    ///
    /// - Parameter terminal: 服务端明确 `retriable: false`，或本地判定不可恢复。
    ///   只有终态才封死回合——可重试的失败仍允许上层按自己的节奏重开，
    ///   本类型不替它决定重试策略。
    mutating func noteFailure(requestId: String, sessionId: String, terminal: Bool) {
        guard terminal else { return }
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        guard !closed.contains(turn) else { return }
        closed.append(turn)
        if closed.count > capacity { closed.removeFirst(closed.count - capacity) }
    }

    /// 新回合显式开始（`stream.start`）时调用：解除该回合的封印。
    ///
    /// `stream.start` 是 Watch 表达「我要开一轮新的」的唯一信号，与被上行帧
    /// 泵出来的隐式重开有本质区别，必须放行——否则 request_id 复用时新回合
    /// 会被上一轮的判死结论误伤。
    mutating func noteTurnStart(requestId: String, sessionId: String) {
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        closed.removeAll { $0 == turn }
    }

    /// 这个信封能不能打开通道。
    ///
    /// - Parameter isTurnStart: 该信封是否为 `stream.start`。
    func decide(requestId: String, sessionId: String, isTurnStart: Bool) -> Decision {
        if isTurnStart { return .open }
        guard closed.contains(Turn(requestId: requestId, sessionId: sessionId)) else {
            return .open
        }
        return .suppress(reason: "turn_closed_terminal")
    }

    /// 取证用：当前封了几个回合。
    var closedTurnCount: Int { closed.count }
}
