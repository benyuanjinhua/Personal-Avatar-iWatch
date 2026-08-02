import Foundation

/// ESS-55 主张 2：任何超过 1 秒的等待都必须有状态，超过 10 秒的等待必须有进展。
/// 每个等待相位按 elapsed（距该状态最近一次变更的秒数）给出阶梯文案；
/// 阶梯走完后副标题带出「已等待 N 秒」，保证任意 10 秒窗口内文案必有变化，
/// 不存在静止转圈。elapsed 以回合最后一个状态事件时间为基准，状态一变阶梯重置。
enum WaitingStatusCopy {
    struct Entry: Equatable {
        let title: String
        let subtitle: String
    }

    /// 验收口径：等待文案静止不得超过这个秒数。
    static let maxSilentInterval: TimeInterval = 10

    /// 等待中的相位返回阶梯文案；非等待相位返回 nil（调用方用静态文案）。
    static func entry(for phase: VoiceTurnPhase, elapsed: TimeInterval) -> Entry? {
        let seconds = max(0, Int(elapsed))
        switch phase {
        case .sending:
            return laddered(seconds, ladder: [
                (0, "正在送出", "录音已保存，正在发到 iPhone"),
                (8, "还在送出…", "手表到手机有点慢，录音不会丢")
            ], tail: ("仍在送出", "已等待 %d 秒 · 录音不会丢，送达后会有震动"))
        case .waitingForPhone:
            return laddered(seconds, ladder: [
                (0, "等待手机连接", "已排队，手机连上后自动送出"),
                (10, "手机还没连上", "确认 iPhone 在附近、蓝牙已开启")
            ], tail: ("仍在等手机", "已等待 %d 秒 · 录音已保存，连上即自动发送"))
        case .waitingForMac:
            return laddered(seconds, ladder: [
                (0, "已到手机，等待 Mac", "任务在后台继续，可以先放下手腕"),
                (10, "Mac 还没接单", "确认 Mac 端助手正在运行")
            ], tail: ("仍在等 Mac", "已等待 %d 秒 · 受理后会有震动提醒"))
        case .delivered:
            return laddered(seconds, ladder: [
                (0, "已收到，正在安排", "Mac 已受理你的请求"),
                (8, "正在准备执行", "马上开始处理")
            ], tail: ("排队中", "已等待 %d 秒 · 开始处理会有提示"))
        case .processing(let background):
            if background {
                return laddered(seconds, ladder: [
                    (0, "已收到，正在处理", "长任务不用盯着，完成会震动提醒"),
                    (10, "还在跑…", "退出页面任务也会继续")
                ], tail: ("仍在执行", "已等待 %d 秒 · 结果会保留，回来就能看"))
            }
            return laddered(seconds, ladder: [
                (0, "已收到，正在思考", "很快给你结果"),
                (8, "还在想…", "正在组织答案")
            ], tail: ("快好了", "已等待 %d 秒 · 结果到达会震动提醒"))
        case .needsConfirmation, .completed, .failed, .cancelled:
            return nil
        }
    }

    /// 阶梯查找 + 尾部计秒：ladder 是 (起始秒, 标题, 副标题) 单调序列；
    /// 超过最后一档 maxSilentInterval 后进入 tail，副标题嵌入已等秒数。
    private static func laddered(
        _ seconds: Int,
        ladder: [(Int, String, String)],
        tail: (String, String)
    ) -> Entry {
        let tailStart = (ladder.last?.0 ?? 0) + Int(maxSilentInterval)
        if seconds >= tailStart {
            return Entry(title: tail.0, subtitle: String(format: tail.1, seconds))
        }
        let rung = ladder.last(where: { seconds >= $0.0 }) ?? ladder[0]
        return Entry(title: rung.1, subtitle: rung.2)
    }
}
