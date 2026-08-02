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

extension ClientLogEntry {
    /// 与 `ClientLogStore.append` 相同 encoder（sortedKeys + withoutEscapingSlashes）。
    /// 主/旁路两条通道输出 bytes 完全一致，便于 Bridge 侧对账。
    static let jsonlEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// 单行 JSONL（末尾带 `\n`）。ESS-137 快速旁路直投时使用；主路径仍走
    /// `ClientLogStore` 落盘 + transferFile，两侧字节应逐字节等价。
    func jsonlLine() throws -> Data {
        var data = try Self.jsonlEncoder.encode(self)
        data.append(0x0A)
        return data
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
    /// ESS-137 快速旁路：Watch 端 selfcheck_finished / 关键节点的完整 JSONL 行
    /// 走 sendMessage / transferUserInfo 直投，绕开正在失败的 transferFile 队列。
    /// 载荷是 `SelfCheckSummaryPayload.jsonData()` 编码后的 Data。
    static let selfCheckSummaryKey = "watch_client_log_selfcheck_summary"
}

/// ESS-137：装机自检收尾快速旁路载荷。Watch 端在 `selfcheck_finished` 落
/// bridge.log 前，把该行同步的 JSONL bytes 打包成一个「microchunk」，走
/// `sendMessage`（可达即刻送达）/ `transferUserInfo`（系统托管持久队列）
/// 双通道推 iPhone。iPhone 侧按 `chunkId` 幂等入 `ClientLogUplink` 队列，
/// 走 HTTPS POST /v1/client-logs 到 Bridge——与 transferFile 主路径归口
/// 同一个 chunk_id 幂等窗（重复送达不重复计数）。
///
/// 背景（ESS-137）：真机 chunk_transfer_failed（WCErrorDomain#7013 /
/// NSCocoaErrorDomain#4097）连发时，`selfcheck_finished` 无法到 Bridge，
/// G9 门禁读到 `ERR_NO_SELFCHECK` 与真实 FAIL 混同。本快速旁路把结论行
/// 从 chunk 队列拆出来单独送——WCSession XPC 层同一故障域不至于同时封死
/// 三个通道（transferFile / sendMessage / transferUserInfo）。
struct SelfCheckSummaryPayload: Codable, Equatable {
    /// 与主路径共用一套 chunk_id 幂等窗，重复送达 Bridge 一律去重。
    let chunkId: String
    /// 一整条 `ClientLogEntry` 的 JSONL 序列化（末尾带 \n），供 iPhone 侧
    /// 直接塞进 `ClientLogUplink.enqueue`；bytes 语义与主路径完全一致。
    let jsonl: String

    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id"
        case jsonl
    }

    init(chunkId: String, jsonl: String) {
        self.chunkId = chunkId
        self.jsonl = jsonl
    }

    static func decode(from data: Data) -> SelfCheckSummaryPayload? {
        try? JSONDecoder().decode(SelfCheckSummaryPayload.self, from: data)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
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
