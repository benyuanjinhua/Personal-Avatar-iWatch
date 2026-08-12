import Foundation

/// 下行消费者对一条 envelope 的处置结果。
///
/// ESS-751 复审阻断项 1：只判断「回调是否存在」不足以决定要不要缓冲——
/// `PhoneConnectivity` 构造 `PhoneRealtimeSession` 时**总是**安装 `onDownlink`，
/// 于是持久队列 `WatchDownlinkOutbox` 不可用或入队失败时，帧既没送出去也不会
/// 进断连缓冲，缓冲主链路实际不可达。改由消费者显式回报。
enum RealtimeDownlinkDisposition: Equatable, Sendable {
    /// 持久队列（`WatchDownlinkOutbox`）已真正接手，或该帧永久不可投递且已留痕。
    /// 两种情况重投都无意义，**不得保留副本**。
    case handled
    /// 消费者没接住（队列不可用 / 入队失败 / 无消费者），只走了尽力而为通道。
    /// 进有界断连缓冲，等 WCSession 恢复后重放。
    case deferred
}

/// ESS-751：下行**主链路**——转发、断连缓冲、重连重放三件事收在一处。
///
/// 为什么是独立类型而不是写在 `PhoneRealtimeSession` 里：`iOS/` 没有单测
/// target，留在那边这条链路就只能靠人眼复核，而这正是它两次写错的原因
/// （第一次是转发后仍留副本，第二次是缓冲分支不可达）。放在 `Shared/` 后，
/// 「健康流不驻留 / 断连入缓冲 / 恢复恰好一次重放 / 重放持续失败仍有界」
/// 四条都能被 `swift test` 判定。
///
/// 上限沿用 `PendingDownlinkBuffer`：64 条 / 512 KiB / 30 秒，超限丢最旧。
/// 重放失败的帧回到同一缓冲，且**保留首次入队时间**——否则一条一直失败的帧
/// 每次重放都把时长上限清零，等价于没有时长上限。
struct RealtimeDownlinkRelay: Sendable {
    /// 缓冲里的一条：带首次入队时刻，重放失败回填时不刷新它。
    private struct Queued: Sendable {
        let envelope: RealtimeDownlinkEnvelope
        let firstQueuedAt: TimeInterval
    }

    struct DeliveryOutcome: Equatable, Sendable {
        /// 是否进了断连缓冲（`false` = 消费者已接手，未留副本）。
        let buffered: Bool
        /// 本次因超限被淘汰的条数。
        let dropped: Int
    }

    struct ReplayOutcome: Equatable, Sendable {
        /// 本次重放尝试的条数。
        let attempted: Int
        /// 消费者接手的条数。
        let handled: Int
        /// 仍未接手、已回到缓冲的条数。
        let rebuffered: Int
        /// 回填过程中因超限被淘汰的条数。
        let dropped: Int

        static let idle = ReplayOutcome(attempted: 0, handled: 0, rebuffered: 0, dropped: 0)
        var isIdle: Bool { self == .idle }
    }

    private var buffer: PendingDownlinkBuffer<Queued>

    init(
        maxCount: Int = 64,
        maxBytes: Int = 512 * 1024,
        maxAge: TimeInterval = 30
    ) {
        buffer = PendingDownlinkBuffer<Queued>(
            limits: .init(maxCount: maxCount, maxBytes: maxBytes, maxAge: maxAge)
        )
    }

    var pendingCount: Int { buffer.count }
    var pendingBytes: Int { buffer.byteCount }
    var droppedCount: Int { buffer.droppedCount }
    var isEmpty: Bool { buffer.isEmpty }

    /// 常驻字节口径：原始负载，不是 base64 上线形态——这里量的是内存占用。
    static func payloadBytes(of envelope: RealtimeDownlinkEnvelope) -> Int {
        (envelope.audio?.payload.count ?? 0) + (envelope.transcript?.utf8.count ?? 0)
    }

    /// 唯一的下行出口：交给消费者，只有它没接住才留副本。
    ///
    /// - Parameter send: 消费者。`nil` 表示还没接上消费者，等同 `.deferred`。
    @discardableResult
    mutating func deliver(
        _ envelope: RealtimeDownlinkEnvelope,
        nowSeconds: TimeInterval,
        send: ((RealtimeDownlinkEnvelope) -> RealtimeDownlinkDisposition)?
    ) -> DeliveryOutcome {
        let disposition = send?(envelope) ?? .deferred
        guard disposition == .deferred else {
            // 已转发：一个字节都不留，这就是 ESS-751 的主泄漏点。
            return DeliveryOutcome(buffered: false, dropped: 0)
        }
        let dropped = enqueue(envelope, firstQueuedAt: nowSeconds, nowSeconds: nowSeconds)
        return DeliveryOutcome(buffered: true, dropped: dropped)
    }

    /// 断连重放：WCSession activation / reachability / watch-state 恢复时调用。
    ///
    /// 取走全部待送帧按序重投，**每条恰好投一次**；仍未被接手的回到同一缓冲
    /// （保留首次入队时间），因此持续失败也不会突破三条上限。
    @discardableResult
    mutating func replay(
        nowSeconds: TimeInterval,
        send: ((RealtimeDownlinkEnvelope) -> RealtimeDownlinkDisposition)?
    ) -> ReplayOutcome {
        // 先按时长上限清理：过了窗口的帧对播放已无意义，补投只会插进新内容里。
        var dropped = buffer.trim(nowSeconds: nowSeconds)
        let pending = buffer.drain()
        guard !pending.isEmpty else {
            return dropped == 0
                ? .idle
                : ReplayOutcome(attempted: 0, handled: 0, rebuffered: 0, dropped: dropped)
        }
        var handled = 0
        var rebuffered = 0
        for item in pending {
            if send?(item.envelope) == .handled {
                handled += 1
                continue
            }
            rebuffered += 1
            dropped += enqueue(
                item.envelope, firstQueuedAt: item.firstQueuedAt, nowSeconds: nowSeconds
            )
        }
        return ReplayOutcome(
            attempted: pending.count, handled: handled, rebuffered: rebuffered, dropped: dropped
        )
    }

    /// 回合切换 / 会话结束：上一轮的待送帧补投过去只会污染新回合的播放顺序。
    /// - Returns: 被丢弃的条数（供日志对账）。
    @discardableResult
    mutating func discardAll() -> Int {
        let discarded = buffer.count
        buffer.discardAll()
        return discarded
    }

    private mutating func enqueue(
        _ envelope: RealtimeDownlinkEnvelope,
        firstQueuedAt: TimeInterval,
        nowSeconds: TimeInterval
    ) -> Int {
        buffer.enqueue(
            Queued(envelope: envelope, firstQueuedAt: firstQueuedAt),
            bytes: Self.payloadBytes(of: envelope),
            nowSeconds: firstQueuedAt
        ) + buffer.trim(nowSeconds: nowSeconds)
    }
}
