import SwiftUI

/// 状态时间线（ESS-29）：把 §6 状态机的每一步以用户可读方式展示。
/// 当前回合展开完整时间线，更早的回合折叠成一行可点开。
/// 诊断入口放在本页底部（ESS-53 §3）：调试信息离开主屏，但排障时两步可达。
struct ConversationTimelineView: View {
    @ObservedObject var journal: VoiceTurnJournal
    @ObservedObject var transport: WatchVoiceTransport

    var body: some View {
        List {
            if journal.turns.isEmpty {
                ContentUnavailableView(
                    "暂无语音请求",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("按住说话发出请求后，进度会显示在这里")
                )
                .listRowBackground(Color.clear)
            }

            if let active = journal.activeTurn {
                Section("当前请求") {
                    TurnTimelineSection(turn: active)
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
                            TurnSummaryRow(turn: turn)
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    DiagnosticsView(transport: transport, journal: journal)
                } label: {
                    Label("诊断", systemImage: "stethoscope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
struct TurnSummaryRow: View {
    let turn: VoiceTurnRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.phase.title)
                .font(.footnote.bold())
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
