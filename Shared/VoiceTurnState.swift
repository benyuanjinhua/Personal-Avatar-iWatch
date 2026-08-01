import Foundation

/// §6 语音回合状态机（ESS-29）。
/// recorded → waiting_for_phone → waiting_for_mac → accepted → realtime_processing
/// → background_accepted → background_processing ⇄ permission_required
/// → completed / failed / cancelled
enum VoiceTurnState: String, Codable, CaseIterable, Equatable {
    case recorded
    case waitingForPhone = "waiting_for_phone"
    case waitingForMac = "waiting_for_mac"
    case accepted
    case realtimeProcessing = "realtime_processing"
    case backgroundAccepted = "background_accepted"
    case backgroundProcessing = "background_processing"
    case permissionRequired = "permission_required"
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    /// 单调进度序号：正常流转只能向前，跳过中间态是允许的（例如手机可达时不经过 waiting_for_phone）。
    private var rank: Int {
        switch self {
        case .recorded: return 0
        case .waitingForPhone: return 1
        case .waitingForMac: return 2
        case .accepted: return 3
        case .realtimeProcessing: return 4
        case .backgroundAccepted: return 5
        case .backgroundProcessing: return 6
        case .permissionRequired: return 7
        case .completed, .failed, .cancelled: return 8
        }
    }

    /// 事件去重/乱序防御：终态吸收；重复状态丢弃；
    /// 唯一允许的回退是权限确认后回到后台执行（§6 permission_required ⇄ background_processing）。
    func canTransition(to next: VoiceTurnState) -> Bool {
        if isTerminal || next == self { return false }
        if next.isTerminal { return true }
        if self == .permissionRequired && next == .backgroundProcessing { return true }
        return next.rank > rank
    }

    /// 时间线里每个状态的用户可读标题。
    var displayTitle: String {
        switch self {
        case .recorded: return "已录音"
        case .waitingForPhone: return "等待手机连接"
        case .waitingForMac: return "已到手机，等待 Mac"
        case .accepted: return "Mac 已受理"
        case .realtimeProcessing: return "正在理解并处理"
        case .backgroundAccepted: return "后台任务已受理"
        case .backgroundProcessing: return "后台执行中"
        case .permissionRequired: return "需要你的确认"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var displaySymbol: String {
        switch self {
        case .recorded: return "waveform"
        case .waitingForPhone: return "iphone.slash"
        case .waitingForMac: return "desktopcomputer"
        case .accepted: return "checkmark.icloud"
        case .realtimeProcessing, .backgroundProcessing: return "gearshape.2"
        case .backgroundAccepted: return "tray.and.arrow.down"
        case .permissionRequired: return "exclamationmark.shield"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }
}

/// 失败阶段：验收要求失败原因可区分（等待手机 / 等待 Mac / 执行失败）。
enum VoiceFailureStage: String, Codable, Equatable {
    case phoneUnreachable = "waiting_for_phone"
    case macUnreachable = "waiting_for_mac"
    case execution

    var displayName: String {
        switch self {
        case .phoneUnreachable: return "失败：手机未连接"
        case .macUnreachable: return "失败：Mac 未响应"
        case .execution: return "执行失败"
        }
    }

    /// 每种失败环节的差异化恢复提示（ESS-53 §5）：失败不能只有红叉，必须给下一步。
    var recoveryHint: String {
        switch self {
        case .phoneUnreachable: return "靠近 iPhone 后会自动重发，也可点下方立即重试"
        case .macUnreachable: return "语音已在手机上，Mac 恢复后会继续；急的话按住重说一次"
        case .execution: return "按住语音球，再说一次"
        }
    }

    /// 从失败前最后一个状态推断失败阶段（信封未显式给出时的兜底）。
    static func inferred(from lastState: VoiceTurnState) -> VoiceFailureStage {
        switch lastState {
        case .recorded, .waitingForPhone: return .phoneUnreachable
        case .waitingForMac: return .macUnreachable
        default: return .execution
        }
    }
}

/// §6 状态机对用户的可读投影：已送达 / 处理中 / 需要确认 / 已完成 / 失败（+ 送达前的等待细分）。
enum VoiceTurnPhase: Equatable {
    case sending
    case waitingForPhone
    case waitingForMac
    case delivered
    case processing(background: Bool)
    case needsConfirmation
    case completed
    case failed(VoiceFailureStage)
    case cancelled

    var title: String {
        switch self {
        case .sending: return "正在送出"
        case .waitingForPhone: return "等待手机连接"
        case .waitingForMac: return "已到手机，等待 Mac"
        case .delivered: return "已送达"
        case .processing(let background): return background ? "后台处理中" : "处理中"
        case .needsConfirmation: return "需要确认"
        case .completed: return "已完成"
        case .failed(let stage): return stage.displayName
        case .cancelled: return "已取消"
        }
    }

    var subtitle: String {
        switch self {
        case .sending: return "录音已保存，正在发送到 iPhone"
        case .waitingForPhone: return "已排队，手机连上后自动送出"
        case .waitingForMac: return "任务在后台继续，可以先离开"
        case .delivered: return "Mac 已受理，等待处理"
        case .processing(let background):
            return background ? "退出页面任务也会继续" : "很快给你结果"
        case .needsConfirmation: return "未确认前不会执行"
        case .completed: return "点击可播放结果"
        case .failed(let stage): return stage.recoveryHint
        case .cancelled: return "需要时再叫我"
        }
    }
}

extension VoiceTurnState {
    /// 当前状态 → 用户可读投影；failed 时结合失败阶段。
    func phase(failureStage: VoiceFailureStage? = nil) -> VoiceTurnPhase {
        switch self {
        case .recorded: return .sending
        case .waitingForPhone: return .waitingForPhone
        case .waitingForMac: return .waitingForMac
        case .accepted: return .delivered
        case .realtimeProcessing: return .processing(background: false)
        case .backgroundAccepted, .backgroundProcessing: return .processing(background: true)
        case .permissionRequired: return .needsConfirmation
        case .completed: return .completed
        case .failed: return .failed(failureStage ?? .execution)
        case .cancelled: return .cancelled
        }
    }
}
