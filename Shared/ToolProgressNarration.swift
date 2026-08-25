import Foundation

// MARK: - ESS-1100 长任务 thinking 进展文字的回合级叙述状态
//
// 问题：工具回合动辄几十秒，此前手表在整段等待里只有一句笼统的「正在思考…」。
// 参照实现（qwen-audio-agent H5，`web/src/task-view.js` + `App.jsx`）在同一段
// 时间里持续换词——「正在查询相关信息」「正在读取相关内容」——用户因此知道
// 任务在推进，而不是卡死了。
//
// 本类型只做**一件事**：把网关下发的一串 `task.state{progress_*}` 收敛成
// 「此刻该显示哪一行字」。它是纯值类型（无 SwiftUI / 无时钟 / 无网络），
// `Tests/ToolProgressNarrationTests.swift` 可完整覆盖。
//
// 三条硬约束，都对应本单验收里点名的失败面：
//
// 1. **回合绑定**：本类型是回合级的，由 `SessionController` 在换
//    `activeTurnRequestId` 时整体重建。跨回合复用会把上一轮的「正在查询」
//    按在新一轮头上——那是本单明令禁止的「旧任务污染新会话」。
//    request/session 的归属校验在会话层（`acceptsTurnEvent`）已经做过一遍，
//    这里不重复第二套真相，只负责回合**内**的排序与去重。
//
// 2. **不伪造**：显示的每一行都来自上游真实事件（投影规则在网关
//    `AudioRealtimeGateway/task-progress.mjs`）。没有进展文本时本类型返回
//    `nil`，由视图层退回稳定的「正在处理」——**不**在客户端编一句工具进展。
//
// 3. **不倒退**：`progress_seq` 是网关每会话单调递增的展示序号。iPhone → Watch
//    这一跳走 WCSession，不保证顺序，只按到达顺序渲染会让旧进展盖回新进展。
//    凡是「不比已应用的更新」的帧一律丢弃并留证。

/// ESS-1100 线格载荷：`task.state` 帧上可选的阶段性进展。
///
/// 三个字段全部来自网关（`AudioRealtimeGateway/realtime-session.mjs`
/// `_emitTaskState`），客户端一个字都不自己编：
/// - `sequence`（`progress_seq`）：网关每会话单调递增的展示序号，客户端据此
///   丢弃迟到与重复。可缺席（老网关），缺席时按「无序号」处理而不是丢弃。
/// - `text`（`progress_text`）：要显示的那句话。**没有它就没有本载荷**——
///   一个不带文字的「进展」对用户是零信息，构造即失败。
/// - `category`（`progress_category`）：取证用类目（search/read/plan/…）。
public struct AgentTaskProgress: Equatable, Sendable {
    public let sequence: Int?
    public let text: String
    public let category: String?

    /// 文本缺席或全空白 ⇒ 本帧没有进展，构造失败（返回 nil）。
    public init?(sequence: Int?, text: String?, category: String?) {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.sequence = sequence
        self.text = text
        self.category = category.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct ToolProgressNarration: Equatable, Sendable {

    /// 手表一行的字符预算。45mm 表盘上 `caption2` 中文约 15 字满行，取 14
    /// 留出省略号的位置。网关侧已按 24 字截过一次，这里是客户端的第二道
    /// 闸——两侧都不越界，任一侧的口径变化都不会把手表撑爆。
    public static let maxDisplayCharacters = 14

    /// 无进展文本时的稳定兜底（ESS-1100 §5）。刻意与普通回合的「正在思考…」
    /// 区分：工具回合里「有事在做但说不出做什么」与「模型在想」不是一回事，
    /// 用同一句话会把两种状态的可判定性一起抹掉。
    public static let fallbackText = "正在处理"

    /// 一帧进展的处置结果。日志与测试都读它——「这条为什么没显示」必须可判定。
    public enum Outcome: Equatable, Sendable {
        /// 采纳并且显示文本发生了变化。
        case applied
        /// 采纳了序号，但显示文本与当前一致（不触发任何 UI 变更，避免闪烁）。
        case unchanged
        /// 序号与已应用的相同——重复投递。
        case duplicate
        /// 序号比已应用的小——迟到/乱序。
        case outOfOrder
        /// 没有可展示文本（空串 / 全空白）。
        case empty

        public var logName: String {
            switch self {
            case .applied: return "applied"
            case .unchanged: return "unchanged"
            case .duplicate: return "duplicate"
            case .outOfOrder: return "out_of_order"
            case .empty: return "empty"
            }
        }

        /// 是否需要把这一帧推给 UI。
        public var changesDisplay: Bool { self == .applied }
    }

    /// 已应用的最大展示序号。缺省 `nil` = 本回合还没收到过任何带序号的进展。
    public private(set) var latestSequence: Int?
    /// 当前应显示的进展文本（已按小屏预算截断）。`nil` = 尚无任何进展。
    public private(set) var text: String?
    /// 上游给的进展类目（取证用；不参与显示决策）。
    public private(set) var category: String?
    /// 本回合累计采纳 / 丢弃的进展帧数，落日志用。
    public private(set) var appliedCount = 0
    public private(set) var droppedCount = 0

    public init() {}

    /// 是否已经拿到过至少一条真实进展。
    public var hasProgress: Bool { text != nil }

    /// 应用一帧进展。
    ///
    /// - Parameters:
    ///   - sequence: 网关的 `progress_seq`。`nil` 表示对端未实现该字段
    ///     （滚动升级窗口）——此时**照常显示**但不推进序号闸门：把没带号的
    ///     帧一律丢掉，等于让老网关配新手表时进展功能整个消失。
    ///   - text: `progress_text`，来自上游真实事件。
    ///   - category: `progress_category`。
    @discardableResult
    public mutating func apply(sequence: Int?, text rawText: String?, category rawCategory: String?) -> Outcome {
        let normalized = Self.normalize(rawText)
        guard !normalized.isEmpty else {
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
        let normalizedCategory = rawCategory.flatMap { $0.isEmpty ? nil : $0 }
        guard normalized != text else {
            // 同一句话重复下发（上游 activity 高频刷新的常态）：序号照收，
            // 但不报变化——UI 不该为一模一样的字重画一次。
            category = normalizedCategory ?? category
            return .unchanged
        }
        text = normalized
        category = normalizedCategory
        return .applied
    }

    /// 回合终结 / 进入回答态时清空叙述。停留的旧进展会在回答播出后仍挂在
    /// 屏幕上，那是错的：那一行说的是「还在做」。
    public mutating func clear() {
        text = nil
        category = nil
    }

    /// 结构化日志的一行摘要。
    public var logDetail: String {
        "progress_seq=\(latestSequence?.description ?? "nil")"
            + " progress_category=\(category ?? "nil")"
            + " progress_applied=\(appliedCount)"
            + " progress_dropped=\(droppedCount)"
            + " progress_len=\(text.map { String($0.count) } ?? "0")"
    }

    /// 归一化 + 小屏截断。换行/连续空白压成单空格——上游的自由文本
    /// （计划 detail、授权 summary）里带换行会把手表那一行的布局撑坏。
    static func normalize(_ raw: String?) -> String {
        guard let raw else { return "" }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        guard collapsed.count > maxDisplayCharacters else { return collapsed }
        return String(collapsed.prefix(maxDisplayCharacters)) + "…"
    }
}
