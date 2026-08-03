import Combine
import Foundation

/// ESS-180：屏幕分身错误卡片的呈现状态机。
///
/// 白梦林拍板的两条铁律：
/// 1. **错误必须语音 + 文字回给用户**——一次失败要有一次卡片、一次触觉、
///    优先一次语音；耳机断连 / 静音 / 播放器失败降级到「文字 + 触觉」，
///    **永远不静音吞错**。
/// 2. **主界面不能把失败当成「还在处理」**——卡片自身即失败终态的可见证据，
///    停留至少 `Self.minimumDisplaySeconds` 秒（本 issue 定为 5 秒），
///    用户点确认或时间到自动收起，然后 UI 才回到「等待输入」。
///
/// 「怎么真的响铃」不在这里，触觉与语音播放走 WatchHaptics / SpeechPlayer；
/// 这里只负责：查表 → 触发触觉 → 起播（如果有 clip） → 记账 dismissAt →
/// 到点自动收起。UI 的呈现只订阅 `$active` 即可，完全被动。
@MainActor
final class AvatarErrorPresenter: ObservableObject {
    struct Presentation: Equatable, Identifiable {
        let id: UUID
        /// 触发这次呈现的 requestId（用来串日志、避免同一回合重复呈现）。
        let requestId: String?
        let entry: ErrorCueEntry
        let showsAt: Date
        let dismissAt: Date
        /// 语音是否真的起播（false = 走文字+触觉降级路径，供日志/UI 差异化提示）。
        let audioAttempted: Bool
    }

    /// 屏幕上正在展示的错误卡片；nil = 无。
    @Published private(set) var active: Presentation?

    /// UI 每秒重算时用这个判断是否到了自动收起时间，避免依赖计时器。
    func shouldAutoDismiss(now: Date) -> Bool {
        guard let active else { return false }
        return now >= active.dismissAt
    }

    /// 至少停留 5 秒（白梦林验收条 1：不能一闪而过）；实际停留可更长
    /// 由用户手动点击或新的失败覆盖。
    static let minimumDisplaySeconds: TimeInterval = 5

    /// 同一 requestId 已呈现过就跳过——错误事件在链路上有可能被重发/快照重放，
    /// 卡片抖动比不出更糟。
    private var presentedRequestIds: Set<String> = []

    /// 触发一次错误呈现。requestId 为 nil 时用于本地失败（如按太短、录音启动失败），
    /// 一律不做请求级去重（每次按都是一次独立失败）。
    /// - Parameters:
    ///   - code: `ERR_*` 稳定短码；缺失走 `ErrorCueCatalog.generic`。
    ///   - now: 注入时间戳便于测试；生产不用传。
    ///   - clipLoader: 语音数据加载闭包，返回 nil = 无预置语音，降级文字+触觉。
    ///   - playAudio: 语音播放闭包，返回 true = 已起播；生产传 SpeechPlayer.play。
    ///   - playHaptic: 触觉闭包；生产传 WatchHaptics.play(.turnFailed, requestId:)。
    /// - Returns: 是否触发了一次新的呈现（false = 因去重跳过）。
    @discardableResult
    func present(
        code: String?,
        requestId: String? = nil,
        now: Date = Date(),
        clipLoader: (String) -> Data? = { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "m4a") else { return nil }
            return try? Data(contentsOf: url)
        },
        playAudio: (Data, String?) -> Bool = { _, _ in false },
        playHaptic: (String?) -> Void = { _ in }
    ) -> Bool {
        if let requestId, !requestId.isEmpty, presentedRequestIds.contains(requestId) {
            return false
        }
        let entry = ErrorCueCatalog.cue(for: code)
        var audioAttempted = false
        if let clipName = entry.clip, let data = clipLoader(clipName) {
            audioAttempted = playAudio(data, requestId)
        }
        // 触觉在所有路径都要响一下——「文字 + 触觉」是听觉降级的兜底通道，
        // 语音成功起播也一起响，卡片起始点跟触觉重合更容易被感知。
        playHaptic(requestId)

        let presentation = Presentation(
            id: UUID(),
            requestId: requestId,
            entry: entry,
            showsAt: now,
            dismissAt: now.addingTimeInterval(Self.minimumDisplaySeconds),
            audioAttempted: audioAttempted
        )
        active = presentation
        if let requestId, !requestId.isEmpty {
            presentedRequestIds.insert(requestId)
        }
        return true
    }

    /// 用户点「知道了」或系统到点自动收起。
    func dismiss() {
        active = nil
    }

}
