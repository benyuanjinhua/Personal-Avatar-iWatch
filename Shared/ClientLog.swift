import Foundation

/// Watch 交互取证日志（ESS-42）：与服务端 trace 同构的最小结构化条目。
/// 只记元数据（字节数 / 状态 / 错误码），绝不落原始音频与凭据。
struct ClientLogEntry: Codable, Equatable {
    struct ErrorInfo: Codable, Equatable {
        /// 稳定错误码（如 ERR_* / NSError domain#code）；没有稳定码时为 nil。
        let code: String?
        let description: String
    }

    /// ISO8601 毫秒精度时间戳（字符串预格式化，避免解码方的日期策略分歧）。
    let ts: String
    let requestId: String?
    let module: String
    let event: String
    let detail: String?
    let error: ErrorInfo?

    enum CodingKeys: String, CodingKey {
        case ts
        case requestId = "request_id"
        case module
        case event
        case detail
        case error
    }

    init(
        ts: String = ClientLogClock.timestamp(),
        requestId: String? = nil,
        module: String,
        event: String,
        detail: String? = nil,
        error: ErrorInfo? = nil
    ) {
        self.ts = ts
        self.requestId = requestId
        self.module = module
        self.event = event
        self.detail = detail
        self.error = error
    }
}

enum ClientLogClock {
    // ISO8601DateFormatter 配置完成后线程安全；只读共享。
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func timestamp(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

/// 应用容器内 JSONL 滚动日志：当前文件写满即滚动成待运 chunk。
/// 单文件 ≤ maxFileBytes（默认 2MB）、chunk 最多保留 maxPendingChunks（默认 3）
/// ——通道长期不可用时丢最旧、留证据（chunks_dropped 标记），绝不撑爆手表。
/// 线程安全：所有文件操作串行在私有队列上，任意线程可调用
/// （全部存储属性不可变，可变状态只有磁盘文件，由串行队列守护）。
final class ClientLogStore: @unchecked Sendable {
    static let currentFileName = "current.jsonl"
    static let chunkPrefix = "watchlog-"
    static let chunkSuffix = ".jsonl"

    private let directory: URL
    private let maxFileBytes: Int
    private let maxPendingChunks: Int
    private let queue = DispatchQueue(label: "wristagent.clientlog.store")
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(directory: URL, maxFileBytes: Int = 2 * 1024 * 1024, maxPendingChunks: Int = 3) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxPendingChunks = maxPendingChunks
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var currentURL: URL {
        directory.appendingPathComponent(Self.currentFileName)
    }

    func append(_ entry: ClientLogEntry) {
        queue.async { [self] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            let size = (try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0, size + line.count > maxFileBytes {
                rotateCurrentLocked()
            }
            if let handle = try? FileHandle(forWritingTo: currentURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: currentURL, options: .atomic)
            }
        }
    }

    /// 把当前文件滚动为待运 chunk 并返回全部待运 chunk（旧→新）。
    /// 由 shipper 在合适的时机调用；当前文件为空时不产生空 chunk。
    func rotateForShipment() -> [URL] {
        queue.sync { [self] in
            rotateCurrentLocked()
            return pendingChunkURLsLocked()
        }
    }

    func pendingChunkURLs() -> [URL] {
        queue.sync { pendingChunkURLsLocked() }
    }

    /// chunk 送达（transferFile 成功）后删除本地副本。
    func removeChunk(named fileName: String) {
        queue.async { [self] in
            guard fileName.hasPrefix(Self.chunkPrefix) else { return }
            try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
        }
    }

    // MARK: - 私有（都在 queue 上执行）

    private func rotateCurrentLocked() {
        let size = (try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 {
            // UUIDv7 前缀毫秒时间戳：文件名字典序即时间序。
            let chunkName = "\(Self.chunkPrefix)\(UUIDv7.generate().uuidString.lowercased())\(Self.chunkSuffix)"
            try? fileManager.moveItem(at: currentURL, to: directory.appendingPathComponent(chunkName))
        }
        let chunks = pendingChunkURLsLocked()
        guard chunks.count > maxPendingChunks else { return }
        let dropped = chunks.prefix(chunks.count - maxPendingChunks)
        dropped.forEach { try? fileManager.removeItem(at: $0) }
        // 丢弃留痕：新 current 的第一行说明丢了几个 chunk。
        if var marker = try? encoder.encode(ClientLogEntry(
            module: "watchlog", event: "chunks_dropped", detail: "dropped=\(dropped.count)"
        )) {
            marker.append(0x0A)
            try? marker.write(to: currentURL, options: .atomic)
        }
    }

    private func pendingChunkURLsLocked() -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.chunkPrefix) && $0.hasSuffix(Self.chunkSuffix) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
}

/// Watch → iPhone 日志 chunk transferFile 的 metadata 键。
enum WatchClientLogMessage {
    /// 值为 chunk 文件名；出现该键即视为日志 chunk（与语音 transferFile 分流）。
    static let fileKey = "watch_client_log_file"

    /// ESS-137：`sendMessage` 直投单行 JSONL 的键（值为 `Data`，一行原字节）。
    /// transferFile 走系统托管队列（reachable=false 时会积压，本仓库 `chunk_transfer_failed`
    /// 是常见故障），G9 门禁读的是 bridge.log，不能靠概率取证。此路径仅用于
    /// 装机自检 `selfcheck_finished` 这类必须秒到的取证行：可达时走本路径直投，
    /// 不可达时静默失败——原有 transferFile 通道自然兜底，不重复投递也不阻塞。
    static let directLineKey = "watch_client_log_line"

    /// 直投单行的合成 chunk_id 前缀。带 `direct-` 让 bridge 侧 chunk_id 幂等去重
    /// 与 transferFile 的 chunk 完全区分（万一同一行两条路都送达，chunk_id 也不撞）。
    static let directChunkPrefix = "direct-"

    /// Watch 侧 JSONEncoder 不带换行；Bridge /v1/client-logs 按 `\n` 逐行解析，
    /// 补一个终止换行让单行 payload 与 chunk 文件格式一致。已带换行则原样返回，
    /// 不重复补——避免多送的空行让 Bridge 记 `watch_client_log_bad_line`。
    static func normalizeInlinePayload(_ data: Data) -> Data {
        guard let last = data.last, last != 0x0A else { return data }
        var normalized = data
        normalized.append(0x0A)
        return normalized
    }
}

/// iPhone → Bridge POST /v1/client-logs 请求体。jsonl 原样透传 Watch 的字节，
/// 逐行解析在 Bridge 侧做（宁可 Bridge 记 bad_line，不在手机上静默丢）。
struct ClientLogUploadBody: Codable {
    let protocolVersion: Int
    let chunkId: String
    let source: String
    let jsonl: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case chunkId = "chunk_id"
        case source
        case jsonl
    }

    init(chunkId: String, jsonl: String, source: String = "watch") {
        self.protocolVersion = RelayWire.protocolVersion
        self.chunkId = chunkId
        self.source = source
        self.jsonl = jsonl
    }

    func jsonData() throws -> Data {
        try RelayEventCoding.encoder.encode(self)
    }
}
