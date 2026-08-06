import SwiftUI

struct CompanionContentView: View {
    @EnvironmentObject private var settings: CompanionSettings
    @EnvironmentObject private var connectivity: PhoneConnectivity
    @State private var tokenVisible = false
    @State private var pairingCode = ""

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
                         : "语音默认通过 iPhone 直连 Audio Realtime Agent。")
                }

                if settings.configuration.mode == .cloud {
                    Section {
                        Toggle("启用 Audio Realtime 直连", isOn: $settings.realtimeDirectEnabled)
                        TextField("wss://agent.example.com/api/realtime", text: $settings.realtimeGatewayURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        HStack {
                            if tokenVisible {
                                TextField("长期密钥", text: $settings.realtimeCredential)
                            } else {
                                SecureField("长期密钥", text: $settings.realtimeCredential)
                            }
                            Button {
                                tokenVisible.toggle()
                            } label: {
                                Image(systemName: tokenVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                        }
                        if let message = settings.realtimeValidationMessage {
                            Text(message).foregroundStyle(.red).font(.caption)
                        } else {
                            LabeledContent("密钥", value: settings.realtimeCredentialSummary)
                                .font(.caption)
                        }
                    } header: {
                        Text("Audio Realtime Agent")
                    } footer: {
                        Text("仅接受 wss:// 地址。长期密钥与配对取得的设备 ID 一起保存在本机 Keychain，不会同步到 Apple Watch 或写入日志。")
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

                Section("语音收件箱（PoC）") {
                    Label(connectivity.voiceStatus, systemImage: "waveform.circle")
                        .font(.footnote)
                    ForEach(connectivity.voiceEntries.suffix(5).reversed()) { entry in
                        LabeledContent {
                            Text("\(entry.durationMs) ms · \(entry.sizeBytes / 1024) KB")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } label: {
                            Text(entry.requestId.prefix(8) + "…")
                                .font(.caption.monospaced())
                        }
                    }
                    if !connectivity.voiceEntries.isEmpty {
                        LabeledContent("累计接收", value: "\(connectivity.voiceEntries.count) 条")
                    }
                }

                Section("Mac Relay（ESS-28）") {
                    Label(connectivity.relay.relayStatus, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                    LabeledContent("事件通道", value: connectivity.relay.eventsConnected ? "已连接" : "未连接")
                        .font(.footnote)
                    let queued = connectivity.relay.outboxEntries.filter { $0.state == .queued }
                    if !queued.isEmpty {
                        LabeledContent("待上送", value: "\(queued.count) 条")
                            .font(.footnote)
                    }
                    TextField("Bridge 地址（tailnet）", text: Binding(
                        get: { connectivity.relay.bridgeURLString },
                        set: { connectivity.relay.bridgeURLString = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .font(.footnote)
                    if !connectivity.relay.isPaired {
                        HStack {
                            TextField("配对码", text: $pairingCode)
                                .textInputAutocapitalization(.never)
                            Button("配对") {
                                let code = pairingCode
                                Task { await connectivity.relay.pair(code: code, deviceName: "Jackson-iPhone") }
                            }
                            .disabled(pairingCode.isEmpty)
                        }
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
