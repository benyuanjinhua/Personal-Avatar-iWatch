import Foundation
import os

/// ESS-321 iPhone WSS session that carries the realtime media loop between
/// the watch (via WatchConnectivity) and the bridge (via WSS).
///
/// Responsibilities:
///
///  * open one WSS connection per request/session id and keep it hot while
///    the turn is alive;
///  * translate the Watch's `RealtimeUplinkEnvelope` into WSS text messages
///    the bridge expects (`stream.start`, `audio.append`, `audio.commit`)
///    and forward them frame-by-frame — no aggregation, no re-ordering;
///  * decode the bridge's downlink events into a `RealtimeDownlinkEnvelope`
///    and hand it back to `PhoneConnectivity` which forwards to the watch;
///  * expose a deterministic disconnect / cancel / lifecycle-switch API so
///    the caller can guarantee "no double execution, no stale playback".
///
/// The wire transport is injected via `Transport` so unit tests can
/// substitute an in-memory pipe; production wraps `URLSessionWebSocketTask`.
@MainActor
final class PhoneRealtimeSession {
    protocol Transport: AnyObject {
        func send(_ envelope: RealtimeUplinkEnvelope, completion: @escaping @MainActor (Error?) -> Void)
        func receive(handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void)
        func close(reason: String)
    }

    enum State: Equatable {
        case idle
        case connecting(requestId: String, sessionId: String)
        case active(requestId: String, sessionId: String)
        case cancelled
        case failed(reason: String)
    }

    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "RealtimeSession"
    )

    /// Bridge PR #113 `server.mjs` requires the WSS handshake to carry
    /// `?request_id=` and `?session_id=` in the URL query AND the request-id
    /// used for HMAC signing to match `request_id` — otherwise the socket
    /// closes with `ERR_STREAM_OWNERSHIP`. The factory therefore takes the
    /// (requestId, sessionId) tuple for the turn it will serve.
    private let transportFactory: (_ requestId: String, _ sessionId: String) -> Transport?
    private var currentTransport: Transport?
    private(set) var state: State = .idle
    private var pendingDownlink: [RealtimeDownlinkEnvelope] = []

    /// Emits every decoded downlink envelope. `PhoneConnectivity` bridges this
    /// back to the watch via `WatchDownlinkOutbox`.
    var onDownlink: ((RealtimeDownlinkEnvelope) -> Void)?
    /// Emits state transitions so callers can flip UI or log evidence.
    var onStateChange: ((State) -> Void)?

    init(transportFactory: @escaping (_ requestId: String, _ sessionId: String) -> Transport?) {
        self.transportFactory = transportFactory
    }

    /// Forward a Watch-side envelope. Opens the WSS session lazily on
    /// `stream.start` and tears it down on `audio.commit` completion or on
    /// the coordinator's fallback signal.
    func forward(_ envelope: RealtimeUplinkEnvelope) {
        switch envelope.kind {
        case .streamStart:
            guard let start = envelope.start else { return }
            openIfNeeded(requestId: start.requestId, sessionId: start.sessionId)
        case .audioAppend:
            guard let append = envelope.append else { return }
            openIfNeeded(requestId: append.requestId, sessionId: append.streamId)
        case .audioCommit:
            guard let commit = envelope.commit else { return }
            openIfNeeded(requestId: commit.requestId, sessionId: commit.sessionId)
        case .playbackStarted, .playbackEnded:
            guard let receipt = envelope.playback else { return }
            openIfNeeded(requestId: receipt.requestId, sessionId: receipt.sessionId)
        case .fallback:
            guard let descriptor = envelope.fallback else { return }
            transition(to: .failed(reason: descriptor.reason))
            currentTransport?.close(reason: descriptor.reason)
            currentTransport = nil
            return
        }
        guard let transport = currentTransport else { return }
        transport.send(envelope) { [weak self] error in
            if let error {
                Self.logger.error(
                    "realtime uplink send failed error=\(String(describing: error), privacy: .public)"
                )
                self?.transition(to: .failed(reason: "send_failed"))
                self?.currentTransport?.close(reason: "send_failed")
                self?.currentTransport = nil
            }
        }
        if envelope.kind == .audioCommit {
            // Commit is the last uplink frame; the bridge will finish playback
            // via `audio.done` and then close the socket.
        }
    }

    /// Watch reported the turn is over (audio.done acknowledged and playback
    /// finished) — or the user cancelled. Either way, tear down the WSS.
    func endTurn(reason: String) {
        transition(to: .cancelled)
        currentTransport?.close(reason: reason)
        currentTransport = nil
        pendingDownlink.removeAll(keepingCapacity: false)
    }

    /// System reported the phone entered background / lost network / the
    /// watch went unreachable. Same tear-down semantics — the coordinator on
    /// the watch will treat any next envelope as a new turn.
    func lifecycleInterrupted(reason: String) {
        Self.logger.notice(
            "realtime session interrupted reason=\(reason, privacy: .public)"
        )
        endTurn(reason: "lifecycle_\(reason)")
    }

    /// Recent downlink envelopes buffered while the watch reconnected — the
    /// caller can drain and forward them.
    func drainPendingDownlink() -> [RealtimeDownlinkEnvelope] {
        let snapshot = pendingDownlink
        pendingDownlink.removeAll(keepingCapacity: false)
        return snapshot
    }

    private func openIfNeeded(requestId: String, sessionId: String) {
        switch state {
        case .active(let activeRequest, let activeSession)
                where activeRequest == requestId && activeSession == sessionId:
            return
        case .connecting(let pendingRequest, let pendingSession)
                where pendingRequest == requestId && pendingSession == sessionId:
            return
        default:
            break
        }
        currentTransport?.close(reason: "supersede")
        guard let transport = transportFactory(requestId, sessionId) else {
            transition(to: .failed(reason: "no_transport"))
            return
        }
        currentTransport = transport
        transition(to: .connecting(requestId: requestId, sessionId: sessionId))
        scheduleReceive(transport)
        transition(to: .active(requestId: requestId, sessionId: sessionId))
    }

    private func scheduleReceive(_ transport: Transport) {
        transport.receive { [weak self, weak transport] result in
            guard let self, let transport, self.currentTransport === transport else { return }
            switch result {
            case .success(let envelope):
                self.pendingDownlink.append(envelope)
                self.onDownlink?(envelope)
                self.scheduleReceive(transport)
            case .failure(let error):
                Self.logger.error(
                    "realtime downlink recv failed error=\(String(describing: error), privacy: .public)"
                )
                self.transition(to: .failed(reason: "recv_failed"))
                self.currentTransport = nil
            }
        }
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}
