import SwiftUI

/// 主界面（ESS-40）：首屏即「按住说话」真实链路（ESS-29 PoC 转正，静态 demo 已删除）。
/// 要素：语音球 + 状态文案 + 按住说话手势 + 结果时间线入口 + 欢迎语（下行音频链验证）。
/// 半双工：录完即传；退出 App 任务继续，重开从 VoiceTurnJournal 恢复。
struct WatchContentView: View {
    @ObservedObject private var pushToTalk: PushToTalkController
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
    /// ESS-307：设置页配置 + 下行积压计数。
    @ObservedObject private var settings: WatchSettingsStore
    /// ESS-573（Wave 1 / F1）：会话态主屏生命周期。isInSession 时主屏
    /// 切换为会话模式（大球偏下 + X 常驻右下角 + 手势冲突处理）。
    @ObservedObject private var session: SessionController
    /// ESS-280 方案 A（PM Jackson Bai 2026-08-04 拍板；R-04.6 后一条覆盖前一条）：
    /// 三屏结构 —— 0 = 主界面、1 = 状态时间线（原挂在主屏 NavigationLink 下的
    /// `ConversationTimelineView` 抬升为独立屏）、2 = 设置。冷启动落 tag 0。
    /// 白梦林原话「右滑第 3 屏设置」字面成立即靠这里的 tag 2。
    @State private var selectedTab: Int = 0
    /// ESS-573 / ESS-653：点球手势的 touch-down 时刻——松手时按时长判定
    /// 「点一下进电话」 vs 「长按误触（丢弃采集）」（见主屏 orb 手势）。
    @State private var orbTouchDownAt: Date?

    init(
        pushToTalk: PushToTalkController,
        selfCheck: SelfCheckRunner,
        debugSettings: WatchDebugSettings,
        settings: WatchSettingsStore,
        session: SessionController
    ) {
        self.pushToTalk = pushToTalk
        self.selfCheck = selfCheck
        self.transport = pushToTalk.transport
        self.journal = pushToTalk.journal
        self.player = pushToTalk.player
        self.notifier = pushToTalk.notifier
        self.errorPresenter = pushToTalk.errorPresenter
        self.debugSettings = debugSettings
        self.settings = settings
        self.session = session
    }

    var body: some View {
        // ESS-280 方案 A：`TabView(.page)` 三屏 —— 0=主界面、1=状态时间线、
        // 2=设置。用 SwiftUI 惯用 `.tabViewStyle(.page)` 让 watchOS 支持横滑
        // 分屏。每个 tab 各自包一层 NavigationStack 以保留标题与 push 语义
        // （时间线内更早回合的详情、设置屏内的自检重跑）。
        TabView(selection: $selectedTab) {
            mainScreen
                .tag(0)

            // ESS-573 / PRD §3.5.6：会话中左右滑切屏**禁用**——滑走等于
            // 静默丢失上下文。实现口径是「会话中②③屏根本不渲染」：
            // TabView 只剩一页，横扫无页可切，不存在拖到一半回弹的
            // 中间态（比运行时拒绝 set 更彻底）。
            if SessionController.showsAuxiliaryTabs(inSession: session.isInSession) {
                NavigationStack {
                    ConversationTimelineView(
                        journal: journal,
                        settings: settings,
                        pushToTalk: pushToTalk,
                        selectedTab: $selectedTab
                    )
                }
                .tag(1)

                NavigationStack {
                    WatchSettingsView(
                        selfCheck: selfCheck,
                        debugSettings: debugSettings,
                        settings: settings,
                        journal: pushToTalk.journal,
                        speechVault: pushToTalk.speechVault,
                        player: pushToTalk.player
                    )
                }
                .tag(2)
            }
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

    /// ESS-573：主屏双模——会话中（isInSession）整屏切换为会话态 UI
    /// （PRD §3.5.3 布局：大球偏下、X 常驻右下角、无状态文字）；待机时
    /// 为既有 PTT 内容，功能完整保留。
    private var mainScreen: some View {
        NavigationStack {
            if session.isInSession {
                sessionScreen
            } else {
                pttMainContent
            }
        }
        // 结果语音的自动播放已下沉到 PushToTalkController（journal.onSpeechAttached
        // 按 request_id 定向触发，ESS-41 B3）：不再依赖本视图挂载或该回合仍是
        // activeTurn——旧的 onChange 触发在「语音后到 + 回合已切换/已判失败」时
        // 会静默漏播。
    }

    private var pttMainContent: some View {
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
                            // ESS-653（F1 入口收敛，设计稿 v2.0 §五 D1 方案 B）：
                            // 主屏球**只有一个语义——进入持续对话**。按下立即起采，
                            // 松手只负责确认进入；按住时长不再复用旧 PTT 门槛。
                            //
                            // touch-down 起采保留（不是为 PTT 抢那几百毫秒，而是
                            // 用户按下立刻开口时首句不丢）：松手后 enterSession
                            // 认领**已经在飞**的那一轮，不重起。
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    guard orbTouchDownAt == nil else { return }
                                    orbTouchDownAt = Date()
                                    // ESS-65 铁律 3：自检绝不锁死 App——用户按下球
                                    // 即打断自检让出音频会话，结论记 inconclusive。
                                    selfCheck.interrupt()
                                    pushToTalk.pressBegan()
                                }
                                .onEnded { _ in
                                    let downAt = orbTouchDownAt
                                    orbTouchDownAt = nil
                                    let heldSeconds = downAt.map { Date().timeIntervalSince($0) } ?? .infinity
                                    switch SessionController.orbReleaseAction(
                                        holdSeconds: heldSeconds,
                                        isCapturing: pushToTalk.state == .recording
                                    ) {
                                    case .enter:
                                        // 录音已在 touch-down 开始（pressBegan 幂等，
                                        // enterSession 内部的 onBeginChannel 不会重复
                                        // 发起）；就绪由真实 uplink ack 驱动。
                                        session.enterSession()
                                    case .reject(let reason):
                                        session.noteEnterRejected(reason: reason, holdSeconds: heldSeconds)
                                        // 只有起采失败才拒绝：不提交、停采集、取消未提交
                                        // 的实时回合并释放音频会话。
                                        pushToTalk.pressCancelled()
                                    }
                                }
                        )

                    if let reChatText = pushToTalk.reChatContextText {
                        Text(reChatText)
                            .font(.caption2.bold())
                            .foregroundStyle(.blue)
                            .lineLimit(1)
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
                        Text("待发送 \(transport.pendingCount) 条")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // ESS-307 (D5 Gap-7)：下行队列积压可见性。
                    // 条件：有积压 AND 当前无处理中回合（处理中优先，积压不抢位）。
                    // 点击跳转到②历史时间线（tab 1）。
                    // 样式：克制的等待态（非红色），无秒级计时。
                    if showDownlinkBacklogHint {
                        Button {
                            selectedTab = 1
                        } label: {
                            Label("还有 \(settings.downlinkBacklogCount) 条结果没送到", systemImage: "tray.and.arrow.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
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

    // MARK: - 会话态主屏（ESS-573 / PRD §3.5.3 布局规格）

    /// 会话模式整屏 UI。布局规格（45mm 基准）：
    /// 球直径 125pt、圆心位于垂直 50%（v2.0 居中）、上方留白；
    /// X 常驻右下角、触控区 ≥44×44pt（Apple HIG 最小触控）、视觉 28pt；
    /// 建立中三点在球正下方 16pt（直径 4pt、间距 6pt）；异常一行文案在球
    /// 正下方 20pt、单行截断。全程无状态文字（PRD F7 硬约束），唯一例外是
    /// 异常链的一行可行动文案。
    private var sessionScreen: some View {
        GeometryReader { proxy in
            let orbSize = min(125, proxy.size.width * 0.7)
            ZStack {
                // ESS-600 F4：回答播放中点球 = 立刻打断并回到聆听。
                // 只有 speaking 相位接手势——聆听/思考中点球无语义，
                // 保持「会话中球不接手势」的原状，不造出误触面。
                VoiceOrbView(mode: sessionOrbMode, size: orbSize)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.5)
                    .accessibilityLabel(session.turnPhase == .speaking ? "打断回答" : "实时对话中")
                    .allowsHitTesting(session.turnPhase == .speaking)
                    .onTapGesture { session.interruptSpeaking() }

                // ESS-598：球体动画不能成为唯一反馈。真机强光、抬腕与连接
                // 建立期都可能让动画差异不可辨，明确显示当前主链路阶段。
                // ESS-1100：工具长任务期间这一行会持续换成真实进展文字
                // （「正在查询相关信息」…）。小屏三条硬约束都落在这里：
                // 单行、尾部截断、切换用 0.25s 淡入淡出而不是硬跳。
                // 高频抖动在会话层已按 0.8s 节流（`progressUpdateMinIntervalSeconds`）。
                Text(sessionStatusText)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: proxy.size.width)
                    .position(x: proxy.size.width / 2, y: 18)
                    .animation(.easeInOut(duration: 0.25), value: sessionStatusText)

                // 建立中 >800ms 未就绪 → 三点渐显（PRD §3.5.1 第 3 步）。
                if session.showConnectingDots {
                    connectingDots
                        .position(
                            x: proxy.size.width / 2,
                            y: proxy.size.height * 0.5 + orbSize / 2 + 16
                        )
                        .transition(.opacity)
                }

                // 异常一行文案（全 PRD 唯一允许状态文字的地方）。
                // ESS-891 复审阻断 1：三条同落点的提示用 else-if 串成单通道，
                // 互斥关系由代码保证，不靠运行期状态互斥的概率。
                if let notice = session.failureNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 12)
                        .position(
                            x: proxy.size.width / 2,
                            y: proxy.size.height * 0.5 + orbSize / 2 + 20
                        )
                        .transition(.opacity)
                } else if session.showFirstRunGuide {
                    // 首次引导（PRD §3.5.7）：只出现一次，3 秒淡出。
                    Text("说话就行，说完停一下")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .position(
                            x: proxy.size.width / 2,
                            y: proxy.size.height * 0.5 + orbSize / 2 + 20
                        )
                        .transition(.opacity)
                } else if session.lowVolumeHint {
                    // ESS-891：回答播放中系统音量过低 → 一行可行动提示。
                    // 落点下移一档，与失败/引导文案在视觉上区分。
                    Text("音量较低，旋转表冠调高")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .position(
                            x: proxy.size.width / 2,
                            y: proxy.size.height * 0.5 + orbSize / 2 + 34
                        )
                        .transition(.opacity)
                }

                // X：右下角常驻，任何会话态可点——隐私开关，触控区
                // ≥44×44pt。会话中球不接手势，不存在「点 X 误触球」的
                // 重叠面（PRD §3.5.3 的不重叠规则由此结构性满足）。
                Button {
                    session.exitSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.18), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("结束对话")
                .position(
                    x: proxy.size.width - 6 - 22,
                    y: proxy.size.height - 6 - 22
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 下滑 = 点 X（PRD §3.5.6 拦截规则）。只响应垂直为主的下滑，
            // 水平/斜向拖拽不触发；表冠不拦（系统默认）。
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if SessionController.isVerticalDismiss(translation: value.translation) {
                            session.exitSession()
                        }
                    }
            )
            .animation(.easeInOut(duration: 0.2), value: session.showConnectingDots)
            .animation(.easeInOut(duration: 0.2), value: session.failureNotice)
            .animation(.easeInOut(duration: 0.3), value: session.showFirstRunGuide)
            .animation(.easeInOut(duration: 0.3), value: session.lowVolumeHint)
        }
    }

    /// 建立中三点提示：直径 4pt、间距 6pt（PRD §3.5.3）。【待调】
    private var connectingDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Color.cyan).frame(width: 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    /// 会话中的球体投影——从既有可观察量计算，与 PTT 屏 orbMode 同一
    /// 口径，不在 SessionController 里另建回合真相：
    /// 建立中 → connecting（0.6 Hz）；录音中 → listening 随人声能量；
    /// 回合在跑/提交中 → thinking；播放中（含实时 PCM）→ speaking；
    /// 回合已终态且未在录/播 → idle（诚实表达「此刻没在采」，多轮
    /// 自动回聆听是 F2/F5 Wave 的事）。
    /// ESS-600：回合相位改由 `SessionController.turnPhase` 承担唯一真相——
    /// 它由真实链路事件（提交 / 首帧渲染 / 播完）推进，而从 PTT 可观察量
    /// 反推相位会在「已提交但 journal 还没落 activeTurn」这种间隙里读出
    /// 错误相位。球的能量条仍取 PTT 的实时电平（那是采集层事实）。
    private var sessionOrbMode: VoiceOrbView.Mode {
        switch session.state {
        case .connecting:
            // ESS-573 rebase 注：orb 侧的「建立中」态收敛到 ESS-572 已合入的
            // `.establishing`（0.6Hz 同一规格）；分支曾命名为 `.connecting`，
            // 与 #244 重复实现，rebase 时统一走 main 的命名与视觉。
            // ESS-600：建立中若本地已在采集，如实显示聆听能量——「网络还没通」
            // 不等于「表没在听」，两者必须独立可见（ESS-598 无反馈的根因之一）。
            return session.isCapturingLocally
                ? .listening(level: pushToTalk.recordingLevel)
                : .establishing
        case .listening:
            switch session.turnPhase {
            case .listening: return .listening(level: pushToTalk.recordingLevel)
            case .thinking: return .thinking
            case .speaking: return .speaking(level: 0)
            case .idle: return .idle
            }
        // ESS-673：ESS-652 给 `State` 加了 `.failed` / `.hungup` 却没补这两个
        // switch，main 编译不过。这里只做**最小可编译**的诚实映射：两态都不在
        // 采/播，球回 idle。P6 失败屏与 P7 挂断屏的完整视觉是 ESS-652 自己的
        // 交付物（控制器侧的 failureNotice / hungupSummary / retryFromFailed
        // 已经在，视图侧还没落），本单不代做。
        case .disconnecting, .idle, .failed, .hungup:            return .idle
        }
    }

    private var sessionStatusText: String {
        switch session.state {
        case .connecting:
            // 本地输入态与网络 ready 分开呈现。
            return session.isCapturingLocally ? "正在听…（连接中）" : "正在连接…"
        case .listening:
            switch session.turnPhase {
            case .listening: return "正在听…"
            // ESS-1100：工具回合把这一行让给真实进展（无进展文本时为稳定的
            // 「正在处理」）。`toolProcessingText == nil` = 本回合没有任何
            // 工具证据，普通直接回答走的还是**逐字相同**的那句「正在思考…」。
            case .thinking: return session.toolProcessingText ?? "正在思考…"
            // ESS-650 F2-4：gate 决定这句话。OFF 时说「点球」就只能点球；
            // ON 时必须把语音这条路说出来，否则用户不知道可以直接开口——
            // 一个不被告知的交互等于不存在。读的是 gate 的同一个真相源
            // （`WatchDebugSettings`，@Published），不另存一份投影。
            case .speaking:
                return debugSettings.voiceBargeInEnabled
                    ? "正在回答…（说话或点球打断）"
                    : "正在回答…（点球打断）"
            case .idle: return "稍等…"
            }
        case .failed:
            // 渲染控制器已经产出的那句话，不在这里另编一套文案（同上，
            // P6 的完整形态归 ESS-652）。
            return session.failureNotice ?? ""
        case .hungup:
            return session.hungupSummary ?? ""        case .disconnecting:
            return "正在结束…"
        case .idle:
            return ""
        }
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

    /// ESS-307：下行积压提示是否可见。
    /// 条件：队列有积压 AND 当前没有处理中的回合（处理中优先，不抢位）。
    private var showDownlinkBacklogHint: Bool {
        Self.shouldShowDownlinkBacklogHint(
            backlogCount: settings.downlinkBacklogCount,
            activeTurn: activeTurn
        )
    }

    /// 纯函数抽出便于 WatchTests 覆盖 UI 决策：有积压且无活跃回合时显示。
    static func shouldShowDownlinkBacklogHint(backlogCount: Int, activeTurn: VoiceTurnRecord?) -> Bool {
        backlogCount > 0 && activeTurn?.isActive != true
    }

    private var isSpeaking: Bool {
        player.isPlaying
    }

    /// ESS-572（Wave 0 / F7）：语音球五态映射。
    /// 所有中间等待态（sending / waitingForPhone / waitingForMac /
    /// delivered / processing / needsConfirmation）统统合并到
    /// `.thinking`——中间态的可视差异改由底部文案承担，球体只表达
    /// 「输入还是输出、正在还是空闲」。终态（completed/failed/cancelled）
    /// 一律回到 idle，失败的可见证据由 `AvatarErrorCardView` 承担；这样即使
    /// 卡片被用户手动关闭，屏幕也不会残留矛盾的失败/成功球。
    /// `.establishing` 预留给后续实时对话 Session 建立流程（ESS-540 F1）。
    private var orbMode: VoiceOrbView.Mode {
        if isRecording { return .listening(level: pushToTalk.recordingLevel) }
        if isSpeaking { return .speaking(level: 0) }
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
            // ESS-653：待机屏的录音态只存在于 touch-down 到松手这一小段。
            // 长按已不再提交，「松开发送」会变成一句当场被打脸的承诺。
            return MainStatusCopy(title: "我在听", subtitle: "松手就和分身通话")
        }
        if isSpeaking {
            // ESS-259 B-STOP：副标题承诺的「可点字幕打断」在 SubtitlePlaybackView
            // 里由 `.onTapGesture` + `PushToTalkController.stopPlaybackByUser` 兑现。
            return MainStatusCopy(title: "AI 分身正在说话…", subtitle: "全文同步展示，轻点字幕打断")
        }
        guard let turn = activeTurn, turn.isActive else {
            // ESS-653 / 设计稿 v2.0 P0 待机屏：主文案「点一下，和分身说话」，
            // 副文案留空（保持干净）。
            return MainStatusCopy(
                title: "点一下，和分身说话",
                subtitle: ""
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
            title: Self.processingTitle(for: turn.phase, elapsed: elapsed),
            subtitle: Self.processingSubtitle(for: turn.phase, elapsed: elapsed)
        )
    }

    /// ESS-180 / D4 Gap-3 语义化阶段词：0-10s 走短文案，10s+ 换「暂无进展」
    /// 提示，30s+ 换语义说明，60s+ 追加「较慢，可继续等待或取消」。
    /// 任何位置都不允许出现秒数或时:分。10s 档位只在无新事件时触发，
    /// 真实事件到达时 elapsed 归零自动抑制。
    static func processingTitle(for phase: VoiceTurnPhase, elapsed: TimeInterval) -> String {
        switch phase {
        case .sending: return "正在送出"
        case .waitingForPhone: return "等待手机连接"
        case .completed, .failed, .cancelled: return phase.title
        default: break
        }
        if elapsed >= 60 { return "任务较慢，可继续等待或取消" }
        switch phase {
        case .waitingForMac:
            if elapsed >= 30 { return "分身还在联系 Mac…" }
            if elapsed >= 10 { return "Mac 尚未响应" }
            return "已到手机，等待 Mac"
        case .delivered:
            if elapsed >= 30 { return "分身正在准备执行…" }
            if elapsed >= 10 { return "仍在等待 Mac 处理" }
            return "Mac 已受理"
        case .processing(let background):
            if elapsed >= 30 { return background ? "分身还在跑…" : "分身还在想…" }
            if elapsed >= 10 { return background ? "仍在后台运行…" : "仍在思考，请稍候" }
            return background ? "分身正在处理…" : "分身正在思考…"
        case .needsConfirmation: return "需要你的确认"
        default: return phase.title
        }
    }

    static func processingSubtitle(for phase: VoiceTurnPhase, elapsed: TimeInterval) -> String {
        switch phase {
        case .waitingForPhone: return "手机连上后自动送出"
        case .needsConfirmation: return "未确认前不会执行"
        default:
            if elapsed >= 60 { return "分身仍在运行，可以先放下手腕" }
            if elapsed >= 30 { return "仍在等待，可继续使用手表" }
            if elapsed >= 10 { return "暂无新进展，可放下手腕等待" }
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
