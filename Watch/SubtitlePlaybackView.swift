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
struct SubtitlePlaybackView: View {
    let session: SubtitleSession
    @ObservedObject var player: SpeechPlayer
    /// 重播回调（ESS-53 §6）：播完后音频可能已从加密仓删除，由控制器
    /// 从内存重播缓存重新起播；nil 时不显示重播按钮。
    var onReplay: (() -> Void)?

    private let script: SubtitleScript
    @State private var currentIndex = 0
    /// 本会话内音频是否播过：区分「播完回看」与「从未进播放态」。
    @State private var hasTracked = false

    /// 200ms 轮询 currentTime：句级高亮足够，且远低于表盘刷新成本敏感区。
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    init(session: SubtitleSession, player: SpeechPlayer, onReplay: (() -> Void)? = nil) {
        self.session = session
        self.player = player
        self.onReplay = onReplay
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

    /// 本会话音频仍在播放器里（播放中或暂停中；player 可能在播别的内容，按 request_id 对账）。
    private var isActiveThisSession: Bool {
        session.hasAudio && player.progress(matching: session.requestId) != nil
    }

    private var isPlayingThisSession: Bool {
        isActiveThisSession && player.isPlaying
    }

    private var isPausedThisSession: Bool {
        isActiveThisSession && player.isPaused
    }

    private var isFinished: Bool {
        session.hasAudio && hasTracked && !isActiveThisSession
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
        HStack(spacing: 6) {
            if isPlayingThisSession {
                Label("播放中", systemImage: "speaker.wave.2.fill")
                    .foregroundStyle(.cyan)
            } else if isPausedThisSession {
                Label("已暂停", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            } else if isFinished {
                Label("已播完，可回看", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // 播放控制（ESS-53 §6）：暂停/继续；播完后可重播（内存缓存起播）。
            if isActiveThisSession {
                Button {
                    player.isPlaying ? player.pause() : player.resume()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            } else if isFinished, let onReplay {
                Button(action: onReplay) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption2)
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
