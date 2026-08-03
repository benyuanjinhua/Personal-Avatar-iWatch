import Foundation

/// ESS-180-A：Bridge 稳定 `ERR_*` → 拟人化错误提示（文字 + 语音片段名 + 触觉）。
///
/// 白梦林拍板：错误必须**语音 + 文字**回给用户，屏幕不再压掉失败终态。
/// 目录在 Shared 里，是因为 iPhone Relay/单元测试也要按 code 走同一份文案，
/// 避免各处硬编码分叉。语音片段真正加载 / 播放 / 降级由 Watch 的
/// `AvatarErrorPresenter` 负责——这里只维护「查表」这一件事，纯数据。
///
/// **180-A / 180-B 分包**：本包只落文案 + 触觉，语音资产由 180-B 一并生成
/// 入包（PM 修正意见，2026-08-03）。因此 `ErrorCueEntry.clip` 现在只是
/// **预留接口**——Bundle 里没有对应 m4a 时，AvatarErrorPresenter 自动降级
/// 到「文字 + 触觉」，绝不静音吞错。180-B PR 只需要把 5 条 m4a 补进
/// Watch/Resources，无需改动本目录。
///
/// 灰度约定：`clip` 为 nil 表示无预置语音、只走文字 + 触觉；`ErrorCueCatalog.cue`
/// 对未知错误码回落到 `.generic`，绝不返回 nil——「静音吞错」是本 issue 的
/// 头号红线，从 API 形状层杜绝。
struct ErrorCueEntry: Equatable {
    /// Bridge 侧稳定错误码，`ERR_*` 前缀；tests 依赖这个字符串完整。
    let code: String
    /// 屏幕分身卡片主文案（≤ 30 汉字，watchOS 顶部条能一屏显示完）。
    let text: String
    /// 语音资产文件名（不含扩展名）；nil = 无预置语音，只走文字 + 触觉。
    let clip: String?
}

enum ErrorCueCatalog {
    /// 兜底文案 —— 未映射的错误码/无 code 的失败仍要说话，不允许静默。
    static let generic = ErrorCueEntry(
        code: "GENERIC",
        text: "刚才没成功，你可以再说一次。",
        clip: "ErrorCue_Generic"
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
                clip: "ErrorCue_AudioTooShort"
            )
        case "ERR_TRANSCRIPT_DISCARDED":
            return ErrorCueEntry(
                code: code,
                text: "话有点糊，麻烦离麦近一点再说一次。",
                clip: "ErrorCue_TranscriptDiscarded"
            )
        case "ERR_VOICE_BUSY":
            return ErrorCueEntry(
                code: code,
                text: "抱歉，我这边有人正在说话，稍后再叫我一下。",
                clip: "ErrorCue_VoiceBusy"
            )
        // 三个 realtime 停摆错误码用户感知一致：都是「那句没通」，共享同一条语音。
        case "ERR_REALTIME_STALLED",
             "ERR_REALTIME_NO_EVENTS",
             "ERR_REALTIME_TIMEOUT":
            return ErrorCueEntry(
                code: code,
                text: "刚才那句我卡了一下，麻烦你再说一次。",
                clip: "ErrorCue_RealtimeStalled"
            )
        default:
            // 其他 ERR_*（ERR_WORK_TIMEOUT / ERR_PROCESSING_FAILED / …）走通用文案，
            // 但 code 保留在 entry.code 里以便日志追溯——用户看到的还是「刚才没成功」，
            // 后台错误码从不裸露到 UI。
            return ErrorCueEntry(code: code, text: generic.text, clip: generic.clip)
        }
    }

    /// 所有目录内独立语音片段的资源名（去重后），用于 Bundle 存在性校验。
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
