import SwiftUI

/// ESS-317 历史对话（②屏）：倒序展示历史轮次，每行：时间 + 用户问句摘要 +
/// 状态图标（成功/失败/已打断）。点进一轮进入 TurnDetailView。
struct ConversationHistoryView: View {
    @ObservedObject var journal: VoiceTurnJournal
    let pushToTalk: PushToTalkController

    /// 应用层导航状态：点「再次对话」后跳回①屏
    @Binding var selectedTab: Int

    var body: some View {
        Group {
            if journal.turns.isEmpty {
                ContentUnavailableView(
                    "暂无历史对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("按住说话开始对话后，历史记录会显示在这里")
                )
            } else {
                List {
                    ForEach(journal.turns) { turn in
                        let children = journal.turns.filter {
                            $0.parentRequestId == turn.requestId
                        }
                        // 子轮次挂在父轮下缩进显示
                        if turn.parentRequestId == nil {
                            Section {
                                TurnHistoryRow(
                                    turn: turn,
                                    pushToTalk: pushToTalk,
                                    selectedTab: $selectedTab
                                )
                                ForEach(children) { child in
                                    TurnHistoryRow(
                                        turn: child,
                                        pushToTalk: pushToTalk,
                                        selectedTab: $selectedTab,
                                        isChild: true
                                    )
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

/// 单行历史轮次：时间 + 摘要（ASR 首行） + 状态图标。
/// 子轮次（再次对话产生）左缩进以示层级。
struct TurnHistoryRow: View {
    let turn: VoiceTurnRecord
    let pushToTalk: PushToTalkController
    @Binding var selectedTab: Int
    var isChild: Bool = false

    var body: some View {
        NavigationLink {
            TurnDetailView(
                turn: turn,
                pushToTalk: pushToTalk,
                selectedTab: $selectedTab
            )
        } label: {
            HStack(spacing: 6) {
                if isChild {
                    // 子轮次缩进
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    // 摘要：取结果摘要（ASR 文本）的首行
                    Text(summaryText)
                        .font(.footnote)
                        .lineLimit(isChild ? 1 : 2)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text(turn.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if isChild, let ctx = turn.contextText, !ctx.isEmpty {
                            Text("续：\(String(ctx.prefix(20)))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        if turn.playbackInterruptedAt != nil {
                            Text("已打断")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 投影

    /// 摘要文本：优先用 result.displaySummary 首行，其次用 contextText，
    /// 都没有则用回合状态标题
    private var summaryText: String {
        if let result = turn.result, !result.displaySummary.isEmpty {
            let firstLine = result.displaySummary
                .components(separatedBy: .newlines)
                .first ?? result.displaySummary
            return firstLine
        }
        if let ctx = turn.contextText, !ctx.isEmpty {
            return ctx
        }
        return turn.phase.title
    }

    /// 状态图标：成功=✓、失败=✗、已打断=⏸、进行中=进度轮
    private var statusIcon: String {
        switch turn.currentState {
        case .completed:
            return turn.playbackInterruptedAt != nil
                ? "hand.point.up.left.fill"
                : "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "minus.circle.fill"
        default:
            return "circle.dotted"
        }
    }

    /// 状态颜色：成功=绿、失败=红、打断/取消=灰、进行中=蓝
    private var statusColor: Color {
        switch turn.currentState {
        case .completed:
            return turn.playbackInterruptedAt != nil ? .secondary : .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        default:
            return .cyan
        }
    }
}
