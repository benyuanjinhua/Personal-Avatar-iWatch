import XCTest
@testable import WristAgent_Watch_App

/// ESS-1047：同一 request_id 已 `completed` 之后到达的迟到 `failed`，
/// **成功回合不得被打进 P6**。
///
/// ESS-1044（PR #390）让被状态机拒绝的 `.failed` 也无条件收口，代价是这条
/// 生产接线：
/// ```
/// journal.apply(failed) 被 completed 吸收 → applied=false
///   → PushToTalkController.onTerminalFailure → onSessionTurnFailed
///   → SessionController.markTurnFailed（此刻 turnPhase 仍是 .thinking，
///     因为答案还没起播）→ enterFailed → P6
/// ```
/// 于是一次**成功**的回合被迟到/竞态的 failed 判死。本套件跑的是生产链路
/// 本体（`WatchVoiceTransport.handleRelayStatus` → `VoiceTurnJournal.apply`
/// → `PushToTalkController` 接线 → `SessionTurnWiring` → `SessionController`），
/// 没有一段是抄进测试的副本。
///
/// 覆盖边界（如实声明）：与 ESS-1044 套件同构，起轮那一步用
/// `session.onBeginChannel` 替身给 request_id（CI 无音频硬件，见 ESS-498）；
/// 跨设备真实链路属 R-02.5 关卡二，合入后随装机真机复测。
@MainActor
final class Ess1047CompletedWinsLateFailureTests: XCTestCase {

    /// 本单核心回归：completed → 迟到 failed(applied=false)，会话必须原地不动。
    func testLateFailureAfterCompletedDoesNotFailSession() throws {
        let (session, pushToTalk) = makeWiredPair()
        let transport = WatchVoiceTransport(journal: pushToTalk.journal)
        let requestId = enterThinking(session: session, journal: pushToTalk.journal)
        XCTAssertTrue(pushToTalk.journal.apply(.status(requestId: requestId, state: .completed)))

        let events = LogCapture()
        events.install()
        transport.handleRelayStatus(data: try relayFailure(requestId: requestId).jsonData())

        XCTAssertTrue(events.contains("turn_terminal_failure_signal",
                                      detailContains: "applied=false"),
                      "前置条件：这一支正是被终态吸收的那条")
        XCTAssertTrue(events.contains("turn_terminal_failure_signal",
                                      detailContains: "current_state=completed forwarded=false"),
                      "R-02.1：success-wins 的判定必须落一条可对账的运行时事件")
        XCTAssertFalse(events.contains("session_turn_failed"),
                       "成功回合不得被派发会话失败信号")
        XCTAssertEqual(session.state, .listening, "ESS-1047：成功回合不得被打进 P6")
        XCTAssertEqual(session.turnPhase, .thinking, "相位不变——答案仍在等起播")
        XCTAssertNil(session.failedReason)
        print("ESS-1047 runtime evidence (completed → late failed):\n" + events.transcript())
    }

    /// ESS-1044 不得被本单改回去：被 `.cancelled` 吸收的那支仍须立刻收口。
    func testLateFailureAfterCancelledStillClosesSession() throws {
        let (session, pushToTalk) = makeWiredPair()
        let transport = WatchVoiceTransport(journal: pushToTalk.journal)
        let requestId = enterThinking(session: session, journal: pushToTalk.journal)
        XCTAssertTrue(pushToTalk.journal.apply(.status(requestId: requestId, state: .cancelled)))

        let events = LogCapture()
        events.install()
        transport.handleRelayStatus(data: try relayFailure(requestId: requestId).jsonData())

        XCTAssertTrue(events.contains("turn_terminal_failure_signal",
                                      detailContains: "current_state=cancelled forwarded=true"))
        XCTAssertTrue(events.contains("session_turn_failed"))
        XCTAssertEqual(session.state, .failed, "ESS-1044 的收口不能被 success-wins 顺带关掉")
        XCTAssertEqual(session.turnPhase, .idle)
    }

    /// 真正失败的那一轮照样收口：`applied=true` 主路径不受影响。
    func testAppliedFailureStillClosesSession() throws {
        let (session, pushToTalk) = makeWiredPair()
        let transport = WatchVoiceTransport(journal: pushToTalk.journal)
        let requestId = enterThinking(session: session, journal: pushToTalk.journal)

        let events = LogCapture()
        events.install()
        transport.handleRelayStatus(data: try relayFailure(requestId: requestId).jsonData())

        XCTAssertTrue(events.contains("turn_terminal_failure_signal",
                                      detailContains: "applied=true"))
        XCTAssertTrue(events.contains("session_turn_failed"))
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(session.turnPhase, .idle)
    }

    // MARK: - helpers

    private func makeWiredPair() -> (SessionController, PushToTalkController) {
        let defaults = UserDefaults(suiteName: "Ess1047Tests.\(UUID().uuidString)")!
        let session = SessionController(defaults: defaults)
        let pushToTalk = PushToTalkController()
        // 生产接线本体，不是副本。
        SessionTurnWiring.connect(session: session, pushToTalk: pushToTalk, interruptSelfCheck: {})
        session.scheduleDelay = { _, _ in NoopToken() }
        return (session, pushToTalk)
    }

    /// 把会话推到「已提交、正在等回答」——误杀就发生在这个相位。
    @discardableResult
    private func enterThinking(session: SessionController, journal: VoiceTurnJournal) -> String {
        let requestId = UUID().uuidString.lowercased()
        session.onBeginChannel = { requestId }
        session.enterSession()
        session.markChannelReady()
        session.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(session.turnPhase, .thinking)
        journal.begin(requestId: requestId)
        return requestId
    }

    private func relayFailure(requestId: String) -> RelayStatusUpdate {
        RelayStatusUpdate(
            requestId: requestId,
            phase: .failed,
            detail: "助手这边还没准备好",
            errorCode: "ERR_VOICE_BUSY",
            failureStage: .execution
        )
    }

    /// 运行时事件采集（R-02.1 证据来源：真实 WatchLog 事件，不是断言的副本）。
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(event: String, detail: String?)] = []

        func install() {
            WatchLog.setObserver { [weak self] _, event, _, detail, _ in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.storage.append((event, detail))
            }
        }

        func transcript() -> String {
            lock.lock(); defer { lock.unlock() }
            return storage
                .map { "  \($0.event)\($0.detail.map { d in " " + d } ?? "")" }
                .joined(separator: "\n")
        }

        func contains(_ event: String, detailContains needle: String? = nil) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return storage.contains { entry in
                guard entry.event == event else { return false }
                guard let needle else { return true }
                return entry.detail?.contains(needle) == true
            }
        }
    }

    private final class NoopToken: SessionDelayToken {
        func cancel() {}
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        super.tearDown()
    }
}
