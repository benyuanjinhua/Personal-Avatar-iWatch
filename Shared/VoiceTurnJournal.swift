import Combine
import Foundation
import os

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
    /// ESS-317 历史对话：父轮次的 request_id（再次对话产生的新轮次）。
    /// nil = 顶级轮次，非 nil = 从父轮次「再次对话」而来，在历史中缩进挂在父轮下。
    var parentRequestId: String?
    /// ESS-317 历史对话：再次对话时携带的上下文摘要（上一轮的问 + 答文本首行），
    /// 展示在①屏球体旁「续：<摘要>」。非持久字段，由 PushToTalkController 在
    /// begin 后注入；保存时编码进 voice-turns.json。
    var contextText: String?
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
    /// completed 之后独立到达的结果语音降级码；不改变 turn 终态。
    var resultAudioErrorCode: String? = nil
    /// ESS-307 / Gap-6：下行投递状态。nil = 未知，true = 已送达 Watch，false = 仍在 iPhone 队列。
    /// 由 Gap-6 折叠逻辑写入，供时间线「待手动重播」标识消费。
    var downlinkDelivered: Bool? = nil

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
    private let onStorageFailure: ((String) -> Void)?
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.shared", category: "VoiceTurnJournal"
    )

    init(directory: URL, maximumCount: Int = 10, onStorageFailure: ((String) -> Void)? = nil) {
        self.maximumCount = maximumCount
        self.onStorageFailure = onStorageFailure
        fileURL = directory.appendingPathComponent("voice-turns.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if
            let data = try? Data(contentsOf: fileURL),
            let saved = try? VoiceProtocolJSON.decoder.decode([VoiceTurnRecord].self, from: data)
        {
            // ESS-363：冷启动时清理超期活跃回合（跨进程重启存活的陈旧 hold），
            // 防止其反复触发 session_start_requested 并导致非 active 时 start() 崩溃。
            let (cleaned, staleIds) = Self.cleanupStaleTurns(saved)
            turns = cleaned
            if !staleIds.isEmpty {
                DispatchQueue.main.async { [staleIds] in
                    self.onStaleTurnsCleaned?(staleIds, "cold_start")
                }
            }
        } else {
            turns = []
        }
    }

    /// 最近一个未走到终态的回合；没有则回退到最近一个回合。
    var activeTurn: VoiceTurnRecord? {
        turns.first(where: \.isActive) ?? turns.first
    }

    /// 录音结束、生成信封后开一个新回合（初始状态 recorded）。同 request_id 已存在则忽略（幂等）。
    func begin(requestId: String, at: Date = Date(), parentRequestId: String? = nil, contextText: String? = nil) {
        guard !turns.contains(where: { $0.requestId == requestId }) else { return }
        let record = VoiceTurnRecord(
            requestId: requestId,
            createdAt: at,
            events: [VoiceTurnEvent(state: .recorded, at: at)],
            parentRequestId: parentRequestId,
            contextText: contextText
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
    var onResultAudioDegraded: ((String, String) -> Void)?
    /// ESS-363：冷启动时清理了超期活跃回合；参数为被清理的 request_id 列表 +
    /// 清理时的 scene_phase。供 Watch 层落冷启动可观测事件。
    var onStaleTurnsCleaned: (([String], String) -> Void)?

    @discardableResult
    func recordAudioDegradation(requestId: String, errorCode: String) -> Bool {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }),
              turns[index].currentState == .completed,
              turns[index].result != nil,
              turns[index].resultAudioErrorCode == nil else { return false }
        turns[index].resultAudioErrorCode = errorCode
        save()
        onResultAudioDegraded?(requestId, errorCode)
        return true
    }

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

    /// ESS-363：冷启动时清理超期活跃回合（阈值 10 分钟）。
    /// 跨进程重启存活的陈旧 hold 会在每次启动时被重新加载为 isActive 回合，
    /// 导致 RuntimeSessionPolicy 反复输出 turn_active hold → 非 active 时
    /// start() 崩溃。这里将其推进到 .cancelled 终态，同时回调供 Watch 层
    /// 落可观测日志（含被清理的 request_id 列表 + 当前 scene_phase）。
    /// 静态方法，因为 init 时必须完成清理才能给 turns 赋值。
    /// 返回 (cleanedTurns, staleIds)。
    private static func cleanupStaleTurns(_ loaded: [VoiceTurnRecord]) -> ([VoiceTurnRecord], [String]) {
        let staleThreshold: TimeInterval = 600 // 10 min
        let now = Date()
        var cleaned = loaded
        var staleIds: [String] = []
        for i in cleaned.indices where cleaned[i].isActive {
            if now.timeIntervalSince(cleaned[i].createdAt) > staleThreshold {
                cleaned[i].events.append(
                    VoiceTurnEvent(state: .cancelled, at: now, detail: "stale_turn_cleaned_on_cold_start")
                )
                staleIds.append(cleaned[i].requestId)
            }
        }
        if !staleIds.isEmpty {
            logger.info(
                "ESS-363 cleaned \(staleIds.count) stale active turns on cold start (threshold > \(Int(staleThreshold))s): \(staleIds.joined(separator: ","))"
            )
        }
        return (cleaned, staleIds)
    }

    private func trimAndSave() {
        if turns.count > maximumCount {
            let removed = turns.suffix(turns.count - maximumCount)
            turns.removeLast(turns.count - maximumCount)
            // ESS-317：trim 时通知调用方清理关联的加密音频文件
            removed.forEach { turn in
                onTurnEvicted?(turn)
            }
        }
        save()
    }

    /// ESS-317 历史对话留存：轮次被 trim 时的回调（供 PushToTalkController
    /// 清理 EncryptedAudioVault 中的对应语音文件）。
    var onTurnEvicted: ((VoiceTurnRecord) -> Void)?

    private static let retentionLogger = Logger(subsystem: "com.benyuan.wristagent.shared", category: "Retention")

    /// ESS-317：清理超过 24 小时的轮次。调用方应传入 vault 用于同步清理
    /// 加密音频文件。
    func evictExpiredAudio(vault: EncryptedAudioVault?, maxAge: TimeInterval = 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var toRemove: [VoiceTurnRecord] = []
        turns = turns.filter { turn in
            if turn.createdAt < cutoff {
                toRemove.append(turn)
                return false
            }
            return true
        }
        for turn in toRemove {
            if let fileName = turn.speechFileName {
                vault?.remove(name: fileName)
                Self.retentionLogger.info("audio_expired_evicted request_id=\(turn.requestId, privacy: .public) age_hours=\(String(format: "%.1f", Date().timeIntervalSince(turn.createdAt) / 3600)) file=\(fileName, privacy: .public)")
            }
        }
        if !toRemove.isEmpty {
            save()
        }
    }

    private func save() {
        do {
            let data = try VoiceProtocolJSON.encoder.encode(turns)
            try PersistHelper.writeAtomically(data, to: fileURL)
        } catch {
            onStorageFailure?("VoiceTurnJournal save: \(error.localizedDescription)")
        }
    }
}
