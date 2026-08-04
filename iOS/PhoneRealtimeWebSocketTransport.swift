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
                    switch message {
                    case .data(let data):
                        if let envelope = RealtimeBridgeWireCodec.decode(data) {
                            handler(.success(envelope))
                        } else {
                            handler(.failure(NSError(
                                domain: "PhoneRealtimeWebSocketTransport", code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "invalid downlink frame"]
                            )))
                        }
                    case .string(let text):
                        if let envelope = RealtimeBridgeWireCodec.decode(text) {
                            handler(.success(envelope))
                        } else {
                            handler(.failure(NSError(
                                domain: "PhoneRealtimeWebSocketTransport", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "invalid downlink frame"]
                            )))
                        }
                    @unknown default:
                        handler(.failure(NSError(
                            domain: "PhoneRealtimeWebSocketTransport", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "unknown message kind"]
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
