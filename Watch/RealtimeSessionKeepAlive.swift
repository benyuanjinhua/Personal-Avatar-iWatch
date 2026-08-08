import Foundation
import WatchConnectivity
import os

/// ESS-509: Watch-side WCSession health monitor for realtime streaming.
///
/// During active realtime downlink streaming, the Watch depends on
/// `WCSession.sendMessageData` for low-latency PCM chunk delivery. If the
/// session becomes inactive or unreachable, chunks are silently dropped and
/// the user gets a stuck playback.
///
/// This monitor:
///   - Pings the session every 3 seconds during active streaming to detect
///     reachability loss before the system tears down the session.
///   - Re-activates the session if it becomes inactive.
///   - Emits `onHealthChange` with a `Health` enum so callers can surface
///     warnings or trigger fallback.
///
/// The monitor is lightweight — it only runs while a stream is active.
/// Outside of streaming, it consumes zero resources.
@MainActor
final class RealtimeSessionKeepAlive {
    private static let logger = Logger(
        subsystem: "beer.workspace.wristagent",
        category: "SessionKeepAlive"
    )

    enum Health: Equatable {
        case healthy
        case unreachable
        case inactive
        case unknown

        var isUsable: Bool { self == .healthy }
    }

    /// Monitored session — typically `WCSession.default`.
    private let session: WCSession
    /// How often to check reachability during active streaming.
    private let pingInterval: TimeInterval
    /// Current health snapshot.
    private(set) var health: Health = .unknown

    /// Emitted on every health state change.
    var onHealthChange: ((Health) -> Void)?

    private var pingTimer: Timer?

    init(session: WCSession = .default, pingInterval: TimeInterval = 3.0) {
        self.session = session
        self.pingInterval = pingInterval
    }

    // MARK: - Start / Stop

    /// Start monitoring. Call when a realtime stream begins.
    func start() {
        guard pingTimer == nil else { return }
        updateHealth()
        pingTimer = Timer.scheduledTimer(
            withTimeInterval: pingInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.onPing() }
        }
        Self.logger.info("session keepalive started")
    }

    /// Stop monitoring. Call when streaming ends.
    func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        Self.logger.info("session keepalive stopped")
    }

    // MARK: - Ping

    private func onPing() {
        let previous = health
        updateHealth()
        if health != previous {
            onHealthChange?(health)
        }
        // If session is inactive, attempt reactivation
        if case .inactive = health {
            Self.logger.notice("session keepalive: reactivating inactive session")
            session.activate()
        }
    }

    private func updateHealth() {
        let state = session.activationState
        switch state {
        case .activated:
            health = session.isReachable ? .healthy : .unreachable
        case .inactive, .notActivated:
            health = .inactive
        @unknown default:
            health = .unknown
        }
    }
}
