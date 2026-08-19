import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-891 unit tests for the deterministic PCM16 level metering used by the
/// low-volume diagnosis. The Watch and Gateway must compute identical RMS /
/// peak numbers so the source-vs-player comparison is meaningful.
final class PCM16LevelMeterTests: XCTestCase {

    private func int16Data(_ samples: [Int16]) -> Data {
        var data = Data()
        samples.forEach { sample in
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testSilenceHasZeroRMSAndPeak() {
        let level = PCM16LevelMeter.measure(int16Data([0, 0, 0, 0]))
        XCTAssertNotNil(level)
        XCTAssertEqual(level?.rms, 0)
        XCTAssertEqual(level?.peak, 0)
        XCTAssertEqual(level?.frameCount, 4)
    }

    func testFullScaleSineHasKnownRMSAndPeak() {
        // A single full-scale sample (32767) must read back exactly.
        let level = PCM16LevelMeter.measure(int16Data([32767, -32767]))
        XCTAssertEqual(level?.peak, 32767)
        XCTAssertEqual(level?.rms, 32767)
    }

    func testHalfScaleRMS() {
        // RMS of a constant half-scale signal is exactly half-scale.
        let level = PCM16LevelMeter.measure(int16Data([16384, 16384, 16384, 16384]))
        XCTAssertEqual(level?.rms ?? 0, 16384, accuracy: 0.001)
        XCTAssertEqual(level?.peak, 16384)
    }

    func testEmptyPayloadReturnsNil() {
        XCTAssertNil(PCM16LevelMeter.measure(Data()))
    }

    func testAccumulatorFoldsChunksWithoutClipping() {
        var acc = PCM16LevelAccumulator()
        let a = PCM16LevelMeter.measure(int16Data([16384, 16384]))!
        let b = PCM16LevelMeter.measure(int16Data([0, 0]))!
        acc.accumulate(a)
        acc.accumulate(b)
        let aggregate = acc.level
        XCTAssertEqual(aggregate?.frameCount, 4)
        // RMS of [16384, 16384, 0, 0] = 16384 / sqrt(2).
        XCTAssertEqual(aggregate?.rms ?? 0, 16384 / sqrt(2), accuracy: 0.001)
        XCTAssertEqual(aggregate?.peak, 16384)
    }

    func testPeakDBFSReferencePoints() {
        let full = PCM16LevelMeter.measure(int16Data([32767]))!
        XCTAssertEqual(full.peakDBFS, 0, accuracy: 0.001)
        let half = PCM16LevelMeter.measure(int16Data([16384]))!
        XCTAssertEqual(half.peakDBFS, -6.02, accuracy: 0.05)
        let silence = PCM16LevelMeter.measure(int16Data([0]))!
        XCTAssertEqual(silence.rmsDBFS, -.infinity)
    }
}
