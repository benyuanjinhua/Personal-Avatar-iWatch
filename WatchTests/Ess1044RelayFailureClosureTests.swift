import XCTest
@testable import WristAgent_Watch_App

/// ESS-1044 / R-02.1：relay 判本轮终态失败后，会话必须**就地收口**，
/// 不能卡在 thinking 干等 45s 硬超时。
///
/// 真机 2026-08-22「今天星期几」：
/// ```
/// 14:00:00.407  session_turn_committed phase=thinking
/// 14:00:04.455  relay_status phase=failed "助手这边还没准备好"
/// 14:00:04.456  relay_terminal_failure_projected applied=false failure_stage=execution
/// 14:00:25      session_thinking_slow
/// 14:00:45      session_thinking_hard_timeout        ← 41 秒后才被捞回
/// 14:01:01      session_failed_auto_hangup
/// ```
///
/// 本套件跑的是**生产链路本体**：
/// `WatchVoiceTransport.handleRelayStatus` → `VoiceTurnJournal.apply`
/// → `PushToTalkController` 的 `onTerminalFailure` 接线 → `SessionTurnWiring`
/// → `SessionController.markTurnFailed`。没有一段是抄进测试的副本。
///
/// 覆盖边界（如实声明）：模拟器里没有 iPhone / Bridge，回合的**起轮**那一步
/// 用 `session.onBeginChannel` 替身给出 request_id（真开麦在无音频硬件的 CI 上
/// 会挂，见 ESS-498）。被测的失败收口链路本身全是生产代码。跨设备真实链路
/// 属 R-02.5 关卡二，合入后随装机真机复测。
@MainActor
final class Ess1044RelayFailureClosureTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess1044-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        WatchLog.setObserver(nil)
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// 结构性防线：接线跑完后这两个出入口都必须是接上的。ESS-1044 的病根
    /// 就是「journal 那条失败链根本没有通往会话层的出口」——没有断言盯着
    /// 它们，下次冲突解决再删掉一次也一样全绿。
    func testProductionWiringConnectsTerminalFailureSeam() {
        let (session, pushToTalk) = makeWiredPair()
        XCTAssertNotNil(pushToTalk.journal.onTerminalFailure,
                        "journal 的终态失败信号未接 → applied=false 时会话永远收不到失败")
        XCTAssertNotNil(pushToTalk.onSessionTurnFailed,
                        "会话侧失败入口未接 → 只能等 45s 硬超时")
        XCTAssertEqual(session.state, .idle)
    }

    /// 主路径：`applied=true`（状态机接受 failed）时收口。
    func testAppliedRelayFailureClosesSessionImmediately() throws {
        let (session, pushToTalk) = makeWiredPair()
        let transport = WatchVoiceTransport(journal: pushToTalk.journal)
        let requestId = enterThinking(session: session, journal: pushToTalk.journal)

        let events = LogCapture()
        events.install()
        transport.handleRelayStatus(data: try relayFailure(requestId: requestId).jsonData())

        XCTAssertEqual(session.state, .failed, "relay 失败后必须立刻进 P6")
        XCTAssertEqual(session.turnPhase, .idle, "必须转出 thinking")
        XCTAssertEqual(session.failedReason, SessionController.turnFailureCopy)
        XCTAssertTrue(events.contains("turn_terminal_failure_signal", detailContains: "applied=true"))
        XCTAssertTrue(events.contains("session_turn_failed"),
                      "R-02.1：收口必须落一条可对账的运行时事件")
    }

    /// 本单核心回归：真机上就是这一支——回合**已经是 failed**，第二条同 request_id
    /// 的失败经另一条通道到达，`journal.apply` 返回 false、`onStateApplied` 不触发，
    /// 旧实现在这里彻底静默，会话一路挂到 45s 硬超时。
    ///
    /// 构造方式说明：先让 journal 落到 `.failed`（此时会话还在 idle，信号被
    /// `isInSession` 闸门丢弃、不产生副作用），再把会话推到 thinking，然后投递
    /// 重复的那一条——等价于「第一条失败在会话接手之前就已入账」。
    func testRejectedRelayFailureStillClosesSession() throws {
        let (session, pushToTalk) = makeWiredPair()
        let transport = WatchVoiceTransport(journal: pushToTalk.journal)
        let requestId = UUID().uuidString.lowercased()
        pushToTalk.journal.begin(requestId: requestId)
        XCTAssertTrue(pushToTalk.journal.apply(
            .status(requestId: requestId, state: .failed, errorCode: "ERR_VOICE_BUSY")
        ))
        XCTAssertEqual(session.state, .idle, "会话尚未开始，第一条失败不产生副作用")
        enterThinking(session: session, requestId: requestId)

        let events = LogCapture()
        events.install()
        transport.handleRelayStatus(data: try relayFailure(requestId: requestId).jsonData())

        XCTAssertTrue(events.contains("relay_terminal_failure_projected", detailContains: "applied=false"),
                      "前置条件：这一支正是真机上 applied=false 的那条")
        XCTAssertEqual(session.state, .failed, "applied=false 也必须收口——这就是 ESS-1044")
        XCTAssertEqual(session.turnPhase, .idle)
        XCTAssertTrue(events.contains("session_turn_failed"))
        // R-02.1：把这条链路的真实运行时事件流打进测试输出，作为可复核证据。
        print("ESS-1044 runtime evidence (applied=false path):\n" + events.transcript())
    }

    /// `.cancelled` 吸收掉的 failed 同样不派发——已取消的回合不是「答不上来」。
    /// 与 `.completed` 同属矛盾终态，判据是当前状态而非「转移有没有被接受」。
    func testCancelledThenLateFailureDoesNotEnterFailed() throws {
        let (session, pushToTalk) = makeWiredPair()
        let transport = WatchVoiceTransport(journal: pushToTalk.journal)
        let requestId = enterThinking(session: session, journal: pushToTalk.journal)
        XCTAssertTrue(pushToTalk.journal.apply(.status(requestId: requestId, state: .cancelled)))

        let events = LogCapture()
        events.install()
        transport.handleRelayStatus(data: try relayFailure(requestId: requestId).jsonData())

        XCTAssertNotEqual(session.state, .failed)
        XCTAssertFalse(events.contains("session_turn_failed"))
        XCTAssertTrue(events.contains("turn_terminal_failure_signal",
                                      detailContains: "dispatched=false current_state=cancelled"),
                      "丢弃必须留证，不得静默")
    }

    /// 成功回合不得被误伤：`completed` 走完之后，同一条链路一个失败都不该产生。
    func testCompletedTurnIsNotClosedAsFailure() throws {
        let (session, pushToTalk) = makeWiredPair()
        let requestId = enterThinking(session: session, journal: pushToTalk.journal)

        XCTAssertTrue(pushToTalk.journal.apply(.status(requestId: requestId, state: .completed)))

        XCTAssertEqual(session.state, .listening)
        XCTAssertEqual(session.turnPhase, .thinking, "completed 不经本条链路改相位")
    }

    /// 复审阻断（毕玄-cx，2026-08-22）：**已成功的回合不得被迟到的 failed 误杀**。
    ///
    /// 真实成因：纯文本结果（ESS-48）或段落屏障期间，journal 已经是 `.completed`
    /// 而会话仍停在 `.thinking`（相位由真实起播推进，不由 journal 终态推进）。
    /// 此时双通道乱序送来一条 failed —— 状态机按「终态吸收」拒绝它，
    /// 但失败信号若无条件派发，用户会看到「这轮没答上来」盖掉一个成功回合。
    /// 口径：矛盾终态 success-wins。
    func testCompletedThenLateFailureDoesNotEnterFailed() throws {
        let (session, pushToTalk) = makeWiredPair()
        let transport = WatchVoiceTransport(journal: pushToTalk.journal)
        let requestId = enterThinking(session: session, journal: pushToTalk.journal)
        XCTAssertTrue(pushToTalk.journal.apply(.status(requestId: requestId, state: .completed)))

        let events = LogCapture()
        events.install()
        transport.handleRelayStatus(data: try relayFailure(requestId: requestId).jsonData())

        XCTAssertEqual(pushToTalk.journal.turn(withId: requestId)?.currentState, .completed,
                       "终态吸收：journal 仍是 completed")
        XCTAssertNotEqual(session.state, .failed, "成功回合不得被迟到 failed 打进 P6")
        XCTAssertEqual(session.state, .listening)
        XCTAssertEqual(session.turnPhase, .thinking, "相位不受影响，仍等真实起播")
        XCTAssertFalse(events.contains("session_turn_failed"),
                       "成功回合不得产生失败收口事件")
        XCTAssertTrue(events.contains("turn_terminal_failure_signal",
                                      detailContains: "dispatched=false current_state=completed"),
                      "丢弃必须留证，不得静默——否则乱序矛盾终态在日志里不可判定")
        print("ESS-1044 runtime evidence (completed → late failed):\n" + events.transcript())
    }

    // MARK: - helpers

    private func makeWiredPair() -> (SessionController, PushToTalkController) {
        let defaults = UserDefaults(suiteName: "Ess1044Tests.\(UUID().uuidString)")!
        let session = SessionController(defaults: defaults)
        let pushToTalk = PushToTalkController()
        // 生产接线本体，不是副本。
        SessionTurnWiring.connect(session: session, pushToTalk: pushToTalk, interruptSelfCheck: {})
        session.scheduleDelay = { _, _ in NoopToken() }
        return (session, pushToTalk)
    }

    /// 把会话推到「已提交、正在等回答」——也就是真机卡死的那个相位。
    @discardableResult
    private func enterThinking(session: SessionController, journal: VoiceTurnJournal) -> String {
        let requestId = UUID().uuidString.lowercased()
        journal.begin(requestId: requestId)
        enterThinking(session: session, requestId: requestId)
        return requestId
    }

    private func enterThinking(session: SessionController, requestId: String) {
        session.onBeginChannel = { requestId }
        session.enterSession()
        session.markChannelReady()
        session.markTurnCommitted(requestId: requestId)
        XCTAssertEqual(session.turnPhase, .thinking)
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

        /// 采到的事件流，供 R-02.1 证据打印。
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
}
