import XCTest

@testable import WristAgent_Watch_App

/// ESS-748：流播放器起播失败必须**立即降级一次**，不得静默丢音。
///
/// 缺陷原样（`Watch/WatchStreamReceiver.swift`）：
/// - `StreamingAudioPlayer.start()` 捕获错误后返回 Void，失败对调用方不可见；
/// - `ensurePlayer` 不论成败都把 player 存进 `StreamState`；
/// - `apply(.ready)` 照旧 `append` 并推进 `playedSequence`，EOS 时照旧
///   `markEndOfStream()`，而 `append` 因 `isStarted == false` 每一帧静默丢弃。
///
/// 净效果：整段回答无声消失，用户没有任何提示，也**不会**触发
/// `fallbackHandler` 走完整文件降级。本套件把修复后的四条口径钉住。
@MainActor
final class WatchStreamPlayerStartFailureTests: XCTestCase {

    /// 起播必失败的替身——模拟器里无法稳定制造 AVAudioEngine 启动失败。
    private final class FailingPlayer: StreamAudioPlaying {
        struct StartError: Error {}
        private(set) var appendedBytes = 0
        private(set) var endOfStreamMarked = false
        private(set) var stopCount = 0

        func start() throws { throw StartError() }
        func append(pcmData: Data) { appendedBytes += pcmData.count }
        func markEndOfStream() { endOfStreamMarked = true }
        func stop() { stopCount += 1 }
    }

    private final class RecordingPlayer: StreamAudioPlaying {
        private(set) var appendedBytes = 0
        func start() throws {}
        func append(pcmData: Data) { appendedBytes += pcmData.count }
        func markEndOfStream() {}
        func stop() {}
    }

    private func makeReceiver(
        player: @escaping () -> StreamAudioPlaying,
        onFallback: @escaping (String, VoiceStreamFallbackReason) -> Void = { _, _ in }
    ) -> WatchStreamReceiver {
        let suiteName = "ESS748.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        let settings = WatchDebugSettings(defaults: defaults)
        let receiver = WatchStreamReceiver(debugSettings: settings, fallbackHandler: onFallback)
        receiver.makeStreamPlayer = { _, _ in player() }
        return receiver
    }

    private func chunk(
        requestId: String,
        streamId: String,
        sequence: Int,
        endOfStream: Bool = false
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId, streamId: streamId, direction: .downlink,
            sequence: sequence, capturedAtMs: 1_785_810_000_000,
            codec: "pcm_s16le", sampleRate: 24_000,
            payload: Data(repeating: 0x01, count: 320), endOfStream: endOfStream
        )
    }

    // MARK: - 起播失败必须降级

    /// 核心：起播失败 → `fallbackHandler` 被调用**恰好一次**，reason 是
    /// `playerStartFailed`。修复前这里一次都不会被调用。
    func testPlayerStartFailureTriggersFallbackExactlyOnce() {
        var fallbacks: [(String, VoiceStreamFallbackReason)] = []
        let receiver = makeReceiver(player: { FailingPlayer() }) { fallbacks.append(($0, $1)) }
        let rid = UUID().uuidString
        let sid = UUID().uuidString

        receiver.receive(chunk: chunk(requestId: rid, streamId: sid, sequence: 0))

        XCTAssertEqual(fallbacks.count, 1, "起播失败必须降级，且只降一次")
        XCTAssertEqual(fallbacks.first?.0, rid)
        XCTAssertEqual(fallbacks.first?.1, .playerStartFailed)
    }

    /// 降级之后继续到达的 chunk 不得再次触发降级（单发语义），也不得
    /// 重新起播——`didFallback` 已经把这条流封死。
    func testSubsequentChunksAfterFailureDoNotRefallback() {
        var fallbacks = 0
        let receiver = makeReceiver(player: { FailingPlayer() }) { _, _ in fallbacks += 1 }
        let rid = UUID().uuidString
        let sid = UUID().uuidString

        receiver.receive(chunk: chunk(requestId: rid, streamId: sid, sequence: 0))
        receiver.receive(chunk: chunk(requestId: rid, streamId: sid, sequence: 1))
        receiver.receive(chunk: chunk(requestId: rid, streamId: sid, sequence: 2, endOfStream: true))

        XCTAssertEqual(fallbacks, 1, "单发降级：后续 chunk 不得反复触发")
    }

    /// 起播失败时**不得推进 played sequence**，也不得标记 EOS——推进了
    /// 等于宣称「这段已经放过了」，降级方拿不到正确的续播位置。
    func testFailedStartDoesNotAdvanceOrMarkEndOfStream() {
        let failing = FailingPlayer()
        let receiver = makeReceiver(player: { failing })
        let rid = UUID().uuidString
        let sid = UUID().uuidString

        receiver.receive(chunk: chunk(requestId: rid, streamId: sid, sequence: 0, endOfStream: true))

        XCTAssertEqual(failing.appendedBytes, 0, "起播失败的播放器绝不能再喂数据")
        XCTAssertFalse(failing.endOfStreamMarked, "起播失败不得标记 EOS")
    }

    // MARK: - 正常路径不受影响

    /// 反向保真：起播成功时照常喂数据、不降级。修复不能把好路径一起改坏。
    func testSuccessfulStartStillPlaysAndDoesNotFallback() {
        var fallbacks = 0
        let player = RecordingPlayer()
        let receiver = makeReceiver(player: { player }) { _, _ in fallbacks += 1 }
        let rid = UUID().uuidString
        let sid = UUID().uuidString

        receiver.receive(chunk: chunk(requestId: rid, streamId: sid, sequence: 0))

        XCTAssertEqual(fallbacks, 0, "起播成功不得降级")
        XCTAssertGreaterThan(player.appendedBytes, 0, "起播成功必须真的喂到播放器")
    }
}
