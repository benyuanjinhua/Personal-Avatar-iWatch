import SwiftUI

/// 一次字幕播放会话（ESS-48）。id 每次进入都新生成：interim 播放中最终结果
/// 到达时整体替换会话，视图随之切换，不会叠加两段字幕。
struct SubtitleSession: Identifiable, Equatable {
    let id: UUID
    let requestId: String
    let text: String
    /// false = 纯文本降级（无音频）：直接展示全文，不进播放态、不显示进度。
    let hasAudio: Bool

    init(requestId: String, text: String, hasAudio: Bool) {
        self.id = UUID()
        self.requestId = requestId
        self.text = text
        self.hasAudio = hasAudio
    }
}

/// 字幕式播放视图（ESS-48 MVP）：语音播放的同时展示全文，按播放进度
/// 逐句高亮 + 自动滚动；播完停留在全文视图可回看。
/// 时间轴映射按字符数加权（SubtitleScript），不是线性均分。
///
/// ESS-259 B-STOP：主屏文案「可点字幕打断」的真实入口——正在播放时轻点
/// 任意位置停止播放、留在 S-READ 全文可回看；不重新入队、不算失败、
/// 不发 `.failure` 触觉、不出错误卡片。
struct SubtitlePlaybackView: View {
    let session: SubtitleSession
    @ObservedObject var player: SpeechPlayer
    /// ESS-259：用户轻点字幕区触发的停止回调。仅在正在播放时才被调用；
    /// nil 表示只读回看态（例如「查看全文」入口，无音频可停）。
    let onUserStop: (() -> Void)?

    private let script: SubtitleScript
    @State private var currentIndex = 0
    /// 本会话内音频是否播过：区分「播完回看」与「从未进播放态」。
    @State private var hasTracked = false
    /// ESS-259：本会话是否被用户轻点打断过——决定收尾文案「已打断」/「已播完」。
    /// 视图级 state：sheet(item:) 每次新会话都会重建视图，天然与 session 生命周期对齐。
    @State private var didUserStop = false

    /// 200ms 轮询 currentTime：句级高亮足够，且远低于表盘刷新成本敏感区。
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    init(session: SubtitleSession, player: SpeechPlayer, onUserStop: (() -> Void)? = nil) {
        self.session = session
        self.player = player
        self.onUserStop = onUserStop
        self.script = SubtitleScript.make(text: session.text)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    statusHeader

                    if script.isEmpty {
                        Text("（无文字）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 12)
                    } else {
                        ForEach(script.sentences) { sentence in
                            Text(sentence.text)
                                .font(.footnote)
                                .fontWeight(isHighlighted(sentence) ? .semibold : .regular)
                                .foregroundStyle(color(for: sentence))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(sentence.index)
                        }
                    }
                }
                .padding(.horizontal, 4)
                // ESS-259：整块内容都是「点一下就停」的靶区——包含空白/句间
                // 空隙。`contentShape(Rectangle())` 保证 ScrollView 里没有文本的
                // 空白位置也接收点击；仅在正在播放时消费点击，回看态透传。
                .contentShape(Rectangle())
                .onTapGesture { userTappedToStop() }
            }
            .onReceive(ticker) { _ in tick(proxy: proxy) }
        }
        .onAppear {
            WatchLog.info(
                "subtitle", "subtitle_view_enter", requestId: session.requestId,
                detail: "sentences=\(script.sentences.count) chars=\(session.text.count) audio=\(session.hasAudio)"
            )
        }
        .onDisappear {
            WatchLog.info(
                "subtitle", "subtitle_view_exit", requestId: session.requestId,
                detail: "last_index=\(currentIndex) finished=\(isFinished)"
            )
        }
    }

    // MARK: - 播放状态

    /// 音频仍在为本会话播放（player 可能在播别的内容，如欢迎语，按 request_id 对账）。
    private var isPlayingThisSession: Bool {
        session.hasAudio && player.progress(matching: session.requestId) != nil
    }

    private var isFinished: Bool {
        session.hasAudio && hasTracked && !isPlayingThisSession
    }

    /// 高亮仅在播放中且多句时生效：单句不闪烁；播完/纯文本全量正常展示。
    private var highlightActive: Bool {
        script.supportsHighlight && isPlayingThisSession
    }

    private func isHighlighted(_ sentence: SubtitleSentence) -> Bool {
        highlightActive && sentence.index == currentIndex
    }

    private func color(for sentence: SubtitleSentence) -> Color {
        guard highlightActive else { return .primary }
        return sentence.index == currentIndex ? .primary : .secondary
    }

    @ViewBuilder
    private var statusHeader: some View {
        if isPlayingThisSession {
            VStack(alignment: .leading, spacing: 2) {
                Label("播放中", systemImage: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
                // ESS-259：明确告诉用户「可点字幕打断」的确切姿势，
                // 与主屏副标题承诺对齐；仅在能真正停止（有回调）时显示。
                if onUserStop != nil {
                    Text("轻点任意位置停止")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        } else if didUserStop {
            Label("已打断，可回看", systemImage: "hand.tap")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if isFinished {
            Label("已播完，可回看", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// ESS-259：用户轻点触发停止。仅在本会话正在播放时向上层派发；否则
    /// 不消费点击（避免回看态误产生 log/journal 事件）。didUserStop 标志
    /// 立刻切文案，不等 player.isPlaying 传回来——UI 感知延迟不该超过一帧。
    private func userTappedToStop() {
        guard let onUserStop, isPlayingThisSession else { return }
        didUserStop = true
        onUserStop()
    }

    /// 中断恢复（降腕/来电，依赖 ESS-45）后无需特判：currentTime 即恢复点，
    /// 下一次 tick 直接对位到对应句，不会回退首句。
    private func tick(proxy: ScrollViewProxy) {
        guard session.hasAudio, let progress = player.progress(matching: session.requestId) else { return }
        hasTracked = true
        guard script.supportsHighlight else { return }
        let index = script.sentenceIndex(at: progress.time, duration: progress.duration)
        guard index != currentIndex else { return }
        currentIndex = index
        WatchLog.info(
            "subtitle", "sentence_index_changed", requestId: session.requestId,
            detail: "index=\(index)/\(script.sentences.count)"
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}
