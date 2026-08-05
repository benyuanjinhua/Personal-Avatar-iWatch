import Foundation

/// ESS-386：Bridge 下行时间戳由 JS `Date#toISOString()` 生成，固定带毫秒
///（`YYYY-MM-DDTHH:mm:ss.sssZ`）。Swift `.iso8601` 策略底层是
/// `ISO8601DateFormatter`，旧 SDK（macOS 15 / watchOS 10 等）默认
/// `formatOptions = .withInternetDateTime`，不含 `.withFractionalSeconds`，
/// 遇到 `.000Z` 返回 nil；叠加各处的 `try?`，整条下行事件被静默丢弃，
/// 不崩溃也不打日志——ESS-368 在 CI（macos-15）上复现过该断层。
///
/// 本策略统一容错解码：先尝试带小数秒，再回退无小数秒，两种都能解出。
/// Bridge 侧输出格式是既定契约（R-01.2），不改；只让 Swift 端解得下来。
/// 三个解码入口（`VoiceProtocolJSON` / `VoiceRequestEnvelope` /
/// `VoiceRelayEvents` 两处）必须使用同一策略，避免只修一处继续漂移。
enum VoiceDateDecoding {
    static let strategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let date = fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法解析 ISO8601 时间戳：\(raw)"
        )
    }

    /// ISO8601DateFormatter 配置完成后线程安全；只读共享（同 ClientLogClock 约定）。
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
