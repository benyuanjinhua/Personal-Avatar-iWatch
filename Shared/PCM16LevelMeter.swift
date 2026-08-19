import Foundation

/// ESS-891: deterministic PCM16 level metering.
///
/// Both the Watch (player input) and the Gateway (downlink first frame)
/// compute RMS / peak with the same math so the two numbers are directly
/// comparable in `bridge.log`. The payload is little-endian Int16 PCM
/// (`pcm_s16le`), the downlink contract used by the realtime audio plane.
struct PCM16LevelMeter {
    struct Level: Equatable, Sendable {
        /// RMS magnitude in Int16 units (0 … 32768).
        let rms: Double
        /// Peak magnitude in Int16 units (0 … 32768).
        let peak: Double
        /// Number of PCM frames measured.
        let frameCount: Int

        var rmsDBFS: Double {
            rms > 0 ? 20 * log10(rms / 32768.0) : -.infinity
        }

        var peakDBFS: Double {
            peak > 0 ? 20 * log10(peak / 32768.0) : -.infinity
        }

        /// Single-line evidence fragment, stable field names for grep.
        var detail: String {
            String(
                format: "rms=%.2f peak=%.2f rms_dbfs=%.2f peak_dbfs=%.2f frames=%d",
                rms, peak, rmsDBFS, peakDBFS, frameCount
            )
        }
    }

    /// Measures RMS / peak of little-endian Int16 PCM. Returns `nil` for an
    /// empty payload (an odd trailing byte is ignored, matching the frame
    /// boundary of `mBytesPerFrame == 2`).
    static func measure(_ payload: Data) -> Level? {
        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }
        var sumSquares: Int64 = 0
        var peak: Int32 = 0
        payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let sample = Int32(base[i])
                sumSquares += Int64(sample) * Int64(sample)
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
            }
        }
        let rms = sqrt(Double(sumSquares) / Double(sampleCount))
        return Level(rms: rms, peak: Double(peak), frameCount: sampleCount)
    }
}

/// ESS-891: turn-scoped accumulator that folds per-chunk levels into a
/// single aggregate RMS / peak for the whole response. Kept in Shared/ so
/// the aggregation is unit-testable without AVFoundation.
struct PCM16LevelAccumulator: Sendable {
    private var sumSquares: Int64 = 0
    private var peak: Int32 = 0
    private var totalFrames: Int = 0

    var isEmpty: Bool { totalFrames == 0 }

    mutating func accumulate(_ level: PCM16LevelMeter.Level) {
        sumSquares += Int64(level.rms * level.rms) * Int64(level.frameCount)
        if Int32(level.peak) > peak { peak = Int32(level.peak) }
        totalFrames += level.frameCount
    }

    var level: PCM16LevelMeter.Level? {
        guard totalFrames > 0 else { return nil }
        let rms = sqrt(Double(sumSquares) / Double(totalFrames))
        return PCM16LevelMeter.Level(rms: rms, peak: Double(peak), frameCount: totalFrames)
    }

    mutating func reset() {
        sumSquares = 0
        peak = 0
        totalFrames = 0
    }
}
