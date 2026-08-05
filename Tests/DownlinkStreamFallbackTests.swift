import XCTest
@testable import WristAgentCore

/// ESS-351：下行流式分片降级单元测试。
///
/// 由于 `WristAgentPhoneRelay` / `WatchFeedbackChannel` 属于 iOS target
/// （非 Shared），SPM 无法直接实例化。本文件覆盖可共享验证的契约：
///
/// 1. `VoiceStreamChunk` downlink 方向构造与编解码正确
/// 2. `BridgeTurnProjection` completed 事件可正确解码（整段 m4a 降级入口）
/// 3. 降级标记集合（`failedDownlinkStreams`）的幂等语义验证
///
/// 完整集成测试（含 `handleStreamChunkDeliveryFailed` + `process(projection:)`）
/// 见 `xcodebuild test -scheme WristAgent`，这里不重复。
final class DownlinkStreamFallbackTests: XCTestCase {

    // MARK: - Helpers

    private func makeDownlinkChunk(
        requestId: String = "req-ess351-test",
        streamId: String = "stream-1",
        sequence: Int = 0,
        payload: Data = Data("hello".utf8)
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId,
            streamId: streamId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1_753_920_000_000,
            codec: "pcm_s16le",
            sampleRate: 24_000,
            payload: payload,
            payloadSha256: VoiceStreamChunk.sha256(payload),
            endOfStream: false
        )
    }

    private func makeCompletedProjectionJSON(requestId: String) -> Data {
        let sha = VoiceStreamChunk.sha256(Data("fake-audio".utf8))
        return """
        {
            "request_id": "\(requestId)",
            "status": "completed",
            "result": {
                "text": "test response",
                "audio": {
                    "sha256": "\(sha)",
                    "codec": "aac",
                    "duration_ms": 1000
                }
            }
        }
        """.data(using: .utf8)!
    }

    // MARK: - VoiceStreamChunk downlink 构造

    func testDownlinkChunkRoundTripsThroughJSON() throws {
        let chunk = makeDownlinkChunk()
        let data = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(VoiceStreamChunk.self, from: data)
        XCTAssertEqual(decoded, chunk)
        XCTAssertEqual(decoded.direction, .downlink)
        XCTAssertEqual(decoded.requestId, "req-ess351-test")
    }

    func testDownlinkChunkSha256MatchesPayload() {
        let payload = Data("hello-world".utf8)
        let chunk = makeDownlinkChunk(payload: payload)
        let computed = VoiceStreamChunk.sha256(payload)
        XCTAssertEqual(chunk.payloadSha256, computed,
                       "payloadSha256 必须与 VoiceStreamChunk.sha256(payload) 一致")
    }

    func testUplinkChunkHasDifferentDirection() throws {
        let chunk = VoiceStreamChunk(
            requestId: "req-up",
            streamId: "s1",
            direction: .uplink,
            sequence: 0,
            capturedAtMs: 1_753_920_000_000,
            codec: "pcm_s16le",
            sampleRate: 24_000,
            payload: Data("uplink".utf8)
        )
        XCTAssertEqual(chunk.direction, .uplink)
        // forwardStreamChunkToWatch 只处理 .downlink；uplink 应被守卫拦截
    }

    // MARK: - 降级标记集合幂等语义

    /// `handleStreamChunkDeliveryFailed` 使用 `Set.insert` 实现幂等：
    /// 同一 request_id 多次插入只产生一次 `.inserted`，后续返回 `(false, _)`。
    func testFailedDownlinkSetIsIdempotent() {
        var failed: Set<String> = []

        let first = failed.insert("req-1")
        XCTAssertTrue(first.inserted, "首次插入应返回 inserted=true")

        let second = failed.insert("req-1")
        XCTAssertFalse(second.inserted, "重复插入应返回 inserted=false（幂等 no-op）")

        XCTAssertEqual(failed.count, 1)
    }

    func testMultipleFailedRequestIdsTrackedIndependently() {
        var failed: Set<String> = []

        XCTAssertTrue(failed.insert("req-a").inserted)
        XCTAssertTrue(failed.insert("req-b").inserted)
        XCTAssertTrue(failed.insert("req-c").inserted)
        XCTAssertEqual(failed.count, 3)

        // 清除 req-a（模拟 process(projection:) completed 后的 remove）
        let removed = failed.remove("req-a")
        XCTAssertNotNil(removed, "remove 应返回被移除的值")
        XCTAssertEqual(failed.count, 2)
        XCTAssertFalse(failed.contains("req-a"))
    }

    // MARK: - BridgeTurnProjection completed 解码

    func testCompletedProjectionDecodesWithAudio() throws {
        let data = makeCompletedProjectionJSON(requestId: "req-completed")
        let projection = try JSONDecoder().decode(BridgeTurnProjection.self, from: data)

        XCTAssertEqual(projection.requestId, "req-completed")
        XCTAssertEqual(projection.status, "completed")
        XCTAssertNotNil(projection.result)
        XCTAssertNotNil(projection.result?.audio)
        XCTAssertEqual(projection.result?.audio?.durationMs, 1000)
    }

    func testCompletedProjectionStatusEnvelopeIsValid() throws {
        let data = makeCompletedProjectionJSON(requestId: "req-env")
        let projection = try JSONDecoder().decode(BridgeTurnProjection.self, from: data)

        let envelope = projection.statusEnvelope()
        XCTAssertNotNil(envelope, "completed turn 应产生有效的 statusEnvelope")
        XCTAssertEqual(envelope?.requestId, "req-env")
    }

    // MARK: - VoiceStreamChunk.sha256 一致性

    func testSha256IsDeterministic() {
        let payload = Data("consistent".utf8)
        let a = VoiceStreamChunk.sha256(payload)
        let b = VoiceStreamChunk.sha256(payload)
        XCTAssertEqual(a, b, "sha256 必须确定性")
        XCTAssertEqual(a.count, 64, "SHA-256 hex 是 64 字符")
    }
}
