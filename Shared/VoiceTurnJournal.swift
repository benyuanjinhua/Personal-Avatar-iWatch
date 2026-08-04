import Combine
import Foundation

/// 一次状态变更事件（时间线的一行）。
struct VoiceTurnEvent: Codable, Equatable {
    let state: VoiceTurnState
    let at: Date
    let detail: String?

    init(state: VoiceTurnState, at: Date = Date(), detail: String? = nil) {
        self.state = state
        self.at = at
        self.detail = detail
    }
}

/// 一次语音回合的完整记录：状态时间线 + 权限请求/决定 + 结果摘要 + 结果语音。
struct VoiceTurnRecord: Codable, Equatable, Identifiable {
    let requestId: String
    let createdAt: Date
    var events: [VoiceTurnEvent]
    var permission: VoicePermissionPayload?
    var permissionApproved: Bool?
    var result: VoiceResultPayload?
    var failureStage: VoiceFailureStage?
    /// 加密语音文件名（EncryptedAudioVault 内），播放交付后置空并删除文件。
    var speechFileName: String?
    /// Watch 收到并校验、加密落盘结果语音的本地时间。用于计算端侧音频 TTFT；
    /// optional 保持对旧版 voice-turns.json 的向后兼容。
    var speechAttachedAt: Date? = nil
    /// Watch 首次收到包含可展示文本的结果信封的本地时间（interim 或 final）。
    /// 必须与 createdAt 同属 Watch 时钟域，不能使用 Bridge 生成的 occurredAt。
    var firstResultAt: Date? = nil
    /// ESS-55 未读机制：结果首次被查看/播放的时间；nil = 未读。
    /// 结果在用户未查看前不丢失，下次打开仍以未读态呈现。
    var resultViewedAt: Date?
    /// ESS-180：failed 事件的 Bridge 稳定错误码（`ERR_*`）；成功回合恒为 nil。
    /// UI 拿它查 `ErrorCueCatalog` 决定拟人化文案与语音提示。
    var errorCode: String?
    /// ESS-259 B-STOP：用户主动点字幕区打断结果语音播放的时刻。设值不改
    /// 状态机（`currentState` 仍为 `.completed`）、不进 failure/cancelled 分支，
    /// 仅供时间线在完成事件之后追加一行「已打断」，保留语音供重播。
    var playbackInterruptedAt: Date? = nil

    var id: String { requestId }
    var currentState: VoiceTurnState { events.last?.state ?? .recorded }
    var phase: VoiceTurnPhase { currentState.phase(failureStage: failureStage) }
    var isActive: Bool { !currentState.isTerminal }
    /// 已完成、有结果、且用户还没看过。
    var hasUnreadResult: Bool {
        currentState == .completed && result != nil && resultViewedAt == nil
    }
}

/// 以 Watch 录音结束为起点的端侧延迟指标。只记录毫秒数和 request_id，
/// 不采集转写文本或音频内容，可直接从 watch_client_log 聚合 P50/P95。
struct VoiceTurnLatency: Equatable {
    let textTTFTMs: Int?
    let audioTTFTMs: Int?

    static func measure(_ turn: VoiceTurnRecord) -> VoiceTurnLatency {
        return VoiceTurnLatency(
            textTTFTMs: elapsedMilliseconds(from: turn.createdAt, to: turn.firstResultAt),
            audioTTFTMs: elapsedMilliseconds(from: turn.createdAt, to: turn.speechAttachedAt)
        )
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date?) -> Int? {
        guard let end else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}

/// 语音回合日志（ESS-29）：持久化到本地文件，
/// 退出页面后任务继续、重新打开可从这里恢复全部状态。
@MainActor
final class VoiceTurnJournal: ObservableObject {
    /// 新的在前。
    @Published private(set) var turns: [VoiceTurnRecord]

    private let fileURL: URL
    private let maximumCount: Int
    private let fileManager = FileManager.default

    init(directory: URL, maximumCount: Int = 20) {
        self.maximumCount = maximumCount
        fileURL = directory.appendingPathComponent("voice-turns.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if
            let data = try? Data(contentsOf: fileURL),
            let saved = try? VoiceProtocolJSON.decoder.decode([VoiceTurnRecord].self, from: data)
        {
            turns = saved
        } else {
            turns = []
        }
    }

    /// 最近一个未走到终态的回合；没有则回退到最近一个回合。
    var activeTurn: VoiceTurnRecord? {
        turns.first(where: \.isActive) ?? turns.first
    }

    /// 录音结束、生成信封后开一个新回合（初始状态 recorded）。同 request_id 已存在则忽略（幂等）。
    func begin(requestId: String, at: Date = Date()) {
        guard !turns.contains(where: { $0.requestId == requestId }) else { return }
        let record = VoiceTurnRecord(
            requestId: requestId,
            createdAt: at,
            events: [VoiceTurnEvent(state: .recorded, at: at)]
        )
        turns.insert(record, at: 0)
        trimAndSave()
    }

    /// Watch 本地产生的状态（发送阶段 / 用户取消）。
    @discardableResult
    func recordLocal(_ state: VoiceTurnState, requestId: String, detail: String? = nil, at: Date = Date()) -> Bool {
        append(state: state, requestId: requestId, detail: detail, at: at, failureStage: nil, errorCode: nil)
    }

    /// 入账 iPhone 转发来的状态事件；校验失败或不允许的转移（乱序/重复/终态之后）会被丢弃。
    ///
    /// ESS-180 / ESS-204：**必须在 append(...) 调用 onStateApplied 之前**把
    /// permission / result / errorCode 挂到回合上。旧路径先 append（内部
    /// fires onStateApplied） → 再写字段，PushToTalkController 的 failed
    /// 回调分支读到 nil errorCode 只能展示 generic 卡片，presenter 又按
    /// requestId 去重，永远无法纠正。
    @discardableResult
    func apply(_ envelope: VoiceStatusEnvelope) -> Bool {
        guard envelope.validate() == nil else { return false }
        // Watch 重装/清数据后收到状态事件：补建回合，保证仍能恢复展示。
        if !turns.contains(where: { $0.requestId == envelope.requestId }) {
            begin(requestId: envelope.requestId, at: envelope.occurredAt)
        }
        guard let index = turns.firstIndex(where: { $0.requestId == envelope.requestId }) else {
            return false
        }
        // ESS-204：先挂 payload、后 append（append 内部同步触发 onStateApplied
        // 时字段已就位）。permission/result/errorCode 只在能真正 transition 时
        // 才生效——append 返回 false 时下面回滚 turns[index] 的临时写。
        let priorPermission = turns[index].permission
        let priorResult = turns[index].result
        let priorFirstResultAt = turns[index].firstResultAt
        let priorErrorCode = turns[index].errorCode
        if let permission = envelope.permission {
            turns[index].permission = permission
        }
        if let result = envelope.result {
            turns[index].result = result
            if turns[index].firstResultAt == nil {
                turns[index].firstResultAt = Date()
            }
        }
        // 一旦落到 failed 就锁定 errorCode，后续同 request_id 的乱序事件不覆盖。
        if envelope.state == .failed, turns[index].errorCode == nil,
           let code = envelope.errorCode, !code.isEmpty {
            turns[index].errorCode = code
        }
        let applied = append(
            state: envelope.state,
            requestId: envelope.requestId,
            detail: envelope.detail,
            at: envelope.occurredAt,
            failureStage: envelope.failureStage,
            errorCode: nil  // 已在上面写入；append 只做状态机推进 + 触发回调
        )
        guard applied else {
            // 转移被拒（终态之后 / 重复 / 乱序）：回滚 payload 写入，回合状态
            // 与信封应用前一致，onStateApplied 未触发。
            turns[index].permission = priorPermission
            turns[index].result = priorResult
            turns[index].firstResultAt = priorFirstResultAt
            turns[index].errorCode = priorErrorCode
            return false
        }
        save()
        // 纯文本降级（ESS-48）：结果没有配套语音（speech_sha256 为空），不会有
        // transferFile / attachSpeech 后续，在这里按 request_id 通知展示全文。
        if envelope.state == .completed, let result = envelope.result, result.speechSha256 == nil {
            onResultWithoutSpeech?(envelope.requestId)
        }
        // 结果已入账（含摘要文本，ESS-55 通知链路）：与 onStateApplied 的区别是
        // 此刻 result 已经挂上——通知正文需要结果摘要，不能在状态回调里取。
        if envelope.state == .completed, envelope.result != nil {
            onResultRecorded?(envelope.requestId)
        }
        return true
    }

    /// 记录用户对权限请求的决定（UI 立即反馈；上行由 transport 负责）。
    func recordDecision(requestId: String, approved: Bool) {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return }
        turns[index].permissionApproved = approved
        save()
    }

    /// 结果语音落盘事件（ESS-41 B3）：attachSpeech 成功后按 request_id 回调。
    /// 播放触发由此驱动而非 UI onChange——语音是后到的（文字先行、transferFile
    /// 随后），到达时该回合可能已被新回合顶掉或已判终态，只盯 activeTurn 的
    /// UI 触发会静默漏播。
    var onSpeechAttached: ((String) -> Void)?

    /// 纯文本结果入账（completed 且 speech_sha256 为空，ESS-48 降级路径）：
    /// 语音永远不会到，直接展示全文，不进播放态。
    var onResultWithoutSpeech: ((String) -> Void)?

    /// 状态成功入账（本地或远端）后的回调（ESS-55）：触觉 cue 由此驱动而非 UI
    /// onChange——结果/失败到达时 App 可能熄屏或视图未挂载，只有事件层触发
    /// 才能保证「熄屏状态下结果到达能靠触觉感知」。
    var onStateApplied: ((String, VoiceTurnState) -> Void)?

    /// completed 且结果载荷已挂上后的回调（ESS-55 通知链路）。重复/乱序的
    /// completed 信封被状态机拒绝时不会触发（幂等第一层；通知记账是第二层）。
    var onResultRecorded: ((String) -> Void)?

    /// ESS-55 未读机制：最近一个未读结果（新的在前）。
    var firstUnreadResult: VoiceTurnRecord? {
        turns.first(where: \.hasUnreadResult)
    }

    /// 标记结果已读（首次查看/播放时调用；重复调用不覆盖首读时间）。
    func markResultViewed(requestId: String, at date: Date = Date()) {
        guard
            let index = turns.firstIndex(where: { $0.requestId == requestId }),
            turns[index].result != nil,
            turns[index].resultViewedAt == nil
        else { return }
        turns[index].resultViewedAt = date
        save()
    }

    /// 按 request_id 查找回合（结果语音定向交付用）。
    func turn(withId requestId: String) -> VoiceTurnRecord? {
        turns.first(where: { $0.requestId == requestId })
    }

    /// ESS-259 B-STOP：记录一次「用户点字幕区打断播放」。首次调用落时间戳并
    /// 持久化；重复调用幂等——同一次播放里连点两下不叠加。不改状态机、
    /// 不动 `speechFileName`（语音留仓可重播）、不派发 onStateApplied。
    @discardableResult
    func recordPlaybackInterrupted(requestId: String, at date: Date = Date()) -> Bool {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return false }
        guard turns[index].playbackInterruptedAt == nil else { return false }
        turns[index].playbackInterruptedAt = date
        save()
        return true
    }

    /// 结果语音已加密落盘。
    @discardableResult
    func attachSpeech(requestId: String, fileName: String, at date: Date = Date()) -> Bool {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return false }
        turns[index].speechFileName = fileName
        if turns[index].speechAttachedAt == nil {
            turns[index].speechAttachedAt = date
        }
        save()
        onSpeechAttached?(requestId)
        return true
    }

    /// 结果语音已播放交付（文件删除由调用方负责）。
    @discardableResult
    func clearSpeech(requestId: String, matching fileName: String? = nil) -> Bool {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return false }
        if let fileName, turns[index].speechFileName != fileName { return false }
        turns[index].speechFileName = nil
        save()
        return true
    }

    func clear() {
        turns = []
        try? fileManager.removeItem(at: fileURL)
    }

    /// ESS-204：`errorCode` 参数保留但已废弃——`apply(_:)` 在调用 append 前
    /// 直接写 `turns[index].errorCode`，确保 onStateApplied 触发时字段已就位。
    /// 保留参数只为不破坏 `recordLocal` 等其它调用点的签名（都传 nil）。
    private func append(
        state: VoiceTurnState,
        requestId: String,
        detail: String?,
        at: Date,
        failureStage: VoiceFailureStage?,
        errorCode: String?
    ) -> Bool {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return false }
        let current = turns[index].currentState
        guard current.canTransition(to: state) else { return false }
        turns[index].events.append(VoiceTurnEvent(state: state, at: at, detail: detail))
        if state == .failed {
            turns[index].failureStage = failureStage ?? .inferred(from: current)
        }
        if let errorCode, !errorCode.isEmpty, turns[index].errorCode == nil {
            turns[index].errorCode = errorCode
        }
        save()
        onStateApplied?(requestId, state)
        return true
    }

    private func trimAndSave() {
        if turns.count > maximumCount {
            turns.removeLast(turns.count - maximumCount)
        }
        save()
    }

    private func save() {
        guard let data = try? VoiceProtocolJSON.encoder.encode(turns) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
