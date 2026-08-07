import Foundation

/// ESS-538：录音进行中断流（降腕息屏 / 会话中断）的收尾裁决（纯函数，可单测）。
///
/// 真机实测（2026-08-07 bridge.log，dev_f865e9876af4e9d6）：按住 5.9s，
/// 第 3.0s 降腕息屏后音频管线即断，M4A 容器内只剩 316ms 残片；旧路径把
/// 残片当正常录音提交（316ms 恰好越过 Bridge 300ms 解码门），整回合走完
/// 上传 + 识别才失败「没听清，请重说」。
///
/// 本策略在 `AudioRecorder.finish()` 收尾时识别「被打断的残片」：丢弃并
/// 提示重说，不提交回合；同时放行「说完才息屏」的可用录音（容器音频够长
/// 照常提交，即本 issue 验收的 fallback 语义——已录片段安全收尾）。
enum RecordingInterruptionPolicy {
    /// 被打断录音的可用下限（ms）。中断场景下容器内音频 < 1s 不可能是
    /// 一次完整表达。不直接用 Bridge 的 300ms 解码门
    /// （`VoiceRequestEnvelope.minimumAudioDurationMs`）：ESS-538 实测
    /// 316ms 残片恰好越过该门，走完全流程才失败，所以中断场景本地用
    /// 更严的门。
    static let interruptedDiscardFloorMs = 1_000

    /// 截断签名：容器真实音频远少于按住时长 → 录音管线中途断流。
    /// - 差值 ≥ 1.5s：排除 AAC 编码器起止帧与容器收尾的正常损耗；
    /// - asset ≤ wall 的一半：排除「说完又按了一会儿才松手」的正常残留
    ///   （说完 4s、第 7s 才松手不判截断）。
    /// ESS-538 样本：asset_ms=316 / wall_clock_ms=5926 → 命中。
    static func isTruncated(assetMs: Int?, wallClockMs: Int) -> Bool {
        guard let assetMs, assetMs >= 0, wallClockMs > 0 else { return false }
        return wallClockMs - assetMs >= 1_500 && assetMs * 2 <= wallClockMs
    }

    /// 收尾裁决：残片（容器音频 < 可用下限）且（观测到断流 或 截断签名
    /// 成立）→ 丢弃并提示重说，不提交。
    /// - wasInterrupted 覆盖「中断通知 / scene 离开 active 已观测到断流」；
    /// - isTruncated 兜底「中断通知未投递」（真机取证：通知不保证投递，
    ///   见 SpeechPlayer 的 .ended 缺失记录）——wall ≫ asset 本身就是
    ///   断流证据；
    /// - 容器音频 ≥ 下限一律放行：用户说完才息屏的录音是完整的，断掉的
    ///   尾部只是按住没松手，照常提交走正常回合；
    /// - asset 读不出（nil）时用 wall-clock 估可用性，且无法判截断——
    ///   只有明确观测到断流且时长本身低于下限才丢弃，保持保守。
    static func shouldDiscardAsFragment(
        assetMs: Int?,
        wallClockMs: Int,
        wasInterrupted: Bool
    ) -> Bool {
        let effectiveMs = assetMs ?? wallClockMs
        guard effectiveMs < interruptedDiscardFloorMs else { return false }
        return wasInterrupted || isTruncated(assetMs: assetMs, wallClockMs: wallClockMs)
    }
}
