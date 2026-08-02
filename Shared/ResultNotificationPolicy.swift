import Foundation

/// ESS-55（白梦林 2026-08-02 拍板追加）：超长任务结果到达时的本地通知决策。
/// 通知由「结果实际抵达的那一端」发——手表侧；本类型只做纯决策与幂等记账，
/// 可在 macOS 单测覆盖；UNUserNotificationCenter 调用在 Watch 层（ResultNotifier）。
final class ResultNotificationPolicy {
    /// 「超长任务」判定阈值（写死并可测）：委派后超过 60 秒仍未出结果才通知，
    /// 短任务只走触觉，避免每条都震把用户逼到关通知权限。
    static let longTaskThresholdSeconds: TimeInterval = 60
    /// 兜底预约触发时间：超过 ExtendedRuntimeSession 上限（约 600s）才有意义——
    /// 上限内 App 还在运行，结果到达走精确通知；预约只兜「结果始终没到手表」。
    static let provisionalFallbackSeconds: TimeInterval = 720

    /// 跳过通知的原因（结构化日志用，禁止静默分支）。
    enum SkipReason: String {
        case shortTask = "short_task"
        case appActive = "app_active"
        case alreadyNotified = "already_notified"
        case notAuthorized = "not_authorized"
    }

    private let ledgerURL: URL
    private let maximumLedgerCount = 50
    /// 已通知的 request_id（幂等口径与 ESS-54 交付 ACK 一致：按 request_id 去重，
    /// 补投/重连多次到达只通知一次）。持久化，杀掉重开不重复通知。
    private var notified: [String]

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledgerURL = directory.appendingPathComponent("notified-results.json")
        if
            let data = try? Data(contentsOf: ledgerURL),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        {
            notified = saved
        } else {
            notified = []
        }
    }

    /// 结果到达时是否发通知；nil = 发，否则给出跳过原因。
    func skipReason(
        requestId: String,
        turnCreatedAt: Date,
        completedAt: Date,
        isAppActive: Bool,
        isAuthorized: Bool
    ) -> SkipReason? {
        if completedAt.timeIntervalSince(turnCreatedAt) < Self.longTaskThresholdSeconds {
            return .shortTask
        }
        if isAppActive { return .appActive }
        if notified.contains(requestId) { return .alreadyNotified }
        if !isAuthorized { return .notAuthorized }
        return nil
    }

    /// 记账：该 request_id 已通知（含兜底预约已触达的情形）。
    func markNotified(requestId: String) {
        guard !notified.contains(requestId) else { return }
        notified.append(requestId)
        if notified.count > maximumLedgerCount {
            notified.removeFirst(notified.count - maximumLedgerCount)
        }
        guard let data = try? JSONEncoder().encode(notified) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    func hasNotified(requestId: String) -> Bool {
        notified.contains(requestId)
    }

    /// 通知内容（纯函数，可测）。协议限制：结果载荷里没有原始提问的转写摘要
    /// （手表端从不持有 ASR 文本），标题暂用固定文案，正文带结果摘要；
    /// 「你问的〈原问题摘要〉」需要 Mac 侧在结果信封里补 question_summary 字段，已列跟进。
    static func notificationContent(resultSummary: String) -> (title: String, body: String) {
        let trimmed = resultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty
            ? "点开查看全文"
            : String(trimmed.prefix(60)) + (trimmed.count > 60 ? "…" : "")
        return (title: "任务完成，结果来了", body: body)
    }

    /// 兜底预约的内容：结果可能始终没到手表（手机不可达），文案必须诚实——
    /// 不承诺「有结果」，只召回用户。
    static func provisionalContent() -> (title: String, body: String) {
        (title: "长任务还在进行", body: "打开腕语查看最新进展，有结果会第一时间提醒你")
    }
}
