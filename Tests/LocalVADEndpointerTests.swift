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
        var events = feed(&vad, rms: 0.08, frames: 2, startingAt: 0)
        events += feed(&vad, rms: 0, frames: 5, startingAt: 200)
        events += feed(&vad, rms: 0.08, frames: 1, startingAt: 700)

        #expect(events == [.speechStarted(atMs: 0)])
    }

    @Test func playbackGuardSuppressesEchoFrames() {
        var vad = LocalVADEndpointer()
        vad.playbackEnded(atMs: 1_000)

        var events = feed(&vad, rms: 0.2, frames: 3, startingAt: 1_000)
        events += feed(&vad, rms: 0.2, frames: 1, startingAt: 1_300)

        #expect(events == [.speechStarted(atMs: 1_300)])
    }

    @Test func continuousNoiseFinalizesAtMaximumTurnDuration() {
        var vad = LocalVADEndpointer(configuration: LocalVADConfiguration(maximumTurnMs: 60_000))
        let events = feed(&vad, rms: 0.08, frames: 601, startingAt: 0)

        #expect(events.first == .speechStarted(atMs: 0))
        #expect(events.last == .speechFinal(atMs: 60_000, reason: .maximumDuration))
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
