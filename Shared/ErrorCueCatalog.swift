import Foundation

/// ESS-180 / ESS-257：Bridge 稳定 `ERR_*` → 拟人化错误提示（文字 + 语音片段名 + 触觉 + 恢复族）。
///
/// 白梦林拍板：错误必须**语音 + 文字**回给用户，屏幕不再压掉失败终态。
/// 目录在 Shared 里，是因为 iPhone Relay/单元测试也要按 code 走同一份文案，
/// 避免各处硬编码分叉。语音片段真正加载 / 播放 / 降级由 Watch 的
/// `AvatarErrorPresenter` 负责——这里只维护「查表」这一件事，纯数据。
///
/// 灰度约定：`clip` 为 nil 表示无预置语音、只走文字 + 触觉；`ErrorCueCatalog.cue`
/// 对未知错误码回落到 `.generic`，绝不返回 nil——「静音吞错」是本 issue 的
/// 头号红线，从 API 形状层杜绝。180-B 起，5 条 m4a 已就位；播放失败仍会
/// 自动降级到「文字 + 触觉」，卡片露出「静音提醒」小字。
///
/// ESS-257：新增 `recoveryFamily` 字段（对应 D2.1 恢复族 A/B/C/D/E/F/G/H），
/// UI 层不得再散写 `if code == ...`——是否显示「重试」按钮由 catalog 说了算。
struct ErrorCueEntry: Equatable {
    /// Bridge 侧稳定错误码，`ERR_*` 前缀；tests 依赖这个字符串完整。
    let code: String
    /// 屏幕分身卡片主文案（≤ 30 汉字，watchOS 顶部条能一屏显示完）。
    let text: String
    /// 语音资产文件名（不含扩展名）；nil = 无预置语音，只走文字 + 触觉。
    let clip: String?
    /// D2.1 恢复族：决定 UI 呈现「知道了/重试/看文字/重播」哪一个动作。
    /// 视图层通过 `recoveryFamily.allowsCachedRetry` 决定是否露出「重试」按钮，
    /// 禁止在视图里按 code 硬编码分支。
    let recoveryFamily: RecoveryFamily
}

/// D2.1 恢复族分类。文档见附件 `iWatch交互设计-D1-D5-20260804.md` D2.1。
enum RecoveryFamily: String, Equatable {
    /// A · 重说：问题出在这次录音本身，缓存无用，用户必须重录
    case reRecord
    /// B · 重试：录音没问题，链路/执行失败，可用缓存录音重发
    case retry
    /// C · 等一下：对端忙 / 限流，稍后再叫
    case waitAndRetry
    /// D · 去授权：权限缺失，重说/重试都无用
    case authorize
    /// E · 看文字：语音丢了、文字还在
    case textOnly
    /// F · 重播：语音在、播出去失败
    case replay
    /// G · 静默降级：不上卡片，仅日志
    case silent
    /// H · 去 Mac 上确认（v1.1 新增）：执行结果未知，重跑有重复副作用
    /// 风险，**禁止出现重试按钮**。ESS-257 引入。
    case manualConfirm

    /// UI 是否允许出「重试（不用重新说）」按钮。
    ///
    /// ESS-257 首版只关闭族 H 的重试按钮——这是本 issue 白梦林点头的唯一
    /// UX 收紧。族 A/C 严格按 D2 也不应给「重试缓存录音」按钮（缓存对它们
    /// 没用/没意义），但那是另一格 UX 变更，本 PR 不动，避免与既有回合的
    /// 用户预期冲突（TODO：见 D2.1 恢复族全量落地跟进单）。
    var allowsCachedRetry: Bool {
        switch self {
        case .manualConfirm:
            return false
        case .reRecord, .retry, .waitAndRetry, .authorize, .textOnly, .replay, .silent:
            return true
        }
    }
}

enum ErrorCueCatalog {
    /// 兜底文案 —— 未映射的错误码/无 code 的失败仍要说话，不允许静默。
    /// D2 E-99：族 B，允许一键重试。
    static let generic = ErrorCueEntry(
        code: "GENERIC",
        text: "刚才没成功，你可以再说一次。",
        clip: "ErrorCue_Generic",
        recoveryFamily: .retry
    )

    /// code → 文案 + 语音 + 触觉。同一「重说一次」意图的多个 realtime 错误
    /// 共享同一条语音提示（用户视角只需要知道「刚才那句我卡了一下」）。
    static func cue(for code: String?) -> ErrorCueEntry {
        guard let code, !code.isEmpty else { return generic }
        switch code {
        case "ERR_AUDIO_TOO_SHORT":
            return ErrorCueEntry(
                code: code,
                text: "刚才没听清，是不是碰到了？多按一会儿再说一遍。",
                clip: "ErrorCue_AudioTooShort",
                recoveryFamily: .reRecord
            )
        case "ERR_TRANSCRIPT_DISCARDED":
            return ErrorCueEntry(
                code: code,
                text: "话有点糊，麻烦离麦近一点再说一次。",
                clip: "ErrorCue_TranscriptDiscarded",
                recoveryFamily: .reRecord
            )
        case "ERR_VOICE_BUSY":
            return ErrorCueEntry(
                code: code,
                text: "抱歉，我这边有人正在说话，稍后再叫我一下。",
                clip: "ErrorCue_VoiceBusy",
                recoveryFamily: .waitAndRetry
            )
        // 三个 realtime 停摆错误码用户感知一致：都是「那句没通」，共享同一条语音。
        case "ERR_REALTIME_STALLED",
             "ERR_REALTIME_NO_EVENTS",
             "ERR_REALTIME_TIMEOUT":
            return ErrorCueEntry(
                code: code,
                text: "刚才那句我卡了一下，麻烦你再说一次。",
                clip: "ErrorCue_RealtimeStalled",
                recoveryFamily: .reRecord
            )
        // ESS-257 · D2 E-18：Mac 不可达族——Bridge 主动上抛的 upstream 不可达 +
        // iPhone Relay 侧的传输/回包异常（ESS-253 已让后两者带码到达 Watch）。
        // 用户视角相同：Mac 那边没人应答，缓存录音可原样重发。
        //
        // 语音资产：D2.2 v1.1 归入 `ErrorCue_Retryable`（新增语音清单，尚未落
        // 包）；在 m4a 就位前 `clip: nil` 走「文字 + 触觉」降级，卡片自带
        // 「静音提醒」小字，绝不静音吞错——避免装机后 clip 缺失导致语音路径
        // 悄悄跑到未知资源加载。
        case "ERR_UPSTREAM_UNAVAILABLE",
             "ERR_TRANSPORT",
             "ERR_BAD_RESPONSE":
            return ErrorCueEntry(
                code: code,
                text: "Mac 那边没应答。确认助手在运行，点重试不用重新说。",
                clip: nil,
                recoveryFamily: .retry
            )
        // ESS-257 · D2 E-26：Mac 找不到这次任务（gateway/taskwatch 均可能抛）。
        // 缓存录音可重投；文案强调「重新交一次」区别于普通重试。
        case "ERR_TASK_NOT_FOUND":
            return ErrorCueEntry(
                code: code,
                text: "Mac 那边找不到这件事了，点重试我重新交一次。",
                clip: nil,
                recoveryFamily: .retry
            )
        // ESS-257 · D2 E-11：Mac 侧任务落到 failed 终态（脚本/工具报错等）。
        // 缓存录音可原样重发一次，也许上游临时故障。
        case "ERR_TASK_FAILED":
            return ErrorCueEntry(
                code: code,
                text: "这件事我没办成，点重试再跑一次，不用重新说。",
                clip: nil,
                recoveryFamily: .retry
            )
        // ESS-257 · D2 E-28（族 H）：Bridge 明确「不知道做完没有」
        // （`manual_confirmation_required`）。**禁止重试按钮**——重跑一个可能
        // 已生效的写操作等于重复执行。Bridge 侧 `isAutomaticallyRetryableTerminalError`
        // 已按此语义关掉自动重试；Watch 侧同步关掉用户可见的重试入口。
        //
        // 语音资产：D2.2 v1.1 归入 `ErrorCue_ManualConfirm`，同样待落包；在
        // m4a 就位前走「文字 + 触觉」降级，卡片露出「静音提醒」小字。
        case "ERR_RESULT_UNKNOWN":
            return ErrorCueEntry(
                code: code,
                text: "这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。",
                clip: nil,
                recoveryFamily: .manualConfirm
            )
        default:
            // 其他 ERR_*（ERR_WORK_TIMEOUT / ERR_PROCESSING_FAILED / …）走通用文案，
            // 但 code 保留在 entry.code 里以便日志追溯——用户看到的还是「刚才没成功」，
            // 后台错误码从不裸露到 UI。族按 E-99 走 .retry。
            return ErrorCueEntry(
                code: code,
                text: generic.text,
                clip: generic.clip,
                recoveryFamily: generic.recoveryFamily
            )
        }
    }

    /// 所有目录内独立语音片段的资源名（去重后），用于 Bundle 存在性校验。
    ///
    /// ESS-257 新增码（UPSTREAM_UNAVAILABLE / TRANSPORT / BAD_RESPONSE /
    /// TASK_NOT_FOUND / TASK_FAILED / RESULT_UNKNOWN）暂用 `clip: nil` 走
    /// 「文字 + 触觉」降级通路，不列在这里——`ErrorCue_Retryable` /
    /// `ErrorCue_ManualConfirm` 两条 m4a 由后续视觉资产单交付；那单落地时
    /// 把上面的 `clip: nil` 换成真名，并把资源名追加到本清单。
    static var allClipNames: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in [
            cue(for: "ERR_AUDIO_TOO_SHORT"),
            cue(for: "ERR_TRANSCRIPT_DISCARDED"),
            cue(for: "ERR_VOICE_BUSY"),
            cue(for: "ERR_REALTIME_STALLED"),
            generic,
        ] {
            guard let clip = entry.clip, !seen.contains(clip) else { continue }
            seen.insert(clip)
            ordered.append(clip)
        }
        return ordered
    }
}
