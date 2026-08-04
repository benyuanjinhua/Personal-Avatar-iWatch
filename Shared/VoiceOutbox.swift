import CryptoKit
import Foundation

/// iPhone → Mac 上送队列的重试退避策略：指数增长 + 抖动，封顶后保持。
struct RetryBackoff {
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    /// 抖动比例（0.2 = ±20%），避免恢复瞬间的同步重试风暴。
    let jitterRatio: Double

    static let outboxDefault = RetryBackoff(baseDelay: 2, maxDelay: 300, jitterRatio: 0.2)

    /// attempt 从 1 开始计数；random 可注入以便测试。
    func delay(
        forAttempt attempt: Int,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let exponent = max(0, min(attempt - 1, 16))
        let raw = min(baseDelay * pow(2, Double(exponent)), maxDelay)
        guard jitterRatio > 0 else { return raw }
        return raw * (1 + random(-jitterRatio...jitterRatio))
    }
}

/// outbox 音频加密密钥来源。iPhone 实现存 Keychain；测试注入固定密钥。
protocol VoiceOutboxKeyProviding {
    func outboxKey() throws -> SymmetricKey
}

enum VoiceOutboxState: String, Codable {
    /// 等待上送 Mac（Mac/Tailscale 可能不可达），按 nextAttemptAt 退避重试。
    case queued
    /// Bridge 已受理（202）。受理即删除本地音频，条目保留用于幂等与历史。
    case delivered
    /// 有界重试耗尽或缓存损坏后的吸收终态；保留索引以维持 request_id 幂等。
    case failed
}

struct VoiceOutboxEntry: Codable, Equatable, Identifiable {
    let requestId: String
    let envelope: VoiceRequestEnvelope
    var state: VoiceOutboxState
    var attemptCount: Int
    var nextAttemptAt: Date
    let enqueuedAt: Date
    var deliveredAt: Date?
    var failureCode: String?

    var id: String { requestId }
}

enum VoiceOutboxError: Error, Equatable, CustomStringConvertible {
    /// 同一 request_id 携带了不同音频摘要：拒绝覆盖，保持首次入队内容。
    case requestIdConflict(requestId: String)
    case entryNotFound(requestId: String)
    case audioUnavailable(requestId: String)
    case storageFailure(String)

    var description: String {
        switch self {
        case .requestIdConflict(let id): return "request_id \(id) 已入队但音频摘要不同"
        case .entryNotFound(let id): return "outbox 中不存在 \(id)"
        case .audioUnavailable(let id): return "\(id) 的加密音频缺失或无法解密"
        case .storageFailure(let reason): return "outbox 写入失败：\(reason)"
        }
    }
}

/// iPhone 端加密 Outbox（ESS-28）：
/// - `request_id` 唯一，重复入队幂等返回既有条目，重试永远复用同一 request_id；
/// - 音频以 AES-GCM 加密落盘（密钥在 Keychain，不随文件存储），索引只含元数据；
/// - Mac/Tailscale 不可达时按指数退避排队，进程重启后从磁盘恢复继续重试；
/// - 成功交付立即删除音频密文；超过保留期的条目连同音频一并清除（§8）。
/// 纯 Foundation + CryptoKit 实现，可在 macOS 上单元测试。
final class VoiceOutbox {
    enum EnqueueResult: Equatable {
        case enqueued(VoiceOutboxEntry)
        case duplicate(VoiceOutboxEntry)
    }

    private(set) var entries: [VoiceOutboxEntry]

    private let directory: URL
    private let indexURL: URL
    private let keyProvider: VoiceOutboxKeyProviding
    private let backoff: RetryBackoff
    private let retention: TimeInterval
    private let now: () -> Date
    private let random: (ClosedRange<Double>) -> Double
    private let fileManager = FileManager.default

    init(
        directory: URL,
        keyProvider: VoiceOutboxKeyProviding,
        backoff: RetryBackoff = .outboxDefault,
        retention: TimeInterval = 24 * 3600,
        now: @escaping () -> Date = Date.init,
        random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) throws {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.keyProvider = keyProvider
        self.backoff = backoff
        self.retention = retention
        self.now = now
        self.random = random
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if
            let data = try? Data(contentsOf: indexURL),
            let saved = try? JSONDecoder().decode([VoiceOutboxEntry].self, from: data)
        {
            entries = saved
        } else {
            entries = []
        }
    }

    // MARK: - 入队 / 读取

    func enqueue(envelope: VoiceRequestEnvelope, audioData: Data) throws -> EnqueueResult {
        if let existing = entries.first(where: { $0.requestId == envelope.requestId }) {
            guard existing.envelope.audio.sha256.lowercased() == envelope.audio.sha256.lowercased() else {
                throw VoiceOutboxError.requestIdConflict(requestId: envelope.requestId)
            }
            return .duplicate(existing)
        }

        let key = try keyProvider.outboxKey()
        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(audioData, using: key).combined else {
                throw VoiceOutboxError.storageFailure("AES-GCM 未产生 combined 数据")
            }
            sealed = combined
            try sealed.write(to: audioURL(for: envelope.requestId), options: .atomic)
        } catch let error as VoiceOutboxError {
            throw error
        } catch {
            throw VoiceOutboxError.storageFailure(error.localizedDescription)
        }

        let entry = VoiceOutboxEntry(
            requestId: envelope.requestId,
            envelope: envelope,
            state: .queued,
            attemptCount: 0,
            nextAttemptAt: now(),
            enqueuedAt: now(),
            deliveredAt: nil,
            failureCode: nil
        )
        entries.append(entry)
        persistIndex()
        return .enqueued(entry)
    }

    func entry(for requestId: String) -> VoiceOutboxEntry? {
        entries.first { $0.requestId == requestId }
    }

    /// 到期可上送的条目，按入队顺序（FIFO）返回。
    func dueEntries(at date: Date? = nil) -> [VoiceOutboxEntry] {
        let reference = date ?? now()
        return entries.filter { $0.state == .queued && $0.nextAttemptAt <= reference }
    }

    /// 最近一个未到期条目的重试时间，用于外层调度下一次 drain。
    func earliestNextAttempt() -> Date? {
        entries.filter { $0.state == .queued }.map(\.nextAttemptAt).min()
    }

    func audioData(for requestId: String) throws -> Data {
        guard entry(for: requestId) != nil else {
            throw VoiceOutboxError.entryNotFound(requestId: requestId)
        }
        guard let sealed = try? Data(contentsOf: audioURL(for: requestId)) else {
            throw VoiceOutboxError.audioUnavailable(requestId: requestId)
        }
        do {
            let key = try keyProvider.outboxKey()
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
        } catch {
            throw VoiceOutboxError.audioUnavailable(requestId: requestId)
        }
    }

    // MARK: - 状态迁移

    /// Bridge 202 受理：删除本地音频密文，条目转 delivered 保留（幂等/历史）。
    func markDelivered(requestId: String) {
        mutate(requestId: requestId) { entry in
            entry.state = .delivered
            entry.deliveredAt = now()
        }
        try? fileManager.removeItem(at: audioURL(for: requestId))
    }

    func markTerminalFailed(requestId: String, code: String) {
        mutate(requestId: requestId) { entry in
            guard entry.state == .queued else { return }
            entry.state = .failed
            entry.failureCode = code
            entry.deliveredAt = now()
        }
        try? fileManager.removeItem(at: audioURL(for: requestId))
    }

    /// 上送失败（网络/Mac 不可达）：退避后重试，返回下一次尝试时间。
    @discardableResult
    func markFailed(requestId: String) -> Date? {
        var next: Date?
        mutate(requestId: requestId) { entry in
            entry.attemptCount += 1
            let delay = backoff.delay(forAttempt: entry.attemptCount, random: random)
            entry.nextAttemptAt = now().addingTimeInterval(delay)
            next = entry.nextAttemptAt
        }
        return next
    }

    /// 毒消息（Bridge 稳定 4xx 拒绝）：不再重试，删除条目与音频。
    func remove(requestId: String) {
        entries.removeAll { $0.requestId == requestId }
        try? fileManager.removeItem(at: audioURL(for: requestId))
        persistIndex()
    }

    /// 清理：已交付条目超保留期移除；排队条目超保留期视为过期放弃（音频一并删除）。
    /// 返回被过期放弃的排队条目（调用方可借此通知 Watch 失败）。
    @discardableResult
    func purgeExpired() -> [VoiceOutboxEntry] {
        let cutoff = now().addingTimeInterval(-retention)
        let expiredQueued = entries.filter { $0.state == .queued && $0.enqueuedAt < cutoff }
        let removable = entries.filter { entry in
            switch entry.state {
            case .queued: return entry.enqueuedAt < cutoff
            case .delivered, .failed: return (entry.deliveredAt ?? entry.enqueuedAt) < cutoff
            }
        }
        guard !removable.isEmpty else { return [] }
        for entry in removable {
            try? fileManager.removeItem(at: audioURL(for: entry.requestId))
        }
        let removedIds = Set(removable.map(\.requestId))
        entries.removeAll { removedIds.contains($0.requestId) }
        persistIndex()
        return expiredQueued
    }

    // MARK: - 私有

    private func mutate(requestId: String, _ body: (inout VoiceOutboxEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.requestId == requestId }) else { return }
        body(&entries[index])
        persistIndex()
    }

    private func audioURL(for requestId: String) -> URL {
        directory.appendingPathComponent("\(requestId).enc")
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
