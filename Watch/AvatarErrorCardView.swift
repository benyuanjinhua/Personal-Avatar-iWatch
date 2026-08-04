import SwiftUI

/// ESS-180：屏幕分身错误卡片。
/// - 头像 + 文案 + 单个「知道了」按钮；淡入 0.25s；停留最少 5s；
/// - ESS-205：「知道了」在 5s 门槛内视觉禁用，避免用户以为可以立即关掉
///   （presenter 也会 nil 出去前再校验一次，两层门禁）。
/// - ESS-180-B：语音播放失败（audioAttempted=false）时在按钮上方露出「静音
///   提醒（无语音）」小字，让用户明确知道「文字 + 触觉」是降级通道，绝不
///   静音吞错。
struct AvatarErrorCardView: View {
    let presentation: AvatarErrorPresenter.Presentation
    let onDismiss: () -> Void

    var body: some View {
        // ESS-205：TimelineView 每秒重算，让按钮到时自动从禁用切到可用；
        // 不需要绑父视图的状态，卡片自带门禁。
        TimelineView(.periodic(from: presentation.showsAt, by: 1)) { context in
            let dismissable = context.date >= presentation.dismissAt
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text("AI 分身提醒")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                }

                Text(presentation.entry.text)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !presentation.audioAttempted {
                    Label("静音提醒（无语音）", systemImage: "speaker.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("知道了", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .disabled(!dismissable)
                    .opacity(dismissable ? 1.0 : 0.5)
            }
            .padding(10)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("分身错误提醒：\(presentation.entry.text)"))
        }
    }
}
