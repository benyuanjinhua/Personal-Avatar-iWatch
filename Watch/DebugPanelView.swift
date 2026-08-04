import SwiftUI

/// 开发者面板（ESS-163）：把装机自检的过程/结果、重跑入口、build 指纹等
/// 开发调试信息收拢到设置页下的单一入口，不再默认铺给用户看。
///
/// 与 ESS-65 铁律 3/4/5 的关系：
/// - 铁律 3（自检失败绝不锁死 App）——保持：本面板只在被主动进入时展示。
/// - 铁律 4（自检期间 UI 有明确提示）——收敛到本面板；首屏不再显示卡片。
///   过程可见性对最终用户是噪音，对开发者仍可用（此处「正在自检…」实时可见）。
/// - 铁律 5（可手动重跑）——保持：入口从首屏卡片迁移到本面板的按钮。
///
/// 门禁不变：R-02.1 要求的 `selfcheck_started` / `selfcheck_step` /
/// `selfcheck_finished` 事件仍由 SelfCheckRunner 照常落 bridge.log，
/// Bridge 侧 `Scripts/watch-smoke-gate.mjs` 判定逻辑零改动。
struct DebugPanelView: View {
    @ObservedObject var selfCheck: SelfCheckRunner
    /// ESS-280：本机 Debug 灰度存储，Toggle 直接绑定。仅在 Watch 本地生效，
    /// 不会同步给 iPhone —— 避免最终用户被开发者态污染。
    @ObservedObject var debugSettings: WatchDebugSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                selfCheckSection
                downlinkStreamingSection
                buildSection
                logsHintSection
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .navigationTitle("开发者面板")
    }

    // MARK: - 自检

    private var selfCheckSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("音频自检")

            Text(selfCheckStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let outcome = selfCheck.pendingAttention {
                Text(SelfCheckPolicy.userMessage(outcome: outcome))
                    .font(.caption2)
                    .multilineTextAlignment(.leading)
            }

            Button {
                selfCheck.rerun()
            } label: {
                Label(selfCheck.isRunning ? "自检运行中…" : "重新自检", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .font(.caption2)
            .disabled(selfCheck.isRunning)

            // 门禁失败常见诱因：扬声器与麦克风互相耦合被系统静音策略挡回。
            // 该提示只在本面板出现，普通用户装机不再被这行文案打扰。
            Text("提示：若结果为 fail，可先连蓝牙耳机让扬声器/麦克风解耦再试一次。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var selfCheckStatusText: String {
        // ESS-163 复审补丁：`.idle` 覆盖两个场景——本进程从未跑过、
        // 或冷启动同 build 已跑过（autoRunIfNeeded → selfcheck_skipped）。
        // 后者的结果在磁盘 RunRecord 里，走 latestOutcome 还原；仍读不出
        // （首启前 / 旧记录字段不全）才落到「尚未运行」。运行中直接
        // 展示实时步骤——本面板对开发者不算噪音。
        if case .running(let step) = selfCheck.stage {
            return "运行中：\(step.rawValue)"
        }
        guard let outcome = selfCheck.latestOutcome else {
            return "尚未运行"
        }
        switch outcome {
        case .pass:
            return "结果：pass"
        case .failed(let step, let code):
            if let code, !code.isEmpty {
                return "结果：fail · 失败步骤 \(step.rawValue) · code=\(code)"
            }
            return "结果：fail · 失败步骤 \(step.rawValue)"
        case .inconclusive(let reason):
            return "结果：inconclusive · \(reason.rawValue)"
        }
    }

    // MARK: - 流式下行灰度（ESS-280）

    /// 白梦林 2026-08-04 决策（正本 ESS-249）：两轨合成一个包，Debug 面板
    /// 内提供开关做同机 A/B。默认 OFF（走完整 m4a / transferFile 旧链路），
    /// 手动 ON 走 ESS-279（PR #100）下行首包即播；关掉即刻按当前分片进度
    /// 丢弃并回退旧链路，不留 session / 分片缓冲 / 计时器等残留。
    private var downlinkStreamingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("流式下行（Debug）")

            Toggle(isOn: Binding(
                get: { debugSettings.downlinkStreamingEnabled },
                set: { debugSettings.setDownlinkStreamingEnabled($0) }
            )) {
                Text("启用流式下行")
                    .font(.caption2)
            }
            .tint(.orange)

            Text("默认关；仅本机生效，不同步 iPhone。关掉时在途流式回合会丢弃并回退旧链路。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 构建指纹

    private var buildSection: some View {
        let fingerprint = BuildFingerprint.current()
        return VStack(alignment: .leading, spacing: 4) {
            sectionHeader("构建")
            keyValueRow("version", fingerprint.shortVersion)
            keyValueRow("build", fingerprint.build)
            keyValueRow("built_at", fingerprint.builtAtText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 日志提示

    private var logsHintSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("日志")
            Text("完整事件流见 Bridge 侧 `bridge.log`（selfcheck / audio / lifecycle）。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 组件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.bold())
            .foregroundStyle(.primary)
    }

    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
