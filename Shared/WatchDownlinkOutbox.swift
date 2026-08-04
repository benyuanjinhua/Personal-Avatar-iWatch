import CryptoKit
import Foundation

/// 下行（iPhone → Watch）投递单元的类别。
/// 与 WCSession 的传输通道一一对应：前三者走 userInfo/message，speech 走 transferFile。
enum WatchDownlinkKind: String, Codable, CaseIterable {
    /// `RelayStatusUpdate`：iPhone 前台状态行文案。
    case relayStatus
    /// ESS-59：真实任务步骤，仅文字，绝不携带/触发语音文件。
    case progress
    /// `VoiceRelayResultPayload`：结果短文本。
    case result
    /// `VoiceStatusEnvelope`：Watch 时间线入账单位（ESS-29）。
    case voiceStatus
    /// 结果语音文件（ESS-38 下行音频）。
    case speech
    /// ESS-184/207 下行链路探针文件；语义同 speech（transferFile 走音频），
    /// 但 Watch 侧走探针分支——不入 vault、不入 journal、播完发 probe_ack。
    case probe
}

enum WatchDownlinkState: String, Codable {
    /// 等待投递：WCSession 未激活 / 未安装 Watch App / 上一次投递失败退避中。
    case queued
    /// 已交给 WCSession，等待系统回执（didFinish）。进程重启后视为未交付，回到 queued。
    case inFlight
    /// 系统已确认交付到 Watch。载荷与暂存音频即刻删除。
    case delivered
}

struct WatchDownlinkItem: Codable, Equatable, Identifiable {
    let id: String
    /// 观测主键：任何一条下行都必须能回溯到发起它的 Watch 请求。
    let requestId: String
    let kind: WatchDownlinkKind
    /// WCSession 字典键 / transferFile metadata 键。
    let messageKey: String
    /// 载荷摘要，用于同类幂等去重（快照重放不会堆积重复条目）。
    let payloadSha256: String
    /// speech 专用：暂存音频在 outbox 目录内的文件名（系统会删除调用方的临时文件）。
    let stagedFileName: String?
    var state: WatchDownlinkState
    var attemptCount: Int
    var nextAttemptAt: Date
    let enqueuedAt: Date
    var deliveredAt: Date?
    var lastError: String?
}

/// 结构化观测事件（ESS-21 验收要求「request_id 观测」）。
/// 由调用方接到 os_log / 状态行；outbox 自身不假设日志实现。
enum WatchDownlinkLogEvent: Equatable {
    case enqueued(requestId: String, kind: WatchDownlinkKind, itemId: String)
    case duplicate(requestId: String, kind: WatchDownlinkKind, itemId: String)
    /// 会话不可用，条目留在队列里等待激活/可达后重放——**不是丢弃**。
    case deferred(requestId: String, kind: WatchDownlinkKind, itemId: String, reason: String)
    case attempted(requestId: String, kind: WatchDownlinkKind, itemId: String, attempt: Int)
    case delivered(requestId: String, kind: WatchDownlinkKind, itemId: String, attempt: Int)
    case failed(requestId: String, kind: WatchDownlinkKind, itemId: String, attempt: Int, reason: String)
    /// 超过保留期仍未送达，放弃并留痕（不静默消失）。
    case expired(requestId: String, kind: WatchDownlinkKind, itemId: String)
    /// 状态迁移后索引写盘失败：内存与磁盘暂时不一致，靠下一次成功写盘收敛。
    /// 入队路径不会走到这里——入队落盘失败直接回滚并抛错，不会宣称成功。
    case persistFailed(operation: String, reason: String)
}

enum WatchDownlinkError: Error, Equatable, CustomStringConvertible {
    case payloadUnavailable(itemId: String)
    case storageFailure(String)

    var description: String {
        switch self {
        case .payloadUnavailable(let id): return "下行条目 \(id) 的载荷缺失"
        case .storageFailure(let reason): return "下行队列写入失败：\(reason)"
        }
    }
}

/// iPhone → Watch 下行持久化队列（ESS-21 B1）。
///
/// 修复的问题：`PhoneConnectivity` 原先在 `WCSession.activationState != .activated` 时
/// 直接 `return`，把状态信封与结果语音**静默丢弃**且无任何留痕——覆盖安装后 iPhone 锁屏、
/// Relay App 未启动时，Mac 侧显示「已推送」，Watch 永远收不到，且没有任何可观测证据。
///
/// 本队列的契约：
/// - 入队即落盘，`request_id` 全程携带；进程重启后继续投递；
///   索引落盘失败时回滚内存与载荷并抛错，**不谎报已入队**；
/// - 会话不可用时条目保持 `queued` 并记 `deferred`，绝不丢弃；
/// - 只有拿到 WCSession 的 `didFinish` 回执才转 `delivered`，且**删除载荷永远排在
///   「delivered 已落盘」之后**——磁盘上还写着 `inFlight`/`queued` 时载荷就是重启后
///   唯一的重投材料，先删就等于把这条下行变成永久 `payload-missing`（ESS-43）；
/// - `inFlight` 在重启后回落 `queued`（没有回执就不算送达）；
/// - 失败按指数退避重试，超过保留期才放弃，且以 `expired` 留痕。
///
/// 纯 Foundation + CryptoKit，无 WatchConnectivity 依赖，可在 macOS 上单元测试。
final class WatchDownlinkOutbox {
    enum EnqueueResult: Equatable {
        case enqueued(WatchDownlinkItem)
        /// 同 request_id + 同类别 + 同载荷摘要：复用既有条目，不重复排队。
        /// **保留期内已送达的条目也参与判定**——iPhone 重启后内存去重清零，
        /// Bridge 重放同一 completed 快照时必须靠这里挡住重复播放。
        case duplicate(WatchDownlinkItem)
    }

    private(set) var items: [WatchDownlinkItem]

    private let directory: URL
    private let indexURL: URL
    private let backoff: RetryBackoff
    private let retention: TimeInterval
    private let inFlightTimeout: TimeInterval
    private let now: () -> Date
    private let random: (ClosedRange<Double>) -> Double
    private let makeId: () -> String
    private let log: (WatchDownlinkLogEvent) -> Void
    private let fileManager = FileManager.default

    /// 已拿到系统回执、但 `delivered` 索引尚未成功落盘的条目：载荷与暂存音频必须继续保留。
    /// 只有索引写盘成功后这些文件才允许删除（见 `flushPendingPayloadDiscards`）。
    private var pendingPayloadDiscards: Set<String> = []

    /// 下行退避比上送更激进：Watch 通常只是「App 没打开」，恢复窗口以秒计。
    static let downlinkBackoff = RetryBackoff(baseDelay: 1, maxDelay: 60, jitterRatio: 0.2)

    init(
        directory: URL,
        backoff: RetryBackoff = WatchDownlinkOutbox.downlinkBackoff,
        retention: TimeInterval = 24 * 3600,
        inFlightTimeout: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
        makeId: @escaping () -> String = { UUIDv7.generate().uuidString.lowercased() },
        log: @escaping (WatchDownlinkLogEvent) -> Void = { _ in }
    ) throws {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.backoff = backoff
        self.retention = retention
        self.inFlightTimeout = inFlightTimeout
        self.now = now
        self.random = random
        self.makeId = makeId
        self.log = log
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WatchDownlinkError.storageFailure(error.localizedDescription)
        }
        if
            let data = try? Data(contentsOf: indexURL),
            let saved = try? JSONDecoder().decode([WatchDownlinkItem].self, from: data)
        {
            items = saved
        } else {
            items = []
        }
        // 冷启动：上一次进程交给系统但没等到回执的条目，一律重投。
        recoverInFlight()
    }

    // MARK: - 入队

    /// 短文本/信封类下行。
    @discardableResult
    func enqueue(
        requestId: String,
        kind: WatchDownlinkKind,
        messageKey: String,
        payload: Data
    ) throws -> EnqueueResult {
        try enqueue(
            requestId: requestId, kind: kind, messageKey: messageKey,
            payload: payload, audio: nil, audioFileName: nil
        )
    }

    /// 结果语音下行：音频复制进 outbox 目录持有，调用方的临时文件可随时被系统清掉。
    @discardableResult
    func enqueueSpeech(
        requestId: String,
        messageKey: String,
        envelope: Data,
        audio: Data,
        fileName: String
    ) throws -> EnqueueResult {
        try enqueue(
            requestId: requestId, kind: .speech, messageKey: messageKey,
            payload: envelope, audio: audio, audioFileName: fileName
        )
    }

    /// ESS-184/207 下行探针文件：与 `enqueueSpeech` 传输语义相同（transferFile），
    /// 但用 `kind=.probe` 与独立 messageKey，让 Watch 端能走探针分支且与结果链路
    /// 的去重/内存队列互不干扰（一场探针不会被前一条 speech 的载荷复用挡掉）。
    @discardableResult
    func enqueueProbe(
        requestId: String,
        messageKey: String,
        envelope: Data,
        audio: Data,
        fileName: String
    ) throws -> EnqueueResult {
        try enqueue(
            requestId: requestId, kind: .probe, messageKey: messageKey,
            payload: envelope, audio: audio, audioFileName: fileName
        )
    }

    private func enqueue(
        requestId: String,
        kind: WatchDownlinkKind,
        messageKey: String,
        payload: Data,
        audio: Data?,
        audioFileName: String?
    ) throws -> EnqueueResult {
        // speech/probe 的去重摘要取「信封 + 音频」，避免同一回合换音频却被当成重复。
        var digestInput = semanticPayload(payload, kind: kind)
        if let audio { digestInput.append(contentsOf: SHA256.hash(data: audio)) }
        let sha = RelayWire.sha256Hex(digestInput)

        if
            let existing = items.first(where: {
                $0.requestId == requestId && $0.kind == kind && $0.payloadSha256 == sha
            })
        {
            log(.duplicate(requestId: requestId, kind: kind, itemId: existing.id))
            return .duplicate(existing)
        }

        let id = makeId()
        let stagedName = audioFileName.map { "\(id)__\($0)" }
        do {
            try payload.write(to: payloadURL(for: id), options: .atomic)
            if let audio, let stagedName {
                try audio.write(to: directory.appendingPathComponent(stagedName), options: .atomic)
            }
        } catch {
            discardFiles(id: id, stagedFileName: stagedName)
            throw WatchDownlinkError.storageFailure(error.localizedDescription)
        }

        let item = WatchDownlinkItem(
            id: id,
            requestId: requestId,
            kind: kind,
            messageKey: messageKey,
            payloadSha256: sha,
            stagedFileName: stagedName,
            state: .queued,
            attemptCount: 0,
            nextAttemptAt: now(),
            enqueuedAt: now(),
            deliveredAt: nil,
            lastError: nil
        )
        items.append(item)
        do {
            // 「已入队」的承诺以索引落盘为准：写盘失败必须回滚内存和刚写的载荷，
            // 向调用方抛错——绝不能在磁盘满/IO 故障时假装可靠入队（进程一退就丢）。
            try persistIndex()
        } catch {
            items.removeLast()
            discardFiles(id: id, stagedFileName: stagedName)
            throw error
        }
        log(.enqueued(requestId: requestId, kind: kind, itemId: id))
        return .enqueued(item)
    }

    // MARK: - 读取

    func item(id: String) -> WatchDownlinkItem? {
        items.first { $0.id == id }
    }

    /// WCSession 回执只带回文件名，用它反查条目。
    func item(stagedFileName: String) -> WatchDownlinkItem? {
        items.first { $0.stagedFileName == stagedFileName }
    }

    /// 到期可投递的条目，按入队顺序返回（Watch 时间线依赖顺序）。
    func dueItems(at date: Date? = nil) -> [WatchDownlinkItem] {
        let reference = date ?? now()
        recoverStaleInFlight(at: reference)
        return items.filter { $0.state == .queued && $0.nextAttemptAt <= reference }
    }

    func pendingCount() -> Int {
        items.filter { $0.state != .delivered }.count
    }

    func earliestNextAttempt() -> Date? {
        items.filter { $0.state == .queued }.map(\.nextAttemptAt).min()
    }

    /// Bridge 的 completed snapshot 仍包含该回合，说明 Watch 的业务 ACK 尚未抵达。
    /// WCSession 的 didFinish 只代表文件交给了 Watch 传输层，不能继续用对应的
    /// delivered tombstone 阻止业务层重投。先持久化移除 tombstone，下一次
    /// enqueueSpeech 才能用重新下载的音频建立一个可投递条目。
    @discardableResult
    func invalidateDeliveredSpeech(requestId: String) -> Bool {
        let removed = items.filter {
            $0.requestId == requestId && $0.kind == .speech && $0.state == .delivered
        }
        guard !removed.isEmpty else { return false }

        let snapshot = items
        let removedIds = Set(removed.map(\.id))
        items.removeAll { removedIds.contains($0.id) }
        guard persistIndexReportingFailure(operation: "invalidate-delivered-speech") else {
            items = snapshot
            return false
        }
        removedIds.forEach { pendingPayloadDiscards.remove($0) }
        return true
    }

    func payload(for id: String) throws -> Data {
        guard let data = try? Data(contentsOf: payloadURL(for: id)) else {
            throw WatchDownlinkError.payloadUnavailable(itemId: id)
        }
        return data
    }

    func stagedAudioURL(for id: String) -> URL? {
        guard let name = item(id: id)?.stagedFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 状态迁移

    /// 会话不可用：条目原样留在队列，仅留痕。**不计入 attemptCount**，
    /// 否则「App 一直没开」会把退避推到上限，用户打开 App 后还要干等。
    func markDeferred(id: String, reason: String) {
        guard let item = item(id: id) else { return }
        log(.deferred(requestId: item.requestId, kind: item.kind, itemId: id, reason: reason))
    }

    /// 已交给 WCSession，等待系统回执。
    func markInFlight(id: String) {
        mutate(id: id, operation: "mark-in-flight") { item in
            item.state = .inFlight
            item.attemptCount += 1
            // Reuse nextAttemptAt as the in-flight receipt deadline. If
            // WCSession never calls didFinish, dueItems recovers the entry.
            item.nextAttemptAt = now().addingTimeInterval(inFlightTimeout)
            log(.attempted(
                requestId: item.requestId, kind: item.kind, itemId: item.id, attempt: item.attemptCount
            ))
        }
    }

    /// 系统回执成功：条目转 `delivered` 并保留用于幂等与观测；载荷与暂存音频
    /// **只有在 `delivered` 成功落盘之后**才删除。
    ///
    /// 原实现无条件先删载荷：索引写盘失败时只记一条 fault 就继续删，磁盘上仍是
    /// `inFlight`，进程此刻退出 → 重启 `recoverInFlight()` 把它拉回 `queued` →
    /// 载荷已不存在 → 永久 `payload-missing`，这条结果再也送不到手表（ESS-43）。
    /// 现在落盘失败时文件原样保留，等下一次成功落盘再删；进程中途退出也只是按磁盘
    /// 状态重投一次（至少一次交付），不会丢。
    func markDelivered(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        pendingPayloadDiscards.insert(id)
        mutate(id: id, operation: "mark-delivered") { item in
            item.state = .delivered
            item.deliveredAt = now()
            item.lastError = nil
            log(.delivered(
                requestId: item.requestId, kind: item.kind, itemId: item.id, attempt: item.attemptCount
            ))
        }
    }

    /// 投递失败：退避后重试，返回下一次尝试时间。
    @discardableResult
    func markFailed(id: String, reason: String) -> Date? {
        var next: Date?
        mutate(id: id, operation: "mark-failed") { item in
            if item.state != .inFlight { item.attemptCount += 1 }
            item.state = .queued
            item.lastError = reason
            item.nextAttemptAt = now().addingTimeInterval(
                backoff.delay(forAttempt: item.attemptCount, random: random)
            )
            next = item.nextAttemptAt
            log(.failed(
                requestId: item.requestId, kind: item.kind, itemId: item.id,
                attempt: item.attemptCount, reason: reason
            ))
        }
        return next
    }

    /// 冷启动恢复：没有回执就不算送达，`inFlight` 一律回落 `queued` 立即重投。
    func recoverInFlight() {
        var changed = false
        for index in items.indices where items[index].state == .inFlight {
            items[index].state = .queued
            items[index].nextAttemptAt = now()
            changed = true
        }
        if changed { persistIndexReportingFailure(operation: "recover-in-flight") }
    }

    /// WCSession callbacks are not guaranteed when the process/session is torn
    /// down. Recover in-process stalls as well as cold-start stalls.
    private func recoverStaleInFlight(at date: Date) {
        var changed = false
        for index in items.indices
        where items[index].state == .inFlight && items[index].nextAttemptAt <= date {
            items[index].state = .queued
            items[index].lastError = "receipt-timeout"
            items[index].nextAttemptAt = date
            log(.failed(
                requestId: items[index].requestId,
                kind: items[index].kind,
                itemId: items[index].id,
                attempt: items[index].attemptCount,
                reason: "receipt-timeout"
            ))
            changed = true
        }
        if changed { persistIndexReportingFailure(operation: "recover-receipt-timeout") }
    }

    /// 清理：已送达条目超保留期移除；排队条目超保留期放弃并以 `expired` 留痕。
    /// 返回被放弃的排队条目，调用方可据此提示用户「这条结果没能送到手表」。
    ///
    /// 与 `markDelivered` 同一条纪律：**先让「条目已移除」这件事落盘，再删文件**。
    /// 反过来（旧实现）在写盘失败时会留下「磁盘仍列着条目、载荷已被删」的组合，
    /// 重启后同样变成永久 `payload-missing`（ESS-43 同类顺序窗口）。落盘失败时
    /// 整轮清理回滚，条目与文件都原样保留，下一轮再清。
    @discardableResult
    func purgeExpired() -> [WatchDownlinkItem] {
        let cutoff = now().addingTimeInterval(-retention)
        let expired = items.filter { $0.state != .delivered && $0.enqueuedAt < cutoff }
        let removable = items.filter { item in
            item.state == .delivered
                ? (item.deliveredAt ?? item.enqueuedAt) < cutoff
                : item.enqueuedAt < cutoff
        }
        guard !removable.isEmpty else { return [] }

        // 文件名必须在移除条目之前取到——移除后 `item(id:)` 就查不到 stagedFileName 了。
        let doomed = removable.map { (id: $0.id, stagedFileName: $0.stagedFileName) }
        let snapshot = items
        let removedIds = Set(removable.map(\.id))
        items.removeAll { removedIds.contains($0.id) }
        guard persistIndexReportingFailure(operation: "purge-expired") else {
            items = snapshot
            return []
        }

        for entry in doomed {
            discardFiles(id: entry.id, stagedFileName: entry.stagedFileName)
            pendingPayloadDiscards.remove(entry.id)
        }
        for item in expired {
            log(.expired(requestId: item.requestId, kind: item.kind, itemId: item.id))
        }
        return expired
    }

    // MARK: - 私有

    private func mutate(id: String, operation: String, _ body: (inout WatchDownlinkItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
        persistIndexReportingFailure(operation: operation)
    }

    /// 索引已经 durable，此前推迟的载荷删除到这里才安全。
    private func flushPendingPayloadDiscards() {
        guard !pendingPayloadDiscards.isEmpty else { return }
        let ids = pendingPayloadDiscards
        pendingPayloadDiscards.removeAll()
        for id in ids { discardPayloads(id: id) }
    }

    private func discardPayloads(id: String) {
        discardFiles(id: id, stagedFileName: item(id: id)?.stagedFileName)
    }

    private func discardFiles(id: String, stagedFileName: String?) {
        try? fileManager.removeItem(at: payloadURL(for: id))
        if let stagedFileName {
            try? fileManager.removeItem(at: directory.appendingPathComponent(stagedFileName))
        }
    }

    private func payloadURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).payload")
    }

    /// Bridge snapshots regenerate occurred_at. It is transport metadata, not
    /// delivery identity; excluding it makes replay idempotent across reconnects.
    private func semanticPayload(_ payload: Data, kind: WatchDownlinkKind) -> Data {
        guard kind == .voiceStatus || kind == .speech || kind == .probe,
              let envelope = try? VoiceStatusEnvelope.decode(from: payload),
              let canonical = try? VoiceStatusEnvelope.status(
                requestId: envelope.requestId,
                state: envelope.state,
                occurredAt: Date(timeIntervalSince1970: 0),
                detail: envelope.detail,
                failureStage: envelope.failureStage,
                permission: envelope.permission,
                result: envelope.result
              ).jsonData()
        else { return payload }
        return canonical
    }

    private func persistIndex() throws {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw WatchDownlinkError.storageFailure(error.localizedDescription)
        }
        flushPendingPayloadDiscards()
    }

    /// 状态迁移路径不能抛错（多来自 WCSession 回调），但失败必须留痕：
    /// 内存是最新真相，磁盘落后一步，下一次成功落盘即收敛。
    /// 返回值供调用方决定「能不能做不可逆的后续动作」（删载荷、删条目）。
    @discardableResult
    private func persistIndexReportingFailure(operation: String) -> Bool {
        do {
            try persistIndex()
            return true
        } catch {
            log(.persistFailed(operation: operation, reason: String(describing: error)))
            return false
        }
    }
}
