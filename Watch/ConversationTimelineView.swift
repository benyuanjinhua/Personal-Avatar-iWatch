import SwiftUI

/// 历史对话（ESS-317 / ESS-242 ②屏）：轮次列表 → 逐步处理日志 → 展开全文/重播 → 再次对话。
///
/// 由 ESS-280 从主屏 NavigationLink 抬升为 `TabView` 第 2 屏（tag=1）。
struct ConversationTimelineView: View {
    @ObservedObject var journal: VoiceTurnJournal
    /// ESS-307：iPhone 下行队列积压信息，用于标注「等待送达」状态。
    @ObservedObject var settings: WatchSettingsStore
    /// ESS-317：用于重播语音和「再次对话」上下文。
    @ObservedObject var pushToTalk: PushToTalkController
    /// 点击「再次对话」时通知父视图切回主屏。
    @Binding var selectedTab: Int

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
                                        pushToTalk: pushToTalk,
                                        selectedTab: $selectedTab
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
/// ESS-317: 重播通过 PushToTalkController.playResult 接入 SpeechPlayer；
/// 上下文通过 pushToTalk.prepareReChat 传递。
struct TurnDetailView: View {
    let turn: VoiceTurnRecord
    @ObservedObject var pushToTalk: PushToTalkController
    @Binding var selectedTab: Int

    @State private var showFullText = false
    @State private var isReplaying = false

    var body: some View {
        List {
            Section("处理步骤") {
                ForEach(Array(turn.events.enumerated()), id: \.offset) { index, event in
                    timelineRow(event: event, isLast: index == turn.events.count - 1)
                }

                if let decision = turn.permissionApproved {
                    Label(
                        decision ? "你已允许，等待执行" : "你已拒绝",
                        systemImage: decision ? "hand.thumbsup.fill" : "hand.raised.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(decision ? .green : .orange)
                }

                if turn.playbackInterruptedAt != nil {
                    Label("你打断了语音播放", systemImage: "hand.tap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if turn.resultAudioErrorCode != nil {
                    Label("语音未播出，文字仍可查看", systemImage: "speaker.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

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

                    if turn.speechFileName != nil {
                        Button {
                            isReplaying = true
                            pushToTalk.playResult(for: turn)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                isReplaying = false
                            }
                        } label: {
                            Label(
                                isReplaying ? "播放中…" : "重新播放语音",
                                systemImage: isReplaying ? "speaker.wave.2.fill" : "play.circle.fill"
                            )
                        }
                        .font(.caption)
                        .disabled(isReplaying)
                    }
                }
            }

            if turn.currentState.isTerminal {
                Section {
                    Button {
                        pushToTalk.prepareReChat(from: turn)
                        selectedTab = 0
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

                if let detail = sanitizedDetail(event.detail), !detail.isEmpty {
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

    /// 每步极简中文标签（≤12 字），不截断。
    private func stepTitle(for event: VoiceTurnEvent) -> String {
        if event.state == .failed, let stage = turn.failureStage {
            return stage.displayName
        }
        switch event.state {
        case .recorded:            return "已录音"
        case .waitingForPhone:     return "等待手机"
        case .waitingForMac:       return "已到手机"
        case .accepted:            return "已受理"
        case .realtimeProcessing:  return "实时处理中"
        case .backgroundAccepted:  return "后台已受理"
        case .backgroundProcessing:return "后台执行中"
        case .permissionRequired:  return "需要确认"
        case .completed:           return "结果就绪"
        case .failed:              return "处理失败"
        case .cancelled:           return "已取消"
        }
    }

    /// 过滤 detail 中的 request_id、ERR_* 错误码、裸数字码（如 -50、561145203）。
    private func sanitizedDetail(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var text = raw
        if text.contains(turn.requestId) {
            text = text.replacingOccurrences(of: turn.requestId, with: "")
        }
        text = text.replacingOccurrences(
            of: #"ERR_[A-Z_]+"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\b-?\d{2,}\b"#,
            with: "",
            options: .regularExpression
        )
        let trimmed = text.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ",;: ")))
        guard !trimmed.isEmpty else { return nil }
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
}
