import Foundation

/// ESS-655（F6）：Watch **电话模式**（ESS-634 交互设计稿 v2.0 的通话式交互，
/// 与 iPhone 侧无关，别和 `PhoneAgentClientLog` 混淆）的埋点契约。
///
/// 为什么要有这一层：现有 `session_*` 事件的 `detail` 是各调用点手拼的
/// `"turn_index=\(i) source=orb_tap"` 字符串。字段名拼错、少带一个必需字段、
/// 写出一个没人认识的 `source=`，编译期和运行期都不会有任何反应——直到
/// 事后按 `bridge.log` 算指标时才发现算不出来。ESS-655 验收标准 1 要求
/// 「必需字段缺失或非法 source 时可检测失败」，所以这里把**事件名、字段集、
/// 枚举取值、编码格式**收成唯一事实源：
///
/// - 写侧：功能代码只调类型化工厂（`enterRejected(...)` / `callSummary(...)`），
///   拼不出非法 detail；
/// - 读侧：`validate(event:detail:)` 校验来自设备日志的**外部输入**，缺字段 /
///   非法枚举 / 格式错都会抛出可断言的错误（`PhoneModeCallMetrics` 据此算指标）。
///
/// 本文件**只管事件的形状**，不持有任何会话状态——触发时机仍归各自的状态机
/// （F1/F2/F3/F4/F5），不另起第二个状态真相源（ESS-649 拆解口径）。
///
/// 事件与必需字段口径见 ESS-634 设计稿 §10.2；本文件是它的可执行副本。
/// 每个事件由谁在哪个 PR 接线，见 `Docs/ESS-655-phone-mode-telemetry.md`。
enum PhoneModeTelemetry {

    /// 电话模式事件统一落在 `session` module 下——与既有 `session_*` 同
    /// category，Bridge / WatchLogShipper 侧无需新增过滤器。
    static let module = "session"

    // MARK: - 事件

    /// ESS-634 §10.2 的 11 个新增事件 + 1 个扩字段事件。
    /// 只列**本期新增或改口径**的事件；沿用事件（§10.1）不在此重复定义，
    /// 避免给既有调用点制造一次无收益的大改。
    enum Event: String, CaseIterable {
        case failedNoticeShown   = "session_failed_notice_shown"
        case failedRetryTapped   = "session_failed_retry_tapped"
        case failedAutoHangup    = "session_failed_auto_hangup"
        case thinkingSlow        = "session_thinking_slow"
        case idleHint            = "session_idle_hint"
        case idleHangup          = "session_idle_hangup"
        case backgroundCap       = "session_background_cap"
        case callSummary         = "session_call_summary"
        case enterRejected       = "session_enter_rejected"
        case speakingInterrupted = "session_speaking_interrupted"
        case bargeInSelfEcho     = "session_barge_in_self_echo"
        case voiceBargeInGate    = "voice_barge_in_gate"
    }

    // MARK: - 枚举字段取值

    /// 失败原因。对应设计稿异常链 E1–E15 里会进 P6 的那几条。
    /// 新增失败路径时在这里加 case——不加就过不了 `validate`，这是刻意的：
    /// 一个没登记的 reason 会让「失败停留转化」这类指标静默漏算。
    enum FailureReason: String, CaseIterable {
        case readyTimeout     = "ready_timeout"      // E1 接通 5s 无 ack
        case recorderStart    = "recorder_start"     // E2 录音启动失败
        case micPermission    = "mic_permission"     // E3 无麦克风权限
        case channelEvent     = "channel_event"      // E4 会话中上行失败
        case thinkingTimeout  = "thinking_timeout"   // E6 思考 45s 未起播
        case systemInterrupt  = "system_interrupt"   // E14 来电等硬中断
        case backgroundCap    = "background_cap"     // E15 后台上限
    }

    /// 失败发生时所处的相位（P1–P5），用于区分「没接通」和「聊到一半断了」。
    enum Phase: String, CaseIterable {
        case connecting
        case listening
        case thinking
        case speaking
    }

    /// P6 失败文案 id。文案本身在视图层，这里只留稳定 id——指标按 id 聚合，
    /// 改文案不该让历史数据断档。
    enum CopyID: String, CaseIterable {
        case cannotConnect  = "cannot_connect"   // 连不上，检查一下 iPhone 是否在身边
        case micUnavailable = "mic_unavailable"  // 麦克风用不了
        case micPermission  = "mic_permission"   // 需要麦克风权限才能通话
        case connectionLost = "connection_lost"  // 连接断了，要再打一次吗？
        case noAnswer       = "no_answer"        // 没等到回答，要再说一次吗？
        case interrupted    = "interrupted"      // 通话被打断了，要再打一次吗？
        case endedBySystem  = "ended_by_system"  // 通话被系统结束了，要再打一次吗？
    }

    /// 打断触发源。ESS-655 验收标准 2 的核心字段：语音打断（F2）与点球打断
    /// 必须在同一事件里可区分，否则误触发率算不出来。
    enum InterruptSource: String, CaseIterable {
        case voice
        case orbTap = "orb_tap"
    }

    /// 语音打断 gate 状态。默认 OFF（ESS-650 口径）。
    enum GateState: String, CaseIterable {
        case on
        case off
    }

    /// gate 状态变化的来由——启动快照和「因为误触发被强制关回去」必须能分开，
    /// 否则「gate 开启门槛」这条指标会把两者混成一个数。
    enum GateReason: String, CaseIterable {
        case launchSnapshot    = "launch_snapshot"
        case userToggle        = "user_toggle"
        case aecUnavailable    = "aec_unavailable"
        case falseTriggerGuard = "false_trigger_guard"
    }

    /// 静默提示档位。设计稿 E11/E12：第 1 档「还在听，说话就行」，
    /// 第 2 档「还在吗？」+ 触觉。
    enum IdleHintLevel: Int, CaseIterable {
        case first = 1
        case second = 2
    }

    /// 待机屏进入被拒的原因。目前只有「按太久」一种（F1 移除长按语义后，
    /// 长按松手不再有任何提交语义，但必须留证，否则用户按了没反应等于黑洞）。
    enum EnterRejectReason: String, CaseIterable {
        case holdTooLong = "hold_too_long"
    }

    /// 通话结束原因。P7 必经，每条结束路径都要能对上一个 case——
    /// 「无提示消失率」指标的分母就是这些路径。
    enum CallEndReason: String, CaseIterable {
        case userExit         = "user_exit"          // E16 点 X / 下滑
        case idleTimeout      = "idle_timeout"       // E13 静默 120s
        case failedAutoHangup = "failed_auto_hangup" // E17 P6 停留 15s
        case channelFailed    = "channel_failed"     // E4/E14 断链
        case backgroundCap    = "background_cap"     // E15 后台上限
    }

    // MARK: - 记录

    /// 一条待写入的事件。`detail` 已经是 `WatchLog` 的 `k=v k=v` 格式，
    /// 调用点直接交给 `WatchLog.record(_:requestId:)`。
    struct Record: Equatable {
        let event: String
        let detail: String
    }

    // MARK: - 字段规格（校验的唯一依据）

    struct FieldSpec: Equatable {
        enum Kind: Equatable {
            /// 取值必须落在给定字符串集合内（枚举字段）。
            case oneOf([String])
            /// 取值必须落在给定整数集合内。
            case intOneOf([Int])
            /// 非负整数（毫秒、计数、序号）。
            case nonNegativeInt
            /// 十进制数，可为负（能量 dB）。
            case decimal
            /// 自由标识符（conversation_id 等），只要求非空且字符合法。
            case token
        }

        let name: String
        let kind: Kind
        let isRequired: Bool

        static func required(_ name: String, _ kind: Kind) -> FieldSpec {
            FieldSpec(name: name, kind: kind, isRequired: true)
        }

        static func optional(_ name: String, _ kind: Kind) -> FieldSpec {
            FieldSpec(name: name, kind: kind, isRequired: false)
        }
    }

    // MARK: - 错误

    enum ValidationError: Error, Equatable {
        /// 事件名不在契约内。
        case unknownEvent(String)
        /// detail 不是 `k=v` 序列（缺 `=`、空键、空值）。
        case malformedDetail(token: String)
        /// 同一个键出现两次——两个不同的值哪个算数无法判定，直接拒。
        case duplicateField(String)
        /// 必需字段缺失。
        case missingField(event: String, field: String)
        /// 枚举取值非法 / 数值格式不对。
        case illegalValue(field: String, value: String)
        /// 出现了契约里没有的字段。宽松处理：默认允许，仅在
        /// `validate(..., rejectsUnknownFields: true)` 下报出。
        case unknownField(event: String, field: String)
    }
}

// MARK: - 每个事件的字段表

extension PhoneModeTelemetry.Event {

    /// 字段顺序即编码顺序——同一个事件在任何调用点产出的 detail 字节一致，
    /// 便于 grep 和逐字节对账。
    var fields: [PhoneModeTelemetry.FieldSpec] {
        switch self {
        case .failedNoticeShown:
            return [
                .required("reason", .oneOf(PhoneModeTelemetry.FailureReason.allValues)),
                .required("from_phase", .oneOf(PhoneModeTelemetry.Phase.allValues)),
                .required("copy_id", .oneOf(PhoneModeTelemetry.CopyID.allValues)),
            ]
        case .failedRetryTapped:
            return [
                .required("reason", .oneOf(PhoneModeTelemetry.FailureReason.allValues)),
                .required("dwell_ms", .nonNegativeInt),
            ]
        case .failedAutoHangup:
            return [
                .required("reason", .oneOf(PhoneModeTelemetry.FailureReason.allValues)),
                .optional("dwell_ms", .nonNegativeInt),
            ]
        case .thinkingSlow:
            return [
                .required("turn_index", .nonNegativeInt),
                .optional("elapsed_ms", .nonNegativeInt),
            ]
        case .idleHint:
            return [
                .required("level", .intOneOf(PhoneModeTelemetry.IdleHintLevel.allCases.map(\.rawValue))),
                .optional("silent_ms", .nonNegativeInt),
            ]
        case .idleHangup:
            return [
                .required("turns", .nonNegativeInt),
                .optional("silent_ms", .nonNegativeInt),
            ]
        case .backgroundCap:
            return [
                .required("duration_ms", .nonNegativeInt),
            ]
        case .callSummary:
            return [
                .required("turns", .nonNegativeInt),
                .required("duration_ms", .nonNegativeInt),
                .required("end_reason", .oneOf(PhoneModeTelemetry.CallEndReason.allValues)),
                // conversation_id 的唯一铸造点是 `ConversationHandle`（构造即生成
                // UUIDv7，不依赖网络），touch-down 起就已存在——所以即便这一通
                // 从没接通，id 也是拿得到的，设计稿把它列为必带成立。
                // 真遇到取不到 id 的路径，按 R-01.2 提子单，不许现编一个。
                .required("conversation_id", .token),
            ]
        case .enterRejected:
            return [
                .required("reason", .oneOf(PhoneModeTelemetry.EnterRejectReason.allValues)),
                .required("hold_ms", .nonNegativeInt),
            ]
        case .speakingInterrupted:
            return [
                .optional("turn_index", .nonNegativeInt),
                .required("source", .oneOf(PhoneModeTelemetry.InterruptSource.allValues)),
                // 点球路径 detect_ms 恒为 0（点下去即判定，没有检测过程），
                // 语音路径是「起说 → 判定命中」的真实耗时。两者共用字段，
                // 指标侧按 source 分开统计。
                .required("detect_ms", .nonNegativeInt),
                .required("stop_ms", .nonNegativeInt),
            ]
        case .bargeInSelfEcho:
            return [
                .required("turn_index", .nonNegativeInt),
                .required("energy_db", .decimal),
            ]
        case .voiceBargeInGate:
            return [
                .required("state", .oneOf(PhoneModeTelemetry.GateState.allValues)),
                .required("reason", .oneOf(PhoneModeTelemetry.GateReason.allValues)),
            ]
        }
    }

    var requiredFields: [String] {
        fields.filter(\.isRequired).map(\.name)
    }
}

/// 枚举字段的合法取值集合统一从 `allCases` 推导——加一个 case 就自动进
/// 白名单，不会出现「枚举加了、校验表忘了改」的漂移。
private extension CaseIterable where Self: RawRepresentable, RawValue == String {
    static var allValues: [String] { allCases.map(\.rawValue) }
}

// MARK: - 写侧：类型化工厂

extension PhoneModeTelemetry {

    /// F3：进入 P6 失败态并显示文案。**这是「用户看见失败」的记账点**，
    /// 与「失败发生」（`session_channel_failed` 等）分开——设计稿的
    /// 「无提示消失率」比的就是这两者的差。
    static func failedNoticeShown(
        reason: FailureReason, fromPhase: Phase, copyID: CopyID
    ) -> Record {
        encode(.failedNoticeShown, [
            ("reason", reason.rawValue),
            ("from_phase", fromPhase.rawValue),
            ("copy_id", copyID.rawValue),
        ])
    }

    /// F3：P6 点重试。`dwell_ms` = 从进入 P6 到点下去的停留时长，
    /// 「失败停留转化」指标的原料。
    static func failedRetryTapped(reason: FailureReason, dwellMs: Int) -> Record {
        encode(.failedRetryTapped, [
            ("reason", reason.rawValue),
            ("dwell_ms", clampNonNegative(dwellMs)),
        ])
    }

    /// F3：P6 停留 15s 无操作自动挂断（E17）。
    static func failedAutoHangup(reason: FailureReason, dwellMs: Int) -> Record {
        encode(.failedAutoHangup, [
            ("reason", reason.rawValue),
            ("dwell_ms", clampNonNegative(dwellMs)),
        ])
    }

    /// F3：思考软提示（E5，25s）。带 `elapsed_ms` 才能事后校准阈值——
    /// 只记「提示出现过」无法回答「阈值该不该改」。
    static func thinkingSlow(turnIndex: Int, elapsedMs: Int) -> Record {
        encode(.thinkingSlow, [
            ("turn_index", clampNonNegative(turnIndex)),
            ("elapsed_ms", clampNonNegative(elapsedMs)),
        ])
    }

    /// F3：聆听静默提示（E11/E12）。阈值以白梦林决策 4 为准（30s / 75s），
    /// 设计稿 §10.2 表里的 20s/60s 是改前的旧值。
    static func idleHint(level: IdleHintLevel, silentMs: Int) -> Record {
        encode(.idleHint, [
            ("level", String(level.rawValue)),
            ("silent_ms", clampNonNegative(silentMs)),
        ])
    }

    /// F3：静默挂断（E13，120s）。
    static func idleHangup(turns: Int, silentMs: Int) -> Record {
        encode(.idleHangup, [
            ("turns", clampNonNegative(turns)),
            ("silent_ms", clampNonNegative(silentMs)),
        ])
    }

    /// F3：后台运行上限到达（E15）。
    static func backgroundCap(durationMs: Int) -> Record {
        encode(.backgroundCap, [
            ("duration_ms", clampNonNegative(durationMs)),
        ])
    }

    /// F3：进入 P7 的通话小结。**每通有且只有一条**——重复一条就说明有
    /// 第二个结束路径在自说自话（验收标准 3 显式盯这一点）。
    static func callSummary(
        turns: Int, durationMs: Int, endReason: CallEndReason, conversationID: String
    ) -> Record {
        encode(.callSummary, [
            ("turns", clampNonNegative(turns)),
            ("duration_ms", clampNonNegative(durationMs)),
            ("end_reason", endReason.rawValue),
            ("conversation_id", conversationID),
        ])
    }

    /// F1/F5：待机屏长按松手被拒（不提交、不进电话）。
    static func enterRejected(reason: EnterRejectReason = .holdTooLong, holdMs: Int) -> Record {
        encode(.enterRejected, [
            ("reason", reason.rawValue),
            ("hold_ms", clampNonNegative(holdMs)),
        ])
    }

    /// F2/F4：打断命中。`detectMs` 点球恒 0；语音路径填「起说 → 判定命中」耗时。
    /// `stopMs` 是「判定命中 → 本地停播动作返回」的耗时，两个数分开才能定位
    /// 慢在检测还是慢在停播。
    static func speakingInterrupted(
        source: InterruptSource, detectMs: Int, stopMs: Int, turnIndex: Int?
    ) -> Record {
        var values: [(String, String)] = []
        if let turnIndex { values.append(("turn_index", clampNonNegative(turnIndex))) }
        values.append(("source", source.rawValue))
        values.append(("detect_ms", clampNonNegative(detectMs)))
        values.append(("stop_ms", clampNonNegative(stopMs)))
        return encode(.speakingInterrupted, values)
    }

    /// F2：判定为自身回声导致的误触发。gate 默认 ON 的门槛就是这条计数为 0。
    static func bargeInSelfEcho(turnIndex: Int, energyDB: Double) -> Record {
        encode(.bargeInSelfEcho, [
            ("turn_index", clampNonNegative(turnIndex)),
            ("energy_db", format(energyDB)),
        ])
    }

    /// F2：gate 状态快照 / 变化。
    static func voiceBargeInGate(state: GateState, reason: GateReason) -> Record {
        encode(.voiceBargeInGate, [
            ("state", state.rawValue),
            ("reason", reason.rawValue),
        ])
    }

    // MARK: 编码

    private static func encode(_ event: Event, _ values: [(String, String)]) -> Record {
        Record(
            event: event.rawValue,
            detail: values.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        )
    }

    private static func clampNonNegative(_ value: Int) -> String {
        String(max(0, value))
    }

    /// 固定一位小数、不随 locale 变化（逗号小数点会当场把 `decimal` 校验打挂）。
    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        return String(format: "%.1f", value)
    }
}

// MARK: - 读侧：校验（外部输入）

extension PhoneModeTelemetry {

    /// 合法的键 / 值字符集。空格是字段分隔符、`=` 是键值分隔符，
    /// 出现在值里会让整条 detail 无法无歧义解析，一律拒收。
    private static let allowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:+"
    )

    /// 把 `k=v k=v` 解析成字典。**不**做事件级校验，只保证格式本身可解析。
    static func fields(in detail: String?) throws -> [String: String] {
        guard let detail, !detail.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for token in detail.split(separator: " ", omittingEmptySubsequences: true) {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ValidationError.malformedDetail(token: String(token))
            }
            let key = String(parts[0])
            let value = String(parts[1])
            guard !key.isEmpty, !value.isEmpty,
                  key.unicodeScalars.allSatisfy(allowedCharacters.contains),
                  value.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
                throw ValidationError.malformedDetail(token: String(token))
            }
            guard result[key] == nil else {
                throw ValidationError.duplicateField(key)
            }
            result[key] = value
        }
        return result
    }

    /// 校验一条**外部输入**的事件（真机 / 模拟器日志、Bridge 回传）。
    /// 通过则返回解析出的字段，供指标计算直接使用。
    ///
    /// - Parameter rejectsUnknownFields: 默认 false。日志里多带一个诊断字段
    ///   不该让整条记录作废；契约回归测试则打开它，防止字段悄悄漂移。
    @discardableResult
    static func validate(
        event: String, detail: String?, rejectsUnknownFields: Bool = false
    ) throws -> [String: String] {
        guard let known = Event(rawValue: event) else {
            throw ValidationError.unknownEvent(event)
        }
        let parsed = try fields(in: detail)
        let specs = known.fields

        for spec in specs {
            guard let raw = parsed[spec.name] else {
                if spec.isRequired {
                    throw ValidationError.missingField(event: event, field: spec.name)
                }
                continue
            }
            guard matches(raw, spec.kind) else {
                throw ValidationError.illegalValue(field: spec.name, value: raw)
            }
        }

        if rejectsUnknownFields {
            let names = Set(specs.map(\.name))
            for key in parsed.keys.sorted() where !names.contains(key) {
                throw ValidationError.unknownField(event: event, field: key)
            }
        }
        return parsed
    }

    /// `validate` 的便捷重载——校验本进程刚编码出来的记录（契约自检用）。
    @discardableResult
    static func validate(_ record: Record, rejectsUnknownFields: Bool = true) throws -> [String: String] {
        try validate(event: record.event, detail: record.detail, rejectsUnknownFields: rejectsUnknownFields)
    }

    private static func matches(_ raw: String, _ kind: FieldSpec.Kind) -> Bool {
        switch kind {
        case .oneOf(let allowed):
            return allowed.contains(raw)
        case .intOneOf(let allowed):
            guard let value = Int(raw) else { return false }
            return allowed.contains(value)
        case .nonNegativeInt:
            guard let value = Int(raw) else { return false }
            return value >= 0
        case .decimal:
            return Double(raw) != nil
        case .token:
            return !raw.isEmpty
        }
    }
}
