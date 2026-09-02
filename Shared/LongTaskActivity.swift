import Foundation

// MARK: - ESS-1111 长任务增量的展示分类与答案流
//
// 背景（ESS-1109 真机取证）：Codex 长任务 24.020s 完成，网关从任务开始即每秒
// 下发 `task.running`，9.48s 起有真实内容进展，13:46:26 起「正在整理结果」。
// 手表这一侧此前只认识两件事——「有没有工具在跑」（ESS-1097）与「最新那句
// 进展文字」（ESS-1100）。它**不区分**这句话是排队、在想、在用工具、在收尾
// 还是**已经是答案本身**，因此答案 token 一旦以增量形式到达，手表要么把它
// 当成一句会被下一帧覆盖的「进展」丢掉，要么整段挤进那一行的 14 字预算里。
//
// 本文件补上这一层，且只补这一层：
//
//   1. `LongTaskActivityKind` —— 把上游的 `progress_category` /（缺席时）
//      `task_status` 投影成一个**稳定、可判定**的展示类目。未知取值一律
//      降级为 `.other(raw)` 并**照常展示**，不丢帧、不抛错：滚动升级窗口里
//      网关随时可能新增类目，把没见过的类目当成错误处理，等于每次协议演进
//      都让手表的进展展示整个消失。
//
//   2. `LongTaskAnswerTranscript` —— 答案增量的回合级累积器。它做三件事：
//      按 `seq` 去重保序、对**增量**与**全量快照**两种上游口径都收敛到同一
//      结果、以及把长文本按尾窗滚动 + 硬上限截断，让 45mm 表盘上永远只渲染
//      有界的一小段。
//
// 两个类型都是**纯值类型**：不依赖 SwiftUI / AVFoundation / 网络 / 时钟。
// 这不是风格洁癖——本单验收要求「长文本不阻塞音频线程」，而一个没有锁、
// 没有 I/O、没有无界增长的值类型是这条要求的**结构性**保证，而不是一句
// 需要靠压测反复确认的承诺。全部行为在 `Tests/Ess1111LongTaskStreamTests.swift`
// 里可完整覆盖。

// MARK: - 展示类目

/// 长任务增量在手表上的展示类目。
///
/// 取值刻意与上游 `activity.category` / `task.status` 的字符串对齐
/// （`AudioRealtimeGateway/task-progress.mjs`、qwen-audio-agent 的
/// `publicTask.activity[]`），但**不做白名单拒绝**：认不出来的类目按
/// `.other(raw)` 原样展示上游给的文字。
public enum LongTaskActivityKind: Equatable, Sendable {
    /// 任务已受理、还没开跑。
    case queued
    /// 任务在跑，但这一帧没说清在做什么。
    case running
    /// 上游明确标注的推理/计划阶段。
    case reasoning
    /// 工具调用阶段（检索、读取、写入、生成图片、执行命令…）。
    case tool
    /// 结果整理/收尾阶段。
    case result
    /// **答案正文的增量**。与上面五类的处置完全不同：它进答案流累积器，
    /// 不进那条会被下一帧覆盖的进展行。
    case answer
    /// 上游给了一个客户端还不认识的类目。照常展示，不丢帧。
    case other(String)

    /// 从 `progress_category`（首选）与 `task_status`（兜底）投影。
    ///
    /// 顺序有意：类目是上游对「这一帧在说什么」的直接表述，状态只说明
    /// 「任务整体处在哪一段」。类目在就用类目，否则退到状态；两者都认不出
    /// 时按 `.other` 保留原文——保留比猜测更有信息量。
    public init(category: String?, status: String? = nil) {
        // 类目**在场即独占**：认得出就用认得出的那一类，认不出就按 `.other`
        // 原样留住上游的措辞。退到状态只发生在类目**缺席**时——一个带着
        // `category=sandbox_exec` 的帧被记成笼统的 `running`，等于把上游真正
        // 说了什么在日志里抹掉，下次协议演进就无从复核。
        if let token = Self.normalizedToken(category) {
            self = Self.fromCategory(token) ?? .other(token)
            return
        }
        if let token = Self.normalizedToken(status) {
            self = Self.fromStatus(token) ?? .other(token)
            return
        }
        // 两个字段都缺席：`task.state` 能到达本身就证明有任务在跑。
        self = .running
    }

    private static func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fromCategory(_ token: String) -> LongTaskActivityKind? {
        switch token {
        case "queued", "pending", "waiting":
            return .queued
        case "running", "progress", "working", "delegated":
            return .running
        case "reasoning", "reason", "thinking", "thought", "plan", "planning":
            return .reasoning
        case "tool", "tool_call", "search", "read", "write", "image", "exec",
             "command", "shell", "browse", "fetch":
            return .tool
        case "result", "finalizing", "summary", "summarizing":
            return .result
        // ESS-1111（#412 / #413 合并收口）：**只认显式的 answer 类目**。
        //
        // #412 写这条时网关还没有真正的答案线格，`text` / `message` / `output`
        // 是当时的兜底猜测。#413 之后网关把 `task.stream{category:'text'}`
        // 直接投影成 `answer_delta` / `answer_seq`（见
        // `AudioRealtimeGateway/qwen-agent-transport.mjs`），而
        // `progress_category` 只承载**进展**类目。此时再把 `text` 当答案，
        // 就会把一条正常的进展帧劫持进答案流、同时让进展行退回「正在处理」
        // ——`WatchTests/Ess1111AnswerStreamDisplayTests` 的
        // `testSingleFrameCarryingBothIsFullyApplied` 正是钉这个的。
        case "answer", "answer_delta":
            return .answer
        default:
            return nil
        }
    }

    private static func fromStatus(_ token: String) -> LongTaskActivityKind? {
        switch token {
        case "queued", "pending", "accepted":
            return .queued
        case "running", "in_progress", "progress":
            return .running
        case "finalizing":
            return .result
        default:
            return nil
        }
    }

    /// 结构化日志用的稳定标识。
    public var logName: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .reasoning: return "reasoning"
        case .tool: return "tool"
        case .result: return "result"
        case .answer: return "answer"
        case .other(let raw): return "other:\(raw)"
        }
    }

    /// 这一类目的增量是否属于**答案正文**（走累积器而不是进展行）。
    public var isAnswerStream: Bool { self == .answer }

    /// 上游**没给文字**时这一类目的稳定兜底。
    ///
    /// 只对「纯生命周期」的类目给具体说法——那是上游状态字段的**忠实渲染**，
    /// 不是编造。`reasoning` / `tool` / `other` 一律退到通用的
    /// `ToolProgressNarration.fallbackText`（「正在处理」）：手表不知道模型在想
    /// 什么、也不知道调的是哪个工具，替它编一句正是本单明令禁止的伪造。
    /// `.answer` 返回 `nil`——一条没有文字的「答案增量」什么都不是。
    public var statusFallbackText: String? {
        switch self {
        case .queued: return "正在排队"
        case .result: return "正在整理结果"
        case .answer: return nil
        case .running, .reasoning, .tool, .other: return ToolProgressNarration.fallbackText
        }
    }
}

// MARK: - 答案流

/// 回合级的答案增量累积器。
///
/// **为什么不复用 `ToolProgressNarration`**：进展行的语义是「覆盖」——只显示
/// 最新那一句，旧的必须消失；答案的语义是「追加」——每一片都是最终答案的
/// 一部分，丢掉任何一片都是内容缺失。两种语义塞进一个类型，去重规则和截断
/// 规则必然打架。
///
/// **上游两种口径都要吃下**。ESS-1112 的契约是「answer delta」，但同一条链路上
/// 也存在按**全量快照**重发的实现（H5 参照实现的 `task.snapshot` 就是全量）。
/// 客户端无法要求对端只用一种口径，因此这里用一个确定性判据而不是概率猜测：
/// 全量快照必然以本回合**最早那段答案文字**（`headPrefix`）开头且总长不短于
/// 已收到的总量；满足这两条即按全量替换，否则按增量追加。判据只读已经记下的
/// 定长指纹，截断之后依然成立。
public struct LongTaskAnswerTranscript: Equatable, Sendable {

    /// 回合内保留的最大字符数。超出即**从头部丢弃**（滚动），保留最新的尾部。
    ///
    /// 手表不是阅读器：答案正文的完整版由 iPhone 的会话历史与语音播报承担，
    /// 表盘只需要「说到哪儿了」的实时感。240 字 ≈ 表盘可滚动区域的数倍余量，
    /// 同时把内存占用钉死在常数——一个几十 KB 的答案不会在手表上无界增长。
    public static let maxRetainedCharacters = 240

    /// 一次渲染的尾窗大小。视图层按两行 caption 排版，36 字是 45mm 表盘上
    /// 两行中文的实际容量。
    public static let displayWindowCharacters = 36

    /// 全量判据用的头部指纹长度。取 16 字：足够把两段不同的答案区分开，
    /// 又短到第一帧就能建立。
    static let headFingerprintCharacters = 16

    /// 一帧答案增量的处置结果。
    public enum Outcome: Equatable, Sendable {
        /// 按增量追加，显示文本变了。
        case appended
        /// 识别为全量快照并整体替换，显示文本变了。
        case replaced
        /// 采纳了，但尾窗渲染结果与当前一致（不触发 UI 重画）。
        case unchanged
        /// 序号与已应用的相同 —— 重复投递。
        case duplicate
        /// 序号比已应用的小 —— 迟到/乱序。
        case outOfOrder
        /// 没有可展示文本。
        case empty

        public var logName: String {
            switch self {
            case .appended: return "appended"
            case .replaced: return "replaced"
            case .unchanged: return "unchanged"
            case .duplicate: return "duplicate"
            case .outOfOrder: return "out_of_order"
            case .empty: return "empty"
            }
        }

        /// 是否需要把这一帧推给 UI。
        public var changesDisplay: Bool { self == .appended || self == .replaced }
    }

    /// 已应用的最大 `progress_seq`。`nil` = 本回合还没收到过带号的答案帧。
    public private(set) var latestSequence: Int?
    /// 保留下来的答案文本（已按 `maxRetainedCharacters` 做头部滚动截断）。
    public private(set) var retainedText: String = ""
    /// 本回合累计**收到**的答案字符数（含已被滚动丢弃的部分）。
    public private(set) var receivedCharacterCount = 0
    /// 是否已经发生过头部滚动截断。
    public private(set) var didTrim = false
    public private(set) var appliedCount = 0
    public private(set) var droppedCount = 0

    /// 本回合最早那段答案文字的定长指纹，用于识别全量快照。
    private var headFingerprint: String = ""

    public init() {}

    /// 是否已经拿到过任何答案正文。
    public var hasAnswer: Bool { !retainedText.isEmpty }

    /// 视图应当渲染的那一小段（保留文本的尾窗）。`nil` = 还没有答案。
    ///
    /// 前面有内容被滚掉时加前导省略号，让「这是中间一段」这件事在屏幕上可见，
    /// 而不是让用户以为答案就是从这里开始的。
    public var displayText: String? {
        guard !retainedText.isEmpty else { return nil }
        guard retainedText.count > Self.displayWindowCharacters else { return retainedText }
        return "…" + String(retainedText.suffix(Self.displayWindowCharacters))
    }

    /// 应用一帧答案增量。
    ///
    /// - Parameters:
    ///   - sequence: 网关的 `progress_seq`。`nil`（老网关）时照常应用但不推进
    ///     序号闸门——把没带号的帧一律丢掉，等于滚动升级窗口内答案流整个消失。
    ///   - delta: 这一帧的答案文字（增量片段或全量快照）。
    @discardableResult
    public mutating func apply(sequence: Int?, delta rawDelta: String?) -> Outcome {
        let normalized = Self.normalize(rawDelta)
        // 判空看**去掉两端空白之后**的样子（纯空白帧没有信息，丢弃并留证），
        // 但真正落进答案的是**未去空白**的原样文本——英文答案的分词全靠
        // 增量之间那一个前导空格，trim 掉就会把 "hello" + " world" 粘成
        // "helloworld"。
        let meaningful = normalized.trimmingCharacters(in: .whitespaces)
        guard !meaningful.isEmpty else {
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

        let before = displayText
        // 判据用**严格大于**而不是「不短于」：一段与前一片等长、又恰好以同样
        // 几个字开头的增量（重复短语、列表项）会满足「不短于」，被误判成全量
        // 快照后前面所有内容就被整段抹掉。全量快照按定义**包含**已收到的一切，
        // 因此必然严格更长；严格判据把误判面收敛到零，代价只是「一个一个字都
        // 没新增的快照」会走追加——那种帧由序号闸门先挡掉。
        let isSnapshot = !headFingerprint.isEmpty
            && meaningful.hasPrefix(headFingerprint)
            && meaningful.count > receivedCharacterCount
        if isSnapshot {
            receivedCharacterCount = meaningful.count
            retain(meaningful, replacing: true)
        } else {
            receivedCharacterCount += normalized.count
            retain(normalized, replacing: false)
        }
        if headFingerprint.isEmpty {
            headFingerprint = String(
                retainedText
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(Self.headFingerprintCharacters)
            )
        }
        guard displayText != before else { return .unchanged }
        return isSnapshot ? .replaced : .appended
    }

    /// 回合结束 / 换回合时清空。上一轮的答案挂在新一轮头上是本单点名禁止的
    /// 「旧任务污染新会话」的展示形态。
    public mutating func clear() {
        latestSequence = nil
        retainedText = ""
        receivedCharacterCount = 0
        didTrim = false
        headFingerprint = ""
    }

    /// 结构化日志的一行摘要。**不记答案正文**——它是用户内容。
    public var logDetail: String {
        "answer_seq=\(latestSequence?.description ?? "nil")"
            + " answer_chars=\(receivedCharacterCount)"
            + " answer_retained=\(retainedText.count)"
            + " answer_trimmed=\(didTrim)"
            + " answer_applied=\(appliedCount)"
            + " answer_dropped=\(droppedCount)"
    }

    // MARK: - 内部

    private mutating func retain(_ piece: String, replacing: Bool) {
        let merged = replacing ? piece : retainedText + piece
        guard merged.count > Self.maxRetainedCharacters else {
            retainedText = merged
            return
        }
        didTrim = true
        retainedText = String(merged.suffix(Self.maxRetainedCharacters))
    }

    /// 归一化：压掉换行与连续空白。答案里的换行会把手表那两行的排版撑坏，
    /// 而**内容一个字都不删**——截断只发生在长度上限那一处，且是显式的。
    static func normalize(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }
}
