import SwiftUI

/// ESS-317 轮次详情：处理步骤日志 + 结果全文 + 重播 + 再次对话。
/// 手表屏宽约 184pt，每步一行、不超过 12 个字；不显示 request_id、
/// 不显示裸错误码。
struct TurnDetailView: View {
    let turn: VoiceTurnRecord
    @ObservedObject var pushToTalk: PushToTalkController
    @Binding var selectedTab: Int

    @State private var showFullResult = false
    @State private var isReplaying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                // 1. 处理步骤日志
                processingLogSection

                Divider()

                // 2. 结果全文 + 重播
                resultSection

                Spacer(minLength: 12)

                // 3. 再次对话
                reChatButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .navigationTitle(formattedTime)
    }

    // MARK: - 处理步骤日志

    private var processingLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("处理步骤")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(Array(processingSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 6) {
                    // 步骤序号圆点
                    Circle()
                        .fill(step.isFailure ? Color.red : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label)
                            .font(.footnote)
                            .foregroundStyle(step.isFailure ? .red : .primary)
                            .lineLimit(1)

                        if let detail = step.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }

                        Text(step.at, style: .time)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// 处理步骤模型：最多 12 个字，不含 request_id / 裸错误码
    private struct ProcessingStep {
        let label: String
        let detail: String?
        let at: Date
        let isFailure: Bool
    }

    /// 从 `turn.events` 映射为精简处理步骤
    private var processingSteps: [ProcessingStep] {
        var steps: [ProcessingStep] = []

        for event in turn.events {
            let label = stepLabel(for: event.state, turn: turn)
            let detail = event.detail
            let isFailure = event.state == .failed
            steps.append(ProcessingStep(
                label: label,
                detail: detail,
                at: event.at,
                isFailure: isFailure
            ))
        }

        // 如果有打断记录，追加一行
        if turn.playbackInterruptedAt != nil {
            steps.append(ProcessingStep(
                label: "你打断了播放",
                detail: nil,
                at: turn.playbackInterruptedAt!,
                isFailure: false
            ))
        }

        // 如果有语音未播出记录
        if turn.resultAudioErrorCode != nil {
            steps.append(ProcessingStep(
                label: "语音暂未播出",
                detail: nil,
                at: turn.events.last?.at ?? turn.createdAt,
                isFailure: false
            ))
        }

        return steps
    }

    /// 每个状态的极简中文标签（≤12 字）
    private func stepLabel(for state: VoiceTurnState, turn: VoiceTurnRecord) -> String {
        switch state {
        case .recorded:
            // 尝试从 events 获取录音时长 detail
            return "已录音"
        case .waitingForPhone:
            return "等待手机"
        case .waitingForMac:
            return "已到手机"
        case .accepted:
            return "已受理"
        case .realtimeProcessing:
            return "实时处理中"
        case .backgroundAccepted:
            return "后台已受理"
        case .backgroundProcessing:
            return "后台执行中"
        case .permissionRequired:
            return "需要确认"
        case .completed:
            return "结果就绪"
        case .failed:
            // 失败原因用可读文案，不用裸错误码
            if let code = turn.errorCode {
                // 截取前 12 个字符以适配手表屏宽
                let cueText = ErrorCueCatalog.cue(for: code).text
                return String(cueText.prefix(12))
            }
            return turn.failureStage?.displayName ?? "处理失败"
        case .cancelled:
            return "已取消"
        }
    }

    // MARK: - 结果全文 + 重播

    @ViewBuilder
    private var resultSection: some View {
        if let result = turn.result, !result.displaySummary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("结果")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                // 全文展开/收起
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.displaySummary)
                        .font(.footnote)
                        .lineLimit(showFullResult ? nil : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if result.displaySummary.count > 120 {
                        Button(showFullResult ? "收起" : "展开全文") {
                            withAnimation { showFullResult.toggle() }
                        }
                        .font(.caption2)
                        .tint(.cyan)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                if result.displayIsTruncated {
                    Text("已截断，完整内容在 Mac 上")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // 重播按钮
            if turn.speechFileName != nil {
                Button {
                    isReplaying = true
                    pushToTalk.playResult(for: turn)
                    // 重置状态（播放结果会让 subtitleSession 触发 sheet）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isReplaying = false
                    }
                } label: {
                    Label(
                        isReplaying ? "播放中…" : "重新播放",
                        systemImage: isReplaying ? "speaker.wave.2.fill" : "play.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .font(.footnote)
                .disabled(isReplaying)
            }
        }
    }

    // MARK: - 再次对话

    private var reChatButton: some View {
        Button {
            // 设定上下文后跳回①屏，进入 listening 态
            pushToTalk.prepareReChat(from: turn)
            selectedTab = 0
            // 延迟触发按住说话，让页面先切换
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pushToTalk.pressBegan()
            }
        } label: {
            Label("再次对话", systemImage: "arrow.uturn.left.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .font(.footnote)
        .disabled(turn.currentState.isTerminal == false)
    }

    // MARK: - 辅助

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: turn.createdAt)
    }
}
