import Foundation

/// Pure ordering gate for token-pinned generation replacement.
struct BargeInGenerationCoordinator: Sendable {
    enum Action: Equatable, Sendable {
        case cancel(Int)
        case mintAndConnect(Int)
        case open(Int)
        case fallback(String)
        case ignore
    }

    private(set) var generation: Int
    private var replacing: (old: Int, new: Int)?
    private var replacementStarted = false
    private var fallbackIssued = false

    init(generation: Int) { self.generation = generation }

    mutating func request(from: Int) -> Action {
        guard replacing == nil, from == generation, !fallbackIssued else { return .ignore }
        replacing = (generation, generation + 1)
        replacementStarted = false
        return .cancel(generation)
    }

    /// ESS-1070：iPhone 是否还应当把这一帧下行转发给 Watch。
    ///
    /// 打断的验收是「停止旧 generation 播放**和下行**」。`generation` 在
    /// `cancel` 发出后仍停在旧值，直到新会话连上才 `ready()` 推进——若只用
    /// `gen == generation` 判定，换代窗口（等 `cancel.ack`，兜底 2 s）里旧代的
    /// `audio.delta` / `audio.done` / `audio.segment_done` 会继续被转发，恰好
    /// 占住用户新一轮上行要用的 WCSession 带宽。Watch 侧的 `.pending` 门禁
    /// 只是最后一道防线，不能替代「不再往下发」。
    ///
    /// 替换在途 = 一律不转发；已回退 = 一律不转发（此时连接正在拆除）。
    func shouldForwardDownlink(generation incoming: Int) -> Bool {
        guard !fallbackIssued, replacing == nil else { return false }
        return incoming == generation
    }

    mutating func cancelSettled(generation old: Int) -> Action {
        guard let replacing, replacing.old == old, !replacementStarted, !fallbackIssued else { return .ignore }
        replacementStarted = true
        return .mintAndConnect(replacing.new)
    }

    mutating func ready(generation new: Int) -> Action {
        guard let replacing, replacing.new == new, replacementStarted, !fallbackIssued else { return .ignore }
        generation = new
        self.replacing = nil
        replacementStarted = false
        return .open(new)
    }

    mutating func fail(_ reason: String) -> Action {
        guard replacing != nil, !fallbackIssued else { return .ignore }
        fallbackIssued = true
        replacing = nil
        replacementStarted = false
        return .fallback(reason)
    }
}
