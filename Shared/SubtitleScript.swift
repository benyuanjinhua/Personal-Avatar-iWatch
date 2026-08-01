import Foundation

/// 字幕脚本里的一句：展示文本 + 时间轴权重（ESS-48）。
struct SubtitleSentence: Equatable, Identifiable {
    let index: Int
    let text: String
    /// 可发音字符数（去标点、去空白）；时间区间按此加权，标点不计入，
    /// 避免全是标点的短句在时间轴上被高估。
    let weight: Int

    var id: Int { index }
}

/// 字幕脚本（ESS-48 字幕式播放 MVP）：把结果全文切成句子，并把
/// `AVAudioPlayer.currentTime / duration` 映射到当前句索引。
///
/// 时间轴不做线性均分——中文句子长短差异大，均分播到后半段高亮会明显跑偏。
/// 每句的时间区间按可发音字符数加权：权重 = 该句字符数 / 全文字符数。
struct SubtitleScript: Equatable {
    /// 单句展示上限（手表窄屏）：超过先试次分隔符 `；`，仍超则硬切。
    static let maxSentenceLength = 30
    /// 无标点长文本的硬切步长：保证不会出现一句占满全屏无法高亮。
    static let hardCutLength = 20

    let sentences: [SubtitleSentence]

    /// 每句时间区间的累计上界（(0, 1]）：sentences[i] 占 [upperBounds[i-1], upperBounds[i])。
    private let upperBounds: [Double]

    var isEmpty: Bool { sentences.isEmpty }
    /// 单句脚本不做逐句高亮（一句话反复高亮是噪声）。
    var supportsHighlight: Bool { sentences.count > 1 }

    /// 播放进度 → 当前句索引。duration 非法或播放未开始时回到第 0 句；
    /// 进度越界钳制到末句（中断恢复后按 currentTime 直接对位，不回退首句）。
    func sentenceIndex(at time: TimeInterval, duration: TimeInterval) -> Int {
        guard sentences.count > 1, duration > 0, time > 0 else { return 0 }
        let fraction = min(max(time / duration, 0), 1)
        if let index = upperBounds.firstIndex(where: { fraction < $0 }) {
            return index
        }
        return sentences.count - 1
    }

    static func make(text: String) -> SubtitleScript {
        let segments = split(text: text)
        var sentences: [SubtitleSentence] = []
        for segment in segments {
            let weight = pronounceableCount(of: segment)
            // 纯标点段（如省略号独立成段）并入前一句展示，不单独占时间区间。
            if weight == 0, !sentences.isEmpty {
                let last = sentences.removeLast()
                sentences.append(SubtitleSentence(
                    index: last.index, text: last.text + segment, weight: last.weight
                ))
                continue
            }
            sentences.append(SubtitleSentence(index: sentences.count, text: segment, weight: weight))
        }
        // 全文无可发音字符（理论兜底）：按等权处理，避免除零。
        let totalWeight = sentences.reduce(0) { $0 + $1.weight }
        let weights: [Double] = totalWeight > 0
            ? sentences.map { Double($0.weight) / Double(totalWeight) }
            : sentences.map { _ in 1.0 / Double(max(sentences.count, 1)) }
        var bounds: [Double] = []
        var cumulative = 0.0
        for weight in weights {
            cumulative += weight
            bounds.append(cumulative)
        }
        return SubtitleScript(sentences: sentences, upperBounds: bounds)
    }

    // MARK: - 分句（F2）

    /// 主分隔符：中文句末标点、其半角形式、换行。半角句点单独判定（见 isSentenceBreak）。
    private static let primarySeparators: Set<Character> = ["。", "！", "？", "…", "!", "?"]
    /// 次分隔符：仅当主分隔后单句仍超上限时启用。
    private static let secondarySeparators: Set<Character> = ["；", ";"]

    private static func split(text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            if character.isNewline {
                appendTrimmed(current, to: &segments)
                current = ""
                continue
            }
            current.append(character)
            if isSentenceBreak(character, next: offset + 1 < characters.count ? characters[offset + 1] : nil) {
                appendTrimmed(current, to: &segments)
                current = ""
            }
        }
        appendTrimmed(current, to: &segments)
        return segments.flatMap(enforceLengthLimit)
    }

    /// 半角句点仅在后随非字母数字时断句：不切开 URL（example.com）与小数（3.14）。
    private static func isSentenceBreak(_ character: Character, next: Character?) -> Bool {
        if primarySeparators.contains(character) { return true }
        guard character == "." else { return false }
        guard let next else { return true }
        return !(next.isLetter || next.isNumber)
    }

    /// 超过单句上限：先按次分隔符切；仍超上限的段按 hardCutLength 硬切。
    private static func enforceLengthLimit(_ segment: String) -> [String] {
        guard segment.count > maxSentenceLength else { return [segment] }
        var pieces: [String] = []
        var current = ""
        for character in segment {
            current.append(character)
            if secondarySeparators.contains(character) {
                appendTrimmed(current, to: &pieces)
                current = ""
            }
        }
        appendTrimmed(current, to: &pieces)
        return pieces.flatMap { piece -> [String] in
            guard piece.count > maxSentenceLength else { return [piece] }
            return hardCut(piece)
        }
    }

    private static func hardCut(_ segment: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in segment {
            current.append(character)
            if current.count >= hardCutLength {
                chunks.append(current)
                current = ""
            }
        }
        appendTrimmed(current, to: &chunks)
        return chunks
    }

    private static func appendTrimmed(_ segment: String, to segments: inout [String]) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(trimmed)
    }

    private static func pronounceableCount(of segment: String) -> Int {
        segment.reduce(0) { count, character in
            if character.isWhitespace || character.isPunctuation || character.isSymbol {
                return count
            }
            return count + 1
        }
    }
}
