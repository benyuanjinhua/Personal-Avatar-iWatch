import Foundation

/// ESS-751：下行**断连缓冲**。
///
/// 修这条之前，`PhoneRealtimeSession` 在立即 `onDownlink?(envelope)` 转发的
/// 同时，把每个 envelope 也 append 进 `pendingDownlink`，而全仓没有任何
/// `drainPendingDownlink()` 的调用者。结果是 `audio.delta` 的 PCM 在整段会话里
/// 重复驻留，只有新回合才 `removeAll` —— 长对话持续增长直到 OOM。
///
/// 本类型把「什么时候该缓冲、缓冲多少」收成一处可测试的策略：
///
/// 1. **只在送不出去时缓冲**。已成功转发的不保留——那是副本，不是待送。
/// 2. **三条上限**（条数 / 字节 / 时长）任一超出即从队头淘汰。断连缓冲的用途
///    是「重连后补上刚错过的一小段」，不是留全量录音；没有上限的队列在长会话
///    里等价于无限增长。
/// 3. **淘汰留证**。静默丢弃会让「重连后少了一段」变成无法解释的现象。
///
/// 放在 `Shared/` 而不是 `iOS/`：`iOS/` 没有单元测试 target，留在那里这条策略
/// 就只能靠人眼复核（正是它当初被写错还合入的原因）。
public struct PendingDownlinkBuffer<Element>: Sendable where Element: Sendable {

    public struct Limits: Equatable, Sendable {
        public var maxCount: Int
        public var maxBytes: Int
        public var maxAge: TimeInterval

        public init(maxCount: Int = 64, maxBytes: Int = 512 * 1024, maxAge: TimeInterval = 30) {
            precondition(maxCount > 0)
            precondition(maxBytes > 0)
            precondition(maxAge > 0)
            self.maxCount = maxCount
            self.maxBytes = maxBytes
            self.maxAge = maxAge
        }
    }

    private struct Entry: Sendable {
        let element: Element
        let bytes: Int
        let queuedAt: TimeInterval
    }

    public private(set) var limits: Limits
    private var entries: [Entry] = []
    private(set) public var byteCount = 0
    /// 累计被淘汰的条数。对账用：重连后少了一段时，这个数字说明是被上限截掉的，
    /// 而不是链路丢了。
    private(set) public var droppedCount = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// 入队一个**没能送出去**的元素。`bytes` 是它的负载大小（用于字节上限）。
    /// - Returns: 本次因超限被淘汰的条数（0 = 没有淘汰）。
    @discardableResult
    public mutating func enqueue(_ element: Element, bytes: Int, nowSeconds: TimeInterval) -> Int {
        entries.append(Entry(element: element, bytes: max(0, bytes), queuedAt: nowSeconds))
        byteCount += max(0, bytes)
        return trim(nowSeconds: nowSeconds)
    }

    /// 三条上限任一超出即从**队头**（最旧）淘汰。
    @discardableResult
    public mutating func trim(nowSeconds: TimeInterval) -> Int {
        var dropped = 0
        while let head = entries.first,
              entries.count > limits.maxCount
                || byteCount > limits.maxBytes
                || nowSeconds - head.queuedAt > limits.maxAge {
            byteCount -= head.bytes
            entries.removeFirst()
            dropped += 1
        }
        droppedCount += dropped
        return dropped
    }

    /// 断连重放：取走全部待送元素并清空。取走即不再是「待送」，不留副本。
    public mutating func drain() -> [Element] {
        let snapshot = entries.map(\.element)
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
        return snapshot
    }

    /// 回合切换 / 会话结束：丢弃全部待送元素（它们属于上一轮，补投过去
    /// 只会污染新回合的播放顺序）。
    public mutating func discardAll() {
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
    }
}
