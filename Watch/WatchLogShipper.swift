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
    /// ESS-137：selfcheck_finished 快速旁路的进程内 pending 集合——
    /// 首次入队时 sendMessage 若因 reachable=false 跳过，reachable 变 true
    /// 时由 WatchSettingsStore.sessionReachabilityDidChange 触发本类的
    /// handleReachabilityChange 补一次 sendMessage。sendMessage 成功回执
    /// 里清除条目，避免二次重发。进程重启后 pending 丢失也没关系——
    /// transferUserInfo 是系统托管持久队列，兜底送达。
    private var pendingFastPath: [String: SelfCheckSummaryPayload] = [:]

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
    /// - **交付契约**：一旦 WCSession `isReachable == true`，5 秒内 iPhone
    ///   端接到本消息并入 `ClientLogUplink` 队列（sendMessage 是即时通道）。
    ///   reachable=false 时 sendMessage 会跳过，但 payload 进本类 pending
    ///   集合，reachable 变 true 时立即补发；同时 transferUserInfo 已入
    ///   系统托管持久队列——两者独立生效，任一到达即算送达。
    /// - **主路径 vs 旁路的 chunk 关系**：主路径 chunk 前缀 `watchlog-*`、
    ///   旁路前缀 `selfcheck-*`，Bridge 的 `/v1/client-logs` 按 `chunk_id`
    ///   幂等，两者不会互相去重。若两条都到 Bridge，`bridge.log` 会有两条
    ///   逐字节等价的 `selfcheck_finished` 行；`watch-smoke.mjs`
    ///   `latestSelfCheckFinished` 按 Bridge 落盘 ts 取最新，业务上不受影响。
    /// - `jsonl` 是 `ClientLogEntry.jsonlLine()` 的字节，与主路径逐字节等价——
    ///   排查者拉任一份都能对齐同一结论。
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
        // transferUserInfo 无论 reachable 与否都进系统托管持久队列，是兜底通道。
        session.transferUserInfo(message)
        WatchLog.info(
            "watchlog", "selfcheck_fastpath_transfer_queued",
            detail: "chunk=\(payload.chunkId) bytes=\(data.count)"
        )
        // 入 pending：reachable 变 true 时 handleReachabilityChange 会补 sendMessage。
        pendingFastPath[payload.chunkId] = payload
        attemptFastPathSend(payload: payload, trigger: "immediate")
    }

    /// WatchSettingsStore.sessionReachabilityDidChange 触发——reachable 变 true
    /// 时补发 pending 的 selfcheck 快速旁路 sendMessage，把不可达期间只入
    /// transferUserInfo 的载荷升级到即时通道，5 秒内送达 iPhone。
    /// reachable=false 无需动作（不能主动收回已投递的 transferUserInfo）。
    func handleReachabilityChange(isReachable: Bool) {
        guard isReachable else { return }
        let pending = pendingFastPath
        guard !pending.isEmpty else { return }
        WatchLog.info(
            "watchlog", "selfcheck_fastpath_reachability_flush",
            detail: "pending=\(pending.count)"
        )
        for (_, payload) in pending {
            attemptFastPathSend(payload: payload, trigger: "reachability_change")
        }
    }

    private func attemptFastPathSend(payload: SelfCheckSummaryPayload, trigger: String) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isReachable else {
            WatchLog.info(
                "watchlog", "selfcheck_fastpath_send_skipped",
                detail: "chunk=\(payload.chunkId) reason=not_reachable trigger=\(trigger)"
            )
            return
        }
        guard let data = try? payload.encoded() else { return }
        let message = [WatchClientLogMessage.selfCheckSummaryKey: data]
        let chunkId = payload.chunkId
        session.sendMessage(
            message,
            replyHandler: { _ in
                // reply 回调在 WC delegate 队列——用 Task hop 回 MainActor 清理 pending。
                Task { @MainActor in
                    WatchLog.info(
                        "watchlog", "selfcheck_fastpath_delivered",
                        detail: "chunk=\(chunkId) via=send_message trigger=\(trigger)"
                    )
                    WatchLogShipper.shared.pendingFastPath.removeValue(forKey: chunkId)
                }
            },
            errorHandler: { error in
                WatchLog.error(
                    "watchlog", "selfcheck_fastpath_send_failed",
                    detail: "chunk=\(chunkId) trigger=\(trigger)", error: error
                )
                // 失败不清 pending——下次 reachability 事件仍会重试。
            }
        )
    }
}
