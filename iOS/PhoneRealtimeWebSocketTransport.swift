import Foundation
import os

/// ESS-321 production transport for `PhoneRealtimeSession`. Wraps a
/// `URLSessionWebSocketTask` speaking the Bridge realtime WSS endpoint owned
/// by ESS-322 (`server.mjs` in PR #113).
///
/// Wire schema: the Bridge accepts **flat** JSON messages tagged by top-level
/// `type` — see `RealtimeBridgeWireCodec` for the exact shape. This transport
/// runs Watch → iPhone envelopes through the codec on the way out and Bridge
/// downlink events through the codec on the way back in. That keeps schema
/// drift confined to one file and lets `Tests/` verify the exact strings the
/// Bridge will see without spinning up a socket.
///
/// Deliberately minimal: connection setup, receive loop, and send. No retry
/// or backoff — the coordinator on the watch treats a failure as a signal
/// to trigger the single full-file fallback for this turn.
@MainActor
final class PhoneRealtimeWebSocketTransport: PhoneRealtimeSession.Transport {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "RealtimeSocket"
    )
    private let task: URLSessionWebSocketTask
    private var isClosed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func send(_ envelope: RealtimeUplinkEnvelope, completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosed else {
            completion(NSError(domain: "PhoneRealtimeWebSocketTransport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "socket already closed"
            ]))
            return
        }
        guard let text = RealtimeBridgeWireCodec.encode(envelope) else {
            completion(NSError(domain: "PhoneRealtimeWebSocketTransport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "envelope encode failed"
            ]))
            return
        }
        task.send(.string(text)) { error in
            Task { @MainActor in completion(error) }
        }
        if case .fallback = envelope.kind {
            // Bridge sees fallback as socket close — no more messages after.
            isClosed = true
            task.cancel(with: .goingAway, reason: envelope.fallback?.reason.data(using: .utf8))
        }
    }

    func receive(handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void) {
        guard !isClosed else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let message):
                    let outcome: RealtimeBridgeWireCodec.DecodeOutcome
                    switch message {
                    case .data(let data): outcome = RealtimeBridgeWireCodec.decodeOutcome(data)
                    case .string(let text): outcome = RealtimeBridgeWireCodec.decodeOutcome(text)
                    @unknown default:
                        handler(.failure(NSError(
                            domain: "PhoneRealtimeWebSocketTransport", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "unknown message kind"]
                        )))
                        return
                    }
                    switch outcome {
                    case .envelope(let envelope):
                        handler(.success(envelope))
                    case .unrecognised(let type):
                        // ESS-329: Bridge PR #113 emits `ready` after `start`
                        // (and may add more heartbeats over time). Well-formed
                        // frames the codec has no route for MUST NOT kill the
                        // socket — log and keep receiving so the next
                        // `audio.delta` still arrives.
                        Self.logger.info(
                            "realtime downlink unrecognised type=\(type, privacy: .public)"
                        )
                        self.receive(handler: handler)
                    case .malformed:
                        handler(.failure(NSError(
                            domain: "PhoneRealtimeWebSocketTransport", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "invalid downlink frame"]
                        )))
                    }
                case .failure(let error):
                    handler(.failure(error))
                }
            }
        }
    }

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        Self.logger.info("realtime socket close reason=\(reason, privacy: .public)")
        task.cancel(with: .goingAway, reason: reason.data(using: .utf8))
    }
}
