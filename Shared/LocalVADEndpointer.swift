import Foundation

public struct LocalVADConfiguration: Equatable, Sendable {
    public var sampleRate: Int
    /// 判定门的**上限**：帧能量超过它一定算语音。历史固定阈值（-35 dBFS），
    /// `VoiceBargeInDetector` 也以它为基准，故语义与取值保持不变。
    public var speechRMS: Double
    /// 判定门的**下限**：噪声底再低，门也不会低于它。
    ///
    /// ESS-865：`.voiceChat`（AEC）路径下麦克风增益比 `.spokenAudio` 低得多，
    /// 固定 0.018 的门在真机上一次都没被跨过（08-11 起 13 次录音 0 次
    /// `speech_started`，而 `.spokenAudio` 的 08-09/08-10 是 68 次录音 29 次）。
    /// 下限取 -49 dBFS，让被 AEC 压低的正常说话仍能起判。
    public var minimumSpeechRMS: Double
    /// 相对噪声底的信噪比要求（线性倍数，3.0 ≈ +9.5 dB）。
    public var noiseFloorRatio: Double
    /// **回判**专用的信噪比要求，必须严于 `noiseFloorRatio`。
    ///
    /// ESS-961：回判是一次「推翻既有判决」的动作——同一帧此前已经被判过
    /// 一次「不是语音」，而回判并没有任何新证据，只是门降下来了。门降下来
    /// 本身可能恰恰是因为**那几帧就是当初把门顶高的噪声**（麦克风启动瞬态），
    /// 此时按实时门回判等于用噪声推翻对噪声的正确判决。所以要更高的门槛。
    ///
    /// 6.0 ≈ +15.6 dB。标定依据是两次真机实测：
    ///
    /// | 场景 | rms / 底噪 | 倍数 | 期望 |
    /// |---|---|---|---|
    /// | 麦克风启动瞬态（08-22 回归） | 0.00660 / 0.00125 | 5.3× | 不得救回 |
    /// | 一开麦就说话（ESS-865 阻断 1） | 0.01098 / 0.00125 | 8.8× | 必须救回 |
    ///
    /// 【标定样本 n=2】按 R-04.4 这不足以支撑一个普遍常数，两侧余量也不宽
    /// （5.3 与 8.8 之间只夹得下一个值）。真机多设备采样后应重新标定。
    public var replayNoiseFloorRatio: Double
    /// 噪声底的最小统计窗口。窗内取最小值作为底噪估计（min-statistics）。
    public var noiseWindowMs: Int64
    /// 起判前 pre-roll 的最长回溯跨度。判定门下降时按新门重判这段历史，
    /// 救回「一开麦就说话、底噪只能从语音帧里估」那条时序（ESS-865 复审阻断 1）。
    public var preRollMs: Int64
    public var speechStartMs: Int64
    /// 起判所需的**最少连续帧数**。
    ///
    /// ESS-961 第二轮：`speechStartMs = 100ms` 而真机帧长约 97ms——一帧的
    /// 时长就已经满足时长条件，于是任意一个孤立脉冲（咂嘴、碰撞、环境瞬态）
    /// 都能开启一轮，700ms 后收口提交，用户来不及说话（2026-08-21 18:14
    /// 真机：整轮 `speech_frames=1`，rms=0.00670 单帧越过 0.00350 的门）。
    ///
    /// 时长条件从原理上挡不住它——一帧就是一个 `speechStartMs`。判据必须
    /// 显式落在「连续性」上：孤立脉冲只有一帧，真语音跨多帧。
    public var minimumSpeechFrames: Int
    public var endpointSilenceMs: Int64
    public var playbackGuardMs: Int64
    /// 单轮硬上限。**必须小于 `AudioRecorder.maxDuration`**：AVAudioRecorder
    /// 到点自停后本地 AAC 收尾会走进「从未起录」误判（ESS-865 真机
    /// `raw_ms=61912` / `bytes=261121` 被整轮丢弃）。
    public var maximumTurnMs: Int64

    public init(
        sampleRate: Int = 16_000,
        speechRMS: Double = 0.018,
        minimumSpeechRMS: Double = 0.0035,
        noiseFloorRatio: Double = 3.0,
        replayNoiseFloorRatio: Double = 6.0,
        noiseWindowMs: Int64 = 2_000,
        preRollMs: Int64 = 8_000,
        speechStartMs: Int64 = 100,
        minimumSpeechFrames: Int = 2,
        endpointSilenceMs: Int64 = 700,
        playbackGuardMs: Int64 = 300,
        maximumTurnMs: Int64 = 55_000
    ) {
        precondition(sampleRate > 0)
        precondition(speechRMS >= 0)
        precondition(minimumSpeechRMS >= 0)
        precondition(minimumSpeechRMS <= speechRMS)
        precondition(noiseFloorRatio >= 1)
        precondition(replayNoiseFloorRatio >= noiseFloorRatio)
        precondition(noiseWindowMs > 0)
        precondition(preRollMs > 0)
        precondition(speechStartMs > 0)
        precondition(minimumSpeechFrames >= 1)
        precondition(endpointSilenceMs > 0)
        precondition(playbackGuardMs >= 0)
        precondition(maximumTurnMs > 0)
        self.sampleRate = sampleRate
        self.speechRMS = speechRMS
        self.minimumSpeechRMS = minimumSpeechRMS
        self.noiseFloorRatio = noiseFloorRatio
        self.replayNoiseFloorRatio = replayNoiseFloorRatio
        self.noiseWindowMs = noiseWindowMs
        self.preRollMs = preRollMs
        self.speechStartMs = speechStartMs
        self.minimumSpeechFrames = minimumSpeechFrames
        self.endpointSilenceMs = endpointSilenceMs
        self.playbackGuardMs = playbackGuardMs
        self.maximumTurnMs = maximumTurnMs
    }
}

public enum LocalVADEvent: Equatable, Sendable {
    public enum FinalReason: String, Equatable, Sendable {
        case silence
        case maximumDuration = "maximum_duration"
    }

    case speechStarted(atMs: Int64)
    case speechFinal(atMs: Int64, reason: FinalReason)
}

/// ESS-865：每轮的能量取证快照。真机上「VAD 为什么不断句」此前完全不可观测
/// （日志里既没有电平也没有门限），这是本单排查耗掉一整轮真机的直接原因。
public struct LocalVADMetrics: Equatable, Sendable {
    public var frameCount: Int
    public var speechFrameCount: Int
    public var lastRMS: Double
    public var peakRMS: Double
    public var noiseFloorRMS: Double
    public var thresholdRMS: Double
    public var didDetectSpeech: Bool

    /// 供 `WatchLog.detail` 直接拼接的一行取证串。
    public var logDetail: String {
        func fixed(_ value: Double) -> String { String(format: "%.5f", value) }
        return "frames=\(frameCount) speech_frames=\(speechFrameCount) "
            + "rms=\(fixed(lastRMS)) peak_rms=\(fixed(peakRMS)) "
            + "noise_floor=\(fixed(noiseFloorRMS)) threshold=\(fixed(thresholdRMS)) "
            + "speech_detected=\(didDetectSpeech)"
    }
}

/// Deterministic PCM16 endpoint detector. Callers own the microphone and use
/// the emitted events to drive their session reducer and commit transaction.
///
/// ESS-865：判定门从「固定绝对阈值」改为「噪声底 × 信噪比，并被绝对上下限
/// 夹住」。固定阈值同时有两个失败方向，真机各踩中一个：门相对麦克风增益偏高
/// 时**永不断句**（本单），偏低时把环境噪声当说话。噪声底用最小统计
/// （窗内最小值）估计——语音的音节间谷底远高于真实静音，所以窗口内的最小值
/// 收敛到底噪而不是说话人电平。
public struct LocalVADEndpointer: Sendable {
    public private(set) var configuration: LocalVADConfiguration

    private var turnStartedAtMs: Int64 = 0
    private var speechCandidateStartedAtMs: Int64?
    /// ESS-961：当前候选段已连续跨门的帧数。孤立脉冲与真语音的唯一区别。
    private var candidateSpeechFrames = 0
    private var speechStartedAtMs: Int64?
    private var lastSpeechAtMs: Int64?
    private var guardUntilMs: Int64 = 0
    private var isFinal = false

    // 最小统计：当前子窗最小值 + 上一个完整子窗最小值，噪声底取二者较小。
    private var currentWindowMinRMS = Double.infinity
    private var previousWindowMinRMS = Double.infinity
    private var windowStartedAtMs: Int64 = 0
    private var observedFrameCount = 0
    private var speechFrameCount = 0
    private var lastRMS: Double = 0
    private var peakRMS: Double = 0

    /// ESS-865 复审整改：起判前的 pre-roll。缓存「还没被判成语音」的帧能量，
    /// 供判定门下降后回溯重判。
    ///
    /// 为什么需要回溯：第 0 帧就开口说话时，底噪估计手上只有语音帧，
    /// 最小统计必然把说话电平本身当成底噪，门被顶到 `rms × ratio` 之上，
    /// 于是**这一整段说话永远跨不过门**——正是本单要救的 AEC 低电平时序。
    /// 靠「前 N 帧一定是环境音」的假设来回避是错的（复审阻断 1）。
    /// 真正能区分「0.006 是说话」与「0.010 是稳态噪声」的信息只有一个：
    /// 后者从头到尾没有更安静的时刻，前者停说后有。所以判据只能延后到
    /// 安静期出现、底噪真正落下来时再回头补判。
    ///
    /// 回溯只影响**判定**，不影响音频：所有帧从第 0 帧起照常上行。
    private var preRoll: [(startedAtMs: Int64, endedAtMs: Int64, rms: Double)] = []

    public init(configuration: LocalVADConfiguration = LocalVADConfiguration()) {
        self.configuration = configuration
    }

    public mutating func updateConfiguration(_ configuration: LocalVADConfiguration) {
        self.configuration = configuration
    }

    public mutating func reset(atMs: Int64 = 0) {
        turnStartedAtMs = atMs
        speechCandidateStartedAtMs = nil
        candidateSpeechFrames = 0
        speechStartedAtMs = nil
        lastSpeechAtMs = nil
        guardUntilMs = atMs
        isFinal = false
        currentWindowMinRMS = .infinity
        previousWindowMinRMS = .infinity
        windowStartedAtMs = atMs
        observedFrameCount = 0
        speechFrameCount = 0
        lastRMS = 0
        peakRMS = 0
        preRoll.removeAll(keepingCapacity: true)
    }

    /// 回答播完：开一段回声守卫窗，并把本轮聆听窗重新起算（用户的下一句
    /// 只可能发生在回答播完之后）。
    public mutating func playbackEnded(atMs: Int64) {
        speechCandidateStartedAtMs = nil
        candidateSpeechFrames = 0
        lastSpeechAtMs = nil
        guardUntilMs = atMs + configuration.playbackGuardMs
        turnStartedAtMs = guardUntilMs
        windowStartedAtMs = guardUntilMs
        preRoll.removeAll(keepingCapacity: true)
    }

    /// 当前判定门。噪声底 × 信噪比，被 `[minimumSpeechRMS, speechRMS]` 夹住。
    public var thresholdRMS: Double {
        min(configuration.speechRMS,
            max(configuration.minimumSpeechRMS, noiseFloorRMS * configuration.noiseFloorRatio))
    }

    /// 当前底噪估计。还没有任何帧时返回「刚好让门落在绝对下限」的值。
    ///
    /// 第一帧起就把观测值算进来：这一侧**故意保守**（噪声房间第 0 帧就把门
    /// 顶到 `rms × ratio`，稳态噪声当场落在门下），冷启动就说话被压住的那一段
    /// 由 pre-roll 回溯补回来，见 `replayPreRollIfThresholdDropped`。
    public var noiseFloorRMS: Double {
        let observed = min(currentWindowMinRMS, previousWindowMinRMS)
        guard observed.isFinite else {
            return configuration.minimumSpeechRMS / configuration.noiseFloorRatio
        }
        return observed
    }

    public var metrics: LocalVADMetrics {
        LocalVADMetrics(
            frameCount: observedFrameCount,
            speechFrameCount: speechFrameCount,
            lastRMS: lastRMS,
            peakRMS: peakRMS,
            noiseFloorRMS: noiseFloorRMS,
            thresholdRMS: thresholdRMS,
            didDetectSpeech: speechStartedAtMs != nil
        )
    }

    public mutating func processPCM16(_ pcm: Data, frameStartedAtMs: Int64) -> [LocalVADEvent] {
        guard !isFinal, !pcm.isEmpty else { return [] }
        let frameDurationMs = durationMs(forPCM16ByteCount: pcm.count)
        guard frameDurationMs > 0 else { return [] }
        let frameEndedAtMs = frameStartedAtMs + frameDurationMs

        // 单轮硬上限。ESS-865 复审整改：**只对已经起判过语音的回合**成立。
        // 从未检测到语音的纯静音不得在这里伪造一次 `speech_final`——那会被
        // 上层无条件 `commitUplink()` 提交成一段静音，回合离开 listening，
        // 30s/75s 提示与 120s 静默挂断从此永远到不了（复审阻断 2）。
        // 静音的归属是会话层的静默治理，不是断句器。
        if speechStartedAtMs != nil,
           frameEndedAtMs - turnStartedAtMs >= configuration.maximumTurnMs {
            isFinal = true
            return [.speechFinal(atMs: frameEndedAtMs, reason: .maximumDuration)]
        }

        // 回声守卫窗内的帧既不判定也不参与底噪统计——它们是扬声器余音。
        guard frameStartedAtMs >= guardUntilMs else { return [] }

        let rms = Self.rms(ofPCM16: pcm)
        let thresholdBefore = thresholdRMS
        observeNoiseFloor(rms: rms, frameEndedAtMs: frameEndedAtMs)

        var events: [LocalVADEvent] = []
        // 底噪落下来了 → 之前被高门压住的 pre-roll 需要按新门重判。
        if thresholdRMS < thresholdBefore, speechStartedAtMs == nil,
           let replayed = replayPreRoll() {
            events.append(replayed)
        }

        let isSpeech = rms >= thresholdRMS
        if isSpeech { speechFrameCount += 1 }

        if isSpeech {
            lastSpeechAtMs = frameEndedAtMs
            if speechStartedAtMs == nil {
                let candidateStart = speechCandidateStartedAtMs ?? frameStartedAtMs
                speechCandidateStartedAtMs = candidateStart
                candidateSpeechFrames += 1
                // ESS-961 第二轮：时长条件挡不住孤立脉冲——真机帧长 ≈97ms，
                // 一帧就已经满足 `speechStartMs = 100ms`。必须同时要求
                // **连续帧数**，孤立脉冲只有一帧，真语音跨多帧。
                if frameEndedAtMs - candidateStart >= configuration.speechStartMs,
                   candidateSpeechFrames >= configuration.minimumSpeechFrames {
                    speechStartedAtMs = candidateStart
                    events.append(.speechStarted(atMs: candidateStart))
                }
            }
            return events
        }

        if speechStartedAtMs == nil {
            // 还没起判：留一份 pre-roll 供门下降后回判。
            appendPreRoll(startedAtMs: frameStartedAtMs, endedAtMs: frameEndedAtMs, rms: rms)
        }
        speechCandidateStartedAtMs = nil
        candidateSpeechFrames = 0
        guard speechStartedAtMs != nil, let lastSpeechAtMs else { return events }
        if frameEndedAtMs - lastSpeechAtMs >= configuration.endpointSilenceMs {
            isFinal = true
            events.append(.speechFinal(atMs: frameEndedAtMs, reason: .silence))
        }
        return events
    }

    private mutating func appendPreRoll(startedAtMs: Int64, endedAtMs: Int64, rms: Double) {
        preRoll.append((startedAtMs, endedAtMs, rms))
        while let first = preRoll.first,
              endedAtMs - first.startedAtMs > configuration.preRollMs {
            preRoll.removeFirst()
        }
    }

    /// 判定门下降后回头重判 pre-roll。找到「连续跨门且累计 ≥ speechStartMs」
    /// 的那一段，按它的真实起点补发 `speechStarted`，并把 `lastSpeechAtMs`
    /// 对齐到该段最后一帧的结束时刻——断句计时因此接得上，不会因为回溯
    /// 而把已经说完的话再多等 700ms。
    ///
    /// 只在「本轮还没起判」时调用；一旦起判，pre-roll 不再增长也不再回放。
    private mutating func replayPreRoll() -> LocalVADEvent? {
        // ESS-961：回判用**更严的门**，不是实时门。
        //
        // 回判要推翻的是「这帧不是语音」这个已经做过的判决，而它手上没有任何
        // 新证据——只是门降下来了。而门降下来本身可能恰恰是因为那几帧就是当初
        // 把门顶高的噪声（麦克风启动瞬态），此时按实时门回判 = 用噪声推翻对
        // 噪声的正确判决。2026-08-22 真机回归正是这一条：0.00660 的启动瞬态
        // 在降到 0.00374 的新门下"跨门"，补发 speechStarted，700ms 后收口，
        // 整轮 956ms 提交空音频。
        let threshold = max(
            thresholdRMS, noiseFloorRMS * configuration.replayNoiseFloorRatio
        )
        var runStart: Int64?
        var runEnd: Int64?
        var runFrames = 0
        var bestFrames = 0
        for frame in preRoll {
            if frame.rms >= threshold {
                if runStart == nil { runStart = frame.startedAtMs; runFrames = 0 }
                runEnd = frame.endedAtMs
                runFrames += 1
            } else {
                if let start = runStart, let end = runEnd,
                   end - start >= configuration.speechStartMs {
                    bestFrames = runFrames
                    break
                }
                runStart = nil
                runEnd = nil
                runFrames = 0
            }
        }
        let rescuedFrames = max(bestFrames, runFrames)
        guard let start = runStart, let end = runEnd,
              end - start >= configuration.speechStartMs,
              rescuedFrames >= configuration.minimumSpeechFrames else { return nil }
        // ESS-961 取证：救回的帧必须计进 speech_frames，否则真机日志会出现
        // 「speech_started 却 speech_frames=0」这种自相矛盾的记录——本次回归
        // 的第一条线索就是它，但当时无法分辨那是回判救回的还是纯误判。
        speechFrameCount += rescuedFrames
        speechStartedAtMs = start
        lastSpeechAtMs = end
        speechCandidateStartedAtMs = nil
        candidateSpeechFrames = 0
        preRoll.removeAll(keepingCapacity: true)
        return .speechStarted(atMs: start)
    }

    /// 滑动最小统计。子窗满一个 `noiseWindowMs` 就轮转，噪声底取「当前子窗
    /// 最小值」与「上一个完整子窗最小值」中较小者——保证估计覆盖至少一个
    /// 完整窗口的历史，同时能在一个窗口内跟上环境变化。
    private mutating func observeNoiseFloor(rms: Double, frameEndedAtMs: Int64) {
        observedFrameCount += 1
        lastRMS = rms
        peakRMS = max(peakRMS, rms)
        if frameEndedAtMs - windowStartedAtMs > configuration.noiseWindowMs {
            previousWindowMinRMS = currentWindowMinRMS
            currentWindowMinRMS = .infinity
            windowStartedAtMs = frameEndedAtMs
        }
        currentWindowMinRMS = min(currentWindowMinRMS, rms)
    }

    public static func rms(ofPCM16 pcm: Data) -> Double {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumSquares = 0.0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples.prefix(sampleCount) {
                let normalized = Double(Int16(littleEndian: sample)) / Double(Int16.max)
                sumSquares += normalized * normalized
            }
        }
        return sqrt(sumSquares / Double(sampleCount))
    }

    private func durationMs(forPCM16ByteCount byteCount: Int) -> Int64 {
        let samples = byteCount / MemoryLayout<Int16>.size
        return Int64(samples * 1_000 / configuration.sampleRate)
    }
}
