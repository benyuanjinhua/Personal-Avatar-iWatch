import SwiftUI

/// ESS-180：屏幕分身错误卡片。
/// - 头像 + 文案 + 单个「知道了」按钮；淡入 0.25s；停留最少 5s；
/// - 语音降级路径（audioAttempted=false）附加「静音提醒」小字，用户知道
///   触觉是唯一的听觉降级替代——不装作正常语音出去了。
struct AvatarErrorCardView: View {
    let presentation: AvatarErrorPresenter.Presentation
    let onDismiss: () -> Void

    var body: some View {
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

            // ESS-180-B 会补 5 条语气语音；届时 audioAttempted=false 才有意义。
            // 本包（180-A）不打包语音，暂不展示「静音提醒」小字，避免误导用户
            // 以为可以通过设置开启语音。
            Button("知道了", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .font(.caption)
                .frame(maxWidth: .infinity)
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
