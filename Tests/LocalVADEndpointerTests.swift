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

    /// ESS-865 复审阻断 2：**从未检测到语音的纯静音不得伪造断句**。
    /// 上层对任何 `speechFinal` 都会无条件 `commitUplink()`；一旦提交，回合就
    /// 离开 listening，会话层 30s/75s 提示与 120s 静默挂断从此永远到不了。
    /// 静音的归属是会话层的静默治理，不是断句器。
    @Test func pureSilenceNeverFabricatesFinalAtMaximumDuration() {
        var vad = LocalVADEndpointer(configuration: LocalVADConfiguration(maximumTurnMs: 5_000))
        let events = feed(&vad, rms: 0.0005, frames: 120, startingAt: 0)   // 12s，远超 5s 上限

        #expect(events.isEmpty)
        #expect(!vad.metrics.didDetectSpeech)
    }

    /// 但**说过话**的回合仍必须在上限处提交——持续说话不能悬到录音硬顶之后。
    @Test func continuousSpeechStillFinalizesAtMaximumDuration() {
        var vad = LocalVADEndpointer(configuration: LocalVADConfiguration(maximumTurnMs: 5_000))
        let events = feed(&vad, rms: 0.08, frames: 120, startingAt: 0)

        #expect(events.first == .speechStarted(atMs: 0))
        #expect(events.last == .speechFinal(atMs: 5_000, reason: .maximumDuration))
    }

    /// ESS-865 复审阻断 1 的回归钉子：**用户一开麦就说话**（第 0 帧起就是
    /// AEC 电平 0.006 RMS），此时底噪只能从语音帧里估，最小统计必然把说话
    /// 电平本身当成底噪、把门顶到 0.018。停说后安静期到来、门落下来，
    /// pre-roll 必须被回判，补出 `speechStarted` 并正常断句。
    @Test func speechFromFirstFrameIsRecoveredOnceNoiseFloorSettles() {
        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0.006, frames: 10, startingAt: 0)      // 1s 说话，从第 0 帧起
        #expect(events.isEmpty, "门被语音自身顶高时，起判只能延后，不能靠假设前几帧是环境音")

        events += feed(&vad, rms: 0.0005, frames: 7, startingAt: 1_000)     // 停说 700ms

        #expect(events == [
            .speechStarted(atMs: 0),
            .speechFinal(atMs: 1_700, reason: .silence)
        ])
    }

    /// 回判不得把稳态噪声也救回来：噪声从头到尾没有更安静的时刻，
    /// 判定门永远不下降，pre-roll 因此永远不会被回放。
    @Test func preRollReplayDoesNotResurrectSteadyNoise() {
        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0.01, frames: 30, startingAt: 0)
        events += feed(&vad, rms: 0.01, frames: 30, startingAt: 3_000)

        #expect(events.isEmpty)
    }

    /// ESS-961（2026-08-22 真机回归）：麦克风启动瞬态**不得**被回判成语音。
    ///
    /// 换 `.spokenAudio` 后（ESS-891 音量修复）真机首轮实测：
    ///
    /// ```
    /// 17:54:47.496  vad_level      rms=0.00660 noise_floor=0.00660 threshold=0.01800 speech_detected=false
    /// 17:54:47.656  speech_started rms=0.00125 noise_floor=0.00125 threshold=0.00374 speech_frames=0  ← 零语音帧却起判
    /// 17:54:48.163  speech_final   reason=silence frames=8 speech_frames=0
    /// ```
    ///
    /// 麦克风刚启动的几帧电平偏高（0.00660），底噪就按它初始化；随后落到真实
    /// 底噪 0.00125，门从 0.01800 掉到 0.00374 → 触发 pre-roll 回判 → 而
    /// pre-roll 里那帧 0.00660 **正是当初构成高底噪的那一帧**，在新门下当然
    /// 跨门 → 补发 `speechStarted` → 700ms 静音立刻 `speechFinal`。
    /// 整轮 956ms，用户根本来不及开口，提交上去的是空音频。
    ///
    /// `.voiceChat` 一直替它遮着：AGC 让底噪平稳，门全程钉在下限从不下降，
    /// 回判分支一次都走不到。
    @Test func micStartupTransientIsNotReplayedAsSpeech() {
        var vad = LocalVADEndpointer()
        // 真机数值：先 2 帧启动瞬态，再落到真实底噪。
        var events = feed(&vad, rms: 0.00660, frames: 2, startingAt: 0)
        events += feed(&vad, rms: 0.00125, frames: 10, startingAt: 200)

        #expect(events.isEmpty)
        #expect(!vad.metrics.didDetectSpeech)
    }

    /// 对照：ESS-865 复审阻断 1 要救的那条时序**必须继续成立**——
    /// 一开麦就说话，底噪只能从语音帧里估，门被顶高压住了起判；
    /// 说完安静下来门落回，这段真语音要被回判救回。
    ///
    /// 与上一条的差别只有一个：真语音相对底噪的余量足够大
    /// （0.01098/0.00125 ≈ 8.8×，而启动瞬态只有 0.0066/0.00125 ≈ 5.3×）。
    ///
    /// 取 08-20 真机 `speech_started rms=0.01098` 那一轮的量级——它低于
    /// 绝对上限 `speechRMS = 0.018`，所以实时路径判不出来，**只能靠回判救回**，
    /// 正是这条用例要守的路径。
    @Test func immediateSpeechIsStillRescuedByPreRollReplay() {
        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0.01098, frames: 4, startingAt: 0)
        events += feed(&vad, rms: 0.00125, frames: 10, startingAt: 400)

        #expect(events.contains { if case .speechStarted = $0 { return true }; return false })
    }

    /// 回判救回的帧必须计进 `speech_frames`，否则真机日志出现
    /// 「`speech_started` 却 `speech_frames=0`」这种自相矛盾的取证，
    /// 定位时无法分辨是回判救回的还是误判。
    @Test func replayedFramesAreCountedAsSpeechFrames() {
        var vad = LocalVADEndpointer()
        _ = feed(&vad, rms: 0.01098, frames: 4, startingAt: 0)
        _ = feed(&vad, rms: 0.00125, frames: 10, startingAt: 400)

        #expect(vad.metrics.didDetectSpeech)
        #expect(vad.metrics.speechFrameCount > 0,
                "speech_started 却 speech_frames=0 是不可解释的取证")
    }

    /// ESS-961 第二轮（2026-08-21 18:14 真机）：**单帧脉冲不得开启一轮**。
    ///
    /// 上一版修好了回判误判（这轮 `speech_frames=1` 说明走的是实时路径，
    /// 回判分支没再触发），但暴露了下一层：
    ///
    /// ```
    /// 18:14:13.309  frames=1   rms=0.00134 noise_floor=0.00134 threshold=0.00401 speech_detected=false
    /// 18:14:14.964  speech_started frames=18 speech_frames=1 rms=0.00670 noise_floor=0.00069 threshold=0.00350
    /// 18:14:15.679  speech_final   reason=silence frames=25 speech_frames=1
    /// ```
    ///
    /// 整轮**只有 1 帧**越过门。帧长约 97ms，而 `speechStartMs = 100ms`——
    /// 一帧的时长就已经满足 `frameEndedAtMs - candidateStart >= speechStartMs`，
    /// 于是任意一个孤立脉冲（咂嘴、碰撞、环境瞬态）都能开启一轮，700ms 后
    /// 收口提交，用户来不及说话。
    ///
    /// 时长条件挡不住这个：一帧就是 100ms。只能显式要求**连续多帧**。
    @Test func isolatedLoudFrameDoesNotStartSpeech() {
        var vad = LocalVADEndpointer()
        // 真机数值：底噪 0.00069 附近，中间夹一帧 0.00670 的孤立脉冲。
        var events = feed(&vad, rms: 0.00069, frames: 15, startingAt: 0)
        events += feed(&vad, rms: 0.00670, frames: 1, startingAt: 1_500)
        events += feed(&vad, rms: 0.00072, frames: 12, startingAt: 1_600)

        #expect(events.isEmpty)
        #expect(!vad.metrics.didDetectSpeech)
    }

    /// 对照：真说话（连续多帧）必须照常起判并断句——不能为了挡脉冲把
    /// 短促但真实的一句话也挡掉。
    @Test func shortRealUtteranceStillStartsAndEndpoints() {
        var vad = LocalVADEndpointer()
        var events = feed(&vad, rms: 0.00069, frames: 15, startingAt: 0)
        events += feed(&vad, rms: 0.00670, frames: 4, startingAt: 1_500)
        events += feed(&vad, rms: 0.00072, frames: 10, startingAt: 1_900)

        #expect(events.contains { if case .speechStarted = $0 { return true }; return false })
        #expect(events.contains { if case .speechFinal = $0 { return true }; return false })
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
