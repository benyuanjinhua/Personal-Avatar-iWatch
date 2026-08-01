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
}
