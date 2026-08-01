import XCTest
@testable import WristAgentCore

/// ESS-48 字幕脚本：分句规则（F2）、字符数加权时间轴（F1）与边界场景（F3）。
final class SubtitleScriptTests: XCTestCase {

    // MARK: - 分句（F2）

    func testSplitsOnPrimarySeparators() {
        let script = SubtitleScript.make(text: "好的。今天北京多云！气温二十度？稍后有雨…")
        XCTAssertEqual(script.sentences.map(\.text), ["好的。", "今天北京多云！", "气温二十度？", "稍后有雨…"])
    }

    func testSplitsOnNewline() {
        let script = SubtitleScript.make(text: "第一行\n第二行")
        XCTAssertEqual(script.sentences.map(\.text), ["第一行", "第二行"])
    }

    func testHalfWidthPeriodDoesNotSplitURLOrDecimal() {
        let script = SubtitleScript.make(text: "圆周率是3.14。详见 example.com 的说明。")
        XCTAssertEqual(script.sentences.map(\.text), ["圆周率是3.14。", "详见 example.com 的说明。"])
    }

    func testSecondarySeparatorOnlyWhenOverLimit() {
        // 未超 30 字：分号不切。
        let short = SubtitleScript.make(text: "早上跑步；晚上读书。")
        XCTAssertEqual(short.sentences.map(\.text), ["早上跑步；晚上读书。"])
        // 超 30 字：启用分号次分隔。
        let long = SubtitleScript.make(
            text: "今天上午先去公司开产品评审会讨论手表字幕功能；下午回家整理会议纪要并同步给所有参与的同事。"
        )
        XCTAssertEqual(long.sentences.count, 2)
        XCTAssertTrue(long.sentences[0].text.hasSuffix("；"))
    }

    func testHardCutsUnpunctuatedLongText() {
        let text = String(repeating: "字", count: 45)
        let script = SubtitleScript.make(text: text)
        // 20 字硬切：20 + 20 + 5，无单句占满全屏。
        XCTAssertEqual(script.sentences.map(\.text.count), [20, 20, 5])
    }

    func testTrailingPunctuationMergesIntoPreviousSentence() {
        let script = SubtitleScript.make(text: "开始了。……")
        XCTAssertEqual(script.sentences.count, 1)
        XCTAssertEqual(script.sentences[0].text, "开始了。……")
    }

    func testEmptyTextProducesEmptyScript() {
        XCTAssertTrue(SubtitleScript.make(text: "").isEmpty)
        XCTAssertTrue(SubtitleScript.make(text: "  \n ").isEmpty)
    }

    // MARK: - 时间轴映射（F1：按字符数加权，不是线性均分）

    func testWeightExcludesPunctuation() {
        let script = SubtitleScript.make(text: "好的。今天天气很好！")
        XCTAssertEqual(script.sentences.map(\.weight), [2, 6])
    }

    func testIndexFollowsCharacterWeightNotLinearSplit() {
        // 「好的。」只有 2 个可发音字，后句 18 个：10 秒音频里首句只占前 1 秒。
        let script = SubtitleScript.make(text: "好的。今天北京多云转晴气温二十度体感非常舒适！")
        XCTAssertEqual(script.sentenceIndex(at: 0.5, duration: 10), 0)
        // 线性均分会把 0~5 秒都判给首句；加权映射在 2 秒处已进入第二句。
        XCTAssertEqual(script.sentenceIndex(at: 2, duration: 10), 1)
        XCTAssertEqual(script.sentenceIndex(at: 9.9, duration: 10), 1)
    }

    func testIndexProgressesThroughEqualSentences() {
        let script = SubtitleScript.make(text: "一二三四。五六七八。九十甲乙。")
        XCTAssertEqual(script.sentences.count, 3)
        XCTAssertEqual(script.sentenceIndex(at: 1, duration: 9), 0)
        XCTAssertEqual(script.sentenceIndex(at: 4, duration: 9), 1)
        XCTAssertEqual(script.sentenceIndex(at: 8, duration: 9), 2)
    }

    // MARK: - 边界（F3）

    func testSingleSentenceDisablesHighlight() {
        let script = SubtitleScript.make(text: "今天天气很好。")
        XCTAssertFalse(script.supportsHighlight)
        XCTAssertEqual(script.sentenceIndex(at: 3, duration: 6), 0)
    }

    func testOutOfRangeTimeClampsToLastSentence() {
        let script = SubtitleScript.make(text: "第一句。第二句。")
        // 中断恢复 / 播放器时间越界：钳制末句，不回退首句、不越界崩溃。
        XCTAssertEqual(script.sentenceIndex(at: 99, duration: 10), 1)
        XCTAssertEqual(script.sentenceIndex(at: -1, duration: 10), 0)
    }

    func testInvalidDurationFallsBackToFirstSentence() {
        let script = SubtitleScript.make(text: "第一句。第二句。")
        XCTAssertEqual(script.sentenceIndex(at: 1, duration: 0), 0)
        XCTAssertEqual(script.sentenceIndex(at: 1, duration: -5), 0)
    }
}
