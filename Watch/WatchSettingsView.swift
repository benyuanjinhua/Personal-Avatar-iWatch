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
    /// ESS-307：iPhone 下行队列积压计数。
    @ObservedObject var settings: WatchSettingsStore
    /// ESS-319「清除历史语音」：清空语音引用的落点。
    @ObservedObject var journal: VoiceTurnJournal
    /// ESS-319「清除历史语音」：删除密文文件的落点。可为 nil（仓初始化失败），
    /// 此时入口置灰而不是假装成功——ESS-342 的教训：不留「点了不生效」的控件。
    let speechVault: EncryptedAudioVault?

    /// 二次确认：清除不可撤销，watchOS 上误触概率高。
    @State private var showClearSpeechConfirm = false
    /// 清除结果回执，给用户一个「确实做了」的确认。
    @State private var clearSpeechResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                downlinkBacklogSection
                channelSection
                streamingSection
                clearSpeechSection
                selfCheckSection
                buildSection
                logsHintSection
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .navigationTitle("设置")
    }

    // MARK: - 通道（ESS-242 ③屏）

    /// ESS-242 冻结设计：「③屏的通道切换依赖 ESS-172（直连）。若它起不来，
    /// ③先只落「经 iPhone」单选 + 灰掉直连，不要自己去实现直连。」
    ///
    /// 复核 2026-08-05：`Shared/` `Watch/` 全仓无直连实现（`grep directConnect|
    /// transportMode|DirectBridge` 无命中），ESS-172 仍 blocked。因此本节按
    /// 冻结设计落「单选 + 灰掉」，**不做假开关**。
    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("通道")

            channelRow(
                title: "经 iPhone",
                detail: "Watch → iPhone → Mac Bridge，当前唯一通路",
                selected: true,
                enabled: true
            )
            channelRow(
                title: "直连 Bridge",
                detail: "需办公网 WiFi；直连能力未实现（ESS-172）",
                selected: false,
                enabled: false
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func channelRow(title: String, detail: String, selected: Bool, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(enabled ? (selected ? Color.blue : Color.secondary) : Color.secondary.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(enabled ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 清除历史语音（ESS-242 Q2 拍板项）

    /// 白梦林 2026-08-04 拍板：「Q2 的『清除历史语音』入口保留。」
    ///
    /// 只清语音，不清回合——②屏的问答文本与处理日志全部保留。
    /// 删除顺序：先删密文文件，再清 journal 引用；反过来若中途失败会留下
    /// 「引用没了但文件还在」的孤儿密文，用户以为清干净了其实没有。
    private var clearSpeechSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("历史语音")

            Text("保留最近 24 小时 / 10 轮（取先到者），到期自动清理。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                showClearSpeechConfirm = true
            } label: {
                Text(speechVault == nil ? "清除历史语音（不可用）" : "立即清除历史语音")
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
            }
            .disabled(speechVault == nil)

            if let clearSpeechResult {
                Text(clearSpeechResult)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text("只删语音，历史对话的文字与处理日志保留。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog(
            "清除全部历史语音？",
            isPresented: $showClearSpeechConfirm,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) { performClearSpeech() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("语音删除后无法恢复；历史对话的文字会保留。")
        }
    }

    private func performClearSpeech() {
        let files = speechVault?.removeAll() ?? 0
        let refs = journal.clearAllSpeech()
        clearSpeechResult = "已清除 \(files) 条语音"
        WatchLog.info(
            "settings", "history_speech_cleared",
            detail: "files=\(files) journal_refs=\(refs)"
        )
    }

    // MARK: - 下行队列积压（ESS-307）

    private var downlinkBacklogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("下行队列")
            HStack {
                Text("当前积压")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(settings.downlinkBacklogCount) 条")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(settings.downlinkBacklogCount > 0 ? .orange : .secondary)
            }
            Text("iPhone 端尚未送到手表的条目数。积压会在会话恢复后自动投递。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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
