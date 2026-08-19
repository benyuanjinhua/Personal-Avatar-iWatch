import Foundation

/// ESS-891：下行 PCM16 响度取证与安全增益（纯函数，可确定性单测）。
///
/// 背景：真机复测确认「回答已播放但音量过小」，但现有日志只有播放
/// 开始/完成与字节数，无法区分是 Qwen 源音频低、PCM 解码衰减、播放器
/// 增益还是 Watch 路由。本工具把「下行 PCM 的 rms / peak」与「削波安全
/// 的增益」收敛到一处：Watch 播放侧与 Gateway 侧按同一口径对同一
/// request_id 取证，才能证明是否发生幅度衰减，并让修复只落在证据指向的
/// 那一层（禁止双端同时盲目加增益）。
enum PCM16Loudness {
    /// 一段 PCM16（小端）的响度分析结果。
    struct Level: Equatable, Sendable {
        /// 有效样本数（`pcm.count / 2`，奇数尾部字节忽略）。
        let sampleCount: Int
        /// 线性 RMS（满量程相对值；1.0 = 满幅正弦波）。
        let rms: Double
        /// 线性 peak（满量程相对值）。
        let peak: Double
        /// RMS 的 dBFS 表示。
        let rmsDBFS: Double
        /// peak 的 dBFS 表示。
        let peakDBFS: Double
        /// 绝对值最大的样本（原始 Int16，用于削波取证）。
        let peakSample: Int16

        /// 是否接近静音（低于给定 dBFS 门，默认 -60 dBFS）。
        func isNearSilence(dBFSThreshold: Double = -60) -> Bool {
            rmsDBFS < dBFSThreshold
        }
    }

    /// 分析 PCM16（小端）数据的响度。非 2 字节对齐的尾部字节忽略。
    static func analyze(_ pcm: Data) -> Level {
        let byteCount = pcm.count & ~1
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            return Level(
                sampleCount: 0, rms: 0, peak: 0,
                rmsDBFS: -.infinity, peakDBFS: -.infinity, peakSample: 0
            )
        }
        var sumSquares = 0.0
        var peak = 0.0
        var peakSample: Int16 = 0
        pcm.withUnsafeBytes { raw in
            for index in 0..<sampleCount {
                let value = raw.load(fromByteOffset: index * MemoryLayout<Int16>.size, as: Int16.self)
                let normalized = Double(value) / Double(Int16.max)
                sumSquares += normalized * normalized
                let magnitude = abs(normalized)
                if magnitude > peak {
                    peak = magnitude
                    peakSample = value
                }
            }
        }
        let rms = (sumSquares / Double(sampleCount)).squareRoot()
        return Level(
            sampleCount: sampleCount,
            rms: rms,
            peak: peak,
            rmsDBFS: dBFS(linear: rms),
            peakDBFS: dBFS(linear: peak),
            peakSample: peakSample
        )
    }

    /// 线性幅度（满量程相对值）转 dBFS。0 或负输入返回 -infinity。
    static func dBFS(linear amplitude: Double) -> Double {
        guard amplitude > 0 else { return -.infinity }
        return 20 * log10(amplitude)
    }

    /// 计算把当前 RMS 提升到目标 RMS 所需的线性增益。
    /// 当前已达标或当前为静音时返回 nil（不降增益、不对静音放大噪声）。
    static func gain(toReachTargetRMS targetRMS: Double, currentRMS: Double) -> Double? {
        guard currentRMS > 0, targetRMS > currentRMS else { return nil }
        return targetRMS / currentRMS
    }

    /// 计算「提升到目标 RMS」且「不削波」的安全线性增益：取
    /// `targetRMS / currentRMS` 与 `1 / currentPeak`（削波上限）的较小者。
    /// 结果 ≤ 1 时返回 nil（无提升空间，宁可不加增益也不放大噪声）。
    static func safeNormalizationGain(
        targetRMS: Double, currentRMS: Double, currentPeak: Double
    ) -> Double? {
        guard currentRMS > 0, currentPeak > 0, targetRMS > currentRMS else { return nil }
        let rmsGain = targetRMS / currentRMS
        let peakGain = 1.0 / currentPeak
        let gain = min(rmsGain, peakGain)
        guard gain > 1.0 else { return nil }
        return gain
    }

    /// 对 PCM16（小端）应用线性增益。
    /// - `linearGain == 1.0`：按位原样返回（正常 PCM 不被衰减的机械保证）。
    /// - 超过满量程的样本被硬削波到 `Int16.max / Int16.min`，绝不回绕成
    ///   反相爆音（增益不削波的机械保证）。
    /// - `linearGain <= 0`：返回全静音（等长）。
    /// 奇数尾部字节原样保留。
    static func applyGain(_ pcm: Data, linearGain: Double) -> Data {
        if linearGain == 1.0 { return pcm }
        let byteCount = pcm.count & ~1
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return pcm }
        var output = Data(count: pcm.count)
        if pcm.count % 2 != 0, let tail = pcm.last {
            output[output.count - 1] = tail
        }
        if linearGain <= 0 { return output }
        pcm.withUnsafeBytes { raw in
            output.withUnsafeMutableBytes { outRaw in
                for index in 0..<sampleCount {
                    let offset = index * MemoryLayout<Int16>.size
                    let value = raw.load(fromByteOffset: offset, as: Int16.self)
                    let scaled = Double(value) * linearGain
                    let clamped = min(Double(Int16.max), max(Double(Int16.min), scaled))
                    outRaw.storeBytes(
                        of: Int16(clamped.rounded()), toByteOffset: offset, as: Int16.self
                    )
                }
            }
        }
        return output
    }
}
