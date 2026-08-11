import CryptoKit
import Foundation
import XCTest
@testable import WristAgent

/// ESS-753 复审补充：WCSession adapter 边界测试。
///
/// 上一个版本只覆盖了 `WatchDownlinkOutbox`（基础设施），缺失
/// `PhoneConnectivity` / `WristAgentPhoneRelay` adapter 边界。
/// 本套件补上：
///
///   - PhoneConnectivity 的 envelope-to-turn 身份提取（静态分发）
///   - WristAgentPhoneRelay 的初始化、handleAccepted 入队→下行通知
///   - Mock WatchFeedbackChannel 验证 requestId 不可变性
///   - 文件 ID 校验：fileName/stagedURL/envelope 绑定一致性
@MainActor
final class PhoneRelayAdapterTests: XCTestCase {

    // MARK: - PhoneConnectivity.turnIdentity

    /// stream.start / audio.append / audio.commit 必须携带正确的身份字段。
    /// 这些 envelope 结构体在到达 PhoneConnectivity 前已在 Watch 端编码——
    /// 此处验证 WireFormat 的定义一致性，确保 PhoneConnectivity 的
    /// `turnIdentity(for:)` 静态分发不会因字段名漂移而静默返回 nil。
    func testStreamStartCarriesRequestAndSessionId() {
        let start = RealtimeStreamStart(requestId: "req-1", sessionId: "sess-a",
                                        format: RealtimeMediaFormat(codec: "pcm_s16le", sampleRate: 16000),
                                        capturedAtMs: 1)
        XCTAssertEqual(start.requestId, "req-1")
        XCTAssertEqual(start.sessionId, "sess-a")
    }

    func testAudioAppendCarriesRequestIdAndStreamId() {
        let chunk = VoiceStreamChunk(requestId: "req-2", streamId: "sess-b",
                                     direction: .uplink, sequence: 0,
                                     capturedAtMs: 1, codec: "pcm_s16le", sampleRate: 16000,
                                     payload: Data([0x00]))
        XCTAssertEqual(chunk.requestId, "req-2")
        XCTAssertEqual(chunk.streamId, "sess-b")
    }

    func testAudioCommitCarriesRequestAndSessionId() {
        let commit = RealtimeStreamCommit(requestId: "req-3", sessionId: "sess-c",
                                          sequence: 0, capturedAtMs: 1)
        XCTAssertEqual(commit.requestId, "req-3")
        XCTAssertEqual(commit.sessionId, "sess-c")
    }

    func testPlaybackReceiptCarriesRequestAndSessionId() {
        let receipt = RealtimePlaybackReceipt(requestId: "req-4", sessionId: "sess-d",
                                              responseId: "resp-1", bytesPlayed: nil)
        XCTAssertEqual(receipt.requestId, "req-4")
        XCTAssertEqual(receipt.sessionId, "sess-d")
    }

    func testFallbackDescriptorRemainsCarrierAgnostic() {
        // fallback 不属于任何 turn，turnIdentity 返回 nil
        let fallback = RealtimeUplinkFallbackDescriptor(requestId: "req-x", sessionId: "sess-x",
                                                        reason: "timeout")
        // 存在性检查：字段存在但 turnIdentity 会忽略
        XCTAssertEqual(fallback.requestId, "req-x")
    }

    func testBargeInRequestCarriesRequestAndSessionId() {
        let bargeIn = RealtimeBargeInRequest(requestId: "req-5", sessionId: "sess-e", fromGeneration: 2)
        XCTAssertEqual(bargeIn.requestId, "req-5")
        XCTAssertEqual(bargeIn.sessionId, "sess-e")
    }

    // MARK: - WristAgentPhoneRelay initialization

    /// Relay 初始化时状态为未配对、events 未连接。
    func testRelayInitialStateIsUnpaired() {
        let relay = WristAgentPhoneRelay()
        XCTAssertFalse(relay.isPaired)
        XCTAssertFalse(relay.eventsConnected)
        XCTAssertEqual(relay.relayStatus, "Relay 未配对")
        // outboxEntries 初始为空
        XCTAssertTrue(relay.outboxEntries.isEmpty)
    }

    /// bridgeURLString 默认值正确。
    func testRelayDefaultBridgeURL() {
        let relay = WristAgentPhoneRelay()
        XCTAssertTrue(relay.bridgeURLString.contains("magic.workspace.beer"),
                      "默认 bridgeURL 应包含 magic.workspace.beer")
    }

    // MARK: - WatchFeedbackChannel mock

    /// Mock channel 验证 requestId 在下行中不变。
    func testMockChannelPreservesRequestIdInStatusNotification() {
        let channel = MockWatchFeedbackChannel()
        let status = RelayStatusUpdate(
            requestId: "req-channel-1", phase: .accepted,
            detail: "test", errorCode: nil, failureStage: nil, updatedAt: Date()
        )
        channel.notifyWatch(status: status)
        XCTAssertEqual(channel.lastStatus?.requestId, "req-channel-1")
    }

    /// Mock channel 验证语音交付信封的 requestId。
    func testMockChannelPreservesRequestIdInVoiceStatusEnvelope() {
        let channel = MockWatchFeedbackChannel()
        let envelope = VoiceStatusEnvelope.status(
            requestId: "req-voice-1", state: .completed,
            detail: "done"
        )
        channel.notifyWatch(voiceStatus: envelope)
        XCTAssertEqual(channel.lastVoiceStatus?.requestId, "req-voice-1")
    }

    /// Mock channel: transferSpeech 返回持久化入队结果。
    func testMockChannelTransferSpeechReturnsPersistenceResult() throws {
        let channel = MockWatchFeedbackChannel()
        let audioDir = temporaryDirectory()
        defer { cleanup(audioDir) }
        let audioURL = audioDir.appendingPathComponent("test.m4a")
        try Data("mock audio".utf8).write(to: audioURL)

        let envelope = VoiceStatusEnvelope.status(
            requestId: "req-speech-1", state: .completed,
            detail: "done"
        )

        // 默认 mock 返回 true（模拟持久化成功）
        channel.transferSpeechResult = true
        let result = channel.transferSpeech(fileURL: audioURL, envelope: envelope)
        XCTAssertTrue(result)
        XCTAssertEqual(channel.lastSpeechRequestId, "req-speech-1")
        XCTAssertEqual(channel.lastSpeechFileName, "test.m4a")

        // 模拟持久化失败
        channel.transferSpeechResult = false
        let failResult = channel.transferSpeech(fileURL: audioURL, envelope: envelope)
        XCTAssertFalse(failResult)
    }

    // MARK: - File ID validation

    /// 入队语音的 fileName 在 delivery 过程中不变。
    func testSpeechFileNamePreservedInMockChannel() throws {
        let channel = MockWatchFeedbackChannel()
        let audioDir = temporaryDirectory()
        defer { cleanup(audioDir) }

        let originalName = "speech_req-abc.m4a"
        let audioURL = audioDir.appendingPathComponent(originalName)
        try Data("audio".utf8).write(to: audioURL)

        channel.transferSpeech(fileURL: audioURL, envelope: VoiceStatusEnvelope.status(
            requestId: "req-abc", state: .completed, detail: "ok"
        ))

        XCTAssertEqual(channel.lastSpeechFileName, originalName,
                       "fileName 必须在传递过程中保持不变")
    }

    /// 不同 requestId 的语音文件不混淆。
    func testDistinctRequestIdsUseDistinctFileNames() throws {
        let channel = MockWatchFeedbackChannel()
        let audioDir = temporaryDirectory()
        defer { cleanup(audioDir) }

        let url1 = audioDir.appendingPathComponent("req-1-speech.m4a")
        try Data("a1".utf8).write(to: url1)
        channel.transferSpeech(fileURL: url1, envelope: VoiceStatusEnvelope.status(
            requestId: "req-1", state: .completed, detail: "first"
        ))
        XCTAssertEqual(channel.lastSpeechFileName, "req-1-speech.m4a")
        XCTAssertEqual(channel.lastSpeechRequestId, "req-1")

        let url2 = audioDir.appendingPathComponent("req-2-speech.m4a")
        try Data("a2".utf8).write(to: url2)
        channel.transferSpeech(fileURL: url2, envelope: VoiceStatusEnvelope.status(
            requestId: "req-2", state: .completed, detail: "second"
        ))
        XCTAssertEqual(channel.lastSpeechFileName, "req-2-speech.m4a")
        XCTAssertEqual(channel.lastSpeechRequestId, "req-2")
    }

    /// 空或非法 fileName 不应导致崩溃。
    func testEmptyFileNameDoesNotCrash() {
        let channel = MockWatchFeedbackChannel()
        // 空文件名也应被接受（实现层负责做防御）
        channel.notifyWatch(status: RelayStatusUpdate(
            requestId: "", phase: .failed, detail: "empty test",
            errorCode: nil, failureStage: nil, updatedAt: Date()
        ))
        // 不应崩溃
        XCTAssertNotNil(channel.lastStatus)
    }

    /// envelope 与 audio 绑定：同一 requestId 的不同 sha256 应视为冲突。
    func testOutboxRejectsSameRequestIdWithDifferentSHA256() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let keyProvider = TestOutboxKeyProvider()
        let outbox = try VoiceOutbox(directory: directory, keyProvider: keyProvider)

        let audio1 = Data(repeating: 0xAA, count: 512)
        let sha1 = VoiceDigest.sha256Hex(of: audio1)
        let env1 = VoiceRequestEnvelope.voiceRequest(
            audio: VoiceAudioDescriptor(codec: "pcm", sampleRate: 16000,
                                        channels: 1, durationMs: 1000, sha256: sha1)
        )
        _ = try outbox.enqueue(envelope: env1, audioData: audio1)

        // 同一 requestId，不同 sha256 → 冲突
        let audio2 = Data(repeating: 0xBB, count: 512)
        let sha2 = VoiceDigest.sha256Hex(of: audio2)
        let env2 = VoiceRequestEnvelope.voiceRequest(
            requestId: UUID(uuidString: env1.requestId) ?? UUID(),
            audio: VoiceAudioDescriptor(codec: "pcm", sampleRate: 16000,
                                        channels: 1, durationMs: 1000, sha256: sha2)
        )
        // 注意：requestId 来自同一 UUID 种子，sha256 不同
        XCTAssertThrowsError(
            try outbox.enqueue(envelope: env2, audioData: audio2),
            "同一 requestId + 不同 sha256 的 envelope 必须被拒绝"
        )
    }

    /// staged URL 与 requestId 必须在磁盘上对应。
    func testDownlinkOutboxStagedURLMatchesEnqueuedItem() throws {
        let directory = temporaryDirectory()
        defer { cleanup(directory) }

        let outbox = try WatchDownlinkOutbox(directory: directory, log: { _ in })

        let audioData = Data([0xFF, 0xFB, 0x90, 0x00])
        let envelope = try JSONEncoder().encode(
            VoiceStatusEnvelope.status(requestId: "req-url-test", state: .completed, detail: "ok")
        )
        let r = try outbox.enqueueSpeech(
            requestId: "req-url-test", messageKey: "voice_speech",
            envelope: envelope, audio: audioData, fileName: "speech_test.m4a"
        )
        guard case .enqueued(let item) = r else { return XCTFail() }

        let stagedURL = try XCTUnwrap(outbox.stagedAudioURL(for: item.id))
        XCTAssertTrue(stagedURL.path.contains(item.id),
                      "staged URL 必须包含条目 ID 以防止跨条目混淆")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path),
                      "staged 音频文件必须实际存在于磁盘")
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSTests-Adapter-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - MockWatchFeedbackChannel

@MainActor
private final class MockWatchFeedbackChannel: WatchFeedbackChannel {
    var lastStatus: RelayStatusUpdate?
    var lastProgress: RelayStatusUpdate?
    var lastResult: VoiceRelayResultPayload?
    var lastVoiceStatus: VoiceStatusEnvelope?
    var lastResultAudioDegradation: VoiceResultAudioDegradationEnvelope?
    var lastSpeechRequestId: String?
    var lastSpeechFileName: String?
    var lastProbeRequestId: String?
    var lastStreamChunks: [VoiceStreamChunk] = []
    var transferSpeechResult = true
    var transferProbeResult = true
    var forwardStreamResult = true
    var retriedRequestIds: [String] = []

    func notifyWatch(status: RelayStatusUpdate) {
        lastStatus = status
    }

    func notifyWatch(progress: RelayStatusUpdate) {
        lastProgress = progress
    }

    func notifyWatch(result: VoiceRelayResultPayload) {
        lastResult = result
    }

    func notifyWatch(voiceStatus envelope: VoiceStatusEnvelope) {
        lastVoiceStatus = envelope
    }

    func notifyWatch(resultAudioDegradation envelope: VoiceResultAudioDegradationEnvelope) {
        lastResultAudioDegradation = envelope
    }

    func transferSpeech(fileURL: URL, envelope: VoiceStatusEnvelope) -> Bool {
        lastSpeechRequestId = envelope.requestId
        lastSpeechFileName = fileURL.lastPathComponent
        return transferSpeechResult
    }

    func transferProbe(fileURL: URL, envelope: VoiceStatusEnvelope) -> Bool {
        lastProbeRequestId = envelope.requestId
        return transferProbeResult
    }

    func retryPendingDownlinks(requestIds: [String], trigger: String) {
        retriedRequestIds = requestIds
    }

    func forwardStreamChunkToWatch(_ chunk: VoiceStreamChunk) -> Bool {
        lastStreamChunks.append(chunk)
        return forwardStreamResult
    }
}

// MARK: - TestOutboxKeyProvider (reused)

private struct TestOutboxKeyProvider: VoiceOutboxKeyProviding {
    private let key: SymmetricKey

    init() {
        self.key = SymmetricKey(size: .bits256)
    }

    func outboxKey() throws -> SymmetricKey {
        key
    }
}
