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
    /// S3 播放→录音交替（ESS-61 缺陷 A，`-50`）、S3R 录音→播放交替（即 ESS-72
    /// 的 S3'：录音刚结束立刻播放，会话未交还则两级激活全 `!res`）、
    /// S4 会话状态复位（ESS-61 根因）。
    /// S5/S6 为 PM 2026-08-02 追加：S6 双激活失败（不得 play()，音频保留
    /// 可重播）；S5 原为 ESS-64 中断闸门断言，ESS-73 撤闸门后改为断言
    /// 「中断残留标志不得阻塞新播放」（.ended 不保证投递，激活结果说话）。
    enum Step: String, CaseIterable {
        case record = "S1"
        case playback = "S2"
        case playThenRecord = "S3"
        case recordThenPlay = "S3R"
        case sessionReset = "S4"
        case interruptionGate = "S5"
        case dualActivationFailure = "S6"
    }

    // MARK: - S5/S6 观测记录契约（ESS-64 §最短修法 第 3 条，字段与毕玄对齐）

    enum InterruptionState: String {
        case none
        case began
        case ended
    }

    enum ActivationResult: String {
        case success
        case failed
        case notAttempted = "not_attempted"
        case skippedInterrupted = "skipped_interrupted"
    }

    /// `selfcheck_observation` 的 detail：受控矩阵每一格的取证快照。
    /// 时间戳 Unix epoch 毫秒；尚未发生的回调 `callback_ts=none`。
    static func observationDetail(
        step: Step,
        phase: String,
        scenePhase: String,
        interruptionState: InterruptionState,
        requestTs: Int64,
        callbackTs: Int64?,
        longFormResult: ActivationResult,
        fallbackResult: ActivationResult
    ) -> String {
        "step=\(step.rawValue) phase=\(phase) scene_phase=\(scenePhase) "
            + "interruption_state=\(interruptionState.rawValue) "
            + "request_ts=\(requestTs) callback_ts=\(callbackTs.map(String.init) ?? "none") "
            + "long_form_result=\(longFormResult.rawValue) fallback_result=\(fallbackResult.rawValue)"
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
    /// ESS-163：追加 `failedStep` / `code` / `inconclusiveReason`（均可空），
    /// Debug 面板据此在冷启动跳过自检时也能还原上次结论；Codable 的可选
    /// 字段解码天然向后兼容旧 JSON（缺字段解为 nil，走 `outcome == nil` 退路）。
    struct RunRecord: Codable, Equatable {
        /// BuildFingerprint.detail 全串（version/build/built_at）作为 build 身份。
        let fingerprintDetail: String
        let result: String
        let failedStep: String?
        let code: String?
        let inconclusiveReason: String?

        init(
            fingerprintDetail: String,
            result: Result,
            failedStep: SelfCheckPolicy.Step? = nil,
            code: String? = nil,
            inconclusiveReason: SelfCheckPolicy.InconclusiveReason? = nil
        ) {
            self.fingerprintDetail = fingerprintDetail
            self.result = result.rawValue
            self.failedStep = failedStep?.rawValue
            self.code = code
            self.inconclusiveReason = inconclusiveReason?.rawValue
        }

        /// 从完整 Outcome 建记录：finish() 落盘走这里，避免各处再拆解。
        static func from(outcome: Outcome, fingerprintDetail: String) -> RunRecord {
            switch outcome {
            case .pass:
                return RunRecord(fingerprintDetail: fingerprintDetail, result: .pass)
            case .failed(let step, let code):
                return RunRecord(
                    fingerprintDetail: fingerprintDetail, result: .fail,
                    failedStep: step, code: code
                )
            case .inconclusive(let reason):
                return RunRecord(
                    fingerprintDetail: fingerprintDetail, result: .inconclusive,
                    inconclusiveReason: reason
                )
            }
        }

        /// 还原为 Outcome；旧记录（缺失新字段）无法还原时返回 nil，
        /// UI 侧退回到「无历史结论可展示」的空态。
        var outcome: Outcome? {
            switch result {
            case Result.pass.rawValue:
                return .pass
            case Result.fail.rawValue:
                guard let rawStep = failedStep,
                      let step = SelfCheckPolicy.Step(rawValue: rawStep) else {
                    return nil
                }
                return .failed(step: step, code: code)
            case Result.inconclusive.rawValue:
                guard let rawReason = inconclusiveReason,
                      let reason = SelfCheckPolicy.InconclusiveReason(rawValue: rawReason) else {
                    return nil
                }
                return .inconclusive(reason)
            default:
                return nil
            }
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
