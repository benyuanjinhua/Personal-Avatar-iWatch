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
