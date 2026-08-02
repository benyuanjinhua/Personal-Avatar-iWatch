import Foundation

/// ESS-58：播放连续性决策（纯函数，可单测）。
/// 背景：锁屏会以 resignedFrontmost 收回 ExtendedRuntimeSession，App 随即
/// 挂起，前台音频会话下播放被无声截断（真机取证：play_started 无对应
/// play_finished）。目标是播放永不静默丢失——要么走后台音频继续，要么回
/// 前台原位续播，要么保留「未播完」状态可重播，且界面有明确标记。
enum PlaybackRecoveryPolicy {
    /// 回前台时对当前播放的处置。
    enum ForegroundAction: Equatable {
        /// 没在播、或后台音频路径下声音一直在响：什么都不做。
        case none
        /// 播放标记还在但播放器已停（App 曾被挂起截断）：原位续播。
        case resume
    }

    static func onForeground(hasActivePlayback: Bool, playerReportsPlaying: Bool) -> ForegroundAction {
        hasActivePlayback && !playerReportsPlaying ? .resume : .none
    }

    /// 一次播放走完（或没走完）后的收尾。
    enum FinishOutcome: Equatable {
        /// 未播完（截断/解码失败/续播失败）：语音留在加密仓、journal 不清
        /// speechFileName、不发交付 ACK——回合停在「未播完」，可重播。
        case retainForReplay
        /// interim 语音播完：删本地文件，但不算交付（ESS-45×ESS-46：终态
        /// 结果还在路上，grace 持有不能被跳过）。
        case deliverInterim
        /// 终态结果语音播完：删文件 + 记交付，持有理由随之解除。
        case deliverFinal
    }

    static func finishOutcome(finishedSuccessfully: Bool, turnIsTerminal: Bool) -> FinishOutcome {
        guard finishedSuccessfully else { return .retainForReplay }
        return turnIsTerminal ? .deliverFinal : .deliverInterim
    }
}
