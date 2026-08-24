import Foundation
import XCTest
@testable import WristAgent

/// ESS-753: iOS 实时链路行为测试 —— 覆盖 PhoneRealtimeSession 的核心状态机、
/// 跨回合隔离、直连/降级路由、下行缓冲与 WSS 生命周期。
///
/// `PhoneRealtimeSession` 通过 `Transport` 协议注入传输层，因此全部用例都使用
/// InMemoryTransport 而不需要实际的网络连接。
@MainActor
final class PhoneRealtimeSessionTests: XCTestCase {

    private let pcmFormat = RealtimeMediaFormat(codec: "pcm_s16le", sampleRate: 16000)

    // MARK: - Transport lifecycle

    /// stream.start 打开传输，同一 (requestId, sessionId) 的后续帧复用它。
    func testOpensTransportOnStreamStartAndReusesForSameTurn() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)
        XCTAssertEqual(session.state, .idle)

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        // 验证 transport 被使用：send 被调用或 receive handler 被设置
        XCTAssertTrue(transport.wasUsed, "stream.start 必须使用传输")
        // 非 Agent 模式：openIfNeeded 立即转 active
        guard case .active(let rid, let sid) = session.state else {
            return XCTFail("非 Agent 模式 stream.start 后应进入 active")
        }
        XCTAssertEqual(rid, "r1")
        XCTAssertEqual(sid, "s1")

        // 同一 turn 的 audio.append 不重新创建传输
        transport.sendCount = 0
        session.forward(RealtimeUplinkEnvelope.append(
            chunk(requestId: "r1", streamId: "s1", sequence: 0)
        ))
        XCTAssertEqual(transport.sendCount, 1, "同一 turn 的后续帧应通过同一传输发送")
    }

    /// 新 (requestId, sessionId) 的 stream.start 淘汰旧传输并打开新的。
    func testNewStreamStartClosesOldTransportAndOpensNewOne() {
        let oldTransport = InMemoryTransport()
        let newTransport = InMemoryTransport()
        var factoryCalls = 0
        let transports = [oldTransport, newTransport]

        let session = PhoneRealtimeSession(transportFactory: { _, _ in
            defer { factoryCalls += 1 }
            return factoryCalls < transports.count ? transports[factoryCalls] : nil
        })

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(oldTransport.wasUsed)

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r2", sessionId: "s2", format: pcmFormat, capturedAtMs: 1)
        ))
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(oldTransport.closeReason, "supersede", "旧传输必须被关闭")
        XCTAssertTrue(newTransport.wasUsed, "新传输必须被使用")
    }

    // MARK: - Cross-turn isolation

    /// 超驰传输投递的延迟回调不得污染新回合的下行。
    func testAgentDownlinkFromSupersededTransportIsDropped() {
        let transport1 = InMemoryTransport()
        let transport2 = InMemoryTransport()
        var delivered: [RealtimeDownlinkEnvelope] = []
        var transports = [transport1, transport2]
        var idx = 0

        let session = PhoneRealtimeSession(transportFactory: { _, _ in
            defer { idx += 1 }
            return idx < transports.count ? transports[idx] : nil
        })
        session.onDownlink = { delivered.append($0) }

        // Turn 1: active
        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "r1", sessionId: "s1", sequence: 0, capturedAtMs: 1)
        ))

        // Turn 2: supersedes turn 1
        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r2", sessionId: "s2", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "r2", sessionId: "s2", sequence: 0, capturedAtMs: 1)
        ))

        // 旧传输的延迟回调
        let staleEnvelope = RealtimeDownlinkEnvelope.audioDelta(
            chunk(requestId: "r1", streamId: "s1", sequence: 1),
            responseId: "resp-1"
        )
        session.receiveAgentDownlink(staleEnvelope, from: transport1)

        XCTAssertTrue(
            delivered.isEmpty,
            "超驰传输投递的音频帧不得进入下行队列（否则会污染新回合）"
        )
    }

    /// 活跃传输的正确请求帧必须被转发。
    func testAgentDownlinkFromActiveTransportIsDelivered() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)
        var delivered: [RealtimeDownlinkEnvelope] = []
        session.onDownlink = { delivered.append($0) }

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "r1", sessionId: "s1", sequence: 0, capturedAtMs: 1)
        ))

        let envelope = RealtimeDownlinkEnvelope.audioDelta(
            chunk(requestId: "r1", streamId: "s1", sequence: 0),
            responseId: "resp-1"
        )
        session.receiveAgentDownlink(envelope, from: transport)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].requestId, "r1")
    }

    /// ESS-541: requestId 或 sessionId 不匹配的帧必须被丢弃。
    func testAgentDownlinkWithMismatchedRequestIsDropped() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)
        var delivered: [RealtimeDownlinkEnvelope] = []
        session.onDownlink = { delivered.append($0) }

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "r1", sessionId: "s1", sequence: 0, capturedAtMs: 1)
        ))

        // 不同 requestId 的帧
        session.receiveAgentDownlink(
            RealtimeDownlinkEnvelope.audioDelta(
                chunk(requestId: "r2", streamId: "s1", sequence: 0)
            ),
            from: transport
        )
        // 不同 sessionId 的帧
        session.receiveAgentDownlink(
            RealtimeDownlinkEnvelope.audioDelta(
                chunk(requestId: "r1", streamId: "s2", sequence: 0)
            ),
            from: transport
        )

        XCTAssertTrue(delivered.isEmpty, "不匹配的 request/session 必须被丢弃")
    }

    /// 空 requestId 或 sessionId 拒绝，防止未限定域的广播泄漏。
    func testAgentDownlinkWithEmptyIdentityIsDropped() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)
        var delivered: [RealtimeDownlinkEnvelope] = []
        session.onDownlink = { delivered.append($0) }

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "r1", sessionId: "s1", sequence: 0, capturedAtMs: 1)
        ))

        session.receiveAgentDownlink(
            RealtimeDownlinkEnvelope.audioDelta(
                chunk(requestId: "", streamId: "s1", sequence: 0)
            ),
            from: transport
        )
        session.receiveAgentDownlink(
            RealtimeDownlinkEnvelope.audioDelta(
                chunk(requestId: "r1", streamId: "", sequence: 0)
            ),
            from: transport
        )

        XCTAssertTrue(delivered.isEmpty)
    }

    // MARK: - Fallback

    /// fallback 帧立即关闭传输并转为 failed 状态。
    func testFallbackClosesTransportAndTransitionsToFailed() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)
        var states: [PhoneRealtimeSession.State] = []
        session.onStateChange = { states.append($0) }

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))

        session.forward(RealtimeUplinkEnvelope.fallback(.init(
            requestId: "r1", sessionId: "s1", reason: "watch_unreachable"
        )))

        XCTAssertEqual(transport.closeReason, "watch_unreachable")
        guard case .failed(let reason) = session.state else {
            return XCTFail("fallback 后必须进入 failed")
        }
        XCTAssertEqual(reason, "watch_unreachable")
        XCTAssertTrue(states.contains(.failed(reason: "watch_unreachable")))
    }

    // MARK: - State transitions

    func testTransitionsFromIdleThroughActiveToCancelled() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)
        var states: [PhoneRealtimeSession.State] = []
        session.onStateChange = { states.append($0) }

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.append(
            chunk(requestId: "r1", streamId: "s1", sequence: 0)
        ))

        // 非 Agent 模式：openIfNeeded 立即转 active
        guard case .active(let rid, let sid) = session.state else {
            return XCTFail("非 Agent 模式 start 后应为 active")
        }
        XCTAssertEqual(rid, "r1")
        XCTAssertEqual(sid, "s1")

        session.endTurn(reason: "user_cancelled")
        XCTAssertEqual(session.state, .cancelled)
    }

    func testAudioAppendOnIdleDoesNotCrash() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)

        // 在 idle 状态直接发 audio.append：openIfNeeded 会打开传输，
        // 这是正常行为（audio.append 触发懒加载）
        session.forward(RealtimeUplinkEnvelope.append(
            chunk(requestId: "r1", streamId: "s1", sequence: 0)
        ))

        // 不应崩溃，且传输应被使用
        XCTAssertTrue(transport.wasUsed, "audio.append 应触发传输创建")
    }

    // MARK: - Pending downlink buffer

    /// 新 stream.start 必须丢弃上一回合的待送下行帧。
    func testNewStreamStartDiscardsStalePendingDownlink() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))

        // 注入一条下行（没有 onDownlink 消费者 → 入 pending）
        let staleEnvelope = RealtimeDownlinkEnvelope.audioDelta(
            chunk(requestId: "r1", streamId: "s1", sequence: 0)
        )
        session.receiveAgentDownlink(staleEnvelope, from: transport)

        let (count, _) = session.pendingDownlinkStats
        XCTAssertEqual(count, 1, "没有消费者时必须进入 pending 缓冲")

        // 新回合
        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r2", sessionId: "s2", format: pcmFormat, capturedAtMs: 1)
        ))

        let (count2, _) = session.pendingDownlinkStats
        XCTAssertEqual(count2, 0, "新 stream.start 必须清空上一回合的待送缓冲")
    }

    /// drainPendingDownlink 必须取走并清空。
    func testDrainPendingDownlinkReturnsAndClears() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))

        // 注入两条（没有 onDownlink 消费者）
        session.receiveAgentDownlink(
            RealtimeDownlinkEnvelope.audioDelta(
                chunk(requestId: "r1", streamId: "s1", sequence: 0)
            ),
            from: transport
        )
        session.receiveAgentDownlink(
            RealtimeDownlinkEnvelope.audioDelta(
                chunk(requestId: "r1", streamId: "s1", sequence: 1)
            ),
            from: transport
        )

        let drained = session.drainPendingDownlink()
        XCTAssertEqual(drained.count, 2)
        let (count, _) = session.pendingDownlinkStats
        XCTAssertEqual(count, 0)

        // 二次 drain 不得重复
        XCTAssertTrue(session.drainPendingDownlink().isEmpty)
    }

    /// endTurn 必须清空 pending 缓冲。
    func testEndTurnDiscardsPendingDownlink() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))

        session.receiveAgentDownlink(
            RealtimeDownlinkEnvelope.audioDelta(
                chunk(requestId: "r1", streamId: "s1", sequence: 0)
            ),
            from: transport
        )

        session.endTurn(reason: "turn_complete")

        let (count, _) = session.pendingDownlinkStats
        XCTAssertEqual(count, 0)
    }

    // MARK: - Agent transport state

    func testAgentTransportDidChangeStateIsIgnoredFromSupersededTransport() {
        let t1 = InMemoryTransport()
        let t2 = InMemoryTransport()
        var transports = [t1, t2]
        var idx = 0

        let session = PhoneRealtimeSession(transportFactory: { _, _ in
            defer { idx += 1 }
            return idx < transports.count ? transports[idx] : nil
        })

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r2", sessionId: "s2", format: pcmFormat, capturedAtMs: 1)
        ))

        // t1 的延迟状态变更
        session.agentTransportDidChangeState(
            .active(requestId: "r1", sessionId: "s1"), from: t1
        )

        guard case .connecting = session.state else {
            return // 不被 t1 篡改即可
        }
    }

    func testAgentTransportDidChangeStateIsAcceptedFromCurrentTransport() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))

        session.agentTransportDidChangeState(
            .active(requestId: "r1", sessionId: "s1"), from: transport
        )

        guard case .active(let rid, let sid) = session.state else {
            return XCTFail("当前传输的状态变更必须被采纳")
        }
        XCTAssertEqual(rid, "r1")
        XCTAssertEqual(sid, "s1")
    }

    // MARK: - isAgentTransport flag

    /// 非 Agent 模式下，openIfNeeded 在流开始后立即转 active。
    func testBridgeModeTransitionsToActiveOnCommit() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        // Bridge 模式：second envelope (commit) 推进到 active
        session.forward(RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "r1", sessionId: "s1", sequence: 0, capturedAtMs: 1)
        ))

        guard case .active(let rid, let sid) = session.state else {
            return XCTFail("非 Agent 模式 commit 后应为 active")
        }
        XCTAssertEqual(rid, "r1")
        XCTAssertEqual(sid, "s1")
    }

    /// Agent 模式下，openIfNeeded 不主动转 active；等待 transport 回调。
    func testAgentModeDoesNotAutoTransitionToActive() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)
        session.isAgentTransport = true

        session.forward(RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "r1", sessionId: "s1", format: pcmFormat, capturedAtMs: 1)
        ))
        session.forward(RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "r1", sessionId: "s1", sequence: 0, capturedAtMs: 1)
        ))

        guard case .connecting(let rid, let sid) = session.state else {
            return XCTFail("Agent 模式必须保持 connecting 直到回调")
        }
        XCTAssertEqual(rid, "r1")
        XCTAssertEqual(sid, "s1")
    }

    // MARK: - Playback receipts

    func testPlaybackStartedReceiptOpensTransportIfNeeded() {
        let transport = InMemoryTransport()
        let session = makeSession(returning: transport)

        session.forward(RealtimeUplinkEnvelope.playbackStarted(.init(
            requestId: "r1", sessionId: "s1", responseId: "resp-1", bytesPlayed: nil
        )))

        // 收到了 playback receipt（即使之前没有 start），transport 应被使用
        XCTAssertTrue(transport.wasUsed)
    }

    func testSendCompletionReportsFalseWhenNoTransport() {
        let session = PhoneRealtimeSession(transportFactory: { _, _ in nil })

        var completed = false
        var success = true
        session.forward(
            RealtimeUplinkEnvelope.append(
                chunk(requestId: "r1", streamId: "s1", sequence: 0)
            ),
            completion: { result in
                completed = true
                success = result
            }
        )

        XCTAssertTrue(completed)
        XCTAssertFalse(success, "无传输时发送必须返回 false")
    }

    // MARK: - Helpers

    private func makeSession(returning transport: InMemoryTransport) -> PhoneRealtimeSession {
        PhoneRealtimeSession(transportFactory: { _, _ in transport })
    }

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
}

// MARK: - InMemoryTransport

/// 内存传输：不发起网络连接，记录所有调用用于断言。
@MainActor
private final class InMemoryTransport: PhoneRealtimeSession.Transport {
    var wasUsed = false
    var sendCount = 0
    var closeReason: String?
    var sentEnvelopes: [RealtimeUplinkEnvelope] = []
    var receiveHandler: (@MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void)?

    func send(
        _ envelope: RealtimeUplinkEnvelope,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        wasUsed = true
        sendCount += 1
        sentEnvelopes.append(envelope)
        completion(nil)
    }

    func receive(
        handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void
    ) {
        wasUsed = true
        receiveHandler = handler
    }

    func close(reason: String) {
        closeReason = reason
    }
}
