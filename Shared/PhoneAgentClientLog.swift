import Foundation

/// ESS-525 iPhone-side realtime downlink evidence sink.
///
/// The Watch has `WatchLog` shipping structured entries into `bridge.log` via
/// `POST /v1/client-logs`. Before ESS-525 the iPhone had no equivalent, so a
/// downlink hang on the phone left `bridge.log` silent: server-side saw the
/// `audio.delta`/`audio.done` go out, no receipt ever came back, and the
/// investigation had no `request_id`-anchored client evidence.
///
/// `PhoneAgentClientLog` is the shared handle. `Shared/` code (the WSS
/// transport, the session state machine) writes through this handle; iOS
/// installs a concrete sink (`PhoneClientLogSink` → `ClientLogStore` +
/// `ClientLogUplink`) at app launch. Tests install an in-memory recorder.
///
/// When no sink is installed the calls are cheap no-ops — Shared code must
/// stay callable from `swift test` targets that don't spin up the iOS relay.
public enum PhoneAgentClientLog {
    /// Structured entry — mirrors `ClientLogEntry` shape but stays lightweight
    /// so the recorder can compare fields without pulling encoding infra.
    public struct Entry: Sendable, Equatable {
        public let module: String
        public let event: String
        public let requestId: String?
        public let sessionId: String?
        public let detail: String?
        public let errorCode: String?

        public init(
            module: String,
            event: String,
            requestId: String? = nil,
            sessionId: String? = nil,
            detail: String? = nil,
            errorCode: String? = nil
        ) {
            self.module = module
            self.event = event
            self.requestId = requestId
            self.sessionId = sessionId
            self.detail = detail
            self.errorCode = errorCode
        }
    }

    /// Sink implementation — installed by iOS/tests. `@Sendable` so the
    /// transport can invoke it from Task-boundary callbacks without warnings.
    public typealias Sink = @Sendable (Entry) -> Void

    // The transport code lives on `@MainActor` so a plain static var with a
    // per-actor accessor is sufficient. The sink itself is Sendable so
    // background invocations remain safe if a caller later reaches this from
    // a different actor.
    nonisolated(unsafe) private static var sinkStorage: Sink?
    private static let sinkLock = NSLock()

    public static func install(_ sink: Sink?) {
        sinkLock.lock(); defer { sinkLock.unlock() }
        sinkStorage = sink
    }

    public static func record(_ entry: Entry) {
        sinkLock.lock()
        let sink = sinkStorage
        sinkLock.unlock()
        sink?(entry)
    }

    /// Convenience helpers keep call sites readable.
    public static func info(
        module: String, event: String,
        requestId: String? = nil, sessionId: String? = nil,
        detail: String? = nil
    ) {
        record(Entry(module: module, event: event, requestId: requestId,
                     sessionId: sessionId, detail: detail))
    }

    public static func error(
        module: String, event: String,
        requestId: String? = nil, sessionId: String? = nil,
        detail: String? = nil, code: String? = nil
    ) {
        record(Entry(module: module, event: event, requestId: requestId,
                     sessionId: sessionId, detail: detail, errorCode: code))
    }
}
