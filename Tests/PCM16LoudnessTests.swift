import Foundation
import Testing

@testable import WristAgentCore

/// ESS-891：下行 PCM16 响度取证与安全增益的确定性单测。
///
/// 验收口径对应：
/// - 正常 PCM 不被衰减 → `applyUnityGainIsBitExact` / `applyHalfGainIsExact`
/// - 增益不削波 → `applyGainClampsAtFullScaleWithoutWraparound` /
///   `safeNormalizationGainCapsAtFullScaleHeadroom`
/// - 首帧 RMS/peak/dBFS 口径一致 → `analyze*`
struct PCM16LoudnessTests {
    private func makePCM(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var littleEndian = sample.littleEndian
            data.append(withUnsafeBytes(of: &littleEndian) { Data($0) })
        }
        return data
    }

    private func repeating(_ sample: Int16, count: Int) -> Data {
        makePCM(Array(repeating: sample, count: count))
    }

    private func samples(of data: Data) -> [Int16] {
        let count = (data.count & ~1) / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { raw in
            (0..<count).map { raw.load(fromByteOffset: $0 * MemoryLayout<Int16>.size, as: Int16.self) }
        }
    }

    // MARK: - 分析口径

    @Test func analyzeFullScaleReportsUnityAndZeroDBFS() {
        let level = PCM16Loudness.analyze(repeating(Int16.max, count: 1_600))
        #expect(level.sampleCount == 1_600)
        #expect(abs(level.rms - 1.0) < 0.0001)
        #expect(abs(level.peak - 1.0) < 0.0001)
        #expect(abs(level.rmsDBFS - 0.0) < 0.001)
        #expect(abs(level.peakDBFS - 0.0) < 0.001)
        #expect(level.peakSample == Int16.max)
    }

    @Test func analyzeHalfScaleReportsMinusSixDBFS() {
        let level = PCM16Loudness.analyze(repeating(16_384, count: 1_600))
        #expect(abs(level.rms - 0.5) < 0.001)
        #expect(abs(level.peak - 0.5) < 0.001)
        #expect(abs(level.peakDBFS - (-6.0206)) < 0.01)
    }

    @Test func analyzeSilenceAndEmptyAreWellDefined() {
        let silent = PCM16Loudness.analyze(repeating(0, count: 1_600))
        #expect(silent.rms == 0)
        #expect(silent.peak == 0)
        #expect(silent.rmsDBFS == -.infinity)
        #expect(silent.isNearSilence())

        let empty = PCM16Loudness.analyze(Data())
        #expect(empty.sampleCount == 0)
        #expect(empty.rms == 0)
        #expect(empty.isNearSilence())
    }

    @Test func analyzeOddTailByteIsIgnored() {
        var data = repeating(16_384, count: 4)
        data.append(0xFF) // 奇数尾字节不得参与样本计数，也不得导致越界
        let level = PCM16Loudness.analyze(data)
        #expect(level.sampleCount == 4)
        #expect(abs(level.rms - 0.5) < 0.001)
    }

    @Test func dbfsConvertsKnownLinearLevels() {
        #expect(abs(PCM16Loudness.dBFS(linear: 1.0) - 0.0) < 0.0001)
        #expect(abs(PCM16Loudness.dBFS(linear: 0.5) - (-6.0206)) < 0.001)
        #expect(PCM16Loudness.dBFS(linear: 0) == -.infinity)
    }

    // MARK: - 增益：不被衰减 / 不削波

    @Test func applyUnityGainIsBitExact() {
        let input = makePCM([0, 1, -1, 16_384, -16_384, Int16.max, Int16.min])
        let output = PCM16Loudness.applyGain(input, linearGain: 1.0)
        #expect(output == input, "unity gain 必须按位不变——正常 PCM 不被衰减")
    }

    @Test func applyHalfGainIsExact() {
        let input = repeating(16_384, count: 8) // 0.5 满量程，无舍入歧义
        let output = PCM16Loudness.applyGain(input, linearGain: 0.5)
        #expect(samples(of: output) == Array(repeating: 8_192, count: 8))
    }

    @Test func applyGainClampsAtFullScaleWithoutWraparound() {
        // 0.5 满量程 × 2.0 增益 = 1.0 满量程，恰好削到 Int16.max，
        // 绝不允许回绕成负样本（反相爆音）。
        let input = repeating(16_384, count: 1_600)
        let output = PCM16Loudness.applyGain(input, linearGain: 2.0)
        let outSamples = samples(of: output)
        #expect(outSamples.allSatisfy { $0 == Int16.max })
        let level = PCM16Loudness.analyze(output)
        #expect(level.peak <= 1.0)
    }

    @Test func applyGainThatWouldClipHardLimitsAtFullScale() {
        // 满量程 × 4.0 会远超 Int16 范围，必须硬削波到 Int16.max/min。
        let input = makePCM([Int16.max, Int16.min, 8_192, -8_192])
        let output = PCM16Loudness.applyGain(input, linearGain: 4.0)
        #expect(samples(of: output) == [Int16.max, Int16.min, Int16.max, Int16.min])
    }

    @Test func safeNormalizationGainCapsAtPeakHeadroom() {
        // 目标 RMS 0.5，当前 RMS 0.25、peak 0.9：按 RMS 要 ×2，但 ×2 会削波
        // （peak 0.9 → 1.8），安全增益必须被 peak 头room（1/0.9 ≈ 1.11）封顶。
        let gain = PCM16Loudness.safeNormalizationGain(
            targetRMS: 0.5, currentRMS: 0.25, currentPeak: 0.9
        )
        #expect(gain != nil)
        #expect(abs(gain! - (1.0 / 0.9)) < 0.0001)
    }

    @Test func safeNormalizationGainReturnsNilWhenNoHeadroomOrAlreadyLoud() {
        #expect(PCM16Loudness.safeNormalizationGain(targetRMS: 0.5, currentRMS: 0.6, currentPeak: 0.9) == nil)
        #expect(PCM16Loudness.safeNormalizationGain(targetRMS: 0.5, currentRMS: 0, currentPeak: 0.5) == nil)
        #expect(PCM16Loudness.gain(toReachTargetRMS: 0.5, currentRMS: 0.6) == nil)
        #expect(PCM16Loudness.gain(toReachTargetRMS: 0.5, currentRMS: 0.25) == 2.0)
    }

    @Test func normalizedOutputPeakNeverExceedsFullScale() {
        // 一个接近满量程的尖峰 + 大量静音：peak 高、RMS 低。安全增益必须被
        // peak 头room（1/peak）封顶，合成路径输出 peak 恒 ≤ 1.0 且不回绕。
        var samples = Array(repeating: Int16(0), count: 1_600)
        samples[0] = 32_439 // ≈ 0.99 满量程
        let input = makePCM(samples)
        let level = PCM16Loudness.analyze(input)
        #expect(abs(level.peak - 0.99) < 0.01)
        let gain = PCM16Loudness.safeNormalizationGain(
            targetRMS: 0.5, currentRMS: level.rms, currentPeak: level.peak
        )
        #expect(gain != nil)
        #expect(abs(gain! - (1.0 / level.peak)) < 0.001, "增益必须被 peak 头room封顶")
        let output = PCM16Loudness.applyGain(input, linearGain: gain!)
        #expect(PCM16Loudness.analyze(output).peak <= 1.0)
        #expect(PCM16Loudness.analyze(output).peakSample == Int16.max)
    }
}
