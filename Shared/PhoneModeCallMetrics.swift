import Foundation

/// ESS-655（F6）验收标准 3 / 4：把一段事件流还原成「通话 → 回合」结构，
/// 并按设计稿 §10.3 的定义算出指标。
///
/// 为什么要代码化而不是「事后拿 jq 数一数」：设计稿给的四条指标（无提示消失率、
/// 轮转成功率、每通额外按键数、语音打断误触发率）都是**门禁**——尤其
/// 「误触发率 0」是 F2 gate 默认 ON 的开关条件。口径散在几个人的临时命令行里，
/// 就会出现 R-04.4 那种「20 分钟窗口里的 100%」被当成普遍结论的事故。
/// 这里把口径写死成可测试的函数，谁跑都是同一个数，样本量和窗口显式带出来。
///
/// 输入是**外部输入**（真机 / 模拟器日志），所有事件都经
/// `PhoneModeTelemetry.validate` 校验；校验不过的记录进 `rejected`，不静默丢弃，
/// 也不混进分子分母（算不出来和算成 0 是两回事）。
enum PhoneModeCallTrace {

    /// 一条与来源无关的事件样本。`ClientLogEntry`（Watch 落盘 JSONL）和
    /// 测试内存日志都能映射到它。
    struct Sample: Equatable {
        let ts: Date
        let event: String
        let requestId: String?
        let detail: String?

        init(ts: Date, event: String, requestId: String? = nil, detail: String? = nil) {
            self.ts = ts
            self.event = event
            self.requestId = requestId
            self.detail = detail
        }
    }

    /// 校验未通过的记录——保留原始事件名与错误，便于定位是哪个调用点漂了。
    struct Rejection: Equatable {
        let event: String
        let detail: String?
        let error: PhoneModeTelemetry.ValidationError
    }

    /// 一次通话：从 `session_enter_requested` 到 `session_ended`。
    ///
    /// 归属规则（刻意不用时间容差）：`session_call_summary` 在设计稿里是
    /// 「进入 P7 时」记，而 `session_ended` 在拆链完成时记，两者先后取决于
    /// F3 的实现顺序。所以**紧跟在 `session_ended` 之后、下一次
    /// `session_enter_requested` 之前**的 summary 仍算这一通的。
    struct Call: Equatable {
        var samples: [Sample] = []
        /// 本通的 `session_call_summary`。0 条 = 无提示消失；≥2 条 = 有第二个
        /// 结束路径在自说自话。
        var summaries: [Sample] = []
        /// 本通是否已看到 `session_ended`（收尾被截断的日志尾巴不计入分母）。
        var isClosed = false
        /// 进入与挂断之外、由失败逼出来的额外按键（设计稿「每通额外按键数」）。
        var extraTaps = 0
        /// 按 request_id 分组的回合，按首次出现顺序排列。
        var turns: [Turn] = []
        /// 回合内事件顺序违例（乱序 / 多个终态）。
        var orderViolations: [String] = []
    }

    /// 一个回合。`requestId` 是唯一关联键——ESS-600 起所有回合事件都带它。
    struct Turn: Equatable {
        let requestId: String
        var events: [String] = []
    }

    // MARK: - 回合事件的规范顺序

    /// 秩相同表示「可以并列/重复出现」，秩递减即乱序。
    /// 未登记的事件不参与顺序判定（诊断类事件不该把链路判成违例）。
    private static let turnEventRank: [String: Int] = [
        "session_next_listening": 0,
        "session_turn_committed": 1,
        "session_thinking_slow": 1,
        "session_turn_cap_reached": 1,
        "session_answer_started": 2,
        "session_answer_interim": 2,
        "session_answer_finished": 3,
        "session_answer_failed": 3,
        "session_turn_aborted": 3,
        "session_speaking_interrupted": 3,
        "session_thinking_timeout": 3,
    ]

    private static let terminalTurnEvents: Set<String> = [
        "session_answer_finished",
        "session_answer_failed",
        "session_turn_aborted",
        "session_speaking_interrupted",
        "session_thinking_timeout",
    ]

    /// 逼出额外按键的事件（进入 / 挂断 / 打断都不算——设计稿「打断除外」）。
    private static let extraTapEvents: Set<String> = [
        "session_enter_rejected",
        "session_failed_retry_tapped",
    ]

    // MARK: - 切分

    struct Segmentation: Equatable {
        var calls: [Call] = []
        var rejected: [Rejection] = []
        /// 落在任何通话之外的样本（例如待机屏的 `session_enter_rejected`）。
        /// 归属规则见 `segment`：它们会被并进**下一通**。
        var orphans: [Sample] = []
    }

    /// 把时间序事件流切成通话。样本无需预排序，内部按 `ts` 稳定排序。
    static func segment(_ samples: [Sample]) -> Segmentation {
        var result = Segmentation()
        var current: Call?
        /// 尚未开通话就发生的额外按键（待机屏长按被拒）——记在这里，
        /// 下一通开始时并进去。用户为了打通这一通多按的次数就该算这一通头上。
        var pendingExtraTaps = 0
        var pendingOrphans: [Sample] = []

        for sample in stableSorted(samples) {
            // 契约内的事件先过校验；沿用事件（§10.1）没有 schema，原样通过。
            if let known = PhoneModeTelemetry.Event(rawValue: sample.event) {
                do {
                    _ = try PhoneModeTelemetry.validate(event: known.rawValue, detail: sample.detail)
                } catch let error as PhoneModeTelemetry.ValidationError {
                    result.rejected.append(
                        Rejection(event: sample.event, detail: sample.detail, error: error)
                    )
                    continue
                } catch {
                    continue
                }
            }

            switch sample.event {
            case "session_enter_requested":
                if let call = current { result.calls.append(call) }
                var started = Call()
                started.extraTaps = pendingExtraTaps
                pendingExtraTaps = 0
                result.orphans.append(contentsOf: pendingOrphans)
                pendingOrphans = []
                started.samples.append(sample)
                current = started

            case "session_call_summary":
                if current != nil {
                    current?.samples.append(sample)
                    current?.summaries.append(sample)
                } else if var last = result.calls.popLast() {
                    // `session_ended` 之后到达的 summary 仍属刚结束那一通。
                    last.samples.append(sample)
                    last.summaries.append(sample)
                    result.calls.append(last)
                } else {
                    pendingOrphans.append(sample)
                }

            case "session_ended":
                if var call = current {
                    call.samples.append(sample)
                    call.isClosed = true
                    result.calls.append(call)
                    current = nil
                } else {
                    pendingOrphans.append(sample)
                }

            default:
                if current != nil {
                    current?.samples.append(sample)
                    if extraTapEvents.contains(sample.event) { current?.extraTaps += 1 }
                } else {
                    if extraTapEvents.contains(sample.event) { pendingExtraTaps += 1 }
                    pendingOrphans.append(sample)
                }
            }
        }

        if let call = current { result.calls.append(call) }
        result.orphans.append(contentsOf: pendingOrphans)
        result.calls = result.calls.map(annotateTurns)
        return result
    }

    /// 按 request_id 还原回合并检查顺序（验收标准 3）。
    private static func annotateTurns(_ call: Call) -> Call {
        var annotated = call
        var order: [String] = []
        var grouped: [String: Turn] = [:]

        for sample in call.samples {
            guard let requestId = sample.requestId, !requestId.isEmpty else { continue }
            if grouped[requestId] == nil {
                grouped[requestId] = Turn(requestId: requestId)
                order.append(requestId)
            }
            grouped[requestId]?.events.append(sample.event)
        }

        var violations: [String] = []
        for requestId in order {
            guard let turn = grouped[requestId] else { continue }
            var lastRank = Int.min
            var terminals = 0
            for event in turn.events {
                if terminalTurnEvents.contains(event) { terminals += 1 }
                guard let rank = turnEventRank[event] else { continue }
                if rank < lastRank {
                    violations.append("\(requestId): \(event) 出现在更晚的相位之后")
                }
                lastRank = max(lastRank, rank)
            }
            if terminals > 1 {
                violations.append("\(requestId): 出现 \(terminals) 个终态事件，一轮只能收一次口")
            }
        }

        annotated.turns = order.compactMap { grouped[$0] }
        annotated.orderViolations = violations
        return annotated
    }

    /// `sorted(by:)` 不保证稳定；同毫秒事件的先后是链路证据的一部分，
    /// 用下标兜底保住原始顺序。
    private static func stableSorted(_ samples: [Sample]) -> [Sample] {
        samples.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.ts == rhs.element.ts { return lhs.offset < rhs.offset }
                return lhs.element.ts < rhs.element.ts
            }
            .map(\.element)
    }
}

// MARK: - 指标

/// 设计稿 §10.3 的指标口径，一处定义。所有比率都显式带样本量——
/// 分母为 0 时返回 `nil` 而不是 0，「没有样本」不许被读成「达标」（R-04.4）。
struct PhoneModeCallMetrics: Equatable {

    /// 「轮转成功率」的时间预算：`session_answer_finished` 到
    /// `session_next_listening` ≤ 400ms（设计稿 AC-2 / F3-8）。
    static let relistenBudget: TimeInterval = 0.4

    // 样本量
    let calls: Int
    let closedCalls: Int

    // 无提示消失率（目标 0%）
    let callsWithoutSummary: Int
    let callsWithDuplicateSummary: Int

    // 轮转成功率（目标 ≥99%，当前为待实测目标）
    let relistenOpportunities: Int
    let relistenWithinBudget: Int

    // 每通额外按键数（目标 0；打断除外）
    let extraTaps: Int

    // 语音打断误触发（目标 0，作为 gate 默认 ON 的门槛）
    let voiceInterrupts: Int
    let orbTapInterrupts: Int
    let selfEchoFalseTriggers: Int

    // 数据质量
    let rejectedRecords: Int
    let turnOrderViolations: [String]

    var silentDisappearanceRate: Double? {
        guard closedCalls > 0 else { return nil }
        return Double(callsWithoutSummary) / Double(closedCalls)
    }

    var relistenSuccessRate: Double? {
        guard relistenOpportunities > 0 else { return nil }
        return Double(relistenWithinBudget) / Double(relistenOpportunities)
    }

    var extraTapsPerCall: Double? {
        guard calls > 0 else { return nil }
        return Double(extraTaps) / Double(calls)
    }

    /// 误触发率 = 判定为自身回声的次数 / 语音打断触发总次数。
    /// 分母含误触发本身——「触发了 10 次，其中 3 次是回声」才是用户体感。
    var voiceBargeInFalseTriggerRate: Double? {
        let attempts = voiceInterrupts + selfEchoFalseTriggers
        guard attempts > 0 else { return nil }
        return Double(selfEchoFalseTriggers) / Double(attempts)
    }

    /// F2-5 门槛：真机跑过语音打断（有样本）且零自身回声误触发。
    /// **没有样本不算通过**——这正是 ESS-650 「未通过不得默认 ON」的意思。
    var isEligibleForDefaultOnGate: Bool {
        voiceInterrupts + selfEchoFalseTriggers > 0 && selfEchoFalseTriggers == 0
    }

    /// 链路可复原且无重复小结（验收标准 3）。
    var hasCleanChains: Bool {
        turnOrderViolations.isEmpty && callsWithDuplicateSummary == 0 && rejectedRecords == 0
    }

    static func compute(_ samples: [PhoneModeCallTrace.Sample]) -> PhoneModeCallMetrics {
        compute(PhoneModeCallTrace.segment(samples))
    }

    static func compute(_ segmentation: PhoneModeCallTrace.Segmentation) -> PhoneModeCallMetrics {
        let calls = segmentation.calls
        let closed = calls.filter(\.isClosed)

        var opportunities = 0
        var withinBudget = 0
        var voiceInterrupts = 0
        var orbTapInterrupts = 0
        var selfEcho = 0
        var violations: [String] = []

        for call in calls {
            violations.append(contentsOf: call.orderViolations)
            let ordered = call.samples

            for (index, sample) in ordered.enumerated() {
                switch sample.event {
                case "session_answer_finished":
                    // 播完之后必须自动回到聆听。中途通话结束的不算机会——
                    // 用户主动挂断不该被记成一次轮转失败。
                    var relistenAt: Date?
                    var interrupted = false
                    for next in ordered[(index + 1)...] {
                        if next.event == "session_next_listening" { relistenAt = next.ts; break }
                        if next.event == "session_ended" || next.event == "session_exit_requested" {
                            interrupted = true; break
                        }
                    }
                    guard !interrupted else { break }
                    opportunities += 1
                    if let relistenAt, relistenAt.timeIntervalSince(sample.ts) <= relistenBudget {
                        withinBudget += 1
                    }

                case PhoneModeTelemetry.Event.speakingInterrupted.rawValue:
                    let source = (try? PhoneModeTelemetry.fields(in: sample.detail))?["source"]
                    if source == PhoneModeTelemetry.InterruptSource.voice.rawValue {
                        voiceInterrupts += 1
                    } else if source == PhoneModeTelemetry.InterruptSource.orbTap.rawValue {
                        orbTapInterrupts += 1
                    }

                case PhoneModeTelemetry.Event.bargeInSelfEcho.rawValue:
                    selfEcho += 1

                default:
                    break
                }
            }
        }

        return PhoneModeCallMetrics(
            calls: calls.count,
            closedCalls: closed.count,
            callsWithoutSummary: closed.filter { $0.summaries.isEmpty }.count,
            callsWithDuplicateSummary: calls.filter { $0.summaries.count > 1 }.count,
            relistenOpportunities: opportunities,
            relistenWithinBudget: withinBudget,
            extraTaps: calls.reduce(0) { $0 + $1.extraTaps },
            voiceInterrupts: voiceInterrupts,
            orbTapInterrupts: orbTapInterrupts,
            selfEchoFalseTriggers: selfEcho,
            rejectedRecords: segmentation.rejected.count,
            turnOrderViolations: violations
        )
    }
}

// MARK: - 从落盘日志构造样本

extension PhoneModeCallTrace.Sample {
    /// 从 Watch 落盘的 JSONL 条目构造。`ts` 解析不出来的条目返回 nil——
    /// 指标全靠时间差，宁可少算一条也不给它编一个时间。
    init?(entry: ClientLogEntry) {
        guard let ts = ClientLogClock.date(entry.ts) else { return nil }
        self.init(ts: ts, event: entry.event, requestId: entry.requestId, detail: entry.detail)
    }
}
