import Foundation

/// WCSession `sendMessageData` payload marker for downlink `VoiceStreamChunk`.
/// Watch-side `didReceiveMessageData` tries this decode first (the chunk carries
/// a unique `protocolVersion` + `direction` discriminator); falling through to
/// `AgentConfiguration` keeps the existing config path intact.
///
/// The `envelopeKey` is reserved for `sendMessage` / `transferUserInfo`
/// dictionary routing when B2/B3 uses those channels; ESS-324 B4 receiver
/// currently goes through raw `sendMessageData`.
enum VoiceStreamChunkMessage {
    static let envelopeKey = "voice_stream_chunk"
}
