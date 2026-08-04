import SwiftUI

/// 状态时间线（ESS-29）：把 §6 状态机的每一步以用户可读方式展示。
/// 当前回合展开完整时间线，更早的回合折叠成一行可点开。
struct ConversationTimelineView: View {
    @ObservedObject var journal: VoiceTurnJournal
    /// ESS-307：iPhone 下行队列积压信息，用于标注「等待送达」状态。
    @ObservedObject var settings: WatchSettingsStore

    var body: some View {
        Group {
            if journal.turns.isEmpty {
                ContentUnavailableView(
                    "暂无语音请求",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("按住说话发出请求后，进度会显示在这里")
                )
            } else {
                List {
                    if let active = journal.activeTurn {
                        Section("当前请求") {
                            TurnTimelineSection(turn: active)
                        }
                    }

                    // ESS-307：积压条目标识 —— 在时间线中标注 iPhone 排队未投递的回合
                    let backlogIds = Set(settings.downlinkQueuedRequestIds)
                    if !backlogIds.isEmpty {
                        let backlogTurns = journal.turns.filter { backlogIds.contains($0.requestId) }
                        if !backlogTurns.isEmpty {
                            Section("等待送达（\\(backlogTurns.count) 条）") {
                                ForEach(backlogTurns) { turn in
                                    TurnSummaryRow(turn: turn, isPendingDelivery: true)
                                }
                            }
                        }
                    }

                    let others = journal.turns.filter { $0.requestId != journal.activeTurn?.requestId }
                    if !others.isEmpty {
                        Section("更早") {
                            ForEach(others) { turn in
                                NavigationLink {
                                    List { TurnTimelineSection(turn: turn) }
                                        .navigationTitle("请求详情")
                                } label: {
                                    TurnSummaryRow(turn: turn, isPendingDelivery: false)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("状态时间线")
    }
}

/// 单个回合的时间线：一行一个状态事件，最后一行是当前状态。
struct TurnTimelineSection: View {
    let turn: VoiceTurnRecord

    var body: some View {
        ForEach(Array(turn.events.enumerated()), id: \.offset) { index, event in
            let isCurrent = index == turn.events.count - 1
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: event.state.displaySymbol)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? color(for: event.state) : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title(for: event))
                        .font(isCurrent ? .footnote.bold() : .footnote)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(event.at, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }

        if let decision = turn.permissionApproved {
            Label(decision ? "你已允许，等待执行" : "你已拒绝，本回合不会执行",
                  systemImage: decision ? "hand.thumbsup.fill" : "hand.raised.fill")
                .font(.caption2)
                .foregroundStyle(decision ? .green : .orange)
        }

        // ESS-259 B-STOP：用户轻点字幕区打断结果语音后追加一行「已打断」——
        // 回合状态仍是 `.completed`（不算失败），语音留在加密仓可重播。
        if turn.playbackInterruptedAt != nil {
            Label("你打断了语音播放（可重播）", systemImage: "hand.tap")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        // resultAudioErrorCode 由 journal 持久化；App 冷启动后时间线仍保留
        // 「文字已到、语音未播出」的事实，而不是把 completed 展示成全成功。
        if turn.resultAudioErrorCode != nil {
            Label("语音未播出，可查看文字或重播", systemImage: "speaker.slash.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func title(for event: VoiceTurnEvent) -> String {
        if event.state == .failed, let stage = turn.failureStage {
            return stage.displayName
        }
        return event.state.displayTitle
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
