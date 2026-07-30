import SwiftUI

struct CompanionContentView: View {
    @EnvironmentObject private var settings: CompanionSettings
    @EnvironmentObject private var connectivity: PhoneConnectivity
    @State private var tokenVisible = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("运行模式", selection: binding(\.mode)) {
                        Text("离线演示").tag(ConnectionMode.demo)
                        Text("云端 Agent").tag(ConnectionMode.cloud)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(settings.configuration.mode == .demo
                         ? "无需服务器即可在手表上体验完整流程。"
                         : "语音会发送到你配置的 HTTPS Agent Gateway。")
                }

                if settings.configuration.mode == .cloud {
                    Section("云端 Agent") {
                        TextField("https://agent.example.com", text: binding(\.endpoint))
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        HStack {
                            if tokenVisible {
                                TextField("Bearer Token", text: binding(\.bearerToken))
                            } else {
                                SecureField("Bearer Token", text: binding(\.bearerToken))
                            }
                            Button {
                                tokenVisible.toggle()
                            } label: {
                                Image(systemName: tokenVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("手表体验") {
                    Toggle("打开后立即聆听", isOn: binding(\.autoListen))
                    Toggle("触感反馈", isOn: binding(\.hapticsEnabled))
                    Toggle("只播报简短结论", isOn: binding(\.conciseReply))
                }

                Section("连接状态") {
                    Label(connectivity.status, systemImage: "applewatch.radiowaves.left.and.right")
                    Button("立即同步到手表") {
                        connectivity.send(settings.configuration)
                    }
                }

                Section("历史对话") {
                    NavigationLink {
                        PhoneHistoryListView(entries: connectivity.history)
                    } label: {
                        LabeledContent {
                            Text("\(connectivity.history.count) 条")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("查看历史对话", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                Section {
                    LabeledContent("接口协议", value: "Docs/API.md")
                } footer: {
                    Text("API 协议随工程保存在 Docs/API.md。高风险动作始终需要在手表上确认。")
                }
            }
            .navigationTitle("腕语")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { settings.configuration[keyPath: keyPath] },
            set: {
                var copy = settings.configuration
                copy[keyPath: keyPath] = $0
                settings.configuration = copy
            }
        )
    }
}
