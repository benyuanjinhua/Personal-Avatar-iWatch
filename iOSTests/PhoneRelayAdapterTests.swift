import CryptoKit
import Foundation
import XCTest
@testable import WristAgent

/// ESS-753 复审整改 v2：真实 production adapter 边界测试。
///
/// v1 版本（已删除）的 12/16 条用例是同义反复（mock 记值→断言记值），
/// 不执行任何生产代码。v2 只保留真正走 `VoiceOutbox` / `WatchDownlinkOutbox`
/// 的用例，并补齐 `PhoneConnectivity.turnIdentity(for:)` 被真实调用的覆盖。
///
///   1. PhoneConnectivity.turnIdentity — 静态分发，覆盖全部 envelope 类型与
///      fallback 返回 nil 的分支（ESS-795 阻断项 #3）
///   2. VoiceOutbox SHA256 冲突拒绝 — 同一 requestId + 不同音频摘要（阻断项 #4）
///   3. WatchDownlinkOutbox staged URL 条目隔离（阻断项 #4）
@MainActor
final class PhoneRelayAdapterTests: XCTestCase {

    // ── turnIdentity 静态分发（PhoneConnectivity 生产代码）──────────────

    func testTurnIdentityReturnsIdsFromStreamStart() {
        let env = RealtimeUplinkEnvelope.start(
            RealtimeStreamStart(requestId: "req-start", sessionId: "sess-a",
                                format: pcm, capturedAtMs: 1))
        let id = PhoneConnectivity.turnIdentity(for: env)
        XCTAssertEqual(id?.requestId, "req-start")
        XCTAssertEqual(id?.sessionId, "sess-a")
    }

    func testTurnIdentityReturnsIdsFromAudioAppend() {
        let env = RealtimeUplinkEnvelope.append(
            chunk("req-append", "sess-b", 0))
        let id = PhoneConnectivity.turnIdentity(for: env)
        XCTAssertEqual(id?.requestId, "req-append")
        XCTAssertEqual(id?.sessionId, "sess-b")
    }

    func testTurnIdentityReturnsIdsFromAudioCommit() {
        let env = RealtimeUplinkEnvelope.commit(
            RealtimeStreamCommit(requestId: "req-commit", sessionId: "sess-c",
                                 sequence: 0, capturedAtMs: 1))
        let id = PhoneConnectivity.turnIdentity(for: env)
        XCTAssertEqual(id?.requestId, "req-commit")
        XCTAssertEqual(id?.sessionId, "sess-c")
    }

    func testTurnIdentityReturnsIdsFromPlaybackStarted() {
        let env = RealtimeUplinkEnvelope.playbackStarted(
            RealtimePlaybackReceipt(requestId: "req-pb", sessionId: "sess-d",
                                    responseId: "resp-1", bytesPlayed: nil))
        let id = PhoneConnectivity.turnIdentity(for: env)
        XCTAssertEqual(id?.requestId, "req-pb")
        XCTAssertEqual(id?.sessionId, "sess-d")
    }

    func testTurnIdentityReturnsIdsFromBargeInRequest() {
        let env = RealtimeUplinkEnvelope.bargeInRequest(
            RealtimeBargeInRequest(requestId: "req-bi", sessionId: "sess-e",
                                   fromGeneration: 2))
        let id = PhoneConnectivity.turnIdentity(for: env)
        XCTAssertEqual(id?.requestId, "req-bi")
        XCTAssertEqual(id?.sessionId, "sess-e")
    }

    /// fallback 是唯一的返回 nil 分支——不走任何 turn，此断言保证
    /// `handleRealtimeUplink` 在遇到 fallback 时不会错误地进入 Agent token mint 路径。
    func testTurnIdentityReturnsNilForFallback() {
        let env = RealtimeUplinkEnvelope.fallback(
            RealtimeUplinkFallbackDescriptor(requestId: "req-fb", sessionId: "sess-f",
                                             reason: "timeout"))
        XCTAssertNil(PhoneConnectivity.turnIdentity(for: env),
                     "fallback 不属于任何 turn，必须返回 nil")
    }

    // ── 文件 ID 校验（真实 VoiceOutbox / WatchDownlinkOutbox）────────────

    func testOutboxRejectsSameRequestIdWithDifferentSHA256() throws {
        let directory = tmpDir()
        defer { cleanup(directory) }
        let outbox = try VoiceOutbox(directory: directory,
                                     keyProvider: TestOutboxKeyProvider())

        let a1 = Data(repeating: 0xAA, count: 512)
        let e1 = VoiceRequestEnvelope.voiceRequest(
            audio: desc(sha: VoiceDigest.sha256Hex(of: a1)))
        _ = try outbox.enqueue(envelope: e1, audioData: a1)

        let a2 = Data(repeating: 0xBB, count: 512)
        let e2 = VoiceRequestEnvelope.voiceRequest(
            requestId: UUID(uuidString: e1.requestId) ?? UUID(),
            audio: desc(sha: VoiceDigest.sha256Hex(of: a2)))

        XCTAssertThrowsError(
            try outbox.enqueue(envelope: e2, audioData: a2),
            "同一 requestId + 不同 sha256 的 envelope 必须被拒绝，防止静默覆盖")
    }

    func testDownlinkOutboxStagedURLContainsItemId() throws {
        let directory = tmpDir()
        defer { cleanup(directory) }
        let outbox = try WatchDownlinkOutbox(directory: directory, log: { _ in })

        let r = try outbox.enqueueSpeech(
            requestId: "req-url", messageKey: "k",
            envelope: try JSONEncoder().encode(
                VoiceStatusEnvelope.status(requestId: "req-url",
                                           state: .completed, detail: "ok")),
            audio: Data([0xFF, 0xFB]), fileName: "s.m4a")

        guard case .enqueued(let item) = r else { return XCTFail() }
        let url = try XCTUnwrap(outbox.stagedAudioURL(for: item.id))
        XCTAssertTrue(url.path.contains(item.id),
                      "staged URL 必须包含条目 ID，防止跨条目文件覆盖")
    }

    func testSpeechPayloadPreservedAcrossEnqueueAndReadback() throws {
        let directory = tmpDir()
        defer { cleanup(directory) }
        let outbox = try WatchDownlinkOutbox(directory: directory, log: { _ in })

        let payload = Data("speech payload".utf8)
        let r = try outbox.enqueueSpeech(
            requestId: "req-readback", messageKey: "voice_speech",
            envelope: payload, audio: Data([0x00]), fileName: "audio.m4a")

        guard case .enqueued(let item) = r else { return XCTFail() }
        let readback = try outbox.payload(for: item.id)
        XCTAssertEqual(readback, payload,
                       "入队 payload 与磁盘回读必须一致")
    }

    // ── helpers ──────────────────────────────────────────────────────

    private let pcm = RealtimeMediaFormat(codec: "pcm_s16le", sampleRate: 16000)

    private func chunk(_ rid: String, _ sid: String, _ seq: Int) -> VoiceStreamChunk {
        VoiceStreamChunk(requestId: rid, streamId: sid, direction: .uplink,
                         sequence: seq, capturedAtMs: 1,
                         codec: "pcm_s16le", sampleRate: 16000,
                         payload: Data([0x00]))
    }

    private func desc(sha: String) -> VoiceAudioDescriptor {
        VoiceAudioDescriptor(codec: "pcm", sampleRate: 16000,
                             channels: 1, durationMs: 1000, sha256: sha)
    }

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSTests-Adapter-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func cleanup(_ d: URL) { try? FileManager.default.removeItem(at: d) }
}

// MARK: - TestOutboxKeyProvider

private struct TestOutboxKeyProvider: VoiceOutboxKeyProviding {
    private let key = SymmetricKey(size: .bits256)
    func outboxKey() throws -> SymmetricKey { key }
}
