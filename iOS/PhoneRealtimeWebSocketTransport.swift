import Foundation
import os

/// ESS-321 production transport for `PhoneRealtimeSession`. Wraps a
/// `URLSessionWebSocketTask` speaking the bridge's realtime WSS endpoint.
///
/// The bridge contract (owned by ESS-322) accepts one WSS connection per
/// (device, request_id, session_id) tuple. Uplink frames are sent as JSON
/// text messages; downlink events arrive as text messages with the same
/// `RealtimeDownlinkEnvelope` shape defined in `Shared`.
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
        guard let data = try? JSONEncoder().encode(envelope),
              let text = String(data: data, encoding: .utf8) else {
            completion(NSError(domain: "PhoneRealtimeWebSocketTransport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "envelope encode failed"
            ]))
            return
        }
        task.send(.string(text)) { error in
            Task { @MainActor in completion(error) }
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
                        if let envelope = try? JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data) {
                            handler(.success(envelope))
                        } else {
                            handler(.failure(NSError(
                                domain: "PhoneRealtimeWebSocketTransport", code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "invalid downlink envelope"]
                            )))
                        }
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let envelope = try? JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data) {
                            handler(.success(envelope))
                        } else {
                            handler(.failure(NSError(
                                domain: "PhoneRealtimeWebSocketTransport", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "invalid downlink envelope"]
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
