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
    /// ESS-419：语音回合日志（清除历史语音用）。
    @ObservedObject var journal: VoiceTurnJournal
    /// ESS-419：加密语音仓（清除历史语音用）。
    var speechVault: EncryptedAudioVault?
    /// ESS-419：语音播放器（清除前先停播）。
    var player: SpeechPlayer

    @State private var showClearConfirmation = false
    @State private var clearResultMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                connectionStatusSection
                downlinkBacklogSection
                streamingSection
                voiceBargeInSection
                privacySection
                selfCheckSection
                buildSection
                logsHintSection
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .navigationTitle("设置")
        .confirmationDialog(
            "确认清除历史语音",
            isPresented: $showClearConfirmation
        ) {
            Button("清除", role: .destructive) {
                performClearHistorySpeech()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有已保存的结果语音文件，文字记录与处理日志保留。此操作不可撤销。")
        }
        .alert("清除结果", isPresented: Binding(
            get: { clearResultMessage != nil },
            set: { if !$0 { clearResultMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            if let message = clearResultMessage {
                Text(message)
            }
        }
    }

    // MARK: - 当前链路（ESS-419 F2）

    private var connectionStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("当前链路")
            HStack(spacing: 4) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 6, height: 6)
                Text(connectionStatusText)
                    .font(.caption2)
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectionStatusColor: Color {
        guard settings.wcSessionActivationState == .activated else { return .gray }
        return settings.wcIsReachable ? .green : .orange
    }

    private var connectionStatusText: String {
        guard settings.wcSessionActivationState == .activated else {
            return "会话未激活"
        }
        return settings.wcIsReachable
            ? "已连接 iPhone"
            : "iPhone 未连接（回合将排队等待）"
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

    // MARK: - 语音打断（ESS-650 F2-4，Debug）

    /// gate 的**唯一用户入口**。白梦林 R1「不许悄悄做潜规则、开关要可见可点」
    /// 同样适用：`setVoiceBargeInEnabled` 此前没有任何调用点，等于这个功能
    /// 只能靠改代码打开——F2-4「运行时切换」与全部真机验收都无从谈起
    /// （ESS-667 复审阻断 2）。
    ///
    /// ESS-711 后新安装默认 ON；此处保留可见退出开关，回声异常时用户可
    /// 显式关闭，且该选择在重启后继续生效。
    private var voiceBargeInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("语音打断")

            Toggle(isOn: Binding(
                get: { debugSettings.voiceBargeInEnabled },
                set: { debugSettings.setVoiceBargeInEnabled($0) }
            )) {
                Text("说话打断回答")
                    .font(.caption2)
            }
            .tint(.teal)

            Text("开启后分身回答时用 .voiceChat 回声消除并持续听你说话，说话即可打断；关掉时只能点球打断。仅本机生效。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 隐私（ESS-419 F1）

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("隐私")

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("清除历史语音", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .font(.caption2)

            Text("清除所有已保存的结果语音文件；文字记录与处理日志不受影响。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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
                Label(selfCheck.isRunning ? "自检运行中…" : "开始自检", systemImage: "play.circle")
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
        // ESS-163 复审补丁：`.idle` 时从磁盘 RunRecord 还原上次手动自检
        // 的结果；仍读不出
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

    // MARK: - 清除历史语音（ESS-419 F1）

    /// 手动一键清空结果语音：停播 → 委托 SpeechVaultCleaner 执行 → 落日志并反馈结果。
    private func performClearHistorySpeech() {
        // 先停播，防止「文件已删但播放器仍在读」
        player.stop(reason: "clear_history_speech")

        let vaultDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("SpeechVault", isDirectory: true)

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: speechVault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()
        clearResultMessage = result.userMessage

        WatchLog.info("settings", "speech_vault_cleared", detail: result.logDetail)
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
