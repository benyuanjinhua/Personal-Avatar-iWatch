import SwiftUI

/// 历史对话（ESS-317 / ESS-242 ②屏）：轮次列表 → 逐步处理日志 → 展开全文/重播 → 再次对话。
///
/// 由 ESS-280 从主屏 NavigationLink 抬升为 `TabView` 第 2 屏（tag=1）。
/// 本文件是 ESS-29 的原生实现升级版，新增：
/// - F2.1 轮次列表（时间 + 摘要 + 状态图标）
/// - F2.2 逐步处理日志（≤12 字/行、无 request_id、无裸错误码）
/// - F2.3 结果展开（全文 + 重播）
/// - F2.4 再次对话入口
struct ConversationTimelineView: View {
    @ObservedObject var journal: VoiceTurnJournal
    /// ESS-307：iPhone 下行队列积压信息，用于标注「等待送达」状态。
    @ObservedObject var settings: WatchSettingsStore
    /// 点击「再次对话」时通知父视图切回主屏并进入 listening。
    var onContinueConversation: ((VoiceTurnRecord) -> Void)?

    var body: some View {
        Group {
            if journal.turns.isEmpty {
                ContentUnavailableView(
                    "暂无对话",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("按住说话发出请求后，历史和进度会显示在这里")
                )
            } else {
                List {
                    if let active = journal.activeTurn {
                        Section("进行中") {
                            TurnSummaryRow(turn: active)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.cyan.opacity(0.12))
                                )
                        }
                    }

                    // ESS-307：积压条目标识 —— 在时间线中标注 iPhone 排队未投递的回合
                    let backlogIds = Set(settings.downlinkQueuedRequestIds)
                    if !backlogIds.isEmpty {
                        let backlogTurns = journal.turns.filter { backlogIds.contains($0.requestId) }
                        if !backlogTurns.isEmpty {
                            Section("等待送达（\(backlogTurns.count) 条）") {
                                ForEach(backlogTurns) { turn in
                                    TurnSummaryRow(turn: turn, isPendingDelivery: true)
                                }
                            }
                        }
                    }

                    let completed = journal.turns.filter { $0.currentState.isTerminal }
                    if !completed.isEmpty {
                        Section("已完成 (\(completed.count))") {
                            ForEach(completed) { turn in
                                NavigationLink {
                                    TurnDetailView(
                                        turn: turn,
                                        journal: journal,
                                        onContinueConversation: onContinueConversation
                                    )
                                    .navigationTitle("对话详情")
                                } label: {
                                    TurnSummaryRow(turn: turn, isPendingDelivery: false)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("历史对话")
    }
}

// MARK: - F2.1 Turn Summary Row

/// 折叠展示的历史回合行：当前投影 + 时间。
/// `isPendingDelivery` 为 true 时追加「等待送达」标识（ESS-307）。
struct TurnSummaryRow: View {
    let turn: VoiceTurnRecord
    var isPendingDelivery: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(turn.phase.title)
                    .font(.footnote.bold())
                if isPendingDelivery {
                    Text("等待送达")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack(spacing: 4) {
                Image(systemName: turn.currentState.displaySymbol)
                Text(turn.createdAt, style: .time)
                if let summary = turn.result?.displaySummary, !summary.isEmpty {
                    Text(summary)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - F2.2 Turn Detail View

/// 单轮对话详情：逐步处理日志 + 展开全文/重播 + 再次对话。
struct TurnDetailView: View {
    let turn: VoiceTurnRecord
    @ObservedObject var journal: VoiceTurnJournal
    var onContinueConversation: ((VoiceTurnRecord) -> Void)?

    @State private var showFullText = false

    var body: some View {
        List {
            // 处理步骤流水
            Section("处理步骤") {
                ForEach(Array(turn.events.enumerated()), id: \.offset) { index, event in
                    timelineRow(event: event, isLast: index == turn.events.count - 1)
                }

                // 权限确认
                if let decision = turn.permissionApproved {
                    Label(
                        decision ? "你已允许，等待执行" : "你已拒绝",
                        systemImage: decision ? "hand.thumbsup.fill" : "hand.raised.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(decision ? .green : .orange)
                }

                // 打断标记
                if turn.playbackInterruptedAt != nil {
                    Label("你打断了语音播放", systemImage: "hand.tap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // 语音降级
                if turn.resultAudioErrorCode != nil {
                    Label("语音未播出，文字仍可查看", systemImage: "speaker.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // 结果
            if let result = turn.result, !result.summary.isEmpty {
                Section("结果") {
                    if showFullText {
                        Text(result.summary)
                            .font(.footnote)
                    } else {
                        Text(result.displaySummary)
                            .font(.footnote)
                            .lineLimit(3)

                        if result.displayIsTruncated || result.summary.count > 60 {
                            Button("查看全文") { showFullText = true }
                                .font(.caption)
                        }
                    }

                    // 重播按钮
                    if turn.speechFileName != nil {
                        Button {
                            replayAudio()
                        } label: {
                            Label("重新播放语音", systemImage: "speaker.wave.2.fill")
                        }
                        .font(.caption)
                    }
                }
            }

            // 再次对话
            if turn.currentState.isTerminal {
                Section {
                    Button {
                        onContinueConversation?(turn)
                    } label: {
                        Label("再次对话", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                }
            }
        }
    }

    // MARK: Timeline Row

    @ViewBuilder
    private func timelineRow(event: VoiceTurnEvent, isLast: Bool) -> some View {
        let isFailed = event.state == .failed
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: event.state.displaySymbol)
                .font(.caption)
                .foregroundStyle(isLast ? color(for: event.state) : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(stepTitle(for: event))
                    .font(isLast ? .footnote.bold() : .footnote)
                    .foregroundStyle(isFailed ? .red : (isLast ? .primary : .secondary))

                // F2.2 克制原则：每步最多一行 ≤12 字，不显示 request_id，不显示裸错误码
                if let detail = sanitizedDetail(for: event), !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(isFailed ? .red.opacity(0.7) : .secondary)
                        .lineLimit(1)
                }

                Text(event.at, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// F2.2：每步一行、最多 12 个字，剔除 request_id 和裸错误码。
    private func stepTitle(for event: VoiceTurnEvent) -> String {
        if event.state == .failed, let stage = turn.failureStage {
            return String(stage.displayName.prefix(12))
        }
        return String(event.state.displayTitle.prefix(12))
    }

    /// F2.2：过滤 request_id 和裸错误码（ERR_*），只保留用户可读的细节文本。
    private func sanitizedDetail(for event: VoiceTurnEvent) -> String? {
        guard let detail = event.detail, !detail.isEmpty else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == turn.requestId { return nil }
        if trimmed.hasPrefix("ERR_") { return nil }
        return String(trimmed.prefix(12))
    }

    private func color(for state: VoiceTurnState) -> Color {
        switch state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .permissionRequired: return .orange
        case .waitingForPhone, .waitingForMac: return .teal
        default: return .cyan
        }
    }

    private func replayAudio() {
        // TODO: ESS-317 — wire up to SpeechPlayer for replay from EncryptedAudioVault
        WatchLog.info("history", "replay_tapped", detail: "request_id=\(turn.requestId)")
    }
}
