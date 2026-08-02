import Foundation

/// 装机音频自检（ESS-65 / G9）的决策与日志契约层（纯逻辑，可单测）。
///
/// 背景：`Scripts/verify.sh` 对 Watch/ 只做语法解析与编译，Tests/ 没有任何
/// 用例触及 AVAudioSession——音频会话是仓库里唯一没有测试网的地方，
/// ESS-52/54/58/61 四个 P0 全部落在这里，且都由白梦林真机人工验收才发现。
/// G9 把「新包能不能用」变成装机后 App 自动执行、Bridge 一条命令可判定的
/// 门禁：不 PASS 不进入人工验收。
///
/// 本类型只管三件事（都不碰 AVFoundation，执行在 Watch/SelfCheck.swift）：
/// 1. 要不要自动跑（同一 build 只跑一次，权限缺失类结论例外）；
/// 2. 结论分类（pass / fail / inconclusive——权限缺失不是代码坏了，
///    但同样不放行）；
/// 3. 日志 detail 契约（Bridge 侧 watch-smoke.mjs 按同一格式解析）。
enum SelfCheckPolicy {
    /// 自检步骤，对应真实事故：S1 录音（ESS-52/54）、S2 播放（ESS-61 缺陷 B）、
    /// S3 播放→录音交替（ESS-61 缺陷 A，`-50`）、S4 会话状态复位（ESS-61 根因）。
    enum Step: String, CaseIterable {
        case record = "S1"
        case playback = "S2"
        case playThenRecord = "S3"
        case sessionReset = "S4"
    }

    enum Result: String {
        case pass
        case fail
        /// 无法判定（权限缺失 / 被用户打断）：不是代码缺陷，但同样不放行。
        case inconclusive
    }

    enum InconclusiveReason: String {
        case micPermissionMissing = "mic_permission_missing"
        case interrupted = "user_interrupted"
    }

    enum Outcome: Equatable {
        case pass
        case failed(step: Step, code: String?)
        case inconclusive(InconclusiveReason)

        var result: Result {
            switch self {
            case .pass: return .pass
            case .failed: return .fail
            case .inconclusive: return .inconclusive
            }
        }
    }

    /// 上一次自检的持久化记录（UserDefaults JSON）。
    struct RunRecord: Codable, Equatable {
        /// BuildFingerprint.detail 全串（version/build/built_at）作为 build 身份。
        let fingerprintDetail: String
        let result: String

        init(fingerprintDetail: String, result: Result) {
            self.fingerprintDetail = fingerprintDetail
            self.result = result.rawValue
        }
    }

    /// 同一 build 只自动跑一次，避免每次开 App 都抢麦克风。
    /// 例外：上次结论是 inconclusive（没授权 / 被打断）时下次启动重试——
    /// 权限缺失分支不碰麦克风即刻返回，重试零成本；授权后无需手动操作
    /// 即可在下次启动补上完整自检。
    static func shouldAutoRun(currentFingerprint: String, lastRun: RunRecord?) -> Bool {
        guard let lastRun else { return true }
        if lastRun.fingerprintDetail != currentFingerprint { return true }
        return lastRun.result == Result.inconclusive.rawValue
    }

    // MARK: - 日志契约（module=selfcheck，Bridge 侧按空格分隔 k=v 解析）

    /// `selfcheck_started` 的 detail：直接携带完整 build 指纹。
    static func startedDetail(fingerprint: String) -> String {
        fingerprint
    }

    /// `selfcheck_step` 的 detail。失败时原始错误码走 WatchLog 的 error_code
    /// 字段（Bridge 白名单内），不塞进 detail。
    static func stepDetail(step: Step, passed: Bool, elapsedMs: Int) -> String {
        "step=\(step.rawValue) result=\(passed ? "pass" : "fail") elapsed_ms=\(max(0, elapsedMs))"
    }

    /// `selfcheck_finished` 的 detail：结论 + 失败步骤 + 完整 build 指纹。
    /// 指纹在 finished 行重复出现是刻意的——门禁只读这一行即可校验
    /// 「自检结论属于哪个 build」，无须与 started 行对账。
    static func finishedDetail(outcome: Outcome, fingerprint: String) -> String {
        var fields = ["result=\(outcome.result.rawValue)"]
        switch outcome {
        case .pass:
            fields.append("failed_step=none")
        case .failed(let step, _):
            fields.append("failed_step=\(step.rawValue)")
        case .inconclusive(let reason):
            fields.append("failed_step=none")
            fields.append("reason=\(reason.rawValue)")
        }
        fields.append(fingerprint)
        return fields.joined(separator: " ")
    }

    /// UI 文案：必须能区分「代码坏了」和「你还没授权麦克风」，
    /// 否则会误导排查方向（PD 约束 2）。
    static func userMessage(outcome: Outcome) -> String {
        switch outcome {
        case .pass:
            return "音频自检通过"
        case .failed(let step, _):
            return "音频自检未通过（\(step.rawValue)）。App 仍可正常使用，但验收未放行。"
        case .inconclusive(.micPermissionMissing):
            return "音频自检未完成：还没有麦克风权限。请在手表设置中允许后重新自检。"
        case .inconclusive(.interrupted):
            return "音频自检被打断，可稍后重新自检。"
        }
    }
}
