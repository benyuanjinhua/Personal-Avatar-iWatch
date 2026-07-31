import SwiftUI

/// 权限确认卡片（ESS-29 / §5.3）：“允许修改 X 文件？”
/// 只对当前回合生效；未确认前 Mac 不执行。决定经 iPhone 签名后回传。
struct PermissionRequestView: View {
    let permission: VoicePermissionPayload
    let decision: Bool?
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(permission.summary, systemImage: "exclamationmark.shield.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("操作：\(permission.action)")
                Text("对象：\(permission.target)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let decision {
                Label(decision ? "已允许，等待执行" : "已拒绝，本回合不会执行",
                      systemImage: decision ? "hand.thumbsup.fill" : "hand.raised.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(decision ? .green : .orange)
            } else {
                HStack(spacing: 6) {
                    Button {
                        respond(false)
                    } label: {
                        Text("拒绝")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button {
                        respond(true)
                    } label: {
                        Text("允许")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .font(.footnote)

                Text("未确认前不会执行")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}
