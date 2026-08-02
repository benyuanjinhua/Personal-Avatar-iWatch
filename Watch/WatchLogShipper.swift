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
    private static let inlineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

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

    /// ESS-137：单行 JSONL 直投（sendMessage）。仅用于 `selfcheck_finished`
    /// 这类必须秒到 bridge 的取证行——transferFile 走系统托管队列，本仓库
    /// `chunk_transfer_failed` 是常见故障（2026-08-02 事故 log 里 37 次），
    /// 只走 transferFile 会出现「表上显示 S2 fail、bridge 侧却 ERR_NO_SELFCHECK」
    /// 的双盲态。可达时秒到；不可达时静默返回，transferFile 通道自然兜底。
    /// 不重试、不重复投，chunk_id 幂等由 bridge 侧完成。
    func shipInline(entry: ClientLogEntry) {
        guard let payload = try? Self.inlineEncoder.encode(entry) else {
            WatchLog.error("watchlog", "inline_ship_encode_failed", detail: entry.event)
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            WatchLog.info(
                "watchlog", "inline_ship_skipped",
                detail: "event=\(entry.event) reachable=\(session.isReachable) "
                    + "state=\(session.activationState.rawValue)"
            )
            return
        }
        session.sendMessage(
            [WatchClientLogMessage.directLineKey: payload],
            replyHandler: nil,
            errorHandler: { error in
                Task { @MainActor in
                    WatchLog.error(
                        "watchlog", "inline_ship_failed",
                        detail: "event=\(entry.event)", error: error
                    )
                }
            }
        )
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
