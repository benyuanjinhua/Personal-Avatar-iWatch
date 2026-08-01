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

    var id: String { requestId }
    var currentState: VoiceTurnState { events.last?.state ?? .recorded }
    var phase: VoiceTurnPhase { currentState.phase(failureStage: failureStage) }
    var isActive: Bool { !currentState.isTerminal }
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
        append(state: state, requestId: requestId, detail: detail, at: at, failureStage: nil)
    }

    /// 入账 iPhone 转发来的状态事件；校验失败或不允许的转移（乱序/重复/终态之后）会被丢弃。
    @discardableResult
    func apply(_ envelope: VoiceStatusEnvelope) -> Bool {
        guard envelope.validate() == nil else { return false }
        // Watch 重装/清数据后收到状态事件：补建回合，保证仍能恢复展示。
        if !turns.contains(where: { $0.requestId == envelope.requestId }) {
            begin(requestId: envelope.requestId, at: envelope.occurredAt)
        }
        let applied = append(
            state: envelope.state,
            requestId: envelope.requestId,
            detail: envelope.detail,
            at: envelope.occurredAt,
            failureStage: envelope.failureStage
        )
        guard applied, let index = turns.firstIndex(where: { $0.requestId == envelope.requestId }) else {
            return applied
        }
        if let permission = envelope.permission {
            turns[index].permission = permission
        }
        if let result = envelope.result {
            turns[index].result = result
        }
        save()
        // 纯文本降级（ESS-48）：结果没有配套语音（speech_sha256 为空），不会有
        // transferFile / attachSpeech 后续，在这里按 request_id 通知展示全文。
        if envelope.state == .completed, let result = envelope.result, result.speechSha256 == nil {
            onResultWithoutSpeech?(envelope.requestId)
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

    /// 按 request_id 查找回合（结果语音定向交付用）。
    func turn(withId requestId: String) -> VoiceTurnRecord? {
        turns.first(where: { $0.requestId == requestId })
    }

    /// 结果语音已加密落盘。
    func attachSpeech(requestId: String, fileName: String) {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return }
        turns[index].speechFileName = fileName
        save()
        onSpeechAttached?(requestId)
    }

    /// 结果语音已播放交付（文件删除由调用方负责）。
    func clearSpeech(requestId: String) {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return }
        turns[index].speechFileName = nil
        save()
    }

    func clear() {
        turns = []
        try? fileManager.removeItem(at: fileURL)
    }

    private func append(
        state: VoiceTurnState,
        requestId: String,
        detail: String?,
        at: Date,
        failureStage: VoiceFailureStage?
    ) -> Bool {
        guard let index = turns.firstIndex(where: { $0.requestId == requestId }) else { return false }
        let current = turns[index].currentState
        guard current.canTransition(to: state) else { return false }
        turns[index].events.append(VoiceTurnEvent(state: state, at: at, detail: detail))
        if state == .failed {
            turns[index].failureStage = failureStage ?? .inferred(from: current)
        }
        save()
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
