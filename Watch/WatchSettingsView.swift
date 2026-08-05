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

    // MARK: - 清除历史语音（ESS-419 F1）

    /// 手动一键清空结果语音：停播 → 遍历 journal turns 逐一删除 vault 文件并
    /// 清 journal speechFileName → 扫描 vault 目录清残留 → 落日志并反馈结果。
    private func performClearHistorySpeech() {
        // 先停播，防止「文件已删但播放器仍在读」
        player.stop(reason: "clear_history_speech")

        guard let vault = speechVault else {
            clearResultMessage = "本机语音仓不可用"
            WatchLog.info("settings", "speech_vault_cleared", detail: "vault_unavailable")
            return
        }

        let turns = journal.turns
        guard !turns.isEmpty else {
            clearResultMessage = "没有可清除的语音"
            WatchLog.info("settings", "speech_vault_cleared", detail: "removed=0 failed=0 orphan=0 turns_empty=true")
            return
        }

        var removed = 0
        var failed = 0

        // 1. 遍历 turns，清除有 speechFileName 的语音
        for turn in turns {
            guard let fileName = turn.speechFileName else { continue }
            vault.remove(name: fileName)
            // remove 是 best-effort（吞了 throws），文件不存在也视为已清
            if journal.clearSpeech(requestId: turn.requestId, matching: fileName) {
                removed += 1
            } else {
                failed += 1
            }
        }

        // 2. 扫描 vault 目录清 journal 已不引用的残留
        var orphanCount = 0
        let referencedNames = Set(turns.compactMap { $0.speechFileName })
        let vaultDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("SpeechVault", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: vaultDir, includingPropertiesForKeys: nil
        ) {
            for url in contents {
                let name = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "sealed", !referencedNames.contains(name) else { continue }
                try? FileManager.default.removeItem(at: url)
                orphanCount += 1
            }
        }

        // 3. 汇总
        if removed == 0, failed == 0 {
            clearResultMessage = "没有可清除的语音"
        } else if failed == 0 {
            clearResultMessage = "已清除 \(removed) 条结果语音"
        } else {
            clearResultMessage = "\(removed) 条已清，\(failed) 条失败"
        }
        if orphanCount > 0 {
            clearResultMessage! += "（另清理 \(orphanCount) 个残留文件）"
        }

        WatchLog.info(
            "settings", "speech_vault_cleared",
            detail: "removed=\(removed) failed=\(failed) orphan=\(orphanCount)"
        )
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
