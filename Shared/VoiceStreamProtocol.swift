import CryptoKit
import Foundation

/// ESS-249 L1: streaming is an explicitly enabled debug path until the L2
/// foreground/wrist-down/screen-off device gate passes. Production must keep
/// the complete m4a + transferFile path as its default.
enum VoiceStreamingGate {
    static let defaultEnabled = false
}

/// Compile-time transport contract. `sendMessageData` is reachable-only and
/// best-effort: it must never be used as a durable queue. A failed stream falls
/// back once to the existing reliable complete-file path.
enum VoiceStreamTransportSemantics: Equatable {
    case reachableBestEffort
    case reliableCompleteFileFallback
}

enum VoiceStreamDirection: String, Codable, Equatable {
    case uplink
    case downlink
}

struct VoiceStreamChunk: Codable, Equatable {
    static let protocolVersion = 2

    let protocolVersion: Int
    let requestId: String
    let streamId: String
    let direction: VoiceStreamDirection
    let sequence: Int
    let capturedAtMs: Int64
    let codec: String
    let sampleRate: Int
    let payload: Data
    let payloadSha256: String
    let endOfStream: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case streamId = "stream_id"
        case direction, sequence
        case capturedAtMs = "captured_at_ms"
        case codec
        case sampleRate = "sample_rate"
        case payload
        case payloadSha256 = "payload_sha256"
        case endOfStream = "end_of_stream"
    }

    init(
        protocolVersion: Int = Self.protocolVersion,
        requestId: String,
        streamId: String,
        direction: VoiceStreamDirection,
        sequence: Int,
        capturedAtMs: Int64,
        codec: String,
        sampleRate: Int,
        payload: Data,
        payloadSha256: String? = nil,
        endOfStream: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.streamId = streamId
        self.direction = direction
        self.sequence = sequence
        self.capturedAtMs = capturedAtMs
        self.codec = codec
        self.sampleRate = sampleRate
        self.payload = payload
        self.payloadSha256 = payloadSha256 ?? Self.sha256(payload)
        self.endOfStream = endOfStream
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum VoiceStreamValidationError: Error, Equatable {
    case unsupportedVersion
    case invalidRequestId
    case invalidStreamId
    case invalidSequence
    case invalidTimestamp
    case unsupportedCodec
    case unsupportedSampleRate
    case emptyPayload
    case payloadTooLarge
    case digestMismatch
}

struct VoiceStreamValidator {
    let maxPayloadBytes: Int
    let allowedCodecs: Set<String>
    let allowedSampleRates: Set<Int>

    init(
        maxPayloadBytes: Int = 64 * 1024,
        allowedCodecs: Set<String> = ["pcm_s16le", "aac_lc"],
        allowedSampleRates: Set<Int> = [16_000, 24_000]
    ) {
        self.maxPayloadBytes = maxPayloadBytes
        self.allowedCodecs = allowedCodecs
        self.allowedSampleRates = allowedSampleRates
    }

    func validate(_ chunk: VoiceStreamChunk) -> VoiceStreamValidationError? {
        guard chunk.protocolVersion == VoiceStreamChunk.protocolVersion else { return .unsupportedVersion }
        guard UUID(uuidString: chunk.requestId) != nil else { return .invalidRequestId }
        guard UUID(uuidString: chunk.streamId) != nil else { return .invalidStreamId }
        guard chunk.sequence >= 0 else { return .invalidSequence }
        guard chunk.capturedAtMs > 0 else { return .invalidTimestamp }
        guard allowedCodecs.contains(chunk.codec) else { return .unsupportedCodec }
        guard allowedSampleRates.contains(chunk.sampleRate) else { return .unsupportedSampleRate }
        guard !chunk.payload.isEmpty || chunk.endOfStream else { return .emptyPayload }
        guard chunk.payload.count <= maxPayloadBytes else { return .payloadTooLarge }
        guard VoiceStreamChunk.sha256(chunk.payload) == chunk.payloadSha256.lowercased() else {
            return .digestMismatch
        }
        return nil
    }
}

enum VoiceStreamFallbackReason: Equatable {
    case invalidChunk(VoiceStreamValidationError)
    case sequenceWindowExceeded
    case backpressure
    case gapTimedOut
    case streamEndedWithGap
}

enum VoiceStreamBufferResult: Equatable {
    case accepted
    case duplicate
    case ready([VoiceStreamChunk])
    case fallback(VoiceStreamFallbackReason)
    case alreadyFellBack
}

/// Deterministic L1 reorder/backpressure state machine. It owns no timers and
/// no transport; callers invoke `gapTimedOut()` from their clock. Fallback is
/// absorbing, guaranteeing at most one complete-file retry per stream.
struct VoiceStreamReorderBuffer {
    let validator: VoiceStreamValidator
    let maxBufferedBytes: Int
    let maxSequenceWindow: Int

    private(set) var nextSequence = 0
    private(set) var bufferedBytes = 0
    private(set) var didFallback = false
    private var pending: [Int: VoiceStreamChunk] = [:]

    init(
        validator: VoiceStreamValidator = .init(),
        maxBufferedBytes: Int = 256 * 1024,
        maxSequenceWindow: Int = 32
    ) {
        self.validator = validator
        self.maxBufferedBytes = maxBufferedBytes
        self.maxSequenceWindow = maxSequenceWindow
    }

    mutating func append(_ chunk: VoiceStreamChunk) -> VoiceStreamBufferResult {
        guard !didFallback else { return .alreadyFellBack }
        if let error = validator.validate(chunk) { return fallBack(.invalidChunk(error)) }
        if chunk.sequence < nextSequence || pending[chunk.sequence] != nil { return .duplicate }
        guard chunk.sequence - nextSequence <= maxSequenceWindow else {
            return fallBack(.sequenceWindowExceeded)
        }
        guard bufferedBytes + chunk.payload.count <= maxBufferedBytes else {
            return fallBack(.backpressure)
        }

        pending[chunk.sequence] = chunk
        bufferedBytes += chunk.payload.count
        var ready: [VoiceStreamChunk] = []
        while let contiguous = pending.removeValue(forKey: nextSequence) {
            bufferedBytes -= contiguous.payload.count
            ready.append(contiguous)
            nextSequence += 1
        }
        if chunk.endOfStream && !pending.isEmpty { return fallBack(.streamEndedWithGap) }
        return ready.isEmpty ? .accepted : .ready(ready)
    }

    mutating func gapTimedOut() -> VoiceStreamBufferResult {
        guard !didFallback else { return .alreadyFellBack }
        guard !pending.isEmpty else { return .accepted }
        return fallBack(.gapTimedOut)
    }

    private mutating func fallBack(_ reason: VoiceStreamFallbackReason) -> VoiceStreamBufferResult {
        didFallback = true
        pending.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        return .fallback(reason)
    }
}
