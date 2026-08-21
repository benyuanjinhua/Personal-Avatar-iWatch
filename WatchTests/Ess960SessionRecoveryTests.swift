import XCTest
@testable import WristAgent_Watch_App

/// ESS-960（Watch 侧，缺陷 3 与缺陷 4）。
///
/// 缺陷 3：整轮没听到人说话时，`session_turn_cap_skipped` 只落一条日志就走人。
/// 真机 L1：`audio_too_short pcm_bytes=1916800 duration_ms=59900 rms=5` ——
/// 录满 59.9 秒、rms=5（≈ VAD 门限的 1/50），50s 时会话层已经知道「没听到人
/// 说话」，用户却在随后的 60s 自停 → 整文件回退 → Bridge 判太短 → 失败回投
/// 全过程得不到任何提示。
///
/// 缺陷 4：iPhone 侧通道终态在 `PhoneConnectivity.onStateChange` 里被整条丢掉
/// （那个闭包只认 `.active`），Watch 因此永远等不到「通道死了」。
@MainActor
final class Ess960SessionRecoveryTests: XCTestCase {

    private var controller: SessionController!
    private var haptics: [SessionController.Haptic]!
    private var scheduled: [(delay: TimeInterval, fire: @MainActor () -> Void)]!
    private var commitCount = 0
    private var teardownCount = 0
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "Ess960SessionRecoveryTests.\(UUID().uuidString)")
        controller = SessionController(defaults: defaults)
        haptics = []
        scheduled = []
        commitCount = 0
        teardownCount = 0
        controller.playHaptic = { [weak self] in self?.haptics.append($0) }
        controller.scheduleDelay = { [weak self] delay, fire in
            self?.scheduled.append((delay, fire))
            return Ess960FakeDelayToken()
        }
        var began = 0
        controller.onBeginChannel = { began += 1; return "req-\(began)" }
        controller.onCommitTurn = { [weak self] in self?.commitCount += 1 }
        controller.onTeardownChannel = { [weak self] in self?.teardownCount += 1 }
    }

    override func tearDown() {
        controller = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 缺陷 3

    /// 到达单轮上限、整轮没听到人说话：**必须**给出一行可行动提示 + 失败触觉，
    /// 而且**不得**提交这段静音（ESS-865 的不变量）。修复前这里 notice 为 nil。
    func testTurnCapWithoutSpeechSurfacesActionableNotice() {
        controller.enterSession()
        controller.markChannelReady()
        XCTAssertEqual(controller.turnPhase, .listening)

        fireDelay(matching: SessionController.turnCapSeconds)

        XCTAssertEqual(controller.failureNotice, SessionController.noSpeechNoticeCopy)
        XCTAssertTrue(haptics.contains(.failure))
        // ESS-865：静音一律不提交，回合仍留在聆听相位交给静默治理收口。
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.turnPhase, .listening)
    }

    /// 提示文案是「怎么办」，不含错误码、不解释内部状态（PRD 异常链文案纪律）。
    func testNoSpeechNoticeCopyCarriesNoErrorCode() {
        let copy = SessionController.noSpeechNoticeCopy
        XCTAssertFalse(copy.isEmpty)
        XCTAssertFalse(copy.contains("ERR_"))
        XCTAssertFalse(copy.lowercased().contains("error"))
        XCTAssertFalse(copy.contains("VAD"))
        XCTAssertFalse(copy.contains("rms"))
    }

    /// 说过话的回合到点仍按原样提交——本修复不得改动主干路径。
    func testTurnCapWithSpeechStillCommits() {
        controller.enterSession()
        controller.markChannelReady()
        controller.markSpeechDetected(requestId: "req-1")
        XCTAssertTrue(controller.didDetectSpeechThisTurn)

        fireDelay(matching: SessionController.turnCapSeconds)

        XCTAssertEqual(commitCount, 1)
        XCTAssertNil(controller.failureNotice)
    }

    // MARK: - 缺陷 4

    /// 通道终态必须驱动失败链：P6 失败态 + 一行可行动文案 + 失败触觉 + 拆链。
    func testChannelFailureDrivesFailedStateWithActionableCopy() {
        controller.enterSession()
        controller.markChannelReady()

        controller.markChannelFailed(.channelEvent)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.failedReason, "连接断了，本轮对话已结束")
        XCTAssertFalse(controller.failedReason?.contains("ERR_") ?? true)
        XCTAssertTrue(controller.failedRetryable)
        XCTAssertTrue(haptics.contains(.failure))
        XCTAssertEqual(teardownCount, 1)
    }

    /// 适配器收到 iPhone 的通道终态 → 触发 `onChannelFailed`。
    /// 这是缺陷 4 新增的那一跳；接线的另一端（→ `markChannelFailed`）在
    /// `PushToTalkController.attachSessionEvents` 里，由生产路径独占。
    func testAdapterForwardsChannelFailedForCurrentTurn() {
        let adapter = Self.makeAdapter()
        var failures: [(String, String)] = []
        adapter.onChannelFailed = { failures.append(($0, $1)) }

        let requestId = "01a017b1-3cdd-72e1-9137-94cc6b9a836c"
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.receiveChannelFailed(RealtimeChannelFailed(
            requestId: requestId, sessionId: handle.sessionId,
            reason: "gateway_error_ERR_STREAM_SEQUENCE"
        ))

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.0, requestId)
        XCTAssertEqual(failures.first?.1, "gateway_error_ERR_STREAM_SEQUENCE")
    }

    /// 上一轮的迟到失败态不得污染当前这一轮（同 `stale_channel_ready_dropped`）。
    func testAdapterDropsStaleChannelFailed() {
        let adapter = Self.makeAdapter()
        var failures: [(String, String)] = []
        adapter.onChannelFailed = { failures.append(($0, $1)) }

        let handle = adapter.beginTurn(requestId: "01a017b1-3cdd-72e1-9137-94cc6b9a836c")
        adapter.receiveChannelFailed(RealtimeChannelFailed(
            requestId: "01a017b0-0000-7000-8000-000000000000",
            sessionId: handle.sessionId, reason: "gateway_error_ERR_STREAM_SEQUENCE"
        ))

        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - Helpers

    private func fireDelay(matching delay: TimeInterval) {
        guard let entry = scheduled.last(where: { abs($0.delay - delay) < 0.001 }) else {
            return XCTFail("no scheduled delay matching \(delay)s")
        }
        entry.fire()
    }

    private static func makeAdapter() -> WatchRealtimeMediaAdapter {
        WatchRealtimeMediaAdapter(
            recorder: NoopRecorder(),
            player: NoopPlayer(),
            transport: NoopTransport(),
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: false
        )
    }

    private final class NoopRecorder: WatchRealtimeMediaAdapter.Recorder {
        var onFrame: ((Data) -> Void)?
        var onFailure: ((Error) -> Void)?
        func start() throws {}
        func stop() {}
    }

    private final class NoopPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        var isRenderingDownlink: Bool { false }
        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {}
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {}
        func bargeIn(clearedBytes: Int) {}
        func finish(responseId: String?) {}
        func stop(barge: Bool) {}
    }

    private final class NoopTransport: WatchRealtimeMediaAdapter.Transport {
        func sendStreamStart(_ start: RealtimeStreamStart, conversationId: String?, turnId: String?) {}
        func sendAudioAppend(_ chunk: VoiceStreamChunk, conversationId: String?, turnId: String?) {}
        func sendAudioCommit(_ commit: RealtimeStreamCommit, conversationId: String?, turnId: String?) {}
        func sendPlaybackStarted(handle: RealtimeMediaSession.TurnHandle, responseId: String) {}
        func sendPlaybackEnded(
            handle: RealtimeMediaSession.TurnHandle, responseId: String, bytesPlayed: Int
        ) {}
        func fallbackToCompleteFile(
            handle: RealtimeMediaSession.TurnHandle,
            reason: RealtimeUplinkStream.FallbackReason
        ) {}
        func sendBargeInRequest(_ request: RealtimeBargeInRequest) {}
    }
}

/// 测试用延迟令牌：只记录取消，不真正调度。
private final class Ess960FakeDelayToken: SessionDelayToken {
    func cancel() {}
}
