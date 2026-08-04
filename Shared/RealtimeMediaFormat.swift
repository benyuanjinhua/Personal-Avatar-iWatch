import Foundation

/// ESS-321 Real-time media contract.
///
/// The Watch/iPhone/Bridge/Agent loop uses a fixed 16k mono PCM16 uplink and
/// 24k mono PCM16 downlink for the streaming path. These values are the shared
/// source of truth: any producer/consumer that drifts from them is a bug and
/// the validator in `VoiceStreamValidator` rejects the mismatch.
struct RealtimeMediaFormat: Equatable, Hashable, Sendable {
    let codec: String
    let sampleRate: Int
    let channelCount: Int

    init(codec: String, sampleRate: Int, channelCount: Int = 1) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Fixed watch microphone → bridge upload contract.
    static let uplinkPCM16 = RealtimeMediaFormat(codec: "pcm_s16le", sampleRate: 16_000)

    /// Fixed bridge → watch playback contract.
    static let downlinkPCM16 = RealtimeMediaFormat(codec: "pcm_s16le", sampleRate: 24_000)

    /// Bytes per second for the format (mono PCM16 only — the streaming path
    /// does not carry compressed audio yet; ESS-265 will graft Opus in when
    /// bandwidth / battery need it).
    var bytesPerSecond: Int { sampleRate * channelCount * 2 }

    /// Convenience: how many bytes cover the given millisecond window.
    func bytes(forMilliseconds ms: Int) -> Int {
        max(1, (bytesPerSecond * ms + 500) / 1_000)
    }
}
