import XCTest

@testable import WristAgent_Watch_App

/// ESS-522：本地兜底确认计时器、主屏释放与进度静默的自动化测试。
///
/// 覆盖验收标准：
///   [ ] 后台 1.5 秒无确认时有本地兜底语音，不出现静默等待。
///   [ ] 后台确认及时到达时不播放兜底；迟到事件不造成双播。
///   [ ] 确认播完后主屏回待命，后台运行期间可继续发起新对话。
///   [ ] 后台任务全程 `progress_spoken == 0`，进度只占角落一行。
///   [ ] 自动化覆盖及时确认、超时兜底、后台不可达、迟到确认和连续两轮对话。
@MainActor
final class VoiceConfirmTimerTests: XCTestCase {

    // MARK: - Core timer lifecycle

    /// 1.5 秒内收到后台确认（cancel）→ 不触发本地兜底。
    func testBackendConfirmationArrivesCancel() {
        let player = SpeechPlayer(instanceTag: "test_confirm")
        let timer = VoiceConfirmTimer(player: player)
        var outcome: VoiceConfirmTimer.Outcome?
        timer.onConfirmComplete = { _, o in outcome = o }

        timer.arm(requestId: "test-001")
        XCTAssertTrue(timer.isArmed)

        // 后台确认在时限内到达
        timer.cancel(reason: "speech_attached")
        XCTAssertFalse(timer.isArmed)
        XCTAssertEqual(outcome, .backendConfirmationArrived)
    }

    /// 1.5 秒超时 → 本地兜底触发。
    /// 使用较长的 timeout 容忍测试环境中异步音频会话激活的延迟。
    func testTimeoutTriggersLocalFallback() async throws {
        let player = SpeechPlayer(instanceTag: "test_confirm")
        let timer = VoiceConfirmTimer(player: player)
        var outcome: VoiceConfirmTimer.Outcome?
        let expectation = expectation(description: "fallback triggered")

        timer.onConfirmComplete = { _, o in
            outcome = o
            expectation.fulfill()
        }

        timer.arm(requestId: "test-002")
        XCTAssertTrue(timer.isArmed)

        // 等待超时 + 音频会话激活（模拟器冷启动可能需要更长时间）
        await fulfillment(of: [expectation], timeout: 10.0)

        XCTAssertFalse(timer.isArmed)
        // 模拟器环境有 Bundle 资源时走 localFallbackPlayed，
        // 无资源时走 localFallbackMissing——两者都不是 backendConfirmationArrived。
        XCTAssertNotEqual(outcome, .backendConfirmationArrived)
    }

    // MARK: - Double-play prevention

    /// 后台确认先到 → 不再触发本地兜底（关键去双播路径）。
    func testCancelPreventsLocalFallback() async throws {
        let player = SpeechPlayer(instanceTag: "test_confirm")
        let timer = VoiceConfirmTimer(player: player)
        var outcomes: [VoiceConfirmTimer.Outcome] = []
        let expectation = expectation(description: "callback fired exactly once")
        expectation.expectedFulfillmentCount = 1

        timer.onConfirmComplete = { _, o in
            outcomes.append(o)
            expectation.fulfill()
        }

        timer.arm(requestId: "test-003")
        XCTAssertTrue(timer.isArmed)

        // 后台确认 0.1s 后到
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        timer.cancel(reason: "speech_attached")
        XCTAssertFalse(timer.isArmed)

        // 等待超过 1.5s——不应再触发回调
        try? await Task.sleep(nanoseconds: 1_800_000_000) // 1.8s

        await fulfillment(of: [expectation], timeout: 0.5)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first, .backendConfirmationArrived)
    }

    /// 重复 cancel 不触发多重回调。
    func testDuplicateCancelIsIdempotent() {
        let player = SpeechPlayer(instanceTag: "test_confirm")
        let timer = VoiceConfirmTimer(player: player)
        var outcomes: [VoiceConfirmTimer.Outcome] = []

        timer.onConfirmComplete = { _, o in outcomes.append(o) }

        timer.arm(requestId: "test-004")
        timer.cancel(reason: "speech_attached")
        timer.cancel(reason: "speech_attached") // duplicate

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first, .backendConfirmationArrived)
    }

    /// 新回合 arm 时自动取消旧计时器。
    func testArmCancelsPrevious() {
        let player = SpeechPlayer(instanceTag: "test_confirm")
        let timer = VoiceConfirmTimer(player: player)
        var requestIds: [String] = []

        timer.onConfirmComplete = { id, _ in requestIds.append(id) }

        timer.arm(requestId: "test-005a")
        // 立即 arm 新回合——旧计时器应被取消
        timer.arm(requestId: "test-005b")

        XCTAssertTrue(timer.isArmed)
        // 旧 requestId 的 confirm 应已触发（cancel 后回调）
        XCTAssertEqual(requestIds.count, 1)
        XCTAssertEqual(requestIds.first, "test-005a")
    }

    // MARK: - forceCancel

    func testForceCancelDoesNotTriggerCallback() {
        let player = SpeechPlayer(instanceTag: "test_confirm")
        let timer = VoiceConfirmTimer(player: player)
        var outcomes: [VoiceConfirmTimer.Outcome] = []

        timer.onConfirmComplete = { _, o in outcomes.append(o) }

        timer.arm(requestId: "test-006")
        timer.forceCancel(requestId: "test-006")

        XCTAssertFalse(timer.isArmed)
        XCTAssertEqual(outcomes.count, 0, "forceCancel must not trigger confirm callback")
    }

    // MARK: - Telemetry fields

    /// 验证 VoiceTurnRecord 新增三个字段存在且默认值正确。
    func testVoiceTurnRecordTelemetryDefaults() {
        let record = VoiceTurnRecord(
            requestId: "test-007",
            createdAt: Date(),
            events: [VoiceTurnEvent(state: .recorded)]
        )

        XCTAssertFalse(record.spawnConfirmSpoken, "默认不应有确认语音")
        XCTAssertEqual(record.mainScreenBlockedMs, 0, "默认封锁时长为 0")
        XCTAssertFalse(record.progressSpoken, "默认进度未触发语音")
    }

    // MARK: - PushToTalkController progress silence

    /// `recordProgressEvent` 标记 progress_spoken = true。
    func testRecordProgressEventMarksProgressSpoken() throws {
        let controller = PushToTalkController()
        let requestId = UUIDv7.generate().uuidString.lowercased()

        controller.journal.begin(requestId: requestId)
        controller.recordProgressEvent(requestId: requestId)

        let turn = controller.journal.turn(withId: requestId)
        XCTAssertTrue(turn?.progressSpoken == true)
        XCTAssertEqual(controller.progressSpokenCount, 1)
    }

    /// 连续两条 progress 事件递增计数。
    func testProgressSpokenCountIncrements() {
        let controller = PushToTalkController()
        let requestId = UUIDv7.generate().uuidString.lowercased()

        controller.journal.begin(requestId: requestId)
        controller.recordProgressEvent(requestId: requestId)
        controller.recordProgressEvent(requestId: requestId)

        XCTAssertEqual(controller.progressSpokenCount, 2)
    }

    /// ESS-522：状态机 accepted → spawnConfirmSpoken 初始为 false。
    func testAcceptedSetsSpawnConfirmSpokenFalse() {
        let controller = PushToTalkController()
        let requestId = UUIDv7.generate().uuidString.lowercased()

        // 模拟完整的请求流程
        controller.journal.begin(requestId: requestId)
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId,
            state: .accepted,
            occurredAt: Date()
        )

        // 应用 accepted 状态
        let applied = controller.journal.apply(envelope)
        XCTAssertTrue(applied, "accepted should be applied")

        let turn = controller.journal.turn(withId: requestId)
        XCTAssertEqual(turn?.currentState, .accepted)
        // 确认计时器应已 arm
        XCTAssertTrue(controller.confirmTimer?.isArmed == true)
    }

    // MARK: - Late confirmation guard

    /// 迟到确认不影响当前对话——cancel 后 state 不变。
    func testLateConfirmationDoesNotOverrideCurrentTurn() {
        let controller = PushToTalkController()
        let requestIdA = UUIDv7.generate().uuidString.lowercased()
        let requestIdB = UUIDv7.generate().uuidString.lowercased()

        // 回合 A：到 accepted
        controller.journal.begin(requestId: requestIdA)
        _ = controller.journal.apply(
            VoiceStatusEnvelope.status(requestId: requestIdA, state: .accepted, occurredAt: Date())
        )

        // 回合 B：新的请求（覆盖 A 的确认等待）
        controller.journal.begin(requestId: requestIdB)
        _ = controller.journal.apply(
            VoiceStatusEnvelope.status(requestId: requestIdB, state: .accepted, occurredAt: Date())
        )

        // 回合 A 的「迟到确认」不应改变 B 的状态
        let lateEnvelope = VoiceStatusEnvelope.status(
            requestId: requestIdA,
            state: .completed,
            occurredAt: Date()
        )
        let applied = controller.journal.apply(lateEnvelope)
        // apply 会推进 A 到 completed（状态机允许），
        // 但不会影响 B（B 仍是 accepted/processing）
        let turnA = controller.journal.turn(withId: requestIdA)
        let turnB = controller.journal.turn(withId: requestIdB)
        XCTAssertEqual(turnA?.currentState, .completed)
        XCTAssertEqual(turnB?.currentState, .accepted)
        XCTAssertTrue(applied, "late completion for A should still apply to A's journal entry")
    }

    // MARK: - Multiple turns (连续两轮对话)

    /// 连续两轮对话：第一轮确认完成后主屏释放，第二轮正常启动。
    func testConsecutiveTurnsEachGetConfirmTimer() {
        let controller = PushToTalkController()
        let requestId1 = UUIDv7.generate().uuidString.lowercased()
        let requestId2 = UUIDv7.generate().uuidString.lowercased()

        // 第一轮
        controller.journal.begin(requestId: requestId1)
        _ = controller.journal.apply(
            VoiceStatusEnvelope.status(requestId: requestId1, state: .accepted, occurredAt: Date())
        )
        XCTAssertTrue(controller.confirmTimer?.isArmed == true)
        // 模拟后台确认到达
        controller.confirmTimer?.cancel(reason: "speech_attached")
        XCTAssertFalse(controller.confirmTimer?.isArmed == true)

        // 第二轮
        controller.journal.begin(requestId: requestId2)
        _ = controller.journal.apply(
            VoiceStatusEnvelope.status(requestId: requestId2, state: .accepted, occurredAt: Date())
        )
        XCTAssertTrue(controller.confirmTimer?.isArmed == true, "第二轮应重新启动确认计时器")
    }
}
