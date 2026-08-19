import Foundation
import Testing
@testable import WristAgentCore

struct LocalVADEndpointerTests {
    private let frameMs: Int64 = 100

    @Test func sevenHundredMillisecondsSilenceFinalizes() {
        var vad = LocalVADEndpointer()
        var events: [LocalVADEvent] = []
        events += feed(&vad, rms: 0.08, frames: 3, startingAt: 0)
        events += feed(&vad, rms: 0, frames: 7, startingAt: 300)

        #expect(events == [
            .speechStarted(atMs: 0),
            .speechFinal(atMs: 1_000, reason: .silence)
        ])
    }

    @Test func fiveHundredMillisecondPauseDoesNotFinalize() {
        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0.08, frames: 3, startingAt: 0)
        events += feed(&vad, rms: 0, frames: 5, startingAt: 300)
        events += feed(&vad, rms: 0.08, frames: 1, startingAt: 800)

        #expect(events == [.speechStarted(atMs: 0)])
    }

    /// ESS-865：预热窗（300ms）内的帧只用来估底噪，`speechStarted` 的**候选
    /// 起点**仍是第一帧——起判时刻不因预热而漂移。
    @Test func playbackGuardSuppressesEchoFrames() {
        var vad = LocalVADEndpointer()
        vad.playbackEnded(atMs: 1_000)

        var events = feed(&vad, rms: 0.2, frames: 3, startingAt: 1_000)
        events += feed(&vad, rms: 0.2, frames: 3, startingAt: 1_300)

        #expect(events == [.speechStarted(atMs: 1_300)])
    }

    @Test func continuousNoiseFinalizesAtMaximumTurnDuration() {
        var vad = LocalVADEndpointer(configuration: LocalVADConfiguration(maximumTurnMs: 60_000))
        let events = feed(&vad, rms: 0.08, frames: 601, startingAt: 0)

        #expect(events.first == .speechStarted(atMs: 0))
        #expect(events.last == .speechFinal(atMs: 60_000, reason: .maximumDuration))
    }

    // MARK: - ESS-865

    /// 本单的回归钉子。真机 `.voiceChat`（AEC）路径下说话电平远低于历史固定门
    /// 0.018（-35 dBFS）：08-11 起 13 次录音一次 `speech_started` 都没有，回合
    /// 一路悬到 60s 录音自停。同样的电平现在必须能起判并在 700ms 静音后断句。
    @Test func attenuatedSpeechBelowLegacyFixedThresholdStillEndpoints() {
        let attenuated = 0.006
        #expect(attenuated < LocalVADConfiguration().speechRMS, "样本必须低于历史固定门，否则钉不住回归")

        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0.0005, frames: 3, startingAt: 0)      // 采集起来后的环境底噪
        events += feed(&vad, rms: attenuated, frames: 10, startingAt: 300)  // 1s 说话
        events += feed(&vad, rms: 0.0005, frames: 7, startingAt: 1_300)     // 700ms 静音

        #expect(events == [
            .speechStarted(atMs: 300),
            .speechFinal(atMs: 2_000, reason: .silence)
        ])
    }

    /// 稳态环境噪声不得被当成说话——否则每一轮都会「起判 → 断句 → 提交噪声 →
    /// 没听清 → 重新聆听」空转。
    @Test func steadyBackgroundNoiseNeverStartsSpeech() {
        var vad = LocalVADEndpointer()
        let events = feed(&vad, rms: 0.01, frames: 50, startingAt: 0)

        #expect(events.isEmpty)
        #expect(vad.thresholdRMS > 0.01)
    }

    /// 同一环境噪声之上的真实说话仍要起判并断句。
    @Test func speechAboveBackgroundNoiseStillEndpoints() {
        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0.01, frames: 20, startingAt: 0)       // 2s 环境噪声
        events += feed(&vad, rms: 0.09, frames: 10, startingAt: 2_000)      // 1s 说话
        events += feed(&vad, rms: 0.01, frames: 7, startingAt: 3_000)       // 700ms 回到噪声

        #expect(events == [
            .speechStarted(atMs: 2_000),
            .speechFinal(atMs: 3_700, reason: .silence)
        ])
    }

    /// 一次都没起判过也必须有终点。真机上正是这条缺口把回合悬到 60s 录音
    /// 自停之后（`session_turn_cap_reached` → `recording_never_started`）。
    @Test func maximumDurationFinalizesEvenWhenSpeechNeverDetected() {
        var vad = LocalVADEndpointer(configuration: LocalVADConfiguration(maximumTurnMs: 5_000))
        let events = feed(&vad, rms: 0.0005, frames: 60, startingAt: 0)

        #expect(events == [.speechFinal(atMs: 5_000, reason: .maximumDuration)])
    }

    /// 单轮上限必须小于 `AudioRecorder.maxDuration`（60s），否则提交发生在
    /// AVAudioRecorder 自停之后，本地 AAC 收尾会走进「从未起录」误判。
    @Test func defaultMaximumTurnLeavesHeadroomBeforeRecorderHardStop() {
        #expect(LocalVADConfiguration().maximumTurnMs < 60_000)
    }

    /// 判定门永远被绝对上下限夹住：既不会比历史固定门更迟钝，也不会低到
    /// 把底噪当说话。
    @Test func thresholdStaysWithinConfiguredBounds() {
        let configuration = LocalVADConfiguration()
        var quiet = LocalVADEndpointer(configuration: configuration)
        _ = feed(&quiet, rms: 0.00001, frames: 10, startingAt: 0)
        #expect(quiet.thresholdRMS >= configuration.minimumSpeechRMS)

        var loud = LocalVADEndpointer(configuration: configuration)
        _ = feed(&loud, rms: 0.5, frames: 10, startingAt: 0)
        #expect(loud.thresholdRMS <= configuration.speechRMS)
    }

    /// 取证：每轮能量/门限必须可读，否则真机上「为什么不断句」再次不可判定。
    @Test func metricsExposeEnergyEvidence() {
        var vad = LocalVADEndpointer()
        _ = feed(&vad, rms: 0.0005, frames: 3, startingAt: 0)
        _ = feed(&vad, rms: 0.06, frames: 5, startingAt: 300)

        let metrics = vad.metrics
        #expect(metrics.frameCount == 8)
        #expect(metrics.speechFrameCount == 5)
        #expect(abs(metrics.peakRMS - 0.06) < 0.001)
        #expect(metrics.didDetectSpeech)
        #expect(metrics.logDetail.contains("threshold="))
        #expect(metrics.logDetail.contains("speech_detected=true"))
    }

    /// 与 `WatchRealtimeMediaAdapterTests.testVADFinalAutomaticallyCommitsExactlyOnce`
    /// 完全同一串帧（3 帧底噪 → 2 帧说话 → 8 帧静音）。adapter 只是把帧转给
    /// 本类型，所以这条在 SwiftPM 侧确定性地钉住那条 Watch 用例的断言
    /// （events.count == 2 且末条是 silence 断句）。
    @Test func adapterFrameSequenceYieldsExactlyStartAndSilenceFinal() {
        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0, frames: 3, startingAt: 0)
        events += feed(&vad, rms: 0.08, frames: 2, startingAt: 300)
        events += feed(&vad, rms: 0, frames: 8, startingAt: 500)

        #expect(events == [
            .speechStarted(atMs: 300),
            .speechFinal(atMs: 1_200, reason: .silence)
        ])
    }

    @Test func rmsReadsLittleEndianPCM16() {
        let pcm = makePCM(rms: 0.25)
        #expect(abs(LocalVADEndpointer.rms(ofPCM16: pcm) - 0.25) < 0.01)
    }

    private func feed(
        _ vad: inout LocalVADEndpointer,
        rms: Double,
        frames: Int,
        startingAt start: Int64
    ) -> [LocalVADEvent] {
        var events: [LocalVADEvent] = []
        for index in 0..<frames {
            events += vad.processPCM16(
                makePCM(rms: rms),
                frameStartedAtMs: start + Int64(index) * frameMs
            )
        }
        return events
    }

    private func makePCM(rms: Double) -> Data {
        let sample = Int16((rms * Double(Int16.max)).rounded())
        var littleEndian = sample.littleEndian
        let sampleBytes = withUnsafeBytes(of: &littleEndian) { Data($0) }
        var data = Data(capacity: 3_200)
        for _ in 0..<1_600 { data.append(sampleBytes) }
        return data
    }
}
