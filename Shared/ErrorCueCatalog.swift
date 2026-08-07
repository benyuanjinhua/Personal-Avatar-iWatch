import Foundation

/// ESS-180 / ESS-257 / ESS-262：Bridge 稳定 `ERR_*` → 拟人化错误提示
/// （文字 + 语音片段名 + 触觉 + 恢复族）。
///
/// 白梦林拍板：错误必须**语音 + 文字**回给用户，屏幕不再压掉失败终态。
/// 目录在 Shared 里，是因为 iPhone Relay/单元测试也要按 code 走同一份文案，
/// 避免各处硬编码分叉。语音片段真正加载 / 播放 / 降级由 Watch 的
/// `AvatarErrorPresenter` 负责——这里只维护「查表」这一件事，纯数据。
///
/// 灰度约定：`clip` 为 nil 表示无预置语音、只走文字 + 触觉；`ErrorCueCatalog.cue`
/// 对未知错误码回落到 `.generic`，绝不返回 nil——「静音吞错」是本 issue 的
/// 头号红线，从 API 形状层杜绝。
///
/// ESS-257：新增 `recoveryFamily` 字段（对应 D2.1 恢复族 A/B/C/D/E/F/G/H），
/// UI 层不得再散写 `if code == ...`——是否显示「重试」按钮由 catalog 说了算。
///
/// ESS-262：D2 v1.1 语气语音资产扩到 10 条。E-04（`ErrorCue_MicPermission`）、
/// E-10/E-11/E-18（`ErrorCue_Retryable`）、E-12（`ErrorCue_TextOnly`）、E-17
/// （`ErrorCue_PhoneUnreachable`）、E-28（`ErrorCue_ManualConfirm`）五条 m4a
/// 由 qwen-audio-realtime 生成入包；播放失败仍会自动降级到「文字 + 触觉」，
/// 卡片露出「静音提醒」小字。
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
    /// D2.0 原则 3：**恢复动作必须与错误成因匹配**。「重试（不用重新说）」
    /// 是族 B 的动作——用缓存录音原样重发。其余族的按钮语义都不是缓存重
    /// 发：A 走「知道了」（缓存录音本身有问题，重发只会再失败）；C 走
    /// 「知道了」（对端忙，立刻重试无意义）；D 走「怎么开」（权限缺失，
    /// 无论录音还是重试都被拦）；E 走「看文字」；F 走「重播」；G 不上卡片；
    /// H 走「知道了」（结果未知，重跑有重复副作用）。
    ///
    /// ESS-257 首版收紧 H；ESS-261 收紧 A/C 并把 D/E/F/G 一并对齐到语义正
    /// 确的位置——只有族 B 返回 true。视图层仍只读这一个字段，不按 code
    /// 硬编码分支。
    var allowsCachedRetry: Bool {
        self == .retry
    }
}

enum ErrorCueCatalog {
    /// 兜底文案 —— 未映射的错误码/无 code 的失败仍要说话，不允许静默。
    /// D2 v1.1 E-99：族 B，允许一键重试。文案先劝重试、再退到重说，因为
    /// 未知码下我们并不知道用户那句话有没有问题（D2.0 原则 5）。
    static let generic = ErrorCueEntry(
        code: "GENERIC",
        text: "刚才这件事没成，点重试再来一次；还不行就再说一遍。",
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
        // ESS-538 · 族 A（重说）：录音进行中被降腕息屏/会话中断截断，
        // 残片已本地丢弃、从未提交——没有缓存可重发，唯一恢复动作是
        // 重新按住说一次。与 ERR_AUDIO_TOO_SHORT 区分：用户不是按太短，
        // 是这次录音被系统打断了。
        case "ERR_RECORDING_INTERRUPTED":
            return ErrorCueEntry(
                code: code,
                text: "刚才录音被打断了，按住我重新说一次。",
                clip: nil,
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
        case "ERR_AUDIO_FETCH":
            return ErrorCueEntry(
                code: code,
                text: "答案在，只是语音没留住——文字给你看。",
                clip: "ErrorCue_TextOnly",
                recoveryFamily: .textOnly
            )
        case "ERR_PLAYBACK_ACTIVATION", "ERR_SESSION_ACTIVATION":
            return ErrorCueEntry(
                code: code,
                text: "我没抢到扬声器，没能说出来——点重播，或直接看文字。",
                clip: nil,
                recoveryFamily: .replay
            )
        case "ERR_PLAY_RETURNED_FALSE", "ERR_PLAYBACK_DEFERRED_TIMEOUT":
            return ErrorCueEntry(
                code: code,
                text: "语音没能播出，点重播试一次。",
                clip: nil,
                recoveryFamily: .replay
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
        // ESS-262 · D2 E-04（族 D）：麦克风权限缺失。SelfCheck/AudioRecorder
        // 在拿不到 permission 时抛这个 code；重录/重试都会被系统再次拦下，
        // 唯一恢复动作是引导用户去手表「设置 → 隐私」里开。
        case "ERR_MIC_PERMISSION":
            return ErrorCueEntry(
                code: code,
                text: "我还没拿到麦克风权限，去手表的「设置 → 隐私」里开一下就能听见你了。",
                clip: "ErrorCue_MicPermission",
                recoveryFamily: .authorize
            )
        // ESS-262 · D2 E-10（族 B）：Bridge 侧 work timeout。缓存录音可原样
        // 重发一次，与 E-11 / E-18 共用「重试」语音资产。
        case "ERR_WORK_TIMEOUT":
            return ErrorCueEntry(
                code: code,
                text: "这件事我跑太久也没跑完，点一下重试，不用重新说。",
                clip: "ErrorCue_Retryable",
                recoveryFamily: .retry
            )
        // ESS-262 · D2 E-12（族 E）：语音丢了 / 存不下 / 加载不出，但文字答案在。
        // 用户能看到 Watch 顶部条上的文本回执；语音资产强调「看文字」这一恢复动作。
        // ERR_NO_SPEECH_FILE：结果语音文件根本不存在（Bridge 没生成或链路丢了）
        // ERR_VAULT_LOAD / ERR_VAULT_STORE：Watch 本地保管室读/写失败。
        case "ERR_NO_SPEECH_FILE",
             "ERR_VAULT_LOAD",
             "ERR_VAULT_STORE":
            return ErrorCueEntry(
                code: code,
                text: "答案在，只是语音没留住——文字给你看。",
                clip: "ErrorCue_TextOnly",
                recoveryFamily: .textOnly
            )
        // ESS-262 · D2 E-17（族 B）：手机不可达族。WCSession 未激活或
        // waiting_for_phone 超时都归入此，用户视角一致：手机没连上，缓存
        // 录音可自动重发。共享 `ErrorCue_PhoneUnreachable` 语音资产。
        case "ERR_WC_NOT_ACTIVATED":
            return ErrorCueEntry(
                code: code,
                text: "手机没连上。录音我存着了，连上会自动重发。",
                clip: "ErrorCue_PhoneUnreachable",
                recoveryFamily: .retry
            )
        // ESS-257 · D2 E-18：Mac 不可达族——Bridge 主动上抛的 upstream 不可达 +
        // iPhone Relay 侧的传输/回包异常（ESS-253 已让后两者带码到达 Watch）。
        // 用户视角相同：Mac 那边没人应答，缓存录音可原样重发。
        // ESS-262：语音资产 `ErrorCue_Retryable` 已落包，替换 clip: nil。
        case "ERR_UPSTREAM_UNAVAILABLE",
             "ERR_TRANSPORT",
             "ERR_BAD_RESPONSE":
            return ErrorCueEntry(
                code: code,
                text: "Mac 那边没应答。确认助手在运行，点重试不用重新说。",
                clip: "ErrorCue_Retryable",
                recoveryFamily: .retry
            )
        // ESS-257 · D2 E-26：Mac 找不到这次任务（gateway/taskwatch 均可能抛）。
        // 缓存录音可重投；文案强调「重新交一次」区别于普通重试。
        // ESS-262：与 E-11 / E-18 共享 `ErrorCue_Retryable` 语音资产。
        case "ERR_TASK_NOT_FOUND":
            return ErrorCueEntry(
                code: code,
                text: "Mac 那边找不到这件事了，点重试我重新交一次。",
                clip: "ErrorCue_Retryable",
                recoveryFamily: .retry
            )
        // ESS-257 · D2 E-11：Mac 侧任务落到 failed 终态（脚本/工具报错等）。
        // 缓存录音可原样重发一次，也许上游临时故障。
        // ERR_PROCESSING_FAILED / ERR_INTERNAL 走同族同资产。
        // ESS-262：语音资产 `ErrorCue_Retryable` 已落包，替换 clip: nil。
        case "ERR_TASK_FAILED",
             "ERR_PROCESSING_FAILED",
             "ERR_INTERNAL":
            return ErrorCueEntry(
                code: code,
                text: "这件事我没办成，点重试再跑一次，不用重新说。",
                clip: "ErrorCue_Retryable",
                recoveryFamily: .retry
            )
        // ESS-257 · D2 E-28（族 H）：Bridge 明确「不知道做完没有」
        // （`manual_confirmation_required`）。**禁止重试按钮**——重跑一个可能
        // 已生效的写操作等于重复执行。Bridge 侧 `isAutomaticallyRetryableTerminalError`
        // 已按此语义关掉自动重试；Watch 侧同步关掉用户可见的重试入口。
        // ESS-262：语音资产 `ErrorCue_ManualConfirm` 已落包，替换 clip: nil。
        case "ERR_RESULT_UNKNOWN":
            return ErrorCueEntry(
                code: code,
                text: "这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。",
                clip: "ErrorCue_ManualConfirm",
                recoveryFamily: .manualConfirm
            )
        default:
            // 其他未命名 ERR_* 走通用文案，但 code 保留在 entry.code 里以便日志
            // 追溯——用户看到的还是「刚才没成功」，后台错误码从不裸露到 UI。
            // 族按 E-99 走 .retry。
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
    /// ESS-262：D2 v1.1 五条新增语音资产 (`ErrorCue_MicPermission` /
    /// `ErrorCue_Retryable` / `ErrorCue_TextOnly` / `ErrorCue_PhoneUnreachable` /
    /// `ErrorCue_ManualConfirm`) 已由 qwen-audio-realtime 生成落包，与既有 5 条
    /// 共 10 条随 App 打包。列表按 D2 v1.1 全量代表 code 遍历一次去重后得到。
    static var allClipNames: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in [
            cue(for: "ERR_AUDIO_TOO_SHORT"),
            cue(for: "ERR_TRANSCRIPT_DISCARDED"),
            cue(for: "ERR_VOICE_BUSY"),
            cue(for: "ERR_REALTIME_STALLED"),
            cue(for: "ERR_MIC_PERMISSION"),
            cue(for: "ERR_WORK_TIMEOUT"),
            cue(for: "ERR_NO_SPEECH_FILE"),
            cue(for: "ERR_WC_NOT_ACTIVATED"),
            cue(for: "ERR_UPSTREAM_UNAVAILABLE"),
            cue(for: "ERR_TASK_NOT_FOUND"),
            cue(for: "ERR_TASK_FAILED"),
            cue(for: "ERR_RESULT_UNKNOWN"),
            generic,
        ] {
            guard let clip = entry.clip, !seen.contains(clip) else { continue }
            seen.insert(clip)
            ordered.append(clip)
        }
        return ordered
    }
}
