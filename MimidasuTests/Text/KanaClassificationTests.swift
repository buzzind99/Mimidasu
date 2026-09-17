@testable import Mimidasu
import Testing

// MARK: - Scalar kana/kanji classification

@Suite("Kana classification")
struct KanaClassificationTests {

    @Test("classifies the hiragana block boundaries", arguments: [
        (0x3041, true), // ぁ small a, first hiragana
        (0x3040, false), // just below the block
        (0x309F, true), // ゟ digraph yori, last hiragana
        (0x30A0, false) // just above the block
    ])
    func hiraganaBoundaries(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isHiragana(scalar) == expected)
    }

    @Test("classifies the katakana block boundaries", arguments: [
        (0x30A0, false), // double hyphen, just below the block
        (0x30A1, true), // ァ small a, first katakana
        (0x30FC, true), // ー long-vowel mark
        (0x30FF, true), // ヿ digraph koto, last katakana
        (0x3100, false) // just above the block
    ])
    func katakanaBoundaries(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isKatakana(scalar) == expected)
    }

    @Test("classifies kanji, extension A, 々, and the astral gap", arguments: [
        (0x3005, true), // 々 iteration mark
        (0x3400, true), // 㐂 extension A first
        (0x4DBF, true), // extension A last
        (0x4E00, true), // 一 unified first
        (0x9FFF, true), // unified last
        (0xA000, false), // just above unified
        (0x20BB7, false) // 𠮷 beyond the BMP
    ])
    func kanjiBoundaries(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isKanji(scalar) == expected)
    }

    @Test("unites the hiragana and katakana ranges", arguments: [
        (0x3042, true), // あ
        (0x30A2, true), // ア
        (0x30FC, true), // ー
        (0x0041, false), // A
        (0x6F22, false) // 漢
    ])
    func kanaRanges(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isKana(scalar) == expected)
    }

    @Test("detects kanji anywhere in the text", arguments: [
        ("𠮷野家", true),
        ("桜", true),
        ("時々", true),
        ("かな", false),
        ("ABC", false),
        ("", false)
    ])
    func containsKanji(text: String, expected: Bool) {
        #expect(KanaClassification.containsKanji(text) == expected)
    }
}
