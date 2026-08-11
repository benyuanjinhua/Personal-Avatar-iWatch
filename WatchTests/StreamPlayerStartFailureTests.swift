import XCTest

@testable import WristAgent_Watch_App

/// ESS-748：流播放器启动/入队失败后必须整段降级，不得静默丢音。
///
/// 回归的事故形态：`StreamingAudioPlayer.start()` 吞掉 AVAudioSession /
/// AVAudioEngine 错误后返回 Void，`WatchStreamReceiver` 照旧保存 player、
/// 照旧推进 `playedSequence`、照旧标记 EOS，`fallbackHandler` 一次都不响 ——
/// 用户侧表现为"没有声音，也没有任何错误提示"。
///
/// 这里用注入的假 player 覆盖失败路径：真 `AVAudioEngine` 在 hosted CI 上
/// 起不来（`HostedCITestGate` 里记录的 -10868），而失败语义本身与音频硬件
/// 无关，所以这组用例在 hosted CI 上也必须跑，不加 skip。
@MainActor
final class StreamPlayerStartFailureTests: XCTestCase {

    private let requestId = UUID().uuidString
    private let streamId = UUID().uuidString

    // MARK: - Fake player

    /// 可编程失败的 `StreamingAudioPlaying`，记录收到的每一次调用。
    private final class FakePlayer: StreamingAudioPlaying {
        enum Failure {
            case none
            case onStart(Error)
            case onAppend(Error)
        }

        let failure: Failure
        private(set) var startCount = 0
        private(set) var appendedPayloads: [Data] = []
        private(set) var endOfStreamCount = 0
        private(set) var stopCount = 0

        init(failure: Failure) {
            self.failure = failure
        }

        func start() throws {
            startCount += 1
            if case .onStart(let error) = failure { throw error }
        }

        func append(pcmData: Data) throws {
            if case .onAppend(let error) = failure { throw error }
            appendedPayloads.append(pcmData)
        }

        func markEndOfStream() { endOfStreamCount += 1 }

        func stop() { stopCount += 1 }
    }

    // MARK: - Fixtures

    private func chunk(
        _ sequence: Int,
        bytes: Int = 4,
        end: Bool = false
    ) -> VoiceStreamChunk {
        VoiceStreamChunk(
            requestId: requestId,
            streamId: streamId,
            direction: .downlink,
            sequence: sequence,
            capturedAtMs: 1_785_810_000_000,
            codec: "pcm_s16le",
            sampleRate: 24_000,
            payload: Data(repeating: UInt8(sequence % 255), count: bytes),
            endOfStream: end
        )
    }

    private func makeSettings() -> WatchDebugSettings {
        let suiteName = "wristagent.tests.ess748.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: WatchDebugSettings.streamingEnabledDefaultsKey)
        return WatchDebugSettings(defaults: defaults)
    }

    private func makeReceiver(
        failure: FakePlayer.Failure,
        onFallback: @escaping (String, VoiceStreamFallbackReason) -> Void
    ) -> (WatchStreamReceiver, () -> FakePlayer?) {
        var created: FakePlayer?
        let receiver = WatchStreamReceiver(
            debugSettings: makeSettings(),
            makePlayer: { _ in
                let player = FakePlayer(failure: failure)
                created = player
                return player
            },
            fallbackHandler: onFallback
        )
        return (receiver, { created })
    }

    // MARK: - AVAudioSession / engine 启动失败

    /// `start()` 抛错（AVAudioSession 激活失败 / engine 起不来）→ 立即整段降级。
    func testPlayerStartFailureTriggersFallbackImmediately() {
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        // NSOSStatusErrorDomain -50 是真机上 AVAudioSession.setActive 最常见的
        // 失败码（ESS-61），拿它当被注入的错误，贴近真实失败形态。
        let sessionError = NSError(domain: NSOSStatusErrorDomain, code: -50)
        let (receiver, player) = makeReceiver(failure: .onStart(sessionError)) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(0))

        XCTAssertEqual(fallbackCalls.count, 1, "启动失败必须触发且只触发一次降级")
        XCTAssertEqual(fallbackCalls.first?.0, requestId)
        XCTAssertEqual(fallbackCalls.first?.1, .playerUnavailable)
        XCTAssertEqual(player()?.startCount, 1)
        XCTAssertEqual(player()?.appendedPayloads, [], "启动失败后不得再往死 player 里塞 PCM")
        XCTAssertEqual(player()?.endOfStreamCount, 0)
    }

    /// 启动失败后 sequence 不得推进 —— 否则后续 chunk 会被当成"已播过"跳掉。
    func testPlayerStartFailureDoesNotAdvancePlayedSequence() {
        let (receiver, _) = makeReceiver(failure: .onStart(StreamingAudioPlayerError.notStarted)) { _, _ in }

        receiver.receive(chunk: chunk(0))

        XCTAssertEqual(receiver.activePlayedSequence, 0, "启动失败的流不得推进 played sequence")
    }

    /// 降级是吸收态：启动失败后继续来 chunk，不再产生第二次降级，
    /// 也不再尝试新建 player。
    func testPlayerStartFailureFallsBackExactlyOnce() {
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let (receiver, player) = makeReceiver(failure: .onStart(StreamingAudioPlayerError.notStarted)) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(0))
        receiver.receive(chunk: chunk(1))
        receiver.receive(chunk: chunk(2, end: true))

        XCTAssertEqual(fallbackCalls.count, 1, "同一条流最多降级一次")
        XCTAssertEqual(player()?.startCount, 1, "降级后不应反复重建 player")
    }

    // MARK: - 入队失败

    /// `append` 抛错（buffer 分配失败等）→ 同样整段降级，且 sequence 不推进。
    func testPlayerAppendFailureTriggersFallbackAndHoldsSequence() {
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let appendError = StreamingAudioPlayerError.bufferAllocationFailed(bytes: 4)
        let (receiver, player) = makeReceiver(failure: .onAppend(appendError)) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(0))

        XCTAssertEqual(fallbackCalls.count, 1, "入队失败必须降级")
        XCTAssertEqual(fallbackCalls.first?.1, .playerUnavailable)
        XCTAssertEqual(player()?.startCount, 1, "start 成功过，失败发生在 append")
        XCTAssertEqual(player()?.endOfStreamCount, 0, "入队失败的流不得标记 EOS")
        XCTAssertEqual(receiver.activePlayedSequence, 0, "入队失败的流不得推进 played sequence")
    }

    // MARK: - 正常路径不受影响

    /// 播放器一切正常时：PCM 逐片入队、sequence 推进、EOS 标记、零降级。
    func testHealthyPlayerStillPlaysAndAdvances() {
        var fallbackCalls: [(String, VoiceStreamFallbackReason)] = []
        let (receiver, player) = makeReceiver(failure: .none) { id, reason in
            fallbackCalls.append((id, reason))
        }

        receiver.receive(chunk: chunk(0))
        receiver.receive(chunk: chunk(1, end: true))

        XCTAssertTrue(fallbackCalls.isEmpty, "健康播放器不应触发降级")
        XCTAssertEqual(player()?.appendedPayloads.count, 2)
        XCTAssertEqual(receiver.activePlayedSequence, 2, "两片播完 played sequence 应为 2")
        XCTAssertEqual(player()?.endOfStreamCount, 1)
    }
}
