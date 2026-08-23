import XCTest
@testable import WristAgentCore

final class BargeInGenerationCoordinatorTests: XCTestCase {
    func testCancelMintReadyOpenOrdering() {
        var gate = BargeInGenerationCoordinator(generation: 1)
        XCTAssertEqual(gate.request(from: 1), .cancel(1))
        XCTAssertEqual(gate.ready(generation: 2), .ignore)
        XCTAssertEqual(gate.cancelSettled(generation: 1), .mintAndConnect(2))
        XCTAssertEqual(gate.ready(generation: 2), .open(2))
        XCTAssertEqual(gate.generation, 2)
    }

    func testLateOldEventsAndDuplicateFailureAreIgnored() {
        var gate = BargeInGenerationCoordinator(generation: 1)
        XCTAssertEqual(gate.request(from: 1), .cancel(1))
        XCTAssertEqual(gate.cancelSettled(generation: 0), .ignore)
        XCTAssertEqual(gate.fail("token_mint_failed"), .fallback("token_mint_failed"))
        XCTAssertEqual(gate.fail("upgrade_failed"), .ignore)
        XCTAssertEqual(gate.ready(generation: 2), .ignore)
    }

    /// ESS-1070：打断的验收是「停止旧 generation 播放**和下行**」。
    /// `cancel` 一发出，iPhone 就必须停止向 Watch 转发旧代下行——而不是等到
    /// 新会话连上（`cancel.ack` 兜底 2 s）才随 `generation` 一起推进。
    func testDownlinkStopsForwardingTheMomentCancelIsIssued() {
        var gate = BargeInGenerationCoordinator(generation: 1)
        XCTAssertTrue(gate.shouldForwardDownlink(generation: 1))
        XCTAssertFalse(gate.shouldForwardDownlink(generation: 0), "旧代下行本就不转发")

        XCTAssertEqual(gate.request(from: 1), .cancel(1))
        XCTAssertFalse(
            gate.shouldForwardDownlink(generation: 1),
            "换代在途时旧代下行必须当场停——Watch 的 pending 门禁只是最后一道防线"
        )
        XCTAssertFalse(gate.shouldForwardDownlink(generation: 2), "新代未 open，不得抢跑")

        XCTAssertEqual(gate.cancelSettled(generation: 1), .mintAndConnect(2))
        XCTAssertFalse(gate.shouldForwardDownlink(generation: 1))

        XCTAssertEqual(gate.ready(generation: 2), .open(2))
        XCTAssertTrue(gate.shouldForwardDownlink(generation: 2), "新代 open 后恢复转发")
        XCTAssertFalse(gate.shouldForwardDownlink(generation: 1), "旧代永久丢弃")
    }

    /// 换代失败后连接正在拆除，任何 generation 的下行都不再转发。
    func testDownlinkStaysClosedAfterReplacementFallback() {
        var gate = BargeInGenerationCoordinator(generation: 3)
        XCTAssertEqual(gate.request(from: 3), .cancel(3))
        XCTAssertEqual(gate.fail("token_mint_failed"), .fallback("token_mint_failed"))
        XCTAssertFalse(gate.shouldForwardDownlink(generation: 3))
        XCTAssertFalse(gate.shouldForwardDownlink(generation: 4))
    }

    func testDuplicateCancelSettledDoesNotMintTwice() {
        var gate = BargeInGenerationCoordinator(generation: 1)
        XCTAssertEqual(gate.request(from: 1), .cancel(1))
        XCTAssertEqual(gate.cancelSettled(generation: 1), .mintAndConnect(2))
        XCTAssertEqual(gate.cancelSettled(generation: 1), .ignore)
    }
}
