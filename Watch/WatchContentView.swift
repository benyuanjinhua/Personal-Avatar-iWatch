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
    /// ESS-280（R1 生效）：设置页承载流式开关与自检；首屏不消费本对象，
    /// 但需要传给 `WatchSettingsView`（TabView 第 2 页）。
    @ObservedObject private var debugSettings: WatchDebugSettings
    /// ESS-280 方案 A（PM Jackson Bai 2026-08-04 拍板；R-04.6 后一条覆盖前一条）：
    /// 三屏结构 —— 0 = 主界面、1 = 状态时间线（原挂在主屏 NavigationLink 下的
    /// `ConversationTimelineView` 抬升为独立屏）、2 = 设置。冷启动落 tag 0。
    /// 白梦林原话「右滑第 3 屏设置」字面成立即靠这里的 tag 2。
    @State private var selectedTab: Int = 0

    init(
        pushToTalk: PushToTalkController,
        welcome: WelcomeGreeter,
        selfCheck: SelfCheckRunner,
        debugSettings: WatchDebugSettings
    ) {
        self.pushToTalk = pushToTalk
        self.welcome = welcome
        self.selfCheck = selfCheck
        self.transport = pushToTalk.transport
        self.journal = pushToTalk.journal
        self.player = pushToTalk.player
        self.notifier = pushToTalk.notifier
        self.errorPresenter = pushToTalk.errorPresenter
        self.debugSettings = debugSettings
    }

    var body: some View {
        // ESS-280 方案 A：`TabView(.page)` 三屏 —— 0=主界面、1=状态时间线、
        // 2=设置。用 SwiftUI 惯用 `.tabViewStyle(.page)` 让 watchOS 支持横滑
        // 分屏。每个 tab 各自包一层 NavigationStack 以保留标题与 push 语义
        // （时间线内更早回合的详情、设置屏内的自检重跑）。
        TabView(selection: $selectedTab) {
            mainScreen
                .tag(0)

            NavigationStack {
                ConversationTimelineView(journal: journal)
            }
            .tag(1)

            NavigationStack {
                WatchSettingsView(selfCheck: selfCheck, debugSettings: debugSettings)
            }
            .tag(2)
        }
        .tabViewStyle(.page)
        // 字幕式播放视图（ESS-48）：播放开始/纯文本结果到达时由控制器置入会话。
        // ESS-259 B-STOP：正在播放本回合语音时轻点字幕区打断，只清播放不改状态、
        // 不重新入队、不算失败——参见 `PushToTalkController.stopPlaybackByUser`。
        .sheet(item: $pushToTalk.subtitleSession) { session in
            SubtitlePlaybackView(session: session, player: pushToTalk.player) {
                pushToTalk.stopPlaybackByUser(requestId: session.requestId)
            }
        }
    }

    // MARK: - 屏 0：主界面

    private var mainScreen: some View {
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

                    // ESS-163：装机自检的过程/结果不再默认铺在首屏；
                    // ESS-280 R1 生效后统一收进设置页（TabView 第 3 屏）。
                    // 日志证据（selfcheck_*）不变，ESS-65 铁律 3/5 通过设置页
                    // 内的重跑按钮与业务入口独立保留。

                    // ESS-180：主界面禁止「已等待 N 秒」——处理中只允许语义化
                    // 阶段词（正在思考…/正在查询…），30/60 秒切换文案而非数秒。
                    // TimelineView 触发文案切换（不显示秒数），每 5 秒重算已够。
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let status = statusCopy(now: context.date)
                        VStack(spacing: 10) {
                            // ESS-280 R1 生效：删除 ESS-163 的「长按标题 2s 进 Debug 面板」
                            // 隐藏手势 —— 与 D3「不许隐藏交互」冲突。设置入口改由
                            // TabView 右滑第 2 屏承担，显式可见。
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

                    // ESS-258 / D1 铁律 + D3 铁律 1：15s 无 iPhone 回执触发的
                    // `iphone_relay_stuck` 触觉必须在屏幕上有对应格子。这是
                    // S-THINK 的 mid-turn 提示，非终态——回执随后到达时
                    // `cancelIphoneRelayWatchdog` 会把 requestId 从集合里移出，
                    // SwiftUI 自动撤下本 banner，不残留。
                    if let stuckRequestId = activeStuckRequestId {
                        iphoneRelayStuckHint(requestId: stuckRequestId)
                    }

                    // ESS-55 JIT 通知授权：只在首次长任务场景出现，冷启动不弹；
                    // 「暂不」永久收起，降级为触觉 + 未读，不再骚扰。
                    if notifier.shouldPromptAuthorization {
                        notificationPromptCard
                    }

                    if let turn = activeTurn {
                        turnContent(turn)
                    }

                    // ESS-280 方案 A（R1 生效）：状态时间线抬升为 TabView 第 2 屏
                    // （右滑一次到达），主界面不再放跳转按钮；设置在第 3 屏
                    // （右滑到底），显式可见，不再走 ESS-163 的长按隐藏手势。

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

    // MARK: - iPhone Relay 15s 无回执提示（ESS-258 / Gap-2）

    /// 当前活跃回合被 15s watchdog 判为「iPhone 侧无回执」的 requestId。
    /// 只有既是活跃回合、又在 stuck 集合里才返回；`cancelIphoneRelayWatchdog`
    /// 撤下集合成员后本值即为 nil，SwiftUI 自动隐藏 banner。
    private var activeStuckRequestId: String? {
        Self.stuckRequestIdToShow(activeTurn: activeTurn, stuckRequestIds: transport.iphoneRelayStuckRequestIds)
    }

    /// 纯函数抽出便于 WatchTests 覆盖 UI 决策：只有回合仍在活跃、且该
    /// requestId 落进 stuck 集合时才返回，其余（无回合 / 已进终态 /
    /// 集合不包含）返回 nil。
    static func stuckRequestIdToShow(activeTurn: VoiceTurnRecord?, stuckRequestIds: Set<String>) -> String? {
        guard let turn = activeTurn, turn.isActive else { return nil }
        return stuckRequestIds.contains(turn.requestId) ? turn.requestId : nil
    }

    /// 非终态提示格子：文案遵循 D2 原则——第一人称分身、说清发生了什么 +
    /// 能做什么 + 系统兜底，不出现裸码、不出现 D2.3 禁用词。视觉用暖黄
    /// 与错误红区分（这不是失败终态，回执可能随后就到）。
    /// `.onAppear` 里落 `iphone_relay_stuck_shown` 是 R-02.1 运行时证据：
    /// 它与 `transport` 侧的 `iphone_relay_stuck`（触觉发起点）成对出现，
    /// 证明「触觉 + 屏幕格子」同回合同时到位。
    private func iphoneRelayStuckHint(requestId: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("手机那边还没回话", systemImage: "iphone.gen3.slash")
                .font(.caption2.bold())
                .foregroundStyle(.yellow)
            Text("去手机上打开一次 WristAgent，接通后我会自动继续；不用再说一遍。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { Self.logIphoneRelayStuckShown(requestId: requestId) }
    }

    /// 抽出便于 WatchTests 覆盖 R-02.1 证据：与 transport 侧的
    /// `iphone_relay_stuck`（触觉发起）成对出现，证明「触觉 + 屏幕格子」
    /// 同回合同时到位（D3 铁律 1）。事件名 / detail 变化会改变链上工具
    /// 的解析口径，改前先看 Scripts/*.mjs。
    static func logIphoneRelayStuckShown(requestId: String) {
        WatchLog.info(
            "ui", "iphone_relay_stuck_shown", requestId: requestId,
            detail: "surface=main_screen"
        )
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
        // ESS-257：是否允许重试由 `ErrorCueCatalog.cue(for:).recoveryFamily`
        // 决定——族 H（`ERR_RESULT_UNKNOWN` + `manual_confirmation_required`）
        // 明确禁止重试，避免重复执行一个可能已生效的写操作。视图不再按
        // code 硬编码分支，恢复族判定集中在 catalog。
        if case .failed = turn.phase,
           ErrorCueCatalog.cue(for: turn.errorCode).recoveryFamily.allowsCachedRetry {
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

            // 错误码随 VoiceTurnJournal 落盘；冷启动恢复后仍明确告诉用户
            // 本轮只有文字结果、语音没有成功播出，避免 completed 被误读为已听见。
            if turn.resultAudioErrorCode != nil {
                Label("语音未播出，可查看文字或重播", systemImage: "speaker.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
