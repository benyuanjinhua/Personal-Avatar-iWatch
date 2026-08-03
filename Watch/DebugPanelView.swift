import SwiftUI

/// ESS-163 开发者面板：装机自检 UI 从首屏（WatchContentView）折叠到这里，
/// 集中呈现最近一次自检结果、「重新自检」按钮、蓝牙耳机引导、build 指纹。
///
/// 决策：普通装机用户默认看不到——首屏按最终用户体验呈现，任何 debug
/// 项都要主动从设置进入才可见。本单不做条件编译（开发/TF/Release 差异化
/// 隐藏），后续如需按渠道隐藏另开单。
///
/// 门禁契约不受影响：自检仍在启动时静默跑，`selfcheck_finished` 事件与
/// `bridge.log` 门禁判定不变（ESS-65 § R-02.1）。
struct DebugPanelView: View {
    @ObservedObject var selfCheck: SelfCheckRunner
    private let fingerprint: BuildFingerprint

    init(selfCheck: SelfCheckRunner, fingerprint: BuildFingerprint = BuildFingerprint.current()) {
        self.selfCheck = selfCheck
        self.fingerprint = fingerprint
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                selfCheckSection
                buildSection
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .navigationTitle("开发者")
    }

    // MARK: - 音频自检 Section

    private var selfCheckSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("音频自检")
                .font(.caption.bold())

            statusLine
                .font(.caption2)
                .multilineTextAlignment(.leading)

            Button("重新自检") {
                selfCheck.rerun()
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .font(.caption2)
            .disabled(selfCheck.isRunning)

            Text("提示：接一副蓝牙耳机后再跑一次，可得到干净回环通道下的结果。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusLine: some View {
        if selfCheck.isRunning {
            Label("正在自检音频链路", systemImage: "waveform.badge.magnifyingglass")
        } else if let outcome = selfCheck.latestOutcome {
            Text(SelfCheckPolicy.userMessage(outcome: outcome))
                .foregroundStyle(color(for: outcome))
        } else {
            Text("尚未运行自检")
                .foregroundStyle(.secondary)
        }
    }

    private func color(for outcome: SelfCheckPolicy.Outcome) -> Color {
        switch outcome {
        case .pass: return .green
        case .failed: return .red
        case .inconclusive: return .orange
        }
    }

    // MARK: - Build 指纹 Section

    private var buildSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Build 指纹")
                .font(.caption.bold())
            Text("v\(fingerprint.shortVersion) (\(fingerprint.build))")
                .font(.caption2)
            Text("built_at \(fingerprint.builtAtText)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
