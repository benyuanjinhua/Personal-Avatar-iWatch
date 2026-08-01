import Foundation
import os

/// Watch 日志 chunk 上送 Bridge（ESS-42）：Watch transferFile 落地后进本目录
/// 排队，逐个 POST /v1/client-logs（HMAC 签名，chunk_id 幂等）。Mac 不可达时
/// 指数退避重试、App 重启后续传；稳定 4xx 视为毒 chunk 丢弃。日志内容只有
/// 元数据（Watch 侧保证不落音频/凭据），明文暂存可接受。
@MainActor
final class ClientLogUplink {
    /// 本地积压上限：超过即丢最旧（日志是取证辅助，绝不为它撑爆手机）。
    private static let maxQueuedChunks = 32

    private static let logger = Logger(subsystem: "com.benyuan.wristagent.phone", category: "ClientLogUplink")

    private let directory: URL
    private let fileManager = FileManager.default
    private let makeClient: () -> RelayClient?
    private var drainTask: Task<Void, Never>?
    private var attempt = 0

    init(directory: URL, makeClient: @escaping () -> RelayClient?) {
        self.directory = directory
        self.makeClient = makeClient
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Watch chunk 落地入队；同名 chunk（重传）覆盖即幂等。
    func enqueue(chunkId: String, data: Data) {
        // chunk id 来自文件名，做一次白名单过滤防路径注入。
        let safeId = chunkId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        guard !safeId.isEmpty, (try? data.write(to: url(for: safeId), options: .atomic)) != nil else {
            Self.logger.error("chunk 落盘失败：\(chunkId, privacy: .public)")
            return
        }
        enforceQueueLimit()
        scheduleDrain(after: 0)
    }

    /// 启动 / 配对成功后调用：续传上次没送完的 chunk。
    func start() {
        scheduleDrain(after: 0)
    }

    private func url(for chunkId: String) -> URL {
        directory.appendingPathComponent(chunkId)
    }

    private func queuedChunkIds() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func enforceQueueLimit() {
        let queued = queuedChunkIds()
        guard queued.count > Self.maxQueuedChunks else { return }
        for chunkId in queued.prefix(queued.count - Self.maxQueuedChunks) {
            try? fileManager.removeItem(at: url(for: chunkId))
        }
        Self.logger.error("日志积压超限，丢弃最旧 \(queued.count - Self.maxQueuedChunks) 个 chunk")
    }

    private func scheduleDrain(after delay: TimeInterval) {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.drain()
            self?.drainTask = nil
        }
    }

    private func drain() async {
        guard let client = makeClient() else { return } // 未配对：chunk 留在队列
        for chunkId in queuedChunkIds() {
            guard !Task.isCancelled else { return }
            guard let data = try? Data(contentsOf: url(for: chunkId)),
                  let jsonl = String(data: data, encoding: .utf8) else {
                try? fileManager.removeItem(at: url(for: chunkId))
                continue
            }
            do {
                try await client.uploadClientLogs(chunkId: chunkId, jsonl: jsonl)
                try? fileManager.removeItem(at: url(for: chunkId))
                attempt = 0
            } catch let error as RelayUploadError where !error.isRetryable {
                Self.logger.error("Bridge 拒绝日志 chunk \(chunkId, privacy: .public)：\(error.stableCode, privacy: .public)")
                try? fileManager.removeItem(at: url(for: chunkId))
            } catch {
                attempt += 1
                let delay = RetryBackoff.outboxDefault.delay(forAttempt: attempt)
                Self.logger.info("日志上送失败（第 \(self.attempt) 次），\(Int(delay)) 秒后重试")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self?.scheduleDrain(after: 0)
                }
                return
            }
        }
    }
}
