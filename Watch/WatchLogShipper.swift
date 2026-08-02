import Foundation
import WatchConnectivity

/// 日志回传（ESS-42）：把 ClientLogStore 的 JSONL chunk 经 transferFile 批量
/// 送往 iPhone（系统托管队列，离线不丢），iPhone Relay 再上送 Bridge 落
/// bridge.log。触发时机：WCSession 激活完成、进前台/后台、回合终态、
/// 欢迎语路径走完——通道不可用时 chunk 留在本地，下次触发重试。
@MainActor
final class WatchLogShipper {
    static let shared = WatchLogShipper()

    private let store: ClientLogStore

    init(store: ClientLogStore = WatchLog.store) {
        self.store = store
    }

    func ship(reason: String) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            WatchLog.info("watchlog", "ship_skipped", detail: "reason=\(reason) session_not_activated")
            return
        }
        let chunks = store.rotateForShipment()
        guard !chunks.isEmpty else { return }
        // 在途的 chunk 不重复入队；transferFile 失败的下次触发自然重试。
        let inFlight = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        for url in chunks where !inFlight.contains(url.lastPathComponent) {
            session.transferFile(url, metadata: [WatchClientLogMessage.fileKey: url.lastPathComponent])
        }
    }

    /// WCSession didFinish 回执：成功即删本地副本；失败保留待重试。
    func handleTransferFinished(fileName: String, error: Error?) {
        if let error {
            WatchLog.error("watchlog", "chunk_transfer_failed", detail: fileName, error: error)
            return
        }
        store.removeChunk(named: fileName)
    }

    /// ESS-137：关键日志（当前只有 `selfcheck_finished`）走 sendMessage +
    /// transferUserInfo 双通道旁路直投，绕开正在失败的 transferFile 队列。
    /// - `chunkId` 与主路径共用幂等窗，重复送达 Bridge 去重（`selfcheck-<uuid>.jsonl`）；
    /// - `jsonl` 是 `ClientLogEntry.jsonlLine()` 的字节，与主路径逐字节等价；
    /// - sendMessage 可达即刻送达（约 100–300 ms 到 Bridge），失败静默；
    /// - transferUserInfo 是系统托管持久队列，reachable 变化后自动补投；
    /// - 两路都失败时留 `selfcheck_fastpath_unavailable` 取证，主路径 chunk
    ///   一旦成功也会覆盖同 chunk_id，不会造成 bridge.log 双写。
    func shipSelfCheckSummary(payload: SelfCheckSummaryPayload) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            WatchLog.info(
                "watchlog", "selfcheck_fastpath_unavailable",
                detail: "chunk=\(payload.chunkId) reason=session_not_activated"
            )
            return
        }
        guard let data = try? payload.encoded() else {
            WatchLog.error(
                "watchlog", "selfcheck_fastpath_encode_failed",
                detail: "chunk=\(payload.chunkId)", code: "ERR_ENCODE"
            )
            return
        }
        let message = [WatchClientLogMessage.selfCheckSummaryKey: data]
        // transferUserInfo 无论 reachable 与否都进系统托管队列，是可靠性兜底。
        session.transferUserInfo(message)
        WatchLog.info(
            "watchlog", "selfcheck_fastpath_transfer_queued",
            detail: "chunk=\(payload.chunkId) bytes=\(data.count)"
        )
        // 可达时再走一次 sendMessage，把送达时延压到秒级——不可达时立即失败，
        // 靠 transferUserInfo 兜底，errorHandler 里不再补动作，避免和上面重复。
        guard session.isReachable else {
            WatchLog.info(
                "watchlog", "selfcheck_fastpath_send_skipped",
                detail: "chunk=\(payload.chunkId) reason=not_reachable"
            )
            return
        }
        let chunkId = payload.chunkId
        session.sendMessage(
            message,
            replyHandler: { _ in
                WatchLog.info(
                    "watchlog", "selfcheck_fastpath_delivered",
                    detail: "chunk=\(chunkId) via=send_message"
                )
            },
            errorHandler: { error in
                WatchLog.error(
                    "watchlog", "selfcheck_fastpath_send_failed",
                    detail: "chunk=\(chunkId)", error: error
                )
            }
        )
    }
}
