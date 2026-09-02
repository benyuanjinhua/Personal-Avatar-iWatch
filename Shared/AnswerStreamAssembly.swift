import Foundation

// MARK: - ESS-1111 答案文本增量的回合级装配
//
// 问题：Codex 长任务的最终答案此前只有**播完整段音频**这一条到达路径，
// 文本侧要么等 `transcript.final` 一次性到达，要么根本不到（ESS-1109 真机
// 取证：任务仍在跑时连接断掉，24 s 后完成的答案无法回传，用户从头到尾只看到
// 一句「正在思考」）。上游 ESS-1110 已经把答案 token 投影成有序的
// `task.stream{category:'text'}`，网关（`AudioRealtimeGateway/realtime-session.mjs`
// `_emitTaskState`）把它落在 `task.state` 的 `answer_delta` / `answer_seq` 上。
//
// 本类型只做**一件事**：把一串到达顺序不保证的 `answer_delta` 收敛成
// 「此刻该显示的那段答案」。纯值类型（无 SwiftUI / 无时钟 / 无网络 / 无锁），
// 因此它既能被 `Tests/` 完整覆盖，也不会阻塞音频线程——装配一帧增量就是一次
// 字符串拼接和一次序号比较，没有任何 I/O。
//
// 三条硬约束，都对应本单验收里点名的失败面：
//
// 1. **回合绑定**：与 `ToolProgressNarration` 同生共死，由 `SessionController`
//    在换 `activeTurnRequestId` 时整体重建。跨回合复用会把上一轮的答案接在
//    新一轮前面——那是「旧 generation 不得污染新回合」的反面。
//
// 2. **不倒退、不重复**：`answer_seq` 是网关每会话单调递增的序号。
//    iPhone → Watch 这一跳走 WCSession，不保证顺序；只按到达顺序拼接，会把
//    迟到的旧片段追加到新答案后面，读起来是一段错乱的话。凡是「不比已应用的
//    更新」的帧一律丢弃并留证。
//
// 3. **有界**：手表屏幕和内存都不能被一段无限增长的答案撑爆。累计文本超过
//    `maxRetainedCharacters` 时**保留尾部**——正在生成的那一头才是用户此刻
//    在读的内容，截头不截尾。

/// ESS-1111 线格载荷：`task.state` 帧上可选的答案文本增量。
///
/// 两个字段都来自网关，客户端一个字都不自己编：
/// - `sequence`（`answer_seq`）：每会话单调递增，客户端据此丢弃迟到与重复。
///   可缺席（未升级的网关），缺席时按「无序号」处理而不是丢弃——把没带号的
///   帧一律丢掉，等于让答案流在滚动升级窗口里整个消失。
/// - `delta`：这一帧新增的文本。**空增量不构成载荷**（构造即失败）：一个没有
///   文字的「答案增量」对用户是零信息，却会白白推进序号闸门。
public struct AgentTaskAnswerDelta: Equatable, Sendable {
    public let sequence: Int?
    public let delta: String

    public init?(sequence: Int?, delta: String?) {
        guard let delta, !delta.isEmpty else { return nil }
        self.sequence = sequence
        self.delta = delta
    }
}

public struct AnswerStreamAssembly: Equatable, Sendable {

    /// 手表侧保留的答案字符上限。超出时丢弃**头部**，保留最新的一段。
    /// 400【待调】≈ 45mm 表盘上滚动阅读的十余屏，足够回看刚刚流出的内容，
    /// 又不会让一个跑飞的长答案把内存和渲染都拖垮。
    public static let maxRetainedCharacters = 400

    /// 被截断时加在头部的省略号——用户必须能看出「上面还有」，
    /// 而不是以为答案就是从半句话开始的。
    public static let truncationMarker = "…"

    /// 一帧增量的处置结果。日志与测试都读它——「这一段为什么没显示」必须可判定。
    public enum Outcome: Equatable, Sendable {
        /// 采纳并追加到答案尾部。
        case applied
        /// 序号与已应用的相同——重复投递。
        case duplicate
        /// 序号比已应用的小——迟到/乱序。
        case outOfOrder
        /// 没有可显示的文本。
        case empty

        public var logName: String {
            switch self {
            case .applied: return "applied"
            case .duplicate: return "duplicate"
            case .outOfOrder: return "out_of_order"
            case .empty: return "empty"
            }
        }

        /// 是否需要把这一帧推给 UI。
        public var changesDisplay: Bool { self == .applied }
    }

    /// 已应用的最大序号。`nil` = 本回合还没收到过任何带序号的增量。
    public private(set) var latestSequence: Int?
    /// 当前应显示的答案文本（已按上限保留尾部）。`nil` = 尚无任何增量。
    public private(set) var text: String?
    /// 本回合累计采纳 / 丢弃的增量帧数，落日志用。
    public private(set) var appliedCount = 0
    public private(set) var droppedCount = 0
    /// 累计收到的字符数（含已被截掉的头部）。取证用：真机上要能分辨
    /// 「答案只有这么短」与「答案很长但只留了尾部」。
    public private(set) var receivedCharacters = 0

    public init() {}

    /// 是否已经拿到过至少一段答案。
    public var hasAnswer: Bool { text != nil }

    /// 显示文本是否因为上限被截过头。
    public var isTruncated: Bool { receivedCharacters > Self.maxRetainedCharacters }

    /// 应用一帧答案增量。
    ///
    /// - Parameters:
    ///   - sequence: 网关的 `answer_seq`。`nil` 表示对端未实现该字段（滚动升级
    ///     窗口）——此时照常追加但不推进序号闸门。
    ///   - delta: `answer_delta`，来自上游真实答案 token。
    @discardableResult
    public mutating func apply(sequence: Int?, delta rawDelta: String?) -> Outcome {
        guard let rawDelta, !rawDelta.isEmpty else {
            droppedCount += 1
            return .empty
        }
        if let sequence, let latestSequence {
            if sequence == latestSequence {
                droppedCount += 1
                return .duplicate
            }
            if sequence < latestSequence {
                droppedCount += 1
                return .outOfOrder
            }
        }
        if let sequence { self.latestSequence = sequence }
        appliedCount += 1
        receivedCharacters += rawDelta.count
        text = Self.bounded((text ?? "") + rawDelta)
        return .applied
    }

    /// 回合终结 / 换回合时清空。停留的旧答案会挂在下一轮的屏幕上，
    /// 那是错的：它说的是上一句话。
    public mutating func clear() {
        text = nil
        latestSequence = nil
        appliedCount = 0
        droppedCount = 0
        receivedCharacters = 0
    }

    /// 结构化日志的一行摘要。**不含答案原文**——它是用户内容。
    public var logDetail: String {
        "answer_seq=\(latestSequence?.description ?? "nil")"
            + " answer_applied=\(appliedCount)"
            + " answer_dropped=\(droppedCount)"
            + " answer_len=\(text.map { String($0.count) } ?? "0")"
            + " answer_received=\(receivedCharacters)"
    }

    /// 上限裁剪：超出即丢头保尾，并在头部标出省略号。
    static func bounded(_ raw: String) -> String {
        guard raw.count > maxRetainedCharacters else { return raw }
        return truncationMarker + String(raw.suffix(maxRetainedCharacters))
    }
}
