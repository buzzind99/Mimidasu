@testable import Mimidasu
import Testing

// MARK: - Kana folding

@Suite("ReadingAlignment folded kana")
struct ReadingAlignmentFoldedKanaTests {

    @Test("folds katakana onto hiragana, passing the long-vowel mark through",
          arguments: [
              ("ゲーム", "げーむ"),
              ("カタカナ", "かたかな"),
              ("ヴァイオリン", "ゔぁいおりん")
          ])
    func foldsKatakana(input: String, expected: String) {
        #expect(ReadingAlignment.foldedKana(input) == expected)
    }

    @Test("composes decomposed voicing marks before folding", arguments: [
        ("か\u{3099}", "が"),
        ("カ\u{3099}", "が")
    ])
    func composesDecomposedVoicing(input: String, expected: String) {
        #expect(ReadingAlignment.foldedKana(input) == expected)
    }

    @Test("passes non-kana scalars through unchanged", arguments: [
        ("A漢!", "A漢!"),
        ("", "")
    ])
    func passesNonKanaThrough(input: String, expected: String) {
        #expect(ReadingAlignment.foldedKana(input) == expected)
    }

    @Test("folds a katakana surface to the same kana as its aligned reading")
    func foldsAgreeWithRuns() throws {
        let runs = try #require(ReadingAlignment.runs(surface: "ゲーム", reading: "げーむ"))

        #expect(ReadingAlignment.foldedKana("ゲーム") == runs.map(\.kana).joined())
    }
}
