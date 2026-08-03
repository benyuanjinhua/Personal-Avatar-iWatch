import Foundation
import XCTest
@testable import WristAgentCore

final class ResultPlaybackLedgerTests: XCTestCase {
    func testClaimSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(ResultPlaybackLedger(directory: directory).claim(token: "req-1"))
        XCTAssertFalse(ResultPlaybackLedger(directory: directory).claim(token: "req-1"))
        XCTAssertTrue(ResultPlaybackLedger(directory: directory).claim(token: "req-2"))
    }

    /// ESS-182：同一 request_id 的 interim 与 final 语音 sha 不同，
    /// 各自的 speechFileName（`<requestId>-<sha>.m4a`）都必须独立 claim 成功，
    /// 否则 final 会被 interim 顶掉，用户只听到「处理中」。
    func testClaimDiscriminatesInterimAndFinalForSameRequestId() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = ResultPlaybackLedger(directory: directory)
        let interimFile = "019fc7a6-aaaaaa.m4a"
        let finalFile = "019fc7a6-bbbbbb.m4a"

        XCTAssertTrue(ledger.claim(token: interimFile), "interim first play")
        XCTAssertTrue(ledger.claim(token: finalFile), "final must not be blocked by interim")
        XCTAssertFalse(ledger.claim(token: interimFile), "same interim second time")
        XCTAssertFalse(ledger.claim(token: finalFile), "same final second time")
    }

    /// 旧 build 遗留的裸 request_id 条目对新 build 的 `<id>-<sha>.m4a` token
    /// 天然不冲突——历史条目不再阻塞任何新播放。
    func testLegacyBareRequestIdDoesNotBlockNewFileNameToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = ResultPlaybackLedger(directory: directory).claim(token: "019fc7a6")
        let ledger = ResultPlaybackLedger(directory: directory)
        XCTAssertTrue(ledger.claim(token: "019fc7a6-aaaaaa.m4a"))
    }
}
