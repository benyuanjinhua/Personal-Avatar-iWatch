import SwiftUI

/// 主界面（ESS-40）：首屏即「按住说话」真实链路（ESS-29 PoC 转正，静态 demo 已删除）。
/// 要素：语音球 + 状态文案 + 按住说话手势 + 结果时间线入口 + 欢迎语（下行音频链验证）。
/// 半双工：录完即传；退出 App 任务继续，重开从 VoiceTurnJournal 恢复。
struct WatchContentView: View {
    @ObservedObject private var pushToTalk: PushToTalkController
    @ObservedObject private var welcome: WelcomeGreeter
    @ObservedObject private var selfCheck: SelfCheckRunner
    @ObservedObject private var transport: WatchVoiceTransport
    @ObservedObject private var journal: VoiceTurnJournal
    @ObservedObject private var player: SpeechPlayer
    @ObservedObject private var notifier: ResultNotifier
    /// ESS-180：屏幕分身错误卡片状态机。
    @ObservedObject private var errorPresenter: AvatarErrorPresenter

    init(pushToTalk: PushToTalkController, welcome: WelcomeGreeter, selfCheck: SelfCheckRunner) {
        self.pushToTalk = pushToTalk
        self.welcome = welcome
        self.selfCheck = selfCheck
        self.transport = pushToTalk.transport
        self.journal = pushToTalk.journal
        self.player = pushToTalk.player
        self.notifier = pushToTalk.notifier
        self.errorPresenter = pushToTalk.errorPresenter
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    // ESS-180：屏幕分身错误卡片放在顶部，确保失败终态永远
                    // 压在等待文案之上——白梦林原始 bug 就是「仍在等 Mac」
                    // 压过了失败终态，让用户傻等 85 秒。
                    if let error = errorPresenter.active {
                        AvatarErrorCardView(presentation: error) {
                            errorPresenter.dismiss()
                        }
                    }

                    transportControls

                    VoiceOrbView(mode: orbMode, size: 70)
                        .padding(.top, 4)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    welcome.interrupt()
                                    // ESS-65 铁律 3：自检绝不锁死 App——用户按住说话
                                    // 即打断自检让出音频会话，结论记 inconclusive。
                                    selfCheck.interrupt()
                                    pushToTalk.pressBegan()
                                }
                                .onEnded { _ in pushToTalk.pressEnded() }
                        )

                    if showWelcomeBanner {
                        welcomeBanner
                    }

                    // ESS-65 / G9：自检期间必须有明确提示（铁律 4），
                    // 没通过时给出可区分「代码坏了 / 没授权」的文案 + 手动重跑（铁律 5）。
                    if selfCheck.isRunning {
                        selfCheckRunningBanner
                    } else if let attention = selfCheck.pendingAttention {
                        selfCheckAttentionCard(attention)
                    }

                    // ESS-180：主界面禁止「已等待 N 秒」——处理中只允许语义化
                    // 阶段词（正在思考…/正在查询…），30/60 秒切换文案而非数秒。
                    // TimelineView 触发文案切换（不显示秒数），每 5 秒重算已够。
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let status = statusCopy(now: context.date)
                        VStack(spacing: 10) {
                            Text(status.title)
                                .font(.footnote.bold())
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(status.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                        }
                        .onChange(of: context.date) { _, now in
                            // ESS-180：错误卡片最少停留 5s，到点由 UI 心跳负责收起。
                            if errorPresenter.shouldAutoDismiss(now: now) {
                                errorPresenter.dismiss()
                            }
                        }
                    }

                    if transport.pendingCount > 0 {
                        Text("待送达 \(transport.pendingCount) 条")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    // ESS-55 JIT 通知授权：只在首次长任务场景出现，冷启动不弹；
                    // 「暂不」永久收起，降级为触觉 + 未读，不再骚扰。
                    if notifier.shouldPromptAuthorization {
                        notificationPromptCard
                    }

                    if let turn = activeTurn {
                        turnContent(turn)
                    }

                    NavigationLink {
                        ConversationTimelineView(journal: journal)
                    } label: {
                        Label("状态时间线", systemImage: "list.bullet.rectangle")
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    if let remote = transport.remoteStatus,
                       remote.requestId != activeTurn?.requestId {
                        Text(remote.detail ?? remote.phase.displayText)
                            .font(.caption2)
                            .foregroundStyle(remote.phase == .failed ? .red : .secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        // 结果语音的自动播放已下沉到 PushToTalkController（journal.onSpeechAttached
        // 按 request_id 定向触发，ESS-41 B3）：不再依赖本视图挂载或该回合仍是
        // activeTurn——旧的 onChange 触发在「语音后到 + 回合已切换/已判失败」时
        // 会静默漏播。
        // 字幕式播放视图（ESS-48）：播放开始/纯文本结果到达时由控制器置入会话。
        .sheet(item: $pushToTalk.subtitleSession) { session in
            SubtitlePlaybackView(session: session, player: pushToTalk.player)
        }
    }

    private var transportControls: some View {
        VStack(spacing: 5) {
            Picker("通路", selection: $transport.mode) {
                ForEach(WatchTransportMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.navigationLink)
            .disabled(activeTurn?.isActive == true || isRecording)

            if transport.mode != .relay {
                TextField("Bridge IP 或 URL", text: $transport.bridgeHost)
                    .textInputAutocapitalization(.never)
                    .disabled(activeTurn?.isActive == true || isRecording)
                if !transport.directIsPaired {
                    SecureField("配对码", text: $transport.pairingCode)
                    Button("配对 Watch") { transport.pairDirect() }
                        .buttonStyle(.bordered)
                        .disabled(activeTurn?.isActive == true || isRecording)
                }
            }
        }
        .font(.caption2)
    }

    // MARK: - 欢迎语（ESS-40）

    private var showWelcomeBanner: Bool {
        welcome.isActive && !isRecording && activeTurn == nil
    }

    private var welcomeBanner: some View {
        VStack(spacing: 3) {
            Text(WelcomeGreeter.welcomeText)
                .font(.footnote.bold())
                .multilineTextAlignment(.center)

            if welcome.stage == .playing {
                Label("欢迎语播放中", systemImage: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 装机音频自检（ESS-65 / G9）

    private var selfCheckRunningBanner: some View {
        VStack(spacing: 3) {
            Label("正在自检音频链路，约 15 秒", systemImage: "waveform.badge.magnifyingglass")
                .font(.caption2.bold())
            Text("装机门禁 · 按住语音球可跳过")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    private func selfCheckAttentionCard(_ outcome: SelfCheckPolicy.Outcome) -> some View {
        VStack(spacing: 4) {
            Text(SelfCheckPolicy.userMessage(outcome: outcome))
                .font(.caption2)
                .multilineTextAlignment(.center)

            Button("重新自检") {
                selfCheck.rerun()
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 通知授权引导（ESS-55）

    private var notificationPromptCard: some View {
        VStack(spacing: 4) {
            Text("这个任务可能要几分钟")
                .font(.caption2.bold())
            Text("开启通知，结果好了第一时间震动提醒你")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Button("开启提醒") {
                    notifier.requestAuthorization(
                        activeLongTaskRequestId: journal.activeTurn?.requestId
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Button("暂不") {
                    notifier.declinePrompt()
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 当前回合区块

    @ViewBuilder
    private func turnContent(_ turn: VoiceTurnRecord) -> some View {
        if turn.currentState == .permissionRequired, let permission = turn.permission {
            PermissionRequestView(
                permission: permission,
                decision: turn.permissionApproved
            ) { approved in
                pushToTalk.respondPermission(approved: approved)
            }
        }

        if let result = turn.result, turn.currentState == .completed {
            resultCard(turn: turn, result: result)
        }

        // 一键重试（ESS-55）：重发缓存的录音，不需要重新说话。
        if case .failed = turn.phase {
            Button {
                pushToTalk.retry(turn: turn)
            } label: {
                Label("重试（不用重新说）", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .font(.footnote)
        }

        if turn.isActive && !isRecording && turn.currentState != .permissionRequired {
            Button("取消本次请求", role: .cancel) {
                pushToTalk.cancelActiveTurn()
            }
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultCard(turn: VoiceTurnRecord, result: VoiceResultPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.displaySummary)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

            if result.displayIsTruncated {
                Text("已截断，完整内容在 Mac 上")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if turn.speechFileName != nil {
                // ESS-58：播放被截断（锁屏挂起等）的回合显式标「未播完」，
                // 语音保留在加密仓，可从头重播——中断不静默丢失。
                let unfinished = pushToTalk.unfinishedPlaybackIds.contains(turn.requestId)
                Button {
                    pushToTalk.playResult(for: turn)
                } label: {
                    Label(
                        player.isPlaying ? "播放中…" : (unfinished ? "未播完 · 重播" : "播放语音"),
                        systemImage: player.isPlaying ? "speaker.wave.2.fill" : "play.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(unfinished ? .orange : .green)
                .font(.footnote)
                .disabled(player.isPlaying)
            }

            // 回看入口（ESS-48）：语音播完（音频交付后已删）仍可完整查看全文。
            if !result.displaySummary.isEmpty {
                Button {
                    pushToTalk.showTranscript(for: turn)
                } label: {
                    Label("查看全文", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .font(.footnote)
            }
        }
        .padding(9)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 投影

    private var isRecording: Bool { pushToTalk.state == .recording }

    private var activeTurn: VoiceTurnRecord? { journal.activeTurn }

    private var isSpeaking: Bool {
        player.isPlaying || welcome.stage == .playing
    }

    /// 语音球状态映射（ESS-29 原逻辑保留）。ESS-180-A 阶段不改球体行为，
    /// 拟人化的四态呼吸留给 180-B——本包只解决「失败被 UI 忽略」和「计时
    /// 傻等」，因此这里保持原有 8 态；失败可见性由顶部的 AvatarErrorCardView
    /// 承担。
    private var orbMode: VoiceOrbView.Mode {
        if isRecording { return .listening(level: pushToTalk.recordingLevel) }
        guard let phase = activeTurn?.phase else { return .idle }
        switch phase {
        case .sending, .waitingForPhone, .waitingForMac: return .waiting
        case .delivered, .processing: return .processing
        case .needsConfirmation: return .confirmation
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .idle
        }
    }

    /// 状态文案：ESS-180 严禁「已等待 N 秒」。处理中只允许语义化阶段词
    /// （分身正在思考… / 正在查询…），30 秒内无阶段变化则文案切换到
    /// 语义提示，60 秒后追加「任务较慢，可继续等待或取消」——数字仅用于
    /// 判定切换阈值，不出现在文本里。真实 progress 事件优先，用它的
    /// 语义文本替换阶梯文案。
    private func statusCopy(now: Date) -> MainStatusCopy {
        if isRecording {
            return MainStatusCopy(title: "我在听", subtitle: "松开发送（最长 60 秒）")
        }
        if isSpeaking {
            return MainStatusCopy(title: "AI 分身正在说话…", subtitle: "全文同步展示，可点字幕打断")
        }
        guard let turn = activeTurn, turn.isActive else {
            return MainStatusCopy(
                title: "按住说话",
                subtitle: showWelcomeBanner ? "按住语音球开始对话" : "松开即发送，结果回来会震动提醒"
            )
        }
        if let progress = currentProgress(for: turn) {
            let elapsed = now.timeIntervalSince(progress.updatedAt)
            let title = progress.detail?.isEmpty == false ? progress.detail! : progress.phase.displayText
            return MainStatusCopy(
                title: elapsed >= 60 ? "任务较慢，可继续等待或取消" : title,
                subtitle: elapsed >= 20 ? "分身还在处理…" : "分身正在处理"
            )
        }
        let lastEventAt = turn.events.last?.at ?? turn.createdAt
        let elapsed = now.timeIntervalSince(lastEventAt)
        return MainStatusCopy(
            title: processingTitle(for: turn.phase, elapsed: elapsed),
            subtitle: processingSubtitle(for: turn.phase, elapsed: elapsed)
        )
    }

    /// ESS-180 语义化阶段词：0-30s 走短文案，30s+ 换语义提示，60s+ 追加
    /// 「较慢，可继续等待或取消」。任何位置都不允许出现秒数或时:分。
    private func processingTitle(for phase: VoiceTurnPhase, elapsed: TimeInterval) -> String {
        if elapsed >= 60 { return "任务较慢，可继续等待或取消" }
        switch phase {
        case .sending: return "正在送出"
        case .waitingForPhone: return "等待手机连接"
        case .waitingForMac: return elapsed >= 30 ? "分身还在联系 Mac…" : "已到手机，等待 Mac"
        case .delivered: return elapsed >= 30 ? "分身正在准备执行…" : "Mac 已受理"
        case .processing(let background):
            if elapsed >= 30 { return background ? "分身还在跑…" : "分身还在想…" }
            return background ? "分身正在处理…" : "分身正在思考…"
        case .needsConfirmation: return "需要你的确认"
        case .completed, .failed, .cancelled: return phase.title
        }
    }

    private func processingSubtitle(for phase: VoiceTurnPhase, elapsed: TimeInterval) -> String {
        switch phase {
        case .waitingForPhone: return "手机连上后自动送出"
        case .needsConfirmation: return "未确认前不会执行"
        default:
            if elapsed >= 60 { return "分身仍在运行，可以先放下手腕" }
            return "结果好了会震动提醒"
        }
    }

    private func currentProgress(for turn: VoiceTurnRecord) -> RelayStatusUpdate? {
        guard let progress = transport.progressStatus,
              progress.requestId == turn.requestId,
              progress.phase == .backgroundProcessing else { return nil }
        return progress
    }
}
