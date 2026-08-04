import SwiftUI

/// ESS-280（R1 生效）：设置页 —— 唯一可见的开发入口。
///
/// 白梦林 R1 原话：**「不要悄悄做些潜规则（比如长按操作），直接在右滑
/// 第 3 屏设置里面加流式下行的开关。」** PM 转述记入 D3「不许隐藏交互」。
/// 本文件替代旧的 `DebugPanelView`（长按主界面标题 2 秒进入，已作废）；
/// 自检、build 指纹、日志提示统一收进本页。
///
/// 屏位：PM Jackson Bai 2026-08-04 拍板方案 A（R-04.6 后一条覆盖前一条）——
/// 三屏结构（0=主界面 / 1=状态时间线 / 2=设置）；本视图挂在 TabView(.page)
/// 的第 3 页（右滑到底）。`WatchContentView` 负责挂 TabView，本视图只关心
/// 内容组织。白梦林原话「右滑第 3 屏设置」在这里字面成立。
///
/// 与 ESS-65 铁律 3/4/5 的关系：
/// - 铁律 3（自检失败绝不锁死 App）——保持：本页只在被主动进入时展示。
/// - 铁律 4（自检期间 UI 有明确提示）——收敛到本页；首屏不再显示卡片。
/// - 铁律 5（可手动重跑）——保持：入口为本页内的重跑按钮。
struct WatchSettingsView: View {
    @ObservedObject var selfCheck: SelfCheckRunner
    @ObservedObject var debugSettings: WatchDebugSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                streamingSection
                selfCheckSection
                buildSection
                logsHintSection
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .navigationTitle("设置")
    }

    // MARK: - 流式（Debug）：R1 直呼直取，不再走隐藏手势

    /// 白梦林 R1 决策落点：Toggle 可见可点。R4「一个开关兼管上下行」——
    /// 现在语义只覆盖下行（ESS-279 未 wire-up），上行接入后本开关一同生效，
    /// 无需 UI 变更（文案里已说「流式」不特指方向）。
    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("流式（Debug）")

            Toggle(isOn: Binding(
                get: { debugSettings.streamingEnabled },
                set: { debugSettings.setStreamingEnabled($0) }
            )) {
                Text("启用流式")
                    .font(.caption2)
            }
            .tint(.orange)

            Text("仅本机生效，不同步 iPhone。关掉时在途流式回合会丢弃并回退旧链路。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 自检（从旧 DebugPanelView 平移）

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
        // 展示实时步骤——本页对开发者不算噪音。
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

    // MARK: - 构建指纹（从旧 DebugPanelView 平移）

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

    // MARK: - 日志提示（从旧 DebugPanelView 平移）

    private var logsHintSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("日志")
            Text("完整事件流见 Bridge 侧 `bridge.log`（selfcheck / audio / lifecycle / settings）。")
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
