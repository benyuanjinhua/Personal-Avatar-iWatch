import XCTest

@testable import WristAgent_Watch_App

/// ESS-253 / R-02.1：iPhone 的带码失败回执必须在 Watch 宿主进程里真实进入 journal，
/// 并落一条可跨端对账的 WatchLog 事件；不能用“能编译”替代运行时证据。
@MainActor
final class RelayFailureProjectionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess253-relay-failure-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testMacUnreachableRelayFailureProjectsToJournalAndWatchLog() throws {
        let requestId = UUID().uuidString.lowercased()
        let journal = VoiceTurnJournal(directory: directory)
        journal.begin(requestId: requestId)
        XCTAssertTrue(journal.recordLocal(.waitingForPhone, requestId: requestId))
        XCTAssertTrue(journal.recordLocal(.waitingForMac, requestId: requestId))

        var captured: (event: String, detail: String?, code: String?)?
        WatchLog.setObserver { _, event, detail, errorCode in
            if event == "relay_terminal_failure_projected" {
                captured = (event, detail, errorCode)
            }
        }

        let transport = WatchVoiceTransport(journal: journal)
        let update = RelayStatusUpdate(
            requestId: requestId,
            phase: .failed,
            detail: "Mac 没有应答，请确认助手正在运行",
            errorCode: "ERR_TRANSPORT",
            failureStage: .macUnreachable
        )
        transport.handleRelayStatus(data: try update.jsonData())

        let turn = try XCTUnwrap(journal.turns.first(where: { $0.requestId == requestId }))
        XCTAssertEqual(turn.currentState, .failed)
        XCTAssertEqual(turn.failureStage, .macUnreachable)
        XCTAssertEqual(turn.errorCode, "ERR_TRANSPORT")
        XCTAssertEqual(captured?.event, "relay_terminal_failure_projected")
        XCTAssertEqual(captured?.code, "ERR_TRANSPORT")
        XCTAssertTrue(captured?.detail?.contains("applied=true") == true)
        XCTAssertTrue(captured?.detail?.contains("failure_stage=waiting_for_mac") == true)
    }
}
