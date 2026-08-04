import Foundation

/// ESS-180：主界面底部文案的最小数据类型。
///
/// 旧 `WaitingStatusCopy.entry(for:elapsed:)` 会把「已等待 N 秒」拼进副标题，
/// 是本 issue 明确废止的做法（白梦林拍板：处理中不允许纯计时）。这个类型
/// 只是文案容器，实际拼装逻辑落在 `WatchContentView.processingTitle/Subtitle`。
///
/// 单独抽出来是为了 `ContainsDigits` 校验能在测试里独立跑（`MainStatusCopyTests`），
/// 无需 SwiftUI 环境。
struct MainStatusCopy: Equatable {
    let title: String
    let subtitle: String

    /// ESS-180 验收辅助：主界面文案任何位置都不允许出现阿拉伯数字或中文数字。
    /// 唯一例外是「60 秒」这种录音上限提示（listening 态明确要求告知上限）——
    /// 调用方按 phase 排除即可。
    var containsDigit: Bool {
        title.rangeOfCharacter(from: .decimalDigits) != nil
            || subtitle.rangeOfCharacter(from: .decimalDigits) != nil
    }
}
