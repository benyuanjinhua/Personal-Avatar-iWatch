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
    /// ESS-163 PD 裁定：首屏零可见开发入口，Debug 面板改用「长按主界面
    /// 标题 2 秒」隐藏手势进入，不加任何可见提示。
    @State private var showDebugPanel = false

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

                    // ESS-163：装机自检的过程/结果不再默认铺在首屏，
                    // 收进「开发者面板」入口。日志证据（selfcheck_*）不变，
                    // ESS-65 铁律 3/5 通过面板内的重跑按钮与业务入口独立保留。

                    // ESS-180：主界面禁止「已等待 N 秒」——处理中只允许语义化
                    // 阶段词（正在思考…/正在查询…），30/60 秒切换文案而非数秒。
                    // TimelineView 触发文案切换（不显示秒数），每 5 秒重算已够。
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let status = statusCopy(now: context.date)
                        VStack(spacing: 10) {
                            // ESS-163：主界面标题就是这个 status.title——长按 2 秒
                            // 唤起 Debug 面板；不加可见提示。手势不消费 tap，
                            // 语音球的 DragGesture 与欢迎语打断均不受影响。
                            Text(status.title)
                                .font(.footnote.bold())
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .contentShape(Rectangle())
                                .onLongPressGesture(minimumDuration: 2.0) {
                                    showDebugPanel = true
                                }

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

                    // ESS-163 PD 裁定：Debug 面板入口迁出首屏，改为长按主界面
                    // 标题 2 秒隐藏手势唤起（见上面 status.title 的
                    // onLongPressGesture）。此处不再放任何可见 NavigationLink /
                    // Button，避免最终用户看到开发者入口。

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
        // ESS-259 B-STOP：正在播放本回合语音时轻点字幕区打断，只清播放不改状态、
        // 不重新入队、不算失败——参见 `PushToTalkController.stopPlaybackByUser`。
        .sheet(item: $pushToTalk.subtitleSession) { session in
            SubtitlePlaybackView(session: session, player: pushToTalk.player) {
                pushToTalk.stopPlaybackByUser(requestId: session.requestId)
            }
        }
        // ESS-163：Debug 面板作为覆盖 sheet 呈现——不占用首屏导航栈，
        // 手表下滑关闭；避免 NavigationLink 在首屏留下可见项。
        .sheet(isPresented: $showDebugPanel) {
            NavigationStack {
                DebugPanelView(selfCheck: selfCheck)
            }
        }
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

    /// ESS-180-B：语音球只有四态。所有中间等待态（sending / waitingForPhone /
    /// waitingForMac / delivered / processing / needsConfirmation）统统合并到
    /// `.thinking`——中间态的可视差异改由底部文案承担，球体只表达
    /// 「输入还是输出、正在还是空闲」。终态（completed/failed/cancelled）
    /// 一律回到 idle，失败的可见证据由 `AvatarErrorCardView` 承担；这样即使
    /// 卡片被用户手动关闭，屏幕也不会残留矛盾的失败/成功球。
    private var orbMode: VoiceOrbView.Mode {
        if isRecording { return .listening(level: pushToTalk.recordingLevel) }
        if isSpeaking { return .speaking }
        guard let phase = activeTurn?.phase, activeTurn?.isActive == true else { return .idle }
        switch phase {
        case .sending, .waitingForPhone, .waitingForMac,
             .delivered, .processing, .needsConfirmation:
            return .thinking
        case .completed, .failed, .cancelled:
            return .idle
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
            // ESS-259 B-STOP：副标题承诺的「可点字幕打断」在 SubtitlePlaybackView
            // 里由 `.onTapGesture` + `PushToTalkController.stopPlaybackByUser` 兑现。
            return MainStatusCopy(title: "AI 分身正在说话…", subtitle: "全文同步展示，轻点字幕打断")
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
