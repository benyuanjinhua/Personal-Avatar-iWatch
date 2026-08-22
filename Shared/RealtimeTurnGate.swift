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
        case suppress(reason: String, shouldLog: Bool)
    }

    private struct Entry: Equatable {
        let turn: Turn
        var handshakeFailures: Int
        var closed: Bool
        var suppressionLogged: Bool
    }

    /// 最近若干个回合的闸门状态。
    ///
    /// **有界**：只保留最近 `capacity` 个。一个永不清理的集合正是
    /// ESS-742/743/744 那一类缺陷；超出容量的老回合早就不会再有帧进来。
    private var entries: [Entry] = []
    private let capacity: Int
    /// 握手连续失败多少次后封死该回合。
    private let maxHandshakeAttempts: Int

    init(capacity: Int = 8, maxHandshakeAttempts: Int = 3) {
        self.capacity = max(1, capacity)
        self.maxHandshakeAttempts = max(1, maxHandshakeAttempts)
    }

    /// 通道进入失败态时调用。
    ///
    /// - Parameter wasActive: 失败前这条通道是否**已经握手成功**（`.active`）。
    ///
    /// 这个区分是 2026-08-21 18:27 真机事故教的：当时网关因 ESS-886 复发对
    /// **所有**握手回 401（`missing_bearer`），客户端拿到 `-1011`，而上一版
    /// 闸门把「第一次握手就被拒」也当成终态，于是整轮当场判死、用户连说话的
    /// 机会都没有。
    ///
    /// 「token 单次使用、重开必然失败」这条理由**只适用于已经握手成功过的
    /// 通道**——那时 token 确实被消耗了。握手本身被拒时 token 压根没进过
    /// 网关的账，重试是合理的；但也不能无界重试（那就退回 255 次风暴），
    /// 所以给一个小的上限。
    mutating func noteFailure(requestId: String, sessionId: String, wasActive: Bool) {
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        if let index = entries.firstIndex(where: { $0.turn == turn }) {
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
                suppressionLogged: false
            )
        )
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// 新回合显式开始（`stream.start`）时调用：解除该回合的封印。
    ///
    /// `stream.start` 是 Watch 表达「我要开一轮新的」的唯一信号，与被上行帧
    /// 泵出来的隐式重开有本质区别，必须放行——否则 request_id 复用时新回合
    /// 会被上一轮的判死结论误伤。
    mutating func noteTurnStart(requestId: String, sessionId: String) {
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        entries.removeAll { $0.turn == turn }
    }

    /// 这个信封能不能打开通道。
    ///
    /// - Parameter isTurnStart: 该信封是否为 `stream.start`。
    mutating func decide(requestId: String, sessionId: String, isTurnStart: Bool) -> Decision {
        if isTurnStart { return .open }
        let turn = Turn(requestId: requestId, sessionId: sessionId)
        guard let index = entries.firstIndex(where: { $0.turn == turn }), entries[index].closed else {
            return .open
        }
        let shouldLog = !entries[index].suppressionLogged
        entries[index].suppressionLogged = true
        return .suppress(reason: "turn_closed_terminal", shouldLog: shouldLog)
    }

    /// 取证用：当前封死了几个回合。
    var closedTurnCount: Int { entries.filter(\.closed).count }
}
