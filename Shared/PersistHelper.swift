import Foundation

/// 轻量级原子写入重试：磁盘满 / 瞬时 IO 故障时最多重试 3 次，每次间隔 100ms。
/// 全部重试失败后抛错，供调用方 do/catch 落 WatchLog。
enum PersistHelper {
    /// 默认重试参数：3 次，每次间隔 100ms。
    static let defaultMaxRetries = 3
    static let defaultSleepInterval: TimeInterval = 0.1

    /// 原子写入 data 到 url，内部重试 `maxRetries` 次（默认 3），
    /// 每次失败后 sleep `sleepInterval` 秒（默认 0.1s）。
    /// 全部重试失败则抛出最后一次错误。
    static func writeAtomically(
        _ data: Data,
        to url: URL,
        maxRetries: Int = defaultMaxRetries,
        sleepInterval: TimeInterval = defaultSleepInterval
    ) throws {
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                try data.write(to: url, options: .atomic)
                return
            } catch {
                lastError = error
                if attempt < maxRetries {
                    Thread.sleep(forTimeInterval: sleepInterval)
                }
            }
        }
        throw lastError ?? NSError(
            domain: "PersistHelper",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "writeAtomically failed after \(maxRetries) attempts"]
        )
    }
}
