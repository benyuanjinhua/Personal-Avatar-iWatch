import AVFoundation
import XCTest
@testable import WristAgent_Watch_App

/// ESS-321 watch integration smoke test. Drives `WatchRealtimeMediaAdapter`
/// with mock recorder/player/transport and asserts the coordinator's events
/// are routed to the right seam (transport for uplink, player for playback,
/// single-shot fallback on transport failure).
@MainActor
final class WatchRealtimeMediaAdapterTests: XCTestCase {

    /// ESS-1008 B1: a dead WSS must not truncate PCM already owned by the
    /// Watch player. Failure is held until the real renderer emits `.ended`.
    func testTransportFailureDrainsBufferedAudioBeforeTerminal() {
        let drainTimer = ManualBarrierTimer()
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [
            "10081008-0000-4000-8000-000000000001"
        ], transportFailureDrainTimer: drainTimer)
        let handle = adapter.beginTurn(requestId: "10081008-0000-4000-8000-000000000002")
        var failures: [String] = []
        adapter.onAnswerPlaybackFailed = { _, code in failures.append(code) }
        adapter.ingestDownlink(VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 1, count: 96)
        ))

        adapter.markTransportFailed(reason: "recv_error")

        XCTAssertTrue(player.isRenderingDownlink)
        XCTAssertFalse(player.stopped, "WSS failure must not truncate buffered PCM")
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(
            drainTimer.lastRequestedInterval,
            WatchRealtimeMediaAdapter.transportFailureDrainDeadlineSeconds
        )

        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: nil, bytesPlayed: 96
        ))

        XCTAssertEqual(failures, ["transport_failed:recv_error"])
        XCTAssertTrue(player.stopped, "fallback cleanup runs only after renderer drained")
        XCTAssertFalse(drainTimer.isArmed, "normal drain must cancel the deadline")
    }

    /// ESS-1019: without an audio.done barrier the player cannot emit
    /// `.ended`; the bounded drain deadline must terminate before the
    /// SessionController's 45-second hard timeout instead of hanging forever.
    func testTransportFailureWithoutBarrierTerminatesAtDrainDeadline() {
        let drainTimer = ManualBarrierTimer()
        let (adapter, _, player, _, _) = makeAdapter(
            sessionIds: ["10191019-0000-4000-8000-000000000001"],
            transportFailureDrainTimer: drainTimer
        )
        let handle = adapter.beginTurn(requestId: "10191019-0000-4000-8000-000000000002")
        var failures: [String] = []
        adapter.onAnswerPlaybackFailed = { _, code in failures.append(code) }
        adapter.ingestDownlink(VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 1, count: 96)
        ))

        adapter.markTransportFailed(reason: "recv_error_before_barrier")

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(drainTimer.isArmed)
        XCTAssertLessThan(
            WatchRealtimeMediaAdapter.transportFailureDrainDeadlineSeconds,
            SessionController.thinkingHardTimeoutSeconds
        )

        XCTAssertTrue(drainTimer.fire())
        XCTAssertEqual(failures, ["transport_failed:recv_error_before_barrier"])
        XCTAssertTrue(player.stopped, "deadline terminal must collapse realtime playback")
        XCTAssertFalse(drainTimer.isArmed)
    }

    /// ESS-1008 B1: when no PCM is queued, there is nothing to preserve and
    /// the turn should terminate immediately rather than waiting 45 seconds.
    func testTransportFailureWithoutBufferedAudioTerminatesImmediately() {
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [
            "10081008-0000-4000-8000-000000000003"
        ])
        adapter.beginTurn(requestId: "10081008-0000-4000-8000-000000000004")
        var failures: [String] = []
        adapter.onAnswerPlaybackFailed = { _, code in failures.append(code) }

        adapter.markTransportFailed(reason: "recv_error")

        XCTAssertEqual(failures, ["transport_failed:recv_error"])
        XCTAssertTrue(player.stopped)
    }

    func testVADFinalAutomaticallyCommitsExactlyOnce() {
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let adapter = WatchRealtimeMediaAdapter(
            recorder: recorder,
            player: player,
            transport: transport,
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: true
        )
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        adapter.beginTurn(requestId: "57557557-5575-4575-8575-575575575575")
        // ESS-865：判定门改为「底噪 × 信噪比」后，头 300ms 是底噪预热窗
        // （见 `LocalVADEndpointer.noiseFloorWarmupFrames`）。生产时序本来就是
        // 「起采 → 环境底噪若干帧 → 用户开口」，这里补上这三帧与真机一致。
        for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0)) }
        recorder.feed(Self.pcmFrame(rms: 0.08))
        recorder.feed(Self.pcmFrame(rms: 0.08))
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0)) }
        recorder.feed(Self.pcmFrame(rms: 0))

        XCTAssertTrue(recorder.didStop)
        XCTAssertEqual(transport.commitEvents.count, 1)
        XCTAssertEqual(vadEvents.count, 2)
        guard case .speechFinal(_, .silence) = vadEvents.last else {
            return XCTFail("expected silence speech.final")
        }
    }

    // MARK: - ESS-1023 播放期自激：无 AEC 时麦克风不得喂给 VAD

    /// 2026-08-22 真机（包 `b409fdf`）：用户**一句话都没说**，系统却提交了
    /// 14.7 秒「语音」。
    ///
    /// ```
    /// 12:15:54.991  play_started                     ← 排队播报开始出声
    /// 12:15:55.289  speech_started  rms=0.01574      ← 0.298 秒后 VAD 起判
    ///               speech_frames 8→27→58→93→121     ← 跟着播报一路涨
    /// 12:16:09.988  speech_final  frames=183 speech_frames=121
    /// 12:16:10.481  → thinking                       ← 从此卡住，无法输入
    /// ```
    ///
    /// 根因：ESS-891 把语音打断默认关掉换音量，`.voiceChat` 的 AEC 一并消失。
    /// 没有 AEC 时扬声器输出会被麦克风拾取，VAD 把系统自己的播报判成用户提问。
    /// 既有的 `playbackEndedForVADGuard` 只覆盖**播完之后**的 300ms，
    /// 缺的正是**播放进行中**这一段。
    ///
    /// 本用例钉的是**生产时序**：buffer 入队即可能出声，而 `.started` 回执要等
    /// `.dataPlayedBack`（首个 buffer **播完**）才到——抑制必须在入队时就生效。
    func testPlaybackAudioDoesNotFeedVADWithoutAECFromFirstBuffer() {
        let events = EventLog()
        WatchLog.setObserver { module, event, _, detail, code in
            events.record(module: module, event: event, detail: detail, code: code)
        }
        defer { WatchLog.setObserver(nil) }

        let (adapter, recorder, player, transport) = makeVADAdapter()
        adapter.aecAvailable = { false }   // 语音打断关闭 → .spokenAudio → 无 AEC
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        let handle = adapter.beginTurn(requestId: "10231023-0000-4000-8000-000000000001")
        for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0)) }

        // 首个 buffer 进渲染链路。**还没有任何回执**——生产里 `.started` 要等
        // 这个 buffer 播完才发，那之前的回声正是漏掉的那一段。
        player.enqueue(playables: [Self.playable(responseId: "resp-1")])
        XCTAssertTrue(adapter.isDownlinkAudible, "入队即视为可能出声（fail-closed）")

        // 麦克风拾到的正是扬声器放出来的播报（真机 rms 0.015~0.033 量级）。
        for _ in 0..<20 { recorder.feed(Self.pcmFrame(rms: 0.02)) }

        XCTAssertTrue(
            vadEvents.isEmpty,
            "首个 buffer 回执前的回声也必须不喂 VAD —— 否则系统把自己的播报当成用户提问"
        )
        XCTAssertEqual(transport.commitEvents.count, 0, "更不得把自己的播报提交上行")
        XCTAssertEqual(
            events.count(module: "vad", event: "vad_input_suppressed_during_playback",
                         detailContains: "reason=no_aec"),
            1,
            "整段压制落且只落一条进入取证"
        )

        // buffer 播完 → `.dataPlayedBack` → 引擎这时才发 `.started` + `.ended`。
        player.completeBuffer(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-1"
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-1", bytesPlayed: 2_672_820
        ))
        XCTAssertFalse(adapter.isDownlinkAudible, "渲染链路已排空")

        // 头 3 帧落在既有的 `playbackGuardMs = 300ms` 守卫窗内（扬声器余音），
        // 之后 3 帧是底噪预热，与生产时序一致。
        for _ in 0..<6 { recorder.feed(Self.pcmFrame(rms: 0)) }
        for _ in 0..<2 { recorder.feed(Self.pcmFrame(rms: 0.08)) }
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0)) }

        XCTAssertEqual(vadEvents.count, 2, "播报结束后用户说话必须能起判并断句：\(vadEvents)")
        guard case .speechFinal(_, .silence) = vadEvents.last else {
            return XCTFail("期望 silence 断句，实际 \(String(describing: vadEvents.last))")
        }
        XCTAssertEqual(transport.commitEvents.count, 1, "真正的用户语音必须提交且只提交一次")
        XCTAssertEqual(
            events.count(module: "vad", event: "vad_input_resumed_after_playback",
                         detailContains: "suppressed_frames=20"),
            1,
            "恢复喂帧同样要有取证，否则「永远说不了话」在日志上不可区分"
        )
    }

    /// 一个回合可以携带多个 response（`WatchRealtimeMediaAdapter:308-313`：被顶掉的
    /// 旧 response 仍会发 `.ended`）。抑制状态若是单个 Bool，
    /// `started(old) → started(current) → ended(old)` 会在 current 还在扬声器上
    /// 播着的时候把门打开，自激窗口当场重开。
    func testStaleResponseEndedDoesNotLiftSuppressionWhileCurrentStillPlaying() {
        let events = EventLog()
        WatchLog.setObserver { module, event, _, detail, code in
            events.record(module: module, event: event, detail: detail, code: code)
        }
        defer { WatchLog.setObserver(nil) }

        let (adapter, recorder, player, transport) = makeVADAdapter()
        adapter.aecAvailable = { false }
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        let handle = adapter.beginTurn(requestId: "10231023-0000-4000-8000-000000000002")
        for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0)) }

        // 旧 response 与当前 response 的 buffer 并存在渲染链路里。
        player.enqueue(playables: [Self.playable(responseId: "resp-old")])
        player.enqueue(playables: [Self.playable(responseId: "resp-current")])
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-old"
        ))
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-current"
        ))

        // 旧 response 播完并发 `.ended` —— 当前 response 仍在播。
        player.completeBuffer(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-old", bytesPlayed: 64
        ))

        XCTAssertTrue(adapter.isDownlinkAudible, "current 还在渲染链路里，门不许开")
        for _ in 0..<10 { recorder.feed(Self.pcmFrame(rms: 0.02)) }
        XCTAssertTrue(vadEvents.isEmpty, "被顶掉的 response 的 `.ended` 不得解除抑制：\(vadEvents)")
        XCTAssertEqual(transport.commitEvents.count, 0)
        XCTAssertEqual(
            events.count(module: "vad", event: "vad_input_resumed_after_playback"), 0,
            "此刻不该有任何「恢复喂帧」取证"
        )

        // current 也播完 → 渲染链路排空 → 恢复听用户说话。
        player.completeBuffer(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-current", bytesPlayed: 64
        ))
        XCTAssertFalse(adapter.isDownlinkAudible)

        for _ in 0..<6 { recorder.feed(Self.pcmFrame(rms: 0)) }
        for _ in 0..<2 { recorder.feed(Self.pcmFrame(rms: 0.08)) }
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0)) }

        XCTAssertEqual(vadEvents.count, 2, "当前 response 播完后必须恢复起判断句：\(vadEvents)")
        XCTAssertEqual(transport.commitEvents.count, 1)
        XCTAssertEqual(
            events.count(module: "vad", event: "vad_input_resumed_after_playback",
                         detailContains: "suppressed_frames=10"),
            1
        )
    }

    /// 对照：**有** AEC 时（语音打断开启，`.voiceChat`）不得改变行为——
    /// 那正是 ESS-650 语音打断赖以成立的路径，本修复不许把它一起关掉。
    func testPlaybackAudioStillFeedsVADWhenAECAvailable() {
        let (adapter, recorder, player, transport) = makeVADAdapter()
        adapter.aecAvailable = { true }
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        adapter.beginTurn(requestId: "10231023-0000-4000-8000-000000000003")
        player.enqueue(playables: [Self.playable(responseId: "resp-1")])
        for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0)) }
        for _ in 0..<2 { recorder.feed(Self.pcmFrame(rms: 0.08)) }
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0)) }

        XCTAssertEqual(vadEvents.count, 2, "有 AEC 时播放期行为不得改变：\(vadEvents)")
        XCTAssertEqual(transport.commitEvents.count, 1)
    }

    /// **抑制的判据不能是 `player.isRenderingDownlink`。**
    ///
    /// 它读 `AVAudioPlayerNode.isPlaying`，而 `prepare(for:)` 末尾就
    /// `playerNode.play()`、适配器又在 `beginTurn` 里调 `prepare`——于是它整轮
    /// 恒为 true（运行时取证见
    /// `testRealPlayerReportsRenderingRightAfterPrepareWithNothingEnqueued`）。
    /// 拿它当门，**无 AEC 是生产默认**，用户从此一句话也说不了：比本单要修的
    /// 自激更坏。判据只能是渲染链路里到底有没有音频。
    func testMicrophoneStaysLiveWhilePlayerNodeIsStartedButSilent() {
        let (adapter, recorder, player, transport) = makeVADAdapter()
        adapter.aecAvailable = { false }
        // 与真实引擎同语义：`prepare` 之后 `isRenderingDownlink` 即为 true。
        player.reportsRenderingFromPrepare = true
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        adapter.beginTurn(requestId: "10231023-0000-4000-8000-000000000004")
        XCTAssertTrue(player.isRenderingDownlink, "前提：节点已启动（没有任何音频在放）")
        XCTAssertFalse(adapter.isDownlinkAudible, "渲染链路是空的，就不算在出声")

        for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0)) }
        for _ in 0..<2 { recorder.feed(Self.pcmFrame(rms: 0.08)) }
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0)) }

        XCTAssertEqual(vadEvents.count, 2, "没在出声时必须照常听用户说话：\(vadEvents)")
        XCTAssertEqual(transport.commitEvents.count, 1)
    }

    /// 停播路径（打断 / 取消 / 回退）把排队 buffer 直接丢掉，**不保证**还会有
    /// `.ended` 回执。抑制若挂在这里，用户就再也说不了话。
    func testSuppressionLiftsWhenPlaybackStopsWithoutEndedReceipt() {
        let (adapter, recorder, player, transport) = makeVADAdapter()
        adapter.aecAvailable = { false }
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        adapter.beginTurn(requestId: "10231023-0000-4000-8000-000000000005")
        player.enqueue(playables: [Self.playable(responseId: "resp-1")])
        XCTAssertTrue(adapter.isDownlinkAudible)

        adapter.cancel(reason: .interrupted)

        XCTAssertFalse(adapter.isDownlinkAudible, "停播即排空渲染链路，不等 `.ended`")
        XCTAssertTrue(player.stopped)

        // 下一轮照常起判（`beginTurn` → `prepare` 的清空也在这条路径上被覆盖）。
        adapter.beginTurn(requestId: "10231023-0000-4000-8000-000000000006")
        for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0)) }
        for _ in 0..<2 { recorder.feed(Self.pcmFrame(rms: 0.08)) }
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0)) }

        XCTAssertEqual(vadEvents.count, 2, "取消后的新回合必须能正常起判断句：\(vadEvents)")
        XCTAssertEqual(transport.commitEvents.count, 1)
    }

    private func makeVADAdapter() -> (
        WatchRealtimeMediaAdapter, MockRecorder, MockPlayer, MockTransport
    ) {
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let adapter = WatchRealtimeMediaAdapter(
            recorder: recorder,
            player: player,
            transport: transport,
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: true
        )
        return (adapter, recorder, player, transport)
    }

    /// ESS-1023：一段可播放的下行块。
    private static func playable(responseId: String) -> RealtimeDownlinkPlayback.PlayableChunk {
        RealtimeDownlinkPlayback.PlayableChunk(
            chunk: VoiceStreamChunk(
                requestId: "10231023-0000-4000-8000-000000000001",
                streamId: "11111111-0000-0000-0000-000000000001",
                direction: .downlink, sequence: 0, capturedAtMs: 1,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: 1, count: 64), endOfStream: false
            ),
            responseId: responseId
        )
    }

    // MARK: - ESS-865

    /// 真机断点的闭环回归：`.voiceChat`(AEC) 电平的说话（0.006 RMS，低于历史
    /// 固定门 0.018）必须走完 `PCM frames → speech_final → audio.commit`，
    /// 并且 append 与 commit 挂在同一个 request/turn 上。
    ///
    /// 真机 L1 对照（request_id 01a017b1-3cdd-72e1-9137-94cc6b9a836c）：
    /// 616 帧 `uplink_ack_received`、0 条 `speech_started`、0 条 `speech_final`，
    /// 回合悬到 `session_turn_cap_reached cap_s=58`。
    func testAttenuatedSpeechCompletesFrameToCommitLoopOnOneTurn() {
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let adapter = WatchRealtimeMediaAdapter(
            recorder: recorder,
            player: player,
            transport: transport,
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: true
        )
        var vadEvents: [LocalVADEvent] = []
        adapter.onVADEvent = { vadEvents.append($0) }

        let requestId = "01a017b1-3cdd-72e1-9137-94cc6b9a836c"
        let handle = adapter.beginTurn(requestId: requestId)
        for _ in 0..<3 { recorder.feed(Self.pcmFrame(rms: 0.0005)) }  // 起采后的环境底噪
        for _ in 0..<10 { recorder.feed(Self.pcmFrame(rms: 0.006)) }  // 1s 被 AEC 压低的说话
        for _ in 0..<7 { recorder.feed(Self.pcmFrame(rms: 0.0005)) }  // 700ms 停说

        XCTAssertEqual(vadEvents.count, 2, "必须先起判再断句：\(vadEvents)")
        guard case .speechFinal(_, .silence) = vadEvents.last else {
            return XCTFail("停说 700ms 必须以 silence 断句，实际 \(String(describing: vadEvents.last))")
        }
        XCTAssertEqual(transport.commitEvents.count, 1, "断句必须产生且只产生一次 commit")
        XCTAssertFalse(transport.appendEvents.isEmpty, "commit 之前必须有真实 PCM 上行")
        XCTAssertEqual(transport.commitEvents.first?.requestId, requestId)
        XCTAssertEqual(Set(transport.appendEvents.map(\.requestId)), [requestId])
        XCTAssertTrue(adapter.hasCommittedUplink, "已提交的回合必须可被 PTT 层识别")
        XCTAssertEqual(handle.requestId, requestId)
    }

    /// 取证：每一轮都必须落得下 `vad_level`（能量 + 门限 + 底噪）。
    /// 缺了它，真机上「VAD 为什么不断句」就只能靠猜——本单第一轮真机
    /// 正是因此无法定位（日志里既没有电平也没有门限）。
    func testVADLevelEvidenceIsEmittedForEveryTurn() {
        let events = EventLog()
        WatchLog.setObserver { module, event, _, detail, code in
            events.record(module: module, event: event, detail: detail, code: code)
        }
        defer { WatchLog.setObserver(nil) }

        let recorder = MockRecorder()
        let adapter = WatchRealtimeMediaAdapter(
            recorder: recorder,
            player: MockPlayer(),
            transport: MockTransport(),
            vadConfiguration: LocalVADConfiguration(),
            automaticallyCommitOnSpeechFinal: true
        )
        adapter.beginTurn(requestId: "57557557-5575-4575-8575-575575575575")
        recorder.feed(Self.pcmFrame(rms: 0.0005))

        XCTAssertGreaterThanOrEqual(
            events.count(module: "vad", event: "vad_level", detailContains: "threshold="),
            1,
            "首帧就必须落一条 vad_level，否则「帧没进 VAD」与「进了没跨门」无法区分"
        )
        XCTAssertGreaterThanOrEqual(
            events.count(module: "vad", event: "vad_level", detailContains: "noise_floor="),
            1
        )
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [(module: String, event: String, detail: String?, code: String?)] = []
        func record(module: String, event: String, detail: String?, code: String?) {
            lock.lock(); defer { lock.unlock() }
            records.append((module, event, detail, code))
        }
        func count(module: String, event: String, detailContains fragment: String? = nil) -> Int {
            lock.lock(); defer { lock.unlock() }
            return records.filter {
                $0.module == module && $0.event == event
                    && (fragment == nil || $0.detail?.contains(fragment!) == true)
            }.count
        }
    }

    /// ESS-1023 取证：**真实**播放器的 `isRenderingDownlink` 在 `prepare(for:)`
    /// 之后就为 true，哪怕一个 buffer 都没入队。
    ///
    /// `RealtimePlaybackEngine.swift:128` 读的是 `AVAudioPlayerNode.isPlaying`，
    /// 而 `prepare(for:)` 末尾调用 `playerNode.play()`；适配器又在 `beginTurn`
    /// 里调 `prepare`。所以它的语义是「节点已启动」，**不是**「此刻在出声」——
    /// 拿它当「播放中」的判据，会在整轮聆听期一直成立。
    func testRealPlayerReportsRenderingRightAfterPrepareWithNothingEnqueued() throws {
        try HostedCITestGate.skipIfHostedCI("real AVAudioEngine start in ESS-1023 evidence pin")
        let controller = ConversationAudioController()
        let engine = RealtimePlaybackEngine(
            audioEngine: controller.playbackEngine,
            lifecycleOwner: { .conversation }
        )
        do {
            try controller.beginConversation(conversationId: "ess1023-evidence")
        } catch {
            throw XCTSkip("模拟器会话不可用：\(error.localizedDescription)")
        }
        defer { controller.endConversation(reason: .userExit) }

        let session = RealtimeMediaSession()
        let handle = session.beginTurn(requestId: "10231023-0000-4000-8000-0000000000ff")
        try engine.prepare(for: handle)

        XCTAssertTrue(
            engine.isRenderingDownlink,
            "证据：一个 buffer 都没入队，isRenderingDownlink 已为 true"
        )
        XCTAssertFalse(
            engine.hasAudioInRenderPipeline,
            "对照：渲染链路是空的——这才是「此刻会不会出声」的诚实读点"
        )
    }

    /// ESS-1023 取证（复审阻断 2）：抑制必须在**首个 buffer 进渲染链路时**就
    /// 生效，而不是等 `.started` 回执。
    ///
    /// `RealtimePlaybackEngine` 的 `.started` 由 `didCompleteBuffer` 发出，后者
    /// 挂在 `scheduleBuffer(completionCallbackType: .dataPlayedBack)` 上——按
    /// Apple 的语义，那是 buffer **已经播完**之后。用真实引擎钉住两端：
    /// 入队即 `hasAudioInRenderPipeline == true`（回执之前），播完后回落为 false
    /// 且此时才收到 `.started` / `.ended`。
    func testRealPlayerMarksRenderPipelineBusyBeforeAnyReceiptArrives() throws {
        try HostedCITestGate.skipIfHostedCI("real AVAudioEngine playback in ESS-1023 evidence pin")
        let controller = ConversationAudioController()
        let engine = RealtimePlaybackEngine(
            audioEngine: controller.playbackEngine,
            lifecycleOwner: { .conversation }
        )
        do {
            try controller.beginConversation(conversationId: "ess1023-pipeline")
        } catch {
            throw XCTSkip("模拟器会话不可用：\(error.localizedDescription)")
        }
        defer { controller.endConversation(reason: .userExit) }

        var receipts: [String] = []
        engine.onPlaybackEvent = { event in
            switch event {
            case .started: receipts.append("started")
            case .ended: receipts.append("ended")
            case .bargedIn: receipts.append("bargedIn")
            case .failed: receipts.append("failed")
            }
        }

        let session = RealtimeMediaSession()
        let handle = session.beginTurn(requestId: "10231023-0000-4000-8000-0000000000fe")
        try engine.prepare(for: handle)
        engine.enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk(
            chunk: VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: 0, capturedAtMs: 1,
                codec: "pcm_s16le", sampleRate: 24_000,
                // 24kHz / 16-bit ≈ 100ms 音频，够真实渲染一小段。
                payload: Data(repeating: 0, count: 4_800),
                endOfStream: false
            ),
            responseId: "resp-real"
        )])

        XCTAssertTrue(
            engine.hasAudioInRenderPipeline,
            "入队即置位：这一段正是 `.started` 回执覆盖不到的窗口"
        )
        XCTAssertTrue(receipts.isEmpty, "证据：此刻一条回执都还没发出来")

        let drained = XCTestExpectation(description: "render pipeline drains")
        Task { @MainActor in
            for _ in 0..<100 {
                if !engine.hasAudioInRenderPipeline { drained.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        wait(for: [drained], timeout: 6)
        XCTAssertTrue(receipts.contains("started"), "回执在 buffer 播完之后才到：\(receipts)")
    }

    private static func pcmFrame(rms: Double) -> Data {
        var sample = Int16((rms * Double(Int16.max)).rounded()).littleEndian
        let bytes = withUnsafeBytes(of: &sample) { Data($0) }
        var data = Data(capacity: 3_200)
        for _ in 0..<1_600 { data.append(bytes) }
        return data
    }

    func testRealtimePlaybackAudioSessionGateActivatesOncePerTurn() throws {
        var gate = RealtimePlaybackAudioSessionGate()
        var activations = 0

        try gate.activate { activations += 1 }
        try gate.activate { activations += 1 }

        XCTAssertTrue(gate.isActivated)
        XCTAssertEqual(activations, 1)

        gate.reset()
        try gate.activate { activations += 1 }
        XCTAssertEqual(activations, 2)
    }

    func testRealtimePlaybackAudioSessionGateRetriesAfterActivationFailure() {
        enum Failure: Error { case rejected }
        var gate = RealtimePlaybackAudioSessionGate()
        var attempts = 0

        XCTAssertThrowsError(try gate.activate {
            attempts += 1
            throw Failure.rejected
        })
        XCTAssertFalse(gate.isActivated)

        XCTAssertNoThrow(try gate.activate { attempts += 1 })
        XCTAssertTrue(gate.isActivated)
        XCTAssertEqual(attempts, 2)
    }

    func testRenderRecoveryAlwaysRestartsOnFirstDeltaAfterSessionActivation() {
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartEngine(
            firstDeltaAfterSessionActivation: true,
            engineIsRunning: true
        ), "AVAudioEngine may report running after the shared session lost its output route")
    }

    func testRenderRecoveryRestartsStoppedEngineOnLaterDelta() {
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartEngine(
            firstDeltaAfterSessionActivation: false,
            engineIsRunning: false
        ))
    }

    func testRenderRecoveryDoesNotRestartHealthyEngineOrNode() {
        XCTAssertFalse(RealtimeRenderRecoveryPolicy.shouldRestartEngine(
            firstDeltaAfterSessionActivation: false,
            engineIsRunning: true
        ))
        XCTAssertFalse(RealtimeRenderRecoveryPolicy.shouldRestartNode(
            engineWasRestarted: false,
            nodeIsPlaying: true
        ))
    }

    func testRenderRecoveryRestartsNodeWheneverEngineWasRestarted() {
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartNode(
            engineWasRestarted: true,
            nodeIsPlaying: true
        ))
        XCTAssertTrue(RealtimeRenderRecoveryPolicy.shouldRestartNode(
            engineWasRestarted: false,
            nodeIsPlaying: false
        ))
    }

    private final class MockRecorder: WatchRealtimeMediaAdapter.Recorder {
        var onFrame: ((Data) -> Void)?
        var onFailure: ((Error) -> Void)?
        private(set) var didStart = false
        private(set) var didStop = false

        func start() throws { didStart = true }
        func stop() { didStop = true }

        func feed(_ data: Data) { onFrame?(data) }
        func fail(_ error: Error) { onFailure?(error) }
    }

    private final class MockPlayer: WatchRealtimeMediaAdapter.Player {
        var onPlaybackEvent: ((RealtimePlaybackEngine.PlaybackEvent) -> Void)?
        private(set) var preparedFor: RealtimeMediaSession.TurnHandle?
        private(set) var enqueuedPlayables: [RealtimeDownlinkPlayback.PlayableChunk] = []
        private(set) var bargedInBytes: [Int] = []
        /// ESS-442 B1 adapter-level regression: prove `player.finish(...)`
        /// is invoked *exactly once* on the sync-release + late-chunk trace,
        /// not just "was called at least once".
        private(set) var finishInvocations: [String?] = []
        var finished: Bool { !finishInvocations.isEmpty }
        var finishCount: Int { finishInvocations.count }
        private(set) var stopped = false
        /// ESS-650：与真实引擎同语义——入队即出声，`bargeIn`/`stop` 即静音。
        private(set) var isRenderingDownlink = false
        /// ESS-1023：与真实引擎同语义——`scheduleBuffer` 前置位，
        /// `.dataPlayedBack` 完成回调后减一，`stop`/`bargeIn` 清零。
        private(set) var pendingRenderedBuffers = 0
        var hasAudioInRenderPipeline: Bool { pendingRenderedBuffers > 0 }

        var enqueuedChunks: [VoiceStreamChunk] { enqueuedPlayables.map(\.chunk) }

        /// ESS-1023：真实引擎的 `isRenderingDownlink` 读 `playerNode.isPlaying`，
        /// `prepare(for:)` 末尾就 `play()` 了——置真即复现该语义。
        var reportsRenderingFromPrepare = false

        func prepare(for turn: RealtimeMediaSession.TurnHandle) throws {
            preparedFor = turn
            if reportsRenderingFromPrepare { isRenderingDownlink = true }
        }
        func enqueue(playables: [RealtimeDownlinkPlayback.PlayableChunk]) {
            enqueuedPlayables.append(contentsOf: playables)
            if !playables.isEmpty { isRenderingDownlink = true }
            pendingRenderedBuffers += playables.count
        }
        func bargeIn(clearedBytes: Int) {
            bargedInBytes.append(clearedBytes)
            isRenderingDownlink = false
            pendingRenderedBuffers = 0
        }

        /// ESS-1023：模拟真实引擎的 `.dataPlayedBack` 完成回调——**buffer 已经
        /// 播完**才轮到它，回执正是在这之后才发出去的。
        func completeBuffer(_ event: RealtimePlaybackEngine.PlaybackEvent? = nil) {
            pendingRenderedBuffers = max(0, pendingRenderedBuffers - 1)
            if let event { onPlaybackEvent?(event) }
        }
        func finish(responseId: String?) { finishInvocations.append(responseId) }
        func stop(barge: Bool) {
            stopped = true
            isRenderingDownlink = false
            pendingRenderedBuffers = 0
        }
    }

    private final class MockTransport: WatchRealtimeMediaAdapter.Transport {
        private(set) var startEvents: [RealtimeStreamStart] = []
        private(set) var appendEvents: [VoiceStreamChunk] = []
        private(set) var commitEvents: [RealtimeStreamCommit] = []
        private(set) var playbackStartEvents: [(RealtimeMediaSession.TurnHandle, String)] = []
        private(set) var playbackEndEvents: [(RealtimeMediaSession.TurnHandle, String, Int)] = []
        private(set) var fallbackEvents: [(RealtimeMediaSession.TurnHandle,
                                          RealtimeUplinkStream.FallbackReason)] = []
        private(set) var bargeInRequests: [RealtimeBargeInRequest] = []
        private(set) var identities: [(String?, String?)] = []

        func sendStreamStart(_ start: RealtimeStreamStart, conversationId: String?, turnId: String?) {
            startEvents.append(start); identities.append((conversationId, turnId))
        }
        func sendAudioAppend(_ chunk: VoiceStreamChunk, conversationId: String?, turnId: String?) {
            appendEvents.append(chunk); identities.append((conversationId, turnId))
        }
        func sendAudioCommit(_ commit: RealtimeStreamCommit, conversationId: String?, turnId: String?) {
            commitEvents.append(commit); identities.append((conversationId, turnId))
        }
        func sendPlaybackStarted(handle: RealtimeMediaSession.TurnHandle, responseId: String) {
            playbackStartEvents.append((handle, responseId))
        }
        func sendPlaybackEnded(handle: RealtimeMediaSession.TurnHandle,
                               responseId: String, bytesPlayed: Int) {
            playbackEndEvents.append((handle, responseId, bytesPlayed))
        }
        func fallbackToCompleteFile(handle: RealtimeMediaSession.TurnHandle,
                                    reason: RealtimeUplinkStream.FallbackReason) {
            fallbackEvents.append((handle, reason))
        }
        func sendBargeInRequest(_ request: RealtimeBargeInRequest) {
            bargeInRequests.append(request)
        }
    }

    private final class FallbackCounter {
        private(set) var invocations: [(RealtimeMediaSession.TurnHandle,
                                        RealtimeUplinkStream.FallbackReason)] = []
        func record(_ handle: RealtimeMediaSession.TurnHandle,
                    _ reason: RealtimeUplinkStream.FallbackReason) {
            invocations.append((handle, reason))
        }
    }

    /// ESS-527 test double for the internal barrier timer. Captures the most
    /// recent `arm(...)` callback so the test can fire it synchronously
    /// without depending on wall-clock `Task.sleep`. `@MainActor` because
    /// `BarrierTimer` requirements are actor-isolated and the callback the
    /// tests want to fire is `@MainActor () -> Void`.
    @MainActor
    final class ManualBarrierTimer: WatchRealtimeMediaAdapter.BarrierTimer {
        private(set) var armCount = 0
        private(set) var cancelCount = 0
        private(set) var lastRequestedInterval: TimeInterval?
        private var pending: (@MainActor () -> Void)?

        var isArmed: Bool { pending != nil }

        nonisolated init() {}

        func arm(after seconds: TimeInterval, fire: @escaping @MainActor () -> Void) {
            armCount += 1
            lastRequestedInterval = seconds
            pending = fire
        }

        func cancel() {
            cancelCount += 1
            pending = nil
        }

        /// Simulate the sleep expiring. Returns whether a callback fired.
        @discardableResult
        func fire() -> Bool {
            guard let callback = pending else { return false }
            pending = nil
            callback()
            return true
        }
    }

    /// ESS-1002：`downlink_drop reason=…` 只经由适配器的 `logger` 闭包落地
    /// （`WatchLog` 那条只覆盖 generation 类丢弃），所以要断言 `sessionEnded`
    /// 有没有发生，必须能接住这条线。
    private final class LoggerSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        func count(containing fragment: String) -> Int {
            all.filter { $0.contains(fragment) }.count
        }
    }

    private func makeAdapter(
        sessionIds: [String],
        barrierTimer: WatchRealtimeMediaAdapter.BarrierTimer = TaskBasedBarrierTimer(),
        transportFailureDrainTimer: WatchRealtimeMediaAdapter.BarrierTimer = TaskBasedBarrierTimer(),
        loggerSink: LoggerSink? = nil
    ) -> (
        WatchRealtimeMediaAdapter, MockRecorder, MockPlayer, MockTransport, FallbackCounter
    ) {
        let recorder = MockRecorder()
        let player = MockPlayer()
        let transport = MockTransport()
        let counter = FallbackCounter()
        var index = 0
        var clock: Int64 = 0
        let session = RealtimeMediaSession(
            configuration: RealtimeMediaSession.Configuration(
                uplinkFrameBytes: 64,
                maxInFlightUplinkBytes: 8 * 1024,
                maxDownlinkBufferBytes: 4 * 1024
            ),
            now: { clock += 10; return clock },
            sessionIdFactory: {
                defer { index += 1 }
                return sessionIds[min(index, sessionIds.count - 1)]
            }
        )
        let adapter = WatchRealtimeMediaAdapter(
            session: session, recorder: recorder, player: player, transport: transport,
            fullFileFallback: { handle, reason in counter.record(handle, reason) },
            logger: { line in loggerSink?.append(line) },
            barrierTimer: barrierTimer,
            transportFailureDrainTimer: transportFailureDrainTimer
        )
        return (adapter, recorder, player, transport, counter)
    }

    func testFullTurnRoutesUplinkToTransportAndDownlinkToPlayer() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, recorder, player, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        let handle = adapter.beginTurn(requestId: requestId)
        XCTAssertTrue(recorder.didStart)
        XCTAssertEqual(player.preparedFor, handle)
        recorder.feed(Data(repeating: 0x11, count: 128)) // 2 frames of 64 bytes
        adapter.commit()

        XCTAssertEqual(transport.startEvents.count, 1)
        XCTAssertEqual(transport.appendEvents.map(\.sequence), [0, 1])
        XCTAssertEqual(transport.commitEvents.count, 1)

        // Simulate downlink chunk from iPhone → adapter → player.
        let downlinkChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1_800_000_000_000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x22, count: 96)
        )
        adapter.ingestDownlink(downlinkChunk)
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0])
    }

    func testUplinkAckReleasesBudgetAndLogsRuntimeReceipt() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, recorder, _, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        let handle = adapter.beginTurn(requestId: requestId)
        recorder.feed(Data(repeating: 0x11, count: 64))
        let chunk = try! XCTUnwrap(transport.appendEvents.first)

        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))
        // Duplicate receipt is ignored by the byte ledger and produces no
        // second accepted-ACK log event.
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))

        recorder.feed(Data(repeating: 0x22, count: 64))
        adapter.commit()
        XCTAssertEqual(transport.appendEvents.map(\.sequence), [0, 1])
        XCTAssertEqual(transport.commitEvents.first?.sequence, 1)
    }

    /// ESS-573：首个被对端接受的 uplink ack = 通道就绪的唯一真实信号，
    /// 每回合只发一次（复审硬约束：不得同步宣告 ready）。
    func testFirstAcceptedAckSignalsChannelReadyOncePerTurn() {
        let requestId = "44444444-4444-4444-4444-444444440573"
        let (adapter, recorder, _, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555550573"
        ])
        var readyEvents: [String] = []
        adapter.onChannelReady = { readyEvents.append($0) }

        let handle = adapter.beginTurn(requestId: requestId)
        // 发起录音本身不得触发 ready（无同步宣告）。
        XCTAssertTrue(readyEvents.isEmpty)

        recorder.feed(Data(repeating: 0x11, count: 64))
        let chunk = try! XCTUnwrap(transport.appendEvents.first)

        // 错误身份的 ack 不得触发 ready。
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: "99999999-9999-9999-9999-999999999999",
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))
        XCTAssertTrue(readyEvents.isEmpty)

        // 首个被接受的 ack 触发一次。
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: chunk.sequence,
            byteCount: chunk.payload.count
        ))
        XCTAssertEqual(readyEvents, [requestId])

        // 同回合后续 ack 不再触发。
        recorder.feed(Data(repeating: 0x22, count: 64))
        let second = try! XCTUnwrap(transport.appendEvents.last)
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: handle.requestId,
            sessionId: handle.sessionId,
            sequence: second.sequence,
            byteCount: second.payload.count
        ))
        XCTAssertEqual(readyEvents, [requestId])
    }

    func testTransportReadySignalsBeforeUserSpeaksAndRejectsStaleTurn() {
        let requestId = "44444444-4444-4444-4444-444444440695"
        let sessionId = "55555555-5555-5555-5555-555555550695"
        let (adapter, _, _, _, _) = makeAdapter(sessionIds: [sessionId])
        var readyEvents: [String] = []
        adapter.onChannelReady = { readyEvents.append($0) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.receiveChannelReady(RealtimeChannelReady(
            requestId: "99999999-9999-9999-9999-999999999999",
            sessionId: handle.sessionId
        ))
        XCTAssertTrue(readyEvents.isEmpty)

        adapter.receiveChannelReady(RealtimeChannelReady(
            requestId: handle.requestId,
            sessionId: handle.sessionId
        ))
        adapter.receiveChannelReady(RealtimeChannelReady(
            requestId: handle.requestId,
            sessionId: handle.sessionId
        ))
        XCTAssertEqual(readyEvents, [requestId])
    }

    /// ESS-573：新回合重置 ready 信号——下一回合的首个 ack 必须再次触发
    /// （多轮会话里每轮的就绪都要能独立确认）。
    func testChannelReadyRearoundsForNextTurn() {
        let (adapter, recorder, _, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555550001",
            "55555555-5555-5555-5555-555555550002"
        ])
        var readyEvents: [String] = []
        adapter.onChannelReady = { readyEvents.append($0) }

        let first = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444440001")
        recorder.feed(Data(repeating: 0x11, count: 64))
        let firstChunk = try! XCTUnwrap(transport.appendEvents.last)
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: first.requestId, sessionId: first.sessionId,
            sequence: firstChunk.sequence, byteCount: firstChunk.payload.count
        ))

        let second = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444440002")
        recorder.feed(Data(repeating: 0x33, count: 64))
        let secondChunk = try! XCTUnwrap(transport.appendEvents.last)
        adapter.receiveUplinkAck(RealtimeUplinkAck(
            requestId: second.requestId, sessionId: second.sessionId,
            sequence: secondChunk.sequence, byteCount: secondChunk.payload.count
        ))

        XCTAssertEqual(readyEvents, [first.requestId, second.requestId])
    }

    /// ESS-573：快速上行死亡（采集 tap 失败 → 传输失败兜底）如实上报，
    /// 会话层据此刻意告知并退出——「不假装还在对话」。
    func testUplinkTransportFailureSignalsFallbackEvent() {
        let requestId = "44444444-4444-4444-4444-444444440574"
        let (adapter, recorder, _, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555550574"
        ])
        var fallbackEvents: [String] = []
        adapter.onUplinkFallback = { fallbackEvents.append($0) }

        enum FakeRecorderError: Error { case tapDied }
        adapter.beginTurn(requestId: requestId)
        recorder.fail(FakeRecorderError.tapDied)

        XCTAssertEqual(fallbackEvents, [requestId])
    }

    func testRealPlaybackCompletionEmitsDeliveryReceiptAndWatchLog() {
        let requestId = "44444444-4444-4444-4444-444444445216"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555216"
        ])
        final class LogSink { var events: [(String, String?)] = [] }
        let sink = LogSink()
        WatchLog.setObserver { _, event, _, detail, _ in sink.events.append((event, detail)) }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-final", bytesPlayed: 4_800
        ))

        XCTAssertEqual(transport.playbackEndEvents.count, 1)
        XCTAssertEqual(transport.playbackEndEvents.first?.1, "resp-final")
        XCTAssertEqual(transport.playbackEndEvents.first?.2, 4_800)
        let delivered = sink.events.first { $0.0 == "result_delivered_after_render" }
        XCTAssertNotNil(delivered)
        XCTAssertTrue(delivered?.1?.contains("response_id=resp-final bytes_played=4800") == true)
    }

    func testTransportFailureTriggersOneShotCompleteFileFallback() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, recorder, _, transport, counter) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        _ = adapter.beginTurn(requestId: requestId)
        recorder.feed(Data(repeating: 0x11, count: 64))
        recorder.fail(NSError(domain: "test", code: 1))
        // Second failure signal must be absorbed.
        recorder.fail(NSError(domain: "test", code: 2))
        XCTAssertEqual(transport.fallbackEvents.count, 1)
        XCTAssertTrue(adapter.didTriggerCompleteFileFallback)
        // Full-file fallback closure invoked exactly once — proves the
        // adapter actually executes the reliable path, not just signals it.
        XCTAssertEqual(counter.invocations.count, 1)
        XCTAssertEqual(counter.invocations.first?.0.requestId, requestId)
    }

    func testZeroPCMFramesFallsBackToCompleteFileOnCommit() {
        let requestId = "44444444-4444-4444-4444-444444444444"
        let (adapter, _, _, transport, counter) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555"
        ])
        _ = adapter.beginTurn(requestId: requestId)

        adapter.commit()

        XCTAssertTrue(transport.commitEvents.isEmpty)
        XCTAssertEqual(transport.fallbackEvents.map(\.1), [.noAudioFrames])
        XCTAssertEqual(counter.invocations.map(\.1), [.noAudioFrames])
    }

    func testAdapterStampsRealBridgeResponseIdOnReceipts() {
        // ESS-330: two responses arrive within the same session; playback
        // receipts must echo the actual response_id observed on delta, not
        // the fabricated session id.
        let requestId = "44444444-4444-4444-4444-4444444444a0"
        let sessionId = "55555555-5555-5555-5555-55555555a000"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [sessionId])
        let handle = adapter.beginTurn(requestId: requestId)

        let chunkA = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x11, count: 48)
        )
        adapter.ingestDownlink(chunkA, responseId: "resp-alpha")
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-alpha"
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-alpha", bytesPlayed: 48
        ))

        // Second response with different response_id.
        let chunkB = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 1, capturedAtMs: 2,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x22, count: 48)
        )
        adapter.ingestDownlink(chunkB, responseId: "resp-beta")
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-beta"
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-beta", bytesPlayed: 48
        ))

        XCTAssertEqual(transport.playbackStartEvents.map(\.1), ["resp-alpha", "resp-beta"])
        XCTAssertEqual(transport.playbackEndEvents.map(\.1), ["resp-alpha", "resp-beta"])
        XCTAssertNotEqual(transport.playbackStartEvents.first?.1, handle.sessionId,
                          "session_id must not be used as response_id")
    }

    func testRealtimePlaybackStartedHasDedicatedLifecycleCallback() {
        let requestId = "44444444-4444-4444-4444-4444444444b0"
        let sessionId = "55555555-5555-5555-5555-55555555b000"
        let (adapter, recorder, player, _, _) = makeAdapter(sessionIds: [sessionId])
        var playbackStartedCount = 0
        adapter.onRealtimePlaybackStarted = { playbackStartedCount += 1 }
        let handle = adapter.beginTurn(requestId: requestId)

        // A fallback resolves the pending hold but must not claim that real
        // playback started; the breather still protects the fallback wait.
        recorder.fail(NSError(domain: "test", code: 1))
        XCTAssertEqual(playbackStartedCount, 0)

        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-start"
        ))
        XCTAssertEqual(playbackStartedCount, 1)
    }

    func testPlaybackReceiptsAreForwardedToTransport() {
        let requestId = "44444444-4444-4444-4444-444444444440"
        let (adapter, _, player, transport, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555559"
        ])
        let handle = adapter.beginTurn(requestId: requestId)
        // Simulate the player firing real started/ended receipts with a real
        // response_id — nil ids no longer produce receipts (ESS-330 v3).
        player.onPlaybackEvent?(.started(
            requestId: handle.requestId, sessionId: handle.sessionId, responseId: "resp-x"
        ))
        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-x", bytesPlayed: 2_048
        ))
        XCTAssertEqual(transport.playbackStartEvents.count, 1)
        XCTAssertEqual(transport.playbackStartEvents.first?.1, "resp-x")
        XCTAssertEqual(transport.playbackEndEvents.count, 1)
        XCTAssertEqual(transport.playbackEndEvents.first?.2, 2_048)
    }

    func testAudioDoneAndPlayerEndedKeepRealtimeTurnAliveForNextResponse() {
        let requestId = "44444444-4444-4444-4444-444444444449"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555559"
        ])
        let handle = adapter.beginTurn(requestId: requestId)

        adapter.markDownlinkComplete(responseId: "resp-late")
        XCTAssertTrue(player.finished)
        XCTAssertEqual(adapter.currentTurn, handle,
                       "audio.done is only a drain marker; it must not clear the turn")

        let lateChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x33, count: 96)
        )
        adapter.ingestDownlink(lateChunk, responseId: "resp-late")
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0])

        player.onPlaybackEvent?(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "resp-late", bytesPlayed: 96
        ))
        XCTAssertEqual(adapter.currentTurn, handle,
                       "response ended must not close a multi-response realtime turn")

        let nextResponseChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 1, capturedAtMs: 2,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x44, count: 96)
        )
        adapter.ingestDownlink(nextResponseChunk, responseId: "resp-next")
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0, 1])
    }

    func testExplicitCancelClosesTurnAndRejectsLateChunks() {
        let requestId = "44444444-4444-4444-4444-444444444450"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555560"
        ])
        let handle = adapter.beginTurn(requestId: requestId)

        adapter.cancel()

        XCTAssertNil(adapter.currentTurn)
        XCTAssertTrue(player.stopped)

        let lateChunk = VoiceStreamChunk(
            requestId: handle.requestId, streamId: handle.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x55, count: 96)
        )
        adapter.ingestDownlink(lateChunk, responseId: "resp-cancelled")
        XCTAssertTrue(player.enqueuedChunks.isEmpty)
    }

    func testNewTurnBargesInAndPlayerClearsPriorPlayback() {
        let (adapter, recorder, player, _, _) = makeAdapter(sessionIds: [
            "55555555-5555-5555-5555-555555555555",
            "66666666-6666-6666-6666-666666666666"
        ])
        let first = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444444441")
        recorder.feed(Data(repeating: 0x11, count: 64))
        let firstDownlink = VoiceStreamChunk(
            requestId: first.requestId, streamId: first.sessionId,
            direction: .downlink, sequence: 0, capturedAtMs: 1, codec: "pcm_s16le",
            sampleRate: 24_000, payload: Data(repeating: 0x22, count: 96)
        )
        adapter.ingestDownlink(firstDownlink)
        let second = adapter.beginTurn(requestId: "44444444-4444-4444-4444-444444444442")
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        // The player must have been asked to prepare for the new turn AND to
        // stop (barge) the prior playback via the coordinator.
        XCTAssertEqual(player.preparedFor, second)

        let staleChunk = VoiceStreamChunk(
            requestId: first.requestId, streamId: first.sessionId,
            direction: .downlink, sequence: 1, capturedAtMs: 2, codec: "pcm_s16le",
            sampleRate: 24_000, payload: Data(repeating: 0x33, count: 96)
        )
        adapter.ingestDownlink(staleChunk, responseId: "resp-stale")
        XCTAssertEqual(player.enqueuedChunks.map(\.sequence), [0],
                       "a new turn must reject late chunks from the replaced turn")
    }

    // MARK: - ESS-442 B1 adapter-level regression (毕玄 REQUEST CHANGES)

    /// Closes the loop 毕玄 flagged in his non-author review of #173: the
    /// coordinator-level test in `Tests/Ess442RegressionTests.swift` only
    /// counts `RealtimeMediaSession.Event`s, so it can't directly assert
    /// the three ESS-442 acceptance items on the `WatchRealtimeMediaAdapter`
    /// seam:
    ///
    ///   1. `player.finish(responseId:)` fires **exactly once**
    ///   2. WatchLog `done_barrier_released` is emitted **exactly once**
    ///   3. That unique log line contains `waited_ms=0` (proving the sync
    ///      path — not the async `.doneBarrierReleased` path — emitted it)
    ///
    /// Pre-fix trace on cd86154: two `player.finish`, two logs, one
    /// missing `waited_ms=0`. Post-fix: one `player.finish`, one log,
    /// present `waited_ms=0`.
    func testEss442B1_AdapterEmitsSingleFinishAndSingleReleaseLogWithWaitedMs() {
        let requestId = "44444444-4442-4442-4442-444444424b01"
        let sessionId = "55555555-5555-5555-5555-555555555b01"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [sessionId])

        struct LogEvent {
            let module: String
            let event: String
            let detail: String?
        }
        // Serial dispatch of observer callbacks is guaranteed by WatchLog's
        // internal lock, so a plain array captured by a class ref is safe.
        final class LogSink { var events: [LogEvent] = [] }
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.events.append(LogEvent(module: module, event: event, detail: detail))
        }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)

        // Seq 0..2 delivered in order under generation 1.
        for i in 0..<3 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-B1", generation: 1
            )
        }
        // Synchronous barrier release path: done arrives after 0..2 already
        // emitted, so `markDone` returns `.barrierReleased` immediately and
        // the adapter's `.doneArrived(.barrierReleased)` branch fires
        // `player.finish` + the `waited_ms=0` log.
        adapter.markDownlinkComplete(
            responseId: "r-B1", generation: 1, finalSequence: 2
        )

        // The regression trigger: a duplicate / late downlink chunk after
        // the sync release. Pre-fix this would go through the coordinator's
        // `checkBarrierRelease()` tail and produce a second
        // `.doneBarrierReleased` → second `player.finish` + second log line.
        adapter.ingestDownlink(
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: 2,
                capturedAtMs: 1_800_000_000_002,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: 2, count: 64)
            ),
            responseId: "r-B1", generation: 1
        )

        // Acceptance 1: player.finish exactly once, carrying the right rid.
        XCTAssertEqual(
            player.finishCount, 1,
            "player.finish(...) must be invoked exactly once — a second call after sync release is the B1 regression"
        )
        XCTAssertEqual(player.finishInvocations.first as? String, "r-B1")

        // Acceptance 2 + 3: done_barrier_released emitted exactly once, and
        // the unique line contains `waited_ms=0` (marker for the sync path).
        let releaseLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_released"
        }
        XCTAssertEqual(
            releaseLogs.count, 1,
            "done_barrier_released must be logged exactly once — a duplicate line is R-02 evidence pollution (B1)"
        )
        let detail = releaseLogs.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("waited_ms=0"),
            "the unique done_barrier_released line must carry waited_ms=0 (sync path marker); got detail=\(detail)"
        )
        XCTAssertTrue(
            detail.contains("final_seq=2"),
            "the unique done_barrier_released line must carry final_seq=2; got detail=\(detail)"
        )
    }

    // MARK: - ESS-1002 异步段落屏障

    /// ESS-1002：`audio.segment_done` 先到、尾帧后到时，屏障走**异步**释放路径
    /// （`receiveDownlink` 尾部的 `checkBarrierRelease()`）。整改前该路径无条件
    /// `downlink.endSession()`，于是第二段每一帧都被判 `.sessionEnded`——
    /// 2026-08-22 真机 `request_id=01a027f8-fcc3` 上 10 帧整段消失就是这条。
    ///
    /// 本用例是 watchOS 模拟器进程内的运行时证据（R-02.1）：断言第二段既没有
    /// `downlink_drop reason=sessionEnded`，也真的进了播放器队列。
    func testEss1002_AsyncSegmentBarrierKeepsNextSegmentPlayable() {
        let requestId = "44444444-4444-4444-4444-444444441002"
        let sessionId = "55555555-5555-5555-5555-555555551002"
        let sink = LoggerSink()
        let (adapter, _, player, _, _) = makeAdapter(
            sessionIds: [sessionId], loggerSink: sink
        )
        adapter.onAnswerPlaybackSegmentFinished = { _, _ in }
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)

        func delta(_ seq: Int) -> VoiceStreamChunk {
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: seq,
                capturedAtMs: 1_800_000_000_000 + Int64(seq),
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: UInt8(seq), count: 64)
            )
        }

        // 第一段：只到了 seq 0，控制帧先于尾帧到达 → 屏障 waiting。
        adapter.ingestDownlink(delta(0), responseId: "r-1002", generation: 1)
        adapter.markDownlinkSegmentComplete(
            responseId: "r-1002", generation: 1, finalSequence: 2, segmentIndex: 0
        )
        XCTAssertEqual(player.finishCount, 0, "屏障还在等，不得提前 drain")

        // 尾帧补齐 → 异步释放本段。
        adapter.ingestDownlink(delta(1), responseId: "r-1002", generation: 1)
        adapter.ingestDownlink(delta(2), responseId: "r-1002", generation: 1)
        XCTAssertEqual(player.finishCount, 1, "补齐后本段必须收口播完")

        // 工具跑完，第二段到达。
        let enqueuedBefore = player.enqueuedChunks.count
        adapter.ingestDownlink(delta(3), responseId: "r-1002", generation: 1)
        adapter.ingestDownlink(delta(4), responseId: "r-1002", generation: 1)

        XCTAssertEqual(
            sink.count(containing: "downlink_drop reason=sessionEnded"), 0,
            "第二段被判 sessionEnded —— 真机整段消失的复现条件，实际日志=\(sink.all)"
        )
        XCTAssertEqual(
            player.enqueuedChunks.count, enqueuedBefore + 2,
            "第二段的 delta 必须进播放队列才可能出声"
        )
        XCTAssertEqual(player.enqueuedChunks.suffix(2).map(\.sequence), [3, 4])
    }

    // MARK: - ESS-1070 增量语音：段落边界与回合终态的分流

    /// ESS-1070 B1：被 generation 门禁**丢弃**的 `audio.segment_done` 不得置位
    /// 段落边界标志。
    ///
    /// 复现时序（打断后的 pending 窗口，iPhone 换代要等 `cancel.ack`，
    /// 期间仍在转发旧代下行）：
    /// 1. 用户打断 → Watch 门禁进入 `.pending`；
    /// 2. 旧代在途的 `audio.segment_done` 到达 → 被判 `droppedPendingGeneration`；
    /// 3. 新一代答案播完 → 那唯一一次 `.ended` 被当成**段落**边界，
    ///    `onAnswerPlaybackFinished` 永不触发，回合只能等 45s 硬超时。
    func testEss1070_DroppedSegmentDoneDoesNotSwallowTurnCompletion() {
        let requestId = "44444444-4444-4444-4444-444444441070"
        let sessionId = "55555555-5555-5555-5555-555555551070"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [sessionId])
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        var segmentFinished = 0
        var answerFinished = 0
        adapter.onAnswerPlaybackSegmentFinished = { _, _ in segmentFinished += 1 }
        adapter.onAnswerPlaybackFinished = { _, _ in answerFinished += 1 }

        // 打断：门禁进入 pending，旧代下行全部丢弃。
        adapter.bargeIn()
        adapter.markDownlinkSegmentComplete(
            responseId: "r-old", generation: 1, finalSequence: 0, segmentIndex: 0
        )

        // iPhone 换代成功，新一代的答案边收边播、正常收口。
        adapter.openGeneration(2)
        adapter.ingestDownlink(
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: 0, capturedAtMs: 1_800_000_000_000,
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: 7, count: 64)
            ),
            responseId: "r-new", generation: 2
        )
        adapter.markDownlinkComplete(responseId: "r-new", generation: 2, finalSequence: 0)
        player.completeBuffer(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "r-new", bytesPlayed: 64
        ))

        XCTAssertEqual(
            answerFinished, 1,
            "回合终态被旧代的段落屏障吞掉——用户要等 45s 硬超时才看到结束"
        )
        XCTAssertEqual(segmentFinished, 0, "被门禁丢弃的 done 不是本回合的段落边界")
    }

    /// ESS-1070 B2：回合终态 `audio.done` 必须**清掉**上一段留下的边界标志。
    ///
    /// 增量语音里段与段几乎背靠背（ADR ESS-1060 的分句窗口 350 ms），段落屏障
    /// 释放时本段音频往往还在渲染。若终态 done 到达时标志仍为 true，之后那次
    /// `.ended` 又会被判成段落边界，回合同样收不了口。
    func testEss1070_TurnTerminalDoneClearsPendingSegmentBoundary() {
        let requestId = "44444444-4444-4444-4444-444444441071"
        let sessionId = "55555555-5555-5555-5555-555555551071"
        let (adapter, _, player, _, _) = makeAdapter(sessionIds: [sessionId])
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        var segmentFinished = 0
        var answerFinished = 0
        adapter.onAnswerPlaybackSegmentFinished = { _, _ in segmentFinished += 1 }
        adapter.onAnswerPlaybackFinished = { _, _ in answerFinished += 1 }

        func delta(_ seq: Int) -> VoiceStreamChunk {
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: seq,
                capturedAtMs: 1_800_000_000_000 + Int64(seq),
                codec: "pcm_s16le", sampleRate: 24_000,
                payload: Data(repeating: UInt8(seq), count: 64)
            )
        }

        // 段 0：「正在查询…」→ 段落屏障释放（音频还在渲染，.ended 未到）。
        adapter.ingestDownlink(delta(0), responseId: "r-1070", generation: 1)
        adapter.markDownlinkSegmentComplete(
            responseId: "r-1070", generation: 1, finalSequence: 0, segmentIndex: 0
        )
        // 段 1：真答案 + 回合终态。
        adapter.ingestDownlink(delta(1), responseId: "r-1070", generation: 1)
        adapter.markDownlinkComplete(responseId: "r-1070", generation: 1, finalSequence: 1)

        // 终态之后的渲染完成必须收口**回合**。
        player.completeBuffer(.ended(
            requestId: handle.requestId, sessionId: handle.sessionId,
            responseId: "r-1070", bytesPlayed: 128
        ))

        XCTAssertEqual(
            answerFinished, 1,
            "终态 done 之后的 .ended 被判成段落边界——回合永不收口"
        )
        XCTAssertEqual(segmentFinished, 0)
    }

    /// ESS-1070 验收 2 的**运行时实测**：播放中打断 → 旧 generation 在 300 ms 内
    /// 停止出声，且此后旧代帧零播放。
    ///
    /// 与前两条控制面用例不同，本用例用**真实** `RealtimePlaybackEngine` +
    /// `AVAudioPlayerNode`（watchOS 模拟器进程内），并用单调时钟
    /// （`DispatchTime.uptimeNanoseconds`）量「打断触发 → 播放器确认不再出声」。
    /// 先等到真实 `.started` 回执（`.dataPlayedBack`，即首个 buffer 已经出声）
    /// 才打断，量的才是「播放中打断」。
    ///
    /// 覆盖边界（诚实声明）：这是模拟器音频栈的实测，不是配对真机的端到端；
    /// 真机三态证据仍是 ESS-1070 验收 3 的独立前置。
    func testEss1070_RealPlayerStopsOldGenerationWithin300msOfBargeIn() throws {
        try HostedCITestGate.skipIfHostedCI("real AVAudioEngine playback in ESS-1070 barge-in latency measurement")
        let controller = ConversationAudioController()
        let engine = RealtimePlaybackEngine(
            audioEngine: controller.playbackEngine,
            lifecycleOwner: { .conversation }
        )
        do {
            try controller.beginConversation(conversationId: "ess1070-bargein")
        } catch {
            throw XCTSkip("模拟器会话不可用：\(error.localizedDescription)")
        }
        defer { controller.endConversation(reason: .userExit) }

        var receipts: [String] = []
        engine.onPlaybackEvent = { event in
            switch event {
            case .started: receipts.append("started")
            case .ended: receipts.append("ended")
            case .bargedIn: receipts.append("bargedIn")
            case .failed: receipts.append("failed")
            }
        }

        let session = RealtimeMediaSession()
        var drops: [RealtimeDownlinkPlayback.DropReason] = []
        var readyCount = 0
        session.onEvent = { event in
            switch event {
            case .playbackReady(let playables):
                readyCount += playables.count
                engine.enqueue(playables: playables)
            case .playbackCleared(let bytes):
                engine.bargeIn(clearedBytes: bytes)
            case .downlinkDropped(let reason):
                drops.append(reason)
            default:
                break
            }
        }
        let handle = session.beginTurn(requestId: "10701070-0000-4000-8000-000000000001")
        session.openGeneration(1)
        try engine.prepare(for: handle)

        func oldChunk(_ seq: Int) -> VoiceStreamChunk {
            VoiceStreamChunk(
                requestId: handle.requestId, streamId: handle.sessionId,
                direction: .downlink, sequence: seq,
                capturedAtMs: 1_800_000_000_000 + Int64(seq),
                codec: "pcm_s16le", sampleRate: 24_000,
                // 24 kHz / 16-bit：4800 字节 ≈ 100 ms 音频。
                payload: Data(repeating: 0, count: 4_800)
            )
        }

        // 旧 generation 的答案正在播：灌 ~2 s，足够在打断前真的出声。
        for seq in 0..<20 {
            session.receiveDownlink(oldChunk(seq), responseId: "r-old", generation: 1)
        }

        XCTAssertEqual(readyCount, 20, "20 帧旧代音频必须全部进入播放器，否则量的不是「播放中打断」")
        XCTAssertTrue(engine.hasAudioInRenderPipeline)

        // 等到首个 buffer **真的播完**（`.dataPlayedBack` 回执）才打断。
        let speaking = XCTestExpectation(description: "first buffer really rendered")
        Task { @MainActor in
            for _ in 0..<120 {
                if receipts.contains("started") { speaking.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        wait(for: [speaking], timeout: 8)
        XCTAssertTrue(engine.isRenderingDownlink, "打断前必须确实在出声")

        // —— 实测：用户新输入触发打断 ——
        let startedAt = DispatchTime.now().uptimeNanoseconds
        session.bargeInDownlink()
        let stopMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000

        XCTAssertFalse(engine.isRenderingDownlink, "打断后播放器仍在出声")
        XCTAssertFalse(engine.hasAudioInRenderPipeline, "打断后渲染链路必须当场清空")
        XCTAssertLessThanOrEqual(
            stopMs, 300,
            "ESS-1070 验收 2：打断后 300ms 内停止旧 generation 播放；实测 \(stopMs) ms"
        )
        // 实测值进测试日志，供复审复核（本机 watchOS 26.5 模拟器：41.43 ms）。
        print("ESS-1070 evidence barge_in_stop_ms=\(stopMs) receipts=\(receipts)")
        XCTAssertTrue(
            receipts.contains("started"), "必须有真实渲染回执才谈得上「播放中」"
        )
        XCTAssertTrue(receipts.contains("bargedIn"), "打断必须产生 barge-in 回执")

        // 打断后旧代在途帧：一帧都不得进入渲染链路（零补播）。
        for seq in 20..<26 {
            session.receiveDownlink(oldChunk(seq), responseId: "r-old", generation: 1)
        }
        XCTAssertFalse(
            engine.hasAudioInRenderPipeline,
            "旧 generation 的在途帧进了渲染链路 —— 越代补播"
        )
        XCTAssertFalse(engine.isRenderingDownlink)
        XCTAssertEqual(
            drops.count, 6,
            "打断后旧代帧必须全部被门禁丢弃并留证，实际=\(drops)"
        )
        XCTAssertTrue(
            drops.allSatisfy { $0 == .pendingGeneration(incoming: 1) },
            "丢弃原因必须是换代 pending 窗口，实际=\(drops)"
        )
    }

    // MARK: - ESS-527 outer timer regressions

    /// ESS-527 acceptance 1: barrier armed + missing tail + timeout → exactly
    /// one `.doneBarrierTimedOut` fallback surfaces, with the structured
    /// `done_barrier_timeout` log carrying the missing seq list. Before this
    /// fix the internal timer was never armed so this trace produced 13
    /// minutes of silence and zero fallback events (bridge.log evidence in
    /// ESS-527 body).
    func testEss527_BarrierTimeoutTriggersExactlyOneFallback() {
        let requestId = "44444444-4444-4444-4444-444444444527"
        let sessionId = "55555555-5555-5555-5555-555555555527"
        let timer = ManualBarrierTimer()
        let (adapter, _, _, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )

        struct LogEvent { let module: String; let event: String; let detail: String? }
        final class LogSink { var events: [LogEvent] = [] }
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.events.append(LogEvent(module: module, event: event, detail: detail))
        }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        // Only seq 0..1 arrive. final_sequence=3 leaves 2..3 pending forever.
        for i in 0..<2 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527A", generation: 1
            )
        }
        adapter.markDownlinkComplete(
            responseId: "r-527A", generation: 1, finalSequence: 3
        )

        // The waiting branch must arm the timer at exactly the 2.0 s budget.
        XCTAssertTrue(timer.isArmed, "barrier waiting must arm the outer timer — this is the ESS-527 dead-code fix")
        XCTAssertEqual(timer.armCount, 1)
        XCTAssertEqual(
            timer.lastRequestedInterval,
            WatchRealtimeMediaAdapter.doneBarrierTimeoutSeconds
        )

        // Fire the timer. Adapter routes it through `session.doneBarrierTimeout()`
        // → `.playbackFallback(.doneBarrierTimedOut([2,3]))` → single
        // structured error log; a second fire is a no-op (buffer absorbs).
        XCTAssertTrue(timer.fire())
        XCTAssertFalse(timer.fire(), "second fire must be absorbed; the buffer's alreadyFellBack path swallows it")

        let timeoutLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_timeout"
        }
        XCTAssertEqual(
            timeoutLogs.count, 1,
            "done_barrier_timeout must surface exactly once — ESS-527 acceptance"
        )
        let detail = timeoutLogs.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("missing_seq=[2, 3]"),
            "done_barrier_timeout must carry the missing seq list; got detail=\(detail)"
        )
    }

    /// ESS-527 acceptance 2: barrier armed + late deltas fill the missing
    /// set → coordinator emits `.doneBarrierReleased` and the adapter
    /// cancels the timer BEFORE it can fire. `player.finish` is called
    /// exactly once (the async release path) and no fallback is surfaced.
    func testEss527_LateDeltasReleaseBarrierAndCancelTimer() {
        let requestId = "44444444-4444-4444-4444-444444444528"
        let sessionId = "55555555-5555-5555-5555-555555555528"
        let timer = ManualBarrierTimer()
        let (adapter, _, player, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )

        struct LogEvent { let module: String; let event: String; let detail: String? }
        final class LogSink { var events: [LogEvent] = [] }
        let sink = LogSink()
        WatchLog.setObserver { module, event, _, detail, _ in
            sink.events.append(LogEvent(module: module, event: event, detail: detail))
        }
        defer { WatchLog.setObserver(nil) }

        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        // Head deltas 0..1 arrive first.
        for i in 0..<2 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527B", generation: 1
            )
        }
        // Done arrives BEFORE tail deltas — barrier waits, timer arms.
        adapter.markDownlinkComplete(
            responseId: "r-527B", generation: 1, finalSequence: 3
        )
        XCTAssertTrue(timer.isArmed, "waiting branch must arm the timer")
        XCTAssertEqual(player.finishCount, 0, "player must NOT drain while the barrier is waiting")
        let cancelsBefore = timer.cancelCount

        // Tail deltas 2..3 land — this should trigger the coordinator's
        // async `checkBarrierRelease()` → `.doneBarrierReleased` and the
        // adapter must cancel the pending timer.
        for i in 2...3 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527B", generation: 1
            )
        }
        XCTAssertFalse(timer.isArmed, "async release must cancel the pending barrier timer")
        XCTAssertGreaterThan(timer.cancelCount, cancelsBefore)

        // Exactly one drain, and it is the async-release path (no waited_ms=0
        // marker; that string belongs to the sync path exclusively).
        XCTAssertEqual(
            player.finishCount, 1,
            "player.finish must be invoked exactly once even after a late release"
        )
        XCTAssertEqual(player.finishInvocations.first as? String, "r-527B")

        let releaseLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_released"
        }
        XCTAssertEqual(releaseLogs.count, 1, "done_barrier_released must be emitted exactly once")
        XCTAssertFalse(
            releaseLogs.first?.detail?.contains("waited_ms=0") ?? true,
            "the async release path must not carry the sync-only waited_ms=0 marker"
        )

        // Timer firing after cancellation is a no-op — this guards against
        // a stray real-time task racing the cancel and stacking a fallback.
        XCTAssertFalse(timer.fire())
        let fallbackLogs = sink.events.filter {
            $0.module == "realtime" && $0.event == "done_barrier_timeout"
        }
        XCTAssertTrue(fallbackLogs.isEmpty, "no barrier-timeout fallback must fire on the async-release path")
    }

    /// ESS-527: synchronous barrier release (all seqs present before done)
    /// must not arm the timer at all. Guards against a regression where
    /// the sync path accidentally lands in the waiting branch first.
    func testEss527_SyncBarrierReleaseDoesNotArmTimer() {
        let requestId = "44444444-4444-4444-4444-444444444529"
        let sessionId = "55555555-5555-5555-5555-555555555529"
        let timer = ManualBarrierTimer()
        let (adapter, _, _, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )
        let handle = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        for i in 0...2 {
            adapter.ingestDownlink(
                VoiceStreamChunk(
                    requestId: handle.requestId, streamId: handle.sessionId,
                    direction: .downlink, sequence: i,
                    capturedAtMs: 1_800_000_000_000 + Int64(i),
                    codec: "pcm_s16le", sampleRate: 24_000,
                    payload: Data(repeating: UInt8(i), count: 64)
                ),
                responseId: "r-527C", generation: 1
            )
        }
        adapter.markDownlinkComplete(
            responseId: "r-527C", generation: 1, finalSequence: 2
        )
        XCTAssertEqual(timer.armCount, 0, "sync release must not arm the barrier timer")
        XCTAssertFalse(timer.isArmed)
    }

    /// ESS-527: `-1` zero-audio done contract must not arm the timer — there
    /// are no missing seqs to wait for and nothing to drain.
    func testEss527_ZeroAudioContractDoesNotArmTimer() {
        let requestId = "44444444-4444-4444-4444-444444444530"
        let sessionId = "55555555-5555-5555-5555-555555555530"
        let timer = ManualBarrierTimer()
        let (adapter, _, _, _, _) = makeAdapter(
            sessionIds: [sessionId], barrierTimer: timer
        )
        _ = adapter.beginTurn(requestId: requestId)
        adapter.openGeneration(1)
        adapter.markDownlinkComplete(
            responseId: "r-527D", generation: 1, finalSequence: -1
        )
        XCTAssertEqual(timer.armCount, 0)
    }
}
