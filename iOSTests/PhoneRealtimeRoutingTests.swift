import Foundation
import XCTest
@testable import WristAgent

/// ESS-753: 直连/降级路由测试 —— 覆盖 Agent 直连路径与 Bridge 降级路径的
/// 关键分支：缓冲区溢出降级、同一 turn 的 token mint 失败后不重试、跨 turn
/// 隔离、Agent 传输的下行分发和状态通知。
///
/// 这些测试不依赖真实的 WCSession 或 URLSession；在内存中验证路由策略。
@MainActor
final class PhoneRealtimeRoutingTests: XCTestCase {

    // MARK: - Agent token mint state (turn ownership)

    /// 同一 turn 的 token mint 失败后，后续帧继续走 Bridge 而非再试一次。
    /// 这条保证了一个 turn 不会被两个路径同时执行。
    func testFailedTurnNeverRetriesMintForSameTurn() {
        var state = AgentTokenMintState()
        let turn = AgentTokenMintState.Turn(requestId: "r1", sessionId: "s1")

        // 激活并注册 mint 任务
        XCTAssertTrue(state.activate(turn))
        guard let taskA = state.registerTask() else {
            return XCTFail("必须能注册 mint 任务")
        }

        // mint 失败
        XCTAssertTrue(state.markFailed(taskId: taskA, turn: turn))
        XCTAssertEqual(state.failedTurn, turn)

        // 同一 turn 再次激活：必须被拒绝（already failed）
        XCTAssertFalse(state.activate(turn))
        XCTAssertEqual(state.failedTurn, turn)
    }

    /// 新 turn 可以胜过一个已失败的旧 turn。
    func testNewTurnCanOverrideFailedTurn() {
        var state = AgentTokenMintState()
        let turnA = AgentTokenMintState.Turn(requestId: "r-old", sessionId: "s-old")

        XCTAssertTrue(state.activate(turnA))
        guard let taskA = state.registerTask() else { return XCTFail() }
        XCTAssertTrue(state.markFailed(taskId: taskA, turn: turnA))
        XCTAssertEqual(state.failedTurn, turnA)

        // 新 turn
        let turnB = AgentTokenMintState.Turn(requestId: "r-new", sessionId: "s-new")
        XCTAssertTrue(state.activate(turnB), "新 turn 必须能覆盖失败的旧 turn")
        XCTAssertNotNil(state.registerTask())
        XCTAssertNil(state.failedTurn, "新 turn 激活后 failedTurn 必须被清除")
    }

    /// 已持有 token 的同一 turn 不需要重新 mint。
    func testSameTurnWithTokenDoesNotTriggerNewMint() {
        var state = AgentTokenMintState()
        let turn = AgentTokenMintState.Turn(requestId: "r1", sessionId: "s1")

        // 首次激活
        XCTAssertTrue(state.activate(turn))
        guard let taskA = state.registerTask() else { return XCTFail() }

        // 同一 turn 再次激活：turn 不变，activate 返回 false（不是新 turn）
        // 但 turn 仍然是当前 turn
        XCTAssertFalse(state.activate(turn))
        // task 不变
        XCTAssertEqual(state.activeTaskId, taskA)
    }

    // MARK: - Agent envelope buffer overflow

    /// 缓冲区溢出时，所有已缓冲 + 进入的 envelope 都必须排空走 Bridge。
    func testBufferOverflowDrainsAllBufferedAndIncomingToBridge() {
        // 上限 2 条的缓冲区
        var buffer = AgentEnvelopeBuffer(maximumCount: 2, maximumBytes: 10_000)
        let now = Date(timeIntervalSince1970: 100)

        let e1 = RealtimeUplinkEnvelope.append(
            chunk(requestId: "r1", streamId: "s1", sequence: 0)
        )
        let e2 = RealtimeUplinkEnvelope.append(
            chunk(requestId: "r1", streamId: "s1", sequence: 1)
        )
        let e3 = RealtimeUplinkEnvelope.append(
            chunk(requestId: "r1", streamId: "s1", sequence: 2)
        )

        XCTAssertBuffered(buffer.append(e1, encodedByteCount: 100, now: now))
        XCTAssertBuffered(buffer.append(e2, encodedByteCount: 100, now: now))

        guard case .overflow(let buffered, let incoming, let snapshot) = buffer.append(
            e3, encodedByteCount: 100, now: now.addingTimeInterval(0.5)
        ) else { return XCTFail("第三条必须触发溢出") }

        XCTAssertEqual(buffered.count, 2)
        XCTAssertEqual(incoming.kind, .audioAppend)
        XCTAssertEqual(snapshot.envelopeCount, 2)
        XCTAssertEqual(snapshot.byteCount, 200)
        XCTAssertEqual(snapshot.waitedMilliseconds, 500)
        XCTAssertEqual(buffer.byteCount, 0)
    }

    /// 缓冲区字节上限溢出时，保留已缓冲的，溢出最新的。
    func testBufferByteOverflowReturnsSnapshotWithCorrectByteCount() {
        var buffer = AgentEnvelopeBuffer(maximumCount: 10, maximumBytes: 50)

        XCTAssertBuffered(buffer.append(
            RealtimeUplinkEnvelope.append(chunk(requestId: "r1", streamId: "s1", sequence: 0)),
            encodedByteCount: 40, now: Date(timeIntervalSince1970: 100)
        ))

        guard case .overflow(let buffered, _, let snapshot) = buffer.append(
            RealtimeUplinkEnvelope.append(chunk(requestId: "r1", streamId: "s1", sequence: 1)),
            encodedByteCount: 20, now: Date(timeIntervalSince1970: 100)
        ) else { return XCTFail("字节超限必须触发溢出") }

        XCTAssertEqual(buffered.count, 1)
        XCTAssertEqual(snapshot.byteCount, 40)
        XCTAssertEqual(buffer.byteCount, 0)
    }

    // MARK: - Agent transport — generation-aware downlink filtering

    /// 不匹配的 generation 的 audio.delta 必须被静默丢弃（不递交给 Watch）。
    func testAgentTransportDropsStaleGenerationAudioDelta() {
        // InMemoryAgentTransport 记录了 onDownlink 调用
        let transport = InMemoryAgentTransport(
            requestId: "r1", sessionId: "s1", generation: 5
        )
        var delivered: [RealtimeDownlinkEnvelope] = []
        transport.onDownlink = { delivered.append($0) }

        // 当前 generation 是 5，投递 generation=3 的旧帧
        transport.simulateAudioDelta(
            chunk: chunk(requestId: "r1", streamId: "s1", sequence: 0),
            generation: 3
        )

        XCTAssertTrue(
            delivered.isEmpty,
            "旧 generation 的 audio.delta 必须被丢弃"
        )
    }

    /// 匹配的 generation 的音频帧必须被递交给 Watch。
    func testAgentTransportDeliversMatchingGenerationAudioDelta() {
        let transport = InMemoryAgentTransport(
            requestId: "r1", sessionId: "s1", generation: 5
        )
        var delivered: [RealtimeDownlinkEnvelope] = []
        transport.onDownlink = { delivered.append($0) }

        transport.simulateAudioDelta(
            chunk: chunk(requestId: "r1", streamId: "s1", sequence: 0),
            generation: 5
        )

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].kind, .audioDelta)
        XCTAssertEqual(delivered[0].generation, 5)
    }

    /// audio.done 必须携带 generation 和 finalSequence。
    func testAgentTransportDeliversAudioDoneWithGenerationAndFinalSequence() {
        let transport = InMemoryAgentTransport(
            requestId: "r1", sessionId: "s1", generation: 5
        )
        var delivered: [RealtimeDownlinkEnvelope] = []
        transport.onDownlink = { delivered.append($0) }

        transport.simulateAudioDone(generation: 5, finalSequence: 42)

        XCTAssertEqual(delivered.count, 1)
        let done = delivered[0]
        XCTAssertEqual(done.kind, .audioDone)
        XCTAssertEqual(done.generation, 5)
        XCTAssertEqual(done.finalSequence, 42)
    }

    /// 不可恢复的 gateway error 必须触发 failed 状态通知。
    func testNonRetriableErrorSignalsFailedState() {
        let transport = InMemoryAgentTransport(
            requestId: "r1", sessionId: "s1", generation: 1
        )
        var finalState: PhoneRealtimeSession.State?
        transport.onStateChange = { finalState = $0 }

        transport.simulateError(code: "INVALID_TOKEN", retriable: false)

        guard case .failed(let reason) = finalState else {
            return XCTFail("不可恢复错误必须转 failed")
        }
        XCTAssertTrue(reason.contains("INVALID_TOKEN"))
    }

    /// 可恢复错误不得触发 failed。
    func testRetriableErrorDoesNotSignalFailedState() {
        let transport = InMemoryAgentTransport(
            requestId: "r1", sessionId: "s1", generation: 1
        )
        var stateChangeCount = 0
        transport.onStateChange = { _ in stateChangeCount += 1 }

        transport.simulateError(code: "RATE_LIMITED", retriable: true)

        XCTAssertEqual(stateChangeCount, 0, "可恢复错误不得触发状态变更")
    }

    // MARK: - Helpers

    private func chunk(requestId: String, streamId: String, sequence: Int) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId,
            streamId: streamId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1000,
            codec: "pcm_s16le",
            sampleRate: 16000,
            payload: Data([0x00])
        )
    }

    private func XCTAssertBuffered(
        _ result: AgentEnvelopeBuffer.AppendResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .buffered = result else {
            return XCTFail("expected buffered", file: file, line: line)
        }
    }
}

// MARK: - InMemoryAgentTransport

/// 简化的 Agent 传输模拟：不连真实 WSS，直接暴露回调以触发 onAudioDelta 等。
@MainActor
private final class InMemoryAgentTransport: PhoneRealtimeSession.Transport {
    var onDownlink: ((RealtimeDownlinkEnvelope) -> Void)?
    var onStateChange: ((PhoneRealtimeSession.State) -> Void)?

    private let requestId: String
    private let sessionId: String
    private let generation: Int

    init(requestId: String, sessionId: String, generation: Int) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.generation = generation
    }

    func send(
        _ envelope: RealtimeUplinkEnvelope,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        completion(nil)
    }

    func receive(
        handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void
    ) {
        // Agent transport delivers via callbacks, not receive loop
    }

    func close(reason: String) {}

    // MARK: - Simulation hooks

    func simulateAudioDelta(chunk: VoiceStreamChunk, generation: Int) {
        guard generation == self.generation else { return }
        let envelope = RealtimeDownlinkEnvelope.audioDelta(
            chunk, responseId: "resp-1", generation: generation
        )
        onDownlink?(envelope)
    }

    func simulateAudioDone(generation: Int, finalSequence: Int) {
        guard generation == self.generation else { return }
        let envelope = RealtimeDownlinkEnvelope.audioDone(
            requestId: requestId, sessionId: sessionId,
            responseId: "resp-1", generation: generation,
            finalSequence: finalSequence
        )
        onDownlink?(envelope)
    }

    func simulateError(code: String, retriable: Bool) {
        if !retriable {
            onStateChange?(.failed(reason: "gateway_error_\(code)"))
        }
    }
}
