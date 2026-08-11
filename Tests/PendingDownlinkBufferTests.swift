import XCTest

@testable import WristAgentCore

/// ESS-751：下行断连缓冲的策略测试。
///
/// 缺陷原样：`PhoneRealtimeSession` 在**已经转发**的同时把每个 envelope 也
/// append 进 `pendingDownlink`，而 `drainPendingDownlink()` 全仓没有调用者 ——
/// `audio.delta` 的 PCM 在整段会话里重复驻留，只有新回合才清。本套件钉住修复后
/// 的三条口径：只缓冲送不出去的、上限内淘汰最旧的、重放取走即清空。
final class PendingDownlinkBufferTests: XCTestCase {

    private func makeBuffer(
        maxCount: Int = 64,
        maxBytes: Int = 512 * 1024,
        maxAge: TimeInterval = 30
    ) -> PendingDownlinkBuffer<String> {
        PendingDownlinkBuffer<String>(
            limits: .init(maxCount: maxCount, maxBytes: maxBytes, maxAge: maxAge)
        )
    }

    // MARK: - 长流不再无限增长（本单的核心）

    /// 长会话形态：连续灌入远超上限的 envelope。修复前这里等价于「全部驻留」，
    /// 修复后必须稳定在条数上限内，且字节数同步收敛（不能只砍数组不减字节，
    /// 那样字节上限会永久失效）。
    func testLongStreamStaysWithinCountLimit() {
        var buffer = makeBuffer(maxCount: 8)
        for i in 0..<500 {
            buffer.enqueue("chunk-\(i)", bytes: 1_024, nowSeconds: Double(i) * 0.02)
        }

        XCTAssertEqual(buffer.count, 8, "长流必须稳定在条数上限内，不得无限增长")
        XCTAssertEqual(buffer.byteCount, 8 * 1_024, "字节计数必须随淘汰同步收敛")
        XCTAssertEqual(buffer.droppedCount, 492)
        // 留下的是**最新**的 8 条：断连重放要补的是「刚错过的」，不是最早的。
        XCTAssertEqual(buffer.drain(), (492..<500).map { "chunk-\($0)" })
    }

    /// 字节上限独立生效：条数没超，但负载很大时同样要淘汰。
    /// `audio.delta` 的单帧可以很大，只看条数挡不住内存增长。
    func testByteLimitEvictsEvenWhenCountIsSmall() {
        var buffer = makeBuffer(maxCount: 1_000, maxBytes: 10_000)

        for i in 0..<10 { buffer.enqueue("big-\(i)", bytes: 4_000, nowSeconds: Double(i)) }

        XCTAssertLessThanOrEqual(buffer.byteCount, 10_000)
        XCTAssertEqual(buffer.count, 2, "10KB 上限下只装得下 2 个 4KB 帧")
        XCTAssertEqual(buffer.drain(), ["big-8", "big-9"])
    }

    /// 时长上限：断连太久的缓冲不该再补投——用户已经在等下一句了，
    /// 把 30 秒前的音频补出来只会造成「答非所问」。
    func testAgeLimitDropsStaleEntries() {
        var buffer = makeBuffer(maxAge: 5)
        buffer.enqueue("old", bytes: 10, nowSeconds: 0)
        buffer.enqueue("older-still", bytes: 10, nowSeconds: 1)

        buffer.enqueue("fresh", bytes: 10, nowSeconds: 20)

        XCTAssertEqual(buffer.drain(), ["fresh"], "超龄条目必须被淘汰")
    }

    /// 时长淘汰不依赖新入队触发：显式 trim 也要生效（重连时先 trim 再 drain
    /// 是正常用法）。
    func testTrimDropsStaleWithoutNewEnqueue() {
        var buffer = makeBuffer(maxAge: 5)
        buffer.enqueue("a", bytes: 10, nowSeconds: 0)

        let dropped = buffer.trim(nowSeconds: 100)

        XCTAssertEqual(dropped, 1)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
    }

    // MARK: - 断连重放

    /// 重放取走即清空——缓冲的语义是「还没送到的」，送出去就不再是待送。
    /// 修复前 drain 没有调用者，这条语义从来没被兑现过。
    func testDrainReturnsQueuedOrderAndClears() {
        var buffer = makeBuffer()
        buffer.enqueue("a", bytes: 1, nowSeconds: 0)
        buffer.enqueue("b", bytes: 2, nowSeconds: 1)
        buffer.enqueue("c", bytes: 3, nowSeconds: 2)

        XCTAssertEqual(buffer.drain(), ["a", "b", "c"], "重放必须保持入队顺序")

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertEqual(buffer.drain(), [], "二次 drain 不得重复补投")
    }

    /// 回合切换丢弃：上一轮的待送 envelope 补投到新回合会污染播放顺序
    /// （ESS-539 已有的口径，这里保住它）。
    func testDiscardAllClearsWithoutReplay() {
        var buffer = makeBuffer()
        buffer.enqueue("stale", bytes: 100, nowSeconds: 0)

        buffer.discardAll()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertEqual(buffer.drain(), [])
    }

    /// 负字节数不得把计数带成负数（防御损坏输入）。
    func testNegativeBytesAreClampedToZero() {
        var buffer = makeBuffer()
        buffer.enqueue("x", bytes: -5, nowSeconds: 0)
        XCTAssertEqual(buffer.byteCount, 0)
    }
}
