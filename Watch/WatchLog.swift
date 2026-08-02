import Foundation
import os

/// 统一 WatchLog 设施（ESS-42）：一次调用同时写
/// 1. os.Logger（subsystem beer.workspace.wristagent，按模块分 category）——
///    真机连 Xcode / Console.app 时实时可见；
/// 2. 应用容器内 JSONL 滚动文件（ClientLogStore）——拉不到系统日志时，
///    经 WCSession → iPhone Relay → Bridge 回传 Mac 分析（WatchLogShipper）。
/// 任意线程可调用；只记元数据，不落音频与凭据。
enum WatchLog {
    static let subsystem = "beer.workspace.wristagent"

    static let store: ClientLogStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ClientLogStore(directory: base.appendingPathComponent("ClientLogs", isDirectory: true))
    }()

    private static let loggersLock = NSLock()
    nonisolated(unsafe) private static var loggers: [String: Logger] = [:]

    /// ESS-65 自检旁路观察：装机自检需要断言「某窗口内 session_activation_failed
    /// 出现 0 次」，而这些事件由 AudioRecorder/SpeechPlayer 在真实链路内部落日志，
    /// 不能靠返回值判断（失败可能被回落尝试吞掉）。观察者只读元数据（module/
    /// event/错误码），不改变日志行为；仅自检期间安装，平时为 nil 零开销。
    nonisolated(unsafe) private static var observer: (@Sendable (String, String, String?, String?) -> Void)?
    private static let observerLock = NSLock()

    static func setObserver(
        _ newValue: (@Sendable (_ module: String, _ event: String, _ detail: String?, _ errorCode: String?) -> Void)?
    ) {
        observerLock.lock()
        defer { observerLock.unlock() }
        observer = newValue
    }

    private static func logger(for module: String) -> Logger {
        loggersLock.lock()
        defer { loggersLock.unlock() }
        if let cached = loggers[module] { return cached }
        let created = Logger(subsystem: subsystem, category: module)
        loggers[module] = created
        return created
    }

    static func info(_ module: String, _ event: String, requestId: String? = nil, detail: String? = nil) {
        write(module: module, event: event, requestId: requestId, detail: detail, error: nil, level: .info)
    }

    static func error(
        _ module: String, _ event: String,
        requestId: String? = nil, detail: String? = nil,
        code: String? = nil, error: Error? = nil
    ) {
        let info = ClientLogEntry.ErrorInfo(
            code: code ?? (error.map { stableCode(of: $0) }),
            description: error?.localizedDescription ?? detail ?? event
        )
        write(module: module, event: event, requestId: requestId, detail: detail, error: info, level: .error)
    }

    /// NSError domain#code：没有业务稳定码时的可 grep 兜底。
    private static func stableCode(of error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    private static func write(
        module: String, event: String, requestId: String?,
        detail: String?, error: ClientLogEntry.ErrorInfo?, level: OSLogType
    ) {
        let line = [
            event,
            requestId.map { "request_id=\($0)" },
            detail,
            error.map { "error=\($0.code ?? "-"):\($0.description)" },
        ].compactMap { $0 }.joined(separator: " | ")
        logger(for: module).log(level: level, "\(line, privacy: .public)")
        store.append(ClientLogEntry(
            requestId: requestId, module: module, event: event, detail: detail, error: error
        ))
        observerLock.lock()
        let currentObserver = observer
        observerLock.unlock()
        currentObserver?(module, event, detail, error?.code)
    }
}
