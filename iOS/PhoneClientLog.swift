import Foundation
import os

/// ESS-525 iPhone-side installer for `PhoneAgentClientLog`.
///
/// Records structured entries into a per-app `ClientLogStore` (same wire
/// shape as Watch entries — `Shared/ClientLog.swift`), then hands each
/// rotated JSONL chunk to `ClientLogUplink` which POSTs it to Bridge
/// `/v1/client-logs`. Bridge writes one `watch_client_log` line per JSONL
/// row keyed by `chunk_id` — greppable in `bridge.log` by `request_id`.
///
/// The chunk id prefix (`phonelog-`) keeps iPhone chunks distinct from
/// `watchlog-*` (Watch main path) and `selfcheck-*` (Watch fast path) so
/// Bridge's per-chunk idempotency window never collides.
///
/// Chunks rotate on a size or time threshold — small enough that even a
/// single-turn hang produces evidence on `bridge.log` within a few seconds.
@MainActor
final class PhoneClientLog {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "PhoneClientLog"
    )

    /// Rotate on either 32 KiB (well below the 2 MiB store default so
    /// small-turn evidence gets shipped promptly) or every 3 s of activity.
    private static let rotateBytes = 32 * 1024
    private static let rotateInterval: TimeInterval = 3.0

    private let store: ClientLogStore
    private let uplink: () -> ClientLogUplink?
    private var byteBudget: Int = 0
    private var rotateTask: Task<Void, Never>?

    /// The concrete Sink handed to `PhoneAgentClientLog.install`. Marked
    /// `@Sendable` because `PhoneAgentClientLog.Sink` requires it — the
    /// closure hops back onto `@MainActor` before touching store state.
    private lazy var sink: PhoneAgentClientLog.Sink = { [weak self] entry in
        // Serialize on MainActor so `byteBudget` / `rotateTask` mutations
        // stay race-free with respect to iOS UI callbacks.
        Task { @MainActor [weak self] in
            self?.appendAndMaybeShip(entry)
        }
    }

    init(directory: URL, uplink: @escaping () -> ClientLogUplink?) {
        // Small pending window: iPhone chunks are cheap to produce; if the
        // uplink is down for a while we prefer dropping the oldest chunks
        // rather than ballooning disk.
        self.store = ClientLogStore(
            directory: directory,
            maxFileBytes: 128 * 1024,
            maxPendingChunks: 4
        )
        self.uplink = uplink
    }

    /// Install the sink and kick a first drain so anything left over from a
    /// prior process launch gets shipped promptly.
    func start() {
        PhoneAgentClientLog.install(sink)
        shipRotatedChunks()
    }

    /// Optional teardown so tests can uninstall the global sink between runs.
    func stop() {
        PhoneAgentClientLog.install(nil)
        rotateTask?.cancel()
        rotateTask = nil
    }

    // MARK: - Ship path

    private func appendAndMaybeShip(_ entry: PhoneAgentClientLog.Entry) {
        let clientEntry = ClientLogEntry(
            requestId: entry.requestId,
            module: entry.module,
            event: entry.event,
            detail: composeDetail(entry: entry),
            error: entry.errorCode.map {
                ClientLogEntry.ErrorInfo(code: $0, description: entry.detail ?? entry.event)
            }
        )
        store.append(clientEntry)

        // Best-effort estimate — the exact JSONL size arrives after encode,
        // so we approximate here to decide when to rotate. Missing by a
        // hundred bytes only shifts the rotate boundary marginally.
        byteBudget += approxEncodedSize(of: clientEntry)
        if byteBudget >= Self.rotateBytes {
            byteBudget = 0
            shipRotatedChunks()
            return
        }
        scheduleTimedRotate()
    }

    private func scheduleTimedRotate() {
        guard rotateTask == nil else { return }
        rotateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.rotateInterval * 1_000_000_000))
            await MainActor.run { [weak self] in
                self?.rotateTask = nil
                self?.byteBudget = 0
                self?.shipRotatedChunks()
            }
        }
    }

    private func shipRotatedChunks() {
        guard let uplink = uplink() else {
            // No uplink yet (unpaired). Chunks stay on disk until pairing
            // succeeds; `PhoneClientLog.start` after pairing will drain.
            _ = store.rotateForShipment()
            return
        }
        let chunks = store.rotateForShipment()
        for url in chunks {
            let name = url.lastPathComponent
            let chunkId = phoneChunkId(originalName: name)
            guard let data = try? Data(contentsOf: url) else { continue }
            uplink.enqueue(chunkId: chunkId, data: data)
            // The uplink now owns the copy; remove ours so the store's
            // `maxPendingChunks` cap doesn't fire on already-shipped files.
            store.removeChunk(named: name)
        }
    }

    /// Bridge's `POST /v1/client-logs` requires `chunk_id == x-request-id`
    /// signed by the caller. `ClientLogUplink` signs the chunk request with
    /// the chunk id as request id, so any collision with a Watch-side chunk
    /// id would land two payloads under the same id and lose one. Prefix
    /// keeps them disjoint; the underlying UUID stays.
    private func phoneChunkId(originalName: String) -> String {
        // Watch chunk names are `watchlog-<uuid>.jsonl`; strip prefix/suffix
        // and reprefix with `phonelog-`.
        let stripped = originalName
            .replacingOccurrences(of: "watchlog-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        return "phonelog-\(stripped)"
    }

    private func composeDetail(entry: PhoneAgentClientLog.Entry) -> String? {
        // Session id doesn't have a dedicated column in `ClientLogEntry`,
        // fold it into `detail` so bridge.log lines still carry it.
        switch (entry.sessionId, entry.detail) {
        case (nil, let d): return d
        case (let sid?, nil): return "session_id=\(sid)"
        case (let sid?, let d?): return "session_id=\(sid) \(d)"
        }
    }

    private func approxEncodedSize(of entry: ClientLogEntry) -> Int {
        // Rough estimate; the encoder never blows this up by more than ~40 %.
        // Broken into intermediate lets so Swift's expression type checker
        // (Xcode 26 in CI) doesn't time out on a single long chain of
        // optional utf8.count summands (ESS-525 CI regression).
        var total = 64
        total += entry.module.utf8.count
        total += entry.event.utf8.count
        total += entry.requestId?.utf8.count ?? 0
        total += entry.detail?.utf8.count ?? 0
        let errorInfo = entry.error
        total += errorInfo?.description.utf8.count ?? 0
        total += errorInfo?.code?.utf8.count ?? 0
        return total
    }
}
