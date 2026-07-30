import SwiftUI

struct PhoneHistoryListView: View {
    let entries: [ConversationHistoryEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "暂无对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("在 Apple Watch 上完成语音对话后，记录会自动同步到这里。")
                )
            } else {
                List(entries) { entry in
                    NavigationLink {
                        PhoneHistoryDetailView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.preview)
                                .font(.headline)
                                .lineLimit(1)
                            Text(entry.reply.isEmpty ? "等待执行结果" : entry.reply)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack {
                                Label(entry.state.phoneTitle, systemImage: entry.state.phoneSymbol)
                                    .foregroundStyle(entry.state.phoneColor)
                                Spacer()
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("历史对话")
    }
}

private struct PhoneHistoryDetailView: View {
    let entry: ConversationHistoryEntry

    var body: some View {
        List {
            Section("你说") {
                Text(entry.preview)
            }
            Section("腕语") {
                Text(entry.reply.isEmpty ? "等待执行结果" : entry.reply)
            }
            Section("执行信息") {
                LabeledContent("状态", value: entry.state.phoneTitle)
                LabeledContent("风险级别", value: entry.risk.displayName)
                LabeledContent(
                    "时间",
                    value: entry.createdAt.formatted(date: .long, time: .shortened)
                )
            }
        }
        .navigationTitle("对话详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AgentTaskState {
    var phoneTitle: String {
        switch self {
        case .completed: return "已完成"
        case .running: return "执行中"
        case .failed: return "未完成"
        case .cancelled: return "已取消"
        }
    }

    var phoneSymbol: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .running: return "ellipsis.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    var phoneColor: Color {
        switch self {
        case .completed: return .green
        case .running: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
